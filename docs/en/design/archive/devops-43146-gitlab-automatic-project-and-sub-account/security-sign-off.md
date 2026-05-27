# Security Sign-off — Gitlab automatic project and sub-account support using API and CLI

<!--
Required for risk=sensitive (the design-time `sensitive` overlay was
applied at /feature:init on 2026-05-06; reasoning recorded in
state.yaml.security.override).

This is the **pre-ship** sign-off — it covers the actually-shipped bundle
(RBAC delta, endpoint surface, image digests). The design-time sign-off
on threat-model.md was completed at /feature:design-review on 2026-05-06.

Per the threat-model.md footer: "the pre-ship sign-off may come from a
separate security-team reviewer if one is named at that point; otherwise
the same self-acting model applies, with the bundle digest recorded
explicitly in security-sign-off.md." No separate security-team reviewer
is named on this team's `security-reviewers.md` (template only contains
the unfilled stub row), so the self-acting model applies — Daniel signs
off here as the connectors-domain-owner with security-overlay, with the
bundle digest recorded below.
-->

## Bundle under review

- **Tag:** `v1.11.0-beta.146.g1aecd74`
- **Image digest:** `sha256:81bc56523b3c097da8247a09a0dda32c6b4da786c8665371b29c90e81d5c0396`
- **Image:** `build-harbor.alauda.cn/devops/connectors-operator-bundle:v1.11.0-beta.146.g1aecd74@sha256:81bc56523b3c097da8247a09a0dda32c6b4da786c8665371b29c90e81d5c0396`
- **Included manifest versions for this feature:**
  - `cmd/kodata/connectors-gitlab-tektoncd/1.0.0/install.yaml` — new (adds
    the `gitlab-connector-automatic-creation` Tekton Task)
  - `cmd/kodata/connectorsgitlab/1.0.0/install.yaml` — modified (adds a
    `connector_address` field to the existing `gitlabconfig` ConnectorClass
    rendered config template; data-additive only)

## Surface review

### Operator RBAC delta (vs v1.10.0)

```diff
# Across every kodata file under cmd/kodata/ (all 16 component dirs):
# git diff v1.10.0..HEAD -- cmd/kodata | grep '^[+-]kind:' | grep -i 'ClusterRole|Role|RoleBinding|ServiceAccount|Secret'
#
# Result: empty.
#
# - No new ClusterRole.
# - No new ClusterRoleBinding.
# - No new Role.
# - No new RoleBinding.
# - No new ServiceAccount.
# - No new Secret.
#
# The new `connectors-gitlab-tektoncd/1.0.0/install.yaml` ships exactly
# ONE resource: a Tekton `Task`. The Task itself runs at user-trigger
# time in a tenant namespace, under the tenant's own ServiceAccount —
# the operator does NOT pre-provision RBAC, ServiceAccounts, or Secrets
# for it. RBAC for the tenant SA to create TaskRuns and reference the
# admin Connector is the cluster-admin's responsibility, exactly as
# documented in the threat-model.md mitigations T8 and T10.
```

The operator's own ClusterRoles + ClusterRoleBindings (governing the
controllers) are unchanged across v1.10.0..v146.

### New exposed endpoints

**None.**

- The new Tekton Task does not expose any in-cluster Service or Ingress.
  It runs as a Pod in a tenant namespace, makes HTTP calls outbound to
  the existing connectors proxy Service of the admin Connector
  (`c-<connector-name>.<management-ns>.svc.cluster.local`), and writes a
  `Secret` + a `Connector` CR back to the connector namespace. No new
  listening ports or endpoints are introduced.
- The connectors proxy itself is unchanged in this slice — its endpoints
  and authn/authz model are inherited from the v1.10.0 surface.

### Third-party network egress introduced

**One — to the operator's already-allowlisted GitLab instance, via the
existing connectors-proxy egress path.**

| Destination | Purpose | TLS | Data sent |
|---|---|---|---|
| Configured GitLab API (e.g. `https://gitlab.example.com/api/v4/...`) — *via* the connectors proxy of the admin Connector | Group / subgroup creation; GAT issuance, rotate, revoke | TLS (validated against the admin Connector's `spec.address`) | Group create payloads (path/parent_id/name); GAT create payloads (name/scopes/access_level/expires_at); GAT rotate / DELETE calls. **Never** sends the tenant's Secrets, the admin PAT/GAT (which lives server-side in the proxy and is injected as `PRIVATE-TOKEN` by the proxy), or any cluster identifiers beyond what the operator chooses to put in the GAT name. |

The egress destination is **the same GitLab instance** the operator
already talks to via the existing tenant-side `gitlab` Connector usage
path (e.g. for the existing `glab` consumer workloads). No new
third-party DNS name is added to the egress allowlist by this feature.

## Findings

### Blocker findings

**None.**

### Non-blocker findings

1. **`security-reviewers.md` template is unfilled.** The team-policy
   list at `docs/en/design/templates/security-reviewers.md` still
   contains only the stub `{{id}}` row from when the template was first
   committed. This made it impossible to nominate a separate
   security-team reviewer at this gate; the self-acting model from the
   threat-model.md footer was used as the documented fallback. Action:
   follow-up PR to populate the active-reviewers list (out of scope
   for this feature; track separately).

2. **Audit alert on Pattern A user's owned-groups count (T1c) is
   documented but not implemented.** The how-to documents the alert
   shape (PrometheusRule example), but the alert isn't shipped as part
   of this bundle — it remains the cluster admin's responsibility to
   configure per their existing observability stack. Accepted residual
   per the threat-model.md residual-risk section ("Pattern A
   user-ownership drift").

3. **Pattern B GAT rotation (the umbrella GAT itself, not the tenant
   GAT) is out of scope for this slice.** The threat-model.md flags
   this as "a follow-up Task" under T2(b). This is consistent with the
   feature scope and is not a new finding here — restating only so
   that the next feature in the epic (DEVOPS-42609) tracks it.

4. **Connectors proxy + admin-credential-injection model is the trust
   root.** This was already true before this feature (the proxy is
   shared infrastructure across all connector Tasks, including the
   v1.10.0 Harbor analogue). This feature does not change the proxy
   architecture; it merely uses it. Restated here so that the auditor
   trail for this feature includes the dependency.

## Decision

**approved**

## Reviewer

- **Name:** Daniel Morinigo
- **Role:** Driver + connectors-domain-owner with security-overlay
  (per threat-model.md footer; self-acting per documented fallback)
- **Security label:** connectors-domain-owner (no separate
  security-team label is configured on this team's
  `security-reviewers.md`)
- **Date:** 2026-05-14
- **Rationale:** The pre-ship bundle introduces zero new operator
  RBAC, zero new exposed endpoints, and one third-party egress to an
  already-allowlisted GitLab instance via the existing connectors-proxy
  path. The new asset surface (admin Connector credential, tenant GAT,
  tmpfs token hand-off) was already analysed in threat-model.md and
  the corresponding mitigations T1–T10 are all in place and verified
  by /feature:qa (11/11 ACs passed live on `daniel-5shk6` against this
  exact bundle digest, including the F1 jq-on-error guard and F2
  idempotent-rerun behaviour that affect the GAT-handling code path).
  The two non-blocker findings (unfilled `security-reviewers.md`,
  Pattern A audit-alert deferred to cluster-admin) are pre-existing
  team-policy items, not feature-introduced risks. Pattern B
  umbrella-GAT rotation is intentionally out of scope per the
  threat-model.md and the epic's Story-N planning.

  The threat-model.md footer's documented fallback (self-acting when
  no separate security-team reviewer is named) is followed verbatim,
  with the bundle digest recorded above as required.
