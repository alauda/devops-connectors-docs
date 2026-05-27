# Docs Changes — Gitlab automatic project and sub-account support using API and CLI

<!-- Output of /feature:docs on 2026-05-14. Index of user-facing doc edits. -->

## Summary

- **Files touched:** 7
- **Already merged in per-repo PRs:** 4 (Story 3 / PR #1002 — concept page + how-to page + reference page + retrospective)
- **Follow-up needed:** 3 (overview release-notes entry, ASCII-tree → mermaid migration in the concept page, plus this umbrella's tech-design.md drift fixes D1+D2 already applied here)
- **No user-facing doc change needed:** no

## Per-file index

| File | Summary | State |
|------|---------|-------|
| `docs/en/connectors-gitlab/concepts/glab_cli_config.mdx` | New concept page **GitLab CLI Configuration and Auto-Creation Patterns** — explains how the auto-creation Task consumes the admin Connector through the `gitlabconfig` CSI mount, the two deployment patterns (Pattern A top-level + `can_create_group` user PAT vs Pattern B subgroup-of-umbrella + Owner user PAT — with the explicit "Why not a GAT on the umbrella?" sidebar covering the bot-membership constraint), the three-path GAT lifecycle (rotate / recreate / expired-fall-through), and the tenant-side cluster surface the Task lands. | merged #1002 |
| `docs/en/connectors-gitlab/how_to/using_gitlab_connector_automatic_creation_task.mdx` | New how-to **Auto-Create GitLab Tenant Group and Connector with Tekton** — operator workflow page. Sections: What This Solves, Before You Begin, Choose a Deployment Pattern, Pattern-A/B prerequisites, Optional Kubernetes Connector for cross-cluster apply, Step-by-step Pattern-A/Pattern-B fresh creation, Step-by-step rotate-in-place + CronJob pattern for scheduled rotation, Step-by-step recreate on identity change, Step-by-step expired-fall-through (self-healing), Verify the Result, full Operations Runbook (token already expired / token-refresh CronJob disabled / tenant offboarding rollback / Pattern-A user ownership audit / group-path conflict / rotation-during-use race / validating scopes against your instance), Manual Cross-Group Permissions Workaround, Troubleshooting (5 named symptoms), Further Reading. | merged #1002 |
| `docs/en/connectors-gitlab/how_to/gitlab_connector_automatic_creation_task.mdx` | New reference page **GitLab Connector Automatic Creation Tekton Task** — parameter / workspace / result reference (operator-installed Task, catalog tool-image expectations, parameters table, workspaces table, results table). Mirrors Harbor's split between the operator-walkthrough (`using_*`) and the contract reference (`*_task.mdx`). | merged #1002 |
| `docs/en/design/connector-gitlab/devops-43146-retrospective.md` | Internal retrospective doc on the design + implementation arc — design-review loops, Option-B image-strategy decision, F1+F2 fix discovery via live QA. **Not a user-facing doc** — listed here for completeness because it shipped in the same PR. | merged #1002 |
| `docs/en/overview/release_notes.mdx` | Add v1.11.0 release-notes section: GitLab Connector Enhancements entry under Features and Enhancements pointing at the new how-to (mirrors v1.10.0's Harbor entry shape); compatibility-matrix row for v1.11.0. Draft text in `release-notes.md` adjacent to this file. | needs-follow-up |
| `docs/en/connectors-gitlab/concepts/glab_cli_config.mdx` (revisit) | Convert the two ASCII art blocks to **mermaid** per Daniel's preference (Discord 2026-05-14 06:08Z, https://doom.js.org/usage/markdown.html ): (a) lines ~75-104 Pattern-A/B group hierarchy trees → `graph TD` showing `root → tenantGroup` (top-level) + `umbrella → tenantGroup → subgroups` (subgroup), and (b) lines ~160-183 three-path GAT lifecycle decision tree → `flowchart TD` with the same `existing GAT? → expired? → identity unchanged? → rotate/recreate/fall-through-recreate` decision branches. Use ` ```mermaid ... ``` ` fence (Doom's parser is Shiki + Mermaid). | needs-follow-up |
| `docs/en/design/devops-43146-gitlab-automatic-project-and-sub-account/tech-design.md` | D1 fix — Test Design case 5 wording: "GAT rotated (no recreate)" → "GAT recreated" with explanation that subgroup set is part of GAT identity. D2 fix — Test Design case 3 wording: "Connector unchanged (resourceVersion bumps for Secret only)" → "Connector spec untouched (`generation: 1` stable / `observedGeneration: 1`)" with note that `metadata.resourceVersion` may bump independently due to controller status reconcile. | applied on this branch (`docs/DEVOPS-43146-accept-and-docs`) — lands in this PR (#1086) |
| (no change) `docs/en/connectors-gitlab/quick_start.mdx` | Reviewed; no edit needed. The Quick Start covers the standalone GitLab Connector setup; the Task is documented in its own how-to and intentionally not surfaced from Quick Start to keep that page focused on the minimal getting-started path. | none-needed (rationale recorded) |

## Follow-up PRs

- **Release-notes v1.11.0 entry** — to be opened against `connectors-operator/main` as a small PR adding the v1.11.0 section to `docs/en/overview/release_notes.mdx`. Content drafted in `release-notes.md` adjacent to this file. Recommended scope: add the v1.11.0 entry + compatibility-matrix row, mirroring v1.10.0's "Harbor Connector Enhancements" entry. This follow-up is intentionally split from the Story-3 docs PR (#1002) because the operator-wide release-notes entry typically lands as part of the release-cut PR rather than per-feature; flag for the v1.11.0 release-cut owner.
- **ASCII → mermaid migration** — separate small PR against `connectors-operator/main` converting the two ASCII art blocks in `docs/en/connectors-gitlab/concepts/glab_cli_config.mdx` to mermaid. Daniel's standing preference: mermaid over ASCII for diagrams in user-facing docs (https://doom.js.org/usage/markdown.html). Touches one file, no semantic change. Good first task for whoever picks it up.
- **D1 + D2 tech-design.md fixes** — already applied on `docs/DEVOPS-43146-accept-and-docs` and ship in PR #1086 alongside this `/feature:docs` umbrella update.

## No-doc-needed rationale

- `docs/en/connectors-gitlab/quick_start.mdx` — the Quick Start covers the standalone GitLab Connector setup; introducing the Task here would dilute the minimal getting-started flow. The Task has its own how-to (`using_gitlab_connector_automatic_creation_task.mdx`) reachable from the connectors-gitlab `how_to/index.mdx` and is also mentioned in the v1.11.0 release-notes entry.
- No CLAUDE.md / agent guidance updates required — the Task is a runtime artifact reconciled by Tekton, not part of Claude's operator-development surface.

## Convention note (recorded for future doc PRs)

For any new diagrams across connectors docs, **prefer mermaid** (` ```mermaid ` fence — Doom framework supports it via Shiki + Markdown Preview Mermaid). ASCII art is harder to maintain, doesn't render in PDF exports, and loses the `mermaid` annotation that the framework toolchain depends on. Existing ASCII blocks should be migrated when they're touched for other reasons; the standalone migration above is offered as a small isolated PR if anyone wants to take it. Source: Daniel 2026-05-14 06:08Z.
