# Release Notes — Gitlab automatic project and sub-account support using API and CLI

<!--
Output of /feature:docs on 2026-05-14. Drafts the v1.11.0 release-note
entry for the Alauda DevOps Connectors operator. Mirrors the v1.10.0
"Harbor Connector Enhancements" entry shape — same connector-automatic-creation
Tekton-Task pattern, same doc-link structure.

This file is the umbrella's draft; the live entry lands in
docs/en/overview/release_notes.mdx as a follow-up edit (see docs-changes.md).
-->

## Summary

The connectors-operator now ships the `gitlab-connector-automatic-creation`
Tekton Task — the GitLab analogue of `harbor-connector-automatic-creation`
introduced in v1.10.0. Given a single admin GitLab Connector, the Task
provisions a tenant GitLab group and any optional per-team subgroups,
mints a Group Access Token at the tenant group, and materialises the
cluster-side tenant `gitlab` Connector + auth Secret in one idempotent
TaskRun. Two deployment patterns are supported uniformly: Pattern A
(top-level group + a `can_create_group` user PAT) for greenfield orgs
where each ACP project becomes a top-level GitLab group; Pattern B
(subgroup of an umbrella + a GAT at the umbrella) for orgs that
centralise tenants. Token refresh follows the Harbor pattern:
rotate-in-place when inputs are unchanged, delete + recreate when
identity-affecting inputs change. The Task is self-healing on missed
rotations: an already-expired GAT falls through to the recreate path
automatically.

## Bundle

- **Tag:** `v1.11.0-beta.146.g1aecd74`
- **Image digest:** `sha256:81bc56523b3c097da8247a09a0dda32c6b4da786c8665371b29c90e81d5c0396`

The shipped bundle for the v1.11.0 release will be tagged at GA and
recorded in `docs/en/overview/release_notes.mdx ## v1.11.0`. The
beta digest above is what was QA-accepted on `daniel-5shk6` on
2026-05-14.

## Breaking changes

None. The Task is opt-in: existing tenant Connectors and existing
Tekton pipelines are unaffected. The ConnectorClass `gitlab` already
ships the `gitlabconfig` configuration that the Task mounts, so no
ConnectorClass change is required.

## New behavior

- Provide the `gitlab-connector-automatic-creation` Tekton Task to
  automate GitLab connector initialisation and credential refresh
  for Alauda Container Platform tenants. More details:
  - It can create or reconcile GitLab tenant groups, optional
    per-team subgroups, Group Access Tokens, Connector Secrets, and
    GitLab Connectors in a single TaskRun.
  - Two deployment patterns are supported: Pattern A (top-level group
    + `can_create_group` user PAT) and Pattern B (subgroup of an
    umbrella + umbrella GAT).
  - Token-refresh follows a three-path lifecycle: rotate-in-place
    when inputs are unchanged; delete + recreate when an
    identity-affecting input changes (subgroup set, scopes, or
    access level); fall-through-to-recreate when the existing GAT is
    already expired (operator missed the rotation window).
  - [Automatically Create and Reconcile GitLab Connector Resources
    with Tekton](../connectors-gitlab/how_to/using_gitlab_connector_automatic_creation_task.mdx)

## Upgrade notes

- The Task itself is **user-applied** (opt-in) — applying the
  bundle does not deploy the Task into any tenant namespace. Apply
  the Task source from
  `cmd/kodata/connectors-gitlab-tektoncd/1.0.0/install.yaml` (or
  reference the published catalog shape) into the tenant namespace
  where you want to run reconciliations.
- The admin Connector for the Task may be either a user PAT
  (Pattern A; the user must have `can_create_group`) or a Group
  Access Token at an umbrella group (Pattern B; the GAT must have
  `owner` scope at the umbrella). Instance-admin PATs are **not
  recommended**; the how-to documents the safer alternatives.
- For the token-refresh CronJob pattern, the rotation interval can
  exceed the GAT's `expires_at`; the Task self-heals on an expired
  GAT by falling through to the recreate path automatically.

## Credits

- Daniel Morinigo — design + implementation + QA
- Jiacheng Tao (jtcheng) — bundle pipeline support + retest cycle on
  `connectors-operator-dr8mw` (v146)
