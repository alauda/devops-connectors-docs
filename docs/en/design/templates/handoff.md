# Handoff — {{title}}

<!--
This file is written or updated by /feature:handoff. It exists so the new
driver can pick up the feature cold by running /feature:status. Everything
that lives only in the prior driver's head should be captured here.
-->

## Previous driver

{{previous_driver}} — handed off at {{timestamp}}

## Current driver

{{current_driver}}

## Current stage

{{stage_current}}  — next command: {{next_command}}

## Open blockers

<!-- External dependencies, upstream decisions, review cycles -->

- {{blocker_1}}
- {{blocker_2}}

## Open questions for the new driver

<!-- Things the previous driver was waiting on a decision about -->

1. {{question_1}}
2. {{question_2}}

## Decisions deferred (and why)

<!-- Things that were intentionally not decided yet, with rationale -->

- {{decision_1}} — deferred because {{reason_1}}

## In-flight sub-agent state

<!-- Populated automatically from state.yaml.story_groups[] -->

- Story 1: {{repo}} PR #{{pr_number}} — state: {{pr_state}}, BDD: {{bdd_state}}
- Story 2: ...

## Free-text note from previous driver

{{handoff_note}}

---

**How to pick up:**

1. Run `/feature:status` — it will print the current stage, open blockers, and next command.
2. Read this file for context the prior driver carried in their head.
3. Read `product-design.md`, `tech-design.md`, and `research.md` **only** when the current stage needs them.
4. Run `/feature:next` to continue.

If the in-flight state looks inconsistent (e.g. a draft PR exists but state.yaml says it doesn't), run `/feature:state-repair --audit-reason="..."` rather than editing state.yaml manually.
