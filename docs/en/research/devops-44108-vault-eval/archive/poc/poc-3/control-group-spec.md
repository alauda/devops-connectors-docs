# Vault Control Groups — Capability Spec (for the "if we had Enterprise" baseline)

> Sourced from `developer.hashicorp.com/vault/docs/enterprise/control-groups`
> and `developer.hashicorp.com/vault/api-docs/system/control-group`,
> retrieved 2026-05-22. **Not deployed in this PoC** — Enterprise license
> not available; spec collected for the gap comparison only.

## 1. What it is

Control Groups add **supplementary authorization** before a path read/write
succeeds. When a request triggers a control group, Vault returns a
**limited-duration response wrapping token** instead of the underlying
secret. Approvers must call `/sys/control-group/authorize` against the
token accessor before the original requester can `unwrap` to receive the
data. This is the only built-in workflow inside Vault OSS or Enterprise
that gates a secret read on out-of-band human approval.

## 2. Edition

> **Vault Enterprise** (or HCP Vault Dedicated). **Not available in OSS.**

## 3. Hypothetical policy (NOT applied in this PoC)

`prod-git-reader.hcl`:

```hcl
# Anyone bound to this policy can read secret/git/prod-* but only after
# a manager approves through the control group flow.
path "secret/git/prod-*" {
  capabilities = ["read"]
  control_group = {
    ttl = "4h"
    factor "release_manager" {
      identity {
        group_names = ["release-managers"]
        approvals   = 1
      }
    }
  }
}
```

`scoped-write.hcl` (operation-specific gating via `controlled_capabilities`):

```hcl
path "secret/registry/prod-*" {
  capabilities = ["read", "write"]
  control_group = {
    factor "admin" {
      controlled_capabilities = ["write"]   # reads pass; writes gate
      identity {
        group_names = ["security-admins"]
        approvals   = 2
      }
    }
  }
}
```

`group-config.json` (Vault identity group for approvers):

```json
{
  "name": "release-managers",
  "policies": ["control-group-approver"],
  "member_entity_ids": ["<entity-id-of-alice>", "<entity-id-of-bob>"]
}
```

## 4. Approver workflow (CLI / API only — no built-in UI for approvers)

1. **Requester triggers the gated read**
   ```
   vault read secret/git/prod-app
   ```
   Returns a wrapping token + `accessor`, plus instructions that the
   request is awaiting `N` approvals.

2. **Requester (or an integration) hands the accessor to approvers**
   — Vault has **no native notification fabric**; this is the integrator's
   responsibility (Slack/email/ticketing/Tekton/etc.).

3. **Approver authorizes**
   ```
   curl -X POST -H "X-Vault-Token: $APPROVER_TOKEN" \
     -d '{"accessor": "0ad21b78-e9bb-..."}' \
     https://vault.example.com/v1/sys/control-group/authorize
   ```
   Response: `{"data": {"approved": false|true}}`. Repeat for each
   required approver.

4. **Requester polls status**
   ```
   curl -X POST -H "X-Vault-Token: $REQUESTER_TOKEN" \
     -d '{"accessor": "0ad21b78-..."}' \
     https://vault.example.com/v1/sys/control-group/request
   ```
   Returns `approved`, `request_path`, `request_entity`, `authorizations[]`.

5. **Requester unwraps** once `approved=true`:
   ```
   vault unwrap <wrapping-token>
   ```
   Now receives the actual secret payload.

## 5. UX notes (verbatim observations)

- The Control Groups documentation references the API and tutorials but
  **does not describe a built-in approver UI**. The Vault Enterprise web
  UI surfaces some control-group state, but the documented workflow is
  CLI/API-driven and integrators are expected to build the notification
  + approval surface themselves.
- The status endpoint does not surface a `time_remaining` field;
  expiration is governed by the `ttl` declared in the policy.
- Approvers must possess their own Vault tokens with sufficient identity
  binding to be members of the approver group — i.e. **every approver
  needs a Vault identity**, not just a platform identity.

## 6. Gap mapped against Connectors

| Connectors mechanism | Equivalent Vault Enterprise piece | Notes |
|---|---|---|
| `AccessPolicy` selects which Connectors require approval | `control_group` block on a path policy | Vault binds gating to the **secret path**, not to "this Connector" — equivalent only after path-naming convention is engineered |
| `AccessRequest` CR is the auditable approval object | wrapping token accessor + `/sys/control-group/request` response | No K8s-native object; integrators must persist the audit trail themselves |
| Tekton `ApprovalTask` step lets approvers click in the **same PipelineRun UI** they are already watching | API call to `/sys/control-group/authorize` | No native Tekton integration — would need a custom Task that approvers cannot run directly (because they need *their own* Vault token, not the pipeline's) |
| Denial yields a CSI-mounted `.error.json` understandable to the running pod | TTL expiry or simply: pipeline blocks until manual abort | Vault has no client-side denial signal beyond timeout |

The structural gap is **not just "OSS lacks it"** — even Enterprise
Control Groups bind authorization to "fetching the credential", whereas
Connectors binds it to "using the credential through the proxy" and to a
running PipelineRun. Two different control planes.
