# DevOps Connectors Approvals & Checks 技术实现提案

- [DevOps Connectors Approvals \& Checks 技术实现提案](#devops-connectors-approvals--checks-技术实现提案)
  - [摘要](#摘要)
  - [动机](#动机)
    - [目标](#目标)
    - [非目标](#非目标)
  - [设计提案](#设计提案)
    - [流水线直接复用 ApprovalTask \& ApprovalRequest](#流水线直接复用-approvaltask--approvalrequest)
    - [新提案](#新提案)
      - [原始问题与使用体验](#原始问题与使用体验)
      - [新方案：按 Connector 维度拆分权限](#新方案按-connector-维度拆分权限)
    - [依靠 Token 实现无状态的审批判断](#依靠-token-实现无状态的审批判断)
      - [使用 临时的 RBAC 来控制](#使用-临时的-rbac-来控制)
    - [ApprovalTask \& ApprovalRequest 的复用](#approvaltask--approvalrequest-的复用)
      - [思路1:](#思路1)
      - [思路2 (推荐)](#思路2-推荐)
      - [思路 3](#思路-3)
    - [方案概述](#方案概述)
  - [设计详情](#设计详情)
    - [数据结构](#数据结构)
      - [ResourceCheckRule](#resourcecheckrule)
      - [ResourceCheckRequest](#resourcecheckrequest)
    - [Approval Context](#approval-context)
      - [Token 的结构](#token-的结构)
      - [流水线通过 CSI Driver 挂载](#流水线通过-csi-driver-挂载)
      - [CLI 调用 API 请求](#cli-调用-api-请求)
      - [数据结构](#数据结构-1)
    - [审批申请](#审批申请)
      - [Connectors CSI Driver](#connectors-csi-driver)
      - [CLI](#cli)
    - [API \& Proxy 请求校验](#api--proxy-请求校验)
      - [根据审批标识进行审批复用](#根据审批标识进行审批复用)
      - [请求校验](#请求校验)
    - [审批记录](#审批记录)
  - [设计评估](#设计评估)
    - [复用性](#复用性)
      - [TektonCD Approval 复用](#tektoncd-approval-复用)
      - [审批检查机制复用](#审批检查机制复用)
    - [性能](#性能)
    - [易用性](#易用性)
    - [扩展性](#扩展性)
    - [风险与缓解措施](#风险与缓解措施)
  - [实施计划](#实施计划)
    - [阶段一: 先按照部分手工的方式跑通流程](#阶段一-先按照部分手工的方式跑通流程)
    - [阶段二：核心框架（MVP）](#阶段二核心框架mvp)
    - [阶段三：UI 集成 Connector 审批体验](#阶段三ui-集成-connector-审批体验)
    - [阶段三：其他扩展审批类型](#阶段三其他扩展审批类型)
  - [TODO](#todo)

## 摘要

本文档描述 DevOps Connectors 审批与检查（Approvals & Checks）功能的技术实现方案。该方案在不改变 Connector 现有使用模式的前提下，为生产环境的敏感操作增加可控的审批门禁。

## 动机

当前 Connectors 平台提供了便捷的 Secretless 访问能力，但对于生产环境的关键操作，仅依赖 RBAC 权限控制是不够的。需要引入审批机制，确保敏感操作经过必要的审核流程。

### 目标

1. 设计相关 CRD，记录审批请求及其状态
2. 集成 CSI Driver，在挂载时创建审批请求和等待审批结果
3. 集成 Proxy/API Server，在请求时校验审批结果
4. 支持按 HTTP 方法过滤审批范围（GET 操作默认不需要审批）
5. 支持按执行上下文（PipelineRun/TaskRun/Pod）复用审批结果

### 非目标

1. 不涉及 UI 层面的实现细节
2. 不实现 Jira/ServiceNow 等外部系统的深度集成（作为扩展预留）

## 设计提案

### 流水线直接复用 ApprovalTask & ApprovalRequest

思路: ApprovalTask 增加 connector 和 subject 标记信息。 在审批检查判断时，通过 connector 和 subject 信息查找是否存在 ApprovalTask & ApprovalRequest 资源， 直接获取审批状态。

**ApprovalTask & ApprovalRequest 增加 Admission Webhook:**

- 分析资源的 Owner's Owner 信息， 找到 PipelineRun 资源， 作为 Context Resource. 找到CustomRun 的 service account 作为 Context Subject. 将其标记在
ApprovalTask & ApprovalRequest 的 labels/annotations 上。 `approval.alaudadevops.io/context: '{"subject":{...},"resource":{...}}'`
- Adminssion Webhook 控制该 annotation 不允许修改。

**审批检查判断**

- API & Proxy 进行验证时，获取当前 UserInfo, Connector，Token 携带的 Pod 信息
- 构造出 connector, context{subject, resource}.
- 根据 labels/annotations 查看对应的 ApprovalTask & ApprovalRequest 的状态。

存在的问题是， ApprovalTask & ApprovalRequest 是否 Connector 当前的审批配置一致。 如果不一致， 实际是需要拒绝的。

~~在 CheckRequest 状态计算时， 根据请求的 context 信息， 匹配当前存在的 ApprovalTask & ApprovalRequest 资源， 获取审批状态。
controller 计算可能会有延迟 ？~~

**挑战**

如果流水线中编排的 ApprovalTask 和 Connector 审批不一致。比如 Connector 配置了必须 2 人审批通过， 流水线中编排的 ApprovalTask 只配置了 1 人审批。 逻辑上不应该复用。

即：需要判断审批配置是一致的， 流水线编排才能起到代替作用。

复杂度: 审批配置的一致性，引入的用户体验的复杂度较高。 流水线编排的用户 ，为了达到避免 Connector 挂载时进行审批" 这一步目标， 必须了解如何和要使用的 Connector 的审批配置保持一致， 否则会导致审批无法复用。

**其他**

如果是编排一个 CheckRequest Task 呢？意味着 CheckRequest 中的 Connector，Context 信息，是自动通过流水线上下文分析而来的。
在 CustomRun 的 CheckRequest Task Controller 中，可以查询到这些 Context，可以直接创建 CheckRequest. 目标就是针对 Connector 发起的申请，直接使用 Connector 配置好的规则。

### 新提案

> 在流水线中由用户显式编排审批 Task，当流水线实际调用 Connector 能够复用审批 Task 的审批结果。

核心问题是：在流水线执行中，使用 Connector 访问敏感环境/资源时，是否能强制先完成审批再放行。

#### 原始问题与使用体验

- 制品晋级：管理员预先配置生产环境的 `prod-harbor` Connector，希望开发者向 `prod-harbor` 推送制品前必须先通过审批。
- 生产部署：管理员预先配置生产环境的 `prod-k8s` Connector，希望开发者部署到生产环境前必须先通过审批。

**当前 Pipeline + Connector 使用体验**

- 在 `prod` 命名空间中创建 `prod-harbor`、`prod-k8s` 等 Connector. 并通过命名空间权限控制，开发者本身不具备该 ns 的访问权限。
- 在 `prod` 命名空间内，由具备更高权限的用户使用部署/晋级 Task 编排流水线。
- 晋级或生产部署流水线由当前命名空间中“有权限执行流水线的人”触发. (这个人不能是普通开发者)

整体无法形成「低权限用户发起申请 → 高权限用户审批授权 → 自动执行」的体验。

Connector 维度增加审批，能够解决如上问题。同时将工具使用授权集中到 Connector 及其 Owner 上，授权边界更清晰、责任更明确。

 #### 新方案：按 Connector 维度拆分权限

将「读取 Connector」与「通过 Connector 调用工具 API」两类权限拆开：

- `connectors`: `Get/List/Watch/Delete`
- `connectors/apis`: `Read/Write`（代表通过 Connector 访问实际工具 API 的能力, 读写操作）

**Pipeline + Connector 用户的使用体验**

权限配置:

- 开发者加入 `prod` 命名空间
- 开发者在 `prod` 命名空间内具备：`connectors:Get/List` 以及 `connectors/apis:Read` 权限。
- 开发者在 `prod` 命名空间内具备执行流水线的权限。 不具备 `connectors/apis:Write` 权限 以及 流水线 编排权限。

**操作流程**

1. 命名空间管理员在 `prod` 命名空间中创建 `prod-harbor`、`prod-k8s` 等 Connector。
2. 命名空间管理员使用部署/晋级 Task 编排流水线，并在其中加入审批 Task，将审批人配置为环境 Owner。
3. 命名空间管理员将流水线的执行 SA 授予 `connectors/apis:Write` 权限。

4. 开发者在需要制品晋级或生产部署时，执行流水线， 执行时，可以选择 connector, 方便的选择到 镜像 或者 集群 Workload.
5. 流水线执行到审批 Task 时挂起，等待审批人审核；审批通过后，流水线继续执行，使用 Connector 访问对应生产资源。

:::info

- 开发者不具备 `connectors/apis:Write` 权限， 在任何情况下（CLI）, 也无法向 `prod-harbor`, `prod-k8s` 推送镜像或者部署操作。
- Pipeline 以 执行 SA 的身份访问 Connector, 具备 `connectors/apis:Write` 权限。
:::

- 模型更简单，依靠 RBAC 和 NS 隔离解决原始问题。
- 依靠 PipelineRun ServiceAccount 控制流水线的实际执行权限

**补充**

- `connectors/apis:Write` 和 `connectors/apis:Read` 在实现层面， 可以并不唯一对应 Http Methods。 我们可以提供针对 Connector 的配置，允许用户自定义 对于某个工具，将何种操作定义为 Read/Write. 默认可以按照 http 的methods 来。


### 依靠 Token 实现无状态的审批判断

**k8s 签发 Token**

>  k8s 已有的签发 Token 的API， 不支持增加扩展信息。

可考虑参考 k8s 的 Token 签发逻辑， 自己实现一个 Token 签发服务。

- 兼容 k8s token，k8s 系统能识别
- 不兼容 k8s token

**兼容 k8s token**

- 需要有 k8s 签发的私钥
- 和 k8s 签发逻辑长期保持一致，成本较高。

**不兼容 k8s token**

- 二次包装 k8s token, 增加扩展信息后， 签名生成新的 JWT Token
- 自己维护签发私钥

**和 UI 调用差异**

通过 UI 进行 API 调用的场景，用户使用的是平台的 Token。 服务端需要支持无审批状态的 Token。

**小结**

单独实现的签发 Token 的服务不能完全解决问题，系统还是需要保存审批状态。引入的成本不划算。

#### 使用 临时的 RBAC 来控制

增加 connectors/proxy 的 RBAC 控制, 当审批通过时， 创建一个 临时的 RoleBinding， 绑定到 Subject 上， 有效期为 Token 的有效期。

- 授权时间可控
- 资源（PipelineRun/Job）的生命周期 和 rolebinding 生命周期保持同步
- Context Resource 约束问题无法解决
  - PipelineRun -1 的 Token 在生命周期内，如果泄露，依然可以在其他地方使用。

### ApprovalTask & ApprovalRequest 的复用

#### 思路1:

参考 TektonCD CustomRun 增加中间层 CustomCheckRequest CRD 记录审批配置。

- 自定义的 Controller 负责监听 CustomCheckRequest， 创建 ApprovalTask / ApprovalRequest.
- 自定义的 Controller 负责监听 ApprovalTask / ApprovalRequest 的资源变化， 更新 CustomCheckRequest 的结果
- 当前系统获取 CustomCheckRequest 的结果， 决定审批状态。

示例yaml:

<details>
<summary>点击展开</summary>

``` yaml
spec:
  checkRequestRef:
    kind: ApprovalTask
    apiVersion: openshift-pipelines.org/v1alpha1
  params:
    - name: approvers
      value:
        - te2t-admin@alauda.io
        - group:g-4lclv
    - name: numberOfApprovalsRequired
      value: "2"
```

</details>

#### 思路2 (推荐)

参考 Knative 的 DuckType 的理念, 抽象 `Approval Duck Type` 的基本数据结构， 定义统一的数据访问接口。

- 在资源的审批配置中， 直接使用 ApprovalTask / ApprovalRequest 的 Spec 作为审批配置。
- 审批执行时， 根据审批配置， 创建对应的 ApprovalTask / ApprovalRequest 实例。
- 审批状态同步时， 系统根据约定的 `Approval Duck Type` CR 的结构，获取审批状态。

yaml 示例:

<details>
<summary>点击展开</summary>

``` yaml
# 某个资源的审批配置
spec:
  object: {}

  template:
    apiVersion: openshift-pipelines.org/v1alpha1
    kind: ApprovalTask
    spec: {} # ApprovalTask Spec
status: {}
---
# 某个资源的审批配置
spec:
  object: {}

  template:
    apiVersion: approval.alaudadevops.io/v1alpha1
    kind: ApprovalRequest
    spec: {} # ApprovalRequest Spec
status: {}
```

</details>

`Approval Duck Type` 如下

- 支持 generateName
- 支持审批状态的自动计算
- 含有 `status.state` 字段，标识审批状态. 审批状态如: pending | approved | rejected | error 等。
- 其他

**挑战**

- `Approval Duck Type` 的抽象需要找到一个平衡点， 既要足够通用， 又要满足不同 ApprovalTask / ApprovalRequest 的需求。业务场景需要依赖这个平衡点完成设计，一定程度上有所限制。

#### 思路 3

直接耦合 ApprovalTask & ApprovalRequest 到 审批检查配置 中， 不做抽象。

``` yaml
spec:
  approvalTaskSpec: {} # ApprovalTask Spec
  approvalRequestSpec: {} # ApprovalRequest Spec
```

**缺点**

- 数据结构直接耦合，升级耦合。

### 方案概述

- 抽象针对 某个资源 "审批规则配置"，"审批申请" 两个核心概念。
- 复用 ApprovalTask & ApprovalRequest 作为审批检查的具体实现。
- API & Proxy 通过检查 "审批申请"，对审批状态的进行校验。
- Connectors CSI Driver 可选发起审批申请与等待审批结果。

**ResourceCheckRule**

审批配置, 一个 Connector 对应多个 ResourceCheckRule 。记录 Connector 关联的审批检查规则。
一个 ResourceCheckRule 包含一个审批检查配置.


<details>
<summary>Yaml 示例</summary>

``` yaml
kind: ResourceCheckRule
apiVersion: approval.alaudadevops.io/v1alpha1
metadata:
  name: connector-manural-approval-check
spec:
  objectRef:
    kind: Connector
    apiVersion: connectors.alaudadevops.io/v1alpha1
    name: prod-harbor
    namespace: connectors-system
  when: # 进行审批检查的条件
    http:
      methods:
        - POST
        - PUT
  checkTemplate:
      apiVersion: openshift-pipelines.org/v1alpha1
      kind: ApprovalTask
      spec:
        # ApprovalTask Spec

    #   apiVersion: openshift-pipelines.org/v1alpha1
    #   kind: ApprovalRequest
    #   spec:
    #     # ApprovalRequest Spec
```

</details>

**ResourceCheckRequest**

审批请求, 代表用户发起的针对某个 Connector 的审批检查请求。计算并记录当前审批检查的状态。
一个 ResourceCheckRequest 可以创建多个 ApprovalTask & ApprovalRequest。

<details>
<summary>Yaml 示例</summary>

``` yaml
kind: ResourceCheckRequest
apiVersion: approval.alaudadevops.io/v1alpha1
metadata:
  name: connector-check-request-001
  namespace: devops-ns1
spec:

  objectRef:
    kind: Connector
    apiVersion: connectors.alaudadevops.io/v1alpha1
    name: prod-harbor
    namespace: devops-project-ns

  context: # 审批申请的上下文信息，根据此进行审批的复用。 参考 ResourceCheck Context
    subject: "system:serviceaccount:default:pipeline-sa"
    token:
      jti: "393678b6-f5ac-49d0-b141-64a177a92e5b"
    pod:
      uid: "xxx-yyy-zzz"
      name: "deploy-prod-xxx"
      namespace: "devops-ns1"
    resource:
      apiVersion: tekton.dev/v1
      kind: PipelineRun
      name: deploy-prod-xxx
      namespace: devops-ns1

# 记录 1. 审批检查的配置规则，2. 审批检查的状态
status:
  conditions: []

  rules: # Copy 当前的 ResourceCheckRule 中的配置
  - metadata:
      name: connector-manural-approval
    spec: {}
  - metadata:
      name: connector-jira-approval
    spec: {}
  requestRefs: # 根据 ResourceCheckRule 生成的具体审批检查请求引用
  - name: connector-manural-approval-xxx
  - name: connector-jira-approval-xxx

  results: # 同步 Approval-Like CR 中的审批检查结果
  - name: connector-manural-approval
    state: approved | rejected | pending | error
  - name: connector-jira-approval
    state: approved | rejected | pending | error

```
</details>

**ApprovalTask & ApprovalRequest**:

- ResourceCheckRequest Controller 根据审批检查配置，创建对应的 ApprovalTask & ApprovalRequest 实例。
- ApprovalTask 和 ApprovalRequest 独立维护自己的审批检查状态。

**API & Proxy**:

根据客户端请求，根据 Approval Context 信息查找相应的 ResourceCheckRequest，检查审批状态，确定是否允许。

**Connectors CSI Driver**:

- 根据 Pod 信息，查找是否有匹配 ResourceCheckRequest
- 如果 ResourceCheckRequest 存在， 则等待审批结果确认
- 如果 ResourceCheckRequest 不存在，则根据 Pod 信息和 Connector 信息， 创建 ResourceCheckRequest
- 审批结果确认后，Pod 挂载成功或者失败。

## 设计详情

### 数据结构

#### ResourceCheckRule

- appiVersion: approval.alaudadevops.io/v1alpha1
- kind: ResourceCheckRule
- Namespaced Scope

<details>
<summary>数据结构</summary>

``` yaml
kind: ResourceCheckRule
apiVersion: approval.alaudadevops.io/v1alpha1
metadata:
  name: connector-manural-approval-check
  namespace: devops-project-ns
  labels:
    approval.alaudadevops.io/objectKind: Connector
    approval.alaudadevops.io/objectName: prod-harbor
spec:

  objectRef: # LocalObjectReference 指向配置的目标资源
    kind: Connector
    apiVersion: connectors.alaudadevops.io/v1alpha1
    name: prod-harbor
    namespace: devops-project-ns # ResourceCheckRule 所在的命名空间

  when: # 进行审批检查的条件
    http:
      methods:
        - POST
        - PUT

  checkTemplate: # Approval Duck Type CR 模板
    apiVersion: openshift-pipelines.org/v1alpha1
    kind: ApprovalTask
    spec:
      # ApprovalTask Spec

#   apiVersion: openshift-pipelines.org/v1alpha1
#   kind: ApprovalRequest
#   spec:
#     # ApprovalRequest Spec

#   apiVersion: openshift-pipelines.org/v1alpha1
#   kind: ScriptCheck
#   spec:
#     # ScriptCheck Spec
```

</details>


#### ResourceCheckRequest

使用 ResourceCheckRequest 来代表针对某个资源发起的审批检查请求, 计算并记录当前审批检查的结果。

- appiVersion: approval.alaudadevops.io/v1alpha1
- kind: ResourceCheckRequest
- Namespaced Scope

数据结构：

<details>
<summary>点击展开...</summary>

``` yaml
kind: ResourceCheckRequest
apiVersion: approval.alaudadevops.io/v1alpha1
metadata:
  name: connector-check-request-001
  namespace: devops-ns1 #
spec:

  objectRef: # 审批使用的目标资源
    kind: Connector
    apiVersion: connectors.alaudadevops.io/v1alpha1
    name: prod-harbor
    namespace: devops-project-ns

  # 审批申请的上下文信息， 参考 Approval Context
  context:
    subject: "system:serviceaccount:default:pipeline-sa"
    token:
      jti: "393678b6-f5ac-49d0-b141-64a177a92e5b"
    pod:
      uid: "xxx-yyy-zzz"
      name: "deploy-prod-xxx"
      namespace: "devops-ns1"
    resource:
      apiVersion: tekton.dev/v1
      kind: PipelineRun
      name: deploy-prod-xxx
      namespace: devops-ns1

```

</details>

**status**

<details>
<summary>点击展开</summary>

``` yaml
status:
  rules: # Copy 当前查询出来的 ResourceCheckRule 中的配置，进行保存。
  - metadata:
      name: connector-manural-approval
    spec: {}
  - metadata:
      name: connector-jira-approval
    spec: {}

  conditions:
  - type: Ready
    status: "True" # | "False" | "Unknown"
    reason: "AllChecksApproved" # | "ChecksPending" | "ChecksRejected" | "Error"
    message: "Detailed message about the current state"

  requestRefs: # 根据 ResourceCheckRule 生成的具体审批检查请求，记录引用信息。
  - name: connector-manural-approval-xxx
  - name: connector-jira-approval-xxx

  results: # 同步 Approval-Like CR 中的审批检查结果
  - name: connector-manural-approval
    state: approved | rejected | pending | error
  - name: connector-jira-approval
    state: approved | rejected | pending | error
```

</details>

**status.conditions**

TODO

- `type=Ready`
- `type=xxx`

### Approval Context

审批申请的上下文信息， 用于计算审批请求的唯一标识， 以及审批请求的复用。

#### Token 的结构

<details>
<summary>Service Account Token 结构</summary>

``` json
{
  "aud": [
    "connectors-proxy"
  ],
  "exp": 1768116599, /*有效期的截止时间*/
  "iat": 1767943799, /*签发时间*/
  "nbf": 1767943799, /*生效时间*/
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "0a647a3e-1a6d-430e-b16d-a514a2145310", /* Token 唯一标识 */
  "kubernetes.io": { /* Kubernetes 特有字段 */
    "namespace": "connectors-system",
    "node": {
      "name": "192.168.143.123",
      "uid": "d6bd54e6-39e7-424a-8efa-6cbd487cb5a3"
    },
    "pod": { /* 仅支持Node, Pod, Secret, 签发时资源必须存在， 资源不存时，Token 失效 */
      "name": "connectors-proxy-c5cd46cdc-v9tzr",
      "uid": "6b2996e0-bbfc-4fae-8fcd-6074cff95ab3"
    },
    "serviceaccount": {
      "name": "connectors-proxy",
      "uid": "ee9e0e06-a370-4c6c-8154-c8baf7525673"
    }
  },
  "sub": "system:serviceaccount:connectors-system:connectors-proxy"
}
```

</details>

<details>
<summary>ACP API Token</summary>


``` json
{
  "jti": "393678b6-f5ac-49d0-b141-64a177a92e5b", /* Token 唯一标识 */
  "exp": 1768549584, /* 有效期的截止时间 */
  "iat": 1767944787, /* 签发时间 */
  "typ": "AccessToken",
  "email": "admin"
}
```

</details>

#### 流水线通过 CSI Driver 挂载

同一个 PipelineRun，对同一个 Connector 使用请求只需要审批一次， 审批通过后，其他 TaskRun 使用时，或者 发生重试时，不需要重新审批。

- Subject: 审批时，更容易了解当前操作者是谁
- PipelineRun: 通过 Pod 上的 owner's owner 获取

例如:

``` yaml
context:
  subject:
    apiGroup: rbac.authorization.k8s.io
    kind: User # | ServiceAccount
    namespace: "" # default
    name: "admin" # | "default-sa"
  resource:
    apiVersion: tekton.dev/v1
    kind: PipelineRun
    name: deploy-prod-xxx
    namespace: devops-ns1
```

TODO:

- 并发的审批请求的问题。 多个 Task 同时进行， 除了 Pod 不同外， 其他均相同 ， 会创建多个审批请求。 需要考虑合并审批请求。 如果使用 Owner 来查询， 则不需要记录 pod 信息了。
- 通过 Pod Owner 的 Owner 获取 PipelineRun 这个动作不能是一个固定的逻辑，需要结合其他场景，考虑配置化。


#### CLI 调用 API 请求

用户发起针对 Connector 的使用的审批请求， 审批通过后， 在有效期内， 当前用户 可以重复进行 API 调用，无需重复审批。
当用户更换其他 Token 时，只要在授权时间内，不受影响，不需要再次审批。

- Subject: 审批时，更容易了解当前操作者是谁
- Duration: 授权有效期。可以对个人有较长有效期的 Token 进行限制。

例如：

``` yaml
context:
  subject:
    apiGroup: rbac.authorization.k8s.io
    kind: User
    name: "admin"
timeRange: # 授权时间范围
  duration: "2h"
```

#### 数据结构

- subject 字段在 admission 中， 通过 Request UserInfo 自动获取后赋值， 且不允许更新。
- 客户端可以自由传递 context.resource 字段

例如：

``` yaml
context:
  subject:
    apiGroup: rbac.authorization.k8s.io
    kind: User # | ServiceAccount
    namespace: # default
    name: "admin" # | "default-sa"
  resource:
    apiVersion: tekton.dev/v1
    kind: PipelineRun
    name: deploy-prod-xxx
    namespace: devops-ns1
timeRange: # 授权时间范围
  duration: "2h"
  # after: "2024-07-10T12:00:00Z"
  # before: "2024-07-10T10:00:00Z"
```

### 审批申请

- CSI Driver 自动申请审批请求
- CLI 场景，用户自主创建审批请求

#### Connectors CSI Driver

- CSI Driver 签发 Token 前, 先根据 `NodePublishVolumeRequest` 中，获取  `pod` 和 `sa` 信息。
- 读取 Pod 的 Owner's Owner， 获取 PipelineRun 信息。
- 构造 Approval Context 信息。 context { subject, resource }
- 根据 ConnectorRef 和 Approval Context 信息， 计算审批请求的唯一标识， 查找是否已经存在 ResourceCheckRequest。
- 如果不存在则 impersonate pod sa 创建 ResourceCheckRequest {connectorRef, context}
- 如果存在，则轮询等待审批结果确认。
- 审批结果确认后，
  - 如果审批通过， 则签发 Token，完成挂载。
  - 如果审批拒绝， 则返回错误， Pod 挂载失败。

#### CLI

- 用户通过 CLI 创建 ResourceCheckRequest 审批请求。
- 服务端判断当前 ResourceCheckRequest 中，是否携带 Context Resource 信息，如果不含有 Context Resource 信息， 则根据 Token 信息，补全 Context Resource 信息。

TODO:

- 在 adminssion webhook 无法拿到 token， 无法自动计算 jti.

解决办法：

1. 客户端由用户自行传递 jti ✅
2. 在 Payload 中增加 token 字段， AdminssionWebhook 解析 token， 获取 jti 信息， 补全 ResourceCheckRequest 中的 Context Resource 信息。 Token 在 CR 中实际不做记录。
3. 或者修改 OIDC Token 签发配置， 在 Token 中增加 jti 字段。

### API & Proxy 请求校验

请求 到达 API 或者 Proxy 时， 进行审批有效性的校验。

- 根据客户端请求， 获取 Token 信息
- 根据当前请求信息，计算审批的请求的唯一标识。
- 根据标识查找审批记录。
- 审批有效则通过。
- 审批无效则拒绝。

#### 根据审批标识进行审批复用

- PipelineRun 场景: md5{ConnectorRef, Context{Subject, Resource{}}} 作为审批请求的唯一标识。
- CLI 场景: md5{ConnectorRef, Context{Subject}, Token{jti}} 作为审批请求的唯一标识。

`ResourceCheckRequest` 资源上，增加 fingerprint label， 记录审批请求的唯一标识。

``` yaml
kind: ResourceCheckRequest
apiVersion: approval.alaudadevops.io/v1alpha1
metadata:
  labels:
    approval.alaudadevops.io/resourcecheckrequest.fingerprint: "md5{ConnectorRef, Subject, ContextResource{resource:PipelineRun}}"
```

#### 请求校验

- 客户端请求时， 携带 Token
- 服务端进行 Token 合法性校验
- 服务端解开 Token
  - 如果 token 含有 k8s 信息， 那么
    - 根据 pod 信息关联的 owner's owner 信息，获取 Context{Resource} 信息
    - 构造 {ConnectorRef, Context{Subject, Resource{}}} 计算唯一标识，查找审批请求记录。
  - 如果 token 不含有 k8s 信息， 那么
    - 构造 {ConnectorRef, Context{Subject}, Token{jti}} 计算唯一标识，查找审批请求记录。
- 审批请求存在，且审批检查已拒绝， 则审批检查不通过。API 拒绝。
- 若审批请求不存在， 则审批检查不通过。API 拒绝。
- 审批请求存在，且审批检查通过，
  - 判断授权时间是否在有效期内， 如果在有效期内， 则审批检查通过。API 允许。
  - 判断 Context{Resource} 是否在生命周期内， 如果在生命周期内， 则审批检查通过。API 允许。

TODO:

- 根据 Pod 关联信息，需要变成配置项， 是找到 Owner 还是 Owner's Owner。
- 每个 API 请求需要 判断资源的是否在生命周期内， 可能会带来性能问题。考虑利用 Controller Reconcile 即使对已经失效的 ResourceCheckRequest 进行实现标记，使得 API 检查时， 无需每次都检查资源的生命周期。

### 审批记录

- ResourceCheckRequest 记录审批请求的配置和状态。
- 根据 ResourceCheckRule 查看关联的审批检查动作执行情况。
  - ApprovalTask / ApprovalRequest

## 设计评估

### 复用性

#### TektonCD Approval 复用

| 组件                                      | 复用程度 | 说明                                             |
| ----------------------------------------- | -------- | ------------------------------------------------ |
| **ApprovalTask/ApprovalRequest 数据结构** | 完全复用 | 数据结构完全复用                                 |
| **ApprovalTask Controller**               | 完全复用       | 当前 ApprovalTask Controller 逻辑 和 CustomRun 耦合， 需要改造 ⚠️ |
| **ApprovalRequest Controller**            | 完全复用 | 实现避免和 CustomRun 耦合                        |
| **Approval Admission Webhook**            | 完全复用 | 校验审批者权限的逻辑可复用                       |
| **多控制器架构支持扩展**                  | 完全复用 | 特定类型控制器模式支持审批扩展                |

#### 审批检查机制复用

ResourceCheckRule 和 ResourceCheckRequest 设计为通用的审批检查机制，并不强绑定 Connectors。 未来如有需要可扩展到其他资源类型的审批检查需求。

比如，为流水线配置 ResourceCheckRule， 执行前，先进行审批检查申请， 通过之后，再执行流水线。

### 性能

1. CSI Driver 审批检查通过后，Pod 完成挂载的时间延迟。

审批结果确认是异步的。 Kubelet 不断发起挂载重试请求，Pod 不断重试，Pod Requeue 时间变长。 需要确认 Requeue 时间变长后，对审批通过后，Pod 完成挂载时间延迟的影响。

2. Proxy/API 请求时审批检查

审批检查需要根据请求信息，计算审批请求的唯一标识， 查找 ResourceCheckRequest 资源，同时确定 Resource 的生命周期是否有效。 查找 Resource 时，需要调用 K8S API。 存在性能隐患。

缓解措施

- 从缓存中读取 ResourceCheckRequest 数据。
- 拒绝优先: 如果 ResourceCheckRequest 已经记录审批无效状态， 则直接拒绝，无需检查 Context Resource 生命周期。
- ResourceCheckRequest Controller 定期检查 ResourceCheckRequest 的 Context Resource 生命周期，授权的有效期，标记已经失效的审批请求。
- 使用 Single Flight 机制， 避免高并发请求时， 重复调用 K8S API， 查询 Context Resource 生命周期。

3. 大规模流水线场景下，长期运行导致大量 ResourceCheckRequest 资源积累，对系统性能的影响。

- 对审批失效超过某个时间的 ResourceCheckRequest 资源，定期进行清理。

### 易用性

1. 当由于审批失败，导致 CSI Driver 或者  API 请求失败时，要能够清晰地告知用户失败的原因

- 在 API Response Header 或者 Body 中，返回明确的错误信息。
- 在 CSI Driver 返回的错误信息中， 包含审批失败的原因。显示到 Pod 的挂载事件中。

2. 在流水线执行过程中， 能够观测到当前流水线 Pending 或者失败是由于审批引起的。

可在 ResourceCheckRequest 资源中， label 关联的 PipelineRun/TaskRun 信息。 在流水线 UI 中， 展示当前流水线 Pending 的审批请求信息。
结合产品详细设计再考虑。

3. 在审批请求中， 可跟踪到原始发起请求的资源信息，辅助决策。

审批请求中， 关联 Context Resource 信息，方便审批者了解当前请求的来源。

### 扩展性

1. 扩展其他的审批类型

- 通过 ResourceCheckRule 中的 checkTemplate 字段， 支持多种 Approval Duck Type 的审批类型。
- ApprovalRequest 自带机制扩展其他审批类型。

2. 在流水线中编排 ResourceCheckRequest 任务

- 未来可提供 ResourceCheckRequest Task， 作为流水线任务的一部分， 对即将使用到的 Connector 进行提前进行审批检查。
- 审批检查通过后， 后续流水线运行时，针对同 Connector 的使用， 可以自动通过审批检查。

### 风险与缓解措施

参考 性能 部分。

## 实施计划

### 阶段一: 先按照部分手工的方式跑通流程

- 按照 Connectors 权限拆分的逻辑， 配合流水线编排， 实现低权限用户发起申请， 高权限用户审批授权， 自动执行的场景。

### 阶段二：核心框架（MVP）

阶段一完成之后， 在讨论这些改动。

**目标**：实现基础的人工审批功能：

- Connector 可配置 人工审批规则
- CSI Driver 支持审批申请与复用&等待审批结果
- API & Proxy 支持审批状态校验&复用
- 流水线挂载需要审批的 Connetor 时， 支持审批申请与复用或等待审批结果

### 阶段三：UI 集成 Connector 审批体验

**目标**: 在 UI 层面集成审批功能，提升用户体验

### 阶段三：其他扩展审批类型

## TODO

- Http 方法过滤的设计
- 审批时配置授权时间 ？
- 方法命名的调整。
  - CheckRequest, CheckRule, Approval Duck Type -> Check Duck Type ?
- 描述各个 Controller的逻辑
- ResourceCheckRequest Controller 逻辑 计算审批状态，标记已经失效的审批。 支持刷新审批状态。
- 权限设计
- Check Duck Type 的设计细节
- 多 Connector 挂载审批的影响
