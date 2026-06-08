# Research — connectors 和旧版本 tektoncd 一起使用时，不安装 v2 的 ResourceInterface

<!--
Written by /feature:research. Profile=full only.
-->

## Overview

DEVOPS-43899 introduced ResourceInterface (RI) versioning: v2 RIs carry the
labels `resourceinterface.connectors.cpaas.io/version` and `schema-version`,
and a version-aware PipelineInvocation (PI) matcher in connectors picks the
highest schema ≤ the PI's `currentSchema`. The matcher lives on the
*versioned* (new) Tekton stack only. On a legacy Tekton install — one
without the version-aware PI matcher — v2-labelled RIs show up as
unusable categories.

The v2 RI labels are not purely a design artifact: on `main`,
`cmd/kodata/connectorsharbor/1.0.0/install.yaml` already ships
`harborociartifact-v2` (`resourceinterface.connectors.cpaas.io/version: "2"`,
`schema-version: "1"`, `cpaas.io/hidden: "true"`). Other extensions ship v2
on the design branch `feat/resource-interface-version`. The frontend-hide
label (`cpaas.io/hidden: "true"`) keeps the *display* clean on legacy UIs,
but does not gate *install*: the v2 RIs land in the cluster, the category
list contains them, and any caller that does not honour the hidden marker
sees them.

This feature adds an install-time gate so that v2-or-higher RIs are *not
written into the cluster at all* when the operator sees a legacy Tekton,
while v1 RIs install unchanged.

## Per-repo findings

### connectors (core)

- ResourceInterface CRD lives at `pkg/apis/connectors/v1alpha1/resourceinterface_types.go`. The spec on `main` carries `Params`, `Attributes`, `Workspaces`, `Configurations` — **no `version` / `schemaVersion` fields**. The v2 contract on `main` is **label-only**, not a structured field.
- No Tekton-version / capability detection anywhere in core (`cmd/controller/main.go`, `cmd/proxy/main.go`, `cmd/csi/main.go` checked). Feature-flag infrastructure exists (`pkg/featureflags/flags.go`) but reads a ConfigMap — it is a *toggle* surface, not a cluster-capability probe.
- No conditional install / skip pattern in `dist/install.yaml`. Everything in core installs unconditionally.
- The PI version-aware matcher (the runtime piece from DEVOPS-43899) is **not in this repo on `main`**; it lives downstream (in the new Tekton stack). That keeps the core's surface for *this* feature small — at most a documentation/CRD-comment confirmation that v2 is label-only.

### connectors-extensions (per-tool repos)

- Pattern is uniform across per-tool repos (`connectors-git`, `connectors-harbor`, `connectors-oci`, `connectors-maven`, `connectors-npm`, `connectors-pypi`, `connectors-sonarqube`, …): each ships its own `dist/install.yaml` (Kustomize + ko) that is synced into `connectors-operator/cmd/kodata/<connectorType>/<version>/install.yaml` via `hack/sync_install_manifests.sh`.
- **Already on `main` with a v2 RI: `connectors-harbor` only** (`harborociartifact-v2`, labels: `version: "2"`, `schema-version: "1"`, `cpaas.io/hidden: "true"`).
- The design branch `feat/resource-interface-version` has the rest of the rollout queued (Maven, NPM, OCI, SonarQube). When it merges, every extension will ship v2 alongside v1.
- No conditional install / per-cluster gating precedent in any extension. `cpaas.io/hidden: "true"` is the only existing v1/v2 separation mechanism — and it only affects the frontend, not whether the RI is created in the cluster.
- The `version` label is a string (`"2"`, not `"v2"`), and `schema-version` is a separate numeric-string label. Any gate needs to handle both consistently.

### connectors-operator

- Two-controller flow confirmed: `ConnectorsReconciler.reconcile()` (`pkg/controllers/connectors_controller.go:133`) loads the per-type manifest from `cmd/kodata/<kind>/<version>/install.yaml` via `pkg/controllers/connectors_releases.go:52-57`, runs it through `transformer.Transform()` (`pkg/controllers/transformer/transform.go:40`), then hands the result to `InstallManifestManager` → `InstallManifest` CR → `InstallManifestReconciler` (`pkg/controllers/installmanifest_controller.go:115`) → ordered apply (CRDs → cluster-scoped → namespace-scoped → workloads via `pkg/controllers/installer/installer.go:51`).
- Transformers in `pkg/controllers/transformer/` are `mf.Transformer` funcs and can only **mutate** docs, not **drop** them. Dropping uses `manifestival.Filter(predicates...)` which already runs inside `installer.NewInstaller()` (`pkg/controllers/installer/installer.go:69-73`) to split by kind. The cleanest hook for v2-RI gating is to apply a `Filter` step in `ConnectorsReconciler.reconcile()` **after** `transformer.Transform()` returns and **before** the IM is built (around `pkg/controllers/connectors_controller.go:326`).
- `component.Transformer` (`pkg/apis/v1alpha1/component/component_interfaces.go:48-52`) is per-connector; v2-RI gating is global to *every* connector type, so the right place is the operator-wide chain, not per-connector `GetTransformers()`.
- `mgr.GetRESTMapper()` is already wired into `InstallManifestReconciler` (line 100). A discovery-based check ("does the cluster have `tekton.dev/v1/PipelineInvocation`?" — or whatever the canonical "versioned-Tekton" marker is) can run off it. Cache the result; refresh on a periodic timer or on reconciler retry so a Tekton upgrade re-enables v2 install without an operator restart.
- `InstallManifestSpec.Manifests` is `mf.Slice` (raw `[]unstructured.Unstructured`) — embedded YAML, not references. Filtering must happen before the slice is packed into the IM; once it's in the IM, it will apply.
- **PR #827 / `feat/resource-interface-version` is not merged to `main`.** The auto-sync of Harbor's v2 RI on `main` is from `bae7d82` (manifest auto-sync), not from the operator-side gating work. So today's `main` has the *labels* but no *gate*.

## Risks

1. **Already partially shipped.** Harbor v2 RIs are on `main`'s kodata today. Any release cut now to a legacy-Tekton cluster will surface an unusable Harbor OCI artifact category — this is the concrete production risk the Jira is responding to.
2. **No canonical "legacy Tekton" marker exists yet.** The design must pick exactly one signal (e.g. presence of the versioned PI CRD, a specific Tekton CRD version, or a tektoncd ConfigMap key) and be confident that signal is monotonic and stable across air-gapped customer Tekton deployments.
3. **Multi-source RI creation.** RIs can land in the cluster from extensions' `dist/install.yaml`, from operator-orchestrated install, or from users directly via the API. Install-time gating only covers the operator path. If RIs from elsewhere can carry v2 labels, the gate is incomplete — though for *this* feature, only the operator path needs to be gated (user-created RIs are out of contract).
4. **Reactivity.** If a Tekton upgrade on the cluster turns legacy into versioned, the operator must reconcile and install the previously-filtered v2 RIs without restart. This implies the capability check is per-reconcile, not one-shot at startup.
5. **Status surface.** Without a visible status field on the connector CR ("v2 RIs filtered: yes/no, reason: legacy Tekton"), debugging "why is OCI Artifact category missing on this customer's cluster?" becomes painful. This is observability scope.
6. **Label discipline.** The gate works only if every v2 RI is correctly labelled. Today only Harbor has v2 labels; the rest will arrive when the design branch lands. The audit / lint enforcing the label convention is the per-extensions slice.

## Unknowns

- **Coarseness of the chosen detection signal.** The picked signal — "`tekton.dev/*/PipelineInvocation` CRD absent" — treats any cluster that *has* a `PipelineInvocation` CRD as "versioned-Tekton", including one that has PI but lacks the schema-aware matcher. If such a stack exists in the field, this gate is too loose. **Reporter to confirm**: is there a legacy stack that has PI but lacks the version-aware matcher? If yes, the design must pick a finer signal (CRD served-version threshold, or a tektoncd-operator ConfigMap key).
- **Gate criterion: by `version: ">=2"` label, or by `schema-version` threshold?** The PI matcher is schema-based; the install gate is version-based; they may diverge. — Blocks design decision about the filter predicate.
- **Multiple `tekton.dev/*/PipelineInvocation` versions served simultaneously.** Discovery may return both `tekton.dev/v1alpha1/PipelineInvocation` and `tekton.dev/v1/PipelineInvocation`. The gate treats "any served version" as "versioned"; the design must confirm this matches the runtime matcher's expectation.
- **Operator-level vs per-connector override.** Should `ConnectorsHarbor` (etc.) gain a `spec.forceV2ResourceInterfaces: bool` for manual override on a legacy-but-patched Tekton? Out of scope for this feature per AC-6 — but design should record whether a follow-up Jira is filed.
- **Existing v2 RIs already installed.** If an operator upgrade introduces the gate on a cluster that already has Harbor v2 RIs from a previous install, does the operator delete them, leave them, or refuse to converge? AC-7 commits to deletion via IM ownership — design must confirm this is achievable without orphaning and without surprising customers who already use Harbor v2 categories.

## References

- [DEVOPS-43943](https://jira.alauda.cn/browse/DEVOPS-43943) — this feature
- [DEVOPS-43899](https://jira.alauda.cn/browse/DEVOPS-43899) — RI versioning (completed)
- connectors-operator#827 — `feat/resource-interface-version` design PR (open)
- `docs/en/design/connector-resourceinterface/resource-interface-versioning.md` (on `feat/resource-interface-version`)
- Current v2-labelled RI on `main`: `cmd/kodata/connectorsharbor/1.0.0/install.yaml:838-868`
- Transformer chain entry: `pkg/controllers/transformer/transform.go:40`
- Hook point for filter: `pkg/controllers/connectors_controller.go:326`
- RESTMapper / discovery hook: `pkg/controllers/installmanifest_controller.go:100`

## Acceptance Criteria (proposed — pending reporter sign-off)

The Jira's lone AC ("connector 能够根据一些行为不安装 v2 的 scheme") is too
abstract to gate completion. Proposed concretization, **pending sign-off
from Lufan You**:

- **AC-1.** When `connectors-operator` reconciles any connector CR on a cluster whose API server does **not** serve a CRD with kind `PipelineInvocation` in the `tekton.dev` group (probed via the controller-manager's REST mapper / discovery client), the resulting `InstallManifest.spec.manifests` MUST contain **zero** `ResourceInterface` documents whose `resourceinterface.connectors.cpaas.io/version` label has a value lexicographically ≥ `"2"`.
- **AC-2.** On a cluster whose API server **does** serve a `tekton.dev/*/PipelineInvocation` CRD, the same connector CR MUST produce an `InstallManifest` whose RI set matches the connector's full `cmd/kodata/<type>/<version>/install.yaml` (no filtering applied).
- **AC-3.** The operator MUST install a discovery-surface watch (CRD informer in the `apiextensions.k8s.io` group) such that:
  - the **appearance** of a `tekton.dev/*/PipelineInvocation` CRD triggers a reconcile of every owned connector CR within the controller queue latency (typically seconds, no operator restart required), and previously-filtered v2 RIs install on that reconcile;
  - the **disappearance** of that CRD triggers a reconcile that drops v2 RIs on the next apply.
- **AC-4.** Each connector CR's `.status` MUST surface the gating outcome via all three of:
  - a condition with `type: V2ResourceInterfacesInstalled`, `status: True | False`, `reason: VersionedTekton | LegacyTekton`, and a human-readable `message`;
  - a numeric field `status.v2ResourceInterfacesFiltered` (count of RI docs dropped in the most recent reconcile, `0` when none);
  - a Kubernetes `Event` emitted on every transition of the condition between `True` and `False`.
- **AC-5.** v1 RIs (no `resourceinterface.connectors.cpaas.io/version` label, OR `version: "1"`) MUST continue to install on legacy Tekton — the gate is strictly additive-version-only.
- **AC-6.** No new field on connector type CRDs is introduced in p0; the gating is implicit / auto-detected. A `spec.forceInstallV2ResourceInterfaces: bool` override MAY be considered as a follow-up but is **out of scope** for this feature.
- **AC-7.** If a cluster previously held v2 RIs (from a pre-gate operator) and then upgrades to a gate-enabled operator while Tekton is still legacy, the operator MUST converge by deleting those v2 RIs (consistent IM ownership). The deletion path is exercised by an integration test.

## Stories

<!-- Required for profile=full -->

1. **Tekton capability detection in the operator** (p0, slice=backend, repos=[connectors-operator])
   Add a cluster-capability probe in `connectors-operator` that determines whether the cluster's API server serves a `tekton.dev/*/PipelineInvocation` CRD (the chosen "versioned-Tekton" signal — see AC-1). Use the controller-manager's REST mapper / discovery client. **Install an informer on `CustomResourceDefinition`** so that appearance / disappearance of that CRD triggers a reconcile of every owned connector CR (see AC-3). Expose a small accessor that the filter in story 2 calls; the accessor MUST be safe to invoke on every reconcile.
   Depends on: none.
   ACs: AC-1, AC-2, AC-3.

2. **Install-time v2 RI filter + status surface** (p0, slice=backend, repos=[connectors-operator])
   Add a `manifestival.Filter` step in `ConnectorsReconciler.reconcile()` (around `pkg/controllers/connectors_controller.go:326`) that drops `ResourceInterface` documents whose `resourceinterface.connectors.cpaas.io/version` label is ≥ `"2"` when story 1's probe reports "legacy Tekton". Surface the gating outcome on the connector CR's status with: (a) a condition `type: V2ResourceInterfacesInstalled` (`reason: VersionedTekton | LegacyTekton`), (b) a numeric `status.v2ResourceInterfacesFiltered` count of dropped RI docs, (c) a Kubernetes `Event` on every condition transition (see AC-4). Garbage-collect v2 RIs previously installed when the cluster is now legacy (AC-7) by relying on InstallManifest ownership of the dropped manifests.
   Depends on: 1.
   ACs: AC-1, AC-2, AC-4, AC-5, AC-7.

3. **v2 RI label discipline audit across extensions** (p0, slice=backend, repos=[connectors-extensions])
   Audit every per-tool extension repo's `dist/install.yaml` (Git, GitLab, Harbor, OCI, Maven, NPM, PyPI, SonarQube, K8S, Nexus, …) for v2 RIs. Confirm each v2 RI carries `resourceinterface.connectors.cpaas.io/version` AND `schema-version` labels consistently. Document the labelling convention so future extensions comply. The filter in story 2 depends on this discipline being correct.
   Depends on: none (parallel to 1, 2).
   ACs: AC-1 (label correctness is a precondition for the filter to gate).

4. **Integration test matrix: legacy vs versioned Tekton** (p0, slice=test, repos=[connectors-operator, connectors-extensions])
   Add Ginkgo integration tests covering the gating matrix: (a) legacy-Tekton kind cluster → v2 RIs absent, v1 RIs present, status condition set; (b) versioned-Tekton kind cluster → all RIs present, status condition clear; (c) cluster transitions legacy → versioned → v2 RIs installed on next reconcile without restart; (d) cluster previously holding v2 RIs from a pre-gate operator → operator-with-gate deletes them. Exercises Harbor v2 specifically (the only v2 RI on `main` today) and at least one extension's v2 RI once they land via the design-branch merge.
   Depends on: 1, 2, 3.
   ACs: AC-1, AC-2, AC-3, AC-5, AC-7.

5. **User-facing documentation for the gating behavior** (p1, slice=docs, repos=[connectors-operator])
   Update `docs/en/connectors/` with a "Compatibility with legacy Tekton" section: what triggers gating, how to verify (kubectl on the connector CR's condition), troubleshooting steps for "category missing" reports, behavior on Tekton upgrade. Release-notes entry for the gating behavior.
   Depends on: 2.
   ACs: covered by AC-1..AC-7 (documentation correctness).

6. **Core RI label-convention reaffirmation** (p2, slice=docs, repos=[connectors])
   Reaffirm in the core repo's CRD comment / docs that `resourceinterface.connectors.cpaas.io/version` is the canonical version-marker for RIs and that `schema-version` is its companion. Do **not** add a structured `spec.version` field — keep v2 as a label-only contract (consistent with what Harbor already ships on `main`). If design decides a structured field is preferable, this becomes p0 backend work and the recommendation reverses.
   Depends on: none.
   ACs: indirect — anchors the contract that AC-1 depends on.

### UI slice — explicitly waived

**No UI story.** Rationale: (a) `connectors-plugin` is not in the affected
repos list on the Jira; (b) the existing v2 RIs already carry
`cpaas.io/hidden: "true"`, which the old frontend honours; (c) gating is
an install-time operator behavior — the frontend continues to display
whatever RIs the cluster has, so no plugin change is required. If story 4's
integration runs surface a UI-visible regression (e.g. status condition not
rendered on the connector detail screen), a UI follow-up will be filed
against the parent epic, not added here.

### Story priority summary

- p0 (must ship): 1, 2, 3, 4
- p1 (should ship; deferrable with reviewer agreement): 5
- p2 (follow-up if needed): 6
