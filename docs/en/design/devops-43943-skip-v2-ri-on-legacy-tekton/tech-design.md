# 技术设计 — Install Overrides (v4)

> **Jira:** [DEVOPS-43943](https://jira.alauda.cn/browse/DEVOPS-43943) · **配套产品设计:** [`product-design.md`](./product-design.md) · **决策来源:** [`research-community-maturity.md`](./research-community-maturity.md) §5 / §6

## TL;DR

三层分工，全部 operator 代码控制（不再依赖 extension ConfigMap 或资源端 feature 标签）：

```text
Layer 1: 资源 manifest（extension 声明）
   └── resourceinterface.connectors.cpaas.io/schema-version: "N"   (existing label)
         ↓
Layer 2: operator transformer（决策）
   ├── pkg/controllers/transformer/installflags/register.go 维护 Feature 列表:
   │   ├── Key（admin override map key, kebab-case）
   │   ├── Maturity（Alpha / Beta / GA / Deprecated）
   │   ├── Match func（per-resource discriminator）
   │   └── Decide func（解析 admin-supplied raw JSON → per-resource predicate）
   ├── 读 spec.installFlags[<key>] (apiextensionsv1.JSON)
   ├── per-feature Decide(raw) → predicate（pipeline-integration 用 semver constraint）
   └── markIgnoreIf(match, predicate) → 给命中的资源贴 IgnoreInstallKey
         ↓
Layer 3: IM installer（执行）
   ├── ignore-install=true?
   ├── kind protected?      (Namespace / PVC / CRD → 永远保留)
   ├── 存在? (Get)            (NotFound → 跳过)
   ├── 是 IM-managed?        (cpaas.io/managed-by → 删；否则保留)
   └── Delete (IgnoreNotFound 幂等)
```

**关键点**：

- **operator 单方决策**：feature 增减 / maturity 升级都改 operator 代码并发版；extension 端零契约
- **JSON value**：`installFlags[X]` 的 value 是任意 JSON；每个 feature 的 transformer 自行解释
- **semver constraint**：pipeline-integration 支持 Masterminds 完整语法（`<=N`、`>=N`、`<N || >=M`、`!=N`、`1.x` 等），不限于 `<=N`
- **Ownership 安全门**：installer 仅删 IM-managed 资源
- **零 webhook 校验**：admin / extension 写啥就是啥；解析失败 → maturity 默认

---

## 架构速览

| 层 | 文件 | 职责 |
|---|---|---|
| **L1 资源** | extension 仓库 `dist/install.yaml` | 资源已有 `resourceinterface.connectors.cpaas.io/schema-version: "N"` label；**不需要**额外打 feature 标签 |
| **L2 transformer**（operator） | `pkg/controllers/transformer/installflags/` 一个 feature 一个文件 + `installflags/maturity.go` 共享 helper + `installflags/register.go` 入口 | 每个 transformer 工厂读 spec + 自身 maturity → 返回 `mf.Transformer`，标记高版本资源 |
| **L3 IM**（installer） | `pkg/controllers/installer/installer.go` | `ensureResource` 入口分诊；`ensureNotInstalled` 走 ownership 检查（IM-managed 才删） |

---

## CRD schema 与 label 契约

### `ComponentCommonSpec.InstallFlags`

```go
// pkg/apis/v1alpha1/component/component_types.go
type ComponentCommonSpec struct {
    Labels      map[string]string
    Annotations map[string]string
    Registry    string
    InstallFlags map[string]apiextensionsv1.JSON `json:"installFlags,omitempty"`
}
```

- 上一版（ffb400f）是 `map[string]bool`；v4 升级为 `apiextensionsv1.JSON` 任意 JSON
- CRD schema 在 `installFlags` 的 additionalProperties 上设 `x-kubernetes-preserve-unknown-fields: true`，apiserver 接受任意 JSON 值
- key 是裸 kebab-case feature 名（例：`pipeline-integration`），与 transformer 文件内 `featureKey` 常量对齐

### 标签常量

```go
// pkg/apis/v1alpha1/annotations_labels.go
const (
    IgnoreInstallKey                  = "connectors.operator.cpaas.io/ignore-install"
    ResourceInterfaceSchemaVersionKey = "resourceinterface.connectors.cpaas.io/schema-version"
    ManagedByKey                      = "cpaas.io/managed-by"
)

type Maturity string
const (
    MaturityAlpha      Maturity = "alpha"
    MaturityBeta       Maturity = "beta"
    MaturityGA         Maturity = "ga"          // serialized lowercase to match the other tiers; user-visible label remains "GA"
    MaturityDeprecated Maturity = "deprecated"
)
```

**已删除**（v3 → v4 cleanup）：

- `FeatureLabel = "connectors.operator.cpaas.io/feature"` —— 资源端不再打 feature 标签
- `RoleLabel = "connectors.operator.cpaas.io/role"`
- `RoleFeatureMaturity = "feature-maturity"` —— extension 不再 ship maturity ConfigMap

---

## 每个 install flag 的 transformer 文件结构

每个 install flag 在 `pkg/controllers/transformer/installflags/` 下一份独立 `<install_flag>.go`，
只暴露两个函数：

- `match<InstallFlag>(u *unstructured.Unstructured) bool` —— per-resource 命中判定
- `decide<InstallFlag>(raw apiextensionsv1.JSON) (predicate, ok)` —— admin override 解析

metadata（Key + Description + ValueExample + Maturity）在 `register.go` 用 `InstallFlag` literal 集中维护：

```go
// pkg/controllers/transformer/installflags/register.go
func Register(ctx context.Context, spec *component.ComponentSpec) []mf.Transformer {
    flags := []InstallFlag{
        {
            Key:          "pipeline-integration",
            Description:  "Cap which ResourceInterface schema-versions get installed ...",
            ValueExample: `"<=2"`,
            Maturity:     v1alpha1.MaturityBeta,   // 升 GA 改这一行
            Match:        matchPipelineIntegration,
            Decide:       decidePipelineIntegration,
        },
        // 新增 install flag 在这里追加
    }
    out := make([]mf.Transformer, 0, len(flags))
    for _, f := range flags {
        out = append(out, f.Build(ctx, spec))
    }
    return out
}
```

`InstallFlag.Build` 委托给共享的 `applyMaturityGate`（`maturity.go`），把
Lock / 无 spec / 无 key / Decide 解析失败 四条 fallback 路径统一收敛到
`maturityDefault`；只有四个 gate 全通过才会调用 `markIgnoreIf` 给命中
资源打 IgnoreInstallKey 注解。

pipeline-integration 的 `decidePipelineIntegration` 用 Masterminds/semver
解析任意 constraint 表达式（`<=2` / `>=2` / `<2 || >=4` / `!=2` / `1.x`），
predicate 把 RI 的 `schema-version` label 视作 `"N.0.0"` 与 constraint 校验，
不满足的资源被标记。

---

## Shared helpers

```go
// pkg/controllers/transformer/installflags/maturity.go
// 通用 maturity-gating 编排：Lock → 无 spec → 无 key → Decide 解析失败 → maturityDefault；
// 四个 gate 全过 → markIgnoreIf(match, predicate)
func applyMaturityGate(ctx context.Context, f InstallFlag, spec *component.ComponentSpec) mf.Transformer

// GA / Deprecated 锁定
func IsLocked(m v1alpha1.Maturity) bool

// Alpha / Deprecated → markIgnoreIf(match, alwaysTrue)
// Beta / GA         → passthrough()
func maturityDefault(ctx context.Context, key string, match func(*unstructured.Unstructured) bool, m v1alpha1.Maturity) mf.Transformer

// pkg/controllers/transformer/installflags/ignore_install.go
// 单一 ignore-install 注解写入点。per-install-flag Decide 返回 predicate，注解写入集中在这里。
func markIgnoreIf(ctx context.Context, key string, match, shouldIgnore func(*unstructured.Unstructured) bool) mf.Transformer

// 全装（Beta / GA 默认用）
func passthrough() mf.Transformer

// pipeline-integration 私有
// pkg/controllers/transformer/installflags/pipeline_integration.go
//   parseConstraint(raw)         — semver constraint expression → *semver.Constraints
//   effectiveSchemaVersion(u)    — schema-version label → int（缺 label / 非数 / 非正 → 1）
//   decidePipelineIntegration    — constraint 不满足 → ignore
```

加新 install flag = 改两处：

1. 新增 `pkg/controllers/transformer/installflags/<install_flag>.go`，定义 `match<InstallFlag>` + `decide<InstallFlag>`
2. 在 `register.go` 的 `registeredInstallFlags()` 里追加一条 `InstallFlag` literal

顺序敏感性：两个 install flag 命中同一资源时，先标 IgnoreInstallKey 的胜（`markIgnoreIf` 不会重复 set）。

---

## Transform pipeline 接入

```go
// pkg/controllers/transformer/transform.go
func Transform(ctx, namespace, spec, manifest, transformers) (*mf.Manifest, error) {
    ...
    comm := []mf.Transformer{
        CertificateNamespaceTransform(namespace),
        InjectCaFromNamespaceTransform(namespace),
        InjectNamespace(namespace),
        InjectAnnotations(spec.Annotations),
        InjectLabels(spec.Labels),
        WorkloadOverrideTransformer(ctx, spec.Workloads),
        InjectImageRegistry(spec.Registry),
    }
    comm = append(comm, installflags.Register(ctx, spec)...)   // v4
    comm = append(comm, transformers...)
    return mi.Transform(comm...)
}
```

`installflags.Register` 在通用 transformer 之后、component-specific 之前。

---

## Installer ownership 检查

```go
// pkg/controllers/installer/installer.go
func (i *installer) ensureNotInstalled(ctx, expected) error {
    if transformer.IsProtectedKind(expected.GetKind()) {
        return nil   // Namespace / PVC / CRD 永远保留
    }
    existing, err := i.mfClient.Get(expected)
    if apierrs.IsNotFound(err) {
        return nil   // 不存在 → 跳过
    }
    if err != nil {
        return err
    }
    managedBy := existing.GetLabels()[connectorsv1alpha1.ManagedByKey]
    if managedBy == "" {
        // 外部手建 → 保留不动
        log.Infow("preserving non-IM-managed resource on ignore-install", ...)
        return nil
    }
    log.Infow("removing IM-managed resource due to ignore-install", ...)
    if err := i.mfClient.Delete(expected); err != nil && !apierrs.IsNotFound(err) {
        return err
    }
    return nil
}
```

**v4 改动**：原 ffb400f 的 `ensureNotInstalled` 直接 Delete-if-present（仅 protected kinds 短路）；v4 加 Get + `ManagedByKey` 判定，**仅删 IM-managed 资源**。

---

## Composition: MergeCommonSpec

per-key map merge — per-component 覆盖 cluster-wide per-key：

```go
// pkg/apis/v1alpha1/connectorsconfig_func.go
func mergeInstallFlags(global, perComp map[string]apiextensionsv1.JSON) map[string]apiextensionsv1.JSON {
    if len(global) == 0 && len(perComp) == 0 {
        return nil
    }
    out := make(map[string]apiextensionsv1.JSON, len(global)+len(perComp))
    for k, v := range global { out[k] = v }
    for k, v := range perComp { out[k] = v }   // per-component wins per-key
    return out
}
```

**v4 改动**：原 `map[string]bool` 改成 `map[string]apiextensionsv1.JSON`；不再用 `maps.Clone`（对 `apiextensionsv1.JSON.Raw []byte` 非深拷贝；transformer 把 value 当不可变，shallow copy 是正确的）。

---

## Validation

**全部移除**：v4 不做 webhook 校验（沿用 v3 信任>强制）。

**软退化**：transformer 解析失败（如 value 不是 `"<=N"` 字符串、kvjpalue 类型不对）→ log warning + 走该 feature 的 maturity 默认。misconfig 不升级为 skip，避免静默隐藏 extension bug。

未注册的 feature key（admin 写了 operator 内不存在的 feature 名）：no-op，不报错。

---

## 响应链

```text
admin: kubectl edit connectorsconfig
   ↓ ConnectorsConfig informer
ConnectorsConfigReconciler
   ↓ resolveComponents → MergeCommonSpec → 更新 per-component CR
per-component CR Generation++
   ↓ ConnectorsReconciler.reconcile
   ↓ load manifest from kodata
   ↓ transformer.Transform → installflags.Register(spec) → 每个 feature transformer 决策
IM Generation++
   ↓ InstallManifestReconciler → ensureResource 分诊
   ↓                            ├── 无 ignore-install → Ensure
   ↓                            └── ignore-install=true → ensureNotInstalled
   ↓                                                       ├── protected kind → 保留
   ↓                                                       ├── 不存在 → 跳过
   ↓                                                       ├── IM-managed → Delete
   ↓                                                       └── 外部 → 保留
集群上资源被删 / 装
```

端到端 < 30s；无 operator restart。

---

## 失败模式

| 场景 | 行为 |
|---|---|
| admin 在 GA feature 上设 cap | transformer 跳过解析，按 maturity 默认装机 |
| admin 在 deprecated feature 上设 cap | 同上，跳过装机 |
| admin 写了未注册的 feature key | no-op，不报错 |
| Value 不是合法 JSON | apiserver 在 CRD 校验阶段拒绝（不是 transformer 阶段） |
| Value 是合法 JSON 但 transformer 不认（如 `{"foo": 1}`）| log warning + 走 maturity 默认 |
| `"<=abc"` 等无效 semver constraint | Masterminds 解析失败 → log warning + 走 maturity 默认 |
| `"<=0"` 等合法但极端 cap | constraint 正常生效；所有 RI 的 effective schema-version ≥ 1 都不满足 → 全部标 ignore |
| 资源端 `schema-version` label 为 `-5` / `0` / `abc` | `effectiveSchemaVersion` 归一到 1，按 v1 处理 |
| `ConnectorsConfig` 不存在 | per-component spec 字段为零；全 maturity 默认 |
| `ignore-install=true` + protected kind | installer 保护短路 |
| `ignore-install=true` + 外部手建资源 | installer 保留不动 |
| Reconcile 中途 admin 翻转 cap | 短暂可能"先装再删"或反向；下次 reconcile 收敛 |

---

## 测试设计

| 层 | 文件 | 覆盖 |
|---|---|---|
| Unit · `parseConstraint` | `pkg/controllers/transformer/installflags/pipeline_integration_test.go` | Masterminds 合法形态（`<=2` / `<3` / `>=2` / `>=1, <=3` / `<2 \|\| >=4` / `=2` / `!=2` / `1.x` / `~1.2` / `^1.2`）+ 4 个无效形态（空 / 乱码 / JSON number / JSON object）|
| Unit · `effectiveSchemaVersion` | 同上 | 缺 label / 非数 / 0 / 负数 / 1 / 2 / 10 → 全归一到 ≥1 |
| Unit · `markIgnoreIf` | `pkg/controllers/transformer/installflags/maturity_test.go` | matched + predicate true / matched + predicate false / unmatched / alwaysTrue 兜底 |
| Unit · `IsLocked` | 同上 | 4 maturity |
| Unit · `decidePipelineIntegration` 端到端 | `pipeline_integration_test.go` | Beta default 全装 / cap=`<=2` 标 v3 / 非 RI 不动 / 缺 label 等同 v1 / `>=2` 标 v1 / `<2 \|\| >=4` 中间空洞 / `!=2` / `<=0` 全标 / parse fail 退 Beta default / 无 override 退 default / nil spec 退 default |
| Unit · `matchPipelineIntegration` | 同上 | git/harbor/nexus/maven RI 命中 / ConfigMap / Deployment 不命中 |
| Unit · `Register` | 同上 | 当前注册 feature 数量一致性 |
| Unit · `ensureNotInstalled` ownership | `pkg/controllers/installer/installer_test.go` | 9 case：IM-managed 删 / 外部保留 / NotFound idempotent / Get error 返回 / Delete NotFound 幂等 / Delete 错误返回 / 3 protected kinds |
| Unit · `MergeCommonSpec` | `pkg/apis/v1alpha1/connectorsconfig_func_test.go` | nil / cluster-wide only / perComp only / disjoint union / per-component wins per-key |

**Gap**：真正的 envtest live-reconcile 沿用 v2 NOTE，仍延后。

---

## 迁移说明（v3 → v4）

v3（ffb400f / cc14051）的部分实现合到 `impl/devops-43943-disable-higher-schema-ri` 但**未上线**（origin 上同分支已被 v4 squash 力推覆盖）。v4 是**理想化重做**，无需向后兼容。

| 项 | v3 状态 | v4 操作 |
|---|---|---|
| `InstallFlags map[string]bool` | 已合 | **改类型** → `map[string]apiextensionsv1.JSON` |
| `FeatureLabel` | exported | **删除** |
| `RoleLabel` / `RoleFeatureMaturity` | exported | **删除** |
| `Maturity` type + 4 const | exported | **保留**（每个 install-flag transformer 用） |
| `extractFeatureMaturity` | 函数 | **删除**（maturity 移入 transformer 文件 hardcode） |
| `featureDecider` | 函数 | **删除**，由 `installflags.Register()` 入口 + per-install-flag transformer 替代 |
| `parseMaturity` | 函数 | **删除**（不再有外部 maturity ConfigMap 输入需要解析） |
| `pkg/controllers/transformer/install_overrides.go` | 文件 | **删除** |
| `pkg/controllers/transformer/install_overrides_test.go` | 文件 | **删除**（覆盖移入 `installflags/*_test.go`）|
| `mergeInstallFlags` | bool 版 | **重写**为 JSON 版 |
| `ensureNotInstalled`（仅 protected-kind 短路）| 已合 | **加 ownership check** — 仅删 `cpaas.io/managed-by` 资源 |
| `pkg/controllers/transformer/installflags/` | 不存在 | **新增**整个包：`maturity.go` + `ignore_install.go` + `register.go` + `pipeline_integration.go` + 各自 test |
| BDD fixture（`higher-schema-ri`） | 已更新 v3 | **未实际 ship 测试**，本轮 v4 无需迁移 |
| 用户文档（resource_interface / upgrade / feature_maturity）| 描述 ffb400f bool API | **重写**为 `"<=N"` cap 语法 |
| Extension 端 ConfigMap | v3 设计要求 ship `role=feature-maturity` ConfigMap | **取消该契约** — extension 端无需做任何事 |

> **v4 是孤立交付**：从 upstream/main 看就是一个 squash commit，不需要分阶段迁移。
