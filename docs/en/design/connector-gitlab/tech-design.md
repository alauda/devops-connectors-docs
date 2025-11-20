# GitLab Connector Technical Design

Feature Requirements: [GitLab Connector Feature Requirements](./feature.md)

## ConnectorClass

### 认证

- 支持 Private Access Token (PAT) 认证
- 定义 Secret Type `connectors.cpaas.io/gitlab-pat-auth`
- Secret Data 包含字段：
  - `token`: PAT token

### 可访问性&认证检测

- 使用 `/` 检测可访问性
- 使用 `/api/v4/user`  API 验证 `Private Access Token` 的有效性

### 配置

##### glab CLI 介绍

GitLab CLI 是 GitLab 官方提供的 CLI 工具，通过 CLI 可以完成 GitLab 的资源管理，例如：

```bash

# 配置默认操作的 GitLab 实例
glab config set -g host gitlab.example.com

glab repo clone devops/demo
cd demo
glab issue list
glab mr create
glab mr merge 123
glab mr note -m "needs to do X before it can be merged" branch-foo
```

依赖配置文件: `~/.config/glab-cli/config.yml`

- 支持配置默认的 GitLab 实例地址
- 支持配置 CA 证书路径和跳过 TLS 验证
- 支持配置多个 Gitlab 实例地址和认证信息
- 不支持在配置文件中指定正向代理地址

``` yaml
# What protocol to use when performing Git operations. Supported values: ssh, https.
git_protocol: ssh
# Default GitLab hostname to use.
host: gitlab-ce.alauda.cn
no_prompt: false
hosts:
    gitlab.com:
        api_protocol: https
        api_host: gitlab.com
        token: # The domains of associated container registries. These are used to configure the
        container_registry_domains: gitlab.com,gitlab.com:443,registry.gitlab.com
        custom_headers: []
    gitlab-ce.alauda.cn:
        token: private-access-token
        container_registry_domains: gitlab-ce.alauda.cn,gitlab-ce.alauda.cn:443,registry.gitlab-ce.alauda.cn
        api_host: gitlab-ce.alauda.cn
        git_protocol: https
        api_protocol: https
        user: jtcheng
        # ca_cert: /path/to/ca-chain.pem
        # skip_tls_verify: true
```

将默认的 gitlab 实例，配置为实际的gitlab server, 配置好认证信息后, glab cli 则可以直接完成 GitLab 的资源管理。

**使用正向代理**

- 需要通过环境变量指定正向代理地址

**使用反向代理**

- 在配置文件中生成好配置，指定默认 Gitlab 实例。用户原有 glab cli 操作，自动使用默认的 Gitlab 实例。

#### 自定义 CLI 的支持

**方案1** ConnectorClass 提供 rawconfig 配置

```yaml
kind: ConnectorClass
spec:
  configurations:
  - name: rawconfig
    data:
      http.proxy: |
        {{- $proxyUrl := urlParse .connector.status.proxyAddress -}}
        {{- $username := printf "%s%%2F%s" .connector.metadata.namespace .connector.metadata.name -}}
        {{- $password := .context.token -}}
        {{- $proxyAddressWithAuth := printf "%s://%s:%s@%s" $proxyUrl.scheme $username $password $proxyUrl.host -}}
      https.proxy: ""
      context.token: "{{.context.token}}"
      context.proxy.caCert: "{{.context.proxy.caCert}}"
      connector.status.proxyAddress: "{{.connector.status.proxyAddress}}"
```

在 自定义的 CLI 使用时， 可以根据 CLI 的支持情况，选择 使用 正向代理或反向代理

- CLI 支持正向代理情况下:

  ``` bash
  export http_proxy=$(cat /{mount-path}/http.proxy) && export https_proxy=$(cat /{mount-path}/https.proxy)
  ```

- CLI 不支持正向代理时，可选择使用反向代理:

  ``` bash
  export GITLAB_TOKEN=$(cat /{mount-path}/context.token) && export GITLAB_SERVER=$(cat /{mount-path}/connector.status.proxyAddress)
  # {cli} --server {GITLAB_SERVER} --token {GITLAB_TOKEN} # 示例
  ```

缺点: 每个 ConnectorClass 都需要提供 rawconfig 配置，实际内容都大致相同。

**方案2** 系统提供一个默认配置，暴露基础数据 (推荐方案)

类似方案1， 但系统默认提供该配置， 不需要 ConnectorClass 自行定义 和 挂载时进行显示指定。包含配置和方案1 一致

配置内容保存在 ConfigMap `connectors-csi-configuration-system` 的 data 中

``` yaml
kind: ConfigMap
metadata:
  name: connectors-csi-configuration-system
  namespace: connectors-system
data:
  http.proxy: |
    {{- $proxyUrl := urlParse .connector.status.proxyAddress -}}
    {{- $username := printf "%s%%2F%s" .connector.metadata.namespace .connector.metadata.name -}}
    {{- $password := .context.token -}}
    {{- $proxyAddressWithAuth := printf "%s://%s:%s@%s" $proxyUrl.scheme $username $password $proxyUrl.host -}}
  https.proxy: ""
  context.token: "{{.context.token}}"
  context.proxy.caCert: "{{.context.proxy.caCert}}"
  connector.status.proxyAddress: "{{.connector.status.proxyAddress}}"
```

在 CSI Driver 挂载时，会默认使用 `connectors-csi-configuration-system` 的配置，在对应的目录下生成相关文件。
如果用户自定义的配置中，含有相同的文件key， 则用户配置优先级高于系统配置。

如果这些系统默认配置不够用，用户还是可以在自己的 ConnectorClass 中，提供配置，和方案1 不冲突。

自定义 CLI 的使用方式，同 方案1.

#### 小结

- 提供 `gitconfig` 配置，和 Git ConnectorClass 一致，使用反向代理完成 Git CLI 的 Secretless 访问
- 提供 `gitlabconfig` 配置，使用反向代理，完成 GitLab CLI 的 Secretless 访问。
- Connectors CSI 挂载时，提供默认配置，支持自定义 CLI 的 Secretless 访问。

示例:

``` yaml
spec:
  configurations:
  - name: gitconfig
    data:
      .gitconfig: ""
  - name: gitlabconfig
    data:
      config.yml: ""
```
挂载后，在 Pod 中 ，/{mount-path}/ 会生成如下文件:

``` yaml
# 来自默认配置
- http.proxy
- https.proxy
- context.token
- context.proxy.caCert
- connector.status.proxyAddress

# 来自 gitconfig 配置
- .gitconfig

# 来自 gitlabconfig 配置
- config.yml
```


### 代理

- 客户端按照原始凭据配置方式，将 `K8S Token` 作为 `Private-Token` 提供给 glab cli。
- Proxy Service 从 `Private-Token` Header 中提取 `Private Token`，进行权限校验。
- Proxy Service 请求 Backend 注入认证信息时，使用 Connector 配置的 Secret，将 data["token"] 作为 `Private-Token`, 转发到 GitLab。

``` yaml
spec:
  auth:
    types:
    - name: PAT
      secretType: connectors.cpaas.io/gitlab-pat-auth
      params:
      - name: token
        type: string
      generator:
        rego: |
          package proxy
          auth = {
            "position": "header",
            "auth": {
              "Private-Token": input.token
            }
          }
  proxy:
    ref:
      kind: Service
      name: connectors-proxy-service
      namespace: connectors-system
    authExtractor:
      rego: |
        package proxy
        auth = {
          "token": input.headers["Private-Token"][0]
        }
```

### API

- 不需要提供自定义的 API， 直接使用GitLab 原始 API 即可满足需求。

例如

``` bash
GET /connectors/v1alpha1/default/gitlab-connector/path/api/v4/groups
GET /connectors/v1alpha1/default/gitlab-connector/path/api/v4/projects
# {project_id} could be encoded of project full path, e.g. devops%2Fdemo
GET /connectors/v1alpha1/default/gitlab-connector/path/api/v4/projects/{project_id}/repository/branches
GET /connectors/v1alpha1/default/gitlab-connector/path/api/v4/projects/{project_id}/repository/tags
GET /connectors/v1alpha1/default/gitlab-connector/path/api/v4/projects/{project_id}/merge_requests
```

### 其他

- 无凭据配置的支持 (配置渲染， Rego 规则健壮性)
