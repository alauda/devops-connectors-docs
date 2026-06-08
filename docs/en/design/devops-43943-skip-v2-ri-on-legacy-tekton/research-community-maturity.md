# 社区调研 — 功能成熟度与多版本选择机制

> 本文是 `research.md`（仓内现状）的补充。聚焦 CNCF / Kubernetes 生态邻近项目
> 如何向 admin 暴露 **成熟度分层**、**逐 feature 安装控制**、**多版本共存**。
> 产出时间：2026-05-28。背景：团队提出 `ConnectorsConfig.spec.installFlags`
> 的值不能继续停留在 `bool`，不同 feature 可能需要不同的选择形态（版本上限、枚举
> 等），通用 decider 也可能不是合适的抽象，需要在 v3 / v4 重新设计前先看清社区
> 怎么做的。

## 1. 为什么调研

`ffb400f` 落地了一套基于 `connectors.operator.cpaas.io/feature` 标签 +
maturity ConfigMap 的二值安装开关。后续设计讨论暴露出两个薄弱点：

1. **一种 value 类型撑不住所有 feature。** 今天 `installFlags[feature] = bool`
   能处理「v2 RI 装/不装」，但下一个 feature 可能需要「最高安装版本 = v2」或
   「在 {lru, lfu} 中挑一个」。我们要决定：是把 value 通用化（如何通用化），
   还是干脆把通用 decider 换成 per-install-flag transformer 由 operator 代码各自解释。

2. **同一 feature 的多个版本必须并存。** Harbor v1 + v2 RI 不是「v2 替换 v1」
   的关系 —— v1 必须留下，因为历史 PipelineInvocation 仍按名引用它。Admin 的
   常见操作是「**对最高已安装版本封顶**」，而不是「整体开/关一个 feature」。

本文整理四类项目的处理方式，提炼可借鉴、可改造、可放弃的模式。

## 2. 按生态分组的调研结果

每节记录 **机制**、**API 形态**、**GA 后的锁定行为**、**多版本共存方式**。
能直接引用原文的地方给出引用。

---

### 2.1 Tekton Pipelines & tektoncd-operator

#### `feature-flags` ConfigMap (`enable-api-fields`)

- 一个枚举字段 `enable-api-fields: stable | beta | alpha` 充当**累积式上限**，
  `alpha` 蕴含 `beta` 蕴含 `stable`。
- Webhook 在准入阶段强制门禁：alpha API 字段在所有 tier 下都*结构上存在于
  schema*，但若 gate 低于其 tier，则会被拒绝。 ([TEP-0033][tep-0033])
- 无法表达「只要 beta，不要 stable」—— stable 特性不可关。一旦字段升 stable，
  门禁就从代码里彻底去掉。
- 集群级单一开关，无 per-feature 粒度。仅**行为变更类**（不引入新 API 字段）
  才单独留 per-feature 标志，例如 `enable-tekton-oci-bundles`、
  `enable-cel-in-whenexpression`。

**反向门禁模式（`disable-inline-spec`）**：唯一一个能关掉已 stable 能力的机制，
接受逗号分隔的资源类型列表（`pipelinerun,taskrun`）。是 Tekton 家族里最接近
「我已发布的 stable 特性，但部分集群 admin 仍需要 opt-out」的先例。

#### TektonConfig / TektonPipeline 投影

`tektoncd-operator` 把 `feature-flags` 的键 1:1 平铺为 `TektonPipeline.spec`
的字段（`enable-api-fields: beta`、`enable-custom-tasks: true` …）。CRD 是唯一
真实来源；直接编辑 ConfigMap 会在 reconcile 时被覆盖。([TektonConfig 文档][tcfg])

`TektonConfig.spec.profile` 枚举（`lite | basic | all`）选择**哪些组件被安装**，
但不是版本选择器。TektonConfig 内没有「在一个 install 内挑某个大版本 Tekton」
的机制 —— operator 二进制内置某一版本 Tekton。

#### 多版本共存：v1beta1 → v1

- v0.43.0 v1 CRD 以 preview 形式引入，与 v1beta1 并列提供。
- v0.50.0 v1beta1 标记弃用（1 年移除窗口）。
- v0.62.0 (LTS) 移除 v1beta1。
- **没有 admin 旋钮**让用户「跳过 v1 安装」或「封顶 v1beta1」——
  两个版本都由 kube-apiserver 经 `CRD.spec.versions[]` 服务，conversion webhook
  自动处理存储侧迁移。
- 唯一例外是 `custom-task-version: v1alpha1|v1beta1`，控制 **controller 创建**
  哪个 API 版本（不是 apiserver 服务哪个）。仅在 Run → CustomRun 过渡期间存活
  了 4 个 release（v0.43 → v0.46）后硬移除。

#### Tekton Hub

- catalog 目录支持同一 Task 多版本（如 `tasks/git-clone/0.7`、`0.8`、`0.9`）。
- 调用方通过 `taskRef.resolver: hub` + `params.version` 显式 pin。
- `metadata.annotations.tekton.dev/deprecated: "true"` 仅为提示，无 resolver 强制。

[tep-0033]: https://github.com/tektoncd/community/blob/main/teps/0033-tekton-feature-gates.md
[tcfg]: https://tekton.dev/docs/operator/tektonpipeline/

---

### 2.2 Knative Serving & knative-operator

#### `config-features` ConfigMap — 三值模型

Knative 的 tier 比 Tekton 的 bool 更细：`Enabled`、`Allowed`、`Disabled`。

| 值          | 含义                                                |
| ----------- | --------------------------------------------------- |
| `Enabled`   | 功能激活，对所有 workload 强制                      |
| `Allowed`   | 功能可用，但需要按 workload 显式 opt-in（注解/字段）|
| `Disabled`  | 功能完全不可用                                      |

`Allowed` 是亮点：让 operator 把能力 ship 进集群但不强加。尤其适合**扩展类**
（不可移植的字段，如 `podspec-hostpath`）。扩展类永远不会升到 `Enabled` ——
其本质就是 opt-in。

```yaml
data:
  kubernetes.podspec-securitycontext: "allowed"
  multi-container: "enabled"
  kubernetes.podspec-hostpath: "disabled"
```

#### Feature vs 扩展生命周期

| 阶段  | Features 默认            | Extensions 默认       |
| ----- | ------------------------ | --------------------- |
| Alpha | `disabled`               | `disabled`            |
| Beta  | `enabled`（可 opt-out）  | `allowed`（按需启用）|
| GA    | 移除 flag（永远开启）    | `allowed`（仍 opt-in）|

GA 特性：flag key **从 ConfigMap schema 中彻底删除**。admin 没有逃生门 ——
跟 Kubernetes、Tekton 一致。

> "Cannot safely be disabled once enabled" —— Knative `features.yaml` 行内注释。
> 把「不可逆」的提示和 flag 声明放在一起，是值得借鉴的文档模式。

#### `KnativeServing.spec.config` — 通用 ConfigMap 透传

```yaml
spec:
  config:
    features:
      kubernetes.podspec-affinity: "enabled"
    autoscaler:
      stable-window: "60s"
```

`spec.config.<suffix>` 映射到 `config-<suffix>` ConfigMap。CRD schema 不校验
内层值 —— 纯透传。operator 拥有 ConfigMap，直接编辑会被覆盖。

Knative 还有 [issue #1838][k-1838] 跟进「把 `spec.features` 提为一等字段以提升
可发现性」—— 旁证嵌套 config 键容易把 feature flag 藏起来。

[k-1838]: https://github.com/knative/operator/issues/1838

---

### 2.3 Kubernetes core

#### `--feature-gates`

- 各组件（`kube-apiserver`、`controller-manager`、`kubelet`）独立标志。
- 生命周期：Alpha（默认关）→ Beta（默认开）→ GA。GA gate 要么**永久锁开**，
  要么**有 1 个 minor release 的 disable 窗口**，之后从代码里删除。
- **两轮弃用规则**：gate 在 GA 后必须再保留 2+ minor 版本才允许从代码移除。
- 没有 per-resource scope。仅集群进程级全局。
- 参见 [Feature Gates 文档][k8s-fg]。

#### CRD `spec.versions[]` — admin 可控的 per-version 暴露

| 字段                             | 类型   | 用途                              |
| -------------------------------- | ------ | --------------------------------- |
| `versions[].served`              | bool   | 立即从 apiserver 屏蔽/暴露此版本  |
| `versions[].storage`             | bool   | 恰好一个版本作为 etcd 存储版本    |
| `versions[].deprecated`          | bool   | 客户端访问时返回告警 header       |
| `versions[].deprecationWarning`  | string | 自定义告警内容                    |

`served: false` 是社区里**最贴近「最高安装版本封顶」**语义的原语。多个 served
版本通过 conversion webhook 共存；存储版本不动，历史数据安全。

```yaml
versions:
  - name: v1
    served: true
    storage: true
  - name: v2
    served: false          # admin 可翻转，不影响数据
  - name: v3
    served: false
conversion:
  strategy: Webhook
  webhook: { ... }
```

#### `--runtime-config`（apiserver 层最接近的类比）

`--runtime-config=apps/v1=true,batch/v2alpha1=true` 控制 apiserver 服务哪些
group/version 路径。和 `--feature-gates` 正交（一个 gate URL 路径、一个 gate
代码路径）。1.22 之后引入的 beta API 默认关闭。

[k8s-fg]: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/

---

### 2.4 Istio

#### Revision 多控制面共存（`istio.io/rev`）

- 多套完整 control plane 可同时运行，以 revision 名区分。
- workload 通过 namespace / pod label `istio.io/rev=<name>` 挑控制面。
- **Revision tag**（`istio.io/rev=prod-stable` → `1-30-0`）加一层间接：admin
  更新 *tag 指针*，不必批量改 namespace label。
- 为金丝雀升级设计，**不**作为永久多版本稳态。期望所有 workload 在一个 release
  周期内迁完。
- 参见 [Canary 升级][istio-canary]。

#### per-feature 成熟度

成熟度编码在 API 版本字符串（`v1alpha1` / `v1beta1` / `v1`）和 feature stages
表中。**没有**全局 `enable-api-fields` 式上限 —— 生产环境默认就服务 alpha API。
稳定性管的是 *API 形状*，不是 *运行时是否可用*。

[istio-canary]: https://istio.io/latest/docs/setup/upgrade/canary/

---

### 2.5 OLM、KubeVirt、OpenShift

#### OLM ClusterServiceVersion (CSV) — channel + 手动审批

- **Channel**（`stable`、`alpha`、`beta` 或 `4.14-stable` …）—— 每 package
  下的命名升级流。Subscription pin 到一个 channel。
- **`installPlanApproval: Manual`** 是 OLM 标准的「人卡下个版本」机制。OLM 生成
  新 InstallPlan，admin patch `spec.approved: true` 才真正安装。
- **`replaces` / `skips` / `skipRange`** 定义升级图 DAG。`skipRange: ">=1.0.0 <1.0.3"`
  可批量标记某段版本可跳过，但同时也会让这些版本从 `spec.startingCSV` 不可达。

#### OLM 能力等级（`metadata.annotations.capabilities`）

| 等级 | 名称              |
| ---- | ----------------- |
| I    | Basic Install     |
| II   | Seamless Upgrades |
| III  | Full Lifecycle    |
| IV   | Deep Insights     |
| V    | Auto Pilot        |

纯元数据 —— CSV 声明，OperatorHub UI 显示 badge，发布时由
`operator-sdk bundle validate` 校验，**不影响安装**。绝大多数 operator 自己 CRD
里并不暴露这个等级。

#### KubeVirt `featureGates` —— 最接近我们场景的先例

```yaml
apiVersion: kubevirt.io/v1
kind: KubeVirt
spec:
  configuration:
    developerConfiguration:
      featureGates:
        - LiveMigration
        - Sidecar
      disabledFeatureGates:          # v1.8 才加，专为显式 opt-out
        - WorkloadEncryption
```

- `featureGates: []string` —— 出现即启用，缺省即不启用（alpha 默认关）。
- `disabledFeatureGates: []string` —— 显式 opt-out（v1.8 引入，用于关掉
  默认开的 beta gate）。
- 不允许同时出现在两个列表里；webhook 校验。
- **GA 升级路径有公认缺陷**：deprecated 的 gate 名仍被静默接受（变成 no-op），
  而不是被拒绝。cert-manager 在 flag 解析阶段就拒绝未知 gate —— admin 的反馈
  更直接。
- KubeVirt issue [#10630][kv-10630] 跟踪此 bug。

#### KubeVirt workload 版本共存

- 基于热迁移：control-plane 升级时不动正在运行的 VMI 所在的旧 virt-launcher pod，
  直到 `workloadUpdateStrategy.workloadUpdateMethods` 触发它们迁到新 pod。
- CRD conversion webhook 在 apiserver 层处理 `v1alpha3 → v1` schema 差异。

#### OpenShift ClusterVersion channel

`oc adm upgrade channel stable-4.14` 设置 `ClusterVersion.spec.channel`。
channel 是粗粒度（订阅哪条 Cincinnati 流）；真正升级仍需要 `oc adm upgrade --to=<v>`。

#### cert-manager feature gates

```bash
cert-manager --feature-gates=AdditionalCertificateOutputFormats=true,LiteralCertificateSubject=true
```

- Webhook 在准入阶段强制 gate 状态：alpha gate 对应的 API 字段始终在 CRD schema
  里可见，但 gate 关闭时创建资源会被拒绝并给出清晰错误。
- GA gate 直接*从 flag parser 中移除* —— 传未知 gate 报错。比 KubeVirt 的
  silent no-op 友好得多。

[kv-10630]: https://github.com/kubevirt/kubevirt/issues/10630

---

### 2.6 Helm、ArgoCD、Crossplane、Flux、Kustomize

#### Helm：`condition` + 模板 `{{- if }}`

子 chart 层：

```yaml
# Chart.yaml
dependencies:
  - name: connectors-v2-ri
    condition: resourceInterface.v2.enabled
```

资源层（chart 内）：

```yaml
{{- if .Values.resourceInterface.v2.enabled }}
apiVersion: connectors.alauda.io/v1
kind: ResourceInterface
…
{{- end }}
```

**陷阱**：如果 values key 缺失（不是 `false`，是直接没写），condition 视作
「无效果」→ chart 照样装。推荐显式写 `false`，不要省。

#### Helm：`kubeVersion` semver 约束

```yaml
kubeVersion: ">= 1.25.0 < 1.30.0"
```

`helm install` 阶段硬门禁。最接近「这套 manifest 需要某运行时能力，否则不装」
的先例 —— 但只对 K8s 版本字符串，不能扩展到自定义能力。

#### Crossplane：`CompositionRevision` + `compositionUpdatePolicy`

- 每次 Composition 修改产生**不可变 revision**。多 revision 集群内并存。
- XR 声明 `compositionUpdatePolicy: Manual | Automatic`。
- `Manual`：XR 一直 pin 到创建时的 revision，admin 改 `compositionRevisionRef`
  才动。
- `Automatic`：XR 自动跟最新 revision。
- **Revision label channel**：`channel: stable` / `channel: v2-preview` 让 XR
  订阅一条命名流而不是某个哈希。

调研里**最成熟的多版本共存模型**。直接对应我们「v1 RI 必须留着」的需求 ——
revision 不会被自动 GC，只要还有 XR pin 着它。

#### Crossplane feature flags：`--enable-*` / `--disable-*`（Helm `args`）

| 阶段  | 默认       | flag 形态           |
| ----- | ---------- | ------------------- |
| Alpha | 关         | `--enable-<x>` 加入 |
| Beta  | 开         | `--disable-<x>` 关  |
| GA    | 永远开     | 没有 flag           |

Kubernetes 风格三层、三种默认值的模型。比 KubeVirt 的单列表清晰 —— beta 默认开
靠 *flag 缺失* 表达，不靠 enable 列表。

#### ArgoCD：ApplicationSet cluster generator

```yaml
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            connectors-schema-version: v1
        values:
          chartVersion: "1.x"
          enableV2: "false"
```

多集群车队模式：cluster Secret 带标签声明自身 tier，ApplicationSet 按集群 tier
渲染不同版本。bundle 全局相同；reconciler 输出按集群 tier 差异化。

#### ArgoCD sync-option 注解

`argocd.argoproj.io/sync-options: Prune=false` 是「即使源 bundle 里没了，也别删
这条资源」的标准先例 —— 直接对标我们「升级后 v1 RI 不能被删」的需求。

#### Flux：`version: '1.x'` + `spec.suspend`

```yaml
spec:
  chart:
    spec:
      version: "1.x" # 封顶在最新 1.x
  suspend: true # admin 一键冻结
```

`version` 作为 semver range = 由 **reconciler** 强制的声明式版本上限，不由
chart 强制。bundle 全 ship；admin 的范围决定 reconciler 应用到哪。这就是我们
想要的形状。

#### Kustomize Components

```text
base/                    # 总会应用
components/ri-v2/        # kind: Component，可选
overlays/legacy/         # 不引用 ri-v2
overlays/modern/         # 引用 ri-v2
```

最干净的静态「功能包」模型。对我们不太直接适用 —— 我们的 manifest 是 operator
动态拼装的，不是静态 overlay。但「一个 feature × 版本 = 一个 Component」的概念
本身值得借用。

---

## 3. 跨生态共性模式

把四份调研报告蒸馏后，留下 8 个反复出现的模式。按对当前问题的相关性大致排序：

### P1. 全局 tier 上限（Tekton、Knative）

集群 CR 上一个枚举（`alpha | beta | stable`）作为累积上限，门禁以下全开。
实现成本低，表达力低 —— 不能表达「只 X 在 alpha、其它 stable」。

### P2. per-feature 显式列表（KubeVirt、cert-manager）

`featureGates: [LiveMigration, Sidecar]`。列表形态，出现即启用。KubeVirt 后来
加了 `disabledFeatureGates` 做显式 opt-out。两列表比 `map[string]bool` 在
「beta 默认开」场景下歧义更少。

### P3. 三值能力状态：Enabled / Allowed / Disabled（Knative）

`Allowed` 是亮点 —— 功能存在但按 workload opt-in，不强制集群级。我们今天没有
per-workload opt-in 概念，但未来「v2 RI 装着但 PipelineInvocation 默认不用」
就是这个形状。

### P4. GA = 永远开，gate 从 schema 移除（社区一致）

Tekton / Knative / cert-manager / KubeVirt / Kubernetes 一致：feature 一旦 GA，
flag 不再被尊重 *并且* 从配置面整体移除。KubeVirt 的 silent-accept-deprecated-gate
bug（#10630）是要避免的*反模式* —— admin 需要清晰反馈，知道自己设的 gate 已经
没意义。cert-manager 的「未知 gate = 解析错误」是金标准。

直接对应我们 `ffb400f` 的 `MaturityGA` 锁定语义。好消息：路线已经对。改进空间：
在 webhook 校验时拒绝（不是默默忽略）admin 给 GA feature 写 override。

### P5. per-version `served` 开关（Kubernetes CRD）

`spec.versions[].served = false` 从 apiserver 屏蔽某版本，但保留数据（存储版本
不动）。这是「v2 封顶」用 Kubernetes 原生 API 表达的*精确*形态 —— 只是它作用于
*CRD*，不是 manifest 内的 *RI 资源*。

我们的问题低一层：不是按 RI 版本各 ship 一个 CRD，而是一个 CRD 下 ship 不同
版本的 RI 资源（`harborociartifact-v2`）。但*模式*可以直接迁移到「feature 上
封顶版本」。

### P6. 不可变带版 revision + admin pin（Crossplane）

`CompositionRevision` 不可变 + `compositionUpdatePolicy: Manual` + 可选
`channel: stable` 标签。pin 是显式的；历史保留；channel 把「版本身份」和
「admin 跟随的目标」解耦。调研里最成熟的多版本共存模型。

直接相关：「v1 RI 必须留着，因为 PipelineInvocation 按名引用」结构上等同于
「XR 可能 pin 着旧 revision，operator 不可删」。结论：今天的
`ensureNotInstalled` 路径对二值 on/off 没问题；但对*版本被覆盖*的场景，需要
一条**保留旧资源**的路径 —— admin 在它上面封顶，旧的留着。

### P7. Reconciler 侧的版本范围约束（Flux `version: '1.x'`）

调研里最人性化的语法：

```yaml
chart:
  spec:
    version: "1.x" # 也支持 '~2.0'、'>=1.5 <2'
```

单字符串、semver 感知、上限下限一字表达。如果我们坚持「每 feature 一个旋钮」，
semver range 的人体工学和 `bool` 差不多，但表达力严格更强。

### P8. 注解驱动的逐资源 sync 排除（ArgoCD `sync-options`）

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

资源自身声明「prune 时别删我」。直接对标「升级后保留 v1 RI」—— 但责任压到
manifest 作者（extension）身上，不是 admin 或 operator。我们已经有
`connectors.operator.cpaas.io/ignore-install` 可作类比；它可以演化出
`keep-on-cap` 这种伴生注解。

---

## 4. 对 DEVOPS-43943 重设计的适用性

### 4.1 社区一致的点

- **GA 锁定不动摇。** 成熟度门禁是非对称的 —— admin 永远能逃离 alpha/beta，
  永远逃不出 GA。我们 v3 已经做到（`MaturityGA` + `Locked: true`），不用改。

- **同一 CRD 多版本通过 apiserver 自身的 conversion 机制共存**
  （CRD `versions[]` 加上 webhook），不靠 operator 复制。我们工作在
  *manifest content* 层，更低一级，所以该模式启发但不能直用。

### 4.2 社区分歧 —— 我们站哪边

| 问题                | Tekton / Knative      | KubeVirt / cert-mgr   | Crossplane / Flux         | 我们采纳                                  |
| ------------------- | --------------------- | --------------------- | ------------------------- | ----------------------------------------- |
| per-feature 粒度    | 粗（一个 tier 旋钮）  | 细（per-gate 列表）   | 细（per-resource 版本 pin）| 细 —— `installFlags` map               |
| value 类型          | enum                  | string-name 列表     | semver-range 字符串       | `apiextensionsv1.JSON`，per-feature 自定义 |
| 未列出 beta 默认    | 开                    | 开                    | 开                        | 开                                         |
| 数据驱动 vs 代码驱动 | 数据                  | 混合                  | 数据                      | **代码** —— per-feature transformer        |
| 多版本：替换或共存  | 共存（CRD 转换）      | 共存（热迁移窗口）    | 共存（不可变 revision）   | **共存**（IM-managed 才删超 cap 部分）     |
| 「封顶」语法        | 无                    | 无                    | `chartVersion: '1.x'`     | `"<=N"`（先收口单一形态）                  |

### 4.3 关于 override value 类型（决策快照）

**决策**：`installFlags` 的 value 类型升级为 `apiextensionsv1.JSON`，
每个 feature 在自己的 transformer 里解析自己想要的形态（bool / string /
struct …）。CRD schema 不约束内部结构，解析失败退化到 maturity 默认。

**为什么不是判别式 struct（方案 B）**：调研里 KubeVirt / cert-manager 等
都选择"每个 feature 自有解读"，没有项目走判别式 struct 路线。我们的下一个
形态（版本封顶 semver range）和已有 bool 完全异质，强行用 struct 反而
增加无谓约束。

**为什么不是单字段 + 多字段并存**：调研里 Knative `Enabled/Allowed/Disabled`
三态用一个 ConfigMap 表达，没有靠多字段。我们沿用一字段、多态 value 的
路径，落地最短。

详细 API 形态见 §5.1。

### 4.4 通用 decider vs per-install-flag transformer（决策快照）

**决策**：丢掉通用 `featureDecider`，每个 feature 在 operator 代码里
注册自己的 transformer（`pkg/controllers/transformer/installflags/<feature>.go`）。
Maturity 也 hardcode 在 transformer 文件里，不再走 extension 的 maturity
ConfigMap。

**为什么**：调研里**没有项目用纯数据驱动的 gating 模型**。Tekton 在
webhook 硬编码 `enable-api-fields` 语义、KubeVirt 在
`pkg/virt-config/featuregate` 硬编码 gate 名、Knative 三值解释器在
`pkg/apis/config/features.go`。`ffb400f` 的通用 decider + ConfigMap-driven
maturity 是孤例。

**成本接受**：新 gate 都需要 operator 改代码并发版，跟 KubeVirt 一致 —
封闭世界 + 易审计。当前 / 18 个月内预计被 gate 的 feature ≤ 5 个，
"每加一个改代码"成本可控。

详细签名与代码示意见 §5.3。

### 4.5 历史数据保留这个坑

`ffb400f` 的 `ensureNotInstalled` 在 override 翻成 false 时会删资源。对
「v1 RI 在 v2 封顶后」场景**这是错的** —— 把 v1 RI 删掉会让仍引用 v1 的
PipelineInvocation 断掉。

社区先例：

- Crossplane CompositionRevision 不主动删，除非 GC 发现没人引用
- ArgoCD `sync-options: Prune=false`
- Kubernetes CRD version `served: false` 保留存储数据

**决策（评审后）**：

- API 只暴露版本封顶（`installFlags[X] = "<=N"`），不暴露"整能力删"
- 实现继续走 `ffb400f` 的 `MarkIgnoreInstallIf` + InstallManifest 注解通道，
  **不**走 `manifest.Filter()`（被过滤资源会脱 owner，触发孤儿 GC 风险）
- `ensureNotInstalled` 加 ownership 门：仅删除本 InstallManifest 管理的资源
  （IM-managed）；非本 IM 管理的资源原地保留
- 首批 install flag 为 `pipeline-integration`（per-install-flag transformer +
  按 schema-version 打 IgnoreInstallKey）

## 5. 重设计建议

### 5.0 一个被调研放大的根因

之前的 feature 命名实践把"能力"和"版本档"糊在同一个名字里 —— 名字描述的是
*某个版本档*而非*某个能力*。一旦更高版本 ship，原名字立刻语义崩塌。

对照调研：

- KubeVirt `featureGates: [LiveMigration]` —— feature 名是**能力**，不带版本
- Crossplane CompositionRevision —— **能力**有名字，**版本**是独立 revision
- Kubernetes CRD `versions[]` —— **种类**和**版本**显式分开

社区一致把这两层概念**强制分开**。我们当前把它们糊在一起，是问题的根。
下面的所有建议都建立在"先把这两层拆开"的前提上。

### 5.1 单字段、多态 value、transformer 自行选择「删 / 留」路径

保留 `installFlags` 作为唯一入口（不引入 sibling 字段），把 value 类型
从 `map[string]bool` 升级为 `map[string]apiextensionsv1.JSON`，让每个 feature
的 transformer 按需解析自己的 value 形态：

```yaml
spec:
  installFlags:                       # map[string]apiextensionsv1.JSON
    legacy-feature: false                 # bool —— 整能力门禁
    pipeline-integration: "<=2"     # 字符串 —— 版本封顶，含低版本
    cache-strategy: "lru"                 # 字符串 —— 枚举（未来场景示例）
```

CRD schema 不校验 value 内部形态 —— 全交给 per-install-flag transformer 在 Transform
阶段解析；解析失败退化为该 feature 默认行为 + log warning（沿用 v3 信任>强制 原则）。

**版本封顶语义为"含低版本"**：`pipeline-integration: "<=2"` 表示装 v1+v2，
跳过 v3+。低版本永远入集群，admin 控制的是上限。这和 §5.0 "能力 + 版本档分离"
直接对应 —— 能力本身是连续累积的，admin 只决定走到哪一档为止。

**只保留版本封顶路径，不再支持"admin 写 bool 关掉整能力"**：

- admin 只能通过 `"<=N"` 形式封顶版本
- per-install-flag transformer 走 `MarkIgnoreInstallIf` 路径：高于 cap 的资源仍**留在
  manifest 里**（InstallManifest 仍 own 它们，不会触发 controller-runtime 孤儿 GC），
  被打上 `IgnoreInstallKey="true"`
- installer 收到注解后：
  - 如果该资源**已被本 InstallManifest 安装过**（IM-managed）→ **删除**
  - 如果该资源存在但**不是本 IM 管理的**（用户手建、其它来源）→ 保留，不动
  - 如果资源未创建过 → 跳过

第二条 ownership check 是相对 ffb400f 的精细化：之前 `ensureNotInstalled` 是
"delete-if-present"（仅靠 protected kinds 列表兜底）；新行为加入"必须是 IM 安装的
才删"作为更严格的安全门。protected kinds 仍保留作 data-safety 兜底。

不走 `manifest.Filter()` 是关键 —— 那条路会让被过滤的资源脱离 InstallManifest 的
owner（变成孤儿），controller-runtime 不再 reconcile，反而失去清理能力。继续走
manifest 内标记的方案，installer 能完整观测每个版本的状态并按 ownership 决定动作。

### 5.2 InstallFlag key 命名为纯能力名

feature key 表达"能力"，不带版本档。版本档（v1 / v2 / v3）放在资源的
`resourceinterface.connectors.cpaas.io/schema-version` label 上。例如：

- `pipeline-integration`（能力名）
- `harbor-oci-artifact-ri`（另一能力名）

`installFlags["pipeline-integration"] = "<=2"` 才是清晰的语义。

### 5.3 用 per-install-flag transformer 替换通用 decider

调研一致：Tekton 在 webhook 硬编码 `enable-api-fields` 语义；KubeVirt 在
`pkg/virt-config/featuregate` 硬编码 gate 名；Knative 三值解释器在
`pkg/apis/config/features.go`。`ffb400f` 的通用 decider 是**孤例**。

每个 feature 的 transformer 工厂函数约定签名：

```go
type FeatureTransformer func(spec *component.ComponentSpec) mf.Transformer
```

**Maturity 直接 hardcode 在 transformer 文件内**，不再依赖 extension ship 的
ConfigMap。`ffb400f` 的 `extractFeatureMaturity` + `RoleFeatureMaturity` 机制
随本次重构整体作废。每个 feature 的 transformer 文件长这样：

```go
// pkg/controllers/transformer/installflags/pipeline_integration.go
const (
    featureKey      = "pipeline-integration"
    featureMaturity = v1alpha1.MaturityBeta   // hardcoded; 升 GA 改这一行
)

// 资源识别由 transformer 内部规则负责，不依赖 connectors.operator.cpaas.io/feature 标签。
// 例如 pipeline-integration 的 transformer 按 (kind=ResourceInterface, name=nexus-*)
// 命中相关资源，再读 resourceinterface.connectors.cpaas.io/schema-version label 判断版本。
func matchResource(u *unstructured.Unstructured) bool {
    return u.GetKind() == "ResourceInterface" && strings.HasPrefix(u.GetName(), "nexus-")
}

// markIgnoreAbove(cap) 返回一个 mf.Transformer，遍历 manifest 时给所有
// matchResource() 命中且 schema-version > cap 的资源打 IgnoreInstallKey="true"。
// 资源仍留在 manifest 里（被 InstallManifest own），installer 只是跳过创建。
func NewTransformer(spec *component.ComponentSpec) mf.Transformer {
    // 锁定 maturity：忽略 admin override，按 maturity 默认行为
    switch featureMaturity {
    case v1alpha1.MaturityGA:
        return passthrough()                       // 装全部，锁定
    case v1alpha1.MaturityDeprecated:
        return markIgnoreAbove(-1)                 // 全部跳过，锁定
    }
    // 未锁定（Alpha / Beta）：尝试读 admin override
    raw, ok := spec.InstallFlags[featureKey]
    if !ok {
        return maturityDefault()                   // override 未写 → maturity 默认
    }
    var rangeExpr string
    if err := json.Unmarshal(raw.Raw, &rangeExpr); err != nil {
        return maturityDefault()                   // 解析失败 → log warning + maturity 默认
    }
    cap := parseCap(rangeExpr)                     // "<=2" → 2
    return markIgnoreAbove(cap)
}

// maturity 默认（沿用 ffb400f）：
// - Alpha → 不装任何版本（全部打 IgnoreInstallKey）
// - Beta  → 装全部版本（passthrough，相当于无 cap）
func maturityDefault() mf.Transformer {
    if featureMaturity == v1alpha1.MaturityAlpha {
        return markIgnoreAbove(-1)                 // -1 ⇒ 所有版本都 > cap
    }
    return passthrough()
}
```

要点：

- **没有 `connectors.operator.cpaas.io/feature` 标签**。资源识别完全由 transformer
  内部规则决定（kind + name pattern + schema-version label 任意组合）。Extension
  侧不再需要给资源打 feature 标签，少一份契约负担。
- **Maturity 升级**就是改 `featureMaturity` 常量并发版 —— 升 GA 后 admin override
  自动失效（被首段 switch 兜走），无需额外迁移代码。换 maturity 不再通过 extension
  的 ConfigMap 推送。
- **默认行为按 maturity 分层**：Alpha 默认不装、Beta 默认装全部、GA 锁定装全部、
  Deprecated 锁定不装。Admin 只在 Alpha / Beta 时能用 override 影响行为；解析失败、
  未写 override、locked 三种情况都走 maturity 默认。

Webhook 完全不参与 maturity / value 校验，保持 v3 信任>强制 原则。

<!-- 5.4 / 5.5 / 5.6 / 5.7 在评审中确认不做：
- 5.4 (IgnoreInstallKey 枚举化) 被 §5.1 的「transformer 自选原语」吸收
- 5.5 (webhook 强校验) 暂不做，保留 v3 信任>强制 原则
- 5.6 (撤回 polymorphic value) 推翻 —— §5.1 已采纳 polymorphic JSON value
- 5.7 (channel) 暂不做，问题域不匹配
-->

## 6. spec 阶段待解决的问题

- **Q1**：value 升到 `apiextensionsv1.JSON` 后，CRD schema 还要不要保留键级
  white-list（限定哪些 feature key 可写）？
  → 不限，v3 信任>强制 原则一致。未知 key 在 reconcile log 里打 warning 即可，
  不在 webhook 拒绝写入。

- **Q2**：per-install-flag transformer 的注册机制 —— Go `init()` 还是显式集中注册？
  → 倾向**显式集中**（`pkg/controllers/transformer/installflags/register.go`），
  每加 feature 改两处：新文件 + 注册行。比 `init()` 隐式注册更易审查。

- **Q3**：资源侧承载版本信息用什么 label？
  → 用 `resourceinterface.connectors.cpaas.io/schema-version`（已存在）。
  Per-feature transformer 自行解析其值。资源端**不再需要** `connectors.operator.cpaas.io/feature`
  标签（A4 决议）—— 资源归属由 transformer 内部规则识别（kind / name / schema-version
  组合）。未来非-RI 能力如要版本封顶，由该能力的 transformer 自己挑识别口径，
  不必引入新通用 label。

- **Q4**：~~版本封顶走 `manifest.Filter()` 是否会触发孤儿 GC？~~
  → 评审决议：不走 Filter 路径。改为 transformer 给高版本资源打
  `IgnoreInstallKey="true"`，资源仍留在 manifest 里被 InstallManifest own。
  Installer 行为为：IM-managed 的删除、非 IM-managed 的保留、未创建的跳过。
  ffb400f `ensureNotInstalled` 的"delete-if-present"语义升级为"delete-if-IM-managed"
  作为 ownership 安全门，protected kinds 仍兜底。

- **Q5**：~~value polymorphism + maturity 锁定如何配合？~~
  → §5.3 已答：transformer 内部锁定。Locked（GA / Deprecated）时跳过 value 解析，
  按 maturity 默认行为走。Webhook 不参与。

- **Q6**：合并语义（`ConnectorsHarbor.spec.installFlags` 覆盖
  `ConnectorsConfig.spec.installFlags`）—— value 升 JSON 后，per-key 覆盖
  语义保持不变即可（不做深合并；同 key 整个 JSON value 替换）。

- **Q7**：版本范围语法 —— 当前需求是"含低版本封顶"，先收口到 `"<=N"`
  单一形态即可（`pipeline-integration: "<=2"` = 装 v1+v2，跳过 v3+）。
  Masterminds/semver 库可解析；spec 文档应明确：未来扩展（`~`、`||`、范围）
  延后到出现第二种语义需求时再开。

- **Q8**：ffb400f 引入但本次决议作废的符号统一清理：
  - `FeatureLabel = "connectors.operator.cpaas.io/feature"` —— 删除常量（A4）
  - `RoleLabel` / `RoleFeatureMaturity` —— 删除（A3）
  - `extractFeatureMaturity()` —— 删除（A3，maturity 改 hardcode 在 transformer）
  - `featureDecider()` —— 删除（A4 + §5.3，由 per-feature transformer 替代）
  - `Maturity` 类型 + 4 个常量 —— 保留（transformer 文件内仍要用）

- **Q9**：`ensureNotInstalled` ownership 判定的具体口径：
  - 复用现有 `ManagedByKey = "cpaas.io/managed-by"` annotation 还是新增 owner
    reference 检查？倾向用 ManagedByKey + ManagerKey + ReleaseVersionKey 三件套
    （现有 `pkg/apis/v1alpha1/annotations_labels.go` 已定义），匹配本 IM 的
    `Manager`/`Version` 就视为 IM-managed。
  - protected kinds 列表（Namespace / PVC / CRD）继续保留作 data-safety 兜底。

## 7. 来源

### Tekton & Knative

- [TEP-0033 Tekton Feature Gates](https://github.com/tektoncd/community/blob/main/teps/0033-tekton-feature-gates.md)
- [Tekton Pipelines Additional Configuration](https://tekton.dev/docs/pipelines/additional-configs/)
- [tektoncd-operator TektonPipeline CR](https://tekton.dev/docs/operator/tektonpipeline/)
- [Knative Serving Feature Flags](https://knative.dev/docs/serving/configuration/feature-flags/)
- [Knative Operator: Configuring Serving CR](https://knative.dev/docs/install/operator/configuring-serving-cr/)
- [Knative `features.yaml`](https://github.com/knative/serving/blob/main/config/core/configmaps/features.yaml)
- [Tekton Pipeline Deprecations](https://tekton.dev/docs/pipelines/deprecations/)
- [Knative operator issue #1838](https://github.com/knative/operator/issues/1838)

### Kubernetes core & Istio

- [Feature Gates | Kubernetes](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/)
- [CRD Versioning | Kubernetes](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/)
- [kube-apiserver flags | Kubernetes](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Istio Canary Upgrades](https://istio.io/latest/docs/setup/upgrade/canary/)
- [Istio Feature Stages](https://istio.io/latest/docs/releases/feature-stages/)

### OLM、KubeVirt、OpenShift、cert-manager

- [OLM Operator Capability Levels](https://operatorframework.io/operator-capabilities/)
- [OLM CSV Docs](https://olm.operatorframework.io/docs/concepts/crds/clusterserviceversion/)
- [OLM Update Graph](https://olm.operatorframework.io/docs/concepts/olm-architecture/operator-catalog/creating-an-update-graph/)
- [KubeVirt Feature Gates](https://kubevirt.io/user-guide/cluster_admin/activating_feature_gates/)
- [KubeVirt issue #10630 — deprecated gates bug](https://github.com/kubevirt/kubevirt/issues/10630)
- [KubeVirt Updating and Deletion](https://kubevirt.io/user-guide/cluster_admin/updating_and_deletion/)
- [OCP 4.11 Update Channels](https://docs.redhat.com/en/documentation/openshift_container_platform/4.11/html/updating_clusters/understanding-upgrade-channels-releases)
- [cert-manager Feature Flags](https://cert-manager.io/docs/installation/featureflags/)

### Helm、ArgoCD、Crossplane、Flux、Kustomize

- [Helm Charts](https://helm.sh/docs/topics/charts/)
- [Helm Template Control Structures](https://helm.sh/docs/chart_template_guide/control_structures/)
- [ArgoCD Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [ArgoCD ApplicationSet Cluster Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/)
- [Crossplane Feature Lifecycle](https://docs.crossplane.io/latest/learn/feature-lifecycle/)
- [Crossplane Composition Revisions](https://docs.crossplane.io/latest/composition/composition-revisions/)
- [Flux Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- [Flux HelmRelease API](https://fluxcd.io/flux/components/helm/helmreleases/)
- [Kustomize Components](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/components.md)
