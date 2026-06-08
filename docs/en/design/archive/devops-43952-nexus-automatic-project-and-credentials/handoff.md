# Handoff — Nexus 自动创建 Project + Connector + Secret

<!--
This file is written or updated by /feature:handoff. It exists so the new
driver can pick up the feature cold by running /feature:status. Everything
that lives only in the prior driver's head should be captured here.
-->

## Previous driver

_(none — feature is newly initialised)_

## Current driver

jtcheng — initialised at 2026-05-21T11:30:06Z

## Current stage

design — next command: `/feature:design`

## Open blockers

<!-- External dependencies, upstream decisions, review cycles -->

- Nexus permission-model research is folded into design (DEVOPS-43950
  merged into DEVOPS-43952 per Jingtao's 2026-05-07 note).

## Open questions for the new driver

1. Which Nexus identity model do we standardise on across customers —
   Local users with scoped roles vs. service-accounts vs. NXRM
   PRO user-tokens? Affects design / threat-model.
2. Is the parent-project shared-scope expected to map 1:1 to a Nexus
   group repository, or to a per-format set of hosted/proxy repos? PRD
   should pin this before tech-design.
3. Sibling story DEVOPS-43953 (SonarQube) is `Designing` — do we share
   any Task scaffolding, or stay strictly per-connector?

## Decisions deferred (and why)

- Effort sizing — deferred to design; will record on `/feature:design`
  close.
- Whether to introduce a new ResourceInterface for repo-creation
  attributes — deferred to tech-design.

## Implementation-stage exit gate (driver 2026-05-21)

Per driver decision recorded in `improvement-log.md`, each story exits
`/feature:implement` ONLY when all four pillars are done in the same
stage, not deferred to a later one:

1. Code merged.
2. BDD (`script.feature` / `tektoncd.feature`) green in CI.
3. ≥1 round of independent-agent review: `code-review-subagent` per repo
   + project-tier `connectors-code-review`; sensitive risk → add a
   security-angle review pass. Disposition recorded.
4. Manual smoke on the live `devops-nexus` instance via
   `/connectors-implement-manual-testing` skill; evidence in PR
   description.

Do NOT close an implement-stage story by saying "tests pass, review and
manual verification can come later". The whole point of this gate is
that "later" is when the cost of finding real-environment bugs is much
higher.

## In-flight sub-agent state

<!-- Populated automatically from state.yaml.story_groups[] -->

_(none — pre-plan)_

## Free-text note from previous driver

n/a

---

**How to pick up:**

1. Run `/feature:status` — it will print the current stage, open blockers, and next command.
2. Read this file for context the prior driver carried in their head.
3. Read `product-design.md`, `tech-design.md` **only** when the current stage needs them.
4. Run `/feature:next` to continue.

If the in-flight state looks inconsistent (e.g. a draft PR exists but state.yaml says it doesn't), run `/feature:state-repair --audit-reason="..."` rather than editing state.yaml manually.
