# Troubleshooting

Every failure mode in the Actions section was seen in production across three repos, not guessed
at. The local section covers the ones that version can hit.

- [Local](#local)
- [Windows](#windows)
- [Actions](#actions)
- [Both](#both)

# Local

Everything the daemon does goes to one log. Read it first:

```bash
tail -50 ~/.local/state/claude-pr-review/daemon.log
```

## Nothing happens at all

Check in this order:

1. **Is the agent loaded?**

   ```bash
   launchctl list | grep claude-pr-review
   ```

   Three columns: PID, last exit status, label. No PID between wake-ups is normal. A non-zero exit
   status is not, and `~/.local/state/claude-pr-review/launchd.err.log` will say why.

2. **Is the repo enabled?** Every repo in the starter config ships with `"enabled": false`.

3. **Is `gh` authenticated?** `gh auth status`. The daemon exits early without it.

4. **Is the PR a draft, or opened by a bot?** Both are skipped by design. Dependabot PRs are never
   reviewed.

5. **Was it already reviewed at this commit?** The daemon reviews a PR once per head commit.

   ```bash
   jq . ~/.local/state/claude-pr-review/reviewed.json
   ```

   Delete an entry to force a re-review, or use `--pr OWNER/REPO#42`, which ignores state.

## It reviewed every open PR at once

`seed_only` was `false` on a repo with a backlog. `max_reviews_per_run` caps each wake-up, so it
drains a few at a time rather than all at once, but it does drain.

To start from a clean slate, set `"seed_only": true`, let one pass run to record every open PR at
its current commit, then set it back to `false`. Only new pushes get reviewed after that.

## "no findings file written, nothing posted"

Claude finished without writing its JSON. Usually one of:

- **It hit the timeout.** Look for `claude exited 143` just above. Raise `timeout_seconds`.
- **It is not logged in.** Run `claude` once by hand and check.
- **The prompt template got edited** and no longer names the output file. `{{OUTPUT_FILE}}` has to
  survive in `local/review-prompt.md`.

The state file is not updated on a failure, so the next pass retries the same commit.

## "batch review rejected, falling back to individual comments"

A comment was anchored to a line the diff does not touch, and GitHub rejects the whole review when
any one comment is invalid. The fallback posts them one at a time and keeps whatever lands, so you
still get a review. The summary always goes up, and says how many inline comments made it.

An occasional one is normal. Every review doing it means the anchoring rule in the prompt got
weakened. See [PROMPT.md](PROMPT.md).

## Reviews arrive late, or not until morning

Nothing runs while the Mac is asleep. launchd fires the missed interval on wake, so a PR opened
overnight gets reviewed when you open the lid.

Because state is keyed on head commit, it reviews the current code rather than replaying every
commit it missed. Three overnight pushes cost one review, not three.

## Two runs at once

They cannot overlap. The second finds the lock and logs `pass skipped, pid N still running`. That
line is normal on any repo where a review runs longer than the poll interval.

If the daemon was killed mid-review the lock goes stale, and the next pass clears it after checking
the pid is gone. No action needed.

## Changing the config does not take effect

The config is read fresh on every wake-up, so edits apply to the next pass with no reload. Editing
the plist is different: rerun `./local/install.sh` for that.

Check the file parses, since a broken config stops the daemon before it does anything:

```bash
jq empty ~/.config/claude-pr-review/config.json
```

## Disk fills up

One clone per repo under `~/.cache/claude-pr-review`. They are blobless, so they are much smaller
than a normal clone, but they grow as they fetch. Safe to delete any time. The next pass re-clones.

# Windows

The Local section above applies too. These are the ones specific to running under Task Scheduler
and Git Bash. Read the log the same way:

```powershell
Get-Content "$HOME\.local\state\claude-pr-review\daemon.log" -Tail 50
```

## Every review logs "no findings file written", forever

The one Windows failure that looks like a Claude problem and is not. `claude` is a native Windows
binary and cannot resolve the POSIX paths the daemon works in. Told to write
`/tmp/claude-pr-review.abc/findings.json`, it reads that as drive-relative and writes
`D:\tmp\claude-pr-review.abc\findings.json`. The script then looks in the real temp directory,
finds nothing, and posts nothing. Every review burns its full runtime first.

Check for the giveaway:

```powershell
Get-ChildItem D:\tmp, C:\tmp -ErrorAction SilentlyContinue
```

A `claude-pr-review.*` directory at a drive root means the daemon is missing the `to_native`
conversion. Pull the current `local/review-daemon.sh`.

## Nothing runs, and the task shows no next run time

```powershell
Get-ScheduledTaskInfo -TaskName claude-pr-review | Select-Object LastRunTime, LastTaskResult, NextRunTime
```

An empty `NextRunTime` on a task that registered fine means it has only a logon trigger, and you
were already logged in when it was registered. It will sit there until the next logon. The
installer registers a time trigger alongside the logon one for exactly this reason; re-running
`install.ps1` fixes a hand-built task.

`LastTaskResult` of `267011` is not an error. It is "has not yet run".

## The task runs, but the log says claude or gh is not found

The task is running WSL's bash instead of Git's. `bash.exe` on PATH is
`C:\Windows\System32\bash.exe` on a default Windows 11 install, and the Windows-side `gh`, `jq`,
and `claude` are not on its PATH.

Check what the task actually calls:

```powershell
(Get-ScheduledTask -TaskName claude-pr-review).Actions.Arguments
```

The second quoted path must be a Git Bash, typically `C:\Program Files\Git\bin\bash.exe`. Re-run
`install.ps1`, which finds it from where `git.exe` is installed rather than trusting PATH.

## perl, sed, or mktemp not found

The daemon was launched without a login shell, so `/usr/bin` is missing from PATH. The launcher
runs `bash -l`. If you are invoking the script yourself, do the same:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -l local\review-daemon.sh --dry-run --pr OWNER/REPO#42
```

## A console window flashes every five minutes

The task is pointed straight at `bash.exe`. Task Scheduler has no setting that reliably suppresses
that window. The action should be `wscript.exe` running `local\windows\run-daemon.vbs`, which shows
nothing. Re-run `install.ps1`.

If your environment blocks Windows Script Host, point the task at `bash.exe` and accept the flash,
or set the task to run whether or not you are logged on, which hides it at the cost of storing your
password.

## It stops running after a reboot

The task runs with an interactive token, so it needs you logged in. That is what lets `gh` reach
the Windows credential store without a stored password. After a reboot it resumes at your next
logon, and the logon trigger runs a pass immediately rather than waiting out the interval.

If the machine must review while logged out, change the principal to run whether or not the user is
logged on, and expect to re-authenticate `gh` with a token in the environment rather than the
keyring.

## Checking it is alive

```powershell
Get-ScheduledTaskInfo -TaskName claude-pr-review | Select-Object LastRunTime, LastTaskResult, NextRunTime
Get-Content "$HOME\.local\state\claude-pr-review\daemon.log" -Tail 20
```

A healthy idle machine logs `pass complete, 0 review(s) run` on every wake-up.

# Actions

## The check is green but no review was posted

The most likely cause, and the one that wastes the most time.

The action refuses to run when the review workflow file on the PR branch differs from the copy on
the default branch. It is a security guard: it stops an untrusted pull request from editing the
workflow to reach your repository secrets. The action logs a warning, skips, and **exits with
conclusion `success`**.

Confirm it:

```bash
gh run view RUN_ID --log | grep -i "workflow validation"
```

You are looking for a line saying the workflow file must have identical content to the version on
the repository's default branch.

Two situations trigger it:

1. **The PR that adds the workflow.** It cannot review itself. Merge it to the default branch,
   then open a separate PR to test. There is no way around this and it is working as intended.
2. **Any later PR that edits the review workflow.** Same skip, same reason. Expect a no-op review
   on those PRs.

The tell without reading logs: the run finishes in under a minute. A real review takes 3 minutes
at the very least.

In the sample, exactly 2 of 136 successful runs were silent skips, and both were the install PR.
Once it is on your default branch this stops happening.

## Runs fail on dependabot PRs, after burning 15 minutes

The action rejects workflows started by a non-human actor that is not on its allowed-bots list.
That check does not run early. Two dependabot PRs in the sample failed after 12 and 18 minutes of
runner time.

The fix is in the shipped `if:` condition:

```yaml
if: >-
  !github.event.pull_request.draft &&
  github.event.pull_request.user.type != 'Bot'
```

That skips the job before the runner starts. If you want dependabot PRs reviewed, you need the
action's own allowed-bots configuration instead, not this filter.

## Nothing happens at all, no run appears

Check in this order:

1. **Is the workflow on the default branch?** GitHub only runs `pull_request` workflows it can see
   there. See the section above.
2. **Is the PR a draft?** The `if:` condition skips drafts. Mark it ready for review and the
   `ready_for_review` trigger picks it up.
3. **Is the secret set?** `gh secret list --repo OWNER/REPO`. A missing secret gives you a run
   that fails immediately, not a missing run, so this one is easy to rule out.

## Push failed: refusing to allow an OAuth App to create or update workflow

Your gh token lacks the `workflow` scope. Re-auth:

```bash
gh auth refresh -h github.com -s workflow
```

## Out of Actions minutes

Private repos draw from a monthly quota. When it runs out, jobs stop starting: the run appears,
fails in about 3 seconds, and lists no steps at all. It does not look like a billing problem.

```bash
gh api repos/OWNER/REPO/actions/runs/RUN_ID/jobs --jq '.jobs[] | {conclusion, steps}'
```

An empty `steps` array on a failed job is the tell.

Public repos have no such limit. For private ones, either move to the local runner or use a
self-hosted runner. See the README.

## Two reviews on one PR

Two workflows can both fire: the auto reviewer on `synchronize`, and the mention agent if someone
wrote `@claude` in a comment. That is expected. They are separate jobs with separate purposes.

## Run cancelled

Concurrency working as intended. Someone pushed again while the review was running, so the older
run got cancelled and the newer one reviews the newer code.

## Checking whether it is healthy

```bash
gh run list --workflow=claude-code-review.yml --repo OWNER/REPO --limit 20 \
  --json conclusion,createdAt,updatedAt,headBranch
```

Healthy looks like: mostly `success`, durations between 3 and 15 minutes, some `cancelled` from
re-pushes. A `success` under a minute is a silent skip.

# Both

## Reviews cost too much

On Actions, ordered by how much they save and how much they cost you:

1. **Drop `synchronize` from the trigger list.** One review when the PR opens, none on later
   pushes. Biggest saving, and you lose review on the code you write after feedback.
2. **Narrow the branches.** `on.pull_request.branches: [main]` skips PRs into side branches.
3. **Use a smaller model.** Change `--model` in `claude_args`. It still works and it finds less.

Keep `concurrency` with `cancel-in-progress: true` no matter what. Pushing three times in a
minute otherwise pays for three reviews. In the sample it cancelled 14 runs.

Locally there are no runner minutes, only Claude usage. Lower `model` to something smaller, or
lower `max_reviews_per_run` so a busy day cannot run away from you. The local version already
avoids the biggest waste on its own: it reviews once per head commit, so three pushes in a minute
cost one review rather than three.

## Reviews are too noisy

Expect a lot of `[minor]` and `[improvement]`. That was 87% of findings in the sample. It is the
design: the prompt tells it to cover the full severity range rather than report only
high-confidence bugs.

If you want less, tighten the reporting rules in the prompt rather than removing review
dimensions. You want it looking everywhere and saying less. See [PROMPT.md](PROMPT.md).

The severity tags are there so you can triage. Read critical and major, skim the rest.

## Findings that are wrong

The prompt has an explicit clause requiring verification before reporting. It holds most of the
time, not always. Treat the output as a careful colleague's first pass, not a verdict.

If you get a wrong finding, check whether the reviewer had the context to know better. Usually it
did not, and the fix is a line in your `CLAUDE.md` or in the repo-context block of the prompt, not
a change to the review instructions.
