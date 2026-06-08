# Feature: SonarQube auto-create Project + Connector + Secret

<!--
This file is the human-readable index of the umbrella. state.yaml is the
machine-readable source of truth. Both are written by /feature:* commands;
manual edits to state.yaml are detected by integrity hash.
-->

- **Jira:** DEVOPS-43953 — [link](https://jira.alauda.cn/browse/DEVOPS-43953)
- **Parent epic:** (none — standalone feature)
- **Reporter:** DevOps Bot
- **Assignee:** Kaiyong Chen (kychen)
- **Blocks:** (none)
- **Blocked by:** DEVOPS-43951 (SonarQube permission-model / account-system research)

## Classification

- **Profile:** full  (light | standard | full)
- **Risk:** sensitive  (low | standard | sensitive)
- **Repos affected:** connectors-extensions, connectors-operator
- **Effort (advisory):** (not set)  (hours | days | weeks | months)
- **Driver:** kychen

## Summary

Implement automatic SonarQube project creation and credential management with
fine-grained permissions. As a platform engineer, I want SonarQube projects and
their corresponding `Connector` + `Secret` provisioned automatically with the
right permissions, so teams get isolated code-quality scanning within the
project hierarchy without manual setup. The work integrates with the SonarQube
Web API for project / permission-template / user / token creation, uses a
robot/service-account or scoped user-token model (per the research conclusion
of DEVOPS-43951), supports parent-project (shared) and namespace-project
(restricted) scopes, and handles permission-template binding plus rollback on
partial failure. DEVOPS-43145 (Harbor auto-create) is the reference for the
permission / idempotency / rollback model.

### Acceptance Criteria (from Jira)

- [ ] SonarQube project can be created automatically via API for a given Project / namespace
- [ ] Project-scoped tokens / credentials are created with project-specific permissions
- [ ] Parent project has access to shared resources (base quality gates / profiles)
- [ ] Namespace projects have restricted access to their own SonarQube projects
- [ ] Connector + Secret reconciled into the right namespace as part of provisioning
- [ ] Error handling for API failures and permission conflicts
- [ ] Rollback mechanism for failed project / token creation
- [ ] Integration tests cover multi-level hierarchy scenarios
- [ ] Documentation includes SonarQube API usage and examples

## Cross-feature collisions

<!-- Populated by /feature:init and /feature:plan -->

- **DEVOPS-43146** (GitLab automatic project & sub-account) — severity **low**
  / informational. Shares both `connectors-operator` and `connectors-extensions`
  but targets a different connector type (gitlab vs sonarqube). In-flight at the
  `regress` stage. Non-blocking; no acknowledgment required.

## Definition of Done

- [ ] Research (profile=full only)
- [ ] Design + review (approved gate)
- [ ] POC (if offered)
- [ ] Plan (story groups created; per-story reviewers signed)
- [ ] Implement (all PRs merged, BDD green)
- [ ] Integrate (bundle tag recorded)
- [ ] QA (all p0 test cases pass)
- [ ] Accept (all ACs pass)
- [ ] Docs (release notes + doc index)
- [ ] Regress (regression suite passed against bundle)
- [ ] Security sign-off (risk=sensitive only)
- [ ] Retrospective (or opt-out for light) — runs BEFORE ship
- [ ] Ship (Jira → Done, maturity report written, archive immediately,
  back-link on parent epic if any)

## Artifacts

- [state.yaml](./state.yaml) — machine-readable state
- [handoff.md](./handoff.md) — driver pick-up snapshot
- [dependencies.md](./dependencies.md) — story dependency graph
- [research.md](./research.md) — profile=full only
- [product-design.md](./product-design.md)
- [tech-design.md](./tech-design.md)
- [threat-model.md](./threat-model.md) — risk=sensitive only
- [ui-prototype.drawio](./ui-prototype.drawio) — when any story has slice=ui
- [design-review.md](./design-review.md)
- [poc.md](./poc.md) — optional
- [qa-packet.md](./qa-packet.md)
- [qa-results.md](./qa-results.md)
- [acceptance.md](./acceptance.md)
- [release-notes.md](./release-notes.md)
- [docs-changes.md](./docs-changes.md)
- [regression.md](./regression.md)
- [security-sign-off.md](./security-sign-off.md) — risk=sensitive only
- [retrospective.md](./retrospective.md) — written before ship
- [maturity-report.md](./maturity-report.md) — written at ship

Post-release bugs against this feature attach to the parent epic's
`post-release-log.md` (see `parent_epic` field above). This umbrella
archives at ship and is not re-opened.
