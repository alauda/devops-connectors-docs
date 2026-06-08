# Feature: connectors 和旧版本 tektoncd 一起使用时，不安装 v2 的 ResourceInterface

<!--
This file is the human-readable index of the umbrella. state.yaml is the
machine-readable source of truth. Both are written by /feature:* commands;
manual edits to state.yaml are detected by integrity hash.
-->

- **Jira:** DEVOPS-43943 — [link](https://jira.alauda.cn/browse/DEVOPS-43943)
- **Parent epic:** (none — standalone feature)
- **Reporter:** Lufan You
- **Assignee:** Kaiyong Chen
- **Blocks:** (none)

## Classification

- **Profile:** full  (light | standard | full)
- **Risk:** standard  (low | standard | sensitive)
- **Repos affected:** connectors, connectors-extensions, connectors-operator
- **Effort (advisory):** days  (hours | days | weeks | months)
- **Driver:** kychen

## Summary

After DEVOPS-43899 introduced ResourceInterface versioning (v2 RIs carry
`resourceinterface.connectors.cpaas.io/version` and `schema-version` labels,
and the PipelineInvocation runtime picks the highest matching schema), a
v2-bearing connectors release can still be installed on an older Tekton
that has no version awareness. On such a Tekton, two concrete user-visible
symptoms appear:

1. **同一资源的多个版本 RI 在 UI 上重复展示**：旧 tektoncd 不识别
   `cpaas.io/hidden: "true"` 隐藏语义，也不识别 `schema-version` label，
   于是同一资源的 v1 与 v2 RI（例如 `harborociartifact` 与
   `harborociartifact-v2`）会**并列**出现在 category 面板里，用户看到
   两条几乎一样的条目，搞不清该选哪个。
2. **高 schema RI 里使用了旧前端解析器不认识的新函数 / 表达式**：
   schema 演进会引入新的表达式或函数（descriptor / 校验 / 动态 option
   等位置），旧 tektoncd 前端的解析器不认识这些新语法 —— 一旦集群里
   存在这种高 schema RI，凡是命中它的渲染路径就会报解析错误，连
   v1 路径下能正常打开的界面也可能被波及。

用户解决这两个问题的路径有两条：

1. **升级 tektoncd 到带 schema-version + hidden-label 感知的版本（推荐）**
   —— 这才是问题根因。升级后新 tektoncd 自然识别 `schema-version` /
   `cpaas.io/hidden` label 做版本去重，且前端解析器跟上 schema 演进
   认识新函数 / 表达式；admin 在 operator 侧 **不需要做任何配置**。
2. **封顶可装的 schema-version**（在无法立刻升级 Tekton 时使用）
   —— 在 `ConnectorsConfig.spec.installFlags` 上为受影响的
   feature 写入 `"<=N"` 范围（例如
   `pipeline-integration: "<=2"`）。operator 会把所有 schema-version
   高于 N 的资源跳过创建；已装的同名资源**仅在 IM-managed 时才删**，
   外部手建的同名资源原地保留。高 schema RI 不落地 → 两个症状都消失。
   升级 Tekton 后把 cap 调高（或移除 key）即可恢复安装。每个被 gate 的
   feature 的 maturity 在 operator 代码里 hardcode；`GA` 成熟度的资源
   忽略 admin override，不能用 installFlags 跳过。

This feature ships the second path: a per-install-flag install-gating
mechanism (per-install-flag transformers under
`pkg/controllers/transformer/installflags/`) so high-schema-version RIs
can be selectively capped via `ConnectorsConfig.spec.installFlags`,
while keeping lower-schema RIs and all GA RIs available so the
connector stays functional.

## Cross-feature collisions

<!-- Populated by /feature:init and /feature:plan -->

None — scanned all non-archived umbrellas under `docs/en/design/`; no
in-flight feature touches the ResourceInterface install path on `main`.

## Definition of Done

- [ ] Research (profile=full only)
- [ ] Design + review (approved gate)
- [ ] POC (if offered)
- [ ] Plan (story groups created; per-story reviewers signed)
- [ ] Implement (all PRs merged, BDD green)
- [ ] Integrate (bundle tag recorded)
- [ ] QA (all p0 test cases pass)
- [ ] Accept (all ACs pass)
- [ ] Docs (release notes + doc index)
- [ ] Regress (regression suite passed against bundle)
- [ ] Security sign-off (risk=sensitive only — N/A)
- [ ] Retrospective (or opt-out for light) — runs BEFORE ship
- [ ] Ship (Jira → Done, maturity report written, archive immediately,
  back-link on parent epic if any)

## Artifacts

- `state.yaml` — machine-readable state
- [handoff.md](./handoff.md) — driver pick-up snapshot
- [dependencies.md](./dependencies.md) — story dependency graph
- [research.md](./research.md) — profile=full only
- [product-design.md](./product-design.md)
- [tech-design.md](./tech-design.md)
- `threat-model.md` — risk=sensitive only (N/A)
- `ui-prototype.drawio` — when any story has slice=ui
- [design-review.md](./design-review.md)
- `poc.md` — optional
- `qa-packet.md`
- `qa-results.md`
- `acceptance.md`
- `release-notes.md`
- `docs-changes.md`
- `regression.md`
- `security-sign-off.md` — risk=sensitive only (N/A)
- `retrospective.md` — written before ship
- `maturity-report.md` — written at ship

Post-release bugs against this feature attach to the parent epic's
`post-release-log.md` (see `parent_epic` field above). This umbrella
archives at ship and is not re-opened.
