## Summary

目前 Connector 仅提供了 面向协议的 ConnectorClass， 考虑到在特定工具下更好的使用体验， 我们需要一套面向工具的 ConnectorClass。
本文描述实现面向特定工具的 ConnectorClass 所需要满足的技术要求和实现思路

## Motivation

描述实现面向特定工具的 ConnectorClass 所需要满足的技术要求和实现思路。

### Goals

- 梳理面向特定工具的 ConnectorClass 所需要满足的技术要求
- 明确实现框架的基本思路。

### Non-Goals

- 定义所有实现细节

### Use Cases

以 gitlab 为例梳理如下:

- 用户可以创建 Gitlab Connector ， 并满足 Connector 定义的基本能力。
    * 工具访问检查，认证检查，配置能力。
- 在 K8S Workload / Pipeline 中，用户能够使用 Gitlab Connector 使用 git, gitlab cli 以 secretless 的形式进行 git/gitlab 操作
    * git cli
    * gitlab cli
    * 用户自定义的 cli， 使用 gitlab 的凭据
- Gitlab Connector 可提供 group API List, repository API List，revision List, branch List, Tag List, PR List  以使得 以 Pipeline 为例的UI 客户端， 可以使用 Connector 这些 API，完成 gitlab 资源的下拉展示 和选择。
    * Git Revision API
    * Gitlab xxx API

## Proposal

支持一个新的 ConnectorClass 类型，包含如下部分内容

- 认证方式
- 配置能力
- 代理能力
- API 能力

### 认证

面向协议的 ConnectorClass 并不对特定工具的 ConnectorClass 有约束。 对于面向特定工具的 ConnectorClass, 我们通常期望提供更好的体验，需要依赖 API 来提供更多的资源访问能力。 所以，这里的认证方式，需要支持工具特有的认证方式。

- **支持工具特有的， 具有 API 访问能力的认证方式。**
  - 例如 Gitlab 的 PAT, oauth2 等。

例如:

``` yaml
kind: ConnectorClass
metadata:
  name: gitlab
spec:
  auth:
    types:
      - name: PAT # private access token
        secretType: connectors.cpaas.io/gitlab-pat-auth
      - name: OAuth2 # oauth2 token
        secretType: connectors.cpaas.io/oauth2
```

### 配置

面向特定工具的 ConnectorClass, 配置使用场景如下:

- 对应协议层 ConnectorClass 的使用场景下，能无缝切换为面向特定工具的 ConnectorClass
- 在当前工具类型下，特有的使用场景。

为满足如上两种使用场景，我们需要:

- **提供和协议层面 ConnectorClass 一致的 configurations 配置能力**
  - 推荐保持命名一致。
  - 例如 Git 类的都提供 gitconfig 配置。
- **额外提供工具特有的 configurations 配置能力**。例如
  - gitlab 的认证信息，harbor 的认证信息。

例如 Gitlab

``` yaml
kind: ConnectorClass
metadata:
  name: gitlab
spec:
  configurations:
  - name: gitconfig # 和 Git connectorclass 一致的配置
    data:
      .gitconfig: ""
  - name: gitlabconfig # 工具特有的配置
    data:
      config.yml: ""

```

### Proxy

我们希望: "工具 CLI (包括自定义 CLI) 通过 Proxy 以 Secretless 的形式访问工具，对 CLI 无侵入", 涉及两方面:

- CLI 如何配置凭据
- CLI 如何发送凭据信息

#### 正向代理

对于工具的 CLI， 只要支持 HTTP Proxy 代理， 自然满足 "工具 CLI 通过 Proxy 以 secretless 的形式访问工具" 的能力， 凭据配置和发送凭据的方式对 CLI 无侵入。

**对 CLI 的要求**

- 工具 CLI 支持 HTTP Proxy
- 工具 CLI 支持 SKIP_TLS_VERIFY 或者支持配置 CA 证书。

工具 CLI 不需做额外适配。

**对 CLI 使用者的影响**

- 无需传递额外的凭据
- 配置 HTTP Proxy 环境变量

#### 反向代理

**基本改造思路**

- 客户端配置凭据时，按照使用的认证方式， 传入 SA Token, 通过 url 或者 path 来传递 Connector namespace/name
- Proxy 校验权限时，根据支持/使用的认证方式，提取 SA Token, 进行权限校验。
- Proxy 请求 Backend 注入认证信息时，根据使用的认证方式，注入认证信息。

**提供三种维度的反向代理**:

- 内置标准认证协议下的反向代理。例如 Basic Auth, Bearer Token
- 自定义的反向代理。根据当前工具的认证方式，自定义反向代理。
- 内置可轻量扩展的反向代理。例如 通过 Rego 插入可扩展逻辑。

**内置标准认证协议的反向代理**

- `Basic Auth`:
  *  权限校验: username 任意, password 传递 SA Token,  Connector namespace/name 通过 url 或 path 来传递
  *  认证注入: 按照 Basic Auth 方式注入
- `Bearer Token`:
  *  权限校验: Bearer token 传递 SA Token, Connector namespace/name 通过 url 或 path 来传递
  *  认证注入: 按照 Bearer Token 方式注入

**自定义的反向代理**

根据当前工具的认证方式，自定义反向代理，满足基本逻辑对 Proxy 的要求。

**可轻量扩展的反向代理**

通过自定义脚本，插入逻辑到标准的 Http Reverse Proxy 中。

- Proxy 校验权限:
  - 通过自定义脚本， 根据工具支持/使用的认证方式，提取 SA Token
  - 通过 Url 或 Path 来传递 Connector namespace/name
- Proxy 请求 Backend 认证注入:
  - 通过自定义脚本，根据工具使用的认证方式，注入认证信息。


示例

- 用户在客户端，按照原始凭据配置方式，将 SA Token 作为 PRIVATE-TOKEN header 提供给 gitlab cli。
- Proxy 通过 Rego 规则，提取 PRIVATE-TOKEN header 提取 SA Token， 校验权限。
- Proxy 请求 Backend 注入认证信息时，根据提供的 rego 规则， 注入认证信息。

例如:

``` yaml
kind: ConnectorClass
metadata:
  name: gitlab
spec:
  proxy:
    ref:
      kind: Service
      name: connectors-proxy-service
      namespace: connectors-system
    authExtractor: # 新增支持, proxy 从客户端请求中，提取权限校验所需的 sa token
      rego: |
        package proxy
        auth = {
          "token": input.headers["Private-Token"][0]
        }
  auth:
    types:
    - name: PAT
      secretType: connectors.cpaas.io/gitlab-pat-auth
      params:
      - name: token  # PRIVATE-TOKEN
        type: string
      generator: # 已有支持，自定义注入认证的逻辑
        rego: |
          package proxy
          auth = {
            "position": "header",
            "auth": {
              "PRIVATE-TOKEN": input.token
            }
          }
```

**对 CLI 的要求**

- 可指定目标 Server 的地址

**对 CLI 使用者的影响**

- 凭据配置时，将 SA Token 按照工具原始的凭据传入方式，进行传递。
- 将请求地址改为 Reverse Proxy 的地址。

**小结**

两种形式的代理， 都可以在无侵入的情况下，支持工具 CLI 以及用户自定义的 CLI ，使用 Connector Proxy 以 Secretless 的形式访问工具。

- 正向代理天然支持。
- 反向代理通过支持工具原始的凭据传入方式，实现对 CLI 的无侵入性，通过三种维度的代理，满足不同场景下的需求。

### API 定义与使用

参考 [Connector API](./connector-api.md)

### Performance

- 可轻量扩展的反向代理，可能使得更多的服务会使用标准的内置反向代理。 代理服务可能成为性能的瓶颈。同时，对于多租户的场景，单个租户对代理的请求，会影响该代理服务的稳定性，从而影响其他租户对代理服务的使用。 需考虑代理服务的性能和多租户场景的支持。


## Implementation Plan

- **Connector Proxy Framework 调整**  ---- 3
  - 支持可轻量扩展的反向代理。
- **支持 Gitlab Connector, 以及 在 Pod 中，通过 Git/Gitlab CLI 以 Secretless 的形式访问 Gitlab**  --- 4
  - Gitlab ConnectorClass
  - Gitlab Proxy (By Rego in ConnectorClass)
  - Connector-Operator 部署支持

- 调整框架，Auth Probe 支持使用 Rego 进行权限校验。

### Test Plan

**集成测试**

- 可轻量扩展的反向代理
- Gitlab ConnectorClass 相关集成测试
- Auth Probe 对 Rego 的支持

**E2E 测试**

- Gitlab ConnectorClass E2E

## References

- [Connectors Proxy Authentication](../connectors/concepts/connectors_proxy.mdx#connectors-proxy-authentication)
