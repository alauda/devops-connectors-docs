# Feature: Gitlab automatic project and sub-account support using API and CLI

<!--
This file is the human-readable index of the umbrella. state.yaml is the
machine-readable source of truth. Both are written by /feature:* commands;
manual edits to state.yaml are detected by integrity hash.
-->

- **Jira:** DEVOPS-43146 — [link](https://jira.alauda.cn/browse/DEVOPS-43146)
- **Parent epic:** DEVOPS-42609 (linked via Epic Link; this umbrella is a *standalone* feature, not branched from an epic umbrella)
- **Reporter:** Daniel Morinigo (daniel)
- **Assignee:** Daniel Morinigo (daniel)
- **Blocks:** is blocked by DEVOPS-43147 (Done — research) and DEVOPS-43148 (Cancelled — superseded design)
- **Fix version:** connectors-operator-v1.11.0

## Classification

- **Profile:** standard  (light | standard | full)
- **Risk:** sensitive  (low | standard | sensitive) — driver override; see `security.override` in state.yaml
- **Repos affected:** connectors-extensions, connectors-operator (pipeline wiring only — `hack/sync_install_manifests.sh` + `values.yaml` stub; `cmd/kodata/` is still auto-synced)
- **Effort (advisory):** _unset_
- **Driver:** daniel

## Summary

Ship a Tekton Task `gitlab-connector-automatic-creation/0.1` under
`connectors-extensions/connectors-gitlab/tektoncd/tasks/` that, given
one admin GitLab Connector, reconciles a tenant's GitLab group
(`tenantGroup`) and any optional per-team `subgroups` under it,
provisions a bot-backed Group Access Token at the tenant group, and
materialises the cluster-side tenant `gitlab` Connector + auth Secret
(class `connectors.cpaas.io/gitlab-pat-auth`) in a single idempotent
TaskRun. Mirrors the shipped Harbor equivalent (DEVOPS-43145 / PR
AlaudaDevops/connectors-extensions#215). Token refresh follows Harbor's
two-path pattern: rotate-in-place when inputs are unchanged, delete +
recreate when identity-affecting inputs change.

The Task is **deployment-pattern-agnostic**: the admin Connector may
hold either a user PAT (for an account with `can_create_group` —
recommended for greenfield where each ACP project becomes a top-level
GitLab group) or an umbrella group's GAT (for orgs that centralise
tenants under an umbrella; the Task then creates the tenant group as a
subgroup of the umbrella). Both patterns share the same Task
contract — the only difference is the admin identity type and the
shape of `tenantGroup`.

The Task **reuses the catalog-shipped `glab` image**
(`registry.alauda.cn:60070/devops/tektoncd/hub/glab` — registered as
the `catalog.tekton.dev/tool-image-glab` ConfigMap by the catalog
repo) for GitLab API steps, and the catalog `kubectl` image for the
cluster-apply step. No new tool image is built in scope. Helper
scripts live entirely inside connectors-extensions at
`connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/scripts/`
and are inlined into each step's `script:` block at build time by a
local render tool (`hack/render-task.sh` — a small ≤50 LOC script
owned by connectors-extensions). No catalog `tasklib` dependency,
no runtime init step, no `images/gitlab-cli/` directory.

The ConnectorClass CLI-config side already ships in GitLab today via
`gitlabconfig` + `gitconfig`, so this ticket covers the Task only and
does not require a ConnectorClass change.

## Cross-feature collisions

None detected — no other in-flight feature umbrellas (no `state.yaml`
files outside templates/) currently exist on `connectors-extensions`.

**Related (informational, not collisions):** the pre-feature-workflow
design directory `docs/en/design/connectors-auto-project/` already
contains the Harbor reference design notes (`harbor.task-1.design.md`,
`harbor.task-2.design.md`, `tech-design.md`) and is the canonical place
to extend the design notes for the GitLab variant. Decide at
`/feature:design` whether to extend those files in place or root the
GitLab design under this umbrella.

## Definition of Done

- [ ] Research (profile=full only — _skipped_ at standard)
- [ ] Design + review (approved gate)
- [ ] POC (if offered)
- [ ] Plan (story groups created; per-story reviewers signed)
- [ ] Implement (all PRs merged, BDD green)
- [ ] Integrate (bundle tag recorded)
- [ ] QA (all p0 test cases pass)
- [ ] Accept (all ACs pass — 11 ACs from Jira)
- [ ] Docs (release notes + concept page for `glab` CLI mount + how-to page with TaskRun example, admin-scope prereqs, token-refresh cron pattern, manual cross-group-permissions workaround)
- [ ] Regress (regression suite passed against bundle)
- [ ] Security sign-off (risk=sensitive — REQUIRED before ship)
- [ ] Retrospective (runs BEFORE ship)
- [ ] Ship (Jira → Done, maturity report written, archive immediately, back-link on parent epic DEVOPS-42609)

## Acceptance criteria (from Jira, adapted to the two-pattern shape)

1. The tenant group at `tenantGroup` is created or reused automatically via the admin Connector, in a single TaskRun. If `tenantGroup` is a top-level path (no `/`), the admin Connector must be a user PAT belonging to an account with `can_create_group`; if it is a subgroup path, the admin Connector must hold `owner` on the parent (either a user PAT for that user or a GAT at the parent). Optional per-team `subgroups` are created under the tenant group; missing subgroups are created idempotently.
2. A Group Access Token is provisioned at `tenantGroup` with the requested `access_level` and `scopes`.
3. Token refresh mirrors Harbor's two-path flow: scope/access-level/subgroup-set unchanged → the Task rotates the secret in place (GitLab `POST /groups/:id/access_tokens/:token_id/rotate`); any identity-affecting input change → the Task deletes and recreates the token cleanly.
4. Cluster outputs land correctly: tenant `gitlab` Connector + its auth Secret (`connectors.cpaas.io/gitlab-pat-auth`) in the connector namespace.
5. Admin credentials are consumed only via the `gitlabconfig` CSI mount (connectors proxy path); the raw admin PAT/GAT is never embedded in the Pod spec or the tenant Secret.
6. Idempotency: rerun with unchanged inputs is a rotate (non-destructive); changing the subgroup set, access level, or scopes triggers a controlled recreate.
7. Error handling: surfaces actionable messages for the four prerequisite mismatch cases — admin lacks `can_create_group` while creating a top-level tenant group; admin lacks `owner` on the parent path; tenant group path conflict (existing path under a different owner); GitLab max-expiry rejections — plus token-quota exhaustion. The Task fails fast on the first prerequisite mismatch. If a later step fails (e.g. the GAT mint at `tenantGroup`) after an earlier step already created a group or subgroup, the partial GitLab state is **not** rolled back transactionally; instead, every step is idempotent so a rerun after fixing the admin Connector reuses the existing group rather than creating a duplicate. This idempotent-rerun semantics is the documented recovery path.
8. Task results populated: `tenant-group`, `subgroups` (array), `access-token-name`, `connector-ref`.
9. Integration tests cover: fresh creation (Pattern A — top-level + can_create_group user, and Pattern B — subgroup of umbrella + GAT), idempotent re-run (rotate-in-place path), add-subgroup reconcile, scope/access-level change (recreate path), invalid params, prerequisite-mismatch errors — mirrors the Harbor feature-file layout.
10. Documentation: concept page covers the `glab` CLI configuration mount and the two deployment patterns; how-to page covers the full Tekton Task with both pattern A and pattern B end-to-end TaskRun examples, the admin-permission prerequisites, the token-refresh cron pattern, and the manual cross-group-permissions workaround.
11. Runs as non-root UID 65532 on linux/amd64 and linux/arm64, with cpu/memory requests + limits on every step and an in-memory `emptyDir` for the script + token hand-off — matches the Harbor Task posture.

> **Image-pull Secrets — REMOVED from scope** (was AC-4 trailing
> clause + a dedicated param/result). Any tenant that needs registry
> image-pull Secrets generated from the tenant GAT can do so as a
> follow-up Task or a separate manual step; that surface is
> intentionally not in this slice.

## Out of scope

- **Image-pull Secrets generated from the tenant GAT.** Removed from
  this slice per design-review. The tenant GAT is what a follow-up
  Task or a manual step would use to mint per-namespace image-pull
  Secrets if and when that demand surfaces.
- **Instance-admin admin Connector.** The Task does not require — and
  the docs explicitly do **not** recommend — using a root/instance-admin
  PAT in the admin Connector. Pattern A's `can_create_group` user is
  the recommended top-level-group flow; Pattern B's umbrella GAT is
  the recommended subgroup-only flow. Listed here so the next driver
  does not re-introduce the instance-admin path without an explicit
  decision.
- **Pre-creating the `can_create_group` user (Pattern A).** Setting up
  the dedicated user, enabling its `can_create_group` flag, and
  generating its PAT is operator deployment hardening (covered in
  the how-to page) rather than a Task-time concern. The Task fails
  cleanly if the admin Connector's PAT lacks the required permission;
  it does not provision the user.
- Project-level (single-repo) access tokens as the primary mode (deferred follow-up).
- Per-group access level on one token (option A — service-account user + PAT + per-group Membership). Manual workaround documented in the proposal comment and the how-to page.
- Creating human user accounts or GitLab-side invitations.
- ConnectorClass changes (`gitlabconfig` and `gitconfig` already ship).
- **Authoring a new `gitlab-cli` tool image.** The catalog repo
  already ships a `glab` image (registered as the
  `catalog.tekton.dev/tool-image-glab` ConfigMap); this Task reuses
  that image. The existing generic `gitlab-cli` catalog Task is
  **reused, not deprecated** — both Tasks share the underlying image
  through the same tool-image ConfigMap.
- Editing operator `cmd/kodata/...` content. The kodata install
  manifest is auto-synced from Nexus by `make manifests`. Pipeline
  wiring (one-line `sync_install_manifests.sh` entry + a
  `values.yaml` stub) is in scope and lands in this repo.

## Workspaces

- **Operator umbrella (this repo):** `/workspaces/daniel-pod/github/alaudadevops/connectors-operator-pilot-43146/` — feature-workflow umbrella, design docs, integration plan, plus the pipeline-wiring touch (`hack/sync_install_manifests.sh` + `values.yaml` stub).
- **connectors-extensions worktree:** `/workspaces/daniel-pod/github/alaudadevops/connectors-extensions-pilot-43146/` on branch `pilot/DEVOPS-43146` (tracks `origin/main`) — Tekton Task implementation + BDD features under `connectors-gitlab/tektoncd/`.
- **catalog (read-only — image references):** `/workspaces/daniel-pod/github/alaudadevops/catalog/` — already ships the `glab` and `kubectl` images. The Task references the published images via `glabImage`/`kubectlImage` param defaults pointing at the existing tool-image ConfigMaps; no new files are added to catalog. Helper scripts for this Task live in connectors-extensions, not in catalog `tasklib/scripts/`.

## Artifacts

- [state.yaml](./state.yaml) — machine-readable state
- [handoff.md](./handoff.md) — driver pick-up snapshot
- [dependencies.md](./dependencies.md) — story dependency graph (populated at `/feature:plan`)
- [product-design.md](./product-design.md) — written at `/feature:design`
- [tech-design.md](./tech-design.md) — written at `/feature:design`
- [threat-model.md](./threat-model.md) — risk=sensitive: REQUIRED at design
- [design-review.md](./design-review.md)
- [poc.md](./poc.md) — optional
- [qa-packet.md](./qa-packet.md)
- [qa-results.md](./qa-results.md)
- [acceptance.md](./acceptance.md)
- [release-notes.md](./release-notes.md)
- [docs-changes.md](./docs-changes.md)
- [regression.md](./regression.md)
- [security-sign-off.md](./security-sign-off.md) — risk=sensitive: REQUIRED before ship
- [retrospective.md](./retrospective.md) — written before ship
- [maturity-report.md](./maturity-report.md) — written at ship

Post-release bugs against this feature attach to the parent epic
DEVOPS-42609. This umbrella archives at ship and is not re-opened.

## Reference implementations

- DEVOPS-43145 — Harbor `harbor-connector-automatic-creation` Task (the spec-mirror for this feature).
- PR AlaudaDevops/connectors-extensions#215 — Harbor Task implementation.
- PR AlaudaDevops/connectors-extensions#222 — Harbor CLI config.
- DEVOPS-43722 — Harbor ConnectorClass `harbor-cli` config (the GitLab analogue already shipped via `gitlabconfig`).
