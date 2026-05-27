# Design Review — Gitlab automatic project and sub-account support using API and CLI

<!--
Written by /feature:design-review. Outcome is approved | pivot | rework.
This file is overwritten on each design-review round; round-by-round
history lives in state.yaml.maturity.entries[].
-->

## Round

Design-review **round #5** — the closing round. Carries forward all
substantive material reviewed in rounds 1–4 (PR #997 review threads
+ WeCom Q&A + team review + the Option-B image-strategy decision).

## Attendees

- Daniel Morinigo (driver) — backend lead-equivalent and self-acting
  security reviewer for the design-time gate (per `threat-model.md`
  Reviewer block; security label = connectors-domain-owner with
  security-overlay).

## Checklist

- [x] Goal is unambiguous — one Tekton TaskRun reconciles tenant
  GitLab group + optional subgroups, provisions a bot-backed GAT,
  lands a tenant `gitlab` Connector + Secret. Deployment-pattern-
  agnostic (admin Connector = user PAT or umbrella GAT).
- [x] Task breakdown covers the goal — 14 tasks across 4 stories;
  every AC mapped; build-time render contract covered by task 2;
  pipeline-wiring (operator-side) by tasks 13–14.
- [x] Direction is right — no unnecessary rebuilds; reuses catalog
  `glab` and `kubectl` images; localised render-tool (≤50 LOC) keeps
  scripts in connectors-extensions and avoids a new image.
- [x] Test design is concrete enough for QA to execute — Gherkin
  zh-CN named scenarios for both `tektoncd.feature` (Task contract +
  e2e) and `script.feature` (helper-script Pod-level), CEL assertion
  tables, per-suite focus, 15 numbered test cases mapped to ACs.
- [x] (n/a) UI slices — none in this feature; `ui-prototype.drawio`
  intentionally absent.
- [x] For risk=sensitive: threat-model residual risks acceptable.
  Reviewed all 10 threats + 10 mitigations + 4 residual-risk entries
  (Pattern-A user-takeover blast radius, umbrella GAT scope, orphaned
  GAT after step-2 fail, Pattern-A ownership drift). Mitigations
  match threat shape; residuals documented and accepted.
- [x] Dependency graph has no cycles — DAG verified: Story 1 → Story 2,
  Story 1 → Story 4, Story 3 ‖ all.

## Security considerations

**Trust roots.**
- Catalog-published `glab` and `kubectl` images via existing
  `catalog.tekton.dev/tool-image-{glab,kubectl}` ConfigMaps. Trivy +
  digest pinning is the catalog repo's responsibility (T7).
- Admin GitLab credential (user PAT for Pattern A or umbrella GAT for
  Pattern B) lives inside the connector proxy CSI mount; never read
  into Pod env; never echoed.
- Helper scripts in connectors-extensions (no catalog dependency at
  the script layer); `set +x` default; PR review checklist greps
  for `echo $TOKEN` and friends.

**Build-time supply chain.** Localising the render contract to
`connectors-extensions/connectors-gitlab/hack/render-task.sh` keeps
build-time machinery within a single repo's CI. The rendered Task
YAML is plaintext (no base64 obfuscation) — fully reviewable.

**Pre-ship checkpoint.** `/feature:security-sign-off` will run before
ship and re-confirm the threat model against the actual bundle
digest, RBAC delta, and exposed endpoints.

## Decisions

1. **Approved as-is.** All four prior round-3+ revisions
   (rework #1 → catalog reuse + ops scope; rework #2 → tenantGroup
   rename + Pattern A/B; rework #3 → testing format + expired-GAT
   self-heal + ops runbook; rework #4 → Option-B render-tool) are
   accepted. No further design changes required before /feature:plan.

2. **Reviewer set documented.** The standard-profile two-approver
   bar is met by the driver acting as backend-lead-equivalent + the
   risk=sensitive security-labeled reviewer (driver self-acting per
   threat-model.md Reviewer block). Pre-ship security gate
   (/feature:security-sign-off) is independent of this design-time
   sign-off and will run separately.

3. **`/feature:plan` is next.** The 14 tasks in tech-design.md become
   the OpenSpec change groups; per-story PR scaffolding picks up
   from dependencies.md.

## Outcome

**approved**

### Pivot / rework notes

_(n/a — outcome is approved)_

## Signatures

- Daniel Morinigo: approved (backend lead-equivalent), 2026-05-06.
- Security reviewer: Daniel Morinigo (self-acting; security label =
  connectors-domain-owner with security-overlay), 2026-05-06.
- (n/a) Frontend lead: no UI slice in this feature.
