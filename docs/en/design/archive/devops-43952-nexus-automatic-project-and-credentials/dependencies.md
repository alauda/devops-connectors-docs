# Dependencies — Nexus 自动创建 Project + Connector + Secret

<!--
Story-level dependency graph. Written by /feature:design and refined by
/feature:plan. Used by /feature:implement to order sub-agent dispatch.

Format: `<from-story-id> -> <to-story-id>   # rationale`

Cycles are rejected at /feature:design-review.
-->

## Stories (post-plan, 2026-05-27)

Original design carved 5 stories (1 / 2 / 3 / 3a / 4); `/feature:plan`
collapsed to **2 stories** based on the as-implemented organization:

- **Story 1** — extensions Task implementation (design-change parent).
  Bundles original Story 2 (BDD harness) and Story 4 (PaC pipeline) into
  one PR set. Status: PR #326 MERGED + PR #332 polish OPEN.
- **Story 2** — operator user docs + install-manifest sync
  (mechanical-followup bundle). Status: not-started.
- Original Story 3 (operator-side concept page) — folded into Story 2 as
  "no concept page; how-to + reference only" (round-3 design decision).
- Original Story 3a (conditional `nexusconfig` ConnectorClass field) —
  **CLOSED** at design-review: driver verified current implementation
  only needs a Nexus secret as workspace input, no schema change.

```text
1 -> 2     # operator user docs reference the as-implemented Task params /
           #   results, which come from Story 1 PR #326/#332 (extensions).
           #   Install-manifest sync (bundled into Story 2) also requires
           #   Story 1 PR to merge first, since /test sync-install-manifests
           #   pulls the latest extensions artifact.
```

## Pre-G2 alignment step (driver constraint 2026-05-27)

Before writing user docs in Story 2, **align the design artifacts to the
as-implemented Task**:

- `product-design.md` — refresh param table / result schema / 调用方式 to
  match merged PR #326 + polish PR #332.
- `tech-design.md` — refresh `## 调用路径` step 1-5 with actual script
  names, helper signatures, anonymous-warning routing, identity-suffix
  inputs, set-x bracket placement.
- `threat-model.md` — verify mitigations T4 / T6 / T7 / T9 / T13–15 still
  describe the merged implementation; update if regex / helper paths
  shifted.

Rationale: user docs (`using_nexus_connector_automatic_creation_task.mdx`
+ `nexus_connector_automatic_creation_task.mdx`) cite design docs for
authoritative param semantics. Citing stale design = stale user docs =
support drag. Align first, then write user docs against fresh source of
truth.

## Notes

- Story 1 dispatched first (its PRs are already in flight; just need to
  drive #332 polish to merge + verify CI).
- Story 2 blocked on Story 1 + pre-G2 alignment step above.
- 4-pillar exit gates (driver 2026-05-21 decision) apply per story:
  - Story 1: code + BDD green + multi-round review + manual smoke on
    live `devops-nexus` — exit conditions for the story, not external
    dependency edges.
  - Story 2 (mechanical-followup): inherits Story 1's exit signal +
    its own docs preview render check + install-manifest sync green CI.
- Mechanical-followups inherit the parent story's review (per `/feature:plan`
  default). G1 review covers Story 1 (design-review carry-over since
  scope unchanged); G2 review = jtcheng one-hat (mechanical content).
- Cross-feature waits (`wait-for=<feature-id>:<story-id>`) live in
  `state.yaml.collisions[].plan_decision`, not here. 当前与 DEVOPS-43146
  GitLab 的 low collision 已 acknowledged，无 sequencing wait。
