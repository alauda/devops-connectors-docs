# SonarQube Connector Design

SonarQube Connector 是用于连接 SonarQube 的 Connector。

用户可以使用 SonarQube Connector 进行 SonarQube 操作，例如代码质量分析、报告生成等。

## ConnectorClass

SonarQube ConnectorClass 包含以下几个部分：

- 配置文件：
  - sonar-project.properties: 指定 SonarQube 服务器地址及认证信息。
- 地址：
  - address: SonarQube server URL, e.g. https://sonarqube.example.com
- 认证类型: tokenAuth, 认证配置为可选
- 验证探测：/api/authentication/validate
- 存活探针：/api/system/status

ConnectorClass 定义:

```yaml
apiVersion: connectors.alauda.io/v1alpha1
kind: ConnectorClass
metadata:
  name: sonarqube
  annotations:
    cpaas.io/display-name: "SonarQube"
    cpaas.io/description: "SonarQube connector enables seamless integration with SonarQube for continuous code quality and security analysis"
    connectors.cpaas.io/readme: |
      The SonarQube connector is a platform-agnostic connector that you can use to connect to any SonarQube instance.

      You can use the SonarQube Connector to securely access SonarQube in CI/CD pipelines for code quality analysis, security scanning, and quality gate checks.
    connectors.cpaas.io/docs-link: "alauda-devops-connectors/connectors-sonarqube/concepts/sonarqube_connectorclass.html"
spec:
  configurations:
  - name: sonar-scanner
    data:
      sonar-project.properties: |
        {{- $proxyURL := urlParse .connector.status.proxyAddress -}}
        {{- $registryURL := urlParse .connector.spec.address -}}
        {{- $username := printf "%s/%s" .connector.metadata.namespace .connector.metadata.name | urlquery -}}
        {{- $password := .context.token -}}
        {{- $proxyPort := $proxyURL.port -}}
        {{- if not $proxyPort -}}
          {{- if eq $proxyURL.scheme "https" -}}
            {{- $proxyPort = "443" -}}
          {{- else -}}
            {{- $proxyPort = "80" -}}
          {{- end -}}
        {{- end -}}

        # SonarQube server configuration
        sonar.host.url={{ trimSuffix "/" .connector.spec.address }}

        # Proxy configuration (scanner properties)
        sonar.scanner.proxyHost={{ $proxyURL.hostname }}
        sonar.scanner.proxyPort={{ $proxyPort }}
        sonar.scanner.proxyUser={{ $username }}
        sonar.scanner.proxyPassword={{ $password }}
  address:
    name: address
    type: string
    description: "SonarQube server URL, e.g. https://sonarqube.example.com"
  auth:
    types:
    - name: tokenAuth
      displayName: "Token Authentication"
      description: "SonarQube user token or project analysis token (recommended)"
      secretType: connectors.cpaas.io/bearer-token
  authProbes:
  - authName: tokenAuth
    probe:
      http:
        path: /api/authentication/validate
        httpHeaders:
        - name: Authorization
          value: >-
            {{- if .Secret }}Bearer {{ printf "%s" .Secret.StringData.token }}{{- end }}
        response:
            cel: >-
              statusCode == 200 && bodyJSON.valid == true
  livenessProbe:
    http:
      path: /api/system/status
      response:
          cel: >-
            statusCode == 200 && bodyJSON.status == 'UP'
  proxy:
    ref:
      kind: Service
      name: connectors-proxy-service
      namespace: connectors-system
```

### 认证和存活

#### 认证说明

认证探测使用 `/api/authentication/validate` 接口，确保存活探针使用 `/api/system/status` 接口。对于 SonarQube，认证存在两种方式：

- Token 认证（推荐）：使用用户令牌或项目分析令牌进行认证。（本次采用Token认证）
  * 用户令牌：适用于用户级别的操作，如手动触发分析、查看报告等。
  * 项目分析令牌：适用于自动化分析任务，如 CI/CD 流水线中的代码质量检查。

- Basic 认证（不推荐）：使用用户名和密码进行认证。由于 Connector 的主要目的是为自动化任务提供服务，Token 认证更安全且易于管理。本次不支持Basic认证。

使用 `/api/authentication/validate` 接口进行认证探测，可以对两种类型的 Token 进行验证，确保连接的有效性。返回报文：

```json
{
  "valid": true // or false
}
```

状态码认证成功失败均为 200，通过返回体中的 `valid` 字段判断认证是否成功。

#### 存活探测

存活探针使用 `/api/system/status` 接口，确保 SonarQube 服务器处于运行状态。返回报文：

```json
{
  "id": "xxx",
  "version": "5.1",
  "status": "UP" // or "DOWN", STARTING,RESTARTING,DB_MIGRATION_NEEDED,DB_MIGRATION_RUNNING
}
```

改接口返回状态码 200 时，且 `status` 字段为 `UP`，表示 SonarQube 服务器运行正常。且无需认证。

#### 代码实现

由于 SonarQube Connector 认证和存活探针均为 HTTP 接口，都需要对 Reposonse Body 进行解析，因此需要增加对 HTTP 探针返回体的解析功能支持：

在 HttpProbAction 上增加 expectedResponse 字段：

```go
...
Response *HttpProbeExpectedResponse `json:"response,omitempty"`
...

// HttpProbeExpectedResponse defines validation rules for HTTP probe responses
type HttpProbeExpectedResponse struct {
	// CEL contains a CEL (Common Expression Language) expression for response validation.
	// The expression must evaluate to a boolean value.
	// Available variables:
	//  - response.statusCode (int): HTTP status code
	//  - response.headers (map<string, list<string>>): Response headers
	//  - response.bodyString (string): Response body as string
	//  - response.body (dynamic): Parsed JSON body (if Content-Type is application/json and body is valid JSON)
	//
	// Example expressions:
	//  - response.statusCode == 200 && bodyJSON.status == 'healthy'
	//  - response.body.uptime > 60 && bodyJSON.errors.size() == 0
	//  - response.bodyString.contains('success') && !response.bodyString.contains('error')
	//  - headers['content-type'][0].startsWith('application/json')
	//
	// CEL is recommended for simple to medium complexity validations:
	//  - Intuitive syntax similar to JavaScript/C/Python
	//  - Better performance for simple expressions
	//  - Native support in Kubernetes ecosystem
	//  - Lower learning curve
	//
	// When both CEL and built-in rules (Contains, Regex, JSONPath) are specified,
	// all rules must pass (AND logic).
	// +optional
	CEL *string `json:"cel,omitempty"`
}
```

使用 CEL 表达式对返回体进行验证：

```yaml
  authProbes:
  - authName: tokenAuth
    probe:
      http:
        path: /api/authentication/validate
        httpHeaders:
        - name: Authorization
          value: >-
            {{- if .Secret }}Bearer {{ printf "%s" .Secret.StringData.token }}{{- end }}
        response:
            cel: >-
              statusCode == 200 && bodyJSON.valid == true
```

### 代理使用说明

SonarQube Scanner 使用代理时存在特殊性。

- 正向代理：sonarqube scanner 支持通过 `sonar.scanner.proxyHost` 和 `sonar.scanner.proxyPort` 配置正向代理。但是发起请求时会行发送一次不带认证请求，然后在发起一次代 Proxy Auth 的请求。 修改：需要调整正代逻辑，不允许没有认证的代理通过。
  * 优点：配置简单，符合大多数用户习惯。
  * 缺点：每个请求都需要发起两次请求，增加延迟和负载。
  
- 反向代理：反向代理使用 token 认证时，sonarqube scanner 在处理过程中，部分请求是通过 Bearer Token 传递的，但是部分请求会将 token basic 编码，然后通过 Basic Auth 传递。 如果我们使用反向代理集成 scanner 需要适配这个认证方式。
  * 优点：每个请求只发起一次请求，性能更好。
  * 缺点：实现复杂，需要调整框架适配多种认证方式；用户日志对用户不透明，增加排查难度。
  
正代处理流程更为清晰，虽然每个请求会发送两次，上传 sonar 报告调用的API 基本是恒定的（获取版本，下载解析jar，上传报告），不会造成性能瓶颈。

综合考虑采用正向代理方式集成 SonarQube Scanner.

### 配置文件说明

SonarQube Connector 主要支持用户通过各种 scanner 完成代码质量分析和报告生成工作，以及SonarQube 的 API 调用（不需要配置文件）。

SonarQube 提供了多种 scanner 工具，例如 SonarQube Scanner CLI、SonarQube Scanner for Maven、SonarQube Scanner for Gradle 等。

部分 scanner 有单独的配置文件（如 scanner cli 的 sonar-scanner.properties 和 sonar-project.properties）,部分 scanner 是以插件形式集成代开发工具当中（如 Maven 和 Gradle）。

| Scanner 类型 | 配置文件名称 | 格式 |
|------------|------------|------|
| **SonarScanner CLI** | `sonar-project.properties` | Java Properties 格式 |
| **Python Scanner** | `pyproject.toml` 或 `sonar-project.properties` | TOML 或 Properties |
| **Maven** | `pom.xml` | Maven XML |
| **Gradle** | `build.gradle` 或 `build.gradle.kts` | Groovy/Kotlin DSL |
| **Azure DevOps** | Pipeline YAML | YAML |

整体上对于 sonar，在流水线的实践中，SonarQube Scanner CLI 使用最为广泛，因此 SonarQube Connector 主要支持 `sonar-project.properties` 配置文件的生成和挂载。

SonarScanner CLI 配置文件：
- 默认位置：项目根目录的 sonar-project.properties
- 系统配置：<scanner-home>/conf/sonar-project.properties

优先级：

1. CLI 命令行参数 (-Dsonar.token=xxx) 
2. 单个环境变量 (SONAR_TOKEN, SONAR_HOST_URL 等)
3. 通用环境变量 (SONAR_SCANNER_JSON_PARAMS)
4. 项目级配置 sonar-project.properties 文件
5. 系统级配置 sonar-scanner.properties

SonarQube Connector 生成的需要挂载的配置文件，挂载路径用户可以自行指定，如： `~/.sonar/sonar-project.properties`。

## 使用connector挂载

用户可以通过挂载 SonarQube Connector 提供的配置文件 `sonar-project.properties` 来使用 SonarQube Connector。

示例：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sonar-scanner-pod
spec:
  containers:
  - name: sonar-scanner
    image: sonarsource/sonar-scanner-cli:latest
    command: ["sonar-scanner"]
    volumeMounts:
    - name: sonar-scanner-config
      mountPath: /root/.sonar/sonar-project.properties
      subPath: sonar-project.properties
  volumes:
  - name: sonar-scanner-config
    csi:
      readOnly: true
      driver: connectors-csi
      volumeAttributes:
        connector.name: "sonarqube-connector"
```

## 流水线 Task 使用 SonarQube Connector

目前 Tekton 支持的 [SonarQube Scanner Task](https://tekton-hub.alauda.cn/catalog/task/sonarqube-scanner) 有 `SonarQube Scanner`, 支持 workspace: `sonar-settings: Optional workspace where SonarQube properties can be mounted`

可以将 SonarQube Connector config 挂载到 `sonar-settings` workspace 中。

task 会自动将 workspace 中的 `sonar-project.properties` 文件内容合并到扫描配置中。

```bash
# Merge properties from workspace
if [[ -f ${ws_props_file} ]]; then
  say "Merging properties from sonar-settings workspace"
  properties=($(getPropertiesFromFile "${ws_props_file}"))
  writePropertiesBatch "${properties[@]}"
fi
```
