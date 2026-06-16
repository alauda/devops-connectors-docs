# Feasibility & UX Assessment — Vault OSS approximation of Control Groups

## What the PoC actually proved

Three pipelines, one namespace, ~150 lines of YAML, and two ad-hoc human
patches drove dev/approve/reject all the way through. So the **mechanism
is technically sound**: ConfigMap-as-status-bus + `manual-approval-gate`
ApprovalTask + gating step works, and the secret read happens **only**
when the approval status reaches `approved`.

But "technically sound" is the floor, not the ceiling for an enterprise
governance feature. The honest assessment is below.

## Engineering cost of the OSS approximation

| Component | Provenance | What it costs to own |
|---|---|---|
| `vault-approval-decisions` ConfigMap | PoC-local convention | Schema is implicit; key collisions across teams must be policed; no concurrency control; needs TTL/janitor |
| `vault-request-secret` Task | Custom Tekton Task | Trivial today; will grow request-context (who/why/risk class) for audit |
| `vault-bridge-approval` Task | Custom Tekton Task — controller in a shell script | Has to know the convention for CustomRun name (`<pr>-<taskName>`) and the controller's pending/approved/rejected vocabulary; brittle on every upstream upgrade |
| `vault-fetch-and-use-secret` Task | Custom Tekton Task with built-in gate poll | Gate poll uses unauthenticated ConfigMap read; any pod in the ns can flip it |
| RBAC | 1 Role + 1 RoleBinding | Tight bus access requires per-team ConfigMap split (current design is single shared CM) |
| `manual-approval-gate` operator | Upstream Tekton component | Approver list is **inlined** in pipeline YAML; webhook validates against authenticated user only — no group resolution |
| Audit | Whatever K8s audit + Tekton logs capture | No first-class `AccessRequest`-equivalent CR; must be reconstructed by joining ConfigMap revisions + CustomRun events |

Realistic engineering needed to make this a productized feature:

- **Define a CRD** to replace the ConfigMap bus (so each request has an
  owner, TTL, requester identity, audit trail, RBAC per request).
- **Build a controller** that subscribes to ApprovalTask events and
  reconciles bus state — i.e. re-implement the bridge in Go.
- **Build an IAM resolver** to translate platform groups → approver
  username list at pipeline render time.
- **Build a notification surface** (Slack/email/wechat-work) since the
  ApprovalTask UI is the only place a human currently sees the request.
- **Wire Vault Kubernetes Auth role mapping** to deny anonymous access
  to gated paths even if the gate is bypassed, so the gate is **not**
  the sole defense.

That's roughly the surface of `AccessPolicy` + `AccessRequest` + the
Connectors UI plumbing — **i.e. we'd be reimplementing 60-70% of what
already exists in Connectors**, on top of Vault, for no net gain.

## UX gap vs Connectors native flow

| Dimension | Connectors `AccessPolicy` + `AccessRequest` + `ApprovalTask` | OSS approximation (this PoC) | Vault Enterprise Control Groups |
|---|---|---|---|
| Where does an approver see the request? | Tekton PipelineRun UI in ACP DevOps — same screen they already use | Same Tekton UI for the ApprovalTask, **but** the link to "which Vault read is being gated" is implicit (request-id string) | Vault Web UI shows control-group state, but approver must authenticate to Vault separately and use CLI/API to authorize |
| What does the approver *do*? | Click Approve in the running PipelineRun | Click Approve in the running PipelineRun | `vault write sys/control-group/authorize accessor=...` — no native click |
| Notification | Hooked into ACP notification framework via `AccessRequest` events | None built-in; would need separate watchers on the ApprovalTask | None built-in |
| Audit object | First-class `AccessRequest` CR, K8s-native, durable | ConfigMap revision history + Tekton CustomRun status — must be joined manually | Vault audit log entries on `/sys/control-group/*` paths |
| Gate granularity | Per Connector instance, per scope (kube-public / ns-group / ns) | Per pipeline + per-request-id (custom convention) | Per secret path (HCL `path` glob) |
| Where the gate is applied | "Use the proxy at request time" — gate is on traffic | "Fetch the credential" — gate is on the read; once fetched, no further enforcement | "Fetch the credential" — same shape as the OSS approximation |
| Denial signal | CSI mount has `.error.json`; downstream code sees a structured error | Pipeline TaskRun fails with the bridge's `exit 1`; downstream tooling sees Tekton fail | TTL expiry of wrapping token; client gets `wrapping token expired` |
| Air-gap-friendly | Yes — only ACP + Tekton needed | Yes — only Tekton + Vault dev-mode equivalent | Yes — Vault Enterprise itself is on-prem, but requires Vault Enterprise binary delivery + license validation |

The single biggest UX difference is **where the approver lives**. In
Connectors, the approver is already in the PipelineRun UI; in the OSS
approximation they are too (for the ApprovalTask itself), but the gate
target ("you are approving a Vault read of `secret/git/prod-...`") is
encoded only by convention in a string the approver typed into the
PipelineRun param. There is no first-class object equating "this
approval = that secret read".

## Acceptance in Alauda customer scenarios

**Financial / state-owned enterprises** (the bulk of Connectors' real
deployments):

- These customers' compliance officers expect **a first-class audit
  object** for each privileged-credential access: who requested, who
  approved, what was approved, when. ConfigMap revision history will not
  pass an internal audit; Vault audit log + Tekton CustomRun status
  cannot be cross-referenced by a non-engineer.
- The Vault Enterprise license itself is a **procurement risk** for
  state-owned customers (HashiCorp now under IBM ownership; license
  delivery to China-mainland customers is uncertain post-2024). The OSS
  approximation avoids that, but **only by spending engineering effort
  that produces an inferior outcome**.

**SRE learning cost**:

- Connectors: a CRD per kind, a small RBAC story, one UI surface. SRE
  treats it the same as any other ACP component.
- OSS approximation: Vault (a separate stateful system with unseal
  rituals) + custom Tekton Tasks + a ConfigMap convention + an upstream
  Tekton component (`manual-approval-gate`) the SRE has not seen before.
  At least three concept layers more than today's Connectors.

**Audit closure**:

- Connectors closes the audit loop inside ACP IAM + Tekton + CSI.
- OSS approximation forces a three-way join (Vault audit logs + Tekton
  PipelineRun status + ConfigMap revision history) that auditors must
  trust to be tamper-evident — it isn't, by construction (any namespace
  member with patch on the ConfigMap can flip an entry).

## One-line rating

> **The OSS-equivalence path is technically feasible but its production
> UX is materially worse than what Connectors already ships, and even a
> serious investment in productizing it lands us roughly where Vault
> Enterprise Control Groups would — at which point we have spent
> engineering effort to land in a worse place. Recommendation: do not
> pursue this path; if "Vault-backed approval" is ever required, the
> only credible route is Vault Enterprise + a new integration layer, and
> that integration layer is essentially a second implementation of
> `AccessPolicy`/`AccessRequest`.**
