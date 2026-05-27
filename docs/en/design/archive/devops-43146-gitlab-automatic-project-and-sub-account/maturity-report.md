# Maturity Report — Gitlab automatic project and sub-account support using API and CLI

<!--
Written at /feature:ship on 2026-05-15. Stratified blocker signal — the
replacement for a single "automation rate" percentage. Per the template
guidance, this is the at-a-glance per-stage view; excluded entries
(design-review loops, design reworks, state-repair invocations) are
listed separately so they don't distort the headline counts.
-->

## Feature metadata

- **Profile:** standard
- **Risk:** sensitive (overlay applied at /feature:init on 2026-05-06; threat model + pre-ship security sign-off both required and both completed)
- **Repos:** connectors-extensions, connectors-operator
- **Effort (advisory):** null (not estimated at /feature:init)
- **Driver:** daniel (no handoffs; sole driver across the full 9-day arc)
- **Bundle shipped:** `v1.11.0-beta.146.g1aecd74@sha256:81bc56523b3c097da8247a09a0dda32c6b4da786c8665371b29c90e81d5c0396`

## Stage summary

```
Total stages run (non-excluded): 12
  none:      5     (auto-complete)
  template:  0
  skill:     0
  kb:        2
  judgment:  5     (on-target — not a miss)
  flake:     0
```

Excluded entries are tracked separately under [Excluded stages](#excluded-stages) below — 11 excluded entries across design-review loops, design reworks, and three /feature:state-repair invocations.

## Top intervention sources

1. **(judgment)** stage `regress` — R3-relaxed regression decision required reasoning across three execution paths (R1 fresh trigger / R2 local make integration / R3 lift latest green) on an unhealthy main pipeline (~10% pass rate over 17h at decision time), then explicit driver-alignment over a 240-min session-arc. Not a miss — it is the kind of qualitative tradeoff the AI is supposed to surface, the driver picks. Suggested investment: **(process)** — promote R3-relaxed (cite-parent + delta-analysis) to a first-class option in the `/feature:regress` skill body so the next driver doesn't have to construct it on the fly. Already on the improvement-log.

2. **(judgment)** stage `qa` — F1 (jq-on-error guard) and F2 (idempotent-rerun, AC-7 amendment) both surfaced during live cluster execution on `daniel-5shk6` after BDD-suite green; required 10 ai turns to triage + ship the fix. Not a miss — this is exactly what live QA on a real cluster is supposed to catch ([[feedback_live_qa_catches_what_bdd_misses]] payoff). Suggested investment: **none** — the design intent is preserved; live QA is the design.

3. **(kb)** stage `init` — 6 ai turns to scaffold the umbrella against the existing `/feature:*` command surface as the first sensitive-overlay feature through this workflow. Suggested investment: **(template)** — better /feature:init starter examples in the TEP for first-time-sensitive features (concrete walk-through of overlay choice + threat-model.md scaffold). Tracked in retrospective.md (template Change entry).

## Judgment-only stages (on-target)

- `plan` — feature scoping + story decomposition is qualitative judgment about ACs vs technical breakdown. AI surfaces the breakdown candidates; driver picks.
- `qa` — live cluster execution + per-AC verification is human-judgment-driven; AI structures the run + records evidence.
- `regress` — execution-path selection (R1/R2/R3-strict/R3-relaxed) is qualitative tradeoff analysis. AI lays out options; driver picks.
- `security-sign-off` — security review is human-judgment work by design; the skill itself notes "judgment-classified maturity entries are the honest floor — not a miss."
- `retrospective` — synthesis from the session arc + memory is qualitative; AI drafts, driver edits if needed (no edits this run).

5 of 12 stages (~42%) are judgment-only. This is the floor for risk=sensitive features under the current workflow shape; reducing it requires redesigning the stage model, not better tooling.

## Excluded stages

11 excluded entries:

**Design-loop entries (8):** Design-review iterated 5 times before approval (`design-review` × 5, paired with `design` rework × 5). The first design-review pair is `kb`-blocked (rework after KB lookups); the next 4 are `judgment`-blocked (rework after design-time tradeoff discussion). Excluded per the template convention — design-review loops are the design stage's normal failure mode, not a maturity gap.

**State-repair entries (3, all `flake`-blocked):**
1. **Repair#1** (2026-05-11T12:15Z) — Story 3 + Story 4 PR URLs missing because no `/feature:*` command had written state since 2026-05-07; also schema additions for `implementation_repo` + `consolidated_from`.
2. **Repair#2** (2026-05-12T13:30Z) — `pr_state: ready → merged` flip after manual admin-squash merges of #269, #1000, #1002 (no /feature:* command auto-records merge events).
3. **Repair#3** (2026-05-14T09:45Z) — bundle drift v141 → v146 in `state.yaml.bundle.{tag,image}` (the QA+accept+docs-passing bundle was v146 after F1+F2 fixes; /feature:integrate had recorded v141 from the initial bundle pipeline run; /feature:integrate's skill has no stage-aware re-run mode so re-running it would have backtracked past 3 already-passed stages).

Per `/feature:state-repair`'s own guidance: "If a driver finds themselves invoking it more than once per feature, that is a bug in an earlier command and should be reported." This feature hit it 3 times — at least 2 of those 3 are skill gaps, not driver mistakes. Both are tracked as `(tooling)` Change entries in the retrospective + improvement-log:
- `/feature:integrate --re-record-bundle` (or auto-detect past-integrate stage) → would have prevented Repair#3.
- `/feature:record-merge <pr-url>` (or PR-merge hook) → would have prevented Repair#1 + #2.

## Reading this report

The category totals tell the team **where** to invest next. For this feature: **0 template, 0 skill, 0 flake** non-excluded — the workflow's primitives (templates, skill bodies, transient retries) held up under sensitive-overlay pressure. The maturity work for the next sensitive-overlay feature lands in the **excluded** column instead — specifically the 3-state-repair pattern, which the retrospective's Change entries already target.

The narratives tell the team **what specifically** to build (now in `improvement-log.md`):
- `(tooling)` `/feature:integrate --re-record-bundle`
- `(tooling)` `/feature:record-merge <pr-url>`
- `(template)` populated `security-reviewers.md` + warn at /feature:init
- `(tooling)` document PaC webhook-drift workaround inline
- `(process)` promote R3-relaxed to first-class option in `/feature:regress`
- `(tooling)` `make render-tasks` mtime check
- `(template)` extend retrospective.md template with PR ledger section

Judgment-only interventions are the honest floor of human involvement on this class of work; reducing them requires redesigning the stage, not better tooling.

This feature's category totals feed `docs/en/design/maturity-metrics.md` via `/feature:metrics`.
