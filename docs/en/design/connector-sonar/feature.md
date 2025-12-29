# SonarQube Connector

## 概述

用户可以通过 SonarQube Connector  在 Kubernetes 集群中以 SecretLess 的形式完成对 SonarQube 的一些操作。

## 核心能力

### 功能需求清单

1. 用户能够通过 API, UI 的形式，在集群中接入 SonarQube，从而在 K8S Workload (Job, Tekton Pipeline 等)  中, 将分析结果推送到 SonarQube 服务器。
2. 用户能够通过 API, UI 的形式，在集群中接入 SonarQube，从而在 K8S Workload 中, 调用 SonarQube 的 REST API 完成代码质量相关操作。

## 功能设计

### 前提条件

- 部署 Connectors-Operator
- 安装 ConnectorsCore 和 ConnectorsSonarQube 组件.

## 创建 SonarQube Connector

按照以下操作流程，完成 SonarQube Connector 的创建，并且 SonarQube Connector 的状态为 Ready 状态。

### UI 创建 SonarQube Connector

前提：需要在对应集群安装 connectors-operator, connectors-core 以及 connectors-sonarqube 组件。

1. 点击 创建 Connector 按钮, 选择 SonarQube 类型。
2. 输入 SonarQube 的地址， 例如 `https://sonarqube.example.com`
3. 输入 SonarQube 的凭据， 可选。
    - 凭据支持 Token 认证。
    - 能够正常完成 Token 的校验
4. 点击提交，完成创建。

### Yaml 创建 SonarQube Connector

通过以下 yaml 完成创建：

```yaml
---
apiVersion: v1
data:
  token: <base64 string>
kind: Secret
metadata:
  name: sonarqube-secret
type: connectors.cpaas.io/bearer-token
---
apiVersion: operator.connectors.alauda.io/v1alpha1
kind: Connector
metadata:
  name: sonarqube-connector
spec:
  connectorClassName: sonarqube
  address: https://sonarqube.example.com
  auth:
    name: tokenAuth
    secretRef:
      name: sonarqube-secret
```

### User Story 1: 用户能够通过 API, UI 的形式，在集群中接入 SonarQube，从而在 K8S Workload (Job, Tekton Pipeline 等)  中, 将分析结果推送到 SonarQube 服务器

描述：作为平台用户，我希望以无密钥（SecretLess）的方式在 Kubernetes 中将sonar 分析结果上传到 SonarQube 服务器，从而避免在工作负载中直接暴露 SonarQube 凭据。

#### 前置条件

- 已安装 Connectors Operator、ConnectorsCore 与 ConnectorsSonarQube 组件。
- 已具备可用的 SonarQube 地址与凭据（若目标仓库匿名可读，可不配置凭据）。

#### 操作步骤

1. 创建命名空间（示例）：

    ```bash
    kubectl create ns connectors-sonarqube-demo
    ```

2. （可选）创建凭据与 Connector（示例）：

    ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: sonarqube-secret
   type: connectors.cpaas.io/bearer-token
   stringData:
     token: "<YOUR_SONARQUBE_TOKEN>"
   ---
   apiVersion: connectors.alauda.io/v1alpha1
   kind: Connector
   metadata:
     name: sonarqube-connector
   spec:
     connectorClassName: sonarqube
     address: https://sonarqube.example.com
     auth:
       name: tokenAuth
       secretRef:
         name: sonarqube-secret
   ```

3. 创建执行 sonarscanner 的 Job，并通过 CSI 挂载 `sonar-scanner.properties` 配置：

    ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: sonarqube-scanner
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: sonarqube-scanner
           image: sonarsource/sonar-scanner-cli:latest
           command: ["sh","-c"]
           args:
           - |
              cd /root/src
              sonar-scanner -X \
                -Dsonar.projectKey=test-project \
                -Dsonar.sources=.
           volumeMounts:
           - name: sonar-scanner-properties
             mountPath: /root/.sonar/sonar-scanner.properties
             subPath: sonar-scanner.properties
         volumes:
         - name: sonar-scanner-properties
           csi:
             readOnly: true
             driver: connectors-csi
             volumeAttributes:
               connector.name: "sonarqube-connector"
               configuration.names: "sonar-scanner"
   ```

#### 关键点说明

- 通过 `connectors-csi` 驱动挂载 `sonar-scanner.properties`，内容由 SonarQube ConnectorClass 模板生成，其中已配置代理与认证参数，无需在容器内直接配置凭据。

#### 验收标准

- `Connector` 资源 `READY=True`，`status.proxy.httpAddress` 已就绪。
- `Job` 成功完成，能够在 Sonarqube 查询到上传的分析结果。

### User Story 2: 用户能够通过 API, UI 的形式，在集群中接入 SonarQube，从而在 K8S Workload 中, 调用 SonarQube 的 REST API 完成代码质量相关操作

#### 前置条件

参考 User Story 1 的前置条件

#### 操作步骤

参考 User Story 1 的操作步骤，创建 Job 时，修改容器命令为调用 SonarQube REST API，例如查询项目列表：

```yaml
    ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: sonarqube-scanner
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: sonarqube-scanner
           image: sonarsource/sonar-scanner-cli:latest
           command: ["sh","-c"]
           args:
           - |
              source /root/.sonar/.env
              curl -X GET http://sonarqube.com/api/projects/search"
              {
                "paging": {
                  "pageIndex": 1,
                  "pageSize": 100,
                  "total": 2
                },
                "components": [
                  {
                    "key": "test-local",
                    "name": "test-local",
                    "qualifier": "TRK",
                    "visibility": "public",
                    "lastAnalysisDate": "2025-12-22T11:35:04+0000",
                    "managed": false
                  },
                  {
                    "key": "test-project",
                    "name": "Test Project",
                    "qualifier": "TRK",
                    "visibility": "public",
                    "lastAnalysisDate": "2025-12-22T11:38:07+0000",
                    "managed": false
                  }
                ]
              }
           volumeMounts:
           - name: sonar-scanner-properties
             mountPath: /root/.sonar/sonar-scanner.properties
             subPath: sonar-scanner.properties
         volumes:
         - name: sonar-scanner-properties
           csi:
             readOnly: true
             driver: connectors-csi
             volumeAttributes:
               connector.name: "sonarqube-connector"
               configuration.names: "sonar-scanner"
   ```

### 非功能需求清单

#### 升级需求说明

- 系统升级后， ConnectorsSonarQube 组件能够平滑升级
- 系统升级后，用户存量的 SonarQube Connector 资源状态正常，使用存量 SonarQube Connector 创建的 K8S Workload 能够正常运行。

#### 安全需求说明

- 用户进入到运行的 k8s workload 中，无法获取原始的 SonarQube 凭据。
- k8s workload 中的中间凭据，应具有有效期，在有效期过期后，该凭据无法使用。
- 在 k8s workload 中，用户应当仅能挂载自己有权限访问的 Connector.

#### 兼容性需求说明

- 参考升级需求说明，存量的 SonarQube Connector 资源状态以及使用正常，用户无需做资源变更。

