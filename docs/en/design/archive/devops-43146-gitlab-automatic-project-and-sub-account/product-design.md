# Product Design — Gitlab automatic project and sub-account support using API and CLI

<!--
Written by /feature:design. The primary output is the Goal statement; every
other section exists to support or validate it.
-->

## Goal

Give platform engineers a single Tekton TaskRun that, against one admin
GitLab Connector, reconciles a tenant's GitLab group (`tenantGroup`)
and any optional per-team `subgroups` under it, provisions a bot-backed
Group Access Token at the tenant group, and lands the cluster-side
tenant `gitlab` Connector + auth Secret — idempotent on re-run, rotates
the token in place when inputs are unchanged, and deletes-and-recreates
only when an identity-affecting input changes. The Task is
deployment-pattern-agnostic: the admin Connector may hold either a user
PAT (for an account with `can_create_group`) or an umbrella group's
GAT (for orgs that centralise tenants under an umbrella). The end
state mirrors the shipped Harbor `harbor-connector-automatic-creation`
Task. Out of scope for this slice: image-pull Secret materialisation,
project-level (single-repo) tokens as the primary mode, per-group
access-level on one token, human user creation, ConnectorClass changes,
recommending an instance-admin admin Connector.

## Context

<!-- profile=standard: research collapsed inline -->

### Reference implementation already shipped (Harbor)

- `connectors-extensions/connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/`
  is the spec mirror. It established the Task contract (params,
  results, optional workspaces, three-step inline + helper-script
  pattern), the BDD shape (`script.feature` for Pod scenarios +
  `tektoncd.feature` for Task contract + e2e smoke), the non-root +
  multi-arch + resource-limit posture, and the operator-sync pipeline
  that bundles the Task into `connectors-operator/cmd/kodata/...` at
  release time.
- The prior design notes at `docs/en/design/connectors-auto-project/`
  (`tech-design.md`, `harbor.task-1.design.md`, `harbor.task-2.design.md`)
  document the decisions we inherit verbatim (two-Task pattern, tmpfs
  token hand-off, optional workspaces).

### Image strategy — REUSE catalog-shipped images

Per design-review (PR #997 review comments): **do not author a new
`gitlab-cli` Containerfile or tool-image ConfigMap**. Use the images
the catalog repo (`alaudadevops/catalog`) already ships:

- **`glab` image** for GitLab API steps. Path:
  `registry.alauda.cn:60070/devops/tektoncd/hub/glab:v1.82` (or
  `:latest`). Registered as the
  `catalog.tekton.dev/tool-image-glab` ConfigMap in `kube-public` by
  the catalog repo. Bundles `glab` (AlaudaDevops/GLab fork) + `bash`
  + `curl` + `git` + `jq` + `tar`. Runs as UID 65532. Multi-arch.
- **`kubectl` image** (also from catalog) for the cluster-apply step.
- **No new ConfigMap**, **no new Containerfile**. The Task references
  the existing tool-image ConfigMap in the same way the catalog
  `gitlab-cli` Task already does (`gitlabCliImage` descriptor uses
  `labelSelector=catalog.tekton.dev%2Ftool-image-glab`).
- The existing generic `gitlab-cli` catalog Task is **reused, not
  deprecated** — both Tasks share the underlying image through the
  same tool-image ConfigMap.

### Script-injection strategy — local render tool in connectors-extensions

Instead of using catalog's `tasklib` render contract (which would put
helper scripts under `catalog/tasklib/scripts/connectors-gitlab/` and
add a cross-repo dependency), this Task ships a **localised render
contract** owned by `connectors-extensions`. Scripts live next to the
Task they serve, the render tool lives in the same repo, and there is
no runtime init step.

1. **Source-of-truth scripts** live as plain `.sh` files at
   `connectors-extensions/connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/scripts/{lib,ensure-tenant-group,ensure-gat,apply-kubernetes-resources,write-results}.sh`.
   Reviewable, lint-able, and shellcheck-able like any other `.sh` file.
2. **Source-of-truth Task template** lives at
   `gitlab-connector-automatic-creation.template.yaml` next to the
   scripts. Each step's `script:` block contains
   `{{ INCLUDE: scripts/<name>.sh }}` placeholders rather than the
   actual bash bodies.
3. **`hack/render-task.sh`** (≤50 LOC; lives in
   `connectors-extensions`) reads the template, replaces each
   placeholder with the matching source file's body inline, and
   writes the rendered, shippable
   `gitlab-connector-automatic-creation.yaml`. Both the template and
   the rendered Task YAML are committed; CI re-renders and fails on
   drift.
4. **Runtime shape** is therefore Harbor's: each step's `script: |`
   block is fully self-contained inline bash. **No init step.** **No
   base64.** **No emptyDir-based script materialisation.** **No new
   image.** Steps run on the catalog `glab` and `kubectl` images
   directly (via `glabImage` and `kubectlImage` params, defaulting
   to the existing catalog tool-image ConfigMaps).

The rendered Task YAML is large but every line is plaintext bash —
easier to debug than base64 blobs. The template + scripts pair
remains the source-of-truth for review and edits.

**Why not Harbor's own-image approach?** Harbor builds a custom
`harbor-cli` image in `connectors-extensions/.../images/harbor-cli/`
because there is no upstream `harbor-cli` image to reuse. Catalog
already publishes `glab` and `kubectl`, so building a connectors-gitlab
image (even a script-only one) is positive marginal cost (Containerfile
maintenance, multi-arch CI matrix, trivy scans, registry storage) for
~0 functional gain. The render-tool approach achieves the same
"scripts owned by connectors-extensions, no catalog dependency"
outcome without any new image.

### Deployment patterns — the admin Connector identity decides

The Task itself does not know or care what kind of credential the
admin Connector carries. It only makes `glab` API calls and trusts
GitLab to enforce the resulting permissions. The two supported
patterns are deployment choices, not Task variants:

**Pattern A — top-level + `can_create_group` user (recommended for
greenfield self-hosted GitLab).**

- Admin Connector holds a **user PAT** for a dedicated GitLab user
  with the `can_create_group` flag enabled. The user is **not**
  instance-admin.
- `tenantGroup` is a top-level path (no slash), e.g. `acme`.
- The Task creates `acme` as a top-level group (the user becomes
  owner because it created the group) and any listed `subgroups`
  under it.
- The tenant GAT is issued at `acme` with the requested
  `accessLevel` and `scopes`.
- Blast radius if the admin user is compromised: every group this
  user owns. The user must therefore not own anything outside the
  intended tenant scope; the how-to page calls this out.

**Pattern B — umbrella + bot GAT (recommended for orgs that
centralise tenants under an umbrella, including SaaS GitLab).**

- Admin Connector holds a **GAT at the umbrella group** (e.g.
  `tenants`) with `owner` access level.
- `tenantGroup` is a subgroup path under the umbrella, e.g.
  `tenants/acme`.
- The Task creates `tenants/acme` as a subgroup of the umbrella (the
  umbrella's GAT is the inviter and acquires `owner` on the new
  subgroup) and any listed `subgroups` under it.
- The tenant GAT is issued at `tenants/acme` with the requested
  `accessLevel` and `scopes`.
- Blast radius if the umbrella GAT is compromised: the umbrella
  subtree only. Tighter than Pattern A.

**Pattern C — opportunistic onboarding under an existing org group.**
- Admin Connector holds a user PAT; user is `owner` on an existing
  group like `engineering`.
- `tenantGroup = engineering/payments`. Same code path as Pattern B,
  just with a user-PAT admin rather than a GAT.

The Task **does not** validate the admin identity type at param-parse
time. It makes the GitLab API call and surfaces GitLab's response
verbatim if the admin lacks the required permission (Pattern A
without `can_create_group`; Pattern B/C without `owner` on the
parent). This keeps the Task simple — GitLab is the only authority
on what the admin identity can do.

### Per-repo finding — connectors-extensions

- `connectors-gitlab/tektoncd/` does not exist yet. The subtree
  (`tektoncd/tasks/gitlab-connector-automatic-creation/0.1/` —
  containing `*.template.yaml`, the rendered Task YAML, `scripts/*.sh`,
  `samples/`, `testing/features/` —
  plus `tektoncd/kustomization.yaml`) is greenfield. The repo also
  gains `hack/render-task.sh` + `make render-tasks` Makefile target.
  **No `images/gitlab-cli/` directory** — `glab` and `kubectl` images
  are reused from catalog directly.
- `connectors-gitlab/config/connectorclass/connectorclass.yaml` already
  ships two CSI-mountable configurations: `gitlabconfig` and
  `gitconfig`. Auth type is `patAuth`; secret class is
  `connectors.cpaas.io/gitlab-pat-auth`. **Both user PATs and group
  GATs are valid `patAuth` credentials at this layer** — the same
  ConnectorClass serves both deployment patterns.
- No ConnectorClass change required for this feature.

### Per-repo finding — connectors-operator (this repo)

- Pipeline DOES need touches in this repo:
  - **`hack/sync_install_manifests.sh`** lists every Nexus component
    explicitly. Add one line:
    `sync_install_manifests "connectors-gitlab-tektoncd" "connectors-gitlab-tektoncd"`
    so `make manifests` pulls our Task install manifest.
  - **`values.yaml`** must contain a stub entry under
    `global.images.gitlab-connector-automatic-creation` (parallel to
    the existing Harbor entry); `hack/update_image_tags.sh` looks up
    components by repository and refuses to insert new entries.
- `cmd/kodata/connectors-gitlab-tektoncd/...` is auto-synced from
  Nexus by `make manifests` once the two changes above are in place.
  CLAUDE.md's "NEVER edit `cmd/kodata/`" rule still holds.
- `hack/sync_harbor_connector_automatic_creation_task_doc.sh` has a
  per-task doc-sync helper. We add a parallel
  `sync_gitlab_connector_automatic_creation_task_doc.sh` in Story 4.

### Risks (carried into the threat model)

- **Admin credential trust boundary.** Whether the admin Connector
  holds a `can_create_group` user PAT (Pattern A) or an umbrella GAT
  (Pattern B), compromise grants write access to whatever that
  identity owns. Mitigated by recommending the smallest-footprint
  identity per pattern and by keeping the credential inside the
  connectors-proxy CSI mount.
- **Long-lived Group Access Token.** The tenant GAT lives at
  `tenantGroup` with the requested `access_level` and `scopes`
  across the entire subtree. Compromise → writeable access to every
  subgroup. Mitigated by short default expiry, rotate-in-place
  pattern, and a documented refresh CronJob; tenant-side rotation
  cadence is the operator's responsibility.
- **Shared-image supply chain.** We trust the catalog `glab` and
  `kubectl` images. Supply-chain risk is now shared across every
  catalog Task, audited by the catalog repo's CI (trivy + digest
  pin) rather than by us.
- **GitLab tier compatibility.** Pattern A requires the
  `can_create_group` flag, which is a self-hosted GitLab feature.
  GitLab.com SaaS allows any user to create top-level groups, so
  Pattern A degrades naturally there (any user, with no special
  flag, suffices). Pattern B works identically on every tier.

## User-facing surface

### Tekton Task — params

- `glabImage` (string, required) — tool image, looked up from the
  `catalog.tekton.dev/tool-image-glab` ConfigMap (UI offers the same
  selector the catalog `gitlab-cli` Task uses).
- `kubectlImage` (string, required) — tool image for the cluster-apply
  step, looked up from the `catalog.tekton.dev/tool-image-kubectl`
  ConfigMap.
- `imagePullPolicy` (string, default `Always`).
- `connector` (string, required) — admin GitLab Connector ref as
  `<ns>/<name>`.
- `secret` (string, optional) — tenant Secret name; defaults to
  `<connector-name>-secret` and lands in the tenant Connector's namespace.
- `tenantGroup` (string, required) — the tenant's GitLab group full
  path. May be top-level (`acme`) or nested (`tenants/acme`,
  `engineering/payments`). Created if missing; reused if present and
  the admin Connector has `owner` on it.
- `subgroups` (array, default `[]`) — optional per-team subgroups
  under `tenantGroup`. May be relative names (`team-a`) or full paths
  (`acme/team-a`); both are normalised to full paths for creation.
- `accessLevel` (string, default `30` — Developer; values map to
  GitLab's standard set 10/20/30/40/50).
- `scopes` (array, required) — GAT scopes (e.g. `api`, `read_api`,
  `read_repository`, `write_repository`).
- `tokenName` (string, optional) — defaults to
  `connector-<ns>-<name>`; non-interactive bot identity.
- `tokenExpiry` (string, default `90d`) — capped at GitLab's
  configured maximum.
- `verbose` (string, default `false`).

> Param `parentGroup` is **renamed → `tenantGroup`** to reflect that
> it is the tenant's group itself, not a parent under which subgroups
> are created. The old name was a hold-over from the Harbor mirror;
> the new name maps cleanly to "one ACP project = one GitLab tenant
> group".
>
> Param `gitlabGroups` (array) is **renamed → `subgroups` and made
> optional**. Most ACP projects don't subdivide; per-team subgroups
> are an opt-in.
>
> Param `imagePullSecrets` (array) is **REMOVED** from this slice.

### Tekton Task — results

- `tenant-group` (string) — the tenant group's full path after reconcile.
- `subgroups` (array) — full paths of all subgroups present after reconcile (the union of `tenantGroup`'s direct children we touched).
- `access-token-name` (string) — the GAT id (not the secret value).
- `connector-ref` (string) — `<ns>/<name>` of the tenant `gitlab`
  Connector that was created or updated.

> Result `gitlab-groups` is **renamed → `tenant-group` (string)** + a
> new `subgroups` (array). Result `image-pull-secret-refs` is
> **REMOVED** from this slice.

### Tekton Task — workspaces

- `gitlab-config` (optional) — CSI mount of the admin Connector's
  `gitlabconfig` configuration (provides `glab` config + the admin
  PAT/GAT; the credential is never read out of the mount into the
  Pod environment).
- `kube-config` (optional) — kubeconfig file when running outside the
  cluster.

### Tool images — REUSED

- `registry.alauda.cn:60070/devops/tektoncd/hub/glab:v1.82` (and
  `:latest`) — catalog-owned. Discoverable via the
  `catalog.tekton.dev/tool-image-glab` ConfigMap in `kube-public`.
- `registry.alauda.cn:60070/devops/tektoncd/hub/kubectl:<tag>` —
  catalog-owned. Discoverable via
  `catalog.tekton.dev/tool-image-kubectl`.

### Operator-side pipeline wiring

- `hack/sync_install_manifests.sh` — one-line addition.
- `values.yaml` — one stub entry under
  `global.images.gitlab-connector-automatic-creation`.
- (Story 4) `hack/sync_gitlab_connector_automatic_creation_task_doc.sh`
  — new file mirroring the Harbor doc-sync helper.

### Doc pages

- `connectors-extensions/connectors-gitlab/docs/en/connectors/concepts/gitlab-cli-config.mdx` —
  new concept page covering the `glab` CLI configuration mount, the
  proxy auth flow, and how the admin credential stays inside the
  mount. Calls out that **both user PATs and umbrella GATs** are
  valid admin Connector credentials.
- `connectors-extensions/connectors-gitlab/docs/en/connectors/how-to/gitlab-auto-create.mdx` —
  new how-to with **two parallel deployment patterns**: Pattern A
  (top-level + `can_create_group` user) and Pattern B (umbrella +
  GAT). Each pattern walks through prerequisite setup, an end-to-end
  TaskRun example, the token-refresh CronJob pattern, and the
  manual cross-group-permissions workaround.

### Release-note line

To be drafted at `/feature:docs` for inclusion in
`connectors-operator-v1.11.0` release notes.

## Example usage

### Example 1 — Fresh creation (Pattern A: top-level + `can_create_group` user)

Onboarding tenant **acme**: create a top-level GitLab group `acme` plus
two per-team subgroups, issue a Group Access Token at `acme`, and land
a `gitlab` Connector + Secret in the `acme-prod` namespace.

**Prerequisite:** the admin Connector
`connectors-management/admin-gitlab-can-create-group` holds a user PAT
for an account with `can_create_group=true` (set by the GitLab
instance administrator; see how-to). The user is **not**
instance-admin.

```yaml
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: tenant-acme-fresh
  namespace: connectors-management
spec:
  taskRef:
    name: gitlab-connector-automatic-creation
  params:
    - name: glabImage
      value: registry.alauda.cn:60070/devops/tektoncd/hub/glab:v1.82
    - name: kubectlImage
      value: registry.alauda.cn:60070/devops/tektoncd/hub/kubectl:v1.30
    - name: connector
      value: connectors-management/admin-gitlab-can-create-group
    - name: tenantGroup
      value: acme                # top-level path → Pattern A
    - name: subgroups
      value:
        - team-a
        - team-b
    - name: accessLevel
      value: "30"                # Developer
    - name: scopes
      value:
        - api
        - read_repository
    - name: tokenName
      value: connector-acme-prod-gitlab
    - name: tokenExpiry
      value: 90d
    - name: secret
      value: acme-prod-gitlab-secret
  workspaces:
    - name: gitlab-config
      csi:
        driver: connectors.csi.alauda.io
        readOnly: true
        volumeAttributes:
          connector: connectors-management/admin-gitlab-can-create-group
          configuration: gitlabconfig
```

**Expected GitLab state after the TaskRun succeeds:**

- Group `acme` exists at the top level (created by the Task; the
  admin user is owner because it created the group).
- Group `acme/team-a` exists as a subgroup of `acme`.
- Group `acme/team-b` exists as a subgroup of `acme`.
- Group Access Token `connector-acme-prod-gitlab` exists at `acme`
  with `access_level=30`, `scopes=[api, read_repository]`,
  `expires_at=<now+90d>`. Its token id is recorded in result
  `access-token-name`.

**Expected cluster state after the TaskRun succeeds:**

- Secret `acme-prod-gitlab-secret` of type
  `connectors.cpaas.io/gitlab-pat-auth` in namespace `acme-prod`,
  containing the GAT value.
- Connector `acme-prod-gitlab` of type `gitlab` in namespace
  `acme-prod`, with `secretRef` pointing at the Secret above.
- Result `tenant-group` = `acme`.
- Result `subgroups` = `["acme/team-a", "acme/team-b"]`.
- Result `connector-ref` = `acme-prod/acme-prod-gitlab`.

### Example 2 — Fresh creation (Pattern B: umbrella + GAT)

Same tenant, different deployment pattern. The org has an umbrella
group `tenants` with a long-lived GAT carried by the admin Connector
`connectors-management/admin-gitlab-umbrella`. The admin Connector is
**not** a user PAT — it's a group GAT.

```yaml
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: tenant-acme-fresh-umbrella
  namespace: connectors-management
spec:
  taskRef:
    name: gitlab-connector-automatic-creation
  params:
    # ... same image params as Example 1 ...
    - name: connector
      value: connectors-management/admin-gitlab-umbrella
    - name: tenantGroup
      value: tenants/acme        # subgroup path → Pattern B
    - name: subgroups
      value:
        - team-a
        - team-b
    # ... same scopes/accessLevel/tokenName/tokenExpiry/secret as Example 1 ...
  workspaces:
    - name: gitlab-config
      csi:
        driver: connectors.csi.alauda.io
        readOnly: true
        volumeAttributes:
          connector: connectors-management/admin-gitlab-umbrella
          configuration: gitlabconfig
```

**Expected GitLab state:**

- Group `tenants/acme` exists as a subgroup of the umbrella `tenants`
  (the umbrella's GAT is the inviter; the new subgroup inherits
  `owner` from the GAT).
- Group `tenants/acme/team-a`, `tenants/acme/team-b` exist as
  sub-subgroups.
- GAT `connector-acme-prod-gitlab` issued at `tenants/acme`.

**Expected cluster state:** identical to Example 1 except
`tenant-group` = `tenants/acme` and `subgroups` =
`["tenants/acme/team-a", "tenants/acme/team-b"]`.

### Example 3 — Token refresh (rotate-in-place)

Run the same TaskRun (or schedule it as a CronJob) with **all params
unchanged** (works identically for Pattern A and Pattern B):

**Expected GitLab state:**

- Same tenant group, same subgroups (no creates).
- Same Group Access Token id `connector-acme-prod-gitlab`,
  `expires_at` advanced (rotate via
  `POST /groups/:id/access_tokens/:token_id/rotate`).
- The previous token value is **invalidated** by GitLab atomically.

**Expected cluster state:**

- Secret `acme-prod-gitlab-secret` updated in place
  (`resourceVersion` bumps; data field carries the new token).
- Connector `acme-prod-gitlab` unchanged (`resourceVersion` stable).
- Annotation `connectors.cpaas.io/gat-rotated-at` on the Secret
  updated to the rotation timestamp.

### Example 4 — Recreate on scope change

Change `scopes` from `[api, read_repository]` to `[read_api,
read_repository]` and re-run:

**Expected:**

- Old GAT id deleted from GitLab.
- New GAT created with the new `scopes`; new id recorded.
- Secret data rewritten with the new token value.
- Annotation `connectors.cpaas.io/gat-recreated-at` set.

### Example 5 — Add-subgroup reconcile

Add `team-c` to `subgroups` and re-run with all other params unchanged:

**Expected:**

- Missing subgroup created at `<tenantGroup>/team-c`.
- GAT rotated in place (subgroup-set drift is NOT identity-affecting;
  the GAT is at the tenant group and already covers the subtree).
- Result `subgroups` = `[..., "<tenantGroup>/team-a",
  "<tenantGroup>/team-b", "<tenantGroup>/team-c"]`.

### Failure example — Pattern A admin lacks `can_create_group`

Admin Connector's user PAT belongs to a user **without**
`can_create_group`, and the request asks for a top-level
`tenantGroup=acme`:

**Expected:**

- Step `ensure-gitlab` exits non-zero with
  `ERROR: admin user lacks 'can_create_group'; cannot create top-level GitLab group 'acme'. Either set the user's can_create_group flag on the GitLab instance, or use a subgroup tenantGroup (e.g. 'tenants/acme') under a parent the admin already owns.`
- No GitLab mutation. No cluster mutation.

### Failure example — Pattern B admin lacks `owner` on the parent

Admin Connector's GAT is at `tenants` but only has `maintainer`
access_level (not `owner`), and the request asks for
`tenantGroup=tenants/acme`:

**Expected:**

- Step `ensure-gitlab` exits non-zero with
  `ERROR: admin GAT lacks 'owner' on parent group 'tenants'; cannot create subgroup 'acme' under it.`
- No GitLab mutation. No cluster mutation.

## Operations runbook

The Story-3 how-to page owns the full operations guide; this section
sketches the scenarios it must cover so the doc author has a clear
acceptance bar. Each scenario is structured as: trigger → what the
Task does → operator action (if any) → monitoring signal.

### Token already expired (missed rotation window)

**Trigger.** Operator created the tenant Connector with
`tokenExpiry=30d` but the next rotation TaskRun did not run within
30 days (CronJob disabled, controller paused, weekend on-call
miss, etc.). On day 31+, GitLab has already expired the GAT.

**What the Task does.** On re-run, `ensure-gat.sh` reads the
existing GAT from `GET /groups/<tenantGroup>/access_tokens` and
detects `expires_at < now`. It logs
`WARN: existing GAT <id> is expired; falling through to recreate`
and switches from the rotate path to the **delete + recreate**
path automatically. GitLab's rotate endpoint would otherwise
return `400 invalid_grant` (token expired); we never call it.

**Outcome.** Same end state as a normal recreate: old GAT id is
gone (best-effort delete; GitLab also garbage-collects expired
tokens), new GAT is issued at `tenantGroup`, Secret is rewritten,
Connector annotation `connectors.cpaas.io/gat-recreated-at` is
set. The TaskRun reports `Succeeded`. **No manual operator
intervention required.**

**Operator action.** None for the immediate recovery. Long-term:
investigate why the rotation cron missed and tighten the alert
threshold below the expiry window (e.g. alert when stale-token
age exceeds `tokenExpiry - 7d`).

**Monitoring signal.** The how-to ships a PrometheusRule example
that fires on:
- `gat_age_seconds > tokenExpiry_seconds - 604800` (warn — 7
  days before expiry).
- `gat_age_seconds > tokenExpiry_seconds` (page — already
  expired; self-healing on next TaskRun, but tenant is reading
  stale credentials in the meantime).
- `gitlab_connector_automatic_creation_taskrun_status == "Failed"`
  for any reason (page).

### Token-refresh CronJob disabled or misconfigured

**Trigger.** Either someone disabled the CronJob, or the schedule
silently stopped firing (Tekton Trigger misconfig, paused
controller, etc.).

**What the Task does.** Nothing — the Task only runs when invoked.
The "missed rotation" failure mode above kicks in once expiry
arrives.

**Operator action.** Re-enable the CronJob; verify the next run
succeeds; review the alerting that should have fired.

### Tenant offboarding rollback

**Trigger.** Tenant `acme` is being decommissioned; the operator
wants to revoke GitLab access cleanly.

**What the Task does.** Out of scope for this slice — the Task
only creates and rotates. The how-to page recommends a manual
sequence: revoke the GAT via `glab api ... DELETE`; remove the
`acme` group via `glab api ... DELETE` (Pattern A) or rely on the
umbrella owner (Pattern B); delete the tenant Secret + Connector;
optionally remove the dedicated user (Pattern A only) if no
other tenants share it.

A future "tenant teardown" Task is a candidate follow-up; tracked
as a deferred ticket once tenant demand surfaces.

### Pattern-A user ownership audit

**Trigger.** Periodic compliance check (the Pattern A user
accumulates ownership of every group it creates, so its blast
radius grows over time).

**What the Task does.** Nothing — read-only audit. The how-to
ships a `glab api groups?owned=true&min_access_level=50` snippet
the operator can run on a schedule (or wire into a separate
audit Task as a follow-up).

**Operator action.** If the owned-groups list contains anything
the user is not supposed to own, escalate; otherwise no-op. The
audit is the visibility tool for T1's residual risk in the
threat model.

### Group-path conflict at fresh-creation time

**Trigger.** Operator chose `tenantGroup=acme` but `acme` already
exists at GitLab and is owned by someone else (not the admin
identity).

**What the Task does.** `ensure-tenant-group.sh` `GET /groups/acme`
returns 200, sees the admin identity is not in the owners list,
exits with
`ERROR: tenantGroup 'acme' already exists and admin identity is not an owner; rename or pick a different tenantGroup`.
No mutation on either side.

**Operator action.** Pick a different `tenantGroup` (e.g.
`acme-prod` or `tenants/acme`) or coordinate with the existing
group's owner.

## Out of scope

- **Image-pull Secrets generated from the tenant GAT.** Removed from
  this slice per design-review. Listed here so the next driver does
  not re-introduce it without an explicit decision.
- **Authoring a new `gitlab-cli` tool image.** The catalog repo
  already ships a `glab` image; this Task reuses it through the
  existing `catalog.tekton.dev/tool-image-glab` ConfigMap. The
  existing generic `gitlab-cli` catalog Task is **reused, not
  deprecated** — both share the same underlying image.
- **Recommending an instance-admin admin Connector.** Pattern A's
  `can_create_group` user and Pattern B's umbrella GAT are the two
  recommended deployment shapes. The Task does **not** require
  instance-admin. The how-to and the threat model both call this
  out explicitly.
- **Pre-creating the `can_create_group` user (Pattern A).** Setting
  up the dedicated user, enabling its `can_create_group` flag, and
  generating its PAT is operator deployment hardening (covered in
  the how-to page) rather than a Task-time concern. The Task fails
  cleanly if the admin Connector's PAT lacks the required permission.
- Project-level (single-repo) GitLab access tokens as the primary mode
  (deferred follow-up; tenant demand-driven).
- Per-group access-level on one token (option A — service-account user
  + PAT + per-group Membership). Manual workaround documented in the
  how-to page; promotion to a first-class option is deferred.
- Creating human user accounts or sending GitLab-side invitations.
- ConnectorClass changes (`gitlabconfig` and `gitconfig` already ship
  and cover the GitLab analogue of DEVOPS-43722).
- Editing operator `cmd/kodata/...` content. Pipeline wiring (one-line
  `sync_install_manifests.sh` entry + `values.yaml` stub) is in scope
  and lands in `connectors-operator`.
