#!/usr/bin/env bash
#
# Poll GitHub for pull requests that need a review, then review them on this
# machine with the Claude Code CLI. Posts inline comments and one summary
# comment through the API. Uses no GitHub Actions minutes.
#
# One pass per invocation. launchd re-runs it on an interval. A lock makes
# overlapping runs a no-op, so a review that outlasts the interval is safe.
#
# Usage:
#   review-daemon.sh                      one normal pass over every enabled repo
#   review-daemon.sh --dry-run            review, print what would be posted, post nothing
#   review-daemon.sh --pr OWNER/REPO#42   review one pull request, ignoring saved state
#
# --dry-run leaves state untouched, so a dry run never suppresses the real one.

set -euo pipefail

DRY_RUN=false
TARGET_PR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --pr)      [ $# -ge 2 ] || { printf -- '--pr needs a value, e.g. OWNER/REPO#42\n' >&2; exit 2; }
               TARGET_PR="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

CONFIG_DIR="${CLAUDE_PR_REVIEW_CONFIG_DIR:-$HOME/.config/claude-pr-review}"
STATE_DIR="${CLAUDE_PR_REVIEW_STATE_DIR:-$HOME/.local/state/claude-pr-review}"
CACHE_DIR="${CLAUDE_PR_REVIEW_CACHE_DIR:-$HOME/.cache/claude-pr-review}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG="$CONFIG_DIR/config.json"
STATE="$STATE_DIR/reviewed.json"
LOG="$STATE_DIR/daemon.log"
LOCK="$STATE_DIR/daemon.lock"
PROMPT_TEMPLATE="${CLAUDE_PR_REVIEW_PROMPT:-$SCRIPT_DIR/review-prompt.md}"

mkdir -p "$STATE_DIR" "$CACHE_DIR"

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
}

die() {
  log "FATAL: $*"
  printf 'claude-pr-review: %s\n' "$*" >&2
  exit 1
}

# Keep the log from growing without bound.
rotate_log() {
  [ -f "$LOG" ] || return 0
  local size
  size=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt 5242880 ]; then
    mv "$LOG" "$LOG.1"
    log "rotated log"
  fi
}

# macOS ships no coreutils timeout, so build one out of a watchdog subshell.
run_with_timeout() {
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local watcher=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

acquire_lock() {
  if ! mkdir "$LOCK" 2>/dev/null; then
    local other=""
    [ -f "$LOCK/pid" ] && other=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      log "pass skipped, pid $other still running"
      exit 0
    fi
    log "clearing stale lock from pid ${other:-unknown}"
    rm -rf "$LOCK"
    mkdir "$LOCK" || die "cannot create lock at $LOCK"
  fi
  echo $$ >"$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH ($PATH)"
}

# ---------------------------------------------------------------- state

state_get() {
  jq -r --arg k "$1" '.[$k] // ""' "$STATE"
}

state_set() {
  local tmp="$STATE.tmp.$$"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# ---------------------------------------------------------------- checkout

# Maintain one blobless clone per repo and park it on the PR head commit.
#
# Everything stays on a detached HEAD. Fetching into a local branch that is
# currently checked out is a hard git error, so reviewing the same PR twice in
# the same clone fails on the second pass if named branches are used here.
prepare_checkout() {
  local repo="$1" pr="$2" sha="$3" dir="$4"

  if [ ! -d "$dir/.git" ]; then
    log "  cloning $repo"
    rm -rf "$dir"
    gh repo clone "$repo" "$dir" -- --filter=blob:none --no-checkout >>"$LOG" 2>&1 \
      || return 1
  fi

  git -C "$dir" fetch origin --prune --quiet >>"$LOG" 2>&1 || return 1
  git -C "$dir" fetch origin "pull/$pr/head" --force --quiet >>"$LOG" 2>&1 || return 1

  # Prefer the exact commit we recorded. If a push landed between listing the
  # PR and fetching it, FETCH_HEAD moved on, but the recorded commit is still
  # an ancestor and reviewing it keeps the posted review's commit_id honest.
  git -C "$dir" checkout --force --detach "$sha" --quiet >>"$LOG" 2>&1 \
    || git -C "$dir" checkout --force --detach FETCH_HEAD --quiet >>"$LOG" 2>&1 \
    || return 1
  git -C "$dir" clean -fdq >>"$LOG" 2>&1 || true

  # Drop branches left by older versions of this script, which are what made
  # the fetch above fail in the first place.
  git -C "$dir" for-each-ref --format='%(refname:short)' 'refs/heads/claude-pr-*' \
    | while read -r stale; do
        [ -n "$stale" ] && git -C "$dir" branch -D "$stale" >>"$LOG" 2>&1 || true
      done
}

# ---------------------------------------------------------------- posting

# One review carries every inline comment plus the summary. If GitHub rejects
# the batch (usually a line that is not part of the diff) fall back to posting
# the comments one at a time and keep the ones that land.
post_review() {
  local repo="$1" pr="$2" sha="$3" findings_file="$4"

  local summary comments count
  # GitHub rejects a review with an empty body, so never send one.
  summary=$(jq -r '(.summary // "") | if (. | gsub("\\s";"")) == "" then
      "Claude reviewed this pull request and wrote no summary." else . end' "$findings_file")
  # Normalize severity so an unexpected value cannot produce a junk tag, and
  # drop findings missing the fields GitHub requires to anchor a comment.
  comments=$(jq -c '[.findings[]?
    | select(.path != null and .line != null and .body != null)
    | (.severity // "improvement" | ascii_downcase) as $sev
    | {
        path: .path,
        line: .line,
        side: (if .side == "LEFT" then "LEFT" else "RIGHT" end),
        body: ("**[" + (if ["critical","major","minor","improvement"] | index($sev)
                        then $sev else "improvement" end) + "]** " + .body)
      }]' "$findings_file")
  count=$(jq 'length' <<<"$comments")

  if [ "$DRY_RUN" = "true" ]; then
    local dropped
    dropped=$(( $(jq '[.findings[]?] | length' "$findings_file") - count ))
    log "  dry run, posting nothing ($count inline comment(s) withheld)"
    printf '\n===== DRY RUN: %s#%s @ %s =====\n\n' "$repo" "$pr" "${sha:0:8}"
    printf -- '--- summary ---\n%s\n\n' "$summary"
    printf -- '--- %s inline comment(s), %s malformed and skipped ---\n' "$count" "$dropped"
    jq -r '.[] | "\n\(.path):\(.line) (\(.side))\n\(.body)"' <<<"$comments"
    printf '\n===== END DRY RUN =====\n\n'
    return 0
  fi

  log "  posting $count inline comment(s)"

  local payload
  payload=$(jq -n \
    --arg commit "$sha" \
    --arg body "$summary" \
    --argjson comments "$comments" \
    '{commit_id: $commit, body: $body, event: "COMMENT", comments: $comments}')

  if printf '%s' "$payload" \
    | gh api "repos/$repo/pulls/$pr/reviews" --method POST --input - >>"$LOG" 2>&1; then
    log "  review posted"
    return 0
  fi

  log "  batch review rejected, falling back to individual comments"

  local i posted=0
  for ((i = 0; i < count; i++)); do
    local one
    one=$(jq -c --argjson i "$i" '.[$i]' <<<"$comments")
    if jq -n --arg commit "$sha" --argjson c "$one" \
      '{commit_id: $commit, path: $c.path, line: $c.line, side: $c.side, body: $c.body}' \
      | gh api "repos/$repo/pulls/$pr/comments" --method POST --input - >>"$LOG" 2>&1; then
      posted=$((posted + 1))
    else
      log "  dropped comment on $(jq -r '.path' <<<"$one"):$(jq -r '.line' <<<"$one")"
    fi
  done

  # The summary always goes up, even when every inline anchor failed.
  local body="$summary"
  if [ "$posted" -lt "$count" ]; then
    body="$summary"$'\n\n---\n\n'"_Posted $posted of $count inline comments. The rest could not be anchored to the diff._"
  fi
  printf '%s' "$body" | gh pr comment "$pr" --repo "$repo" --body-file - >>"$LOG" 2>&1 \
    || log "  summary comment failed"
  log "  posted $posted/$count inline, summary posted"
}

# ---------------------------------------------------------------- review

review_pr() {
  local repo="$1" pr="$2" sha="$3" title="$4" stack="$5" watch_for="$6"

  local slug dir
  slug=$(printf '%s' "$repo" | tr '/' '_')
  dir="$CACHE_DIR/$slug"

  log "  preparing checkout"
  if ! prepare_checkout "$repo" "$pr" "$sha" "$dir"; then
    log "  checkout failed, skipping"
    return 1
  fi

  local work findings prompt
  work=$(mktemp -d "${TMPDIR:-/tmp}/claude-pr-review.XXXXXX")
  findings="$work/findings.json"

  prompt=$(sed \
    -e "s|{{REPO}}|$repo|g" \
    -e "s|{{PR_NUMBER}}|$pr|g" \
    -e "s|{{HEAD_SHA}}|$sha|g" \
    -e "s|{{OUTPUT_FILE}}|$findings|g" \
    "$PROMPT_TEMPLATE")
  # Free-text fields go through the environment so their contents cannot be
  # read as sed replacement syntax.
  prompt=$(STACK="$stack" WATCH_FOR="$watch_for" TITLE="$title" \
    perl -pe 's/\{\{STACK\}\}/$ENV{STACK}/g; s/\{\{WATCH_FOR\}\}/$ENV{WATCH_FOR}/g; s/\{\{TITLE\}\}/$ENV{TITLE}/g' \
    <<<"$prompt")

  log "  running claude ($MODEL)"
  local rc=0
  (
    cd "$dir" || exit 1
    run_with_timeout "$TIMEOUT_SECONDS" \
      claude -p "$prompt" \
      --model "$MODEL" \
      --permission-mode acceptEdits \
      --add-dir "$work" \
      --allowedTools "Read,Grep,Glob,Write,Bash(gh pr view:*),Bash(gh pr diff:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*)" \
      >>"$LOG" 2>&1
  ) || rc=$?

  if [ "$rc" -ne 0 ]; then
    log "  claude exited $rc"
  fi

  if [ ! -s "$findings" ]; then
    log "  no findings file written, nothing posted"
    rm -rf "$work"
    return 1
  fi

  if ! jq empty "$findings" 2>/dev/null; then
    log "  findings file is not valid JSON, nothing posted"
    rm -rf "$work"
    return 1
  fi

  post_review "$repo" "$pr" "$sha" "$findings"
  rm -rf "$work"
  return 0
}

# ---------------------------------------------------------------- main

main() {
  rotate_log
  acquire_lock

  require jq
  require gh
  require git
  require claude
  require perl

  [ -f "$CONFIG" ] || die "no config at $CONFIG (copy local/config.example.json there)"
  jq empty "$CONFIG" 2>/dev/null || die "config at $CONFIG is not valid JSON"
  [ -f "$PROMPT_TEMPLATE" ] || die "no prompt template at $PROMPT_TEMPLATE"
  [ -f "$STATE" ] || echo '{}' >"$STATE"

  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

  MODEL=$(jq -r '.model // "claude-opus-5"' "$CONFIG")
  TIMEOUT_SECONDS=$(jq -r '.timeout_seconds // 2700' "$CONFIG")
  local max_reviews seed_only
  max_reviews=$(jq -r '.max_reviews_per_run // 2' "$CONFIG")
  seed_only=$(jq -r '.seed_only // false' "$CONFIG")

  # Targeted mode: review exactly one pull request and stop. Saved state is
  # ignored on the way in, and only updated on a real (non dry) run.
  if [ -n "$TARGET_PR" ]; then
    local t_repo t_pr
    t_repo="${TARGET_PR%%#*}"
    t_pr="${TARGET_PR##*#}"
    [ -n "$t_repo" ] && [ -n "$t_pr" ] && [ "$t_repo" != "$t_pr" ] \
      || die "--pr wants OWNER/REPO#NUMBER, got: $TARGET_PR"

    local meta t_sha t_title t_stack t_watch
    meta=$(gh pr view "$t_pr" --repo "$t_repo" --json headRefOid,title 2>>"$LOG") \
      || die "cannot read $t_repo#$t_pr"
    t_sha=$(jq -r '.headRefOid' <<<"$meta")
    t_title=$(jq -r '.title' <<<"$meta")
    t_stack=$(jq -r --arg r "$t_repo" '(.repos // [])[] | select(.repo == $r) | .stack // ""' "$CONFIG")
    t_watch=$(jq -r --arg r "$t_repo" '(.repos // [])[] | select(.repo == $r)
      | ((.watch_for // []) | map("- " + .) | join("\n"))' "$CONFIG")

    log "$t_repo#$t_pr: targeted review of $t_sha (dry_run=$DRY_RUN)"
    if review_pr "$t_repo" "$t_pr" "$t_sha" "$t_title" "$t_stack" "$t_watch"; then
      [ "$DRY_RUN" = "true" ] || state_set "$t_repo#$t_pr" "$t_sha"
      log "$t_repo#$t_pr: done"
      return 0
    fi
    log "$t_repo#$t_pr: review failed"
    return 1
  fi

  local reviewed=0

  while IFS=$'\t' read -r repo stack watch_for enabled; do
    [ -n "$repo" ] || continue
    # @tsv escapes newlines as a literal backslash-n. Put them back.
    stack=$(printf '%b' "$stack")
    watch_for=$(printf '%b' "$watch_for")
    if [ "$enabled" = "false" ]; then
      log "$repo: disabled, skipping"
      continue
    fi

    local prs
    if ! prs=$(gh pr list --repo "$repo" --state open --limit 50 \
      --json number,headRefOid,isDraft,title,author 2>>"$LOG"); then
      log "$repo: could not list pull requests, skipping"
      continue
    fi

    local rows
    rows=$(jq -r '.[]
      | select(.isDraft == false)
      | select((.author.is_bot // false) == false)
      | [(.number|tostring), .headRefOid, .title] | @tsv' <<<"$prs")

    while IFS=$'\t' read -r pr sha title; do
      [ -n "$pr" ] || continue

      local key seen
      key="$repo#$pr"
      seen=$(state_get "$key")

      if [ "$seen" = "$sha" ]; then
        continue
      fi

      # First sight of a pull request that predates installation. Record it
      # and move on, so turning the daemon on does not review the backlog.
      if [ -z "$seen" ] && [ "$seed_only" = "true" ]; then
        [ "$DRY_RUN" = "true" ] || state_set "$key" "$sha"
        log "$key: seeded at $sha, not reviewed"
        continue
      fi

      if [ "$reviewed" -ge "$max_reviews" ]; then
        log "$key: hit max_reviews_per_run ($max_reviews), leaving for next pass"
        continue
      fi

      log "$key: reviewing $sha ($title)"
      if review_pr "$repo" "$pr" "$sha" "$title" "$stack" "$watch_for"; then
        [ "$DRY_RUN" = "true" ] || state_set "$key" "$sha"
        log "$key: done"
      else
        log "$key: review failed, will retry next pass"
      fi
      reviewed=$((reviewed + 1))

    done <<<"$rows"

  done < <(jq -r '(.repos // [])[]
    | [ .repo,
        (.stack // ""),
        ((.watch_for // []) | if length == 0 then "" else (map("- " + .) | join("\n")) end),
        ((.enabled // true) | tostring)
      ] | @tsv' "$CONFIG")

  log "pass complete, $reviewed review(s) run"
}

main "$@"
