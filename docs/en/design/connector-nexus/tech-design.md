# Nexus Connector Tech Design

## 用户使用场景分析

Nexus 是一个通用制品库，单个实例通常同时托管 Maven、NPM、PyPI 等多种类型的 repository。在 CI/CD 流水线中，同一个构建任务往往需要同时依赖多种制品库类型（如既需要 Maven 依赖，又需要 NPM 包），这与现有单一协议 Connector 的设计存在落差。

**典型场景**：

- 在流水线中使用相同类型的多个仓库（如 Maven 的 releases、snapshots、thirdparty 仓库），所有仓库属于同一个 Nexus 实例（通常可以是小权限账号）。
- 管理员希望通过统一的 Nexus Connector 来管理 Nexus 实例，包括仓库创建，权限分配等等。

**用户痛点**：

使用现有 Maven/NPM/PyPI Connector 时，用户需要为同一 Nexus 实例分别创建三个 Connector，并在 Pod 中分别挂载三个 CSI 卷，配置繁琐、凭据重复管理。

**目标**：通过一个 Nexus Connector，统一管理对同一 Nexus 实例的多种 repository 访问，并通过各协议专属的 ResourceInterface 按需挂载对应配置文件（`settings.xml`、`.npmrc`、`pip.conf` 等）。

---

## 实现难点

与 Maven/NPM/PyPI Connector 不同，Nexus Connector 的 `spec.address` 只是 Nexus 服务的根地址（如 `https://nexus.example.com`），并不包含具体的 repository 路径。而各工具的配置文件（`settings.xml`、`.npmrc`、`pip.conf`）需要指向具体的 repository URL（如 `.../repository/maven-releases/`），仅凭根地址无法完成配置文件的生成。

这带来以下核心问题：

- **repository 信息从哪来**：用户需要额外提供 repository 名称，系统才能拼接出完整的 repository URL 写入配置文件。
- **配置生成时额外的参数如何获取**：如 Maven 的 `mirrorRepository`、NPM 的 `registry`、PyPI 的 `repository` 等，需要在 ResourceInterface 使用时由用户输入。

---

## 设计方案

### 方案：每协议独立 ResourceInterface + Configuration Params

#### 核心思路

1. **Connector 创建阶段**：用户仅需指定 Nexus 根地址，无需额外参数。
2. **ConnectorClass 定义阶段**：为每种协议（Maven、NPM、Yarn、PyPI）定义独立的 configuration，每个 configuration 内嵌 `params` 声明用户输入项（如 `mirrorRepository`、`registry`、`repository`）。
3. **ConnectorClass API 阶段**：在 `spec.api.openapi` 中声明 Nexus `/service/rest/v1/repositories` 接口，供 Dynamic Form 动态拉取可选 repository 列表。
4. **ResourceInterface 定义阶段**：为每种协议分别创建独立的 ResourceInterface（`nexusmavenartifact`、`nexusnpmartifact`、`nexuspypiartifact`），每个 ResourceInterface 通过 `spec.workspaces` 定义 CSI 挂载配置，并在 `configuration.params` 中传入用户选择的 repository 名称。
5. **Attributes 计算阶段**：ResourceInterface 的 `spec.attributes` 将用户输入与 connector 地址拼接，计算出完整的 repository URL，供流水线任务引用。
6. **ConnectorClass 模板阶段**：各 configuration 模板读取 `index .configurations "<paramName>"` 获取 repository 名称，结合 `connectorclass.proxyAddress` 和 `context.token` 生成工具配置文件，认证通过 Connectors Proxy 代理完成。

#### 1. Connector 定义与创建

**ConnectorClass 示例**（节选关键字段）：

```yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: ConnectorClass
metadata:
  name: nexus
  labels:
    resourceinterface.connectors.cpaas.io/nexusmavenartifact: "true"
    resourceinterface.connectors.cpaas.io/nexusnpmartifact: "true"
    resourceinterface.connectors.cpaas.io/nexuspypiartifact: "true"
spec:
  address:
    name: address
    type: string
    description: "Nexus Registry endpoint URL, e.g. https://nexus.example.com"
  api:
    openapi:
      openapi: 3.0.3
      info:
        title: Nexus API
        version: v1
      paths:
        /service/rest/v1/repositories:
          get:
            operationId: listNexusRepositories
            responses:
              "200":
                description: List all Nexus repositories
                content:
                  application/json: {}
            x-display-schema:
              descriptors:
                - urn:alm:descriptor:expression:props.options:label:path:name
                - urn:alm:descriptor:expression:props.options:value:path:name
  auth:
    types:
    - name: basicAuth
      displayName: "Basic Auth"
      description: "Basic authentication for Nexus Registry"
      secretType: kubernetes.io/basic-auth
      optional: true
  authProbes:
  - authName: basicAuth
    probe:
      http:
        path: /service/rest/v1/status
        httpHeaders:
        - name: Authorization
          value: >-
            {{- if .Secret }}Basic {{ printf "%s:%s" .Secret.StringData.username .Secret.StringData.password | b64enc }} {{- end }}
  livenessProbe:
    http:
      path: /service/rest/v1/status
  proxy:
    ref:
      kind: Service
      name: connectors-proxy-service
      namespace: connectors-system
  configurations:
  - name: settings
    params:
    - name: mirrorRepository
      type: string
      default: ""
      description: "The Nexus repository to use as mirror for Maven artifacts."
    data:
      settings.xml: |
        {{- $proxyUrl := urlParse .connectorclass.proxyAddress -}}
        {{- $proxyHost := splitList ":" $proxyUrl.host | first -}}
        {{- $proxyPassword := .context.token -}}
        {{- $proxyUsernameList := list -}}
        {{- range .connectors }}
        {{- $proxyUsernameList = append $proxyUsernameList (printf "%s/%s" .metadata.namespace .metadata.name) -}}
        {{- end }}
        {{- $proxyUsername := $proxyUsernameList | join "," -}}

        <settings>
          <proxies>
            <proxy>
              <id>connectors-proxy</id>
              <active>true</active>
              <protocol>http</protocol>
              <host>{{ $proxyHost }}</host>
              <port>80</port>
              <username>{{ $proxyUsername }}</username>
              <password>{{ $proxyPassword }}</password>
              <nonProxyHosts>localhost</nonProxyHosts>
            </proxy>
          </proxies>
          <mirrors>
            {{- $mirrorRepository := index .configurations "mirrorRepository" -}}
            {{- if $mirrorRepository }}
            <mirror>
              <id>{{ .connector.metadata.name }}-mirror</id>
              <url>{{ .connector.spec.address }}/repository/{{ $mirrorRepository }}</url>
              <mirrorOf>*</mirrorOf>
            </mirror>
            {{- end }}
          </mirrors>
        </settings>
  - name: npmrc
    params:
    - name: registry
      type: string
      description: "The Nexus proxy repository to use as the npm registry."
    - name: strictSSL
      type: string
      default: "true"
      description: "Whether to require SSL. Default is true."
    data:
      .npmrc: |
        {{- $proxyURL := urlParse .connectorclass.proxyAddress -}}
        {{- $password := .context.token -}}
        {{- $registryURL := urlParse .connector.spec.address -}}
        {{- $username := printf "%s/%s" .connector.metadata.namespace .connector.metadata.name | urlquery -}}
        registry={{ trimSuffix "/" .connector.spec.address }}/repository/{{ index .configurations "registry" }}/
        //{{ $registryURL.host }}/repository/{{ index .configurations "registry" }}/:_auth={{ printf "user:password" | b64enc }}
        https-proxy={{ $proxyURL.scheme }}://{{ $username }}:{{ $password }}@{{ $proxyURL.host }}
        proxy={{ $proxyURL.scheme }}://{{ $username }}:{{ $password }}@{{ $proxyURL.host }}
        {{- $strictSsl := index .configurations "strictSSL" }}
        {{- if $strictSsl }}
        strict-ssl={{ $strictSsl }}
        {{- end }}
        audit=false
        fund=false
  - name: yarnrc
    params:
    - name: registry
      type: string
      description: "The Nexus proxy repository to use as the npm registry."
    - name: strictSSL
      type: string
      default: "true"
      description: "Whether to require SSL. Default is true."
    data:
      .yarnrc.yml: |
        # (模板略，结构与 npmrc 类似，输出 yarnrc.yml 格式)
  - name: pipconf
    params:
    - name: repository
      type: string
      description: "The Nexus proxy repository to use as the PyPI index."
    data:
      pip.conf: |
        {{- $proxyURL := urlParse .connectorclass.proxyAddress -}}
        {{- $username := printf "%s/%s" .connector.metadata.namespace .connector.metadata.name | urlquery -}}
        {{- $password := .context.token -}}
        {{- $repositoryURL := urlParse .connector.spec.address -}}

        [global]
        index-url = {{ trimSuffix "/" .connector.spec.address }}/repository/{{ index .configurations "repository" }}/simple/
        timeout = 30
        trusted-host = {{ $repositoryURL.host }}
        proxy = {{ $proxyURL.scheme }}://{{ $username }}:{{ $password }}@{{ $proxyURL.host }}:80
  - name: pypirc
    params:
    - name: deployRepository
      type: string
      description: "The repository to upload the PyPI artifact to."
    data:
      .pypirc: |
        # (模板略，输出 .pypirc 格式，用于 twine upload)
```

**创建 Connector 示例**：

```yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: Connector
metadata:
  name: nexus-main
  namespace: my-namespace
spec:
  connectorClassName: nexus
  address: https://nexus.example.com
```

无需指定任何额外参数。

#### 2. 独立 ResourceInterface 设计

每种协议对应一个独立的 ResourceInterface。ConnectorClass 通过 labels 声明其支持的 ResourceInterface 类型：

```yaml
labels:
  resourceinterface.connectors.cpaas.io/nexusmavenartifact: "true"
  resourceinterface.connectors.cpaas.io/nexusnpmartifact: "true"
  resourceinterface.connectors.cpaas.io/nexuspypiartifact: "true"
```

**Maven ResourceInterface 示例**：

```yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: ResourceInterface
metadata:
  name: nexusmavenartifact
  labels:
    resourceinterface.connectors.cpaas.io/category: MavenArtifact
  annotations:
    cpaas.io/display-name: Nexus Maven Artifact
    style.tekton.dev/descriptors: |-
      - path: params.mirrorRepository
        x-descriptors:
          - urn:alm:descriptor:widgets:select
          - urn:alm:descriptor:expression:props.options:schema:openapi:context.connectorClass.spec.api.openapi:listNexusRepositories
          - urn:alm:descriptor:label:en:Mirror Repository
          - urn:alm:descriptor:label:zh:镜像仓库
          - urn:alm:descriptor:description:en:The Nexus repository to use as Maven mirror.
          - urn:alm:descriptor:description:zh:用作 Maven 镜像的 Nexus 仓库。
          - urn:alm:descriptor:expression:props.options:path.exp:$.filter(i => i.format === 'maven2')
spec:
  params:
  - name: mirrorRepository
    type: string
    default: ""
    description: "The Nexus Maven repository to use as mirror."
  attributes:
  - name: mirrorRepository
    type: string
    dependsOn:
    - params.mirrorRepository
    expression: "{connector.spec.address.replace(/\\/+$/, '') + '/repository/' + params.mirrorRepository}"
  workspaces:
  - name: settings
    workspaceMapping:
      name: maven-settings
    value:
      csi:
        driver: connectors-csi
        readOnly: true
        volumeAttributes:
          connectors: "{connector.metadata.name}"
          configuration.names: settings
          configuration.params: "{JSON.stringify({settings: {mirrorRepository: params.mirrorRepository || ''}})}"
          token.expiration: 30m
```

Dynamic Form 通过 `style.tekton.dev/descriptors` 调用 ConnectorClass 定义的 OpenAPI 接口（`listNexusRepositories`），并使用 `path.exp` 过滤出对应 format（如 `maven2`）的仓库，填充下拉选项。

类似地，NPM ResourceInterface 过滤 `format === 'npm'`，PyPI ResourceInterface 过滤 `format === 'pypi'`。

#### 3. 认证与代理机制

Nexus Connector 采用 Connectors Proxy 代理认证，而非直接将凭据写入配置文件：

- **代理地址**：`connectorclass.proxyAddress`，由平台注入，模板中通过 `urlParse` 解析 host/scheme。
- **Token**：`context.token`，由 CSI 驱动在挂载时动态生成，作为代理认证的 password。
- **Username 编码**：`<namespace>/<connectorName>`，URL encode 后作为代理认证的 username。

这样，工具（Maven/NPM/pip）实际上连接的是平台代理，由代理转发请求并注入真实凭据，用户无需在配置文件中暴露 Nexus 用户名密码。

#### 4. CSI 挂载方式

ResourceInterface 的 `spec.workspaces` 定义了 CSI 卷的完整配置，用户无需手动编写 volumes。在流水线 PipelineRun 中，平台根据 ResourceInterface 的 `workspaceMapping` 自动绑定。

**Pod 中的 CSI 卷等效示例（以 Maven 为例）**：

```yaml
volumes:
- name: maven-settings
  csi:
    driver: connectors-csi
    readOnly: true
    volumeAttributes:
      connectors: nexus-main
      configuration.names: settings
      configuration.params: '{"settings":{"mirrorRepository":"maven-releases"}}'
      token.expiration: 30m
```

CSI 驱动流程：

1. 读取 `volumeAttributes.configuration.params` 中的用户参数（如 `mirrorRepository`）
2. 将参数传入 ConnectorClass 对应 configuration 的模板（`.configurations` 上下文）
3. 渲染并挂载配置文件（如 `settings.xml`）到 Pod 内指定路径

#### 方案优点

1. **最小化 Connector 配置**：用户创建 Connector 时仅需指定地址，无需额外参数。
2. **按协议解耦**：每种协议独立的 ResourceInterface，互不影响，易于扩展新协议。
3. **Dynamic Form 集成**：通过 ConnectorClass `spec.api.openapi` + `style.tekton.dev/descriptors` 引导前端调用 Nexus API 动态拉取可选 repository，并按 format 过滤，避免手工输入错误。
4. **代理认证安全**：凭据不写入配置文件，通过 Connectors Proxy + 动态 token 完成认证，更安全。
5. **符合现有规范**：CSI 挂载方式、ResourceInterface 结构与现有 Connector 规范完全一致，无需扩展 CSI 驱动功能。
6. **多工具支持**：同一 Connector 支持 Maven（settings.xml）、NPM（.npmrc）、Yarn（.yarnrc.yml）、PyPI 下载（pip.conf）、PyPI 上传（.pypirc）五种配置，覆盖主流 CI/CD 场景。

#### 方案缺点

1. **ResourceInterface 与协议耦合**：每种协议需要单独维护一个 ResourceInterface，当 Nexus 支持新协议时需同步新增。
2. **单 repository 限制**：每个 configuration 当前只支持配置单个 repository（如 Maven 的 `mirrorRepository`），若需要多个同类型 repository（如同时配置 releases 和 snapshots mirror），需要用户在 Nexus 侧配置 group repository，或通过多次挂载解决。
3. **多 Connector 场景限制**：由于参数输入并没有区分 Connector，因此无法适配于多 Connector 场景。
