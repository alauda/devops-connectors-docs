# Connectors Approval 技术设计方案

## 基本思路

- 通过 `AccessPolicy`, 定义 Connector 的访问策略，包含默认开放的权限， 以及需要满足的审批检查，才能授予的权限。
- 通过 `AccessRequest`, 定义对某个 Connector的访问申请，通过该资源，匹配集群中已经存在的审批检查资源，以及检查通过之后进行授权.
- `CSI Driver` 在挂载 Connector 时，自动创建 `AccessRequest`，自动复用集群中已有的审批检查资源(例如 ApprovalTask)，等待审批检查通过，完成授权后，允许挂载。

## 设计详情

### AccessPolicy

- apiVersion: connectors.alauda.io/v1alpha1
- kind: AccessPolicy
- scope: Namespace

示例：

``` yaml
kind: AccessPolicy
spec:
  # 匹配的目标 Connector
  connector:
    selector:
      matchLabels:
        connectors.cpaas.io/connectorclass: oci
    names: [ "prod-harbor" ]

  # 默认授予的权限
  defaultPermission:
    roleTemplate:
      rules:
      - apiGroups:
        - connectors.alauda.io
        resources:
        - connectors/apis
        verbs:
          - read
    bindingTemplate:
      subjects:
      - kind: ServiceAccount
        name: system:serviceaccount:devops-ns1:default
        nameSelector: {}
        namespaceSelector: {}

  # 通过审批检查授予的权限
  checkGrantedPermission:
    spec:
      checks:
      - name: manual-approval-check
        # which check objects can be used
        selector:
          labels:
            tekton.dev/pipelineRun: '{.object.pod.metadata.labels["pipelineRun"]}'
          objectRef:
            apiVersion: openshift-pipelines.org/v1alpha1
            kind: ApprovalTask
        state:
          # 默认情况下， 按照 Check Duck Type 的 state 字段进行判断， 也可以通过 Rego 表达式，来计算判断结果。
          # 通过 rego 来计算 check 的结果， state: pending | approved | rejected | passed
          rego: ""
      # permissions granted after check passed
      permissions:
        roleTemplate:
          rules:
          - apiGroups:
            - connectors.alauda.io
            resources:
            - connectors/apis/tekton.dev/v1/pipelineruns/{.object.pod.metadata.namespace}/{.object.pod.name} # 仅支持 授权到 pod ns 和 pod name
            verbs:
              - "*"
```

#### 目标 Connector

通过 `spec.connector` 指定当前访问策略，适用于哪些 Connector

- 为整个 NS 定义统一的访问策略
- 为某一类的 Connector 定义访问策略
- 为指定的 Connector 定义访问策略

配置示例：

``` yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: AccessPolicy
metadata:
  name: connector-access-policy-001
  namespace: devops-ns1 # 目标 Connector 的 NS
spec:
  connector: # 为空表示当前 NS 所有 connector
    selector:
      matchLabels: # 选择某一类的 Connector
        connectors.alauda.io/connectorclass: oci
    names: [ "prod-harbor" ]
```

#### 默认权限

目标 Connector 默认开放的权限，为指定的 Subject (ServiceAccount, User, Group), 赋予 Connector 的特定 subresource 的特定 verb 权限。

例如:
  - 授权 NS SA 能够访问当前 NS 的 connectors/apis subresources 的 read 权限。 (NS Connector)
  - 授权 Project 下 NS SA 能够访问当前 NS 的 connectors/apis subresources 的 read 权限。 (Project Connector)

对应的 AccessPolicy 配置：

``` yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: AccessPolicy
metadata:
  name: connector-access-policy-001
  namespace: devops-ns1
spec:
  connector: {}

  # 默认授予的权限
  defaultPermission:
    roleTemplate:
      rules:
      - apiGroups:
        - connectors.alauda.io
        resources:
        - connectors/apis
        verbs:
          - read
    bindingTemplate:
      subjects:
      - kind: ServiceAccount
        name: system:serviceaccount:devops-ns1:default
        nameSelector: {}
        namespaceSelector: {}
```

**对 Subject/Group 的支持**

``` yaml
     # 当前 NS 的所有 SA
    bindingTemplate:
      subjects:
      - kind: Group
        name: "system:serviceaccounts:devops-ns1"
---
    # 当前项目下的 NS 的 所有 SA
    bindingTemplate:
      subjects:
      - kind: Group
        name: "system:serviceaccounts"
        namespaceSelector:
          matchLabels:
            cpaas.io/project: devops
```

**对 Subject/ServiceAccount 的支持**

``` yaml
    # 当前 NS 的 指定 SA
    bindingTemplate:
      subjects:
      - kind: ServiceAccount
        nameSelector:
          matchLabels:
            tekton.dev/pipeline: deploy-prod
```

##### 对 User 的支持

需要确保系统给与用户的角色，能够使用基本的 API， 完成页面操作。

**当前现状**

- Connectors-Operator 默认安装后， 会授予平台角色对 Connectors API 的 Read 权限。

**预期状态**

- 默认授予用户的权限是可开启或关闭的
- 默认授予的用户权限粒度是最小的， 最安全的。 可能需要不同的 ConnectorClass 来定义和控制。

**思路**

- 不同的 ConnectorClass 可控制，开放给平台角色一些基础的 API（默认认为安全）.
- 如果用户想要自己控制授予用户的权限，那么可以关闭该开关。用户自主配置。
- 如果用户想要更精细的控制到用户的权限，可以通过手动创建 Role 和 RoleBinding 来解决。

#### 审批检查匹配规则

定义审批检查的匹配规则，匹配到的审批检查任务是通过状态后，授予目标 Connector connectors/apis 的特定 verb 权限。

``` yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: AccessPolicy
metadata:
  name: connector-access-policy-001
  namespace: devops-ns1
spec:
  connector: {}
  defaultPermission: {}

  # 通过检查规则授予的权限
  checkGrantedPermission:
    spec:
      checks:
      - name: manual-approval-check
        # which check objects can be used
        selector:
          labels:
            tekton.dev/pipelineRun: '{.pod.metadata.labels["tekton\.dev/pipelineRun"]}'
          objectRef:
            apiVersion: openshift-pipelines.org/v1alpha1
            kind: ApprovalTask
        state:
          # 默认情况下， 按照 Check Duck Type 的 state 字段进行判断， 也可以通过 Rego 表达式，来计算判断结果。
          # 通过 rego 来计算 check 的结果， state: pending | approved | rejected | passed
          rego: |
            package approval

            output = {
              "state": state
            } {
              state := input.status.state
            } else = {
              "state": "pending"
            }
      # permissions granted after check passed
      permissions:
        roleTemplate:
          rules:
          - apiGroups:
            - connectors.alauda.io
            resources:
            - connectors/apis/tekton.dev/v1/pipelineruns/{.object.pod.metadata.namespace}/{.object.pod.metadata.name} # 仅支持授权到 pod ns 和 pod name
            verbs:
              - "*"
```

**匹配流水线中的 ApprovalTask**

``` yaml
# which check objects can be used
selector:
  labels:
    tekton.dev/pipelineRun: '{.object.metadata.labels["tekton\.dev/pipelineRun"]}'
  objectRef:
    apiVersion: openshift-pipelines.org/v1alpha1
    kind: ApprovalTask
```

**匹配流水线中某个 Stage 的 ApprovalTask**

``` yaml
# which check objects can be used
selector:
  labels:
    tekton.dev/pipelineRun: '{.object.metadata.labels["tekton\.dev/pipelineRun"]}'
    tekton.dev/stageName: '{.object.metadata.labels["tekton\.dev/stageName"]}'
  objectRef:
    apiVersion: openshift-pipelines.org/v1alpha1
    kind: ApprovalTask
```

**表达式**

支持范围:

- checks[].selector 中的 value
- permissions 中的 resources

格式和渲染数据:

- jsonpath
- 输入的数据为 `{ "object": <accessRequest.spec.context.objectRef 对应的资源内容> }`

示例：

``` yaml
selector:
  labels:
    tekton.dev/pipelineRun: '{.object.metadata.labels["tekton\.dev/pipelineRun"]}'
```

**Check Duck Type State 计算**

- 默认情况下，使用 `Check Duck Type ` 定义的标准数据结构， 来获取 state 字段的值， 来获取审批检查的结果。
- 用户也可以自定义  Rego 表达式， 来计算审批检查的结果。 例如， 通过检查 ApprovalTask 甚至一个 ConfigMap（用于模拟一个审批资源）， 来获取审批检查的结果。

#### Controller 处理流程

- 根据 default permission 定义的规则， 以及 Selector 选择的 Connector，自动生成 Role 和 RoleBinding。
  - 根据 RoleTemplate 定义的规则， 以及 Selector 选择的 Connector，自动生成 Role.
  - 根据 BindingTemplate 定义的规则， 自动生成 RoleBinding.
- AccessPolicy Controller 对生成的 Role 和 RoleBinding 进行维护， 生成资源配置 OwnerReference， label 关联 AccessPolicy， 方便清理
- AccessPolicy Watch
  - AccessPolicy 变更，重新 Reconcile AccessPolicy， 更新授权。
  - Watch Connector 删除动作，重新 Reconcile AccessPolicy， 更新授权。(移除已删除的 Connector 的授权)
  - Watch Namespace 增加和删除， 重新 Reconcile AccessPolicy， 更新授权。（移除或增加通过 namespaceSelector 匹配的 ns 配置）
  - Watch Role 和 RoleBinding, 更新后，重新刷新。

### AccessRequest

`AccessRequest` 代表指定 Subject 对某个 Connector 的访问申请。 用来管理跟踪审批检查的执行，以及检查通过后的授权和撤销。

执行时，根据匹配的 `AccessPolicy` 定义的 checks 匹配规则，匹配集群中已经存在的审批检查资源(例如 ApprovalTask)。

记录审批检查结果，通过则进行授权。授权的内容根据 AccessPolicy 中 checkGrantedPermission 定义的规则进行授权。
如果没有匹配的审批检查资源，则认为检查未通过。

#### 数据结构

**Spec**

``` yaml
kind: AccessRequest
apiVersion: connectors.alauda.io/v1alpha1
metadata:
  name: connector-check-request-001
  namespace: devops-ns1 # 访问的目标 Connector 的 NS
spec:
  subject:
    apiGroup: rbac.authorization.k8s.io
    kind: ServiceAccount
    namespace: "" # 以哪个 NS 的 SA 进行访问， 可能与 Connector 所在 NS 不同。
    name: "pipeline-sa"
  connectorRef:
    name: prod-harbor # 访问的目标 Connector, NS 和 当前资源 NS 一致。
  context: # 审批申请的上下文信息, 目前仅支持 Pod。MutationWebhook 验证限制。
    objectRef:
      apiVersion: v1
      kind: Pod
      name: deploy-prod-xxx
      namespace: devops-ns1
```

**Status**

记录如下信息:

- 匹配到的 `AccessPolicy`: 记录当时匹配到的完整信息
- 匹配的 `Check Duck Type` 资源: 记录检查结果信息

示例：

``` yaml
kind: AccessRequest
apiVersion: connectors.alauda.io/v1alpha1
metadata:
  name: connector-check-request-001
  namespace: devops-ns1
spec: {}
status:
  policies:
  - policy:
      kind: AccessPolicy
      metadata:
        name: connector-access-policy-001
        namespace: "devops-ns1"
      spec: {} # 记录当时匹配到的 AccessPolicy 的完整信息
    checkRefs:
    - name: manual-approval-check
      ref:
        apiVersion: openshift-pipelines.org/v1alpha1
        kind: ApprovalTask
        name: manual-approval-check-001
        namespace: "" # Context Object 所在的 NS
      status:
        state: pending | approved | rejected
```

**Status Conditions**

- `Type`: ContextObjectValid:
  - Reason: UnCompleted | Completed | NotFound
  - Pod 处于非结束状态时，status 为 True
- `Type`: AccessPolicyMatched:
  - Reason: NoAccessPolicyMatched | AccessPolicyMatched
- `Type`: AccessCheckReady:
  - Reason: AccessCheckFailed | AccessCheckPassed | AccessCheckPending | AccessCheckRejected
- `Type`: AccessPermissionSync
  - Reason: AccessPermissionSyncFailed | AccessPermissionGranted | AccessPermissionRevoked

示例：

``` yaml
kind: AccessRequest
status:
  conditions:
  - type: ContextObjectValid
    status: "True" | "False"
    reason: UnCompleted | Completed | NotFound
  - type: AccessCheckReady
    status: "True" | "False"
    reason: AccessCheckFailed | AccessCheckPassed | AccessCheckPending | AccessCheckRejected
  - type: AccessPermissionSync
    status: "True" | "False"
    reason: AccessPermissionSyncFailed | AccessPermissionGranted | AccessPermissionRevoked
```

#### Controller

主要 **处理流程**:

- 计算 Context Object 的有效性
- 根据 Connector，匹配 AccessPolicy
- 根据 AccessPolicy 定义的 checks, 匹配 `Check Duck Type` 资源，等待审批结果。
- 审批通过后，根据 AccessPolicy 定义的 `checkGrantedPermission` 进行授权。
- 授权无效时，撤回授权。
- 汇总结果， 记录到 Status conditions 上。

#### 匹配 AccessPolicy

**处理流程**

- 遍历 Connectors NS 的 AccessPolicy，匹配 AccessPolicy 中 selector 选择的 Connector 是否包含当前 AccessRequest 的 connectorRef。
- 如果匹配成功，则进入下一步匹配 `Check Duck Type`

#### 匹配 `Check Duck Type` 资源

复用用户通过流水线编排的 ApprovalTask 或 ApprovalRequest.

**处理流程**

- 遍历配的 `AccessPolicy`
- 遍历 `AccessPolicy` 中的 checks
- 根据 check 的 selector 配置， 在集群中，查找 含有指定 label 的 GVK 资源。
- 根据 state 计算方式，获取 check 结果， 记录到 status 中。
- 所有 check 都通过，则认为审批检查通过。
- 进入授权流程。

#### 执行授权创建 Role & RoleBinding

**处理流程**

确认 `Check Duck Type CR` 已经检查通过，创建 Role & RoleBinding 进行授权。授权的内容根据 AccessPolicy 中 checkGrantedPermission 定义的规则进行授权。

- NS 为当前 Connector 的 NS
- Role 资源中,  根据 AccessPolicy 中配置的 rules, 渲染变量后，生成 Role 资源。
- 增加 OwnerReference 关联 AccessRequest
- 增加 Label 关联 AccessRequest, 方便查询。


示例：

``` yaml
kind: Role
metadata:
  name: connector-prod-harbor-apis-reader
  namespace: devops-ns1 # 与 Connector 所在 NS 一致
  labels:
    connectors.alauda.io/accessRequest: connector-check-request-001
  ownerReferences:
  - kind: AccessRequest
rules:
- apiGroups:
  - connectors.alauda.io
  resources:
  - connectors/apis/v1/pod/devops-ns1/deploy-prod-xxx # 关联 context Object 进行授权范围的限制
  resourceNames: [ "prod-harbor" ] # 关联当前 Connector 的 Name
  verbs:
  - "*"
---
kind: RoleBinding
metadata:
  name: connector-prod-harbor-apis-reader
  namespace: devops-ns1 # 与 Connector 所在 NS 一致
  labels:
    connectors.alauda.io/accessRequest: connector-check-request-001
  ownerReferences:
  - kind: AccessRequest
subjects:
- kind: ServiceAccount # 从当前的 AccessRequest 的 spec.subject 中获取
  name: pipeline-sa
  namespace: devops-ns1
roleRef: # 创建的 Role
  kind: Role
  name: connector-prod-harbor-apis-reader
  apiGroup: rbac.authorization.k8s.io
```

#### 授权无效后撤销授权

授权撤销: 删除当前 AccessRequest 关联的 Role 和 RoleBinding，撤销授权。

授权被撤销后，AccessRequest 进入最终状态。 不再进行 reconcile。

- context.objectRef 不存在，或者已经在生命周期外，授权撤销。
- `AccessRequest` 被删除，授权撤销。
- 已完成的 `Check Duck Type CR` 被删除不影响授权。(已经记录在 status 上)

**Context Object Running 状态判断**

目前发起的 AccessRequest 中的 context.objectRef 仅支持 Pod，所以状态判断，直接使用 Pod 的状态进行判断。

### CSI Driver

根据挂载的 Connector，判断当前 pod 的 SA 是否有权限， 如无，则创建 `AccessRequest`, 等待审批通过，有权限后，允许挂载。

**处理流程**

- 遍历挂载的目标 Connector
- 判断是否具备 connectors/apis subresources 的 "*" 权限
- 如果满足权限, 则正常挂载
- 如果不满足权限要求，则匹配或创建 AccessRequest。
- 已有 AccessRequest
  - 权限满足，则放行，正常挂载。
  - 权限不满足，
    - AccessRequest 未完成 PermissionSync，拒绝挂载，CSI Driver 重试。
    - AccessRequest 已经完成 PermissionSync，挂载失败。CSI Driver 不再重试。

**权限判断**

``` yaml
kind: SubjectAccessReview
apiVersion: authorization.k8s.io/v1
spec:
  resourceAttributes:
    namespace: devops-ns1 # 访问的目标connector
    verb: "*"
    group: connectors.alauda.io
    resource: connectors/apis/v1/pod/devops-ns1/deploy-prod-xxx # 关联 context Object 进行授权范围的限制, ns 为 pod 的 ns
    name: prod-harbor # 关联当前 Connector 的 Name
  user: system:serviceaccount:devops-ns1:pipeline-sa # 当前 pod 的 sa
```

多 connector 时，进行多次判断， 所有 connector 权限都满足后，才允许挂载。

备注：

- 在因为权限检查不通过时，在 k8s events 中说明是哪个 connector 的何种权限校验未通过。

**匹配或创建 AccessRequest**

为每个挂载的 Connector，生成一个 `AccessRequest`. 匹配时， 需要匹配 Subject, Connector 和 context Object (Pod) 都一致的 `AccessRequest`。

``` yaml
kind: AccessRequest
metadata:
  name: connector-check-request-001
  namespace: devops-ns1 # 与 Connector 所在 NS 一致
  labels: # 增加 label 关联当前 Context Object, 方便根据 Pod 查询 AccessRequest
    connectors.cpaas.io/contextObjectKind: Pod
    connectors.cpaas.io/contextObjectName: deploy-prod-xxx
    connectors.cpaas.io/contextObjectNamespace: devops-ns1
    connectors.cpaas.io/connector: prod-harbor
spec:
  subject: # 当前 Pod 的 SA
    apiGroup: rbac.authorization.k8s.io
    kind: ServiceAccount
    namespace: devops-ns1
    name: pipeline-sa
  connectorRef: # 挂载的 Connector
    name: prod-harbor
  context:
    objectRef: # 当前 Pod
      apiVersion: v1
      kind: Pod
      name: deploy-prod-xxx
      namespace: devops-ns1 # Pod 所处 NS
```

### API 权限校验

校验目标发生变化

**之前**:

context object 是从 当前 Pod 向上查找 Owner 来动态获取

- resources: `connectors/apis/{context-object-apiVersion}/{context-object-kind}/{context-object-namespace}/{context-object-name}`

**现在**

直接获取当前 Pod 信息，作为 Context Object，进行权限校验。

- resources: `connectors/apis/v1/pod/{.object.pod.metadata.namespace}/{.object.pod.metadata.name}`

### Check Duck Type

`Check Duck Type` 代表满足审批检查的资源类型， 例如 ApprovalTask 和 ApprovalRequest。

#### 满足的数据结构如下

``` yaml
status:
  state: rejected | approved | pending | passed | ""
```

**state**

- rejected: 拒绝，进入检查最终状态，不再进行审批检查。
- approved|passed: 通过，进入最终状态，不再进行审批检查。
- pending: 进入审批流程，等待审批结果。
- 允许为空: 等同于 pending

## 扩展性

### 扩展支持匹配其他 Check Duck Type 资源

- 在 selector 中，通过 objectRef 来指定匹配新的资源类型
- 可在 selector 中扩展 `fieldSelector` , 支持更细粒度的匹配，例如， 匹配 ApprovalRequest 中 spec.type 为 TimeWindow 的资源。
- 结果计算和类型无耦合，新的 Check Duck Type 资源类型，不影响 state 的计算。
- AccessRequest Controller 注册新的 GVK， 实现对新资源类型的 Watch, 及时感知资源的变化

示例：

``` yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: AccessPolicy
metadata:
  name: connector-access-policy-001
  namespace: devops-ns1
spec:
  connector: {}
  defaultPermission: {}

  # 通过检查规则授予的权限
  checkGrantedPermission:
    spec:
      checks:
      - name: manual-approval-check
        # which check objects can be used
        selector:
          labels:
            tekton.dev/pipelineRun: '{.object.metadata.labels["tekton\.dev/pipelineRun"]}'
          objectRef:
            apiVersion: openshift-pipelines.org/v1alpha1
            kind: ApprovalTask
        state: {}
      - name: business-hour-check
        selector:
          labels:
            tekton.dev/pipelineRun: '{.object.metadata.labels["tekton\.dev/pipelineRun"]}'
          objectRef:
            apiVersion: openshift-pipelines.org/v1alpha1
            kind: ApprovalRequest
          fieldSelector: # 将来扩展
            spec.type: "TimeWindow"
        state: {}
      # permissions granted after check passed
      permissions: {}
```

### 权限

**AccessPolicy**

- 和 Connector 权限保持一致， 能创建/更新/查看/删除 Connector 的用户， 也能创建/更新/查看/删除 AccessPolicy 来定义访问策略。

**AccessRequest**

- NS 开发人员拥有 当前 NS, 项目 NS， 集群 kube-public, 查看/创建/更新 AccessRequest 的权限。
- NS 管理员拥有
  - 当前 NS 查看/创建/更新/删除 AccessRequest 的权限。
  - 项目 NS 集群 kube-public, 查看/创建/更新 AccessRequest 的权限。
- Project 管理员拥有
  - 项目 NS，项目下 NS, 查看/创建/更新/删除 AccessRequest 的权限。
  - 集群 kube-public 查看/创建/更新 AccessRequest 的权限。


## 功能开关

- enable-connectors-approval: 整体开关，控制是否启用 Connectors Approval 功能。默认关闭

## 安全考虑

**防伪造审批结果**

- 申请人， 无法使用对流水线 A 的审批结果，来伪造为对流水线 B 的审批结果。

**权限提升**

普通用户没有权限修改 policy，可规避 "通过修改AccessPolicy"以达到使得自己的 AccessRequest 满足授权条件，获得权限的目的。

**授权可审计**

- AccessRequest Controller 创建/撤销 Role & Rolebinding, k8s apiserver 有审计可查。
- AccessPolicy Controller 创建 Role & Rolebinding 时， 记录 k8s events. 说明当前授权信息。
- AccessPolicy Controller 撤销授权时，记录 k8s events. 说明当前授权撤销信息。

## 代码实现与变更

### AccessPolicy Admission Webhook

**默认值逻辑**

**校验逻辑**

- defaultPermission 和 checkGrantedPermission 不能同时为空，至少需要配置一项权限。
- defaultPermission 中的 roleTemplate.rules 和 bindingTemplate.subjects 不能为空。
- checkGrantedPermission 中必须至少配置一个 check, 且 check 中的 selector.objectRef 不能为空。
- checkGrantedPermission 中 permissions.roleTemplate.rules 不能为空。

### AccessRequest Admission Webhook

**默认值逻辑**

- connectorRef 的 namespace 默认为当前 AccessRequest 的 namespace。

**校验逻辑**

- connectorRef.namespace 必须与 AccessRequest 的 namespace 一致。
- connectorRef.name 不能为空。
- context.objectRef 不能为空， name, namespace 不能为空， 仅支持 Pod.
- contxt.objectRef.kind 目前仅支持 Pod。
- subject 不能为空

### AccessPolicy Controller

参考 AccessPolicy 的 Controller 处理流程

### AccessRequest Controller

参考 AccessRequest 上文中， 提到的 **处理流程**

### CSI Driver

参考 CSI Driver 处理流程

### API 权限校验的调整

- ConnectorsReviewer 中，校验逻辑修改为，直接获取当前 Pod 信息，作为 Context Object，进行权限校验。


## 其他问题

**创建 Check Duck Type CR 之后, 如何 Reconcile CR 的状态变化**

Controller 中 Watch Unstructed 类型, 配置 GVK 来 Watch 目标 CR 的状态变化, 从而触发 Reconcile.

``` go
u := &unstructured.Unstructured{}
u.SetGroupVersionKind(schema.GroupVersionKind{
    Group:   "openshift-pipelines.org",
    Version: "v1",
    Kind:    "ApprovalTask",
})

controller.Watch(source.Kind(cache, u), &handler.EnqueueRequestForObject{})
```

系统预置已知的 Check Duck Type CR 的 GVK 列表。

**对于时间窗口类型的任务，如何快速感知时间窗口到期, 进行授权的撤销**

- 时间窗口类型的任务，需要自己能够根据时间窗口，对自身的状态进行切换。时间窗口到期后，状态切换为过期。
- 使用上述机制， watch 对应的 Check Duck Type CR， 触发 AccessRequest 的 Reconcile, 进行授权的撤销。

**Context Object 生命周期结束，如何快速感知，进行授权的撤销**

- Watch Pod, 触发关联的 AccessRequest 的 Reconcile （AccessRequest 上增加label）
- 根据 Pod 的 状态和是否存在，进行授权的撤销。
