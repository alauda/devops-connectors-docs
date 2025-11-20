# NPM Connector Design

NPM Connector 是用于连接 NPM Registry 的 Connector。

用户可以使用 NPM Connector 进行 NPM 操作，例如安装依赖、发布包等。


## ConnectorClass
 
NPM ConnectorClass 包含以下几个部分：

- 配置文件：
  - npmrc: 用于指定 connector Proxy 作为 npm 的源，npm cli  安装和发布时使用。
  - yarnrc: 用于指定 connector Proxy 作为 npm 的源，yarn  cli 安装和发布时使用。（注意这里仅支持 yarn 2 格式的配置）
- 地址：
  - address: NPM Registry endpoint URL, e.g. https://registry.npmjs.org
- 认证类型: basicAuth, 认证配置可选
- 验证探测：采用端点：/
- 存活探针：采用根路径：/

例如:

```yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: ConnectorClass
metadata:
  name: npm
  annotations:
    cpaas.io/display-name: "NPM Registry"
    cpaas.io/description: "NPM connector is a platform-agnostic connector that you can use to connect to any NPM Registry"
    connectors.cpaas.io/readme: |
      The NPM connector is a platform-agnostic connector that you can use to connect to any NPM Registry like Nexus, npmjs.org etc.

      You can use the NPM Connector to securely access private NPM registries in CICD pipelines, or use it in containerized workloads to perform NPM operations without credentials.
    connectors.cpaas.io/docs-link: "alauda-devops-connectors/connectors-npm/concepts/npm_connectorclass.html"
    connectors.cpaas.io/proxy-resolver: host
spec:
  configurations:
  - name: npmrc
    data:
      ca.cert: "{{ .context.proxy.caCert }}"
      .npmrc: |
        {{- $proxyURL := urlParse .connector.status.proxyAddress -}}
        {{- $password := .context.token -}}
        {{- $registryURL := urlParse .connector.spec.address -}}
        {{- $username := printf "%s/%s" .connector.metadata.namespace .connector.metadata.name | urlquery -}}
        # NPM Registry Configuration
        registry={{ trimSuffix "/" .connector.spec.address }}/
        
        # The authentication token is fake, because the connector will not use it, it will be used for proxy requests.
        //{{ $registryURL.host }}/{{ trimSuffix "/" (trimPrefix "/" $registryURL.path) }}/:_auth={{ printf "user:password" | b64enc }}

        # Set the connector proxy URL for npm registry access
        https-proxy={{ $proxyURL.scheme }}://{{ $username }}:{{ $password }}@{{ $proxyURL.host }}
        proxy={{ $proxyURL.scheme }}://{{ $username }}:{{ $password }}@{{ $proxyURL.host }}

        # Disable strict SSL verification for internal registries
        strict-ssl=false
        
        # Disable npm audit to avoid security warnings during CI/CD
        audit=false
        
        # Disable funding messages to reduce output noise
        fund=false
  - name: yarnrc
    data:
      ca.cert: "{{ .context.proxy.caCert }}"
      .yarnrc.yml: |
        {{- $proxyURL := urlParse .connector.status.proxyAddress -}}
        {{- $password := .context.token -}}
        {{- $registryURL := urlParse .connector.spec.address -}}
        {{- $username := printf "%s/%s" .connector.metadata.namespace .connector.metadata.name | urlquery -}}
        # Set the NPM registry server URL for package resolution
        npmRegistryServer: "{{ .connector.spec.address }}"

        # The authentication token is fake, because the connector will not use it, it will be used for proxy requests.
        npmAuthIdent: "{{ printf "user:password" | b64enc }}"

        # The unsafeHttpWhitelist is used to whitelist the host for proxy requests.
        unsafeHttpWhitelist:
        - {{ $registryURL.hostname }}
        
        # authentication for proxy requests
        httpProxy: "{{ $proxyURL.scheme }}://{{ $username }}:{{ $password }}@{{ $proxyURL.host }}"
        httpsProxy: "{{ $proxyURL.scheme }}://{{ $username }}:{{ $password }}@{{ $proxyURL.host }}"

        # Always authenticate to the registry
        # This is required for the connector to work correctly, if the npmAlwaysAuth is not set to true, the metadata request will not be authenticated.
        npmAlwaysAuth: true
        
        # Disable strict SSL verification for internal registries
        enableStrictSsl: false
        
        # Set the registry URL for package publishing
        # Ensures packages are published to the correct registry
        npmPublishRegistry: "{{ .connector.spec.address }}"
  address:
    name: address
    type: string
    description: "NPM Registry endpoint URL, e.g. https://registry.npmjs.org"
  auth:
    types:
    - name: basicAuth
      displayName: "Basic Auth"
      description: "Basic authentication for NPM Registry"
      secretType: kubernetes.io/basic-auth
      optional: true
  authProbes:
  - authName: basicAuth
    probe:
      http:
        path: "{{ trimPrefix \"/\" (trimSuffix \"/\" (urlParse .Connector.Spec.Address).path) }}/"
        httpHeaders:
        - name: Authorization
          value: >-
            {{- if .Secret }}Basic {{ printf "%s:%s" .Secret.StringData.username .Secret.StringData.password | b64enc }} {{- end }}
  livenessProbe:
    http:
      path: /
  proxy:
    ref:
      kind: Service
      name: connectors-proxy-service
      namespace: connectors-system
```

## 使用connector挂载

使用时，用户需提前创建 Connector，使用 CSI 的方式挂载到 connector，挂载完成后会在pod 中写入两个文件：

- `.yarnrc.yml`: 需要用户将文件放到用户目录下，即 `~/.yarnrc.yml`
- `.npmrc`: 需要用户将文件放到用户目录下，即 `~/.npmrc`
- `ca.cert`: 代理信任的证书，yarn 使用正向代理访问时，可以通过环境变量配置证书可信

用户需要将两个文件放到用户目录下，就可以使用connector 完成 NPM 操作。文件示例：

- `.yarnrc.yml`:

    ```yaml
    # Set the NPM registry server URL for package resolution
    npmRegistryServer: "https://connectors-npm-proxy-service.connectors-system.svc.cluster.local"
    
    # Authentication token for registry access
    # This token is automatically generated by the connector
    npmAuthToken: "<token>"

    # Always authenticate to the registry
    # This is required for the connector to work correctly, if the npmAlwaysAuth is not set to true, the metadata request will not be authenticated.
    npmAlwaysAuth: true

    unsafeHttpWhitelist:
    - connectors-npm-proxy-service.connectors-system.svc.cluster.local
    
    # Disable strict SSL verification for internal registries
    # Set to true for production environments with valid certificates
    enableStrictSsl: false
    
    # Set the registry URL for package publishing
    # Ensures packages are published to the correct registry
    npmPublishRegistry: "https://connectors-npm-proxy-service.connectors-system.svc.cluster.local"
    ```

- `.npmrc`:

    ```ini
    # NPM Registry Configuration
    registry=https://connectors-npm-proxy-service.connectors-system.svc.cluster.local
    
    # Configure authentication for private registry access
    //connectors-npm-proxy-service.connectors-system.svc.cluster.local/_authToken=<token>

    # Disable strict SSL verification for internal registries
    strict-ssl=false
    
    # Disable npm audit to avoid security warnings during CI/CD
    audit=false
    
    # Disable funding messages to reduce output noise
    fund=false
    ```
