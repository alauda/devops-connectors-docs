# Tech Design — Gitlab automatic project and sub-account support using API and CLI

<!--
Written by /feature:design. Mirrors the Goal from product-design.md; adds
architecture, task breakdown, and test design.
-->

## Goal

Give platform engineers a single Tekton TaskRun that, against one admin
GitLab Connector, reconciles a tenant's GitLab group (`tenantGroup`)
and any optional per-team `subgroups` under it, provisions a bot-backed
Group Access Token at the tenant group, and lands the cluster-side
tenant `gitlab` Connector + auth Secret — idempotent on re-run,
rotates the token in place when inputs are unchanged, and
deletes-and-recreates only when an identity-affecting input changes.
The Task is deployment-pattern-agnostic: the admin Connector may hold
either a user PAT (Pattern A — `can_create_group` user, recommended
for top-level tenant groups) or an umbrella group's GAT (Pattern B —
recommended for subgroup-of-umbrella tenants). Out of scope:
image-pull Secret materialisation, project-level (single-repo) tokens
as the primary mode, per-group access-level on one token, human user
creation, ConnectorClass changes, recommending instance-admin admin
Connectors.

## Architecture

### Components touched

- **connectors-extensions/connectors-gitlab** — new subtree
  `tektoncd/tasks/gitlab-connector-automatic-creation/0.1/` containing:
  - `gitlab-connector-automatic-creation.template.yaml` — source-of-truth
    Task template with `{{ INCLUDE: scripts/<name>.sh }}` placeholders.
  - `gitlab-connector-automatic-creation.yaml` — rendered, shippable
    Task (committed; CI verifies it matches `make render-tasks` output).
  - `scripts/{lib,ensure-tenant-group,ensure-gat,apply-kubernetes-resources,write-results}.sh`
    — source helper scripts as plain `.sh` files (reviewable, lint-able,
    shellcheck-able).
  - `samples/` — sample TaskRuns covering Pattern A and Pattern B.
  - `testing/` — BDD features and fixtures.
  Plus new `tektoncd/kustomization.yaml`, new `hack/render-task.sh`
  (≤50 LOC; reads the template, inlines each referenced script body
  into the matching step's `script: |` block via placeholder
  substitution, emits the shippable Task YAML), and new docs under
  `docs/en/connectors/{concepts,how-to}/`. **No new Containerfile.**
  **No new tool-image ConfigMap.** **No `images/gitlab-cli/` directory.**
- **catalog (alaudadevops/catalog)** — **NOT TOUCHED.** The Task
  reuses the catalog-published `glab` and `kubectl` tool images via
  `glabImage` and `kubectlImage` param defaults pointing at the
  existing `catalog.tekton.dev/tool-image-glab` and
  `catalog.tekton.dev/tool-image-kubectl` ConfigMaps in `kube-public`.
  No new files added to catalog; no entries added to catalog
  `tasklib/scripts/`. The render contract lives entirely in
  connectors-extensions so the Task ships from a single repo.
- **connectors-extensions/connectors-gitlab** (existing, untouched) —
  `config/connectorclass/connectorclass.yaml` already exposes
  `gitlabconfig` and `gitconfig`; the new Task consumes them.
- **connectors** — no change. The proxy and CSI driver are reused as-is.
- **connectors-operator (this repo)** — pipeline wiring only:
  - `hack/sync_install_manifests.sh` — add one entry:
    `sync_install_manifests "connectors-gitlab-tektoncd" "connectors-gitlab-tektoncd"`.
  - `values.yaml` — add a stub entry under
    `global.images.gitlab-connector-automatic-creation` (parallel to
    Harbor's existing entry); `update_image_tags.sh` looks up
    components by repository and refuses to insert new entries.
  - `hack/sync_gitlab_connector_automatic_creation_task_doc.sh` — new
    helper script mirroring Harbor's `sync_harbor_..._doc.sh` (Story 4).
  - `cmd/kodata/connectors-gitlab-tektoncd/...` — auto-synced from
    Nexus once the two changes above are in place. CLAUDE.md's
    "NEVER edit `cmd/kodata/`" rule still holds.
- **connectors-plugin** — no change. No UI surface in this slice.

### Call paths

- Build time: `make render-tasks` → `hack/render-task.sh` reads
  `gitlab-connector-automatic-creation.template.yaml`, inlines each
  `{{ INCLUDE: scripts/<name>.sh }}` placeholder with the matching
  source file's body, and writes the shippable
  `gitlab-connector-automatic-creation.yaml`. Each step's `script: |`
  block in the rendered Task is fully self-contained — no init step,
  no base64, no emptyDir-based script materialisation at runtime.
- Platform engineer → `kubectl create -f taskrun.yaml` → Tekton
  TaskRun → step 0 `ensure-gitlab` (catalog `glab` image) → glab via
  connectors-proxy → GitLab API. Calls made:
  - `GET /groups/<tenantGroup>` — does the tenant group exist?
  - If not: `POST /groups` (top-level: Pattern A) or
    `POST /groups` with `parent_id` (subgroup: Pattern B/C). The Task
    derives "top-level vs subgroup" from whether `tenantGroup`
    contains a `/` and lets GitLab enforce the permission check.
  - For each item in `subgroups`: `GET /groups/<tenantGroup>/<sub>` →
    `POST /groups` with `parent_id=tenantGroup.id` if missing.
  - `GET /groups/<tenantGroup>/access_tokens` → either
    `POST /groups/<tenantGroup>/access_tokens` (fresh) or
    `POST /groups/<tenantGroup>/access_tokens/:id/rotate` (refresh) or
    `DELETE` + `POST` (recreate on identity-affecting change).
- Step 0 → tmpfs `/workspace/secrets/token` (in-memory `emptyDir`) →
  step 1 `apply-kubernetes-resources` (catalog `kubectl` image) →
  cluster API server (server-side-apply on Secret + Connector).
- Step 1 → step 2 `write-results` (catalog `kubectl` image) →
  Tekton results sink (string `tenant-group`, JSON array `subgroups`;
  strings `access-token-name`, `connector-ref`).

### Failure modes

- **Pattern A — admin user lacks `can_create_group`.**
  `ensure-tenant-group.sh` requests `POST /groups` with no
  `parent_id` (top-level path); GitLab returns 403. Script exits with
  `ERROR: admin user lacks 'can_create_group'; cannot create top-level GitLab group '<tenantGroup>'. Either set the user's can_create_group flag on the GitLab instance, or use a subgroup tenantGroup (e.g. 'tenants/<tenantGroup>') under a parent the admin already owns.`
  No cluster mutation.
- **Pattern B/C — admin lacks `owner` on the parent.**
  `ensure-tenant-group.sh` requests `POST /groups` with `parent_id`;
  GitLab returns 403. Script exits with
  `ERROR: admin lacks 'owner' on parent group '<parent>'; cannot create subgroup '<leaf>' under it.`
  No cluster mutation.
- **`tenantGroup` path conflict (already owned by a different
  identity).** `ensure-tenant-group.sh` detects the existing path via
  `GET /groups/<tenantGroup>` 200 + ownership mismatch (the admin
  identity is not in the group's owner list) and exits with the
  explicit message. No GAT issued, no cluster mutation.
- **GAT already expired at refresh time.** Operator missed the
  rotation window (e.g. created with `tokenExpiry=30d`, second run
  arrives at day 31). GitLab's rotate endpoint returns 400 ("token
  expired") on the expired GAT id. `ensure-gat.sh` detects this and
  falls through to the **delete + recreate** path automatically:
  emits `WARN: existing GAT <id> is expired; falling through to recreate`,
  deletes the expired GAT (best-effort; GitLab garbage-collects
  expired tokens anyway), creates a fresh GAT at `tenantGroup`,
  hands the new token to step 2. The Task is therefore **self-healing
  on missed rotations** — no manual intervention required, no orphan
  state on either side. Documented in product-design.md operations
  runbook + how-to "missed rotation" section.
- **GitLab max-expiry rejection.** `ensure-gat.sh` reads the
  configured cap on the first 400 response, surfaces it, and exits
  before any cluster mutation.
- **Token quota exhaustion.** `ensure-gat.sh` surfaces GitLab's quota
  message verbatim and exits; no cluster mutation; recommend in the
  how-to that operators alert on this case.
- **Server-side-apply conflict on tenant Secret/Connector.**
  `apply-kubernetes-resources.sh` uses field manager `connector-auto`;
  surfaced conflicts fail loud rather than silently overwriting a
  rival manager's state.
- **Partial step-1 success then step-2 failure.** The GAT exists at
  GitLab but the tenant Secret was not written. Re-run is safe: step 1
  detects the existing GAT id, hits the rotate path, step 2 retries.
  Documented in the how-to as the recommended retry stance.
- **Pipeline wiring missing on operator side.** `make manifests` does
  not pull our install manifest until the
  `sync_install_manifests.sh` entry exists; the values.yaml stub must
  also be present. Both are part of Story 4 and gate
  `/feature:integrate`.

## Task Breakdown

| # | Task | Story | Slice | Repo | Why |
|---|------|-------|-------|------|-----|
| 1 | Author Task template `gitlab-connector-automatic-creation.template.yaml` (params: `tenantGroup`, optional `subgroups`, `connector`, `secret`, `accessLevel`, `scopes`, `tokenName`, `tokenExpiry`, `glabImage`, `kubectlImage`, `imagePullPolicy`; results: `tenant-group`, `subgroups`, `access-token-name`, `connector-ref`; optional workspaces; podTemplate non-root; three-step skeleton — `ensure-gitlab` + `apply-kubernetes-resources` + `write-results` — with cpu/mem requests + limits; each step's `script:` block uses `{{ INCLUDE: scripts/<name>.sh }}` placeholders); commit the rendered `gitlab-connector-automatic-creation.yaml` produced by `make render-tasks` | 1 | backend | connectors-extensions | AC-1, AC-4, AC-8, AC-11 — Task contract |
| 2 | Author `hack/render-task.sh` (≤50 LOC; reads `*.template.yaml`, replaces `{{ INCLUDE: <path> }}` placeholders with the matching source file's body, writes the rendered Task YAML); add `make render-tasks` Makefile target; add CI check that re-renders and fails on drift between template+scripts and the committed Task YAML | 1 | infra | connectors-extensions | Build-time render contract owned by connectors-extensions — no catalog dependency, no new image |
| 3 | Author `scripts/lib.sh` + `scripts/ensure-tenant-group.sh` — `lib.sh` carries shared bash helpers (logging that suppresses secrets, `glab` error parsing, JSON helpers); `ensure-tenant-group.sh` resolves `tenantGroup` shape (top-level vs subgroup), creates the tenant group via `glab`, creates any missing entries from `subgroups` under it, emits the reconciled tenant-group full path + the subgroup full-path list | 1 | backend | connectors-extensions | AC-1, AC-7 — group reconcile + actionable errors for both Pattern A and Pattern B/C |
| 4 | Author `scripts/ensure-gat.sh` — provision Group Access Token at `tenantGroup`; **three-path** lifecycle: rotate-in-place when GAT is healthy and inputs unchanged; delete+recreate when an identity-affecting input changes; **fall through to recreate when the existing GAT is already expired** (operator missed the rotation window). Write token value to tmpfs token file | 1 | backend | connectors-extensions | AC-2, AC-3, AC-5, AC-6, AC-7 — token lifecycle + admin-credential containment + expired-GAT self-healing |
| 5 | Author `scripts/apply-kubernetes-resources.sh` — server-side-apply Secret (`connectors.cpaas.io/gitlab-pat-auth`) + tenant `gitlab` Connector | 1 | backend | connectors-extensions | AC-4 — cluster outputs |
| 6 | Author `scripts/write-results.sh` — emit string `tenant-group` + JSON array `subgroups` + strings `access-token-name`, `connector-ref` | 1 | backend | connectors-extensions | AC-8 — result contract |
| 7 | Wire `connectors-gitlab/tektoncd/kustomization.yaml` (new) referencing the rendered Task YAML; mirror the Harbor kustomization shape | 1 | infra | connectors-extensions | Required for catalog publish + operator kodata sync pickup |
| 8 | Author `testing/features/script.feature` — Pod-level scenarios for `ensure-tenant-group.sh` (Pattern A top-level + Pattern B subgroup paths), `ensure-gat.sh` (rotate-in-place + recreate), `apply-kubernetes-resources.sh`, error paths (lacks `can_create_group`; lacks `owner`) | 2 | test | connectors-extensions | AC-9 (helper-script half — both patterns) |
| 9 | Author `testing/features/tektoncd.feature` — Task contract scenarios (params/results/workspaces) + end-to-end smoke TaskRuns covering Pattern A (top-level + can_create_group user) and Pattern B (subgroup + umbrella GAT) against a real GitLab + kind cluster | 2 | test | connectors-extensions | AC-9 (Task-contract + e2e — both patterns) |
| 10 | Author BDD fixtures `testing/features/testdata/*.pod.yaml`, `*.taskrun.yaml`, `*.connector.yaml`, `*.secret.yaml` | 2 | test | connectors-extensions | AC-9 — BDD inputs |
| 11 | Author concept page `docs/en/connectors/concepts/gitlab-cli-config.mdx` — `glab` CLI mount + auth-flow narrative | 3 | docs | connectors-extensions | AC-10 (concept) |
| 12 | Author how-to page `docs/en/connectors/how-to/gitlab-auto-create.mdx` — two parallel deployment patterns (Pattern A: top-level + `can_create_group` user; Pattern B: subgroup-of-umbrella + GAT), each with prerequisite setup steps, the end-to-end TaskRun examples from product-design.md, the token-refresh CronJob pattern, an **operations runbook section** (token already expired → self-healing recreate; missed-rotation alerting; tenant onboarding rollback; group-ownership audit), and the manual cross-group-permissions workaround | 3 | docs | connectors-extensions | AC-10 (how-to — two-pattern guide + ops runbook) |
| 13 | Add `sync_install_manifests "connectors-gitlab-tektoncd" "connectors-gitlab-tektoncd"` line to `hack/sync_install_manifests.sh`; add `values.yaml` stub for `global.images.gitlab-connector-automatic-creation`; run `make manifests` and commit the resulting `cmd/kodata/connectors-gitlab-tektoncd/...` | 4 | infra | connectors-operator | Required for the Task to flow into operator releases |
| 14 | Author `hack/sync_gitlab_connector_automatic_creation_task_doc.sh` (mirror of the Harbor doc-sync helper); add a Makefile target `sync-gitlab-connector-automatic-creation-task-doc` | 4 | docs | connectors-operator | Keeps the per-Task how-to snippet in operator docs in sync with the source manifest |

### Goal coverage check

- **AC-1** (`tenantGroup` create/reuse + optional `subgroups`) covered by tasks 1, 3.
- **AC-2** (GAT issued at `tenantGroup` with requested access-level + scopes) covered by task 4.
- **AC-3** (three-path refresh: rotate vs recreate vs expired-fall-through) covered by task 4; verified by test cases 3, 4, 6.
- **AC-4** (cluster outputs: tenant Connector + Secret) covered by tasks 1, 5.
- **AC-5** (admin PAT/GAT consumed only via CSI mount; never in Pod spec or tenant Secret) covered by tasks 1, 4.
- **AC-6** (idempotency: rotate on unchanged inputs; recreate on identity-affecting change; self-heal on expired GAT) covered by tasks 4, 8, 9; verified by test cases 3, 4, 5, 6.
- **AC-7** (actionable errors + expired-GAT self-healing) covered by tasks 3, 4; verified by test cases 7, 8, 9, 12.
- **AC-8** (results populated: `tenant-group`, `subgroups`, `access-token-name`, `connector-ref`) covered by task 6.
- **AC-9** (integration tests covering both Pattern A and Pattern B end-to-end + helper-script scenarios + expired-GAT self-heal) covered by tasks 8, 9, 10; mapped to test cases 1–13.
- **AC-10** (docs: concept + two-pattern how-to with all listed elements) covered by tasks 11, 12.
- **AC-11** (non-root UID 65532, multi-arch, cpu/mem requests + limits, in-memory `emptyDir`) covered by task 1 (delegated to the catalog `glab` image's UID + the Task podTemplate's resource limits — we reuse the catalog image rather than building our own).
- **Build-time render contract** covered by task 2 (no AC line — build-time machinery, not a user-facing surface).
- **Pipeline-wiring (operator-side)** covered by tasks 13, 14.
- No orphan ACs. No orphan tasks (every task maps to one AC, the build-time render slot, or a story-4 wiring slot).

## Test Design

### Test methods per story

- **Story 1 (backend — Task + scripts).** Helper-script Pod scenarios in
  `script.feature` (godog) cover unit-level shell behaviour against a
  real GitLab + kube API; idempotency, argument-validation, and error
  paths exercised here.
- **Story 2 (test — BDD).** End-to-end TaskRun in `tektoncd.feature`
  against a kind cluster + a GitLab CE instance (provisioned by the
  existing `connectors-gitlab/testing/init/` bootstrap), covering all
  six AC-9 scenarios.
- **Story 3 (docs).** `mdx` lint in CI; manual review by reporter
  (Daniel Morinigo) before sign-off; how-to TaskRun example walked
  through end-to-end against a fresh GitLab namespace.
- **Story 4 (operator pipeline wiring).** `make manifests` produces a
  non-empty `cmd/kodata/connectors-gitlab-tektoncd/1.0.0/install.yaml`
  in CI; `make dist` succeeds with the new component included; the
  doc-sync helper runs cleanly against the source manifest.

### Testing format

Both `script.feature` and `tektoncd.feature` follow the
**connectors-extensions BDD harness** (godog runner, run by
`cd connectors-extensions/testing && make test`), with the Gherkin
shape established by Harbor's
`harbor-connector-automatic-creation/0.1/testing/features/`.
Conventions inherited verbatim:

- `# language: zh-CN` directive at the top of every feature file;
  scenario titles in Chinese (`场景:`), table headers in English.
- Allure tagging on every scenario: `@allure.label.epic:GitlabConnectorAutomaticCreationTask`
  + `@priority-high|medium|low`, `@automated|@manual`.
- Selector tags for filtering:
  `@gitlab-connector-automatic-creation`,
  `@gitlab-connector-automatic-creation-tektoncd` /
  `@gitlab-connector-automatic-creation-script`,
  plus per-scenario tags
  (e.g. `@params`, `@workspaces`, `@results`, `@execution`,
  `@expired-token-refresh`).
- **CEL-based resource assertions** in pipe-table form:
  `资源检查通过` blocks evaluate CEL on the matching resource (`obj.spec.*`,
  `obj.status.*`) with `interval` + `timeout` columns.
- Pod- and TaskRun-level outcome assertions:
  Pod scenarios assert `$.status.phase == Succeeded|Failed` and
  match log patterns under named containers; TaskRun scenarios assert
  step exit codes, results, and post-run resource state via CEL.
- All testdata referenced by relative path
  (`../testdata/<scope>/<file>.yaml`) so the testdata stays
  reviewable next to the feature.

**`tektoncd.feature` focus** — the **Task contract** (does the
shipped Task declare the params/results/workspaces this design
promises?) plus **end-to-end smoke** (does a real TaskRun against a
real GitLab CE + kind cluster produce the expected GitLab + cluster
state?). One Scenario per AC subset:
- `场景: Task 应声明完整参数 contract` — CEL on `obj.spec.params` size + per-param presence and type/default.
- `场景: Task 应声明可选 workspaces` — CEL on `obj.spec.workspaces` for `gitlab-config` + `kube-config` both `optional: true`.
- `场景: Task 应声明 4 个 results` — CEL on `obj.spec.results` size + per-result presence and type.
- `场景: Task 应完成 GitLab 与 Kubernetes 资源初始化 (Pattern A)` — full TaskRun smoke for Pattern A.
- `场景: Task 应完成 GitLab 与 Kubernetes 资源初始化 (Pattern B)` — full TaskRun smoke for Pattern B.
- `场景: Task 应在过期 GAT 上自动 recreate` — expired-token refresh recovery (test case 4 below).
- `场景: Task 应在 scope 变更时 recreate token` — recreate-on-scope-change.
- `场景: Task 应支持 add-subgroup 的 reconcile` — add-subgroup smoke.
- `场景: Task 应在 admin 缺少 can_create_group 时给出可操作错误` — Pattern A failure.
- `场景: Task 应在 admin 缺少 owner 时给出可操作错误` — Pattern B failure.

**`script.feature` focus** — the **helper-script unit-level
behaviour** under realistic Pod conditions (catalog `glab` image +
helper script under `/workspace/scripts/connectors-gitlab/<name>.sh`,
loaded directly from the source `.sh` file at fixture-render time —
no rendered-Task indirection — against a real GitLab CE), independent
of the Tekton plumbing. One Scenario per script + branch:
- `场景: ensure-tenant-group 应创建 top-level group (Pattern A)` — Pod runs `ensure-tenant-group.sh` with `tenantGroup=acme`; asserts log pattern `RESULT: tenant-group path=acme status=created` + post-run group existence.
- `场景: ensure-tenant-group 应创建 subgroup under umbrella (Pattern B)` — analogous for `tenants/acme`.
- `场景: ensure-tenant-group 应处理已存在 group 的幂等情况` — pre-create the group, rerun, assert `status=reused`.
- `场景: ensure-gat 应 rotate-in-place 已存在的 GAT` — pre-create GAT, run rotate path, assert new token in tmpfs token file + log pattern `RESULT: ensure-gat token=connector-... status=rotated`.
- `场景: ensure-gat 应在 GAT 已过期时 fall through 到 recreate` — pre-create GAT with `expires_at` in the past; assert log pattern `WARN: token expired, falling through to recreate` + `RESULT: ensure-gat token=connector-... status=recreated`.
- `场景: ensure-gat 应在 scope 变更时 recreate` — analogous; identity-affecting input drives recreate path.
- `场景: ensure-gat 应在 GitLab max-expiry 拒绝时给出可操作错误` — set `tokenExpiry` higher than instance max; assert Pod `Failed` + log includes the GitLab error verbatim.
- `场景: apply-kubernetes-resources 应幂等 server-side-apply Secret + Connector` — rerun, assert no `resourceVersion` bump on Connector when token is unchanged.

Each script scenario uses one Pod manifest under
`testing/features/testdata/script/<script>/<branch>.pod.yaml`,
matching Harbor's `testdata/script/<script>/<branch>.pod.yaml`
layout. Each TaskRun scenario uses one TaskRun manifest under
`testing/features/testdata/tektoncd/<scenario>.taskrun.yaml`.

### Specific test cases

1. **(p0) Fresh creation — Pattern A (top-level + `can_create_group`).**
   Input: `tenantGroup=acme`, `subgroups=[team-a, team-b]`,
   `scopes=[api, read_repository]`, `accessLevel=30`, admin Connector
   = user PAT with `can_create_group` → expected: top-level `acme`
   created, `acme/team-a` + `acme/team-b` created, GAT issued at
   `acme`, Connector + Secret created. Method: BDD `tektoncd.feature`
   end-to-end scenario. Mirrors product-design.md Example 1.
2. **(p0) Fresh creation — Pattern B (subgroup + umbrella GAT).**
   Input: `tenantGroup=tenants/acme`, `subgroups=[team-a, team-b]`,
   admin Connector = umbrella GAT with `owner` on `tenants` →
   expected: `tenants/acme` + `tenants/acme/team-a` +
   `tenants/acme/team-b` created, GAT issued at `tenants/acme`,
   Connector + Secret created. Method: BDD `tektoncd.feature`.
   Mirrors product-design.md Example 2.
3. **(p0) Idempotent rotate-in-place.** Input: rerun any prior
   creation with all inputs unchanged → expected: same group set,
   same GAT id, new token value rotated via `POST /groups/:id/access_tokens/:token_id/rotate`,
   Secret data updated, Connector unchanged (resourceVersion bumps
   for Secret only). Method: BDD `tektoncd.feature`. Mirrors
   Example 3.
4. **(p0) Expired-token refresh self-heals via recreate.** Setup:
   pre-create a GAT at `tenantGroup` with `expires_at` in the past
   (e.g. via direct GitLab API as test fixture). Input: rerun #1
   with all inputs unchanged → expected: `ensure-gat.sh` detects the
   expired GAT, emits `WARN: existing GAT <id> is expired; falling
   through to recreate`, deletes the expired GAT, creates a fresh
   GAT, Secret rewritten, Connector annotation
   `connectors.cpaas.io/gat-recreated-at` updated, TaskRun succeeds.
   No manual intervention required. Method: BDD `tektoncd.feature`
   end-to-end scenario + helper-level scenario in `script.feature`
   (`ensure-gat 应在 GAT 已过期时 fall through 到 recreate`). Covers
   the "ran first time with 30d, ran second time after 30d" case
   raised in team review.
5. **(p0) Add-subgroup reconcile.** Input: rerun #1 with `team-c`
   added to `subgroups` → expected: missing subgroup created under
   `tenantGroup`, GAT rotated (no recreate), Connector unchanged.
   Method: BDD `tektoncd.feature`. Mirrors Example 5.
6. **(p0) Recreate on scope or access-level change.** Input: rerun #1
   with `scopes` changed (or `accessLevel` flipped) → expected: old
   GAT deleted at GitLab, new GAT created with new attributes, Secret
   data rewritten, Connector annotation
   `connectors.cpaas.io/gat-recreated-at` updated. Method: BDD
   `tektoncd.feature`. Mirrors Example 4.
7. **(p0) Invalid params — missing `tenantGroup`.** Expected: Task
   fails at param validation, no GitLab call, no cluster mutation.
   Method: BDD `tektoncd.feature`.
8. **(p0) Pattern A admin lacks `can_create_group`.** Input:
   top-level `tenantGroup=acme`, admin Connector = user PAT for an
   account *without* `can_create_group` → expected: Task fails with
   the explicit "admin user lacks 'can_create_group'" message; no
   partial state in GitLab; no cluster mutation. Method: BDD
   `tektoncd.feature`. Mirrors product-design.md Pattern-A failure
   example.
9. **(p0) Pattern B admin lacks `owner` on the parent.** Input:
   `tenantGroup=tenants/acme`, admin Connector = umbrella GAT with
   only `maintainer` on `tenants` → expected: Task fails with the
   explicit "admin lacks 'owner' on parent group 'tenants'"
   message; no partial state. Method: BDD `tektoncd.feature`.
   Mirrors product-design.md Pattern-B failure example.
10. **(p0) Helper: `ensure-tenant-group.sh` creates a missing
    top-level group AND a missing subgroup under existing parent.**
    Two scenarios in one feature file (one per pattern). Method:
    BDD `script.feature` Pod scenarios.
11. **(p0) Helper: `ensure-gat.sh` rotates a known healthy GAT id
    and writes the new token to the tmpfs token file.** Method: BDD
    `script.feature`.
12. **(p1) Helper: `ensure-gat.sh` honours `tokenExpiry` capped at
    GitLab max-expiry; surfaces actionable error when GitLab rejects.**
    Method: BDD `script.feature`.
13. **(p1) Helper: `apply-kubernetes-resources.sh` server-side-applies
    Secret + Connector idempotently with field-manager `connector-auto`.**
    Method: BDD `script.feature`.
14. **(p1) Pipeline wiring: `make manifests` populates
    `cmd/kodata/connectors-gitlab-tektoncd/1.0.0/install.yaml`** with
    the rendered Task + (zero or one) tool-image ConfigMap references.
    Method: shell test in `connectors-operator` CI.
15. **(p2) Doc-sync helper: `sync_gitlab_connector_automatic_creation_task_doc.sh`**
    rewrites the inline TaskRun in the connectors-extensions how-to
    snippet using `${REGISTRY}` + `${TARGET_NS}` envsubst markers.
    Method: shell test in `connectors-operator` CI.

### E2E case decision

**Yes — new e2e cases required** in connectors-extensions:

- `connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/testing/features/tektoncd.feature`
  — full TaskRun on a kind cluster + a real GitLab CE, covering test
  cases 1–9 above (Task contract conformance + Pattern A end-to-end +
  Pattern B end-to-end + idempotent rotate + expired-GAT self-heal +
  add-subgroup + recreate-on-scope-change + invalid params + Pattern
  A/B prerequisite-mismatch failures).
- `connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/testing/features/script.feature`
  — Pod-level helper scenarios, covering test cases 10–13 (helper
  unit-level behaviour with one Pod per scenario; assertions on
  `$.status.phase` + log patterns + post-run cluster state).

Reason for needing new e2e cases: this Task issues real Group Access
Tokens against a real GitLab API; the rotate-vs-recreate decision and
the max-expiry / token-quota error paths are not testable without the
real API contract. The Harbor reference set the precedent (split
`script.feature` + `tektoncd.feature`) and the operator integration
suite expects the same shape from each connector. **No new e2e cases
in `connectors-operator/test/integration`** — that suite covers
operator-level reconciliation; this Task lives in connectors-extensions
and is exercised by the extensions BDD suite.

### Re-approval log

<!-- If the test design is edited during implement, the design reviewer re-signs here. -->

- 2026-05-06 — initial design (this round). Pending design-review.
- 2026-05-06 — design rework #1 after PR #997 review (drop image-pull
  Secrets; reuse catalog `glab` + `kubectl` images; expand repos to
  include connectors-operator for pipeline wiring; add example usage).
- 2026-05-06 — design rework #2 after PR #997 follow-up discussion
  (rename `parentGroup` → `tenantGroup`; rename `gitlabGroups` →
  optional `subgroups`; document Pattern A — `can_create_group` user
  for top-level tenant groups — and Pattern B — umbrella + GAT for
  subgroup-of-umbrella tenants — as deployment patterns the Task
  serves uniformly; drop instance-admin from recommendations; renumber
  test cases 1–14 to cover both patterns end-to-end).
- 2026-05-06 — design rework #3 after team-review on PR #997
  (3 comments). Added: explicit Testing format subsection (Gherkin
  `# language: zh-CN`, godog runner, CEL assertion tables, per-suite
  focus declaration with named Scenarios mirroring Harbor's shape);
  expired-GAT self-healing path in `ensure-gat.sh` (rotate ⇒ recreate
  ⇒ expired-fall-through-to-recreate is now a three-path lifecycle);
  new test case 4 (expired-token refresh retry) — both Task-level
  e2e scenario and helper-level Pod scenario; how-to (task 11) gains
  an operations-runbook subsection covering the missed-rotation
  case + monitoring alerts.
- 2026-05-06 — design rework #4 after PR #997 follow-up review
  surfaced two unaddressed comments from rework #3 ("scripts in
  connectors-extensions, not catalog" + "image building logic and
  Containerfile"). Considered three options: (A) build a script-only
  image owned by connectors-extensions, (B) localised render-tool
  with `{{ INCLUDE: ... }}` placeholder substitution and inline
  `script:` blocks (no new image, no init step at runtime), (C) own
  Containerfile that bundles `glab`+`kubectl`+scripts (Harbor
  pattern). Picked B: the catalog already publishes `glab` and
  `kubectl` images; building any new image is positive marginal cost
  for ~0 functional gain. Substantive design changes:
  - **Script ownership** flipped from `catalog/tasklib/scripts/connectors-gitlab/`
    → `connectors-extensions/connectors-gitlab/tektoncd/tasks/.../0.1/scripts/`.
  - **Build-time render contract** moved from catalog `tasklib` →
    new local `hack/render-task.sh` in connectors-extensions.
  - **Runtime shape** simplified from 4-step (init `prepare-scripts`
    + 3 substantive steps) → 3-step (init step removed; each step's
    `script:` block carries the inlined helper bodies, mirroring
    Harbor's runtime layout but without a custom image).
  - **Repos affected unchanged**: `connectors-extensions` +
    `connectors-operator`. Catalog reverts to a read-only image
    reference; no PR there.
  - Task breakdown: 13 → 14 (added task 2 = render-tool +
    Makefile target; helper-script tasks 2–5 → 3–6 with paths
    updated; testing/docs/ops tasks shifted +1).
  - Coverage check refreshed; 11 ACs all still covered. Pending re-review.
