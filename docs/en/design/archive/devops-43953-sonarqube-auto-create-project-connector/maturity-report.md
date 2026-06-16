# Maturity Report — SonarQube auto-create Project + Connector + Secret

<!--
Written at /feature:ship. Stratified blocker signal — the replacement for
a single "automation rate" percentage.
-->

## Feature metadata

- **Profile:** full
- **Risk:** sensitive
- **Repos:** connectors-extensions, connectors-operator
- **Effort (advisory):** —
- **Driver:** kychen (+ handoffs: none)
- **Bundle shipped:** v1.11.0-beta.183.gd204e0e@sha256:f9327e7250cec686ddcb4cf691a52fc1c10189a7f8f6b370daf81576ae81598f

## Stage summary

```
Total stages run: 12   (3 excluded — see below)
  none:      5     (auto-complete)
  template:  3
  skill:     0
  kb:        2
  judgment:  2     (on-target — not a miss)
  flake:     0
```

## Top intervention sources

<!-- Derived from entries with largest driver_edits.lines_changed or highest ai_turns. -->

1. **(template)** stage `research` — 14 AI turns synthesizing four p0
   stories from per-repo `Explore` sub-agents plus first-party SonarQube
   Web API research after the prerequisite ticket DEVOPS-43951 was
   cancelled and folded in. Driver edits: 0 lines.
   Suggested investment: enrich `templates/research.md` with the
   per-repo Explore prompt skeleton + a SonarQube/auto-create
   Web-API anchor section (parallels the GitLab-analogue prompt set
   already used here).

2. **(template)** stage `design` — 11 AI turns producing
   `product-design.md`, `tech-design.md`, and `threat-model.md` for the
   full Tekton Task surface, idempotency/rollback model, 16-task
   breakdown, 16 test cases, and 10 threats. Driver edits: 0 lines.
   Suggested investment: extract a reusable "auto-create connector Task"
   design template (Tenant Connector + Secret + admin-Connector + key
   pattern) from the SonarQube + GitLab + Harbor instances now on main —
   three instances is enough to template.

3. **(kb)** stage `qa` — 10 AI turns reconstructing QA evidence from the
   GitHub PR-check rollup after the named PipelineRuns
   (`connectors-sonarqube-integration-test-bk9vw`,
   `connectors-sonarqube-lint-and-test-m4kn4`) were reclaimed from the
   live Tekton namespace post-merge.
   Suggested investment: enable the Tekton Watcher results-archiver in
   the `connectors-extensions` `devops` namespace (already filed under
   improvement-log: tooling) so post-merge QA can pull per-scenario
   granularity from `results.tekton.dev`; add a KB entry for the
   PR-check-rollup fallback path when results-archiver is unavailable.

## Judgment-only stages (on-target)

<!-- Stages that were always going to be human judgment — not counted as misses. -->

- `accept`: deciding to waive the `/workflow:accept` sub-agent dispatch
  (duplicate work versus PR-check-rollup authority) and verifying AC-3
  / AC-9 via non-BDD evidence paths (precondition pass + mdx-on-main +
  doc-build) requires human reasoning about evidence equivalence; the
  AI is not expected to originate the waiver without a driver decision.
- `security-sign-off`: security review is human-judgment work by design
  (spec §step 6) for `risk=sensitive` features; reviewer cross-references
  threat-model assets, bundle delta, and any new egress against
  organizational policy.

## Excluded stages

<!-- Design-review loops, POC loops, story mutations, state-repair. -->

- `poc`: `poc-loop` — 62 AI turns across multiple Discord-driven
  sessions validating the Branch-3 auto-create hypothesis end-to-end
  against SonarQube 25.1 and 8.9.2. Excluded by design; POC loops are
  expected high-variance research blocks, not stage automation misses.
- `design-review` (round 1): `design-review-loop` — single targeted
  correction R1 (`tokenExpiry` → `tokenDuration` + bash-derived
  `expirationDate`). Excluded by design; design-review rework loops
  do not count against maturity totals.
- `implement` (integrate-partial entry): `integrate-partial` — first
  `/feature:integrate` pass reconciled 11 days of out-of-band PR
  activity, declared the bundle materially complete, but did not
  advance stage. Excluded by design; partial integrations are
  bookkeeping passes, not standalone stage closures.

## Reading this report

The category totals tell the team *where* to invest next (templates? skills?
KB?). The narratives tell the team *what specifically* to build. Judgment-only
interventions are the honest floor of human involvement on this class of work;
reducing them requires redesigning the stage, not better tooling.

This feature's category totals feed `docs/en/design/maturity-metrics.md`
via `/feature:metrics`.

### Headline for this feature

- **Five `none` stages** (`design-review` R2, `integrate`, `docs`,
  `regress`, `retrospective`) cleared with zero driver edits and ≤6 AI
  turns — the "done is done" pattern that the GitLab analogue
  (DEVOPS-43146) also produced once the design was settled.
- **Three `template` stages clustered upstream** (`research`, `design`,
  `plan`) — the same shape as DEVOPS-43146, and now ready to template
  because three auto-create connector implementations
  (Harbor / GitLab / SonarQube) cover the design space.
- **Two `judgment` stages** (`accept`, `security-sign-off`) are the
  honest human-judgment floor on a `risk=sensitive` feature; reducing
  these requires redesigning the stage, not tooling.
- **Two `kb` stages** (`init`, `qa`) are both Alauda-environment KB
  gaps (Jira-CLI bootstrap, Watcher results-archiver) — exactly the
  class of investment that pays back across every feature.
