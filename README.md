# claude-pr-review

Run Claude Code as a reviewer on every pull request. It reads the diff, opens the surrounding
code, and posts each finding as an inline comment anchored to the line, tagged by severity.
Then it posts one summary comment with an index of what it found.

It never approves and never requests changes, so it cannot block a merge. It only comments.

## Two ways to run it

| | Runs on | GitHub Actions minutes | Setup |
|---|---|---|---|
| **[Local](#local-setup)** | your own machine, on a timer | none | one config file, one installer |
| **[Actions](#actions-setup)** | GitHub-hosted runners | billed on private repos | copy two workflow files in |

Start local if your repos are private. A 9 minute median review against a 2,000 minute monthly
quota runs out faster than you expect, and the failure is silent: jobs stop starting and finish in
3 seconds with no steps, which does not look like a quota problem until you check.

Public repos get unlimited free Actions minutes, so the Actions path is the easier choice there.

Either way you need a Claude subscription (Pro, Max, Team, or Enterprise) or an Anthropic API key.

## What the output looks like

Each inline comment starts with a severity tag and stands on its own:

> **[major]** `getCachedRecord` looks up by `recordId` only and ignores the `userId` argument.
> Two users requesting the same record id get the same cache entry, so the second request is
> served the first user's data. Add `userId` to the cache key.

Then one summary comment on the PR: a short assessment plus the findings listed worst first.

## Does it actually catch things

Numbers from three private repos, first review 2026-07-17, counted 2026-07-30. One React Native
app, one Express and TypeScript backend, one Next.js frontend.

| | |
|---|---|
| PRs reviewed | 57 |
| Inline findings | 640 |
| critical | 11 |
| major | 73 |
| minor | 334 |
| improvement | 221 |
| Median run time | 9 min |
| Range | 3.5 to 15 min |

Three of the eleven critical findings, paraphrased:

1. A cache lookup keyed on a record id while ignoring the user id it was handed, so one account
   could be served another account's cached data.
2. A full-privilege database service key placed behind a client-public environment variable
   prefix, which inlines the secret into the browser bundle.
3. A cache expiry constant named in milliseconds but computed in seconds, cutting an intended
   24-hour window down to 86 seconds.

Read the honest version of that table too. Most of the output is minor and improvement level.
Major and critical together are 13% of findings. That 13% is where the value is, and the severity
tags exist so you can skim the rest.

## Local setup

Runs on macOS or Windows. Either way it needs `gh`, `jq`, `git`, `perl`, and the `claude` CLI on
your PATH. Log in first with `gh auth login` and `claude` (or `claude setup-token`). On Windows it
also needs Git for Windows, because it runs through Git Bash.

### 1. Install

**macOS**

```bash
./local/install.sh
```

Registers a launchd agent and starts it. It wakes every 5 minutes. Set
`POLL_SECONDS=900 ./local/install.sh` for a different interval.

**Windows**

```powershell
powershell -ExecutionPolicy Bypass -File local\windows\install.ps1
```

Registers a scheduled task named `claude-pr-review`, triggered at logon and repeating every 5
minutes for as long as you stay logged in. Pass `-PollSeconds 900` for a different interval.

The installer checks that `jq`, `gh`, `git`, `claude`, and `perl` all resolve inside the shell the
task will actually use, and that `gh` is authenticated, before it registers anything. A missing
tool is an error at install time rather than a silent failure at 3am.

Both installers write a starter config to `~/.config/claude-pr-review/config.json`. Every repo in
it ships disabled, so nothing runs until you edit it.

### 2. Fill in the config

```json
{
  "model": "claude-opus-5",
  "max_reviews_per_run": 2,
  "timeout_seconds": 2700,
  "seed_only": false,

  "repos": [
    {
      "repo": "acme/billing-api",
      "enabled": true,
      "stack": "This is an Express and TypeScript backend, backed by Supabase Postgres, with Stripe for billing and Zod for request validation.",
      "watch_for": [
        "Routes that read a resource by id without checking the caller owns it.",
        "Stripe webhook handlers that are not idempotent, so a retried event double-charges."
      ]
    }
  ]
}
```

`stack` and `watch_for` are what separate a generic review from a good one. `watch_for` is the
higher-value field of the two: it is where you name the mistakes this repo keeps making. See
[PROMPT.md](PROMPT.md).

The top-level knobs:

| Key | Default | What it does |
|---|---|---|
| `model` | `claude-opus-5` | a smaller model works and finds less |
| `max_reviews_per_run` | `2` | ceiling per wake-up, so a backlog cannot stampede |
| `timeout_seconds` | `2700` | kills a review that hangs |
| `seed_only` | `false` | record open PRs without reviewing them, to start from a clean slate |

Adding a repo later is a matter of appending another object to `repos`. Nothing needs restarting;
the next wake-up reads the file fresh. On Windows there is a helper that appends the entry for you
and refuses a repo name your `gh` credentials cannot reach:

```powershell
local\windows\add-repo.ps1 -Repo acme/billing-api `
  -Stack "Express and TypeScript on Node 20, backed by Supabase Postgres." `
  -WatchFor "Routes that read a resource by id without checking the caller owns it."
```

### 3. Check it before trusting it

Review one PR and print the result without posting anything:

```bash
./local/review-daemon.sh --dry-run --pr OWNER/REPO#42
```

On Windows, run the same script through Git Bash:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -l local\review-daemon.sh --dry-run --pr OWNER/REPO#42
```

A dry run leaves the state file untouched, so it never suppresses the real review of that PR.

Then watch the real thing:

```bash
tail -f ~/.local/state/claude-pr-review/daemon.log
```

```powershell
Get-Content "$HOME\.local\state\claude-pr-review\daemon.log" -Wait -Tail 20
```

### Turning it off

```bash
./local/uninstall.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File local\windows\uninstall.ps1
```

Add `--purge` (or `-Purge`) to delete the config, state, and cached clones too.

## How the local version works

**Polling.** Every wake-up it calls `gh pr list` on each enabled repo, skipping drafts and
bot-authored PRs. Dependabot never gets reviewed, which matters: five open dependabot PRs would
otherwise be five full reviews.

**What counts as needing review.** It stores the last reviewed head commit per PR in
`~/.local/state/claude-pr-review/reviewed.json`. A PR is reviewed when that commit does not match
the current head, so a new push gets a fresh review and an untouched PR is left alone.

**Checkout.** One blobless clone per repo under `~/.cache/claude-pr-review`, fetched and parked on
the PR head. Claude runs with that as its working directory, so it can open any file in the repo,
not only the diff.

**Posting.** Claude writes its findings to a JSON file. The script posts them as one review
containing every inline comment plus the summary. If GitHub rejects the batch, usually because a
comment is anchored to a line outside the diff, it falls back to posting comments one at a time,
keeps the ones that land, and always posts the summary.

**Overlap.** The timer fires on a fixed interval and a review can outlast it. A lock makes the
second run a no-op rather than a duplicate review. The Windows task additionally sets
`IgnoreNew`, so the overlap is refused twice over.

**Sleep.** Nothing runs while the machine is asleep. It catches up on the next wake-up, and because
state is keyed on head commit it reviews the current code rather than replaying what it missed.

**Runtime.** Budget more than the Actions numbers above. A large PR took 22 minutes locally
against a 9 minute median on hosted runners, so `timeout_seconds` defaults to 45 minutes. Raise it
before you lower it: a review killed by the timeout writes nothing and gets retried on the next
pass, which costs more than letting it finish.

**Cost.** Reviews draw against your normal Claude usage, same as CLI work. GitHub is not involved
and bills nothing.

### What is different on Windows

Four things bite there, and the installer handles all four. They are written down because each one
fails quietly rather than loudly.

**`bash.exe` on PATH is the wrong bash.** On a default Windows 11 install it resolves to
`C:\Windows\System32\bash.exe`, which is WSL. That is effectively a different machine: the
Windows-side `gh`, `jq`, and `claude` are not on its PATH. The installer ignores PATH and locates
Git's own `bash.exe` from where `git.exe` is installed.

**`claude` is a native Windows binary, so it cannot read POSIX paths.** The daemon works in
`/tmp/...` form, but a native binary handed `/tmp/x` treats it as drive-relative and writes to
`D:\tmp\x`. Left alone, this is a total silent failure: every review runs for its full nine
minutes, writes its findings somewhere the script never looks, and logs `no findings file written,
nothing posted`. Every path handed to `claude`, on the command line or embedded in the prompt,
goes through `cygpath -m` first. `to_native` in `review-daemon.sh` is a no-op on macOS.

**A login shell is required.** `bash script.sh` leaves `/usr/bin` off the PATH, so `perl`, `sed`,
and `mktemp` all go missing. The launcher uses `bash -l`.

**Task Scheduler cannot hide a console window.** Pointing the task at `bash.exe` flashes one on
screen every five minutes, all day. The task runs `wscript.exe run-daemon.vbs` instead, which
shows nothing.

The task is triggered at logon rather than at startup, so it needs no stored password and runs
with your own credentials, which is what lets `gh` reach the Windows keyring. The tradeoff is that
a reboot nobody logs back in to leaves the reviewer down until the next login.

## Actions setup

The workflow files still work and are still the right choice for public repos.

| File | Trigger | What it does |
|---|---|---|
| `claude-code-review.yml` | every non-draft PR | full review, unprompted |
| `claude.yml` | `@claude` in a comment | answers questions, on demand |

### 1. Get a token

```bash
claude setup-token
```

It opens a browser, you authorize, and it prints a token good for one year. Usage counts against
your subscription. If you bill through the API instead, create a key at
[platform.claude.com](https://platform.claude.com).

### 2. Add it as a repository secret

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo OWNER/REPO
```

For an API key, set `ANTHROPIC_API_KEY` instead and change the `with:` line in
`claude-code-review.yml` to `anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}`.

### 3. Install the GitHub App

Install [github.com/apps/claude](https://github.com/apps/claude) on the repo. It needs read and
write on contents, issues, and pull requests. You need admin on the repo to install it.

The Claude Code CLI can walk you through steps 1 to 3 in one go with `/install-github-app`.

### 4. Copy the workflows in

```bash
cp workflows/claude-code-review.yml workflows/claude.yml /path/to/your/repo/.github/workflows/
```

Then edit the prompt in `claude-code-review.yml`. It has two `<<< REPLACE >>>` markers. Filling
them in is what separates a generic review from a good one. See [PROMPT.md](PROMPT.md).

Pushing workflow files needs the `workflow` scope on your gh token.

### 5. Merge to the default branch before you test

The action refuses to run when the workflow file on the PR branch differs from the copy on the
default branch. That is a security guard. It stops an untrusted pull request from editing the
workflow to reach your repository secrets.

It skips quietly and **exits green**. A passing check is not evidence that a review happened.

So the PR that adds these files can never review itself. Merge it first, then open a separate
throwaway PR to test. The same guard fires on any later PR that edits the review workflow, by
design.

### 6. Confirm it ran

Look for posted comments, or a run time over 3 minutes. Do not trust the green check. If a
review is missing, grep the run log:

```bash
gh run view RUN_ID --log | grep -i "workflow validation"
```

### How the Actions version is wired

**Triggers.** `opened`, `synchronize`, `ready_for_review`, `reopened`. `synchronize` means every
push to an open PR gets a fresh review, which is the behavior you want and also the main cost
driver.

**Concurrency.** One review per PR at a time, `cancel-in-progress: true`. Push three times in a
minute and you pay for one review, not three. Cancelled runs showed up 14 times in the sample.

**Drafts and bots.** The `if:` condition skips draft PRs and PRs opened by bots. The action rejects
non-human actors on its own, but not before burning runner time. Two dependabot PRs in the sample
ran 12 and 18 minutes before hitting that check.

**Permissions.** `contents: read` and no write access beyond comments. The reviewer cannot push,
and the prompt tells it not to try.

**Version pinning.** `anthropics/claude-code-action@v1` is a moving tag. It picks up patches
automatically. Pin to an exact release if you want the workflow frozen.

### A note on runner minutes

Private repos draw from your account's monthly Actions quota. Public repos are unlimited and free.

Self-hosted runners are a third option: keep the workflows and change `runs-on: ubuntu-latest` to
`runs-on: self-hosted`. GitHub bills no minutes for those today. It announced a per-minute charge
for self-hosted runners on private repos starting March 2026, then postponed it. Worth knowing
before you build on it. Personal accounts also register runners per repository, so three repos
means three runner services.

## Files

```
local/review-daemon.sh             the poller and reviewer, macOS and Windows
local/review-prompt.md             the prompt it runs, with placeholders
local/config.example.json          starter config
local/install.sh                   launchd agent installer, macOS
local/uninstall.sh                 removes it
local/windows/install.ps1          scheduled task installer, Windows
local/windows/uninstall.ps1        removes it
local/windows/add-repo.ps1         appends a repo to the config
local/windows/run-daemon.vbs       runs a pass with no console window
workflows/claude-code-review.yml   the reviewer, on Actions
workflows/claude.yml               the @claude mention agent, on Actions
PROMPT.md                          how to tune the prompt for your repo
TROUBLESHOOTING.md                 failure modes, with the fix for each
```

## License

MIT
