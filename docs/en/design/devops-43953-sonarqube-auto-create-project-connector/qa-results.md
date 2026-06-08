# QA Results — DEVOPS-43953 SonarQube auto-create

<!-- Output of /feature:qa. Per-case pass/fail with evidence links. -->

## Summary

- **Bundle under test:** `v1.11.0-beta.183.gd204e0e@sha256:f9327e7250cec686ddcb4cf691a52fc1c10189a7f8f6b370daf81576ae81598f`
- **Total cases:** 11 (from `tech-design.md` §4.3)
- **Pass:** 11   **Fail:** 0   **Blocked:** 0
- **Outcome:** advance

## Per-case results

| # | Priority | Case | Method | Outcome | Evidence |
|---|----------|------|--------|---------|----------|
| 1 | p0 | 单租户全新供给 | `tektoncd.feature` e2e | pass | extensions#325 check `connectors-sonarqube-integration-test` SUCCESS (PipelineRun `connectors-sonarqube-integration-test-bk9vw`) |
| 2 | p0 | 幂等重跑 | `tektoncd.feature` | pass | same |
| 3 | p0 | token 过期 / 缺失重签 | `tektoncd.feature` + `script.feature` | pass | extensions#325 checks integration-test + `connectors-sonarqube-lint-and-test` (PipelineRun `connectors-sonarqube-lint-and-test-m4kn4`) both SUCCESS |
| 4 | p0 | 回滚 | `tektoncd.feature` + `script.feature` | pass | same |
| 5 | p0 | 多租户隔离 | `tektoncd.feature` | pass | extensions#325 integration-test SUCCESS |
| 6 | p0 | E2E — 扫描期自动建项目 | `tektoncd.feature` (含 catalog `sonarqube-scanner` 串联) | pass | same |
| 7 | p0 | Admin token 缺权限 | `tektoncd.feature` | pass | same |
| 8 | p0 | 非法参数 | `tektoncd.feature` | pass | same |
| 9 | p1 | SCIM/SSO 自动供给冲突 (A2) | `script.feature` | pass | extensions#325 lint-and-test SUCCESS |
| 10 | p1 | helper: ensure-user / ensure-template / `lib.sh` 双挂载识别 | `script.feature` | pass | same |
| 11 | p1 | helper: ensure-token mint / reuse / revoke+mint / SSA 幂等 | `script.feature` | pass | same |

## Defects opened

None.

## Acknowledged p1 failures

None.

## Per-AC verification status

| AC | Status | Linked test case(s) | Notes |
|----|--------|---------------------|-------|
| AC-1 | pass | #1, #6 | private 项目自动建并套权限模板 — confirmed by e2e 扫描 |
| AC-2 | pass | #1, #5 | USER_TOKEN scoped via template; admin perms not present |
| AC-3 | pass | (precondition P4) | shared gate/profile = SonarQube 实例默认 — verified at design via P4 documentation; SonarQube has no per-key-pattern gate selection, so AC-3's "shareable" reading is satisfied by inheritance, not by Task action |
| AC-4 | pass | #5 | A's token reading B → 403/private-invisible |
| AC-5 | pass | #1, #2 | Connector + Secret SSA land in Connector namespace with field manager `connector-auto` |
| AC-6 | pass | #7, #8, #9 | preflight rejects + SonarQube 403 propagated raw |
| AC-7 | pass | #4 | tmpfs state-file rollback verified; reused resources unaffected |
| AC-8 | pass | all 11 | 8 p0 + 3 p1 BDD cases all green |
| AC-9 | pass | (CI mdx + manual) | `docs/en/connectors-sonarqube/how_to/sonarqube_connector_automatic_creation_task.mdx` (concept + how-to, 488 lines) and `using_sonarqube_connector_automatic_creation_task.mdx` (reference, 516 lines) on `main` since PR #1211; CI `doc-build` SUCCESS on PR #1211 |

## PipelineRun reclamation note

The PipelineRuns referenced as evidence
(`connectors-sonarqube-integration-test-bk9vw`,
`connectors-sonarqube-lint-and-test-m4kn4`) are already reclaimed from the
live Tekton namespace — PR #325 merged 2026-05-28, retention window has
since expired. Tekton Results archive query against
`results.tekton.dev/v1alpha2` returned no records, indicating the
connectors-extensions repo does not enable the Watcher's results-archiver
in this namespace. The "SUCCESS" status used as evidence above is sourced
from the immutable GitHub PR-check rollup on
`AlaudaDevops/connectors-extensions#325` and is treated as authoritative
for closed merged PRs. This is a known QA-evidence gap for retroactive
verification — recorded for tooling follow-up (enabling results archiver
or migrating to Allure report retention in `testing/allure-report/`).

## Reviewer

- **QA reviewer:** kychen (Discord-async-driver convention, same as design-review approved entry — driver acts as QA reviewer + domain owner for both repos).
- **Signed at:** 2026-06-02T10:30:00Z

Verification that the enumerated cases match `tech-design.md` §4.3 1:1
(no silently dropped cases, no surprise additions): yes — 11 cases exactly,
identical priority assignment (8 p0 + 3 p1), method column matches.
