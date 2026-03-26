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
    matchLabels:
      connectors.cpaas.io/connectorclass: oci
    matchExpressions: {}
    names: [ "prod-harbor" ] # names 和 labels 为二选一关系，互斥验证

  # 默认授予的权限
  defaultPermission:
    roleTemplate:
      ref:
        configMap:
          name: connectors-use-connectors-proxy # ns 为 当前 connectors 组件部署的 namespace
    bindingTemplate:
      serviceAccounts:
      - names: [""]   # 匹配一个或者多个 SA Name. 空字符串表示匹配所有 SA
        namespaceSelector: # 匹配 sa 所在的 namespace
          names: [""] # names 和 labels 为二选一关系，互斥验证
          matchLabels: {}
          matchExpressions: {}

  # 通过审批检查授予的权限
  checkGrantedPermission:
    spec:
      checks:
      - name: manual-approval-check
        # which check objects can be used
        ref: 
          configMap:
            name: connectors-approvals-in-pipeline # 当前 connectors 安装的命名空间
        spec: # spec 和 ref 二选一。 增加验证。
          selector:
            labels:
              tekton.dev/pipelineRun: '{.object.pod.metadata.labels["pipelineRun"]}'
            objectRef:
              apiVersion: openshift-pipelines.org/v1alpha1
              kind: ApprovalTask
          state:
            # 默认情况下，按照 Ready Condition 状态来计算， 也可以通过 Rego 表达式，来计算判断结果。
            # 参考下文 state 计算
            rego: ""
      # role template granted after check passed
      permission:
        roleTemplate:
          ref:
            configMap:
              name: connectors-use-connectors-proxy-in-pod # ns 为 当前 connectors 安装的命名空间
status:
  matchedConnectors: # 匹配的 Connectors
    - name: prod-harbor
  conditions:
    - status: "True"
      type: ConnectorsMatched
    - status: "True"
      type: PermissionSynced
    - status: "True"
      type: Ready
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
    matchLabels: # 选择某一类的 Connector
      connectors.alauda.io/connectorclass: oci
    matchExpressions: {}
    names: [ "prod-harbor" ]
```

#### 默认权限 - 权限列表

-  通过 roleTemplate.ref 指定权限内容
-  ref 指向的 configmap 保存具体的权限内容

例如:

``` yaml
spec:
  defaultPermission:
    roleTemplate:
      ref:
        configMap:
          name: connectors-use-connectors-proxy
```

**内置默认权限模板**

``` yaml
kind: ConfigMap
metadata:
  name: connectors-use-connectors-proxy
  namespace: connectors-system
  annotations:
    cpaas.io/display-name: "Use Connectors APIs"
data:
  rules: |
    - apiGroups:
      - connectors.alauda.io
      resources:
      - connectors/proxy
      verbs:
        - "*"
```

#### 默认权限 - 授权对象

授权对象为 ServiceAccount, 赋予 Connector 的指定 subresource 的权限。

例如:
  - 授权 NS SA 能够访问当前 NS 的 connectors/proxy subresources 权限。 (NS Connector)
  - 授权 Project 下 所有NS 的 SA 能够访问当前 Project 的 connectors/proxy subresources 的 权限。 (Project Connector)
  - 授权集群 所有 NS， 均能访问当前集群级别 connector 的 connectors/proxy 权限

例如:

``` yaml
bindingTemplate:
  serviceAccounts:
  - names: [""]   # 匹配一个或者多个 SA Name. 空数组表示匹配所有 SA
    namespaceSelector:
      names: [""] # names 和 labels 互斥
      matchLabels: {}
      matchExpressions: {}
```

**NS Connector | Current NS**

``` yaml
bindingTemplate:
  serviceAccounts:
  - names: []
    namespaceSelector:
      names: ["xxx"] # 配置为当前 NS
```

**Project Connector | Project Namespaces**

``` yaml
bindingTemplate:
  serviceAccounts:
  - names: []
    namespaceSelector:
      matchLabels:
        cpaas.io/project: <name> # 配置为当前 Project 的 label
```

**Cluster Connector | All Namespaces**

``` yaml
bindingTemplate:
  serviceAccounts:
  - names: [] # 匹配所有 sa name
    namespaceSelector: {} # 匹配所有 namespaces
```

**Subjects 展开**

names 和 namespaceSelector 组合使用， 来确定最终的授权目标 SA 列表。

- names 指定 具体 SA 的名称，每个 sa 生成一个 subject. 为空数组时, 表示匹配所有 sa.
- namespaceSelector 指定命名空间的选择条件，用于筛选出符合条件的命名空间。为空对象表示匹配所有命名空间。

namespaceSelector 不为空, names 不为空，展开为目标 ns 的 sa 数组

``` yaml
- kind: ServiceAccount
  name: <sa-1>
  namespace: <ns-1>
- kind: ServiceAccount
  name: <sa-2>
  namespace: <ns-1>
- kind: ServiceAccount
  name: <sa-1>
  namespace: <ns-2>
- kind: ServiceAccount
  name: <sa-2>
  namespace: <ns-2>
```

namespaceSelector 不为空, names 为空，展开为目标 ns 的 sa group 数组
``` yaml
- kind: Group
  name: system:serviceaccounts:<ns-1>
- kind: Group
  name: system:serviceaccounts:<ns-2>
```

namespaceSelector 为空，names 不为空，展开为 所有 ns 的指定 sa 数组

``` yaml
- kind: ServiceAccount
  name: <sa-1>
  namespace: <ns-1>
- kind: ServiceAccount
  name: <sa-1>
  namespace: <ns-2>
- kind: ServiceAccount
  name: <sa-2>
  namespace: <ns-1>
- kind: ServiceAccount
  name: <sa-2>
  namespace: <ns-2>
```

namespaceSelector 为空，names 为空，展开为 所有 ns 的 sa group
``` yaml
- kind: Group
  name: system:serviceaccounts
```

**授权校验**

目标: 校验授权的目标 Subject 是否具备当前 NS Get Connector 的权限。只有具备 Get Connector 权限， 才能授予 Connectors-API 的权限。

防范超越已有的 NS & Project 隔离体系进行授权, 如:

- NS Admin 授权另外一个 NS 的 SA 访问当前 NS 的 Connector APIs
- Project Admin 授权 另外一个 Project 下的 NS 的 SA 访问当前 Project 的 Connectors APIs

例如:

``` bash
kubectl auth can-i --as=system:serviceaccount:<目标NS>:default --as-group=system:serviceaccounts:<目标NS> get connectors -n <当前NS>
```

校验时机: Controller 中，创建 Role 和 RoleBinding 时进行校验。
对展开的 Subject 列表进行校验，过滤掉没有权限的 subject, 使用事件进行提醒记录。

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

#### 审批检查匹配规则结果计算

定义审批检查的匹配规则，匹配到的审批检查任务是通过状态后，授予目标 Connector connectors/proxy 的特定 verb 权限。

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
        ref:
          configMap:
            name: connectors-approvals-in-pipeline
        spec: # ref 和 spec 二选一
          selector:
            labels:
              tekton.dev/pipelineRun: '{.pod.metadata.labels["tekton\.dev/pipelineRun"]}'
            objectRef:
              apiVersion: openshift-pipelines.org/v1alpha1
              kind: ApprovalTask
          state:
            # 默认情况下， 按照 Ready/Succeeded Condition 的状态来计算检查结果。如果指定了 rego 表达式，则使用 rego 表达式。
            rego: ""
```

**ConfigMap 模板**

``` yaml
kind: ConfigMap
metadata:
  name: connectors-approvals-in-pipeline
  annotations:
    cpaas.io/display-name: "Manual Approval in Pipeline"
  labels:
    connectors.cpaas.io/templateType: "accessPolicyCheckTemplate"
data:
  spec: |
    selector:
      labels:
        tekton.dev/pipelineRun: '{.object.metadata.labels["tekton\.dev/pipelineRun"]}'
      objectRef:
        apiVersion: openshift-pipelines.org/v1alpha1
        kind: ApprovalTask
    state:
      rego: ""
```

将来可以扩展: `approval-in-pipeline-stage`

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

默认使用目标资源的 Ready Condition 状态来表示审批结果

- True: 审批通过
- False: 审批失败或者拒绝，最终状态。
- UnKnown: 进行中

流水线 ApprovalTask 可配置 rego 表达式 返回 result= {status: "True|False|UnKnown"}

``` json
package check
result = {
  input.data.status.state
}
```

当 配置了 rego 表达式时， 则使用 rego 表达式进行计算。

#### 检查授权：授予的权限

通过 `checkGrantedPermission.spec.permission` 配置授予的权限

``` yaml
spec:
  checkGrantedPermission:
    spec:
      # permissions granted after check passed
      permission:
        ref: 
          configMap:
            name: connectors-use-connectors-proxy-in-pod
```

**模板**

``` yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: connectors-use-connectors-proxy-in-pod
  annotations:
    cpaas.io/display-name: "Use Connectors APIs in Pipeline"
data:
  ruls: | 
    - apiGroups:
      - connectors.alauda.io
      resources:
      - connectors/proxy/v1/pod/{.object.metadata.namespace}/{.object.metadata.name}
      verbs:
        - "*"
```

#### Status

**status.conditions**

- ConnectorsMatched: 表示 Connectors 的匹配状态, 匹配结果记录在 `status.matchedConnectors` 中
  - True: 表示正常完成匹配
  - False: 表示匹配失败，存在错误
  - UnKnown: 表示匹配状态未知，正在匹配中.
- PermissionSync: 
  - True: 表示权限同步成功
  - False: 表示权限同步失败，存在错误
  - UnKnown: 表示权限同步状态未知，正在同步中.
- Ready: Top Level Condition.

**status.matchedConnectors**

记录匹配的 Connectors，包含匹配成功的 Connector 名称。

yaml 示例:

``` yaml
kind: AccessPolicy
metadata:
  name: default
spec: {}
status:
  matchedConnectors: 
    - name: prod-harbor
    - name: prod-gitlab
  conditions:
    - type: Ready
      status: "True"
      reason: ""
      message: ""
```

#### 创建 Connector 时默认的 AccessPolicy

``` yaml
kind: AccessPolicy
metadata:
  namespace: <connector-namespace>
  generateName: <connector-name>-
spec:
  connector:
    names: [ "<connector-name>" ]
  defaultPermission:
    roleTemplate:
      ref:
        configMap:
          name: connectors-use-connectors-proxy
    bindingTemplate:
      serviceAccounts:
      # NS Connector 授权当前 NS 下的所有 SA
      - names: []
        namespaceSelector:
          names: ["<connector-namespace>"]
          
      # Project Connector 授权当前 Project 下的 NS 的所有 SA
      - names: []
        namespaceSelector:
          matchLabels:
            cpaas.io/project: "<project-name>"
            
      # Cluster Connector 授权集群所有 SA
      - names: []
        namespaceSelector: {}
```

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
  - name: connector-access-policy # access policy name
    policySpec: {} # 记录当时匹配到的 AccessPolicy 的完整 spec
    matchedChecks:
    - name: manual-approval-check
      ref:
        apiVersion: openshift-pipelines.org/v1alpha1
        kind: ApprovalTask
        name: manual-approval-check-001
        namespace: "" # Context Object 所在的 NS
      condition:
        status: "True | False | Unknown" # 记录当前 Check 的 结果
        message: ""
    permissionSynced:
      status: "True | False"
      reason: Synced | SyncFailed | Pending
      message: ""
```

**Status Conditions**

- `Type`: Ready
  - Status: "True" | "False" | "Unknown"
  - Reason: 由计算出该结果的子 Condition 透传而来（例如 Pending, Failed, Matched, NotFound, SyncFailed, Revoked 等）。
  - 顶层 Condition，由 `knative/pkg/apis` 的 `LivingConditionSet` 自动计算得出。只有当所有必要的子 Condition 都为 True 时，Ready 才为 True。若有子 Condition 不为 True，Ready 将自动继承该子 Condition 的 Reason 和 Message。CSI Driver 只需要判断 `Ready == True` 即可。
- `Type`: ContextObjectValid:
  - Status: 
    - `True`： 上下文对象有效。
    - `False`: 上下文对象已无效。例如 Pod Completed。
    - `UnKnown`: 上下文对象状态未知，处于计算中。
  - Reason: 
    - `UnCompleted`: Pod 未完成， 上下文有效
    - `Completed`: Pod 已完成。
    - `NotFound`: Pod 未找到。
- `Type`: AccessPolicyMatched:
  - Status: "True" | "False"
  - Reason: Matched | NoMatched

- `Type`: AccessCheckReady:
  - Status: "True" | "False" | "Unknown"
  - Reason: Passed | Rejected | Pending | Failed
  - Pending 状态下，status 应为 Unknown（等待审批），而不应是 False。只有明确被拒绝或检查出错时才为 False。
  - 建议包含 `message` 以提升可观测性（如 "Waiting for ApprovalTask manual-approval-check to be approved"）。

- `Type`: ConnectorResolved:
  - Status: "True" | "False"
  - Reason: Resolved | NotFound
  - Resolved: 根据 `AccessRequest.spec.connectorRef` 成功在当前 Namespace 找到了对应的 Connector 资源。
  - NotFound: Connector 不存在或已被删除。如果 Connector 被删除，这会导致 Ready 变为 False，进而触发后续可能的权限撤销。

- `Type`: PermissionSynced
  - Status:
    - True: 权限已同步完成
    - False: 同步执行失败
    - Unknown: 同步中
  - Reason: 
    - Synced: 授予权限已成功同步。
    - SyncFailed: 同步执行失败。
    - NoPermissionRequired: 不需要同步权限，同步的内容为空
    - Pending: 同步尚未完成。
    - PermissionCleanUp: 已同步的权限被清理。
- `Type`: Ready
  - Status: "True" | "False" | "Unknown"
  - Reason: 
    - `Pending`: 同步尚未完成，Ready 状态为 Unknown。

关键状态判断：

- Pending （approval）:
  - AccessCheckReady.status == "Unknown" 
- Rejected:
  - AccessCheckReady.status == "False" && AccessCheckReady.reason == "Rejected"
- Passed 且授权完成：
  - PermissionSynced.status == "True" && PermissionSynced.reason == "Synced"
- 其他:
  - 根据 Ready.status 和 Ready.reason， Hover 显示 message 

示例：

``` yaml
kind: AccessRequest
status:
  conditions:
  - type: Ready 
    status: "True | False | Unknown"
    reason: Pending  # 示例：继承自未就绪的 AccessCheckReady 子条件
  - type: ContextObjectValid
    status: "True" | "False"
    reason: Active | Completed | NotFound
  - type: ConnectorResolved
    status: "True" | "False"
    reason: Resolved | NotFound
  - type: AccessPolicyMatched
    reason: Matched | NoMatch
  - type: AccessCheckReady
    status: "True" | "False" | "Unknown"
    reason: Passed | Rejected | Pending | Failed
    message: "Waiting for ApprovalTask manual-approval-check to be approved"
  - type: PermissionSynced
    status: "True" | "False"
    reason: Synced | SyncFailed | Revoked
```

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
  - connectors/proxy/v1/pod/devops-ns1/deploy-prod-xxx # 关联 context Object 进行授权范围的限制
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
- 判断是否具备 connectors/proxy subresources 的 "*" 权限
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
    resource: connectors/proxy/v1/pod/devops-ns1/deploy-prod-xxx # 关联 context Object 进行授权范围的限制, ns 为 pod 的 ns
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

- resources: `connectors/proxy/{context-object-apiVersion}/{context-object-kind}/{context-object-namespace}/{context-object-name}`

**现在**

直接获取当前 Pod 信息，作为 Context Object，进行权限校验。

- resources: `connectors/proxy/v1/pod/{.object.pod.metadata.namespace}/{.object.pod.metadata.name}`

### Check Duck Type

`Check Duck Type` 代表代表审批检查的资源类型， 例如 ApprovalTask 和 ApprovalRequest。

默认使用 Ready Condition 来判断资源是否就绪， 也可以通过 Rego 来动态配置状态的计算方式。 参考上文 Check State 的计算。

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
