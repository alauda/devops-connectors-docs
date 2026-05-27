# Acceptance — Gitlab automatic project and sub-account support using API and CLI

<!-- Output of /feature:accept on 2026-05-14. AC-by-AC pass/fail mapped to BDD results + live evidence. -->

## Summary

- **Total ACs:** 11
- **Pass:** 11  **Fail:** 0  **Unverified:** 0
- **Overall status:** **passed**
- **Bundle under test:** `v1.11.0-beta.146.g1aecd74@sha256:81bc56523b3c097da8247a09a0dda32c6b4da786c8665371b29c90e81d5c0396` (carries F1 fix from `connectors-extensions#288` synced via operator `#1082`)
- **Live env:** `daniel-5shk6` (business cluster) against `devops-gitlab.alaudatech.net`
- **Sub-agent:** `/workflow:accept gitlab-connector-automatic-creation-task` (Story 1 design-change in connectors-extensions). Stories 2/3/4 are mechanical-followups with no separate AC list — covered by Story 1's AC verification.

## Per-AC results

### AC-1 — Tenant group + optional subgroups created/reused via admin Connector in a single TaskRun (Pattern A + Pattern B)

- **Code evidence:**
  - Step `ensure-group` — `connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/task.yaml:106` (calls `scripts/ensure-group.sh`)
  - `scripts/ensure-group.sh:1-291` — handles top-level (Pattern A, requires admin `can_create_group`) and `umbrella/tenant` (Pattern B, requires admin `owner` on parent); writes `tenant-group-id` + `tenant-group-path` to `/workspace/state/`
  - Step `ensure-subgroups` — `task.yaml:424` calls `scripts/ensure-subgroups.sh:1-150` (idempotent `glab api groups` create per subgroup)
- **BDD scenario(s):** `tektoncd.feature` 测试用例 1 (Pattern A 全新创建顶层租户分组), 测试用例 2 (Pattern B 在 umbrella 下创建租户子分组)
- **Live evidence:** TaskRun `test-dev/smoke-tenant-jvzsv` (Pattern A), `test-dev/smoke-tenant-b-2l4bq` (Pattern B); v146 re-verify `reg146-case1-7lllz`, `reg146-case2-qhh89` — all Succeeded
- **Status:** PASS

### AC-2 — Group Access Token provisioned at `tenantGroup` with requested `access_level` and `scopes`

- **Code evidence:**
  - `scripts/ensure-gat.sh:280-326` — `create_gat()` POSTs `{ name, scopes, access_level, expires_at }` to `/groups/${TENANT_GROUP_ID}/access_tokens`
  - `task.yaml:32-39` — `accessLevel` (default `owner`) + `scopes` (default `["api"]`) params
- **BDD scenario(s):** 测试用例 1, 测试用例 2 (both assert `access-token-name` result is non-empty with the requested shape)
- **Live evidence:** `smoke-tenant-jvzsv`, `smoke-tenant-b-2l4bq`, plus v146 rotate/recreate sweeps — all GAT minted with the requested scopes/access_level
- **Status:** PASS

### AC-3 — Token refresh: rotate-in-place when inputs unchanged; delete + recreate when identity-affecting inputs change

- **Code evidence:**
  - `scripts/ensure-gat.sh:340-353` — `rotate_gat()` POSTs `/groups/:id/access_tokens/:token_id/rotate`
  - `scripts/ensure-gat.sh:387,397,403-405` — explicit branch labels: `status=recreated reason=expired-fallthrough`, `status=recreated reason=identity-changed`, `status=rotated reason=identity-match`
  - Identity suffix encodes (accessLevel, scopes, subgroups)
- **BDD scenario(s):** 测试用例 3 (同参数重跑应触发 GAT 原地 rotate), 测试用例 5 (新增子分组应触发 GAT 重建), 测试用例 6 (scopes 变更应触发 GAT 撤销并重建), 测试用例 7 (accessLevel 变更应触发 GAT 撤销并重建)
- **Live evidence:** v146 — `reg146-case3-t9vwr` (rotate path: `RESULT: ensure-gat status=rotated reason=identity-match`), `reg146-case5-bq7st`, `reg146-case6-8gdqg`, `reg146-case7-zt55n` (all recreate path)
- **Status:** PASS  *(D1/D2 doc-drift recorded as `/feature:docs` followups, not feature defects)*

### AC-4 — Tenant `gitlab` Connector + auth Secret (`connectors.cpaas.io/gitlab-pat-auth`) materialised in connector namespace

- **Code evidence:**
  - `scripts/apply-kubernetes-resources.sh:166-218` — builds Secret manifest with `type: connectors.cpaas.io/gitlab-pat-auth` (line 186), label `connectors.cpaas.io/connector-class: gitlab-pat-auth` (line 182); `kubectl apply --server-side --field-manager=connectors-operator` for both Secret and Connector
- **BDD scenario(s):** 测试用例 1 + 测试用例 2 (resource checks assert Secret type, Connector `connectorClassName=gitlab`, `auth.secretRef`); bonus contract scenario `Task 应声明当前已实现的 4 个 results`
- **Live evidence:** `test/test-smoke-gitlab` Connector + `test/test-smoke-gitlab-secret` Secret (Pattern A); `test/test-smoke-b-gitlab` (Pattern B) — all Ready=True LivenessReady=True
- **Status:** PASS

### AC-5 — Admin credentials only via `gitlabconfig` CSI mount; raw admin PAT/GAT never embedded in Pod spec or tenant Secret

- **Code evidence:**
  - `task.yaml:69-70` — `gitlabconfig` workspace declared (CSI mount); no env vars containing admin PAT in any step
  - `scripts/ensure-group.sh:84-89`, `ensure-subgroups.sh:65-70`, `ensure-gat.sh:122-127` — token parsed from `${glab_home}/config.yml` only
  - `scripts/ensure-gat.sh:16` — `set +x` default; `verbose=true` only enables tracing on non-secret paths
- **BDD scenario(s):** Bonus contract scenario `Task 应声明 admin 与可选 kubeconfig workspaces`; `script.feature` 测试用例 14 (ensure-gat verbose=true 时不应 echo admin PAT — verbose-trace pod asserts admin PAT literal absent)
- **Live evidence:** Static contract verified on deployed Task (`test-dev/gitlab-connector-automatic-creation`) — same workspace shape; admin PAT scrubbing covered at unit-helper layer
- **Status:** PASS

### AC-6 — Idempotency: rerun unchanged → rotate (non-destructive); change subgroup-set / access-level / scopes → controlled recreate

- **Code evidence:** Same paths as AC-3 — `ensure-gat.sh:387-405` 3-way branch driven by identity suffix
- **BDD scenario(s):** 测试用例 3 (rotate-in-place); 测试用例 5/6/7 (recreate on subgroup-set / scopes / accessLevel change)
- **Live evidence:** v146 — `reg146-case3-t9vwr` (rotate); `reg146-case5/6/7-*` (all recreate, all Succeeded)
- **Status:** PASS

### AC-7 — Error handling for the 4 prerequisite mismatches + token-quota exhaustion; fail-fast; partial GitLab state recovered via idempotent rerun (amended)

- **Code evidence:**
  - Pattern A no `can_create_group` → `ensure-group.sh` surfaces verbatim `403 Forbidden` from `POST /groups`
  - Pattern B no `owner` on parent → `ensure-group.sh:240` `parent group '...' not found; admin identity must have owner on the parent path`
  - Path conflict → `ensure-group.sh:184,194,255` `ERROR: group path conflict; existing owner does not match admin ...`
  - Max-expiry rejection → `ensure-gat.sh:316` `ERROR: GitLab rejected token expiry; check the instance-wide max_token_expiry policy`
  - Quota exhaustion → `ensure-gat.sh:310-312` `ERROR: GitLab refused to mint GAT (token quota likely exhausted at this group)`
  - **F1 fix landed in v146** — `ensure-gat.sh:236-260` actionable jq-on-error path: `find_matching_gat()` captures `list_gats` exit code, asserts `jq -e 'type == "array"'` on the body, and surfaces verbatim `message`/`error` field plus hint `admin Connector likely lacks 'api' scope or 'owner' access on the tenant group`
- **BDD scenario(s):** 测试用例 8 (Pattern A no `can_create_group`), 测试用例 9 (Pattern B no owner — F1+F2 evidence case), 测试用例 10 (path conflict), 测试用例 11 + `script.feature` 测试用例 11 unit (max-expiry), 测试用例 12 (quota exhausted)
- **Live evidence:** v146 post-fix — `qa9-v146f-zt6xh` exit=1 with `ERROR: GitLab refused to list access tokens at group id=54260: 401 Unauthorized` + actionable hint (verifies F1); `reg146-case8-q9bk7` exit=1 with `403 Forbidden` (Pattern A); idempotent-rerun recovery semantics documented in amended `feature.md` AC-7 + `tech-design.md` cases 8/9 (verifies F2)
- **Status:** PASS  *(post-amendment to drop "no partial state" wording; F1 + F2 verified live on v146 — see `qa-results.md ## Post-fix verification on v146 bundle`)*

### AC-8 — Task results populated: `tenant-group`, `subgroups`, `access-token-name`, `connector-ref`

- **Code evidence:**
  - `task.yaml:74-83` — declares all four results, `subgroups` typed `array`
  - `task.yaml:1086-1092` — `apply-kubernetes-resources` step wires `$(results.tenant-group.path)`, `$(results.subgroups.path)`, `$(results.access-token-name.path)`, `$(results.connector-ref.path)`
  - `apply-kubernetes-resources.sh:220-225` — emits results
- **BDD scenario(s):** Bonus contract scenario `Task 应声明当前已实现的 4 个 results` (asserts exactly the 4 names + `subgroups` typed `array`); 测试用例 1 (asserts `size(obj.status.results) == 4` and per-result values)
- **Live evidence:** Verified on deployed Task `test-dev/gitlab-connector-automatic-creation`
- **Status:** PASS

### AC-9 — Integration tests cover: fresh A+B, rotate, add-subgroup, scope/access-level change, invalid params, prerequisite-mismatch errors

- **Code evidence:** BDD suite at `connectors-gitlab/tektoncd/tasks/gitlab-connector-automatic-creation/0.1/testing/features/{tektoncd.feature, script.feature}` plus 13 testdata TaskRun fixtures + 3 stub Pod fixtures
- **BDD scenario(s):** Coverage map (qa-results.md `## Per-case results` cases 1–17):
  - Fresh A → 测试用例 1
  - Fresh B → 测试用例 2
  - Rotate → 测试用例 3
  - Add-subgroup → 测试用例 5
  - Scope change → 测试用例 6
  - AccessLevel change → 测试用例 7
  - Invalid params → 测试用例 13 (accessLevel enum validation, fail before any GitLab call)
  - Prerequisite mismatches → 测试用例 8/9/10/11/12
- **Live evidence:** Cases 1, 2, 3, 5, 6, 7, 8, 9 cross-validated live on `daniel-5shk6`; cases 4, 10, 11, 12, 13 BDD-CI-only (4/10/11/12 require GitLab instance-admin scope on the QA env's PAT — fixture-blocked, documented in qa-results.md)
- **Status:** PASS  *(Deviations vs tech-design test-list documented in qa-results.md `## Deviations`; no AC lost coverage; QA reviewer accepted)*

### AC-10 — Documentation: concept page + how-to with both patterns, prereqs, refresh cron pattern, manual cross-group-permissions workaround

- **Scope note:** Documentation lives in connectors-operator (`docs/en/connectors-gitlab/`) and is delivered by Story 3 / PR #1002 (merged) — Story 1's design-change AC verification cross-references this for completeness; deeper doc verification is the responsibility of `/feature:docs`.
- **Code/file evidence:**
  - `docs/en/connectors-gitlab/` content delivered by PR #1002 (Story 3, merged)
  - Doc-sync helper `hack/sync_gitlab_connector_automatic_creation_task_doc.sh` present in operator repo (mirrors Harbor `sync_harbor_connector_automatic_creation_task_doc.sh`)
- **BDD scenario(s):** n/a (file-presence assertion — qa-results.md case 17)
- **Status:** PASS  *(D1/D2 doc-drift on tech-design.md will be folded into `/feature:docs`; not a feature defect)*

### AC-11 — Runs as non-root UID 65532 on linux/amd64 + arm64; cpu/memory requests + limits per step; in-memory `emptyDir` for script + token hand-off

- **Code evidence:**
  - `task.yaml:12` — `tekton.dev/platforms: "linux/amd64,linux/arm64"`
  - `task.yaml:91-99` — `stepTemplate.securityContext`: `runAsUser: 65532`, `runAsGroup: 65532`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`
  - `task.yaml:84-90` — `volumes`: `state` and `secrets` both `emptyDir.medium: Memory`
  - `task.yaml:109,427,601,1059` — `computeResources` (requests + limits) on each of the 4 steps
- **BDD scenario(s):** Bonus contract scenario `Task steps 应声明 non-root 安全上下文` (asserts `runAsNonRoot=true, runAsUser=65532, runAsGroup=65532, allowPrivilegeEscalation=false` on the 4 expected steps)
- **Live evidence:** Verified on deployed `test-dev/gitlab-connector-automatic-creation` (qa-results.md `## Bonus: static Task-contract assertions`)
- **Status:** PASS

## Failing ACs (if any)

None.

## Unchecked tasks

None — all 7 task groups (1.1–1.4, 2.1–2.4, 3.1–3.3, 4.1–4.5, 5.1, 6.1–6.2, 7.1–7.2) in `gitlab-connector-automatic-creation-task/tasks.md` are checked.

## Open followups (acknowledged, non-blocking)

- **D1** — `tech-design.md ## Test Design` case 5 says "rotate" but implementation + BDD do "recreate". Doc-drift only; substance correct. Fix during `/feature:docs`.
- **D2** — `tech-design.md ## Test Design` case 3 wording on Connector `resourceVersion` (controller's status reconcile loop bumps it, not the Task spec). Replace with `generation: 1` stable. P3 docs nit; fix during `/feature:docs`.
- **Process improvements** (input to `/feature:regress` + framework retro): see qa-results.md `## Process improvements` (per-case `method` declaration, live-execution checklist, fixture-provisioning Task, design-doc-drift discovery cadence, BDD-CI-not-sufficient).

## Reviewer

- **Accept reviewer:** Daniel Morinigo (`daniel`)
- **Signed at:** 2026-05-14T05:25:00Z
