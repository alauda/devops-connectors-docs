# Release Notes — DEVOPS-43953 SonarQube auto-create

<!--
Output of /feature:docs. Follows the operator's release-note convention.
Profile=full, so the structured form is used (one-line form is reserved
for profile=light).
-->

## Summary

A new catalog Tekton Task, `sonarqube-connector-automatic-creation`,
automates per-tenant SonarQube onboarding. From a single TaskRun the
operator now provisions a project-scoped SonarQube user with the
`provisioning` global permission, a key-pattern permission template
that grants only project-level rights to that user, a long-lived
USER_TOKEN, and a tenant `Connector` + bearer-token `Secret` in the
target namespace — all idempotent across re-runs and reversible on
failure. Subsequent `sonar-scanner` calls that hit project keys
matching the tenant's pattern auto-create private projects with the
template's permissions applied; the tenant token can scan and read
`api/measures` but cannot reach projects outside its pattern.

## Bundle

- **Tag:** `v1.11.0-beta.183.gd204e0e`
- **Image digest:** `sha256:f9327e7250cec686ddcb4cf691a52fc1c10189a7f8f6b370daf81576ae81598f`

## Breaking changes

None.

## New behavior

- **New Tekton Task** `sonarqube-connector-automatic-creation` (catalog
  category: `connectors-sonarqube`) — provisions per-tenant SonarQube
  user + permission template + project-scoped USER_TOKEN, and lands a
  tenant `Connector` + bearer-token `Secret` in the target namespace.
  Parameters: `connector`, `tenant`, `projectPattern`,
  `templatePermissions` (default covers Browse/See-Source/Execute-Analysis),
  `tokenDuration` (default 30 days, derived at runtime so cron re-runs
  auto-extend without writing absolute dates into Pod spec or
  TaskRun YAML), and the existing admin-Connector workspace mount.
- **Multi-tenant isolation** verified end-to-end against SonarQube
  25.1 and 8.9.2 — tenant A's token cannot read private projects under
  tenant B's `projectPattern` (returns 403/invisible).
- **Idempotent + reversible** — re-runs reuse the existing user,
  template, and token; injected failures roll back only the resources
  the current run created (existing reused resources are untouched);
  `apply-kubernetes-resources` step uses Server-Side Apply with field
  manager `connector-auto`.
- **No new e2e in `connectors-operator/test/integration`** — the BDD
  surface lives in `connectors-extensions/extensions/connectors-sonarqube-tektoncd/testing/features/`
  (`tektoncd.feature` + `script.feature`, 11 scenarios).

## Upgrade notes

- **Preflight P1–P5** (documented in `product-design.md` §5.4) must
  hold before the Task runs successfully against a SonarQube instance:
  P1 default project visibility = Private; P2 `Default Permission
  Template` lists only admin-level subjects; P3 sonar-users group
  lists only admin-level subjects; P4 instance default quality
  gate/profile = the desired shared baseline; P5 an admin `Connector`
  in the operator namespace whose token holds the `Administer System`
  permission. The Task's `ensure-task-preconditions.sh` step fails
  loudly if P5 is not satisfied.
- **`tokenDuration` parameter** replaces an earlier `tokenExpiry`
  proposal — the difference matters for cron-driven Task re-runs: the
  old absolute-date form did not auto-rotate, the new days-form
  derives `today UTC + N days` at step time so re-runs always extend
  the expiry.
- **No data migration** is required for existing installs — the
  feature is purely additive (new Task; no schema or CRD changes to
  existing `Connector` resources).
- **Rollback** — revert the squash-merge commit `d204e0e` on
  `connectors-operator/main` to remove all 7 bundle-input paths; the
  next bundle will drop the SonarQube Task image registration. See
  `qa-packet.md` "Rollback" section for the full sequence.

## Credits

- kychen — driver, design, PRs #325 (extensions) and #1147/#1211 (operator)
- The DEVOPS-43146 GitLab auto-create umbrella, which served as the
  structural template for plan, design, test, and BDD harness shapes.
