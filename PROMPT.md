# Tuning the prompt

The prompt in `claude-code-review.yml` ships with two `<<< REPLACE >>>` markers. The generic
version works. The version with six lines about your repo works much better, and it is the whole
difference between a reviewer you keep and one you turn off after a week.

A general-purpose reviewer already knows how to find null derefs, missing awaits, and unhandled
errors. What it cannot guess is which mistakes your team keeps making. That is what you are
supplying.

## Marker 1: what this repo is

Two to four lines. Name the stack and point at your docs.

```
This is the API server: Express 5 and TypeScript on Railway, Postgres with row-level
security, Stripe for billing. Read `CLAUDE.md` at the repo root first. It documents the
architecture, the job-queue model, conventions, and the hard constraints this code must honor.
```

Pointing at an in-repo doc matters more than the stack summary. If you keep a `CLAUDE.md`,
`ARCHITECTURE.md`, or `CONTRIBUTING.md`, name the file. The reviewer will read it and start
citing your own conventions back at you.

If you have no such file, write one before you tune this prompt. It pays off twice.

## Marker 2: the failure modes you have actually hit

This is the highest-value line in the file. Be specific. Name the real thing, not the category.

Weak:

```
Pay attention to security and data handling.
```

Strong, from a backend:

```
Pay extra attention to the failure modes this codebase has actually hit: job-queue
correctness (claim, heartbeat, reaper, timeouts, idempotency); billing-ledger double-writes
or missed ledger rows; Stripe webhook handling; multi-tenant scoping, where every
user-scoped or store-scoped query must filter by owner and a cross-user leak is critical;
row-level security and service-role usage; SQL migrations that need a matching CHECK
constraint or enum update; secrets or tokens reaching logs.
```

Strong, from a Next.js frontend:

```
Pay extra attention to the failure modes this codebase has actually hit: server and client
component boundaries, and accidental "use client" creep; secrets or service-role keys
leaking into the client bundle, where only NEXT_PUBLIC_* may reach the browser; auth gaps in
middleware and layout guards; multi-tenant scoping, where a cross-account leak is critical;
stale query caches and missing invalidation after mutations; realtime subscription leaks and
effect dependency churn; private storage buckets needing signed URLs rather than public URLs;
unhandled loading and error states; accessibility regressions on interactive components.
```

Where to get your list, in order of usefulness:

1. Your last ten postmortems or hotfix commits. Whatever broke twice belongs here.
2. The review comments you find yourself writing by hand over and over.
3. The constraints in your docs that a newcomer would not guess.

Add to it when something new breaks. It is a living line.

## Leave these alone

The rest of the prompt is doing specific work. Changing it usually costs you something.

**"Never review a hunk in isolation."** Without this the reviewer reads the diff and stops.
Opening call sites is where the real findings come from.

**"Verify every finding against the actual code before reporting it. Only report issues you have
confirmed."** This is the anti-hallucination clause. Drop it and you get plausible bugs that do
not exist, which is worse than no reviewer, because it trains you to ignore the output.

**"Cover the full severity range ... But never pad."** These pull against each other on purpose.
The first stops it from reporting only the one obvious bug. The second stops it from inventing
filler for a clean file. Keep both or the balance tips.

**"Comments only: do not approve, do not request changes, do not push commits."** This is what
keeps it out of your merge path. A reviewer that can block merges becomes something you fight.

**The severity tags.** `[critical]`, `[major]`, `[minor]`, `[improvement]`. Tagging held at 99.8%
across 640 comments in the sample, so you can filter and triage on them reliably. Pick different
words if you like, but keep four levels and keep them in the first line of the comment.

## Things worth trying

- Add a line telling it to skip a directory: generated clients, vendored code, snapshots.
- Add your test conventions if you want it to judge test quality rather than just coverage.
- If reviews come back too long, tighten the "cover the full severity range" line instead of
  cutting dimensions. You want it looking everywhere and reporting less.
