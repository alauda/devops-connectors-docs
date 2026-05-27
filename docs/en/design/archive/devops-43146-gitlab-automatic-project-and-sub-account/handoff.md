# Handoff — Gitlab automatic project and sub-account support using API and CLI

<!--
This file is written or updated by /feature:handoff. It exists so the new
driver can pick up the feature cold by running /feature:status. Everything
that lives only in the prior driver's head should be captured here.
-->

## Previous driver

_(none — feature freshly initialised)_

## Current driver

daniel — initialised at 2026-05-06T03:50:00Z

## Current stage

design — next command: `/feature:design`

## Open blockers

_(none recorded at init)_

## Open questions for the new driver

_(none recorded at init)_

## Decisions deferred (and why)

- **Where to root the design docs** — deferred to `/feature:design`. The
  pre-existing `docs/en/design/connectors-auto-project/` already contains
  the Harbor reference design notes; decide whether to extend those in
  place or write fresh under this umbrella.
- **Per-group access level (option A)** — explicitly out of scope for
  this umbrella; documented as a manual workaround in the how-to.

## In-flight sub-agent state

_(no story groups yet — populated by `/feature:plan`)_

## Free-text note from previous driver

_(none — fresh init)_

---

**How to pick up:**

1. Run `/feature:status` — it will print the current stage, open blockers, and next command.
2. Read this file for context the prior driver carried in their head.
3. Read `product-design.md`, `tech-design.md`, and `research.md` **only** when the current stage needs them.
4. Run `/feature:next` to continue.

If the in-flight state looks inconsistent (e.g. a draft PR exists but
state.yaml says it doesn't), run `/feature:state-repair --audit-reason="..."`
rather than editing state.yaml manually.
