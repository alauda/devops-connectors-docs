# 产品设计 — Install Overrides: per-install-flag 版本封顶

> **状态**：已实现（branch `impl/devops-43943-disable-higher-schema-ri`） · **Jira** [DEVOPS-43943](https://jira.alauda.cn/browse/DEVOPS-43943) · **配套技术设计:** [`tech-design.md`](./tech-design.md) · **决策来源:** [`research-community-maturity.md`](./research-community-maturity.md) §5

## TL;DR

**问题**：旧 Tekton 不识别 `schema-version` label，operator 装上去的高 schema RI 会出现 UI 重复或前端解析失败。

**方案**：operator 内部为每个被 gate 的 install flag 注册一个 transformer（`pkg/controllers/transformer/installflags/<feature>.go`），feature 的 maturity 在 transformer 文件里 hardcode。Admin 通过 `ConnectorsConfig.spec.installFlags[<FeatureName>] = "<=N"` 指定**安装版本上限**；resource 的 `resourceinterface.connectors.cpaas.io/schema-version` 大于 N 的会被打 `ignore-install` 注解，installer **仅在 IM-managed 时才删**，外部手建的同名资源保留。

**关键收益**：

- **零配置常态**：99% 集群 admin 不动任何配置
- **历史版本保留**：`"<=N"` 含低版本 —— v1+v2 都装，仅 v3+ 跳过；不会因为 cap 误删 v1 上历史 PipelineInvocation 引用的资源
- **GA 自动锁定**：feature 推到 GA 后 transformer 内部跳过 admin override 解析，强制装机；admin 历史 cap 失效无须清理
- **Ownership 安全门**：admin 翻 cap 不会误删用户手动创建的同名资源（只删带 `cpaas.io/managed-by` 注解的）

---

## 核心机制速览

| 输入 | 来源 | 谁负责 | 何时变 |
|---|---|---|---|
| **资源归属判定 + maturity** | `pkg/controllers/transformer/installflags/<feature>.go` 内部 hardcode（resource match rule + Maturity 常量） | operator 仓库代码 | operator 发版时 |
| **版本判别 label** | `resourceinterface.connectors.cpaas.io/schema-version: "N"` on RI | extension 仓库作者 | extension 发版时 |
| **Admin override** | `ConnectorsConfig.spec.installFlags` (broadcast) + `Connectors<X>.spec.installFlags` (per-component 覆盖) | 集群 admin | kubectl edit（少数应急场景）|

**关键点**（按重要性）：

1. **每个 gated feature 都对应 operator 内一个 transformer 文件**：feature 进出由代码控制，不再有"extension 端注册"通道
2. **GA / deprecated 锁定**：transformer 内部先判 maturity 再决定是否读 admin override —— GA 锁定的 feature 直接跳过 override 解析
3. **beta 是安全默认**：transformer 未读到 admin override / 解析失败 → 走 maturity 默认（Beta install all、Alpha skip all）
4. **Tekton 升级是根因解**，installFlags 是应急 fallback

---

## 问题陈述

旧 Tekton 不识别 `resourceinterface.connectors.cpaas.io/schema-version` label。若 operator 升级后引入 `schema-version > 1` 的 RI，会出现两类症状：

1. **同一资源多版本 RI 并列**：旧 Tekton 不去重 `cpaas.io/hidden`/`schema-version`，category 面板看到多条相似项
2. **新表达式解析失败**：高 schema RI 内部新函数/动态语法，旧前端不认，命中渲染路径直接报错

根本修复是**升级 Tekton**；installFlags cap 是无法立即升级时的**per-install-flag 应急开关**。

---

## Maturity 模型 + 默认行为

### 四档语义

| Maturity | 默认行为 | Admin 可覆盖 | 用途 |
|---|---|---|---|
| `alpha` | skip all matched | ✓ opt-in `"<=N"`（N≥1 装至 N）| 新引入、内测中 |
| `beta` | install all matched | ✓ opt-out via `"<=N"` cap | 默认推开；旧 Tekton 客户可应急封顶 |
| **`GA`** | **install all（锁定）** | ✗ 锁定 | **稳态 feature，admin 失忆也能正确装机** |
| `deprecated` | skip all（锁定）| ✗ 锁定 | 待移除 feature |

### Maturity 升级流程

extension / operator 维护者要把某 feature 推进 maturity：**改 operator 代码里该 feature transformer 文件的 `featureMaturity` 常量并发版**。例：

```go
// pkg/controllers/transformer/installflags/pipeline_integration.go
const featureMaturity = v1alpha1.MaturityBeta   // → MaturityGA 即升级到 GA
```

升级到 GA 后：

- transformer 跳过 admin override 解析
- 旧 admin 历史 cap（如 `pipeline-integration: "<=1"`）失效无效但不会报错 —— **GA 自动收敛**
- admin 无需任何动作

> ⚠️ **隐含的协调要求**：legacy Tekton 客户在 maturity 推进到 GA **前**必须完成 Tekton 升级；否则 GA 阶段强制装机会让原症状回归。该协调由 release notes + 升级 guide 承载（在 docs/en/upgrade/）。

### 解析失败 / 缺 override 的回退

| 情形 | 行为 |
|---|---|
| admin 没写 override key | 走 maturity 默认（Beta install all、Alpha skip all） |
| admin 写了 key 但 value 解析失败（如非 `"<=N"` 形态、非字符串 JSON）| log warning + 走 maturity 默认 |
| value 在 locked maturity 下被设置 | 解析跳过，按 locked 行为 |
| feature 在 transformer 中未注册（admin 写了无人消费的 key）| operator 没人理这个 key —— no-op，不报错（forward-compat） |

**结论**：admin 不设任何 override → 所有 matched 资源按 maturity 默认处理（Beta 全装、Alpha 全跳）。

---

## Admin 接口

### CRD 字段

```yaml
apiVersion: operator.connectors.alauda.io/v1alpha1
kind: ConnectorsConfig
metadata:
  name: connectors-config
spec:
  installFlags:
    pipeline-integration: "<=2"   # 装 schema-version 1 + 2，跳过 3+
```

- key 是**裸 kebab-case feature 名**（无前缀），对应 operator 内某个 transformer 文件的 `featureKey` 常量
- value 类型是 `apiextensionsv1.JSON`（任意 JSON）；具体形态由每个 feature 的 transformer 自行解释
- 当前唯一已注册的 feature 是 `pipeline-integration`（Beta），value 是 `"<=N"` cap 字符串

### Value 形态约定

- `"<=N"`：**含低版本**封顶 —— 装 schema-version ≤ N，跳过 > N
- 其它形态：保留给未来 feature（如 `boolean`、enum 字符串、结构化 JSON）；具体语义见每个 feature 的 release notes

### Per-component override（高级用法）

同名字段同时存在于每个 `Connectors<Type>` CR 上：

- per-component CR 接受**任意** feature 名（无前缀限制）
- merge 优先级：per-component 的 map per-key 覆盖 global（与早期 bool-OR 设计不同）
- **per-component 可以反悔 global**：global 上设了 `"<=1"`、per-component 上设 `"<=3"`，该 component 用 `"<=3"`

### Discover gated resources

```bash
# 1. 看哪些 RI 带 schema-version label（亦即潜在被 cap 的资源）
kubectl get resourceinterface -A \
  -L resourceinterface.connectors.cpaas.io/schema-version

# 2. 看哪些已被打 ignore-install
kubectl get resourceinterface -A \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.connectors\.operator\.cpaas\.io/ignore-install}{"\n"}{end}'
```

---

## Operator 端运行机制（admin 视角）

admin 翻 `installFlags` 后 operator 做了什么，分两步：

1. **transformer 阶段**：feature transformer 在 Transform 阶段决定每条 matched 资源装/跳，把结果**贴成 annotation**：

   ```text
   metadata.annotations:
     connectors.operator.cpaas.io/ignore-install: "true"   # ← 决定 skip 的资源会有
   ```

2. **InstallManifest installer 阶段**：installer 收到 annotation 后按 ownership 决策：

   | 资源在集群里的状态 | 行为 |
   |---|---|
   | 不存在 | 跳过创建 |
   | 存在，且带 `cpaas.io/managed-by`（IM-managed）| **删除**（幂等，NotFound 视为成功） |
   | 存在，无 `cpaas.io/managed-by`（外部手建）| **保留不动** |
   | 任何 Namespace / PVC / CRD（protected kinds）| 无条件保留 |

**关键含义**：

- **flip cap 会真删除高版本的 IM-managed 资源**，不只是"将来不再装"。如果该资源已经在业务里被引用，admin 应当先评估业务影响
- **历史低版本保留**：cap = `"<=2"` 不会动 schema-version 1 的资源（v1 仍 install 路径），只动 schema-version > 2 的
- **Ownership 安全门**：admin 翻 cap 不会误删带相同名字但非 operator 创建的资源
- IM 端这套 annotation + ownership 契约是**通用机制**，未来任何其它 install-time 决策都可以套同一契约

---

## 两条恢复路径

升级 operator 后旧 Tekton 命中症状：

### 路径 1（推荐）：升级 Tekton

升级到识别 `schema-version` 的 Tekton 版本。**根因解**，升级后：

- 前端按 `schema-version` 去重 + 解析跟得上 → 两个症状自然消失
- operator 侧 **零配置**：`installFlags` 保持 unset，所有 RI 都装
- 不留技术债

### 路径 2：installFlags 应急封顶

无法立即升级 Tekton 时：

```yaml
spec:
  installFlags:
    pipeline-integration: "<=1"   # 仅装 schema-version 1，跳过 2+
```

operator 把 schema-version > 1 的同名资源（IM-managed 部分）从集群中移除，category 回退到 v1。Tekton 升级完成后把 cap 抬高（如 `"<=2"`）或移除整个 key，operator 重新装高版本。

**约束**：`GA` maturity 的 feature **忽略 cap**（锁定）。如果某 feature 已经 promote 到 GA 而 Tekton 仍未升级 —— 必须先升级 Tekton。

---

## 完整示例：一条 feature 从 alpha → GA 的生命周期

以 `pipeline-integration` 为例（当前 Beta）：

### R1.0 · feature 处于 alpha

operator 仓库 `pkg/controllers/transformer/installflags/pipeline_integration.go`：

```go
const featureMaturity = v1alpha1.MaturityAlpha
```

任意 extension 仓库 ship schema-version 标注的 RI（无 maturity ConfigMap，maturity 在 operator 内部）—— `pipeline-integration` 是跨所有 connector 的功能开关，下面的例子用 nexus 仅为示例，git / harbor / maven 等所有 RI 都同样参与 gating：

```yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: ResourceInterface
metadata:
  name: nexus-pipeline-build
  labels:
    resourceinterface.connectors.cpaas.io/schema-version: "1"
spec: { ... }
```

operator 升级后：

- **大多数客户**：alpha 默认 skip all → matched RI 全不装（即使 schema-version=1 也跳）→ 现网毫无变化
- **early adopter** 想内测：在 ConnectorsConfig 上设置

  ```yaml
  spec:
    installFlags:
      pipeline-integration: "<=1"     # opt-in，装 v1
  ```

  RI 被装上，admin 自行验证

### R1.1 · feature 推进到 beta（**当前状态**）

operator 代码改 `const featureMaturity = v1alpha1.MaturityBeta` 并发版。

operator 升级到 R1.1 后：

- **现代 Tekton 客户**：beta 默认 install all → RI 自动装上，使用正常
- **旧 Tekton 客户**：RI 装上，但前端解析新表达式失败 → category 不可用。admin 应急封顶：

  ```yaml
  spec:
    installFlags:
      pipeline-integration: "<=1"    # 装 v1，跳过 v2+
  ```

  同时规划 Tekton 升级
- **R1.0 时 opt-in 过的 admin**：`installFlags: { pipeline-integration: "<=1" }` 仍生效，与现在默认相同（v1 install）—— 无副作用，可清理可保留

### R1.5 · feature 推进到 GA

operator 代码改 `const featureMaturity = v1alpha1.MaturityGA` 并发版。前提是社区与升级 guide 已确认 Tekton 兼容性达到 GA 要求。

operator 升级到 R1.5 后：

- **所有客户**：GA 锁定 install all → 全部 schema-version 强制装机
- **旧 admin 忘清的 `installFlags: { pipeline-integration: "<=1" }`**：
  - transformer 检测到 GA 锁定 → 跳过 override 解析 → 全部装
  - admin 无需任何动作；运维不需要去检查每个集群的历史 override —— **这就是 GA 自动收敛**

### 关键观察

| 阶段 | operator 操作 | admin 操作 | 旧 admin 忘事 |
|---|---|---|---|
| alpha | transformer 文件 `featureMaturity = Alpha`，extension ship RI | early adopter 设 `"<=1"` 试用 | N/A |
| beta | transformer 文件 `featureMaturity = Beta` | 旧 Tekton 客户设 `"<=1"` 应急 | 早期 opt-in `"<=1"` 与默认同向，无害 |
| GA | transformer 文件 `featureMaturity = GA` | **无需操作** | 早期 opt-out cap 被忽略，feature 强制装机 |

**结论**：admin 在 installFlags 上写过的任何 cap，都不会随着 feature GA 后变成"踩坑陷阱"——transformer 内部锁定语义把这条出口堵死了。

---

## 失败场景（admin 视角）

| 场景 | 行为 |
|---|---|
| admin 在 GA 的 key 上设 cap | cap 忽略；资源继续全部装机（GA 自动收敛的关键保证）|
| admin 在 deprecated 的 key 上设 cap | cap 忽略；资源继续跳过 |
| admin 写了 operator 内未注册的 feature key | noop，不报错（forward-compat）|
| ConnectorsConfig 不存在 | 全部走 maturity 默认值 |
| value 解析失败（非 `"<=N"` 形态）| log warning + 走 maturity 默认 |
| 多个 transformer 同时声称 match 同一资源 | 首个标记 ignore-install 的生效；后续 transformer 跳过已标记资源（顺序由 `installflags.Register()` 控制）|
| 资源被标 `ignore-install: "true"` 但 kind 是 protected（Namespace/PVC/CRD）| installer 短路保护，资源保留 |
| 资源被标 `ignore-install: "true"` 但无 `cpaas.io/managed-by`（外部手建）| installer 保留不删 |

---

## Out of scope

- 自动探测 Tekton 版本（PipelineInvocation CRD / `feature-flags` ConfigMap）—— 明确拒绝
- 在 connector CR `status` 上暴露 per-install-flag install 决定 —— 现有 `Ready` condition 已足够
- 整个 feature 关闭语义（`installFlags[X] = false` 删全部）—— 仅暴露版本封顶
- 自定义 maturity 值（仅内置四档）
- 跨 namespace 的 feature 作用域（仅集群级）
- Extension 端 ship maturity ConfigMap（已废弃，maturity 在 operator 代码内 hardcode）
- 资源端 `connectors.operator.cpaas.io/feature` 标签（已废弃，资源识别由 transformer 内部 rule 完成）
- semver range 全集（仅 `"<=N"`；`~`、`||`、范围延后到出现第二种语义时再开）

---

## 未来延伸：runtime featureFlags 复用同一套成熟度机制

本次为 install-time gating 引入的 per-install-flag transformer + 内部 maturity 锁定 是**通用语义**。runtime feature flags（`ConnectorsCoreSpec.FeatureFlags`，最终落到 `connectors-system/connectors-config` ConfigMap 的 string-bool 开关）形态上可借鉴：

- 在 ConnectorsCore reconciler 内为每个 runtime flag 注册类似的"per-flag handler"
- handler 内部 hardcode flag maturity；GA flag admin override 自动忽略
- 比目前"手工维护 [Feature Maturity](../../overview/feature_maturity.mdx) 表 + admin 凭 release notes 决定开关"更可靠

本次 feature **不**实现该延伸，仅记录架构同构性供未来 runtime gating 演进对接。
