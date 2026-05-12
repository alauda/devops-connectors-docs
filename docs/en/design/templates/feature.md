# Feature: {{title}}

<!--
This file is the human-readable index of the umbrella. state.yaml is the
machine-readable source of truth. Both are written by /feature:* commands;
manual edits to state.yaml are detected by integrity hash.
-->

- **Jira:** {{jira_id}} — [link]({{jira_url}})
- **Parent epic:** {{parent_epic_jira_id or "(none — standalone feature)"}}
- **Reporter:** {{reporter}}
- **Assignee:** {{assignee}}
- **Blocks:** {{blocks}}

## Classification

- **Profile:** {{profile}}  (light | standard | full)
- **Risk:** {{risk}}  (low | standard | sensitive)
- **Repos affected:** {{repos_list}}
- **Effort (advisory):** {{effort}}  (hours | days | weeks | months)
- **Driver:** {{driver}}

## Summary

{{one-paragraph summary of the feature, drawn from the Jira description or the driver's brief}}

## Cross-feature collisions

<!-- Populated by /feature:init and /feature:plan -->

{{list of colliding in-flight features with severity and acknowledgment status}}

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
