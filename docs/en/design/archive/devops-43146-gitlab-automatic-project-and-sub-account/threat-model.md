# Threat Model — Gitlab automatic project and sub-account support using API and CLI

<!--
Required for risk=sensitive. Reviewed at /feature:design-review by a
security-labeled reviewer.
-->

## Assets

- **Admin GitLab credential** — either a user PAT (Pattern A — for an
  account with `can_create_group`) or a group GAT (Pattern B — at an
  umbrella group with `owner` access). Lives inside the admin
  Connector's CSI mount (`gitlabconfig`); never read into Pod env.
  Compromise grants access to whatever the identity owns:
  - Pattern A: the dedicated user's owned groups (bounded by the
    user's group-ownership footprint).
  - Pattern B: the umbrella subtree only.
  Instance-admin is **not** a recommended deployment shape and is
  explicitly out of scope for this slice.
- **Group Access Token (GAT) at `tenantGroup`** — write access to the
  tenant subtree with the requested `scopes` + `accessLevel`. Issued
  by the Task; written into the tenant Secret in the connector
  namespace.
- **Tenant `gitlab` Connector secret** (`connectors.cpaas.io/gitlab-pat-auth`) —
  what tenant workloads consume to talk to GitLab; cluster-readable
  per RBAC on its namespace.
- **Tmpfs token hand-off file** — `/workspace/secrets/token` on an
  in-memory `emptyDir`; ephemeral but readable by every container in
  the Task Pod for the duration of the run.

> **Removed asset:** "GitLab Container Registry image-pull Secrets"
> — this slice no longer mints those, so they are no longer an asset
> the Task is responsible for. If a follow-up Task introduces them,
> re-add and re-evaluate.

## Actors

### Legitimate

- **Platform engineer** — submits the TaskRun; selects `tenantGroup`,
  `subgroups`, `scopes`, `accessLevel`. Holds RBAC to create
  TaskRuns referencing the admin Connector.
- **Pattern A admin user** — a dedicated GitLab user with
  `can_create_group` enabled. **Not** instance-admin. Created
  out-of-band by the GitLab instance administrator per the how-to
  page's Pattern A setup guide. The admin Connector holds this user's
  PAT.
- **Pattern B umbrella owner** — the human or system that originally
  created the umbrella group and minted its GAT (with `owner` access)
  for the admin Connector. Out-of-band setup; the Task only consumes
  the GAT.
- **Operator** (out-of-band) — reconciles the tenant Connector once
  the Task creates it; consumes the tenant Secret for proxy bootstrap.
- **Tenant workload** — consumes the tenant Connector + Secret via
  the connectors proxy; never sees the admin credential.

### Adversarial

- **Co-tenant on the same cluster (lateral movement)** — has RBAC in a
  neighbouring namespace; wants to read the tenant Secret to access
  GitLab on someone else's behalf.
- **Compromised tenant workload** — already holds the tenant GAT;
  wants the admin credential (privilege escalation); wants the GAT to
  survive rotation (persistence).
- **Pattern A admin user takeover** — attacker compromises the
  dedicated `can_create_group` user (e.g. PAT leak from a misplaced
  CI log). Gets ownership over every group that user already owns.
  Bounded but non-trivial.
- **Pattern B umbrella GAT leak** — attacker exfiltrates the
  umbrella's GAT. Gets `owner` on the umbrella subtree.
- **Sidecar / debug-pod operator** — has `pods/exec` or
  shareProcessNamespace in the Task's namespace; scrapes the tmpfs
  token file mid-run.
- **Catalog supply-chain attacker** — compromises the catalog `glab`
  or `kubectl` image (or one of their pinned base images); gains
  code-exec inside any Task Pod that uses the catalog tool images.
- **Misled platform engineer** — social-engineering victim convinced
  to submit a TaskRun with a `tenantGroup` value that's not the
  intended tenant (e.g. an attacker's "tenant" name). The Task does
  the right thing by GitLab semantics; the attack lives at the
  TaskRun-author layer.

## Threats

| # | Threat | Affected asset | Likelihood | Impact |
|---|--------|----------------|------------|--------|
| 1 | Pattern A admin user takeover (PAT leak from CI log, etc.) | All groups the user owns | low | medium-high |
| 2 | Pattern B umbrella GAT leak | Umbrella subtree | low | medium |
| 3 | Admin credential logged or echoed from a step's stdout (especially with `verbose=true`) | Admin credential | low | high |
| 4 | GAT written to a Secret in the wrong namespace (typo in `secret` param) | GAT | low | medium |
| 5 | Compromised tenant workload exfiltrates its GAT and replays it after a rotation cycle | GAT | medium | medium |
| 6 | Token-refresh CronJob disabled or misconfigured — GAT expires under load | tenant connection availability | medium | low |
| 7 | Catalog `glab` or `kubectl` image is replaced with a malicious one (shared supply chain) | All assets | very low | high |
| 8 | Sidecar or `pods/exec` operator scrapes the tmpfs token file mid-run | GAT (in transit) | low | high |
| 9 | Step 1 succeeds at GitLab but step 2 fails at the cluster — orphaned GAT exists on GitLab without a tenant consumer | GAT | medium | low |
| 10 | Misled platform engineer submits a TaskRun for the wrong `tenantGroup` (social-engineering / typo) | Tenant boundary integrity | low | medium |

> **Removed threat (was T1 in v2 — "TaskRun parameters point
> `parentGroup` at an unrelated group"):** GitLab natively prevents
> this. Both Pattern A and Pattern B fail closed when the admin
> identity lacks the required permission on the path being requested
> (Pattern A: not `can_create_group`; Pattern B/C: not `owner` on the
> parent). The Task surfaces the failure verbatim. The remaining
> social-engineering surface is captured in the new T10.
>
> **Removed threat (was T6 in v1):** "Concurrent TaskRuns race
> server-side-apply on the same imagePullSecret." Not applicable —
> image-pull Secrets are out of scope. The remaining
> server-side-apply path (Connector + Secret) writes resources owned
> by this Task only; race risk is negligible.
>
> **Downgraded threat (was T7 in v1):** "gitlab-cli image
> supply-chain (malicious base)." We no longer author a per-Task
> Containerfile; we depend on the catalog `glab` and `kubectl`
> images, which run trivy + digest pinning in catalog CI. Likelihood
> drops from `low` to `very low` (now T7 in v3); impact unchanged.

## Mitigations

| # | Threat | Planned mitigation | Lives in | Owner |
|---|--------|--------------------|----------|-------|
| 1 | T1 | (a) The Pattern-A user's group-ownership footprint must be intentionally minimised — how-to recommends "the user owns nothing pre-existing; it only owns groups the Task creates". (b) Standard PAT hygiene: short rotation cadence; recommend external secret storage (Vault, KMS); CI logs scrubbed for PAT patterns. (c) Audit alert on the user's owned-groups count to detect drift. | how-to docs (Pattern A setup); ops runbook | docs author + cluster admin |
| 2 | T2 | (a) Umbrella GAT issued at `owner` access only — never above. (b) Same rotation discipline as the tenant GAT; the umbrella GAT itself is rotated by a separate scheduled TaskRun (out of scope here; a follow-up Task). | how-to docs (Pattern B setup) | docs author |
| 3 | T3 | Helper scripts (`connectors-gitlab/tektoncd/tasks/.../0.1/scripts/*.sh`) use `set +x` by default, never echo PAT/GAT, never `cat` the tmpfs token file. `verbose=true` enables shell tracing only on non-secret steps. PR review checklist: grep for echo/printf of `$TOKEN`. | connectors-extensions `connectors-gitlab/tektoncd/tasks/.../0.1/scripts/{ensure-gat,apply-kubernetes-resources}.sh`; PR review checklist in CONTRIBUTING | implementer + reviewer |
| 4 | T4 | `secret` defaults to `<connector-name>-secret` and is created in the connector's namespace (not the TaskRun namespace). `apply-kubernetes-resources.sh` validates the namespace exists and matches the connector's namespace before any apply. | connectors-extensions `connectors-gitlab/tektoncd/tasks/.../0.1/scripts/apply-kubernetes-resources.sh` | implementer |
| 5 | T5 | Two-path refresh ensures rotate-in-place invalidates the old token at GitLab via `POST /groups/:id/access_tokens/:token_id/rotate`. The how-to documents the rotation cadence and recommends an alert on stale-token age. | connectors-extensions `connectors-gitlab/tektoncd/tasks/.../0.1/scripts/ensure-gat.sh`; how-to docs | implementer + docs author |
| 6 | T6 | How-to provides a CronJob template with retry + alert on rotation failure; PrometheusRule example for stale-token age. CronJob is the operator's responsibility, not the Task's. | how-to docs | docs author |
| 7 | T7 | Pin to a specific `glab` and `kubectl` image **tag** in the Task's `glabImage` and `kubectlImage` defaults; rely on the catalog repo's CI (trivy + digest pin) for upstream supply-chain monitoring. Document in CONTRIBUTING that bumping the image tag requires re-running the smoke BDD. | Task YAML param defaults; catalog repo CI; CONTRIBUTING | implementer + catalog maintainer |
| 8 | T8 | Pod template sets `emptyDir.medium=Memory`, runs as non-root UID 65532, declares no `shareProcessNamespace`, no debug sidecars. `apply-kubernetes-resources.sh` `rm -f` the tmpfs token file at the end of step 2. Cluster RBAC on `pods/exec` in the Task's namespace is the operator's responsibility. | Task podTemplate; how-to docs | implementer + cluster admin |
| 9 | T9 | Re-run the Task: step 1 detects the existing GAT id and hits the rotate path; step 2 retries the cluster apply. The how-to documents this retry stance and recommends a Tekton retry policy. | how-to docs | docs author |
| 10 | T10 | (a) The TaskRun's `connector` parameter is the natural permission boundary — only platform engineers with RBAC to reference the admin Connector can run the Task. (b) How-to recommends a per-tenant ServiceAccount with namespace-scoped `taskruns/create` RBAC, so a typo on `tenantGroup` from one tenant's TaskRun cannot affect another tenant's resources at the cluster layer (the GitLab side is still bounded by the admin identity's owned scope). (c) Pattern A user's bounded ownership (T1 mitigation a) limits the GitLab-side blast radius even when the wrong `tenantGroup` is supplied. | how-to docs; cluster RBAC | docs author + cluster admin |

## Residual risk

- **A platform engineer with TaskRun-create RBAC can still target an
  admin Connector they shouldn't access.** Accepted because the admin
  Connector itself is the RBAC boundary; the how-to recommends a
  per-tenant ServiceAccount with namespace-scoped TaskRun-create RBAC.
  Re-evaluate at the first audit incident.
- **Shared-image supply-chain risk.** Catalog `glab` and `kubectl`
  images are the trust roots. Accepted because (a) those images are
  also exercised by every other catalog Task and so receive broad
  attention, (b) the catalog repo runs trivy + digest pinning, and
  (c) the alternative (forking and maintaining our own image) would
  add a maintenance burden without measurably reducing risk.
- **Orphaned GAT after a step-2 failure** (T9) leaves a usable token
  at GitLab. Accepted because rerunning the Task immediately
  invalidates it via rotate-in-place; how-to documents the retry
  stance. If the operator never reruns, the token still expires per
  `tokenExpiry`.
- **Pattern A user-ownership drift.** Over time, the dedicated
  `can_create_group` user accumulates ownership across many
  Task-created groups. The audit alert from T1(c) is the operator's
  visibility tool; the Task itself does not enforce a cap. Accepted
  because capping would require coordinating across many TaskRuns and
  is better solved by a separate group-ownership-audit Task.

## Reviewer

- **Name:** Daniel Morinigo (driver, self-acting for design-time security review)
- **Role:** Security reviewer (design-review gate)
- **Security label:** connectors-domain-owner with security-overlay
- **Sign-off date:** 2026-05-06

**Note.** This sign-off covers the **design-time** threat model only —
that the threats listed are realistic, the mitigations match the threat
shape, and the residual risks are acceptable for the design. The
**pre-ship** security gate at `/feature:security-sign-off` will require
a fresh sign-off against the actually-shipped bundle (RBAC delta,
endpoint surface, image digests). That sign-off may come from a
separate security-team reviewer if one is named at that point;
otherwise the same self-acting model applies, with the bundle digest
recorded explicitly in `security-sign-off.md`.
