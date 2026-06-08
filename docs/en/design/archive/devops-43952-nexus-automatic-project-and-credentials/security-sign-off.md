# Security Sign-off — Nexus 自动创建 Project + Connector + Secret

<!-- Output of /feature:security-sign-off. risk=sensitive. -->

## Bundle under review

- **Tag:** `v1.11.0-beta.173.g15aaded`
- **Image digest:** `sha256:34827db4667b5f2fc87c89aa6cb2441c6e247e048566c90dd0e1cf5aea16f37d`
- **Included manifest versions:**
  - `cmd/kodata/connectors-nexus-tektoncd/1.0.0/install.yaml` — adds the
    `nexus-connector-automatic-creation` v0.1 Tekton Task + the two
    `catalog-tool-image-*` ConfigMaps (v0.1 and `latest`).
  - `cmd/kodata/connectorsnexus/1.0.0/install.yaml` — ConnectorClass icon
    annotation patch (no schema change).

## Surface review

### Operator RBAC delta (vs previous bundle)

No new RBAC. The bundle adds a `tekton.dev/v1.Task` and two `v1.ConfigMap`
catalog-tool-image entries. The Task runtime SA (`connectors-management/automation-sa`)
is deployment-side and pre-existed for the Harbor sibling.

```diff
# Bundle-level diff (cmd/kodata/*/install.yaml):
+ tekton.dev/v1.Task/nexus-connector-automatic-creation
+ v1.ConfigMap/catalog-tool-image-nexus-connector-automatic-creation-0.1
+ v1.ConfigMap/catalog-tool-image-nexus-connector-automatic-creation-latest
~ connectors.alauda.io/v1alpha1.ConnectorClass/nexus  (annotation tekton.dev/icon set; no spec change)
# No (Cluster)Role / (Cluster)RoleBinding / ServiceAccount added at the bundle layer.
```

### New exposed endpoints

None. The Task is invoked synchronously from a `TaskRun`; it does not
register a Service, Route, Ingress, or webhook. All I/O is in-Pod against
the caller-supplied Nexus endpoint and the K8s API via the caller SA.

### Third-party network egress introduced

- **Caller-configured Nexus instance** (`nexusEndpoint` param) — HTTPS,
  basic-auth from the admin Connector's CSI-mounted Secret, only writes
  `user/role/privilege/repository` REST objects under the caller's
  `pathPrefix`. The destination is the customer's own Nexus; no Alauda
  infrastructure is contacted. Same trust model as the existing
  `nexusconfig` ConnectorClass.
- **Task image pull** at install time — `connectors-nexus-tools` image from
  the bundle's configured registry mirror. No internet egress required
  (air-gap safe).

## Findings

### Blocker findings

None. All `BLOCKING` and `IMPORTANT` items raised by the two-tier
project + team reviews (rounds v1 and v2 against `dadbd4b` and `c5808a7`)
have been resolved in the merged PR #332:

- B1 (xtrace leak via in-loop `set -x` re-enable) — closed; in-loop
  `set -x` removed, function-tail restore is the sole safe point.
- B2 (Makefile `set-image-config` would rewrite source `task.yaml` default
  to `build-harbor.alauda.cn/...`) — closed; `$(subst ...)` wraps the
  registry host so the source default stays on the mirror.
- I1 (CoreDNS upstream-DNS patch silent-noop on schema rename) — closed;
  sed output is captured, grep-verified, and the apply step is fail-closed.
- I2 (`run-test-on-kind` 30m timeout vs ~38m steady-state run) — closed;
  bumped to 60m matching observed envelope.
- I3 (mirror reachability question raised by team-tier) — N/A;
  `registry.alauda.cn:60070` is the documented public read-only mirror
  (see `environment/build-harbor.md`), not a private host.

### Non-blocker findings

- **T9 (Nexus anonymous-read default-on)** — accepted as
  `anonymous-policy-warning` result + how-to documentation. Strict sites
  opt in via `requireAnonymousDisabled=true`. Re-evaluation trigger
  recorded in `threat-model.md ## 残余风险`: flip default to fail-on-
  anonymous if a customer reports unauthorized pulls.
- **T16 (cluster operator `pods/exec` reading tmpfs token / CSI mount)** —
  inherent K8s trust-boundary residual. Mitigated by `shred -u` on tmpfs
  before step 5 exit + how-to runbook recommends restricting `pods/exec`
  on `connectors-management` ns. Cluster-admin remains out of scope.
- **T10 (supply-chain injection by compromised project user)** — out of
  scope for this Task; mitigated by `strictContentTypeValidation=true`
  forced-default on hosted repos.

## Decision

**approved**

## Reviewer

- **Name:** jtcheng (driver of record)
- **Security label:** team-internal — connectors-domain owner with
  cross-repo signing authority for connectors-family bundles; same role
  that signed off the Harbor sibling feature in v1.10.0.
- **Date:** 2026-05-28
- **Rationale:** The bundle delta is one Tekton Task + catalog ConfigMaps;
  no new RBAC, no new exposed endpoints, no new Alauda-side egress. The
  Task's threat surface was modelled in `threat-model.md` (17 threats,
  17 mitigations) and walked end-to-end during `/feature:design-review`
  round 3. Two independent multi-tier reviews (project + team, rounds v1
  and v2) plus 9/9 ACs green on the BDD suite (29/29) and 58/58 on the
  operator regression confirm the mitigations land. Two residual risks
  (T9 anonymous-default-on, T16 pods/exec) are accepted with documented
  re-evaluation triggers. No blockers carried into the bundle.
