# 依赖图 — connectors 和旧版本 tektoncd 一起使用时，不安装 v2 的 ResourceInterface

<!--
Story 级依赖图。由 /feature:research 写出，由 /feature:design 与
/feature:plan 进一步细化。被 /feature:implement 用来排定 sub-agent
派发顺序。

格式：`<from-story-id> -> <to-story-id>   # 原因`
环会在 /feature:design-review 阶段被拒绝。
-->

```text
1 -> 2    # ConnectorsConfig schema-version 开关 + resolver 是 transformer 的前置
1 -> 4    # resolver 与 reactive watch 是集成测试矩阵的前置
2 -> 4    # transformer + status 面 + IM annotation handler 是集成测试矩阵的前置
3 -> 4    # 在真实 extension 上跑通集成测试之前，先把 `schema-version` label 规则在 extension 仓库里落实
2 -> 5    # 行为存在之后用户文档才能描述
```

## 备注

- Story 3（extension label 审计）与 story 1、2 互不依赖，可以并行
  派发。截至当前主线上还没有真正落地的 v2 RI；当设计分支把 Maven /
  NPM / OCI / SonarQube / Harbor 的 v2 也带入主线后，这一审计才
  变得关键。
- Story 6（core 仓库 label 契约复述）没有入边也没有出边，是 p2 ——
  只在 /feature:design-review 中发现 core 仓库的契约出现漂移时才
  提升优先级。其首要价值是在 core 仓库里显式区分 `version`（PI
  运行时匹配）与 `schema-version`（前端渲染能力）两个独立维度。
- 没有跨 feature 等待（`wait-for=<feature-id>:<story-id>`）——
  /feature:init 的碰撞扫描结果为空。
- 依赖边相对 /feature:research 阶段没有变化；只是把原因文案刷新
  成新的（基于 ConnectorsConfig + `version` label 的布尔声明式信号）模型。
- Story 2 的实现方案在 /feature:design 阶段经多轮讨论调整：
  - 原 research：靠 IM owner-ref 自动 GC（实际不存在该能力）
  - 中间方案 1：baseline-tracking（`status.appliedManifests` + 差集 GC）
  - 中间方案 2：predicate-registry（IM 侧 Registry 接口）
  - 中间方案 3：`spec.featureGates` 通用 map
  - 中间方案 4：`spec.install` / `spec.installation` 新顶层段
  - 中间方案 5：`spec.resourceInterface.*` 专属子段
  - 中间方案 6：**annotation + transformer + GlobalSpec 包装结构**
    把字段隔离在 `spec.global` 之外（编译期保证不漏到 per-component CR）。
    implement 阶段评审后回退此点（见下方）。
  - 最终方案：**annotation + transformer + 字段直接放
    `ComponentCommonSpec` + 统一 transformer 注册位置 + protectedKinds
    单一来源**。具体而言：
    - `connectors.operator.cpaas.io/ignore-install` annotation 作为
      IM 的通用 install/delete 对偶机制（IM 多 4 行代码 + 对称的
      `ensureNotInstalled` 方法）
    - `DisableHigherSchemaResourceInterfaces` 字段加在
      `component.ComponentCommonSpec` 上，与 labels/annotations/registry
      同级；`ConnectorsConfig.spec` 把 `ComponentCommonSpec` inline 嵌入
      （字段直接挂在 spec 根），per-component CR（ConnectorsCore /
      Harbor / …）的 spec 通过 `ComponentSpec` 嵌入同一类型
    - `MergeCommonSpec` 用 per-key map merge 合并 InstallFlags
      （per-component 同 key 胜 cluster-wide，缺 key 走 cluster-wide），
      registry 走 component-wins-if-non-empty，labels / annotations 走
      default-map merge
    - ConnectorsReconciler **不 watch ConnectorsConfig**；链路通过
      ConnectorsConfigReconciler → per-component CR → 自身 watch 自然
      传播
    - `MarkIgnoreInstallIf` transformer 与 `higherSchemaRIDecider`
      工厂在 `pkg/controllers/transformer/transform.go` 的 `Transform()`
      函数内作为 built-in 注册（与 InjectLabels / InjectAnnotations
      等同级），ConnectorsReconciler 内不内联接线
    - `protectedKinds []string` package-level 常量为 IM installer 的
      唯一保护列表来源，`ensureNotInstalled` 与 `DeleteResources` 的
      过滤器构造逻辑都从此读
  方案 6 → 最终方案的转换发生在 implement 阶段评审：评审认为
  "GlobalSpec 包装强制 ConnectorsReconciler watch ConnectorsConfig"
  引入了跨 CR 耦合，违反了 ConnectorsReconciler 的自封闭性。改成
  让字段经由 MergeCommonSpec 自动 propagate 到 per-component CR，
  ConnectorsReconciler 只看自己的 CR。代价是字段会出现在每个
  per-component CR 的 schema 上 —— 但这其实是 feature（admin 能
  per-component 独立 opt-in 禁用单个组件）。
