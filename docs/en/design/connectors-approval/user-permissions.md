# 平台用户的默认权限

原始的问题

- 加了 `connectors/apis` 权限校验后， 用户会因为没有 权限，无法在 UI 查看 Branches/Tags.
- 为平台用户增加了默认权限，允许 调用 Connectors 的所有 `read` API (http get). 使得 UI 可以List资源

但，目前的 `read` verb 定义由于比较宽泛，存在 git 仓库泄露， oci registry 镜像仓库泄露的风险。

## 思路

:::info

UI -> Cluster Ingress -> Connectors API -> Connectors Proxy
SA -> Connectors Proxy

:::

将 `Connectors-API` 权限和 `Connectors-Proxy` 权限分开, 当成两个SubResource. connectors/apis, connectors/proxy

- `connectors/api`: 通过平台用户角色体系授予用户。 在有限的 API 范围内，用于页面资源选择。
- `connectors/proxy`: 通过 AccessPolicy 授予。

**场景**

以 一个团队为例:

- 绝对敏感的 Connector, 通过 NS 来隔离：其他 NS SA 或用户， 无法 Get Connector, 无法以任何形式调用 Connector API.
  - UI 选择 🚫
  - 通过 Proxy 调用 API 🚫

- 次敏感的 Connector，在 Project 创建 Connector
  - UI 选择 ✅  ------ Project 下用户可调用 Connectors API
  - 通过 Proxy 调用 API 🕐 -----  AccessPolicy 通过**检查授权** SA

- 不敏感的 Connector， 在 Project 下创建 Connector
  - UI 选择 ✅  ------ Project 下用户可调用 Connectors API
  - 通过 Proxy 调用 API ✅ -----  AccessPolicy 默认授权

**问题**

- Gitlab 的 Rest API ，可以获取文件内容，理论上是可以拖库的。
  - 方案1： Connectors-API 只允许调用 ConnectorClass spec.api.openapi 描述过的 API 。 ✅
  - 方案2: 考虑额外提供一些配置

- 某些工具是 Post API 进行 Search
  - 非本方案引入，通过 对 ConnectorClass 自定义 API 来实现。

## 其他可选思路

### 细化 ConnectorClass 权限

按照不同的 ConnectorClass 做权限细分，细分出最安全的那部分权限(verb)，授权给用户，用于 API 调用。

**Git ConnectorClass**

- read-api （list refs）
- 其他
  - read-git (clone) 
  - write-git （push）

**GitLab ConnectorClass**

- read-api （list branches, list tags, list projects, list pr）
- 其他
  - read-git (clone) 
  - write-git （push）
  - write-gitlab （create pr comment, create pr）

**OCI ConnectorClass**

- read-api (list tags)
- 其他
  - read-registry （pull）
  - write-registry （push）

#### 总结

**粗粒度的权限划分**

verbs:
- `read-api`: 用于页面上 API 调用的权限
- `*`

挑战: verbs 的细化和工具自身强相关，较为复杂。

------------------------------------


## 详细方案

**总体思路**

- 抽象 `connectors/apis` 和 `connectors/proxy` 两个 subresource.
- Connectors-API 组件校验 `connectors/apis` 权限
- Connectors-Proxy组件校验 `connectors/proxy` 权限
- 平台默认角色中包含 `connectors/apis` 权限

### Connectors-API 权限校验

#### ConnectorClass 提供的 ClusterRole

每个 ConnectorClass 提供自己的 Connectors-API 的 ClusterRole, aggregated 到平台角色中。

``` yaml
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-{connectorclass}-apis-reader
rules:
- apiGroups: ["connectors.alauda.io"]
  resources: ["connectors/apis/{class}/{api-path-1}", "connectors/apis/{api-path-2}"]
  verbs: ["get"]
```

例如:

``` yaml
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-gitlab-apis-reader
rules:
- apiGroups: ["connectors.alauda.io"]
  resources: 
  - connectors/apis/gitlab/api/v4/projects
  - connectors/apis/gitlab/api/v4/projects/{project_id}/repository/branches
  verbs: ["get"]
```

Connectors-API 通过请求的路径来校验权限。
默认的 resources 最小的 API列表， 如果用户需要自定义， 也可以加上。

#### Connectors-API 权限校验

Connectors-API 组件改为校验请求 的 connector 的 `connectors/apis` subresource 的权限。

校验两层权限，任意通过即可 (verb 为 get):

- `connectors/apis/{connectorclass}`
- `connectors/apis/{connectorclass}/{api-path}` 

**api-path 转换**

查询 ConnectorClass 中 `spec.api.openapi` 的定义， 将用户请求的路径转换为权限验证所需的路径:

例如:

`api/v4/projects/devops%2Fkatanomi/repository/branches`       ---openapi--> 
`apis/gitlab/api/v4/projects/{project_id}/repository/branches`

如果在 openapi 中未定义， 则需要有 `connectors/apis/{connectorclass}` 权限，才能正常调用。

### Connectors-Proxy 权限校验

在原有有逻辑基础上

- 校验 subresource: `connectors/apis` -> `connectors/proxy` 
- 校验的 verb: `http 映射 verb` -> `*`

其他不变

### CSI Driver 权限校验

在原有有逻辑基础上

- 校验 subresource: `connectors/apis` -> `connectors/proxy` 

其他不变

### Task List

- 修改已有的 `connectors/apis` 为 `connectors/proxy`
  - Connectors-Proxy: 保持不变，校验 `connectors/proxy`, verb 为 * -- 需要核对
  - CSI-Driver: 保持不变， 校验 `connectors/proxy`
  - Connectors-API: 改为校验 `connectors/apis`
  - 变量重命名， 文件名重命名
- 修改 Connectors-Proxy 权限校验逻辑
  - verb *, 移除 verb 映射逻辑
- 修改 Connectors-API 权限校验逻辑
  - 校验 connectors/apis/{class} 权限
  - 否则，对具体的 API 路径权限进行校验
    - 根据当前路径， 查找 openapi 定义， 获得 openapi 路径
    - 如果未查找到，则返回 无权限。
    - 将该路径作为 resource 一部分
    - 移除 verb 映射的逻辑，verb 直接使用 get
    - 调用校验API 进行校验
  - 组件需要授权 `connectors/proxy:*` 
- 移除 已有的 ConnectorClass 中， permission 映射的配置
- 每个 ConnectorClass 提供 class-api-reader 角色， 聚合到系统角色
  - 配置已知的 API 列表
- 集成测试
  - 回归 Proxy、CSI 相关逻辑
  - 修改已有的 Connectors-API 集成测试
  - 修改 ConnectorClass 中的 集成测试 ？


### 可行性验证

``` yaml
cat << EOF | kubectl apply -f -
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-gitlab-connectors-apis-reader
rules:
- apiGroups: ["connectors.alauda.io"]
  resources: 
  - connectors/apis/gitlab/api/v4/projects
  - connectors/apis/gitlab/api/v4/projects/{project_id}/repository/branches
  verbs: ["get"]
EOF
```

``` bash
kubectl create ns temp-1

cat << EOF | kubectl apply -n temp-1 -f -
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: connectors-gitlab-connectors-apis-reader
roleRef:
  name: connectors-gitlab-connectors-apis-reader
  kind: ClusterRole
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: default
  namespace: temp-1
EOF

```

``` bash
# yes
kubectl auth can-i --as=system:serviceaccount:temp-1:default get connectors --subresource=apis/gitlab/api/v4/projects -n temp-1

# `api/v4/projects/devops%2Fkatanomi/repository/branches` ---openapi--> apis/gitlab/api/v4/projects/{project_id}/repository/branches
# yes
kubectl auth can-i --as=system:serviceaccount:temp-1:default get connectors --subresource=apis/gitlab/api/v4/projects/{project_id}/repository/branches -n temp-1

# no
kubectl auth can-i --as=system:serviceaccount:temp-1:default get connectors --subresource=apis/gitlab/api/v4/projects/{project_id}/repository/mergerequests -n temp-1
```
