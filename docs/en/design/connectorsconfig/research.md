# ConnectorsConfig 调研文档

## 1. 背景与问题

当前 Connectors Operator 安装流程需要分别创建 13 个独立 CR：ConnectorsCore、ConnectorsGit、ConnectorsGitHub、ConnectorsGitLab、ConnectorsOCI、ConnectorsK8S、ConnectorsMaven、ConnectorsNPM、ConnectorsPyPI、ConnectorsHarbor、ConnectorsSonarQube、ConnectorsNexus、ConnectorsJFrog。另外 OperatorHub 中还有 ConnectorClass 和 Connector 资源的创建入口。

用户痛点：
- 概念多且关系不清晰，普通用户难以理解各 CR 的作用和依赖
- 安装过程繁琐，需逐一创建多个 CR
- 容易遗漏或配置错误
- 升级和维护复杂度高

需求（DEVOPS-42744）：
- 提供单一 CR 完成所有组件安装
- Operator 部署后自动完成安装
- 支持各组件的启用/禁用和配置
- 移除 OperatorHub 中 ConnectorClass/Connector 创建入口

## 2. Tekton Operator TektonConfig 调研

### 2.1 TektonConfig 概述

TektonConfig 是 Tekton Operator 提供的顶层 CR，用于从单一控制点安装、配置和管理所有 Tekton 组件。

- API Group: `operator.tekton.dev`
- Kind: `TektonConfig`
- Scope: **Cluster-scoped**（全局单例，名称固定为 `config`）
- Version: v1alpha1

### 2.2 组件控制机制

TektonConfig 使用 `profile` 字段控制安装哪些组件：

| Profile | 安装组件 |
|---------|---------|
| lite | Pipeline controller only |
| basic | Pipeline + Triggers |
| all | Pipeline + Triggers + Hub + Chains + Dashboard + Results |

每个组件在 spec 中有独立配置段：

```yaml
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonConfig
metadata:
  name: config
spec:
  profile: all
  targetNamespace: tekton-pipelines
  pipeline:
    enable-api-fields: beta
    performance:
      disable-ha: false
  trigger:
    enable-api-fields: stable
  hub:
    enable-devconsole-integration: true
  result:
    db_host: tekton-results-postgres
  chain:
    artifacts.taskrun.format: in-toto
  dashboard: {}
```

### 2.3 架构：两级 Controller 模式

```
TektonConfig CR
    │
    └── TektonConfig Reconciler (tekton-operator-lifecycle)
            │
            ├── 创建/更新/删除子 CR
            │   (TektonPipeline, TektonTrigger, TektonChain, TektonHub, TektonResult, TektonDashboard)
            │
            └── 每个子 CR → Component Reconciler → TektonInstallerSet → 部署资源
```

- **TektonConfig Reconciler**：根据 profile 和 spec 创建/更新子 CR
- **Component Reconciler**（如 TektonPipeline Reconciler）：从 kodata 加载清单，创建 TektonInstallerSet
- **TektonInstallerSet Reconciler**：四阶段部署（CRDs → ClusterScoped → NamespaceScoped → Workloads）

### 2.4 子 CR 管理

子 CR 创建模式（以 TektonHub 为例）：

```go
func GetTektonHubCR(config *v1alpha1.TektonConfig, operatorVersion string) *v1alpha1.TektonHub {
    ownerRef := *metav1.NewControllerRef(config, config.GroupVersionKind())
    return &v1alpha1.TektonHub{
        ObjectMeta: metav1.ObjectMeta{
            Name:            v1alpha1.HubResourceName, // "hub"
            OwnerReferences: []metav1.OwnerReference{ownerRef},
            Labels: map[string]string{
                v1alpha1.ReleaseVersionKey: operatorVersion,
            },
        },
        Spec: v1alpha1.TektonHubSpec{
            CommonSpec: v1alpha1.CommonSpec{
                TargetNamespace: config.Spec.TargetNamespace,
            },
            Hub: config.Spec.Hub,
        },
    }
}
```

关键设计：
- **OwnerReference + controller=true**：TektonConfig 是子 CR 的控制器
- 子 CR 使用**固定名称**（`pipeline`、`hub`、`trigger`）
- 携带版本标签 `operator.tekton.dev/release-version`
- **CRD 和 Namespace 不设 OwnerReference**，防止删除 TektonConfig 时级联删除

### 2.5 自动安装机制

通过 ConfigMap 控制自动安装：

```yaml
kind: ConfigMap
metadata:
  name: tekton-config-defaults
  namespace: tekton-operator
data:
  AUTOINSTALL_COMPONENTS: "true"
  DEFAULT_TARGET_NAMESPACE: tekton-pipelines
```

启动流程：
1. Operator 启动，读取 ConfigMap
2. 检查是否已存在 TektonConfig CR
3. 如不存在且 `AUTOINSTALL_COMPONENTS=true`，创建默认 TektonConfig（name=`config`, profile=`all`）
4. TektonConfig Reconciler 接管后续安装

### 2.6 升级路径

使用 Pre-upgrade 函数链进行版本迁移：

```go
var preUpgradeFunctions = []upgradeFunc{
    resetTektonConfigConditions,       // 重置过时 conditions
    upgradePipelineProperties,          // 更新默认配置
    copyResultConfigToTektonConfig,     // 从旧 TektonResult CR 迁移配置
    deleteTektonResultsTLSSecret,       // 清理旧资源
}
```

迁移旧 CR 示例（TektonResult → TektonConfig）：
1. 检测独立 TektonResult CR 是否存在
2. 存在则复制配置到 TektonConfig.Spec.Result
3. 清理旧 CR

### 2.7 版本管理

通过 ConfigMap 指定组件版本：
- 读取 `pipelines-info` ConfigMap 的 `target-version`
- 未指定或版本不存在时使用最新版本
- 版本变更检测：operator 版本 + 组件版本组合为 InstallerSet 版本标签，任何变更触发重建

### 2.8 状态聚合

- TektonConfig Ready = 所有启用组件子 CR 均 Ready
- 组件未 Ready 时记录具体失败信息：`MarkComponentNotReady()`
- 每个子组件通过标准 Conditions 报告状态

## 3. 与 Connectors Operator 的对比分析

### 3.1 架构对比

| 维度 | Tekton Operator | Connectors Operator（现有） |
|------|----------------|--------------------------|
| 顶层 CR | TektonConfig (Cluster-scoped, 单例) | 无（需新增 ConnectorsConfig） |
| 组件 CR | TektonPipeline/TektonTrigger/... | ConnectorsCore/ConnectorsGit/... |
| 清单安装 | TektonInstallerSet (4 阶段) | InstallManifest (4 阶段) |
| 通用 Reconciler | 每组件有独立 Reconciler | 单一泛型 ConnectorsReconciler |
| 清单来源 | kodata/\<component\>/\<version\>/ | kodata/\<component\>/\<version\>/ |
| 父子关系标签 | OwnerRef + version label | labels (`cpaas.io/name`, `cpaas.io/namespace`) |

### 3.2 ConnectorsConfig 方案与 TektonConfig 的差异

| 维度 | TektonConfig | ConnectorsConfig（方案） | 差异原因 |
|------|-------------|----------------------|---------|
| 作用域 | Cluster-scoped | **Namespace-scoped** | 与现有 Connector CR 保持一致 |
| 组件启用 | profile 枚举（lite/basic/all） | **per-component enabled bool** | Connectors 组件间依赖少，需更细粒度控制 |
| 父子 OwnerRef | controller=true | **controller=false** | 子 CR 已有 ConnectorsReconciler 作为 controller |
| 自动创建 | ConfigMap 开关 | **ConfigMap 开关 + Bootstrap Runnable** | 借鉴 Tekton，同时支持根据已有 CR 状态动态决定行为 |
| 升级迁移 | Pre-upgrade hooks 迁移配置 | **保留配置 + 删除旧实例 + 统一重建** | 消除跨 namespace 问题，由 ConnectorsConfig 统一管理 |
| 子 CR 命名 | 固定名称 | **确定性名称** | 统一重建，不存在自定义命名兼容问题 |
| Namespace 确定 | spec.targetNamespace 显式指定 | **环境变量/ConfigMap 指定，升级时以 ConnectorsCore NS 为准** | 灵活性 + 升级兼容 |

### 3.3 可复用的设计模式

| 模式 | Tekton 实现 | Connectors 应用 |
|------|------------|----------------|
| 子 CR 工厂函数 | `GetTektonHubCR(config, version)` | 为每个组件提供 `buildConnectorsXxxCR()` |
| CRD/NS 保护 | 不对 CRD/Namespace 设 OwnerRef | 同样处理 |
| 状态聚合 | `MarkComponentNotReady()` | 聚合子 CR Ready 状态到 ConnectorsConfig |
| Spec 漂移修复 | TektonConfig reconcile 覆盖子 CR spec | 同样处理，通过 Event 通知用户 |

### 3.4 不适用的模式

| 模式 | 原因 |
|------|------|
| Profile 枚举 | Connectors 组件间依赖简单，无需预定义安装组合 |
| Cluster-scoped | 与现有 namespace-scoped CR 设计不一致 |
| controller=true OwnerRef | 会与现有 ConnectorsReconciler 的 controller 角色冲突 |
| ~~ConfigMap 开关控制~~ | 实际上已采纳：ConfigMap + Bootstrap Runnable 结合使用 |

## 4. 结论

基于 Tekton TektonConfig 的实践，ConnectorsConfig 应采用类似的两级编排架构：

1. **ConnectorsConfig** 作为顶层编排 CR，管理所有组件的安装和配置
2. **保留现有架构**：不替换 ConnectorsReconciler 和 InstallManifest 机制
3. **ConfigMap + Bootstrap 自动创建**：借鉴 Tekton 的 ConfigMap 开关模式，支持通过 ConfigMap 或环境变量控制是否自动创建
4. **旧数据迁移**：升级时保留旧 CR 配置，删除旧实例，由 ConnectorsConfig 在目标 namespace 统一重建，彻底消除跨 namespace 问题
5. **Namespace 确定**：优先使用环境变量/ConfigMap 指定，升级时以 ConnectorsCore 所在 namespace 为准
