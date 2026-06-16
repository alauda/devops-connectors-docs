# Docs Changes — DEVOPS-43953 SonarQube auto-create

<!--
Output of /feature:docs. Index of user-facing doc edits.
-->

## Summary

- **Files touched:** 5
- **Already merged in per-repo PRs:** 5
- **Follow-up needed:** 0
- **No user-facing doc change needed:** no — feature ships a new
  user-visible Tekton Task and needs full concept + how-to + reference

## Per-file index

| File | Summary | State |
|------|---------|-------|
| `docs/en/connectors-sonarqube/how_to/sonarqube_connector_automatic_creation_task.mdx` | New 488-line how-to: concept overview, preflight P1–P5 checklist, parameter reference, worked examples (single-tenant + multi-tenant + scan), operations runbook | merged in operator#1211 (d204e0e) |
| `docs/en/connectors-sonarqube/how_to/using_sonarqube_connector_automatic_creation_task.mdx` | New 516-line reference: SonarQube Web API call sequence, idempotency table, rollback step matrix, error-handling examples, troubleshooting | merged in operator#1211 (d204e0e) |
| `docs/en/connectors-sonarqube/how_to/index.mdx` | Index page links the two new how-to pages | merged in operator#1211 |
| `docs/en/connectors-sonarqube/trouble_shooting/index.mdx` | Added SonarQube tenant-onboarding troubleshooting section | merged in operator#1211 |
| `cmd/kodata/connectors-sonarqube-tektoncd/1.0.0/install.yaml` | Inline `style.tekton.dev/descriptors` carries Chinese label + tooltip + advanced-form widget specs for every parameter — this is the ACP UI surface for the Task | merged in operator#1211 |

## Follow-up PRs

None. All user-facing doc edits are already on `upstream/main` via
`AlaudaDevops/connectors-operator#1211` (merge commit `d204e0e`,
2026-06-02T09:29:16Z). CI check `doc-build-alauda-devops-connectors`
on PR #1211 ran SUCCESS — confirms mdx lint and the `hack/sync_install_manifests.sh`
docs pre-hook (added in PR #1206 / 3f485c1) successfully rendered the
embedded Task YAML into the reference page.

## No-doc-needed rationale

n/a — this feature ships a brand-new user-facing Tekton Task, so the
docs surface (concept + how-to + reference + descriptors + trouble-
shooting index entry) is required and already complete.

## Release-note linkage

The `release-notes.md` user-visible summary cross-references these
files implicitly via the Task name and parameter list. No release-note
"see also" links are added because the operator's release-note
convention does not include per-doc-page deep links — readers reach
the how-to pages through the connector's documentation index.

## Mdx-source authority

The two new how-to pages embed the Task YAML inline via the
`hack/sync_sonarqube_connector_automatic_creation_task_doc.sh` helper
that PR #1211 also shipped. This helper re-renders the inline Task
block from `cmd/kodata/connectors-sonarqube-tektoncd/1.0.0/install.yaml`
on every doc build, so the mdx never drifts from the manifest. If a
future PR edits the install.yaml, the next doc-build pre-hook (added
to `hack/sync_install_manifests.sh` in PR #1206) regenerates the mdx
inline blocks; no manual mdx edit is required.
