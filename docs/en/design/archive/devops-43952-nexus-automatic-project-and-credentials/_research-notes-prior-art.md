# Prior-art research — DEVOPS-43952 Nexus automatic project + connector + secret

Research-only scratchpad. Findings are anchored to file paths the design
author should re-read in full. All paths absolute.

## 0. Umbrella inventory

- **Harbor (DEVOPS-43145):** no `/feature:*` umbrella exists. Design
  artifacts live under `docs/en/design/connectors-auto-project/` as
  three pre-feature-workflow notes (`harbor.task-1.design.md`,
  `harbor.task-2.design.md`, `tech-design.md`). There is no
  retrospective.md / acceptance.md / state.yaml. The shipped artifact
  is the Task in `connectors-extensions/connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/`.
- **GitLab (DEVOPS-43146):** full `/feature:*` umbrella at
  `docs/en/design/devops-43146-gitlab-automatic-project-and-sub-account/`,
  stage=regress. Retrospective at
  `docs/en/design/connector-gitlab/devops-43146-retrospective.md`
  (separate from the umbrella).

> Contradiction with session assumption: there is **no Harbor parent-project
> concept**. Harbor's design takes a *list* of harbor projects + one
> robot account spanning them (`harbor.task-1.design.md:42-48`); no
> umbrella-tenant hierarchy. GitLab introduced the Pattern A
> (top-level) vs Pattern B (umbrella/tenant) shape only after design
> rework #2 (gitlab state.yaml lines 295-336).

---

## 1. Tekton Task interface convention

| Item | Harbor | GitLab |
|---|---|---|
| Task name | `harbor-connector-automatic-creation` | `gitlab-connector-automatic-creation` |
| Version dir | `0.1` (no patch component) | `0.1` |
| Version label | `app.kubernetes.io/version: "0.1"` (`.../harbor-connector-automatic-creation/0.1/harbor-connector-automatic-creation.yaml:7`) | same (`.../gitlab-connector-automatic-creation/0.1/task.yaml:6`) |
| File name | `<task>.yaml` (no template; scripts live in a built image) | `task.yaml` + `task.template.yaml` (rendered by `hack/render-task.sh` inlining `scripts/*.sh`) |
| Path | `connectors-extensions/connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/` | `connectors-extensions/connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/` |

**Params, common to both:** `connector` (required `<ns>/<name>`),
`secret` (optional, default = `<connector-name>-secret`),
`imagePullPolicy` (default `Always`), `verbose` (`"true"`/`"false"`
string), one tool-image param (`harborCliImage` / `gitlabCliImage` +
`kubectlImage`). Tool-image params are wired to a `kube-public`
ConfigMap by the `style.tekton.dev/descriptors` annotation
(label selector `catalog.tekton.dev/tool-image-<name>`).

**Params, divergent:**

- Harbor (`harbor-connector-automatic-creation.yaml:93-129`):
  `harborProjects` (array, required), `permissions` (array, required —
  positional `<resource>:<verbs>`), `robotAccount` (optional, default
  `connector-<conn-ns>-<conn-name>`), `robotAccountDuration` (default
  `-1` = no expiry), `imagePullSecrets` (array, default `[]`).
- GitLab (`task.yaml:122-168`): `tenantGroup` (required string),
  `subgroups` (array, default `[]`), `accessLevel` (default `owner`),
  `scopes` (array, default `["api", "read_repository"]`),
  `tokenDuration` (default `"30"` days), `accessTokenName` (optional —
  full name becomes `<prefix>/<identity-suffix>` where the suffix
  encodes access level + scopes + subgroup set).

**Results, divergent:**

- Harbor (`harbor-connector-automatic-creation.yaml:137-150`):
  `harbor-projects` (array), `robot-account-name`, `connector-ref`,
  `image-pull-secret-refs` (array).
- GitLab (`task.yaml:175-184`): `tenant-group`, `subgroups` (array),
  `access-token-name`, `connector-ref`. No image-pull-secret result.

**Workspaces, identical shape:** one optional CLI-config workspace
(`harbor-config` / `gitlabconfig`) bound from a Connector-CSI mount,
plus one optional `kube-config` / `kubeconfig` workspace.

**Representative snippet** (gitlab `task.yaml:175-184`):

```yaml
results:
  - name: tenant-group
    description: The materialised tenant group path
  - name: subgroups
    type: array
    description: JSON array of materialised subgroup paths
  - name: access-token-name
    description: Identity-encoded GitLab GAT name minted/rotated by this run
  - name: connector-ref
    description: Namespaced reference of the tenant Connector handled by the Task
```

---

## 2. Identity-provisioning pattern

Neither prior-art "reuses" an existing identity in the Kubernetes
sense. Both **always provision a fresh per-tenant credential** owned
by the Task and named deterministically so reruns find it:

- Harbor (`harbor.task-1.design.md:58-71`,
  `ensure-robot-account.sh:300-330`): single Robot Account named
  `connector-<connector-ns>-<connector-name>` (or user-specified).
  Existence-check via `lookup_robot_id`; if found and project-set
  unchanged → `update_robot_account_permissions` + `refresh_robot_token`
  (in-place token refresh). If project-set changed → `recreate_robot_account`
  (delete + re-create). No fallback to a "shared" robot.
- GitLab (`scripts/ensure-gat.sh:373-405`): single GAT named
  `<accessTokenName>/<identity-suffix>` where the suffix encodes
  identity-affecting inputs. Three-path lifecycle:
  - no existing GAT → `status=created reason=no-existing-gat`
  - existing GAT expired → `status=recreated reason=expired-fallthrough`
  - identity-affecting input changed (suffix mismatch) →
    `status=recreated reason=identity-changed`
  - else → `status=rotated reason=identity-match`

**Fall-back order** is "find existing by name → recreate-if-changed →
otherwise refresh in place". No "reuse a global service account" path
in either Task.

**Credential return to Kubernetes:**

- Token written to a tmpfs (`emptyDir.medium: Memory`) hand-off file
  between steps (Harbor `volumes: shared-data`,
  `harbor-connector-automatic-creation.yaml:151-154`; GitLab
  `volumes: state` + `secrets`, `task.yaml:84-90`).
- Step 2/3 (`apply-kubernetes-resources.sh`) reads the token and
  **the Task itself runs `kubectl apply --server-side`** against the
  in-cluster API server to write the Connector + Secret. No operator
  involvement, no follow-up controller, no Helm post-install hook.
- Harbor optionally writes a `kubernetes.io/dockerconfigjson` Secret
  in each target namespace listed in `imagePullSecrets`. GitLab
  intentionally **does not** ship that surface (gitlab feature.md
  AC-4 trailing note + "Out of scope" section, lines 106-110).

---

## 3. Connector + Secret reconciliation flow

**The Task is the reconciler.** Concrete code path:

- `apply-kubernetes-resources.sh` (harbor:
  `connectors-extensions/connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/images/harbor-cli/scripts/apply-kubernetes-resources.sh`;
  gitlab same path under `connectors-gitlab/.../scripts/`) runs in
  the catalog `kubectl` image with the TaskRun ServiceAccount.
- Uses `kubectl apply --server-side --field-manager=connectors-operator`
  (gitlab acceptance.md AC-4 cites
  `apply-kubernetes-resources.sh:166-218`) to write Secret +
  Connector. Server-side-apply on a stable field-manager makes reruns
  idempotent and surfaces field-manager conflicts on the next reconcile.
- The operator **is not in this loop**. The operator's only touch
  point is the install-manifest pipeline (Story 4 — `hack/sync_install_manifests.sh`
  + `values.yaml` stub + auto-synced `cmd/kodata/connectors-<kind>-tektoncd/1.0.0/install.yaml`).
  See `tech-design.md ## Architecture` lines 59-71 for the gitlab
  case.

The retrospective explicitly rejected the CRD+controller alternative
on cost grounds (`connectors-auto-project/tech-design.md:78-85`).

---

## 4. Rollback contract

**Neither prior-art does transactional rollback.** Both rely on
**idempotent rerun** as the recovery model. Gitlab feature.md AC-7
spells this out (lines 100, amended):

> If a later step fails (e.g. the GAT mint at `tenantGroup`) after an
> earlier step already created a group or subgroup, the partial GitLab
> state is **not** rolled back transactionally; instead, every step is
> idempotent so a rerun after fixing the admin Connector reuses the
> existing group rather than creating a duplicate.

Mechanism per resource type:

- **Harbor projects** (`ensure-projects.sh:58-74`): create → on
  conflict `409` / `already exists` → swallow + return success. No
  delete-on-failure.
- **Harbor robot accounts** (`ensure-robot-account.sh:300-320`):
  delete-then-recreate is the **identity-change** path, not a failure
  rollback. The `cleanup()` function
  (`ensure-robot-account.sh:85-92`, `trap cleanup EXIT`) only deletes
  ephemeral *files* (`TEMP_FILES[]`), not Harbor-side state.
- **GitLab groups/subgroups**: idempotent create
  (`ensure-group.sh:184,194,255` surfaces "path conflict" instead of
  silently adopting).
- **GitLab GAT**: `revoke_gat` is invoked only as part of the
  identity-changed and expired-fallthrough recreate flows
  (`ensure-gat.sh:387, 397`). Not invoked on cluster-apply failure.

**Task retry semantics:** every step is idempotent — re-running the
TaskRun re-uses existing remote resources and rotates/refreshes the
credential. The gitlab retrospective (DEVOPS-43146-retrospective.md,
"Design changes during implementation" §2) tightened this further by
adding **ownership verification** so that a stale path owned by a
different identity does not get silently adopted.

---

## 5. Operator RBAC delta

**Zero RBAC changes shipped from the operator side for either prior-art.**

Both `cmd/kodata/connectors-harbor-tektoncd/1.0.0/install.yaml`
(490 lines) and `cmd/kodata/connectors-gitlab-tektoncd/1.0.0/install.yaml`
(1357 lines) contain only `kind: Task` + `kind: ConfigMap`
(tool-image refs). `grep -nE "^kind:|ClusterRole|verbs:|apiGroups"`
returns no ClusterRole/Role/Binding entries.

The TaskRun runs as whatever ServiceAccount the operator/admin
attaches at trigger time; that SA needs `connectors.cpaas.io/*`
Connector CRUD + `core/secrets` CRUD in the target namespaces. This
RBAC is **out-of-scope for the connectors operator manifests** — the
deploying admin is expected to grant it on the dedicated
`connectors-management` namespace (harbor design "前置准备",
`harbor.task-1.design.md:13-16`; gitlab feature.md AC-4 + threat-model
section on admin namespace isolation).

Operator-side wiring is therefore three lines of plumbing:
`sync_install_manifests.sh` entry, `values.yaml` stub, doc-sync
helper. See `devops-43146-gitlab-automatic-project-and-sub-account/tech-design.md:59-71`.

---

## 6. Test design

**Per `tech-design.md ## Test Design` (lines 188-405, gitlab):**

- No new unit tests in Go. The Task ships shell scripts; tests are
  Pod-level Gherkin (godog) BDD.
- Two feature files per Task (Harbor reference set the precedent;
  gitlab mirrors it):
  - `script.feature` — one Pod per scenario; loads helper `.sh`
    directly; asserts `$.status.phase == Succeeded|Failed` + log
    pattern + post-run cluster/remote state.
  - `tektoncd.feature` — full TaskRun against a real backend
    (Harbor/GitLab CE) on a kind cluster; CEL assertion tables for
    Task contract (params/results/workspaces) + end-to-end behavior.
- Gherkin language: `# language: zh-CN` directive; scenario titles in
  Chinese (`场景:`); table headers in English; allure
  `@allure.label.epic:...` labels + `@priority-*`, `@automated|@manual`.
- All testdata referenced by relative path under `testing/features/testdata/`.
- **No new e2e cases** in `connectors-operator/test/integration`. The
  operator integration suite is reserved for operator-level reconciliation.
- **GitLab specific test cases that proved hard to verify in CE**
  (acceptance.md "Live evidence" + retrospective "What's `@manual`
  and why"):
  - TC4 expired-GAT path — GitLab `expires_at` is date-resolution; no
    minute-precision injection. Marked `@manual`.
  - TC11 instance `max_token_expiry` — mutating instance-wide setting
    breaks suite parallelism. Marked `@manual`.
  - TC12 GAT quota — Premium/Ultimate only; CE cannot reproduce.
    Tagged `@manual @premium-only`.

---

## 7. OpenSpec change groups

Pulled from
`devops-43146-gitlab-automatic-project-and-sub-account/state.yaml.story_groups[]`
(lines 113-170):

| Story | Change ID | Repo | Class | One-line |
|---|---|---|---|---|
| 1 | `gitlab-connector-automatic-creation-task` | connectors-extensions | design-change | The Task + helper scripts + render tool. Parent of stories 2/3/4. |
| 2 | `gitlab-connector-automatic-creation-task-bdd` | connectors-extensions | mechanical-followup (of Story 1) | `script.feature` + `tektoncd.feature` + fixtures. Consolidated into Story 1's PR #269 during implement (state.yaml line 141). |
| 3 | `gitlab-connector-automatic-creation-task-docs` | connectors-extensions (folder) / connectors-operator (impl) | mechanical-followup (of Story 1) | Concept + how-to + reference doc pages. Shipped via operator PR #1002. |
| 4 | `gitlab-connector-automatic-creation-task-operator-wiring` | connectors-operator | mechanical-followup (cross-repo parent = Story 1) | `sync_install_manifests.sh` entry + `values.yaml` stub + doc-sync helper. PR #1000. |

Harbor has no openspec change groups (predates the workflow).

---

## 8. Retrospective takeaways

Pulled from
`/home/ubuntu/jtcheng/code/src/github.com/AlaudaDevops/connectors-operator/docs/en/design/connector-gitlab/devops-43146-retrospective.md`
("Bottom line" + "Design changes during implementation"):

1. **Identity model is the highest-cost design surface.** GitLab's
   Pattern B (umbrella GAT) is materially different from what was
   originally proposed because GitLab refuses every API path that
   would let an umbrella GAT mint a per-tenant subgroup GAT — group
   share doesn't grant the *direct* Owner that GAT-creation requires.
   The Task contract (params/results/workspaces) did **not** change;
   all adjustments were in helper scripts and admin-identity prereqs.
   (Retrospective §"Design changes during implementation 1".)
2. **ConnectorClass dependencies must be grep-verified, not assumed.**
   The proposal explicitly listed "no ConnectorClass changes" as
   out-of-scope, then implementation discovered `gitlabconfig` needed
   a new top-level `connector_address` field — same field Harbor's
   `harborconfig` had already added in DEVOPS-43722. Lesson: grep the
   ConnectorClass template before claiming the dependency is satisfied
   (retrospective §5).
3. **Path-conflict handling must verify ownership, not just existence.**
   Initial `ensure-group.sh` silently adopted a same-named group owned
   by another user; fixed by adding `verify_admin_ownership`
   (retrospective §2). Nexus repos and roles likely face the same
   issue.
4. **Live-test on the real backend after BDD-on-stub passes** —
   caught 26 distinct bugs the stub suite missed (retrospective
   "Live-test-driven bug catalog"). Includes shell traps like `set -e`
   + `[[ -z X ]] && Y` silently killing scripts and `set -x` xtrace
   dumping 200+ lines per step. Build the live-validation harness
   into the iteration loop.
5. **CE-vs-Premium awareness must be explicit in the test plan.** TC12
   (GAT quota) cannot be exercised on GitLab CE. Nexus has a similar
   shape: Nexus OSS vs Pro have divergent capabilities (e.g.
   blob-store granularity, SAML, fine-grained roles). Mark cases
   that need Pro upfront and stub them at the unit layer.

The retrospective also flags an **operational incident** (a global
`kubectl delete ns -l 'kubernetes.io/metadata.name'` wiped the test
cluster) — included in the personal-memory rules; relevant for any
Nexus author who scripts cleanup of test namespaces.

---

## 9. Reuse-vs-reject table for Nexus

| Topic | Harbor / GitLab convention | Nexus verdict | Reason |
|---|---|---|---|
| Two-Task split (init + rotation) | Harbor design proposed it (`connectors-auto-project/tech-design.md:33-61`) but only the init Task shipped; GitLab folded both into one. | **inherit** (single Task with idempotent rerun + cron-friendly rotation) | One-Task model is the lived convention; Nexus rotation is just a re-mint with the same identity suffix. |
| Version dir `0.1`, label `app.kubernetes.io/version: "0.1"` | both | **inherit** | Catalog Task version convention. No reason to bump. |
| Task name pattern `<vendor>-connector-automatic-creation` | both | **inherit** | Naming is already conventional and operator-side `sync_install_manifests.sh` ergonomics expect it. |
| `task.template.yaml` + `task.yaml` + `hack/render-task.sh` inlining helper scripts | gitlab (`tech-design.md:30-58, 156`). Harbor uses a built tool image (`images/harbor-cli/`). | **inherit** (gitlab approach) | Nexus has a published REST API + an upstream `nexus-cli` is shaky; gitlab's "reuse upstream CLI image + inline shell scripts" beats authoring + maintaining a `nexus-cli` Containerfile. |
| `connector` / `secret` / `verbose` / `imagePullPolicy` params | both | **inherit** | Cross-Task UX uniformity matters; ConnectorClass operators wire them by name. |
| `harborProjects` / `tenantGroup` core resource param | shape divergent | **diverge** | Nexus's primary resource is a **repository** (and a blob-store on Pro). Use `nexusRepositories` (array) similar to Harbor's `harborProjects`. |
| Per-resource permission array (`permissions`) — positional with the resource list | Harbor only | **diverge** (model under design) | Nexus roles + privileges are richer than Harbor's `<resource>:<verbs>`. Consider a single per-Task service-account role (Harbor-style) rather than positional permission lists; the gitlab retrospective explicitly recommends keeping admin identity out of the Task's branching logic. |
| Per-tenant identity = deterministic name + identity suffix | gitlab (`<prefix>/<identity-suffix>`) | **inherit** | Same lifecycle needs (rotate vs recreate). Nexus user/token name should encode the repository set so rerun detects identity change. |
| `imagePullSecrets` array (cross-namespace docker pull secrets) | Harbor only | **drop** | Nexus is a generic artifact repo (maven, npm, raw, docker — though docker is one format). Image-pull-secret materialisation is a Harbor-shaped feature; the gitlab feature explicitly dropped it from scope. If a Nexus consumer needs a docker-pull secret, it's a follow-up Task. |
| Workspace pair: `<vendor>-config` (required CSI) + `kube-config` (optional CSI) | both | **inherit** | Admin credential must come via the connectors-csi mount per AC-5 invariant. |
| Three-path identity lifecycle (rotate / recreate-on-change / recreate-on-expired-fallthrough) | gitlab | **inherit** | Nexus tokens / user-tokens are not inherently expiring on most setups, but the symmetry is cheap and gives the self-healing missed-rotation property for free. |
| Server-side-apply with `--field-manager=connectors-operator` | both | **inherit** | Identical wire-format invariant for tenant Secret + Connector. |
| Rollback semantics = idempotent rerun, no transactional rollback | both | **inherit** | Same constraint applies: REST APIs aren't transactional across resources. |
| Tool image from `kube-public` `catalog.tekton.dev/tool-image-<name>` ConfigMap, descriptor form wiring | both | **inherit** | If no upstream nexus CLI image exists, use gitlab's "inline scripts + `curl` REST" pattern to avoid a new Containerfile. |
| Two-pattern (top-level vs umbrella/tenant) admin-identity shape | gitlab only | **drop** | Nexus has no parent-tenant hierarchy. Nexus realms / repositories are flat under the instance. Single admin model. |
| BDD layout: `script.feature` + `tektoncd.feature`, zh-CN Gherkin, allure tags, CEL assertion tables | both | **inherit** | Connectors-extensions test harness expects this shape; reviewer expects parity. |
| Mechanical-followup change layout (Story 1 = parent design-change; Stories 2–4 = bdd / docs / operator-wiring followups, optionally cross-repo) | gitlab | **inherit** | Direct copy of structure; gitlab story_groups[] is the template. |
| Operator-side delta = `sync_install_manifests.sh` + `values.yaml` stub + doc-sync helper; **zero RBAC change** in operator manifests | both | **inherit** | Confirmed by `grep` on shipped install.yaml manifests. RBAC is the deployer's responsibility, not the operator's. |
| Documentation: concept page covers CLI-config mount + auth flow; how-to covers full TaskRun + cron + ops runbook + manual workaround | gitlab AC-10 (`feature.md:103-104`) | **inherit** | Existing concept-page pattern (e.g. `harbor-cli-config.tech-design.md`, `glab_cli_config.mdx`) is the model. Nexus concept page = `nexus-cli-config` (or whichever upstream CLI you pick). |
| Risk classification = `sensitive` + threat model + security sign-off | gitlab (state.yaml.security.override, lines 679-692) | **inherit** | Same threat surface: long-lived per-tenant credential issued from an admin credential; compromise impact ≈ admin's blast radius. |

