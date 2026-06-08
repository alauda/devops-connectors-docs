# Feature: Nexus 自动创建 Project + Connector + Secret

<!--
This file is the human-readable index of the umbrella. state.yaml is the
machine-readable source of truth. Both are written by /feature:* commands;
manual edits to state.yaml are detected by integrity hash.
-->

- **Jira:** DEVOPS-43952 — [link](https://jira.alauda.cn/browse/DEVOPS-43952)
- **Parent epic:** DEVOPS-43559 — *Automatic Project, Connector and Secret creation (Nexus, SonarQube)* (linked via Epic Link; this umbrella is a *standalone* feature, not branched from an epic umbrella)
- **Reporter:** DevOps Bot
- **Assignee:** Jingtao Cheng (jtcheng)
- **Blocks:** merged from DEVOPS-43950 (Nexus permission-model research — research folded into design per `--profile=standard`); sibling story DEVOPS-43953 (SonarQube automatic creation, Designing); reference DEVOPS-43146 (GitLab automatic creation, regress) and DEVOPS-43145 (Harbor automatic creation, archived) for prior-art reuse / rejection patterns.

## Classification

- **Profile:** standard  (light | standard | full)
- **Risk:** sensitive  (low | standard | sensitive) — driver `--risk` override matches computed value; see `security.override` in state.yaml.
- **Repos affected:** connectors-extensions (`connectors-extensions/connectors-nexus`), connectors-operator (pipeline wiring only — `hack/sync_install_manifests.sh` + values.yaml stub; `cmd/kodata/` is still auto-synced).
- **Effort (advisory):** _unset_ (refined during design)
- **Driver:** jtcheng

## Summary

Ship a Tekton Task `nexus-connector-automatic-creation/0.1` under
`connectors-extensions/connectors-nexus/tektoncd/tasks/` that, given one
admin Nexus Connector, provisions a per-project Nexus repository
hierarchy (parent-project shared scope + namespace-project restricted
scope), creates scoped users/roles (re-using Nexus
service-account / robot-account model where supported; falling back to
per-project user with scoped role otherwise), and reconciles the
resulting Connector + Secret into the target project namespace. Covers
rollback on partial failure, integration tests on multi-level hierarchy,
and user docs / API references.

Spec research (DEVOPS-43950) is folded into `/feature:design`:
Nexus 3.x permission model (roles, privileges, content selectors,
realms), automation-friendly identity options (Local users vs. NXRM
service-accounts vs. PRO tokens), and the parent/namespace permission
inheritance pattern are decided in `tech-design.md` rather than a
separate `research.md`.

## Cross-feature collisions

<!-- Populated by /feature:init and /feature:plan -->

- **DEVOPS-43146** (gitlab-automatic-project-and-sub-account) —
  severity: **low** (same repos: `connectors-extensions`,
  `connectors-operator`; different connector type: gitlab vs nexus;
  GitLab feature is at `regress` stage, near ship).
  **Status:** acknowledged at init (informational only; no shared paths
  expected). If `/feature:plan` finds file-level overlap, the planner
  will upgrade severity and require a sequencing decision.

## Definition of Done

- [ ] Research (profile=full only) — N/A (folded into design)
- [ ] Design + review (approved gate)
- [ ] POC (if offered)
- [ ] Plan (story groups created; per-story reviewers signed)
- [ ] Implement (all PRs merged, BDD green)
- [ ] Integrate (bundle tag recorded)
- [ ] QA (all p0 test cases pass)
- [ ] Accept (all ACs pass)
- [ ] Docs (release notes + doc index)
- [ ] Regress (regression suite passed against bundle)
- [ ] Security sign-off (risk=sensitive — required)
- [ ] Retrospective (or opt-out for light) — runs BEFORE ship
- [ ] Ship (Jira → Done, maturity report written, archive immediately,
  back-link on parent epic DEVOPS-43559)

## Artifacts

- [state.yaml](./state.yaml) — machine-readable state
- [handoff.md](./handoff.md) — driver pick-up snapshot
- [dependencies.md](./dependencies.md) — story dependency graph
- [product-design.md](./product-design.md)
- [tech-design.md](./tech-design.md)
- [threat-model.md](./threat-model.md) — risk=sensitive required
- [design-review.md](./design-review.md)
- [poc.md](./poc.md) — optional
- [qa-packet.md](./qa-packet.md)
- [qa-results.md](./qa-results.md)
- [acceptance.md](./acceptance.md)
- [release-notes.md](./release-notes.md)
- [docs-changes.md](./docs-changes.md)
- [regression.md](./regression.md)
- [security-sign-off.md](./security-sign-off.md) — risk=sensitive required
- [retrospective.md](./retrospective.md) — written before ship
- [maturity-report.md](./maturity-report.md) — written at ship

Post-release bugs against this feature attach to the parent epic's
`post-release-log.md` (DEVOPS-43559). This umbrella archives at ship
and is not re-opened.
