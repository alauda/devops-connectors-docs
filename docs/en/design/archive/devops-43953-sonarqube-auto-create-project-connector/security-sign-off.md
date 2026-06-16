# Security Sign-off — DEVOPS-43953 SonarQube auto-create

<!--
Required for risk=sensitive. Produced by /feature:security-sign-off.
Threat model source: threat-model.md (10 threats, mitigations,
residual risk — reviewed at /feature:design-review).
-->

## Bundle under review

- **Tag:** `v1.11.0-beta.183.gd204e0e`
- **Image digest:** `sha256:f9327e7250cec686ddcb4cf691a52fc1c10189a7f8f6b370daf81576ae81598f`
- **Included manifest versions:**
  - `sonarqube-connector-automatic-creation` Task v0.1 (extensions Task image v1.9.0-g8632398, pinned in `values.yaml`)
  - 7 paths shipped via `cmd/kodata/...`, `docs/en/connectors-sonarqube/...`, `hack/`, `mk/`, `values.yaml` (see `state.yaml.bundle.synced_manifests`)

## Surface review

### Operator RBAC delta (vs previous bundle)

No RBAC delta. The feature adds a Tekton Task; the operator's existing
cluster roles cover catalog Task discovery and InstallManifest reconciliation,
both of which already had permissions before this feature. The Task itself
runs inside user-managed Tekton pipelines and uses a user-provisioned
ServiceAccount (driver chooses the account when creating the TaskRun), so
no operator-managed RBAC primitive is added.

```diff
(no rbac changes)
```

Verification: `git diff upstream/main~10..upstream/main -- 'cmd/kodata/connectors-operator/**'`
shows no role / clusterrole / rolebinding changes attributable to PR #1211
or PR #325. The new install.yaml for `connectors-sonarqube-tektoncd` ships
the Task definition only — no `ServiceAccount`, `Role`, `RoleBinding`,
`ClusterRole`, or `ClusterRoleBinding` resources.

### New exposed endpoints

None. The Task does not run a server; it executes scripted SonarQube Web
API calls inside its TaskRun pod and exits.

### Third-party network egress introduced

| Destination | Purpose | TLS policy | Data sent |
|---|---|---|---|
| SonarQube admin endpoint (driver-supplied via the admin `Connector`'s `spec.address`) | API calls: `api/users/create`, `api/permissions/add_user`, `api/permission_templates/{create,add_user,add_group_to_template,search,update_default_template}`, `api/user_tokens/{generate,revoke}`, `api/measures/component` (read in the e2e scan verification only) | https (verified against deployed CAs; bypass requires explicit `caCertSecret` workspace mount per `product-design.md` §5.3) | admin bearer token in `Authorization` header; user-creation payload (username, full name); permission-template payload (regex pattern, template-permission set); user-token request (name, expiry date computed at step time) |

No other egress. The Task does not call out to telemetry, analytics, or
any third-party service.

## Findings

### Blocker findings

None.

### Non-blocker findings

- **NB-1 — Admin bearer token is in process environment during Task
  execution.** The admin token is mounted via the admin `Connector`'s
  Secret as a workspace, sourced into `Authorization` headers for the
  duration of the Task. Mitigation: workspace is `medium: Memory`
  (tmpfs); token never persists to disk. Process listing on the pod
  could surface the token if a sidecar were injected, but Tekton's
  default pod-security profile blocks sidecar injection by adversarial
  controllers. Accepted by design (threat-model.md threat T-3,
  residual-risk section).

- **NB-2 — Tenant USER_TOKEN written into Kubernetes `Secret` in the
  Connector namespace.** This is the intended product surface (the
  whole point of the Task), but it does mean an adversary with read
  access to that namespace can extract the token. Mitigation: standard
  Kubernetes RBAC at the Connector namespace; the same protection
  model that applies to every other connector's bearer-token Secret
  (Harbor, GitLab, Nexus, etc.). Accepted by design (threat-model.md
  threat T-5).

- **NB-3 — `tokenDuration` (days) computed at step time as `today UTC + N
  days`.** Adopted at design-review R1 to avoid writing absolute dates
  into Pod spec / TaskRun YAML. **Strictly an improvement** over the
  earlier `tokenExpiry` proposal: credential-lifetime info-leak surface
  shrinks (lifetime is no longer visible in TaskRun YAML / Pod env /
  process args), and cron re-runs auto-extend without driver action.
  Recorded as positive note rather than risk.

### Defense-in-depth observations (informational)

- Token cleanup on rollback uses `api/user_tokens/revoke` (not just
  Secret deletion) — verified in `script.feature` case #4 + #11.
- The Task script set never includes the admin token in error output
  (logs are pre-sanitised through `lib.sh` helpers); failed steps
  expose SonarQube error JSON verbatim but not the bearer token.
- Project visibility is enforced via the SonarQube instance's `Private`
  default (preflight P1); the Task does not need to set per-project
  visibility because the instance default takes effect at scan-time
  auto-creation.

## Decision

**approved**

## Reviewer

- **Name:** kychen
- **Security label:** driver-async-sensitive (Discord-async-driver convention; same as design-review approved entry — driver acts as security reviewer + per-repo owner. The `security-labeled signature is deferred to the dedicated /feature:security-sign-off stage` waiver recorded in maturity.entries at design-review approved is now consumed by this signature.)
- **Date:** 2026-06-02T11:04:00Z
- **Rationale:** Reviewed the 10 threats in `threat-model.md` against the
  bundle as built. All 10 mitigations remain in place: tmpfs token
  handling (T-3), tenant-token Secret RBAC (T-5), preflight P5 admin
  scope gating (T-1), permission-template `projectKeyPattern` isolation
  (T-2), Private visibility instance default (T-4), `apply-kubernetes-
  resources` SSA field manager `connector-auto` (T-6), revoke-on-rollback
  (T-7), no telemetry/analytics egress (T-8), no operator RBAC delta
  (T-9), and the design-review-R1 `tokenDuration` change actively
  reduced T-10's info-leak surface. No new threats surfaced during
  implement, integrate, qa, accept, regress that were not already
  enumerated. Residual-risk acceptance unchanged from threat-model.md.
  Bundle clears the risk=sensitive gate.

  Three non-blocker findings (NB-1, NB-2, NB-3) are inherent to the
  product surface, not introduced by this feature; documented for
  audit traceability rather than as actionable items.
