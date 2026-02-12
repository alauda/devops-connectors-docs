# Connectors 权限拆分

## 目标

拆分 Connectors 的权限， 配合流水线，以手动赋权的方式能够完成 用户申请，审批， 使用 Connectors 部署到生产环境的流水线。手动赋权能够确保最小粒度的权限控制

- 拆分 Connectors 的权限
- 手动赋予 SA 最小粒度的权限

## 拆分 Connectors 的权限

| Resource        | Action                             | Description                         |
| --------------- | ---------------------------------- | ----------------------------------- |
| connectors      | Get/List/Watch/Patch/Update/Delete | Connector 的权限                    |
| connectors/apis | Get/Update/Delete                  | 操作 Connector 指向的工具资源的权限 |

## Role & RoleBinding

### 使用 ResourceNames 方式绑定权限

**Role**

- Resource: `connectors/apis/{context-resource-name}`
- resourceNames: `{connector-name}`
- verbs: `{verb}`
- context-resource-name: 资源的上下文名称， `{api-version}/{resources}/{resource-name}` 例如： tekton.dev/v1/namespaces/default/pipelineruns/pr-demo-01

**RoleBinding**

约束 ServiceAccount 仅能在如下上下文中访问资源

- 特定 Namespace 的 特定 PipelineRun
- 特定 Namespace 的 特定 Connector
- 特定 Verb

**示例**


``` bash

export NS=default
export PR_NAME=pr-demo-01

# 创建 指定 Connector 和 PipelineRun 的 Role

cat << EOF | kubectl apply -n $NS -f -
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-apis-reader-for-$PR_NAME
rules:
- apiGroups: [ "connectors.alauda.io" ]
  resources: [ "connectors/apis/tekton.dev/v1/pipelineruns/$PR_NAME" ]
  resourceNames: [ "prod-harbor" ]
  verbs: [ "get" ]
EOF

# 创建 RoleBinding 绑定到指定的 ServiceAccount

cat << EOF | kubectl apply -n $NS -f -
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: bind-connectors-apis-reader-for-$PR_NAME
subjects:
- kind: ServiceAccount
  name: pipeline-sa
  namespace: $NS
roleRef:
  kind: Role
  name: connectors-apis-reader-for-$PR_NAME
  apiGroup: rbac.authorization.k8s.io
EOF

# 允许
kubectl auth can-i update connectors/prod-harbor --subresource apis/tekton.dev/v1/pipelineruns/$PR_NAME --as=system:serviceaccount:$NS:pipeline-sa

# 拒绝
kubectl auth can-i update connectors/prod-harbor --subresource apis/tekton.dev/v1/pipelineruns/$PR_NAME-changed --as=system:serviceaccount:$NS:pipeline-sa

```

### 使用 Non-ResourceURLs 方式绑定权限

Non-ResourceURLs  必须使用 ClusterRole 和 ClusterRoleBinding 进行绑定

**ClusterRole**

- nonResourceURLs: `/connectors/apis/{connector-ns-name}/context/{context-resource-name}/path/{api-path}`
- verbs: `{verb}`

**ClusterRoleBinding**

约束 ServiceAccount 仅能在如下上下文中访问资源

- 特定 Namespace 的 特定 Connector
- 特定 Namespace 的 特定 PipelineRun
- 特定 Verb
- 特定 Path 的 请求

**示例**

``` bash
export NS=default-2
export PR_NAME=pr-demo-02
export CONNECTOR_NAME=prod-harbor

kubectl create ns $NS
kubectl create sa pipeline-sa -n $NS

cat << EOF | kubectl apply -n $NS -f -
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-apis-non-resourceurls-writer-for-$PR_NAME
rules:
  - nonResourceURLs: ["/connectors/apis/${NS}/${CONNECTOR_NAME}/context/tekton.dev/v1/pipelineruns/$PR_NAME/path/projects/*"]
    verbs: ["update"]
EOF

cat << EOF | kubectl apply -n $NS -f -
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: bind-connectors-apis-writer-for-$PR_NAME
subjects:
- kind: ServiceAccount
  name: pipeline-sa
  namespace: $NS
roleRef:
  kind: ClusterRole
  name: connectors-apis-non-resourceurls-writer-for-$PR_NAME
  apiGroup: rbac.authorization.k8s.io
EOF

# 允许
kubectl auth can-i update /connectors/apis/${NS}/${CONNECTOR_NAME}/context/tekton.dev/v1/pipelineruns/$PR_NAME/path/projects/abc --as=system:serviceaccount:$NS:pipeline-sa

# 拒绝
kubectl auth can-i update /connectors/apis/${NS}/${CONNECTOR_NAME}/context/tekton.dev/v1/pipelineruns/$PR_NAME/path/repository/abc --as=system:serviceaccount:$NS:pipeline-sa
```

### 讨论

ClusterRole & ClusterRoleBinding 方式虽然比较灵活和强大， 但在资源管理上存在一些局限:

- NS 内的审批授权人员需要 创建或者管理 Cluster 级别的资源，这是不太合理的。
- NS 维度的资源管理不方便。

使用 ResourceNames 方式绑定权限，无法做到 Path 级别的权限控制， 但按照 Path 级别的控制用户决策更为复杂，想要精细的控制某次审批允许的 API 范围，并不是容易的事情. 适用的场景尚不明确。

综合考虑， 使用 ResourceNames 方式绑定权限， 作为默认的权限绑定方式。 满足大部分的使用场景。

## 设计

### 功能开关

- ``enable-connectors-apis-permissions``: 默认关闭

### Role & RoleBinding 手动创建

- resource: `connectors/apis/{context-resource-name}`
- resourceNames: `{connector-name}`
- verbs: `{verb}`
- `{context-resource-name}`: 资源的上下文名称， `{api-version}/{resource-kind}/{resource-namespace}/{resource-name}` 例如： tekton.dev/v1/pipelineruns/default/pr-demo-01

> PipelineRun 的 NS 名称 和 Connector 所在的 NS 名称 可能不一致。

**临时授权**

``` yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-apis-reader-for-$PR_NAME
  namespace: devops
rules:
- apiGroups: [ "connectors.alauda.io" ]
  resources: [ "connectors/apis/tekton.dev/v1/pipelineruns/devops-ns1/$PR_NAME" ]
  resourceNames: [ "prod-harbor" ]
  verbs: [ "update", "delete" ]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
```

**只读授权**
``` yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-apis-reader
rules:
- apiGroups: [ "connectors.alauda.io" ]
  resources: [ "connectors/apis" ]
  resourceNames: [ "*" ]
  verbs: [ "get" ]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
```

验证

``` bash

# 允许
kubectl auth can-i update connectors/prod-harbor --subresource apis --as=system:serviceaccount:$NS:pipeline-sa -n $NS

# 允许
kubectl auth can-i update connectors/prod-harbor --subresource apis/tekton.dev/v1/pipelineruns/$PR_NAME  --as=system:serviceaccount:$NS:pipeline-sa -n $NS

# 拒绝
kubectl auth can-i update connectors/prod-harbor --subresource apis/tekton.dev/v1/pipelineruns/$PR_NAME-changed --as=system:serviceaccount:$NS:pipeline-sa -n $NS

```

### API 请求权限配置

:::info

git clone 会发送 post 请求。 POST https://gitlab-ce.alauda.cn/devops/katanomi.git/git-upload-pack

需要针对不同的工具类型，提供配置方案，能够配置工具的 API 请求与 `Role Rules Verb` 的映射关系。 无配置时，默认按照请求 http method 来区分.

- Get/Head/Option -> read
- Put/Post -> write
- Delete -> delete

:::

例如： 配置 git connectorclass, 将 git 所有的 GET 和 POST /git-upload-pack 按照 read 操作来对待。

``` yaml
kind: ConnectorClass
metadata:
  name: git
spec:
  api:
    permissions:
      rego: |
        package permissions
        result = {
          "verb": "read"
        }
```

### 改动

- Connectors API Filter 增加 对 connectors/apis SubResources 权限的验证
- Connectors Proxy (正代和反代) 增加 对 connectors/apis SubResources 权限的验证

### 默认角色权限

**方案1**

- connector view 角色： 仅允许 get/list/watch connectors 资源， 以及 /connectors/apis/*:get 权限
- connector admin 角色： 允许 connectors 资源的所有操作， 以及 /connectors/apis/*:* 权限

**方案2**

- connector view 和 admin 角色： 仅允许 get/list/watch connectors 资源， 以及 /connectors/apis/*:get 权限

推荐: 方案2

具备平台 connector admin 角色，并不意味着对工具的数据具有 admin 权限。这是跨信任边界的。
对于工具上的敏感操作，应该是即时授权的使用机制。 避免 **权限的横向移动**。`k8s connector admin -> 工具 admin`

**Cluster Connector**

| 角色名称                               | 权限                                               |
| -------------------------------------- | -------------------------------------------------- |
| cpaas:connectors-cluster:cluster:view  | connectors:get/list/watch , /connectors/apis:get |
| cpaas:connectors-cluster:cluster:admin | connectors:* , /connectors/apis:get              |

**Project Connector**

| 角色名称                                  | 权限                                               |
| ----------------------------------------- | -------------------------------------------------- |
| cpaas:connectors-project:project-ns:view  | connectors:get/list/watch , /connectors/apis:get |
| cpaas:connectors-project:project-ns:admin | connectors:* , /connectors/apis:get              |

**Namespace Connector**

| 角色名称                                      | 权限                                               |
| --------------------------------------------- | -------------------------------------------------- |
| cpaas:connectors-namespaced:business-ns:view  | connectors:get/list/watch , /connectors/apis:get |
| cpaas:connectors-namespaced:business-ns:admin | connectors:* , /connectors/apis:get              |