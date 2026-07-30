# claude-pr-review

Run Claude Code as a reviewer on every pull request. It reads the diff, opens the surrounding
code, and posts each finding as an inline comment anchored to the line, tagged by severity.
Then it posts one summary comment with an index of what it found.

It never approves and never requests changes, so it cannot block a merge. It only comments.

Two workflow files:

| File | Trigger | What it does |
|---|---|---|
| `claude-code-review.yml` | every non-draft PR | full review, unprompted |
| `claude.yml` | `@claude` in a comment | answers questions, on demand |

You need a Claude subscription (Pro, Max, Team, or Enterprise) or an Anthropic API key.

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

## Setup

Six steps. Step 5 is the one people get wrong.

### 1. Get a token

If you have a Claude subscription, run this in the Claude Code CLI:

```bash
claude setup-token
```

It opens a browser, you authorize, and it prints a token good for one year. Usage counts against
your subscription.

If you bill through the API instead, create a key at [platform.claude.com](https://platform.claude.com).

### 2. Add it as a repository secret

For a subscription token:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo OWNER/REPO
```

For an API key:

```bash
gh secret set ANTHROPIC_API_KEY --repo OWNER/REPO
```

If you use the API key, change the `with:` line in `claude-code-review.yml` to
`anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}`.

### 3. Install the GitHub App

Install [github.com/apps/claude](https://github.com/apps/claude) on the repo. It needs read and
write on contents, issues, and pull requests. You need admin on the repo to install it.

The Claude Code CLI can walk you through steps 1 to 3 in one go:

```
/install-github-app
```

### 4. Copy the workflows in

```bash
cp workflows/claude-code-review.yml workflows/claude.yml /path/to/your/repo/.github/workflows/
```

Then edit the prompt in `claude-code-review.yml`. It has two `<<< REPLACE >>>` markers.
Filling them in is what separates a generic review from a good one. See [PROMPT.md](PROMPT.md).

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

More failure modes in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## How it is wired

**Triggers.** `opened`, `synchronize`, `ready_for_review`, `reopened`. `synchronize` means every
push to an open PR gets a fresh review, which is the behavior you want and also the main cost
driver. Drop it if reviews get noisy.

**Concurrency.** One review per PR at a time, `cancel-in-progress: true`. Push three times in a
minute and you pay for one review, not three. Cancelled runs showed up 14 times in the sample,
each one money saved.

**Drafts and bots.** The `if:` condition skips draft PRs and skips PRs opened by bots. The action
rejects non-human actors on its own, but not before burning runner time. Two dependabot PRs in
the sample ran 12 and 18 minutes before hitting that check.

**Permissions.** `contents: read` and no write access beyond comments. The reviewer cannot push,
and the prompt tells it not to try.

**Model.** `--model claude-opus-5`. A cheaper model works and finds less. This is a judgment call
about what a missed bug costs you.

**Version pinning.** `anthropics/claude-code-action@v1` is a moving tag. It picks up patches
automatically. Pin to an exact release if you want the workflow frozen.

## Cost

On a subscription token, reviews draw against your normal Claude usage, same as CLI work. On an
API key, you pay per token. Either way the shape is: one full-context read of the diff plus the
files around it, per push, on an Opus-class model. That is not cheap per PR.

Three levers if it costs too much:

1. Drop `synchronize` so it reviews once at open instead of on every push.
2. Narrow `on.pull_request.branches` to the branches you actually care about.
3. Move to a smaller model in `claude_args`.

GitHub Actions runner minutes are billed separately by GitHub. At a 9 minute median, that adds up
on private repos.

## Files

```
workflows/claude-code-review.yml   the reviewer
workflows/claude.yml               the @claude mention agent
PROMPT.md                          how to tune the prompt for your repo
TROUBLESHOOTING.md                 failure modes, with the fix for each
```

## License

MIT
