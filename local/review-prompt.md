Perform an in-depth code review of pull request #{{PR_NUMBER}} in {{REPO}}, titled "{{TITLE}}", at head commit {{HEAD_SHA}}.

Your working directory is a checkout of that head commit. Read `CLAUDE.md` at the repo root first if one exists. It documents the architecture, conventions, and constraints this code must honor.

{{STACK}}

Process:

1. Read the PR title and description (`gh pr view {{PR_NUMBER}}`), then the full diff (`gh pr diff {{PR_NUMBER}}`), then open every changed file in the checkout and enough surrounding code (call sites, handlers, migrations, related tests) to judge each change in context. Never review a hunk in isolation.
2. Hunt across ALL of these dimensions: correctness bugs and race conditions; edge cases and error handling; security issues; performance problems; API and contract regressions; test coverage gaps and test quality; readability, naming, and maintainability; simpler or more idiomatic alternatives.
3. Pay extra attention to the failure modes this codebase has actually hit:
{{WATCH_FOR}}
4. Verify every finding against the actual code before reporting it. Only report issues you have confirmed. No speculation about code you have not read.

Reporting:

Write your review as JSON to `{{OUTPUT_FILE}}`. That file is the only output that matters. Do not post anything to GitHub yourself; do not run `gh pr comment`, `gh pr review`, or any `gh api` write. The surrounding script reads your file and posts it.

The shape:

```json
{
  "summary": "markdown, a short overall assessment plus a severity-ordered index of the findings below",
  "findings": [
    {
      "path": "src/cache.ts",
      "line": 42,
      "side": "RIGHT",
      "severity": "critical",
      "body": "markdown: what is wrong, the concrete failure scenario or cost, and a specific suggested fix"
    }
  ]
}
```

Rules for the fields:

- `path` is the file path exactly as it appears in the diff, relative to the repo root.
- `line` MUST be a line that the diff actually touches. Anchoring to an untouched line makes GitHub reject the comment. Confirm each one against `gh pr diff {{PR_NUMBER}}` before you write it.
- `side` is `RIGHT` for added and unchanged lines, `LEFT` only when your comment is about a line the diff deletes.
- `severity` is one of `critical`, `major`, `minor`, `improvement`. The script prefixes the body with the tag, so do not repeat it inside `body`.
- `body` must be self-contained. Someone reading it on the line, with no other context, should understand the problem and how to fix it.

Cover the full severity range. Include minor issues and potential improvements, not just high-confidence bugs. But never pad: if an area of the diff is clean, do not invent findings for it. An empty `findings` array with an honest summary is a valid review.

Write the file even if you find nothing.
