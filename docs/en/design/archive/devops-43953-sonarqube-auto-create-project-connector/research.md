# Research — SonarQube auto-create Project + Connector + Secret

<!--
Written by /feature:research. Profile=full only. For profile=light|standard,
research is inlined as a `## Context` section in product-design.md.
-->

## Overview

DEVOPS-43953 adds automatic SonarQube project provisioning: given a Project /
namespace, create the SonarQube project via the Web API, mint project-scoped
credentials with the right permissions, and reconcile a `Connector` + `Secret`
into the target namespace — with error handling and rollback on partial
failure. The two reference features, GitLab auto-create (DEVOPS-43146, shipped)
and Harbor auto-create (DEVOPS-43145, shipped), both deliver this as a **Tekton
Task** authored in `connectors-extensions`, distributed through the operator's
install-manifest sync pipeline. SonarQube auto-create follows the same shape.
The connector itself (`connectors-sonarqube`) is today a proxy-only connector
with no provisioning capability and no Tekton tasks.

## Per-repo findings

### connectors

Not in `feature.repos` — no changes planned here. The Tekton Task consumes the
existing `connectors.alauda.io/v1alpha1.Connector` API and core `Secret`
objects as-is; no new core CRD types are needed. If design later finds the
core `Connector`/`ConnectorClass` contract must change, that is a scope change
requiring `/feature:promote` to add the repo.

### connectors-extensions

- `connectors-sonarqube/` today: a proxy-only connector. `ConnectorClass`
  exposes a single `tokenAuth` type, a `sonar-project.properties` config
  template, liveness probe `/api/system/status`, auth probe
  `/api/authentication/validate`, and a CSI-mounted credential workspace.
  **No `tektoncd/` directory, no project-creation capability.**
- GitLab reference pattern —
  `connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/`:
  source-of-truth `task.template.yaml` + `scripts/*.sh`, rendered into a
  committed `task.yaml` by `hack/render-task.sh` (~47 LOC POSIX shell) which
  inlines `{{ INCLUDE: scripts/<name>.sh }}` placeholders. `Makefile` targets
  `render-tasks`, `render-tasks-check` (CI staleness gate), `shellcheck-tasks`,
  all wired into `make lint`. Task = 4 idempotent steps (ensure-group,
  ensure-subgroups, ensure-gat, apply-kubernetes-resources) using an in-memory
  state volume and a tmpfs `0600` secrets volume; `set +x` around token ops.
- Harbor reference pattern —
  `connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/`:
  scripts baked into a **custom Containerfile image** (`images/harbor-cli/`)
  instead of inlined; monolithic Task YAML, no render tool, extra
  `build-*-image` Makefile target. Robot-account credential model.
- **Recommendation:** mirror GitLab's render-tool approach, not Harbor's custom
  image. SonarQube's Web API is plain REST — catalog `kubectl` + `curl`/`jq`
  images suffice, so no image build/push/scan cost.

### connectors-operator

- `ConnectorsSonarQube` CRD (`pkg/apis/v1alpha1/connectorssonarqube_types.go`)
  is a thin wrapper: Spec embeds only `component.ComponentSpec` (Labels,
  Annotations, Workloads); reconciliation is fully delegated to the generic
  `ConnectorsReconciler` + `InstallManifest`. **No CRD field or webhook changes
  are needed** — auto-create is a Tekton Task deliverable, not a controller
  change.
- Install-manifest machinery: `hack/sync_install_manifests.sh` pulls per-component
  manifests from Nexus into `cmd/kodata/<folder>/<version>/install.yaml`.
  `cmd/kodata/connectorssonarqube/1.0.0/install.yaml` holds the current
  `ConnectorClass` + `ResourceInterface`. GitLab's Task ships as a separate
  synced folder `cmd/kodata/connectors-gitlab-tektoncd/1.0.0/install.yaml`.
- GitLab "Story 4" operator-wiring pattern: one new line in
  `sync_install_manifests.sh`, a `values.yaml` image stub mirroring Harbor's
  `global.images.*` entries, a new `hack/sync_<feature>_task_doc.sh` doc-sync
  helper, and the committed auto-synced kodata manifest. The operator is a
  passive distribution hub — it pulls, it does not author the Task.

### connectors-plugin

Not in `feature.repos`. No console/UI surface is in scope — see the "no UI
story" entry under `## Stories`.

## SonarQube permission & account model

The prerequisite research ticket DEVOPS-43951 was **cancelled** — Daniel's
comment: "现在 feature flow 包含调研，不需要单独进行" (the feature flow now
includes research; no separate ticket needed). So this section *is* that
research. (DEVOPS-43951 also records that the work belongs to epic
**DEVOPS-43559** — see "Open question for the driver" below.)

### Account model — no robot/service account

Unlike Harbor (robot accounts) and GitLab (Group Access Tokens), SonarQube has
**no dedicated robot/service-account type**. Automation identity options:

- **Dedicated local technical user** — created via `api/users/create`
  (`local=true`), granted permissions, then issued tokens. Closest to a
  service account; the Task owns its lifecycle.
- **Pre-provisioned shared admin user** — one operator-owned account, reused
  across all projects. Simpler, larger blast radius.

### Token model — three types, project-scoped is the safe one

`api/user_tokens/generate` issues three token types (`api/user_tokens/revoke`
to revoke; tokens support an expiration):

- **User token** — every permission of the issuing user. Broadest.
- **Global Analysis token** — analyze *any* project; needs Global Execute
  Analysis permission.
- **Project Analysis token** — scoped to **one** project, analysis-only.
  Sonar explicitly recommends it: a leak only exposes that single project.

→ For the **namespace-project (restricted) `Connector`**, a **Project Analysis
token** is the right fit — minimal blast radius. The **parent-project
(shared) `Connector`** needs broader reach (shared quality gates/profiles) —
token type for it is a design decision (B3).

### Permission model — templates match by project-key regex

SonarQube splits **global** permissions (Administer System, Administer Quality
Gates/Profiles, Create Projects, Execute Analysis…) from **project**
permissions (Browse, See Source Code, Administer Issues/Hotspots, Administer
the project, Execute Analysis). A **permission template** declares the project
permissions granted to groups/users when a project is created; SonarQube picks
the template whose **project-key pattern (regex)** matches the new key — *if
several match, it raises an error* — else the default template.

→ "Restricted vs shared" is expressed by **project-key naming + per-pattern
templates**: namespace projects get a key matching a "restricted" template,
the shared/parent project matches a different template. APIs:
`api/permissions/create_template`, `api/permissions/apply_template`,
`api/permissions/add_user|add_group`.

⚠️ Caveat: a user with **instance-level Execute Analysis** can scan *any*
project regardless of project permissions — so do not lean on global Execute
Analysis; use project-scoped tokens. ⚠️ If the target SonarQube uses
GitHub/GitLab/SCIM auto-provisioning, project permissions of auto-provisioned
users **cannot be changed via API** — our automation would conflict (B5).

### "Parent project" is not a SonarQube primitive

SonarQube core has **no project hierarchy**. Quality gates and quality
profiles are global objects assigned per-project (`api/qualitygates/select`,
`api/qualityprofiles/add_project`); a new project just inherits the *default*
gate/profile. AC-3 ("parent project has access to shared base quality
gates/profiles") therefore needs a product definition (B3): most likely a
designated parent SonarQube project plus explicit shared-gate/profile
assignment onto each namespace project — not an inheritance mechanism.
(Enterprise edition's Portfolios/Applications could model the grouping, but
that depends on the target edition — B1.)

### Rollback is feasible

Partial-failure rollback is API-supported: `api/projects/delete`,
`api/user_tokens/revoke`, `api/permissions/remove_template`. The Task tracks
what it created (state volume) and unwinds in reverse on failure.

## Block points (for /feature:design)

Items B1/B2/B3/B5 need a driver/product answer before `/feature:design` can
fully settle Story 1; B4/B6 are design-task items.

- **B1 — SonarQube edition + version unknown.** Project Analysis tokens need
  9.5+; Portfolios need Enterprise; permission templates exist everywhere. The
  connectors-sonarqube repo only pins the *scanner* image (`v7.0.2`), not the
  server. → Confirm the target SonarQube edition/version. Blocks the token
  strategy for Story 1.
- **B2 — account strategy.** Dedicated technical user (Task-managed lifecycle)
  vs pre-provisioned shared admin user. → Product/design decision.
- **B3 — "parent vs namespace" definition.** What parent/shared concretely
  means in SonarQube terms (separate projects + shared gate/profile assignment
  + key-pattern templates, vs Portfolios). → Product decision; gates AC-3/AC-4.
- **B4 — bootstrap credential is high-privilege.** Creating projects, users,
  tokens and permission templates needs Administer System (or a carefully
  assembled global-permission set). This is the reason `risk=sensitive`; the
  threat model must cover its storage and blast radius.
- **B5 — auto-provisioning conflict.** If the instance auto-provisions users
  via GitHub/GitLab/SCIM, API-driven project-permission changes are rejected.
  → Confirm the target instance's provisioning mode.
- **B6 — project-key naming scheme.** Namespace/parent key naming must be
  designed so exactly one permission template matches each project (multiple
  matches → SonarQube error). → Design task within Story 1.

Other (non-blocking) notes: SonarQube project tokens do **not** rotate in
place — identity change forces revoke + mint (simpler than GitLab's 3-path
`ensure-gat.sh`); identity must be tracked via token name or a `Secret`
annotation. `values.yaml` automation (`update_image_tags.sh`) will not insert
an unknown component entry — the `sonarqube-connector-automatic-creation` stub
may need pre-seeding. Operator wiring (Story 4) cannot pull a real manifest
until the Task is published to Nexus from `connectors-extensions`.

## SonarQube permission model reference

A consolidated reference for the design's authorization model. SonarQube
exposes **two distinct permission classes**, plus a third construct
(permission templates) that bridges into project-level permissions.

### Global permissions (instance-wide; not templated)

Set via Administration → Security → **Global Permissions**, or via API
`api/permissions/add_user|add_group|remove_user|remove_group` **without** a
`templateName`. Granted to specific users or groups; affect the whole
instance. There is exactly one Global Permissions configuration per instance
— it is **not** a template, and cannot be duplicated.

| API name | UI label | What it grants |
|---|---|---|
| `admin` | Administer System | Full system administration (highest). |
| `provisioning` | Create Projects | Create new projects on the instance. |
| `scan` | Execute Analysis | Analyze **any** project on the instance — bypasses project permissions. **Isolation-breaker.** |
| `gateadmin` | Administer Quality Gates | Manage quality gates. |
| `profileadmin` | Administer Quality Profiles | Manage quality profiles. |
| `applicationcreator` | Create Applications | Enterprise only. |
| `portfoliocreator` | Create Portfolios | Enterprise only. |

### Project-level permissions (per-project; can be templated)

Granted per-project via Administration → Project Settings, or via API
`api/permissions/add_user|add_group` **with** `projectKey`, or via a
**permission template** that auto-applies these permissions to projects
whose key matches the template's `projectKeyPattern`.

| API name | UI label | What it grants |
|---|---|---|
| `user` | Browse | View the project; read measures via API. |
| `codeviewer` | See Source Code | Read source-code snippets shown in issues. |
| `issueadmin` | Administer Issues | Triage issue status (confirm / false-positive / resolve / won't-fix). |
| `securityhotspotadmin` | Administer Security Hotspots | Triage security hotspot status. |
| `admin` | Administer | Project administrator — change project permissions, visibility, delete the project. **Dangerous to grant to tenant users.** |
| `scan` | Execute Analysis | Analyze this specific project. |

### Permission templates

Multiple per instance. Each template has a name, an optional
`projectKeyPattern` (regex), and a set of grants to users *and/or* groups
using the six project-level permissions above. Created via
`api/permissions/create_template`; grants via `add_user_to_template` /
`add_group_to_template`. Applied to existing projects via `apply_template`.

**Auto-apply at project creation.** When a project is created (by API, UI,
or first-scan auto-provisioning), SonarQube picks the matching template by
`projectKeyPattern` and applies its grants to the new project. If multiple
templates match, SonarQube **errors**; if none match, the **default
template** (set via `set_default_template`) applies.

Template grants can target users *and* groups in the same template — the
choice is operational. Use groups when many subjects share the same role;
use users directly when the model is 1:1 (like one bot per tenant, which
is this design — POC item 11 verified the user-direct variant works end
to end).

### The `scan` API-name collision

`scan` is the same API key at both layers but has very different scope:

- **Global `scan`** — analyze **any** project on the instance, regardless
  of project-level permissions. Granting this to broad groups (including
  the `sonar-users` default group) **breaks cross-tenant isolation**.
- **Project-level `scan` (via a template)** — analyze only the projects
  whose key matches the template's `projectKeyPattern`. This is the
  authorization a tenant scanner pipeline actually needs.

### The `sonar-users` default group — special and unavoidable

SonarQube auto-adds **every** user (UI or `api/users/create`) to the default
group `sonar-users`. Members **cannot be removed** —
`api/user_groups/remove_user` returns `400 Default group cannot be used`.
Consequence: a user's effective permissions are always
`(direct grants on user) ∪ (template grants matching the project's key) ∪
(sonar-users grants)`. For tenant-scoped tokens to remain scoped,
`sonar-users` must hold **no** global permissions — this is a documented
deployment prerequisite of this design.

### Auto-creation-on-scan requires global `provisioning` (POC-verified)

For a user to auto-create a project on first scan (when the project key
doesn't exist), the user must hold the **global `provisioning`** permission
— project-level `scan` granted via a template is **not** sufficient. POC
clean re-test (with `sonar-users` stripped of global permissions): template
granting only project-level `scan` → scan fails with "you're not authorized
to create it"; granting the user direct global `provisioning` → scan
succeeds and the project is auto-created. (See `poc.md` items 10 + 11.)

### Implications for this design (Branch 3, per-tenant)

- The tenant user receives **exactly one** global permission, granted
  directly: `provisioning` (Create Projects). No other globals.
- The tenant template grants project-level permissions to the user
  **directly** (via `add_user_to_template`) — no intermediate group is
  required, because the model is one user per tenant.
- Recommended template grants: `user` + `codeviewer` + `issueadmin` +
  `securityhotspotadmin` + `scan`. **Never `admin`** (would let the tenant
  modify its own project permissions and break isolation).
- Three deployment prerequisites depend on this model: (a) instance default
  project visibility = `private`; (b) `sonar-users` stripped of all global
  permissions; (c) instance default quality gate / profile configured as
  the shared baseline.

## References

- [DEVOPS-43953 (this feature)](https://jira.alauda.cn/browse/DEVOPS-43953)
- [DEVOPS-43951 — SonarQube permission-model research (**cancelled**; folded into this feature flow)](https://jira.alauda.cn/browse/DEVOPS-43951)
- [DEVOPS-43559 — parent epic of DEVOPS-43951 (see open question below)](https://jira.alauda.cn/browse/DEVOPS-43559)
- [DEVOPS-43145 — Harbor auto-create (reference)](https://jira.alauda.cn/browse/DEVOPS-43145)
- [DEVOPS-43146 umbrella — GitLab auto-create (reference pattern)](../devops-43146-gitlab-automatic-project-and-sub-account/)
- `connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/` — render-tool Task pattern
- `connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/` — custom-image Task pattern
- `connectors-operator` `hack/sync_install_manifests.sh`, `values.yaml` — operator distribution machinery
- [SonarQube — Managing permissions](https://docs.sonarsource.com/sonarqube-server/instance-administration/user-management/user-permissions)
- [SonarQube — Setting project permissions / permission templates](https://docs.sonarsource.com/sonarqube-server/project-administration/setting-project-permissions)
- [SonarQube — Managing your tokens (user / global-analysis / project-analysis)](https://docs.sonarsource.com/sonarqube-server/user-guide/managing-tokens)

## Driver decision — epic linkage

DEVOPS-43951's description states it is prerequisite research for **epic
DEVOPS-43559**. DEVOPS-43953 (this feature) was started standalone via
`/feature:init` with `parent_epic: null`.

**Decision (driver, 2026-05-21, at research close): re-link DEVOPS-43953 to
epic DEVOPS-43559.**

This is a structural change outside `/feature:research`'s scope and was **not**
applied at research close — `state.yaml.feature.parent_epic` is still `null`.
No epic umbrella exists for DEVOPS-43559 yet (`docs/en/design/epics/` is
empty). Re-link path — **pending action**:

1. `/feature:epic-init DEVOPS-43559 --profile=full` — scaffold the epic
   umbrella under `docs/en/design/epics/devops-43559-<slug>/`.
2. Set `state.yaml.feature.parent_epic: DEVOPS-43559` on this umbrella and
   register DEVOPS-43953 on the epic's story list.

Practical deadline: before `/feature:ship` (ship writes a back-link on the
parent epic, and `/feature:bug-link` attaches post-release bugs to it). It
does **not** block `/feature:design`.

## Stories

<!-- Required for profile=full -->

1. **SonarQube auto-create Tekton Task + helper scripts + render tool** (p0, slice=backend, repos=[connectors-extensions])
   Author `connectors-sonarqube/tektoncd/tasks/sonarqube-connector-automatic-creation/0.1/` mirroring the GitLab render-tool pattern: `task.template.yaml` + `scripts/*.sh` (ensure-project, ensure-permissions, ensure-token, apply-kubernetes-resources), `hack/render-task.sh`, and `Makefile` render/render-check/shellcheck targets wired into `make lint`. Idempotent steps; in-memory state volume; tmpfs `0600` secrets volume. Creates the SonarQube project (parent/shared vs namespace/restricted scope), binds permissions, mints a project-scoped token, and server-side-applies the tenant `Connector` + `Secret`. Handles API errors / permission conflicts and rolls back partial state (revoke token if `Secret` apply fails).
   Depends on: none.
   ACs: 1, 2, 3, 4, 5, 6, 7.

2. **BDD coverage for the SonarQube auto-create Task** (p0, slice=test, repos=[connectors-extensions])
   zh-CN Gherkin feature(s) + godog runner + CEL resource-check tables covering multi-level hierarchy scenarios: parent-project creation + shared quality-gate access, namespace-project creation + restricted access, token expiry / revoke-and-mint, permission-template binding failure, and partial-failure rollback. Mirrors the GitLab BDD shape (`tektoncd.feature` + `script.feature`).
   Depends on: 1 (Task contract must exist).
   ACs: 8.

3. **Documentation — SonarQube auto-create concept, how-to and API examples** (p0, slice=docs, repos=[connectors-operator])
   Concept page + how-to with TaskRun examples for both scopes + reference page documenting the SonarQube Web API calls the Task makes, under `docs/en/connectors-sonarqube/`. Plus an operations runbook section (token-already-expired, permission-conflict, offboarding).
   Depends on: 1 (documents the shipped Task contract).
   ACs: 9.

4. **Operator pipeline wiring for the SonarQube Task manifest** (p0, slice=infra, repos=[connectors-operator])
   Add a `sync_install_manifests.sh` entry for `connectors-sonarqube-tektoncd`, a `values.yaml` image stub under `global.images.sonarqube-connector-automatic-creation` (mirroring Harbor), a `hack/sync_sonarqube_connector_automatic_creation_task_doc.sh` doc-sync helper, and commit the auto-synced `cmd/kodata/connectors-sonarqube-tektoncd/1.0.0/install.yaml` once the Nexus artifact exists.
   Depends on: 1 (the Task must be published before the operator can pull it).
   ACs: none directly — enabling/distribution work that makes ACs 1-9 reachable on the operator bundle.

<!--
No UI story — explicit waiver. The feature ships a Tekton Task invoked via a
TaskRun inside a provisioning pipeline; it adds no CRD field, no connectors-plugin
console form/card/detail screen, and no user-facing operator surface. The
connectors-plugin repo is intentionally out of feature.repos. The analogue
DEVOPS-43146 (GitLab auto-create) shipped with no UI story for the same reason.
-->
