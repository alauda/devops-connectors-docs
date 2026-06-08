# Release Notes — Nexus 自动创建 Project + Connector + Secret

<!--
Output of /feature:docs. Follows the operator's release-note convention
under `docs/en/overview/release_notes.mdx`.
-->

## Summary

Provide the `nexus-connector-automatic-creation` Tekton Task to automate Nexus
repository, scoped user / role / privilege, Connector Secret, and Nexus
Connector lifecycle for Alauda Container Platform tenants and namespaces.
The Task accepts a mixed `provision:` and `reference:` repository list,
supports both basic-auth-Secret and ConnectorRef CSI workspace modes for the
Nexus credential, and rotates the scoped user password on every run. Air-gap
friendly; runs as UID 65532 with the proxy MITM CA trusted via
`--cacert $STATE_PROXY_CACERT`.

## Bundle

- **Tag:** `v1.11.0-beta.173.g15aaded`
- **Image digest:** `sha256:34827db4667b5f2fc87c89aa6cb2441c6e247e048566c90dd0e1cf5aea16f37d`
- **Image:** `build-harbor.alauda.cn/devops/connectors-operator-bundle:v1.11.0-beta.173.g15aaded@sha256:34827db4667b5f2fc87c89aa6cb2441c6e247e048566c90dd0e1cf5aea16f37d`

## Breaking changes

None. New surface only.

## New behavior

- New Tekton Task `nexus-connector-automatic-creation` v0.1 ships under
  `cmd/kodata/connectors-nexus-tektoncd/1.0.0/install.yaml`, including the
  v0.1 tool-image ConfigMaps + the Task itself with full
  `style.tekton.dev/descriptors` form metadata and `tekton.dev/icon`.
- Two new user-facing documentation pages under
  `docs/en/connectors-nexus/how_to/`:
  - `using_nexus_connector_automatic_creation_task.mdx` (workflow guide,
    696 lines covering both BasicAuthSecret + ConnectorRef workspace modes,
    `nexusRepositories` schema, three end-to-end examples, rerun semantics,
    troubleshooting).
  - `nexus_connector_automatic_creation_task.mdx` (reference page, 340
    lines including parameter table, workspaces, results, RBAC, security
    posture).

## Upgrade notes

- Operators upgrading from v1.10.z (LTS) need no migration: the new Task
  is opt-in. Existing Nexus Connectors and namespaces are unaffected.
- The Task pins `nexusCliImage` default to
  `registry.alauda.cn:60070/devops/nexus-connector-automatic-creation:v0.1`
  (the public-facing read-only mirror). Air-gap customers who mirror the
  image into a private registry should override `nexusCliImage` per
  TaskRun.

## Credits

- jtcheng (driver, design + extensions implementation + operator-side wiring)
- daniel + kychen (design-review approvers, 2026-05-27)

## Suggested entry for the operator release-notes file

The release notes above are the umbrella record. The corresponding entry
for `docs/en/overview/release_notes.mdx` v1.11.0 (WIP) section, mirroring
how `harbor-connector-automatic-creation` was advertised in v1.10.0, is:

```markdown
**Nexus Connector Enhancements**

- Provide the `nexus-connector-automatic-creation` Tekton Task to automate
  Nexus connector initialization and credential refresh for Alauda Container
  Platform tenants and namespaces. More details:
  - It can create or reconcile Nexus repositories (hosted, proxy, group),
    scoped user + role + per-repository privileges, the Connector
    authentication Secret, and the Nexus Connector resource, with
    rerun-based self-healing for partial failures.
  - [Automatically Create and Reconcile Nexus Connector Resources with Tekton](../connectors-nexus/how_to/using_nexus_connector_automatic_creation_task.mdx)
```

This entry is **not yet in a merged PR** (`docs-changes.md` lists it as a
follow-up). The driver decides whether to open it as a small follow-up
PR against `connectors-operator` main or to fold it into the next batch
of release-note edits for v1.11.0.
