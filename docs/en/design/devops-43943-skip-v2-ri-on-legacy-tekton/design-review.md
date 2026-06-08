# Design Review — connectors 和旧版本 tektoncd 一起使用时，不安装 v2 的 ResourceInterface

<!--
Written by /feature:design-review. Outcome is approved | pivot | rework.
-->

> **Status note (v4 shipping contract).** This file captures the design
> iteration history through v1–v4 of DEVOPS-43943. The early decisions
> reference shapes that have since been replaced — `GlobalSpec` wrapper,
> reverse-polarity `disableHigherSchemaResourceInterfaces` bool, per-component
> `IgnoreInstallTransformer` wiring, role-labelled extension ConfigMaps for
> maturity — none of which exist in the shipped code. The current contract
> is fixed in [`product-design.md`](./product-design.md) (admin-facing
> semantics) and [`tech-design.md`](./tech-design.md) (operator-side
> mechanism): `installFlags: map[string]apiextensionsv1.JSON` driven by a
> single catalog in `pkg/controllers/transformer/installflags/`. Use those
> two docs as the source of truth; treat this file as audit history.

## Attendees

- **kychen** — driver / backend (connectors-operator)；self-review +
  签字。
- **Lufan You** — reporter；AC 签字走 **PR async**（PR #1172）。
  `state.yaml.feature.acs_pending_reporter_signoff` 保持 `true`，
  直到 reporter 在 PR comment 上确认。
- Domain owners per affected repo（connectors / connectors-extensions /
  connectors-operator）—— 同步走 PR review，作为 PR approval 一并
  完成 sign-off。

## Checklist

- [x] Goal is unambiguous —— Goal 段经多轮迭代固化为：默认装齐 +
  `spec.global.disableHigherSchemaResourceInterfaces` 反向开关，旧
  Tekton 上 admin 应急 set true；schema-version 维度，不是 version。
- [x] Task breakdown covers the goal (no missing slices) —— 10 个任务
  覆盖 6 个 story，goal coverage check 表显示无孤儿 AC、无孤儿 task。
- [x] Direction is right (no unnecessary rebuilds) —— annotation +
  transformer 对称机制是 design 阶段反复对比 baseline-tracking /
  predicate-registry / featureGates 等若干备选后确定的最简方案；
  IM 只多 4 行代码；reactivity 复用现有 GenerationChangedPredicate。
- [x] Test design is concrete enough for QA to execute as-is ——
  15 条具体测试用例（含 p0/p1/p2 优先级）+ 7 个新增 e2e 测试文件，
  每条用例都标明 input、期望、方法。
- [N/A] For UI slices —— UI slice 已在 research.md 显式 waive。
- [N/A] For risk=sensitive —— risk=standard，不需要 threat model。
- [x] Dependency graph has no cycles —— dependencies.md 5 条边
  （1→2, 1→4, 2→4, 3→4, 2→5），DAG。

## Security considerations

- 新 annotation `connectors.operator.cpaas.io/ignore-install` 提供"标记
  资源不应被 IM 安装"的能力（cleanup-if-present 是副作用）—— 通过
  `isProtectedKind` 护栏永远不会删除 Namespace / PVC / CRD（即使被
  错误地贴上）。
- `GlobalSpec` 包装结构编译期保证新字段不会被复制到 per-component
  CR；测试用例 13 + `higher_schema_global_isolation_test.go` 显式
  验证。
- 反向语义（`disable*` 默认 false）让 operator 在默认配置下行为
  与升级前完全一致，避免升级带来意外删除。

## Decisions

1. **过滤维度选 `schema-version` 而不是 `version`** —— PI 运行时
   matcher 实际用 `max(schema) <= currentSchema` 比较的就是
   schema-version；version 当前主线上没被任何运行时逻辑读取。
2. **字段反向语义 (`disableHigherSchemaResourceInterfaces`)** ——
   默认装齐是现代 Tekton 的常态行为；admin 在旧 Tekton 上踩坑时
   显式 opt-in 禁用。不需要未来翻默认值。
3. **字段位置在 `spec.global` (通过 GlobalSpec 包装)** —— 复用现存
   "影响所有组件的全局设置"语义；GlobalSpec 包装编译期保证不污染
   per-component CR schema。
4. **ignore-install annotation + transformer 对称设计** —— 不引入
   IM baseline-tracking 或 predicate-registry；IM 只多 4 行代码即可
   完成 install ↔ ignore-install (cleanup-if-present) 对偶。通用 IM
   机制。
5. **不引入专属 status condition / 计数 / Event** —— 现有 Ready
   condition + IM 状态足以反映"达到预期"。
6. **AC-4 撤销** —— 状态可观测性走现有路径，不新增字段。
7. **主用户故事明确为反应式 + 极少数情况** —— 触发要求 (a) operator
   升级到带高 schema RI 的版本 + (b) 集群上 Tekton 是旧版本，两者
   同时满足；大多数集群上 admin 永远不需要碰这个字段。
8. **升级时优先推荐升级 Tekton 而不是 disable=true** —— disable 是
   "应急 fallback"，长期保留会用不上后续高 schema RI 的新功能。

## Outcome

**approved**

driver 自身 review 通过；签字走 PR async。

### Pivot / rework notes (if applicable)

（N/A）

## Signatures

- **kychen** (driver / connectors-operator backend): approved,
  2026-05-25 — 见 PR #1172 commit history（11 轮 design 迭代记录
  每一处方向决策）
- **kychen** (driver / re-approval after post-iteration changes):
  approved, 2026-05-25 — covers commits 7d64a36..14256be: disable
  polarity flip, user-story refinement (rare-condition emphasis),
  removal of redundant rationale sections, upgrade-troubleshooting
  section. Stage is already advanced past plan into implement
  (PR #1174 implementation in flight); this re-approval is recorded
  in-place without regressing stage.
- **kychen** (driver / re-approval after implement-stage refactor):
  approved, 2026-05-25 — covers implement-stage architectural cleanup
  (impl branch commit b813df3): (1) `protectedKinds []string` 单一
  来源（removes duplicate kind list between ensureNotInstalled and
  DeleteResources）; (2) MarkIgnoreInstallIf 内置到 transformer.Transform
  built-in 链（removes ad-hoc 接线 from connectors_controller.go）;
  (3) `DisableHigherSchemaResourceInterfaces` 从 GlobalSpec 包装结构
  移到 ComponentCommonSpec，删除 ConnectorsConfigResolver + Watch on
  ConnectorsConfig；改为通过 MergeGlobalSpec → per-component CR 链路
  自动 propagate（cleaner ConnectorsReconciler；trade-off：字段会
  出现在每个 per-component CR 的 schema 上，并允许 per-component OR
  override）。设计文档同步更新，AC 实质不变。
- **kychen** (driver / re-approval after architectural finalization):
  approved, 2026-05-25 — covers impl branch commits 5995569 +
  follow-up: (1) protectedKinds 完全统一到
  `pkg/controllers/transformer/protected.go` 的 exported
  `IsProtectedKind` / `ProtectedKindFilters`；三个消费方
  （installer.ensureNotInstalled、installer.delete()、transformer.InjectOwner）
  共用此唯一来源（消除 owner.go 中早已存在的重复硬编码）；
  (2) MarkIgnoreInstallIf 从 transformer.Transform 的 built-in 链
  彻底移到 per-component 的 GetTransformers —— 新增
  `transformer.IgnoreInstallTransformer(ctx, spec)` 一行接线 helper，
  13 个 per-component 类型的 GetTransformers 都追加这一行；
  transformer.Transform 保持作为通用 pipeline，不 bake-in feature 决策。
  AC 实质不变；该次重构进一步加强"通用机制 / per-component 显式
  声明"的分层。
- **Lufan You** (reporter / AC sign-off): pending —— 等待 PR #1172
  评论确认；
  `state.yaml.feature.acs_pending_reporter_signoff` 保持 `true`，
  在 reporter 确认后由 `/feature:state-repair` 调整。
- **Domain owners**: 走 PR #1172 approval（GitHub 强制 review 要求）。
- **Implementation review**: 走 PR #1174 approval（独立 review surface）。
