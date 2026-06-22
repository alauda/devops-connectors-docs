# Kubernetes Service Binding 能力调研指南

> **状态**：已完成（持续可追加）
> **覆盖版本**：**Service Binding Specification for Kubernetes — Core 1.1.0**（2024-03-12 release，[spec releases](https://github.com/servicebinding/spec/releases)）；参考实现 **servicebinding/runtime v1.0.0**（2024-07-16，[runtime releases](https://github.com/servicebinding/runtime/releases)）
> **基于源**：官方规范站 `servicebinding.io` + 规范仓库 `github.com/servicebinding/spec` + 参考实现 `github.com/servicebinding/runtime` + Red Hat SBO 文档（逐条带 URL）
> **edition 范围**：单一形态 —— **整个 Service Binding 是社区开源标准（spec 与参考实现均 Apache-2.0）**，无 Enterprise/付费分层。它是「规范 + 多个实现」的生态，不是一个商业产品。
> **不覆盖**：被绑定的后端服务自身（数据库 / broker 等）的能力；具体厂商发行版（如 VMware Tanzu Application Platform 内置的 service binding）的私有增强；价格（无）。
> **未实测**：本指南未在集群实跑 demo，命令/YAML 均"未实测，基于官方文档"。

本文档**只讲 Service Binding 自身**：它是什么标准、定义了哪些资源与约定、解决什么问题、基本原理、谁来实现、收不收费。

---

## §0 心智模型 + 能力地图速览

**心智模型（4 行）**：Service Binding 是一套 **K8s 社区规范**，把「**把一个后端服务（Provisioned Service）的连接信息投射进一个工作负载（Workload）**」这件事标准化。核心是三步契约：① 后端服务用一个 **K8s Secret** 承载连接信息，并在自己的 `.status.binding.name` 里指向这个 Secret（**Provisioned Service duck type**）；② 用户写一个 `ServiceBinding` 资源，声明「把哪个 service 绑到哪个 workload」；③ **service binding reconciler**（控制器）把那个 Secret 以**文件目录**形式投射进 workload 的容器（`$SERVICE_BINDING_ROOT/<binding-name>/<key>`），可选再投射成环境变量。它**只搬运 Secret → 文件/env，不做协议代理、不发凭据、不做授权**。（[spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)、[spec README](https://github.com/servicebinding/spec/blob/main/README.md)）

**简化架构（数据流）**：

```
   +---------------------------+        +-----------------------------+
   |   Provisioned Service     |        |       ServiceBinding (CR)   |
   |   (e.g. a DB CRD)         |        |  spec.service -> 上游服务    |
   |   .status.binding.name ---+--+     |  spec.workload -> 下游负载   |
   +---------------------------+  |     |  spec.env / type / provider |
                                  |     +--------------+--------------+
                                  |                    | (1) 用户 apply
                                  v                    v
                            +-----+--------------------+------+
                            |  Service Binding Reconciler     |  (2) watch + reconcile
                            |  (servicebinding/runtime 等)    |
                            |  解析 service -> 拿到 Secret 名  |
                            |  按 workload 类型找注入点        |
                            +----------------+----------------+
                                             | (3) 改写 workload PodSpec
                                             |     加 volume(投射 Secret) + 可选 env
                                             v
   +-------------------------------------------------------------------+
   |  Workload Pod (Deployment/StatefulSet/...)                        |
   |   volumeMount: $SERVICE_BINDING_ROOT/<binding-name>/              |
   |     ├── type        (well-known)                                  |
   |     ├── provider    (well-known)                                  |
   |     ├── host / port / username / password / uri / ...            |
   |   app 直接以「读本地文件」方式拿连接信息（或读注入的 env）         |
   +-------------------------------------------------------------------+
```

- **(1)** 用户 `kubectl apply` 一个 `ServiceBinding`，声明 service（上游）+ workload（下游）。
- **(2)** reconciler watch 到后，解析 `spec.service`：若是 Provisioned Service，读它的 `.status.binding.name` 拿到 Secret；若是 **Direct Secret Reference**（`spec.service.kind: Secret`），直接用该 Secret。
- **(3)** reconciler **改写 workload 的 PodSpec**：挂一个投射 Secret 的 volume 到 `$SERVICE_BINDING_ROOT/<binding-name>/`，每个 Secret key 变成一个文件；若声明了 `spec.env` 再加 env。**app 永远只看到文件/env，不感知 reconciler 的存在**。
- **✦ 关键边界**：投射进 Pod 的就是 **Secret 的明文内容**（落成文件）。Service Binding **不**做凭据短期化、不做协议代理、不做 per-request 授权 —— 它是「Secret → workload 的标准化投射约定」，**仅此一层**。

**许可 / 生态 / air-gap（先记这条）**：**spec 与参考实现 `servicebinding/runtime` 均 Apache-2.0**，社区主导（bi-weekly 工作组 + Kubernetes Slack `#bindings-discuss`，[spec README](https://github.com/servicebinding/spec/blob/main/README.md)）。它是**「一个规范 + 多个实现」的生态**，不是单一产品。⚠️ Red Hat 的 **Service Binding Operator（SBO）自 2024-02 起 deprecated、2024-06-26 archived**，官方建议迁到 `servicebinding/runtime`（见 §6）。air-gap：reconciler 是普通 K8s 控制器，镜像可离线；`servicebinding/runtime` 源码构建依赖 cert-manager（[runtime](https://github.com/servicebinding/runtime)）。

### 能力地图速览（30 秒看全貌）

一行 = 一章。**全部社区开源（Apache-2.0），无付费分层**，故不分 OSS/付费两表；用 maturity（规范是 1.1.0 released；实现是 GA/参考级）区分。

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 | maturity |
|---|---|---|---|---|---|---|
| §1 | Provisioned Service duck type | 服务怎么"声明可被绑定" | 服务在 `.status.binding.name` 指向一个 Secret | 任何 CRD 加一个 status 字段即可被绑定 | 数据库 operator 暴露连接 Secret | spec 1.1.0 |
| §2 | ServiceBinding 资源 | 声明"把谁绑到谁" | `spec.service` + `spec.workload`，reconciler 接管 | 声明式、与 workload 解耦 | 把 DB 绑进一个 Deployment | spec 1.1.0 |
| §3 | Workload Projection（**核心**） | app 怎么拿到连接信息 | Secret → `$SERVICE_BINDING_ROOT/<name>/<key>` 文件 + 可选 env | 约定式目录 + well-known key | app 读本地文件拿 host/password | spec 1.1.0 |
| §4 | Direct Secret Reference | 没有 Provisioned Service 也能绑 | `spec.service.kind: Secret` 直接引用 | 不需要服务方改造 | 把手写 Secret 绑进 workload | spec 1.1.0 |
| §5 | (Cluster)WorkloadResourceMapping + Role-Based reconciler | 绑非标准 workload / RBAC 授权 | mapping 描述注入点；aggregated ClusterRole 授权 | 支持自定义 workload CRD | 绑进自研 workload 类型 | spec 1.1.0 |
| §6 | 规范 vs 实现生态 + SBO 弃用 | 用哪个实现 | spec 是契约，runtime/SBO 是实现 | 实现可替换 | 选 reconciler 落地 | 见正文 |

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 让我的服务 CRD"可被绑定" | §1 |
| 声明把某个服务绑进某个工作负载 | §2 |
| 理解 app 最终在 Pod 里看到什么（目录/文件/env） | §3（核心，已展开） |
| 把一个手写的 K8s Secret 直接绑进 workload | §4 |
| 把绑定投射进一个非 Deployment 的自定义 workload | §5 |
| 给 reconciler 授权读我的服务资源 | §5（Role-Based reconciler） |
| 选哪个实现落地 / SBO 还能不能用 | §6 |
| app 侧用什么库读取投射目录 | §3 核心能力清单（consumer libraries） |

---

## §1 Provisioned Service duck type（edition: 社区 Apache-2.0；spec 1.1.0）

### 解决什么问题
服务方（数据库 operator、消息 broker operator…）需要一种**标准方式声明"我这个服务实例的连接凭据在这里"**，而不必让每个消费方都去理解该服务私有的 status 结构。

### 核心模型 / 原理
**Provisioned Service 是一个 duck type（鸭子类型）**：任何资源只要实现 `.status.binding`（规范描述为 "a `LocalObjectReference`-able … to a `Secret`"），就被视为「可被绑定的服务」。该 Secret **必须与资源同 namespace**（规范原文："The `Secret` **MUST** exist in the same namespace as the resource"）。Secret 自身可带 `.type` = `servicebinding.io/{type}`。（[spec 1.1.0 §Provisioned Service](https://servicebinding.io/spec/core/1.1.0/)）

### 核心能力清单
- 契约极小：服务方只需在 CR 的 `.status.binding.name` 填一个同 namespace 的 Secret 名。
- 不要求服务方依赖 Service Binding 的任何库——只是一个 status 字段约定（duck typing）。
- Secret 内容遵循 well-known key 约定（见 §3）。
- 边界：规范**不**定义这个 Secret 怎么被创建/轮换——那是服务 operator 自己的事。

### 最小命令示例
> 未实测，基于官方文档 [spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)

**场景：一个数据库 CRD 声明自己可被绑定**——服务方只加一个 status 字段指向已有 Secret。

```yaml
# 服务方的 CR（示意）：只要 .status.binding.name 指向一个同 ns 的 Secret 即"可被绑定"
apiVersion: example.dev/v1
kind: Database
metadata: { name: account-db }
status:
  binding:
    name: account-db-secret      # ← 这一个字段就让它成为 Provisioned Service
---
apiVersion: v1
kind: Secret
metadata: { name: account-db-secret }    # 必须与 Database 同 namespace
type: servicebinding.io/postgresql
stringData:
  type: postgresql               # well-known: type（源 Secret 层 RECOMMENDED，投射层 REQUIRED；缺省可由 ServiceBinding.spec.type 提供）
  provider: bitnami              # well-known: provider（推荐）
  host: account-db.svc
  port: "5432"
  username: app
  password: s3cr3t
```

### 一句话本质
**服务在 `.status.binding.name` 指一个 Secret，就成了"可被绑定的服务"——一个 status 字段的鸭子类型契约。**

---

## §2 ServiceBinding 资源（edition: 社区 Apache-2.0；spec 1.1.0）

### 解决什么问题
需要一个**声明式、与 workload 解耦**的对象来表达「把哪个服务的连接信息送进哪个工作负载」，而不是让开发者手工往 Deployment 里塞 volume/env。

### 核心模型 / 原理
`ServiceBinding`（`apiVersion: servicebinding.io/v1`，`kind: ServiceBinding`）描述 **一个 Provisioned Service 与一个 Workload Projection 之间的连接**。关键 spec 字段（[spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)）：
- `.spec.service` — 指向上游（Provisioned Service 或直接 Secret，见 §4）。
- `.spec.workload` — 指向下游工作负载，可按 `name` 或 `selector`（二选一），并可用 `.spec.workload.containers` 限定只注入某些容器。
- `.spec.name` — 可选，默认取 `.metadata.name`，**决定投射目录名**（见 §3）。
- `.spec.type` / `.spec.provider` — 可选，覆盖投射里的 `type`/`provider` 条目。
- `.spec.env` — 可选数组，每个 `EnvMapping` 把某个 Secret key 映射成容器 env 变量。
- `.status.binding.name` — 最终被投射的 Secret 名；`.status.conditions` 含 `Ready`。

### 核心能力清单
- 声明式：apply 一个 CR，reconciler 接管对 workload 的改写。
- workload 可按 name 或 label selector 选取，可限定容器。
- 可覆盖 `type`/`provider`，可加 env 映射。
- 边界：一个 ServiceBinding 绑**一个** service 到**一个** workload；多对多靠多个 ServiceBinding。

### 最小命令示例
> 未实测，基于官方文档 [spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)

**场景：把上面的 `account-db` 绑进一个 Deployment**。

```yaml
# 用户 apply：声明 service（上游）+ workload（下游），reconciler 负责其余
apiVersion: servicebinding.io/v1
kind: ServiceBinding
metadata: { name: account-db }      # 也将成为投射目录名（除非 spec.name 另指定）
spec:
  service:
    apiVersion: example.dev/v1
    kind: Database
    name: account-db                # → §1 的 Provisioned Service
  workload:
    apiVersion: apps/v1
    kind: Deployment
    name: account-service
  env:
    - name: DB_PASSWORD             # 可选：把 Secret 的 password key 也投成 env
      key: password
```

### 一句话本质
**一个 `ServiceBinding` CR 声明"把哪个 service 绑进哪个 workload"，reconciler 据此改写 PodSpec。**

---

## §3 Workload Projection — Secret 怎样落进 Pod（edition: 社区 Apache-2.0；spec 1.1.0）【核心，展开】

### 解决什么问题
应用需要一种**跨服务、跨语言一致**的方式读取连接信息，而不是每接一个后端就学一套环境变量命名/挂载约定。Service Binding 的全部价值几乎都落在这一层——它**唯一真正标准化**的就是「投射出来的目录长什么样」。

### 核心模型 / 原理
reconciler 把目标 Secret 以 **volume 投射**方式挂进容器，目录布局固定：

```
$SERVICE_BINDING_ROOT/<binding-name>/
├── type        # well-known，必填：服务抽象类型（如 postgresql / mysql / kafka）
├── provider    # well-known，推荐：provider 标识
├── host
├── port
├── username
├── password
└── ...         # 每个 Secret key 一个文件，文件名=key，内容=value
```

**带编号的数据流（CR → 控制器做什么 → Pod 看到什么，必须能复述）**：

1. 用户 apply `ServiceBinding`（§2）。reconciler watch 到。
2. reconciler 解析 `.spec.service`：Provisioned Service → 读 `.status.binding.name` 拿 Secret 名；Direct Secret Reference（§4）→ 直接用 `.spec.service.name`。把结果写进 `ServiceBinding.status.binding.name`。
3. reconciler 解析 `.spec.workload`，按 workload 类型找到 PodSpec 注入点（默认 PodSpec-able；自定义类型见 §5 mapping）。
4. reconciler **改写 workload 的 PodSpec**：
   - 确定根目录：若容器已设 `SERVICE_BINDING_ROOT` env 则**不覆盖**（规范原文："The `$SERVICE_BINDING_ROOT` environment variable **MUST NOT** be reset if it is already configured"）；否则 reconciler 设一个（常见 `/bindings`）并写入该 env。
   - 加一个投射 Secret 的 volume，volumeMount 到 `$SERVICE_BINDING_ROOT/<binding-name>/`（`<binding-name>` = `.spec.name` 或 `.metadata.name`）。规范原文："A projected binding **MUST** be volume mounted into a container at `$SERVICE_BINDING_ROOT/<binding-name>`"。
   - 投射时：若 `.spec.type` 有值 → 覆盖目录里的 `type` 条目；`.spec.provider` 同理。
   - 若有 `.spec.env`，按 EnvMapping 把指定 key 加成容器 env。
5. kubelet 按改写后的 PodSpec 起 Pod；**app 在 `$SERVICE_BINDING_ROOT/<binding-name>/` 下读到一堆文件**（每个 Secret key 一个文件），或读到注入的 env。
6. **更新传导**：Secret 内容变化通过 K8s 投射 volume 的常规机制下传文件（有 kubelet 同步延迟，规范不规定具体延迟值——未确认）；但**新增/删除 binding 需 reconciler 改 PodSpec → Pod 重建**才生效（PodSpec 变更不能热更）。

**well-known Secret 条目**（规范定义，[spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)）：`type`（必填，抽象分类）、`provider`（推荐）、`host`、`port`、`uri`、`username`、`password`、`certificates`（PEM X.509 链）、`private-key`（PEM，mTLS 用）。规范要求：不满足这些语义的条目**必须换用别的条目名**（"entries that do not meet these requirements **MUST** use different entry names"）。

### 核心能力清单
- **目录约定**：`$SERVICE_BINDING_ROOT/<binding-name>/<key>`，一个 Secret key 一个文件。
- **well-known key 语义**：`type`/`provider`/`host`/`port`/`uri`/`username`/`password`/`certificates`/`private-key`。
- **env 投射**：通过 `.spec.env` 把选定 key 投成环境变量。
- **多 binding 共存**：同一 workload 可有多个 binding，各占 `$SERVICE_BINDING_ROOT` 下一个子目录。
- **app 侧 consumer 库**（读投射目录的现成库）：
  - **Spring Cloud Bindings**（JVM/Spring，自动把目录翻成 Spring 属性，[servicebinding.io application-developer](https://servicebinding.io/application-developer/)）。
  - **Quarkus** `quarkus-kubernetes-service-binding` 扩展（实现 Workload Projection 消费侧，[Red Hat Quarkus service binding 文档](https://docs.redhat.com/en/documentation/red_hat_build_of_quarkus/3.8/html/service_binding/assembly_service-binding_quarkus-service-binding)）。
  - 其他语言：`nebhale/client-jvm` 等（[application-developer](https://servicebinding.io/application-developer/)）。
- **边界**：投射进 Pod 的是 **Secret 明文内容**，不做加密、不短期化、不轮换语义；app 容器内的进程都能读这些文件（同容器无隔离）。

### 最小命令示例
> 未实测，基于官方文档 [spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/) / [application-developer](https://servicebinding.io/application-developer/)

**场景：app 启动后读投射目录拿连接信息**（接 §2 的 binding，目录名 `account-db`）。

```bash
# Pod 内 app 看到的（reconciler 改写 PodSpec 后由 kubelet 挂载）：
ls $SERVICE_BINDING_ROOT/account-db/
#   type  provider  host  port  username  password  ...

cat $SERVICE_BINDING_ROOT/account-db/type        # postgresql
cat $SERVICE_BINDING_ROOT/account-db/password     # s3cr3t   ← Secret 明文，直接落文件
# app 自行拼连接串；或用 Spring Cloud Bindings / quarkus 扩展自动映射成框架配置
```

### 一句话本质
**把 Secret 摊成 `$SERVICE_BINDING_ROOT/<name>/<key>` 的一堆文件（+可选 env），app 当本地文件读——这是 Service Binding 唯一真正标准化的东西。**

---

## §4 Direct Secret Reference（edition: 社区 Apache-2.0；spec 1.1.0）

### 解决什么问题
不是所有服务都实现了 Provisioned Service duck type（例如外部托管数据库、手工维护的凭据）。需要一条**不依赖服务方改造**的绑定路径。

### 核心模型 / 原理
当 `.spec.service.kind` 为 `Secret`、`.spec.service.apiVersion` 为 `v1` 时，ServiceBinding **直接引用该 Secret**，跳过 Provisioned Service 包装。规范原文："the `.spec.service.name` attribute **MUST** be treated as `.status.binding.name`"。之后投射流程与 §3 完全一致。（[spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)）

### 核心能力清单
- 直接把任意 K8s Secret 当绑定源。
- 服务方零改造（无需 `.status.binding`）。
- 投射行为与 Provisioned Service 路径一致（同 §3）。
- 边界：Secret 的内容仍需尽量遵循 well-known key，否则 consumer 库无法自动识别。

### 最小命令示例
> 未实测，基于官方文档 [spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)

```yaml
# 把一个手写 Secret 直接绑进 workload（无需 Provisioned Service）
apiVersion: servicebinding.io/v1
kind: ServiceBinding
metadata: { name: external-db }
spec:
  service:
    apiVersion: v1          # ← v1 + kind: Secret 触发 Direct Secret Reference
    kind: Secret
    name: external-db-secret
  workload:
    apiVersion: apps/v1
    kind: Deployment
    name: account-service
```

### 一句话本质
**`spec.service.kind: Secret` 即把任意 Secret 直接当绑定源，服务方零改造。**

---

## §5 WorkloadResourceMapping + Role-Based reconciler（edition: 社区 Apache-2.0；spec 1.1.0）

### 解决什么问题
两件配套事：(a) 默认只能绑 **PodSpec-able** 的 workload（Deployment/StatefulSet…）；自研 workload CRD 的 PodSpec 藏在非标准路径时需要告诉 reconciler 注入点。(b) RBAC 集群里 reconciler 需被授权读服务资源、改 workload 资源。

### 核心模型 / 原理
- **ClusterWorkloadResourceMapping**（`servicebinding.io/v1`，cluster-scoped）：用 CRD 风格命名（`<plural>.<group>`）描述某 workload 类型的注入点——`.spec.versions[]` 里用 JSONPath 指出 `annotations` / `containers` / `volumes` 的位置；版本可用 `*` 通配。规范要求：无 mapping 时 **MUST** 按 PodSpec-able 处理。
- **Role-Based reconciler（RBAC opt-in）**：reconciler 实现若用 RBAC，**MUST** 定义一个带 label selector `servicebinding.io/controller=true` 的 **aggregated ClusterRole**，并绑定到 reconciler 的 ServiceAccount。CRD 作者 / 集群运维通过给资源定义带该 label 的 ClusterRole（授 `get/list/watch`）来**显式 opt-in**「我这个资源允许被 service binding 读取/投射」。（[spec 1.1.0 §Role-Based Reconcilers](https://servicebinding.io/spec/core/1.1.0/)）

### 核心能力清单
- 把绑定能力扩展到任意自定义 workload 类型（指明注入点）。
- 通过 aggregated ClusterRole + label 实现「资源作者 opt-in 暴露」的授权模型。
- workload 投射所需 verbs：`get/list/watch/update/patch`；读服务资源：`get/list/watch`。
- 边界：mapping 只描述「注入点在哪」，不改变投射格式（仍是 §3 的目录）。

### 最小命令示例
> 未实测，基于官方文档 [spec 1.1.0](https://servicebinding.io/spec/core/1.1.0/)

```yaml
# (a) 告诉 reconciler 一个自定义 workload 类型的注入点
apiVersion: servicebinding.io/v1
kind: ClusterWorkloadResourceMapping
metadata: { name: cronjobs.batch }       # <plural>.<group>
spec:
  versions:
    - version: "*"
      annotations: .spec.jobTemplate.spec.template.metadata.annotations
      containers:
        - path: .spec.jobTemplate.spec.template.spec.containers[*]
---
# (b) CRD 作者 opt-in：让 reconciler 有权读自己的服务资源
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: example-database-binding
  labels: { servicebinding.io/controller: "true" }   # ← 被 reconciler 的 aggregated ClusterRole 收编
rules:
  - apiGroups: ["example.dev"]
    resources: ["databases"]
    verbs: ["get", "list", "watch"]
```

### 一句话本质
**Mapping 告诉 reconciler「自定义 workload 的注入点在哪」；`servicebinding.io/controller=true` 的 aggregated ClusterRole 让资源作者显式 opt-in 授权。**

---

## §6 规范 vs 实现生态 + 维护状态（含 SBO 弃用）

> **这是本指南最容易被外部材料搞混的一节，单独讲清。** 「Service Binding 规范活着」与「Red Hat 的那个 operator 死了」是两件事，不要混为一谈。

### 三层要分清

| 层 | 是什么 | 仓库 / 站点 | 许可 | 维护状态 |
|---|---|---|---|---|
| **规范（spec）** | 社区标准，定义 §1–§5 全部契约 | [servicebinding.io](https://servicebinding.io/) / [servicebinding/spec](https://github.com/servicebinding/spec) | **Apache-2.0** | **活跃**。最新 **Core 1.1.0**（2024-03-12 release）；社区 working group 持续运作（[spec README](https://github.com/servicebinding/spec/blob/main/README.md)） |
| **参考实现** | 规范的官方参考 reconciler | [servicebinding/runtime](https://github.com/servicebinding/runtime) | **Apache-2.0** | **活跃**。最新 **v1.0.0**（2024-07-16），实现 spec 1.0 + 1.1；源码构建需 cert-manager（[runtime releases](https://github.com/servicebinding/runtime/releases)） |
| **Red Hat 实现（SBO）** | Red Hat 的 Service Binding Operator | [redhat-developer/service-binding-operator](https://github.com/redhat-developer/service-binding-operator) | Apache-2.0 | ⚠️ **已弃用（DEPRECATED）**：**2024-02** 起停止特性开发；**仓库已归档（最后活动 2024-06-26）**；官方建议迁到 `servicebinding/runtime`（[SBO 弃用通知](https://redhat-developer.github.io/service-binding-operator/userguide/intro.html)、[SBO README](https://github.com/redhat-developer/service-binding-operator/blob/master/README.md)） |

**SBO 弃用通知原文要点**（[SBO README](https://github.com/redhat-developer/service-binding-operator/blob/master/README.md)）：
- "No further feature development is expected at this time."
- 安全修复 "on an as-need basis, but no schedule … can be guaranteed"。
- "Usage of this project for new deployments is no longer recommended"；建议改用 [servicebinding/runtime](https://github.com/servicebinding/runtime)。
- 注意：SBO 历史上对规范有**超集扩展**（如更灵活的 binding 数据提取注解 `service.binding/...`、自动检测绑定数据等）；这些 Red Hat 私有增强随 SBO 弃用而不再演进，规范侧的 `servicebinding/runtime` **不一定**等价覆盖（具体差异未确认）。

### 不要与 Open Service Broker / Service Catalog 混淆（一行）
**Open Service Broker API（OSB API）+ Kubernetes Service Catalog 是另一个、更早、已休眠的东西**：Service Catalog 现位于 `kubernetes-retired/service-catalog`（已退役），用 OSB API 在集群里 provision 外部服务实例（svcat CLI）。它解决的是「provision 服务实例」，与 Service Binding「把已有服务的 Secret 投射进 workload」**不是同一层、不是同一标准**（[kubernetes-retired/service-catalog](https://github.com/kubernetes-retired/service-catalog)）。spec README 仅把 Heroku / Cloud Foundry / Open Service Broker 列为「prior art」，并不依赖它们（[spec README](https://github.com/servicebinding/spec/blob/main/README.md)）。

### 维护状态小结
- **规范本身：活跃**（1.1.0 是当前 released 版本；仍标注 working draft 性质供早期实现者反馈）。
- **官方参考实现 `servicebinding/runtime`：活跃**（v1.0.0 / 2024-07）。
- **Red Hat SBO：死亡**（弃用 + 归档）。外部资料若说"Service Binding 已弃用"通常指的是 SBO 这一个实现，**不是规范**。

---

## §7 整体回顾 + 许可 / air-gap

**整体回顾**：Service Binding 是**单层社区开源标准**，没有 Enterprise/付费边界。它把一件很窄的事做成跨实现的契约：**「后端服务的连接 Secret」如何以「约定目录的文件（+可选 env）」投射进「工作负载容器」**。三个角色（服务方实现 Provisioned Service、运维写 ServiceBinding、开发者读投射目录）各自只需关心自己那段约定。

它**不做**的（关键边界，避免误判为缺陷）：
- 不存储、不创建、不轮换、不短期化凭据 —— 投进 Pod 的就是 Secret 明文。
- 不做协议代理 / 出栈认证注入 —— app 拿到凭据后**自己**去连后端服务（凭据进 app 地址空间）。
- 无资源浏览 API、无 Pipeline/CI 资源选择器、无运行时审批门控、无镜像拉取代理。
- 不 provision 服务实例（那是 OSB API / Service Catalog 的事，且已休眠）。

**许可 / 生态 / air-gap**：
- **许可**：spec 与参考实现均 **Apache-2.0**；无 Enterprise tier（[spec](https://github.com/servicebinding/spec)、[runtime](https://github.com/servicebinding/runtime)）。
- **生态形态**：「一个规范 + 多个实现」。可选实现：官方 `servicebinding/runtime`（活跃）、Red Hat SBO（已弃用归档）、各厂商发行版内置（如 VMware Tanzu Application Platform——具体增强未确认）。
- **air-gap**：reconciler 是普通 K8s 控制器，镜像可离线运行；投射机制纯 K8s volume，无外呼。`servicebinding/runtime` 源码构建依赖 cert-manager（运行时是否强依赖未确认）。
- **维护状态**：规范与官方参考实现活跃；最广为人知的 Red Hat 实现已弃用——选型务必盯准是哪个实现。

---

## 附：额外有价值发现（技能范围外）

- **"凭据进 app 地址空间"是与代理类方案的结构性分水岭**：Service Binding 把 Secret 明文落进 Pod 文件，app 直接持有连接凭据去连后端。它**天生**不提供"客户端永不持有真凭据""出栈方向注入""per-request 授权/审计"这类能力——这不是缺陷，是它的定位（标准化投射，而非数据面代理）。评估任何"绑定/投射"方案时，这条边界决定了它能不能满足"零客户端凭据"诉求。
- **well-known key 约定本身是可复用的低成本资产**：`type`/`provider`/`host`/`port`/`uri`/`username`/`password`/`certificates`/`private-key` 是一套跨语言、有 consumer 库支持（Spring Cloud Bindings / Quarkus）的成熟约定。任何"把连接信息投进 workload"的方案若采用这套 key + `$SERVICE_BINDING_ROOT` 目录布局，可直接复用现有 app 侧生态，省掉自定义消费胶水。
- **SBO 的死亡是"实现死、标准活"的典型案例**：检索时极易把 SBO 的弃用误读为整个 Service Binding 失败。实际是 Red Hat 退出该 operator 的维护、把社区导向 `servicebinding/runtime`，规范与参考实现仍活跃。竞品/邻接产品调研里要区分"标准 / 某个实现"的生死。
- **PodSpec 改写 = binding 增删需 Pod 重建**：reconciler 通过改 PodSpec 注入 volume/env，因此**新增或移除一个 binding 会触发 workload 滚动重建**；只有 Secret **内容**变化才走 K8s volume 的常规热更（有 kubelet 同步延迟）。这对"凭据轮换是否需要重启 Pod"的判断很关键——内容轮换不需重启，binding 拓扑变化需要。

---

**相关文档**：`connectors-vs-service-binding.md`（与 Connectors 的对比 + 边界 + roadmap 启发）。
