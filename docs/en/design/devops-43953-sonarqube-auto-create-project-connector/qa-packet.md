# QA Packet — DEVOPS-43953 SonarQube auto-create

<!--
Input to /feature:qa. Test design source: tech-design.md §4 (11 cases:
8 p0 + 3 p1). Bundle source: /feature:integrate recorded on
2026-06-02T10:15:00Z.
-->

## Bundle

- **Tag:** `v1.11.0-beta.183.gd204e0e`
- **Image:** `build-harbor.alauda.cn/devops/connectors-operator-bundle:v1.11.0-beta.183.gd204e0e@sha256:f9327e7250cec686ddcb4cf691a52fc1c10189a7f8f6b370daf81576ae81598f`
- **Sources fed in:**
  - `AlaudaDevops/connectors-extensions#325` (merge `0f66f9b`, 2026-05-28) — Stories 1+2: Tekton Task + BDD harness
  - `AlaudaDevops/connectors-operator#1211` (merge `d204e0e`, 2026-06-02) — Story 3 docs + Story 4 wiring (install.yaml, values, mk, hack scripts)

## Jira

- **Story:** DEVOPS-43953 — SonarQube auto-create Project + Connector + Secret
- **Risk:** sensitive (token/secret creation, permission-template handling, third-party API egress)

## Acceptance criteria → BDD mapping

Mapping is taken from `product-design.md` §7 (AC table) cross-referenced with
`tech-design.md` §4.3 (test case table). Both BDD features live in
`AlaudaDevops/connectors-extensions` under
`extensions/connectors-sonarqube-tektoncd/testing/features/`:

| AC | Text (abbrev) | BDD feature | Scenarios (test-case #) | Expected |
|----|--------------|-------------|------------------------|----------|
| AC-1 | Project auto-created via API on scan | `tektoncd.feature` | 单租户全新供给 (#1), E2E 扫描期自动建项目 (#6) | private 项目自动建、套模板、扫描成功 |
| AC-2 | Project-level token + project-only perms | `tektoncd.feature` | #1, 多租户隔离 (#5) | USER_TOKEN scoped via template; admin perms denied |
| AC-3 | Parent project shares quality gate/profile | (covered by P4 — instance defaults; not directly testable per-tenant) | n/a | gate/profile 继承实例默认 (precondition) |
| AC-4 | Namespace tenant cannot reach other projects | `tektoncd.feature` | 多租户隔离 (#5) | A's token reading B private → 403 |
| AC-5 | Connector + Secret land in correct namespace | `tektoncd.feature` | #1, 幂等重跑 (#2) | SSA `connector-auto` to Connector namespace |
| AC-6 | Error handling | `tektoncd.feature` + `script.feature` | Admin token 缺权限 (#7), 非法参数 (#8), SCIM 冲突 (#9) | preflight reject / 403 propagated raw |
| AC-7 | Rollback | `tektoncd.feature` + `script.feature` | 回滚 (#4) | tmpfs state file → reverse-order undo; reused resources untouched |
| AC-8 | Integration test covers multiple scenarios | both features | All 11 cases | 8 p0 + 3 p1 pass |
| AC-9 | Docs include API usage + examples | (CI mdx lint + manual review) | n/a | `docs/en/connectors-sonarqube/how_to/*.mdx` present and lint-clean on `main` |

## Environment

- **Cluster requirements:** business-build (cluster) / devops (ns) for BDD runs; SonarQube 25.1 (latest) and 8.9.2 (LTS) instances both validated during POC (see `poc.md` §B.2 F1–F7).
- **Bundle source:** the bundle image @ tag above; pulled from `build-harbor.alauda.cn`.
- **Required feature flags:** none.
- **Preflight prerequisites P1–P4 + admin Connector P5** documented in `product-design.md` §5.4.
- **Kubeconfig retrieval:** edge platform; see `~/.local/bin/acp-kubeconfig-sync <ACP_URL>` (global instruction in `CLAUDE.md`).

## Test instructions

- **Tag expressions to run:** `@sonarqube-connector-automatic-creation`, `@sonarqube-connector-automatic-creation-script`, `@sonarqube-connector-automatic-creation-tektoncd`
- **How to interpret failure output:** godog Allure reports per-scenario; CEL resource-assertion table tells you the exact failed assertion.
- **Who to contact on blockers:** kychen (driver).

## Rollback

If a regression is detected in `main` post-release: revert the squash-merge
commit `d204e0e` (PR #1211) in `AlaudaDevops/connectors-operator`. That single
revert removes all 7 bundle-input paths — `cmd/kodata/connectors-sonarqube-
tektoncd/install.yaml`, `docs/en/connectors-sonarqube/how_to/*.mdx`,
`hack/sync_*_doc.sh`, `hack/update_image_tags.sh`, `mk/operator.mk` target,
`values.yaml` image registration — and bumps the next bundle. The extensions-
side commit `0f66f9b` (PR #325) can stay on `main` because connectors-operator
no longer references the Task image once the install.yaml is gone.

The Task itself is stateless from the operator's view; tenant Connectors and
Secrets created by past TaskRuns remain in their original namespaces. If the
intent is also to purge tenant data, see `product-design.md` §10 (offboarding
runbook) — that walks through the SonarQube user/template/token revocation
sequence.
