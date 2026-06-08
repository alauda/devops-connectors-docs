# Docs Changes — Nexus 自动创建 Project + Connector + Secret

<!--
Output of /feature:docs. Index of user-facing doc edits.
-->

## Summary

- **Files touched:** 3 (2 new how-to pages + 1 follow-up release-note edit)
- **Already merged in per-repo PRs:** 2 (the two how-to pages, in PR #1198)
- **Follow-up needed:** 1 (release-notes line under v1.11.0)
- **No user-facing doc change needed:** no

## Per-file index

| File | Summary | State |
|------|---------|-------|
| `docs/en/connectors-nexus/how_to/using_nexus_connector_automatic_creation_task.mdx` | New 696-line workflow guide — covers basic-auth Secret vs Connector workspace, `nexusRepositories` schema with the three repository types, three end-to-end examples (provision-only, reference-only, mixed), rerun semantics, full troubleshooting section | merged in [#1198](https://github.com/AlaudaDevops/connectors-operator/pull/1198) |
| `docs/en/connectors-nexus/how_to/nexus_connector_automatic_creation_task.mdx` | New 340-line reference page — parameter table, workspaces, results, RBAC, security posture, image and tag pinning, Task definition pointers | merged in [#1198](https://github.com/AlaudaDevops/connectors-operator/pull/1198) |
| `docs/en/overview/release_notes.mdx` | Add a `**Nexus Connector Enhancements**` block under the `## v1.11.0 (WIP)` section, mirroring how `harbor-connector-automatic-creation` was advertised in v1.10.0 | follow-up [#1207](https://github.com/AlaudaDevops/connectors-operator/pull/1207) |

## Verified-already-handled (no edit needed)

| Surface | Why no edit | Sibling precedent |
|---------|-------------|-------------------|
| `docs/en/connectors-nexus/how_to/index.mdx` | The index renders `<Overview />` which auto-lists every page in the directory; the two new pages appear without manual registration | Same `<Overview />` pattern in `docs/en/connectors-harbor/how_to/index.mdx` |
| `docs/en/connectors-nexus/intro.mdx` and `quick_start.mdx` | The Harbor sibling does NOT cross-reference its own `harbor_connector_automatic_creation_task` from intro / quick_start — adding one for Nexus would diverge from the family precedent. The how_to listing is the canonical landing path | `docs/en/connectors-harbor/intro.mdx` carries no automatic-creation cross-ref |
| `docs/en/connectors-nexus/concepts/` | Round-3 design-review decision: no concept page for this Task — it is an operational tool, not a connector primitive | Same decision recorded in `product-design.md` round-3 |
| Chinese / Korean translations | No `docs/zh*/` tree exists in this repo; all user docs are English-only | Verified via `ls docs/` |
| Bug release-notes | Auto-filled via the `{/* release-notes-for-bugs?template=fixed&project=DEVOPS&version=v1.11.0 */}` token already in the v1.11.0 release-notes section; no PR-side action required | Token already present in `docs/en/overview/release_notes.mdx` line 39 |

## Follow-up PRs

- [#1207 docs(release-notes): advertise nexus-connector-automatic-creation under v1.11.0](https://github.com/AlaudaDevops/connectors-operator/pull/1207)
  — covers `docs/en/overview/release_notes.mdx` single-block insertion.

Reference: proposed scope (single file, single block insertion):

```diff
--- a/docs/en/overview/release_notes.mdx
+++ b/docs/en/overview/release_notes.mdx
@@ ## v1.11.0 (WIP)
 ### Features and Enhancements
 
 - Added the `enable-pod-image-pull-via-connector` feature flag ...
 
+**Nexus Connector Enhancements**
+
+- Provide the `nexus-connector-automatic-creation` Tekton Task to automate
+  Nexus connector initialization and credential refresh for Alauda
+  Container Platform tenants and namespaces. More details:
+  - It can create or reconcile Nexus repositories (hosted, proxy, group),
+    scoped user + role + per-repository privileges, the Connector
+    authentication Secret, and the Nexus Connector resource, with
+    rerun-based self-healing for partial failures.
+  - [Automatically Create and Reconcile Nexus Connector Resources with Tekton](../connectors-nexus/how_to/using_nexus_connector_automatic_creation_task.mdx)
+
 ### Fixed Issues
```

## No-doc-needed rationale

N/A — this feature ships a user-visible Task with both how-to and
reference pages already merged in #1198. The only outstanding edit is the
release-notes advertisement, captured above.
