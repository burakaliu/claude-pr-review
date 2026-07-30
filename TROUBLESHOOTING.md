# Troubleshooting

Every failure mode below was seen in production across three repos, not guessed at.

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

## Reviews cost too much

Ordered by how much they save, and how much they cost you:

1. **Drop `synchronize` from the trigger list.** One review when the PR opens, none on later
   pushes. Biggest saving, and you lose review on the code you write after feedback.
2. **Narrow the branches.** `on.pull_request.branches: [main]` skips PRs into side branches.
3. **Use a smaller model.** Change `--model` in `claude_args`. It still works and it finds less.

Keep `concurrency` with `cancel-in-progress: true` no matter what. Pushing three times in a
minute otherwise pays for three reviews. In the sample it cancelled 14 runs.

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
