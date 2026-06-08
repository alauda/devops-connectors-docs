# Dependencies — SonarQube auto-create Project + Connector + Secret

<!--
Story-level dependency graph. Initialised by /feature:research, refined by
/feature:design from the task-breakdown's implied edges, re-validated at
/feature:plan when story groups become PR groups. The graph is the source of
truth for /feature:tracks.

Format: `<from-story-id> -> <to-story-id>   # rationale`
Cycles are rejected at /feature:design-review.
-->

## Stories

- **Story 1 — SonarQube auto-create Tekton Task + helper scripts + render
  tool** (slice: backend + infra). Tasks 1–9 in `tech-design.md §3`. Task
  template + rendered Task YAML, `hack/render-task.sh` render tool, seven
  helper scripts under
  `connectors-sonarqube/tektoncd/tasks/sonarqube-connector-automatic-creation/0.1/scripts/`:
  `lib`, `ensure-user`, `ensure-template`, `ensure-token`,
  `apply-kubernetes-resources`, `rollback`, `write-results`. Plus the
  `tektoncd/kustomization.yaml`. Repo: `connectors-extensions`.
- **Story 2 — BDD coverage** (slice: test). Tasks 10–12. `script.feature`,
  `tektoncd.feature`, BDD fixtures. Repo: `connectors-extensions`.
- **Story 3 — Docs** (slice: docs). Tasks 13–15. Concept + how-to + Web API
  reference pages. **Authored in `connectors-extensions`** under
  `connectors-sonarqube/docs/en/connectors/{concepts,how-to,reference}/`;
  **synced into `connectors-operator`** by Story 4's
  `hack/sync_sonarqube_connector_automatic_creation_task_doc.sh`. The
  OpenSpec change folder lives in `connectors-extensions` for review-surface
  alignment with the parent design-change (`implementation_repo:
  connectors-operator`).
- **Story 4 — Operator pipeline wiring** (slice: infra). Task 16.
  `sync_install_manifests.sh` entry, `make manifests` regenerates
  `cmd/kodata/connectors-sonarqube-tektoncd/...`, doc-sync helper +
  Makefile target. Repo: `connectors-operator`.

## Edges

```
Story 1 (Task + scripts) ──► Story 2 (BDD)
                          │
                          ├─► Story 3 (docs)
                          │
                          └─► Story 4 (operator wiring)
```

- **`Story 1 → Story 2`** — BDD scenarios exercise the actual Task + helper
  scripts; they require the Task YAML, scripts, and kustomize wiring in
  place.
- **`Story 1 → Story 3`** — soft dependency. Docs describe the Task contract
  (params/results/workspaces) and the SonarQube Web API surface, both fixed
  by the design; docs drafting can run in parallel, but the how-to TaskRun
  examples are verified end-to-end against the Story 2 BDD before docs
  sign-off.
- **`Story 1 → Story 4`** — operator pipeline wiring is meaningful only once
  `connectors-extensions` publishes a non-empty install manifest to Nexus.
  Story 4's one-line script edit can be drafted in parallel, but the
  `make manifests` validation requires Story 1's manifest on Nexus.

## Cycle check

No cycles. DAG with one source node (Story 1) and three sinks (Stories 2,
3, 4). Verified at `/feature:design-review` (approved 2026-05-22).

## Cross-feature dependencies

- **DEVOPS-43146** (GitLab auto-create) — shares both `connectors-operator`
  and `connectors-extensions` but targets a different connector type.
  Collision severity **low** / informational (re-checked at `/feature:plan`;
  feature is at `regress` stage, non-blocking). Its render-tool /
  Tekton-Task / Nexus-sync patterns ship in `main` and are **reused, not
  blocked on** (this feature 1:1 mirrors them).
- **DEVOPS-43145** (Harbor auto-create) — shipped; its Task + operator-sync
  patterns are available in `main` (additionally referenced for the
  `connector_address` ConnectorClass pattern that motivates assumption A8).
- No catalog PR — the Task reuses catalog-published alpine `kubectl` image
  by reference only.

## Per-PR group skeleton

OpenSpec change paths populated by `/feature:plan` on 2026-05-22 (1:1
mirror of DEVOPS-43146's plan shape):

- **Story 1 PR — `connectors-extensions`.** OpenSpec change:
  `openspec/changes/sonarqube-connector-automatic-creation-task/` (class:
  **design-change**; full pre-apply cycle — README, research, proposal,
  spec, design, tasks, bdd-scratch). Implementation paths under
  `connectors-sonarqube/tektoncd/tasks/sonarqube-connector-automatic-creation/0.1/`
  (template `task.template.yaml`, rendered `task.yaml`, `scripts/*.sh`,
  `samples/`), plus
  `connectors-sonarqube/tektoncd/kustomization.yaml` (new file),
  `connectors-sonarqube/hack/render-task.sh` (new, local render tool),
  and a `make render-tasks` Makefile target. **One additive
  `sonarqube` ConnectorClass entry** (`sonar-api` configuration —
  assumption A8) may be in-PR or deferred to a follow-up.

- **Story 2 PR — `connectors-extensions`.** OpenSpec change:
  `openspec/changes/sonarqube-connector-automatic-creation-task-bdd/`
  (class: **mechanical-followup**; parent_change = Story 1's change;
  tasks.md only). Implementation paths under
  `connectors-sonarqube/tektoncd/{testing,tasks/.../0.1/testing}/`.

- **Story 3 PR — `connectors-extensions` (`implementation_repo:
  connectors-operator`).** OpenSpec change:
  `openspec/changes/sonarqube-connector-automatic-creation-task-docs/`
  (class: **mechanical-followup**; parent_change = Story 1's change;
  tasks.md only). Implementation paths under
  `connectors-sonarqube/docs/en/connectors/{concepts,how-to,reference}/`
  in `connectors-extensions`; surfaced into `connectors-operator` via
  Story 4's `hack/sync_sonarqube_connector_automatic_creation_task_doc.sh`.

- **Story 4 PR — `connectors-operator`.** OpenSpec change:
  `openspec/changes/sonarqube-connector-automatic-creation-task-operator-wiring/`
  (class: **mechanical-followup**; parent_change is **cross-repo** —
  points at
  `../connectors-extensions/openspec/changes/sonarqube-connector-automatic-creation-task/`;
  tasks.md only). Implementation paths:
  `hack/sync_install_manifests.sh` (one-line addition),
  `cmd/kodata/connectors-sonarqube-tektoncd/1.0.0/install.yaml`
  (auto-generated by `make manifests` once Story 1's Nexus artifact exists),
  `hack/sync_sonarqube_connector_automatic_creation_task_doc.sh` (new),
  `Makefile` (new target). `values.yaml` stub is a strikethrough no-op
  (Story 1 reuses catalog images, no operator-managed image to pin —
  same pattern as GitLab Story 4).

Per-story PR draft state is tracked in `state.yaml.story_groups[]`;
reviewer sign-off recorded under `story_groups[].review`.
