# NPM Connector

## 概述

用户可以通过 NPM Connector  在 Kubernetes 集群中以 SecretLess 的形式完成对 NPM Registry 的一些操作。

## 核心能力

### 功能需求清单

1. 用户能够通过 API, UI 的形式，在集群中接入 NPM Registry，从而在 K8S Workload (Job, Tekton Pipeline 等)  中, 从该 NPM Registry 中下载依赖。
2. 用户能够通过 API, UI 的形式，在集群中接入 NPM Registry，从而在 K8S Workload (Job, Tekton Pipeline 等)  中, 发布制品到 Maven Registry。

## 功能设计

### 前提条件

- 部署 Connectors-Operator
- 安装 ConnectorsCore 和 ConnectorsNPM 组件.
- 使用的 NPM Registry 具备发布和下载的能力

## 创建 NPM Connector

按照以下操作流程，完成 NPM Connector 的创建，并且 NPM Connector 的状态为 Ready 状态。

### UI 创建 NPM Connector

前提：需要在global 安装 ConnectorsCore，并部署 UI 组件

```yaml
apiVersion: operator.connectors.alauda.io/v1alpha1
kind: ConnectorsCore
metadata:
  name: connectors-core
spec:
    additionalManifests: /kodata/ui/frontend.yaml
```

1. 访问平台页面：`http://<platform-url>/console-connectors-plugin/`
2. 点击 创建 Connector 按钮, 选择 NPM 类型。
3. 输入 NPM Registry 的地址， 例如 `https://registry.npmjs.org`
4. 输入 NPM Registry 的凭据， 可选。
    - 凭据支持用户名密码。
    - 能够正常完成用户名密码的校验
5. 点击提交，完成创建。

### Yaml 创建 NPM Connector

通过以下 yaml 完成创建：

```yaml
---
apiVersion: v1
data:
  password: <base64 string>
  username: <base64 string>
kind: Secret
metadata:
  name: npm-secret
type: kubernetes.io/basic-auth
---
apiVersion: operator.connectors.alauda.io/v1alpha1
kind: Connector
metadata:
  name: npm-connector
spec:
  connectorClassName: npm
  address: https://private-nexus.alaudatech.net/repository/maven-public
  auth:
    name: basicAuth
    secretRef:
      name: npm-secret
```

### User Story 1: 用户能够通过 API, UI 的形式，在集群中接入 NPM Registry，从而在 K8S Workload (Job, Tekton Pipeline 等)  中, 从该 NPM Registry 中下载依赖

描述：作为平台用户，我希望以无密钥（SecretLess）的方式在 Kubernetes 中执行 `npm install`，从而避免在工作负载中直接暴露 NPM Registry 凭据。

#### 前置条件
- 已安装 Connectors Operator、ConnectorsCore 与 ConnectorsNPM 组件。
- 已具备可用的 NPM Registry 地址与凭据（若目标仓库匿名可读，可不配置凭据）。

#### 操作步骤

1. 创建命名空间（示例）：

    ```bash
    kubectl create ns connectors-npm-demo
    ```

2. （可选）创建凭据与 Connector（示例）：

    ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: npm-registry-secret
   type: kubernetes.io/basic-auth
   stringData:
     username: <your-username>
     password: <your-password>
   ---
   apiVersion: connectors.alauda.io/v1alpha1
   kind: Connector
   metadata:
     name: npm-connector
   spec:
     connectorClassName: npm
     address: https://nexus.example.com/repository/npm
     auth:
       name: basicAuth
       secretRef:
         name: npm-registry-secret
   ```

3. 创建执行 `npm install` 的 Job，并通过 CSI 挂载 `.npmrc` 配置：

    ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: npm-install
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: npm-demo
           image: node:latest
           command: ["sh","-c"]
           args:
           - |
             set -ex
             git clone --depth 1 https://github.com/kycheng/demo-npm-publish-slack-notifier.git npmdemo
             cd npmdemo
             npm install --verbose
           volumeMounts:
           - name: npmrc
             mountPath: /root/.npmrc
             subPath: .npmrc
         volumes:
         - name: npmrc
           csi:
             readOnly: true
             driver: connectors-csi
             volumeAttributes:
               connector.name: "npm-connector"
               configuration.names: "npmrc"
   ```

#### 关键点说明

- 通过 `connectors-csi` 驱动挂载 `.npmrc`，内容由 NPM ConnectorClass 模板生成，其中已配置代理与认证参数，无需在容器内直接配置凭据。
- 若使用 Yarn，需设置 `NODE_EXTRA_CA_CERTS` 以信任代理证书。

#### 验收标准

- `Connector` 资源 `READY=True`，`status.proxy.httpAddress` 已就绪。
- `Job` 成功完成，日志包含从目标仓库拉取包的 HTTP 访问记录与 `npm info ok`、或 `added <N> packages` 等成功信息。

### User Story 2: 用户能够通过 API, UI 的形式，在集群中接入 NPM Registry，从而在 K8S Workload (Job, Tekton Pipeline 等)  中, 发布制品到 NPM Registry

描述：作为平台用户，我希望在 Kubernetes 中以无密钥（SecretLess）的方式执行 `npm publish`，安全地将包发布到指定的 NPM Registry。

#### 前置条件

- 与 User Story 1 相同，目标 NPM Registry 需支持发布操作。

#### 操作步骤

1. 复用或创建可用的 `Connector`（见 User Story 1 第 2 步）。
2. 创建执行 `npm publish` 的 Job，并通过 CSI 挂载 `.npmrc`（Yarn 可另行挂载 `.yarnrc.yml`）：

    ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: npm-publish
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: npm-publish
           image: node:latest
           command: ["sh","-c"]
           args:
           - |
             set -ex
             git clone --depth 1 https://github.com/kycheng/demo-npm-publish-slack-notifier.git npmdemo
             cd npmdemo
             npm publish --verbose
           volumeMounts:
           - name: npmrc
             mountPath: /root/.npmrc
             subPath: .npmrc
         volumes:
         - name: npmrc
           csi:
             readOnly: true
             driver: connectors-csi
             volumeAttributes:
               connector.name: "npm-connector"
               configuration.names: "npmrc"
   ```

#### 关键点说明

- `.npmrc`/`.yarnrc.yml` 中的代理地址与 token 由 NPM Connector 提供，代理会在转发请求至后端 Registry 时自动注入认证。
- 使用 Yarn 发布时，需通过 `NODE_EXTRA_CA_CERTS` 指定证书路径以建立 TLS 信任。

#### 验收标准

- `Connector` 资源 `READY=True`。
- `Job` 日志出现 `npm publish --verbose` 且包含成功发布记录，例如 `Publishing to <registry> with tag ...`、`+ <pkg>@<version>`，退出码为 0。

### 非功能需求清单

#### 升级需求说明

- 系统升级后， ConnectorsNPM 组件能够平滑升级
- 系统升级后，用户存量的 NPM Connector 资源状态正常，使用存量 NPM Connector 创建的 K8S Workload 能够正常运行。

#### 安全需求说明

- 用户进入到运行的 k8s workload 中，无法获取原始的 NPM Registry 凭据。
- k8s workload 中的中间凭据，应具有有效期，在有效期过期后，该凭据无法使用。
- 在 k8s workload 中，用户应当仅能挂载自己有权限访问的 Connector.

#### 兼容性需求说明

- 参考升级需求说明，存量的 NPM Connector 资源状态以及使用正常，用户无需做资源变更。

## 补充说明

### 局限

1. 当 NPM Registry 只能进行推送或者拉取时，无法在同一个 Job 中完成推送和拉取，需要分成两个步骤挂载不同的Connector完成。
2. 使用 Yarn 工具链接 HTTPS NPM Registry 时，需要单独配置 NODE_EXTRA_CA_CERTS 指定根证书，完成客户端与 Connector Proxy 的 TLS Tunnel 建立。
3. Connector 目前的配置为全局仓库，没有限定到具体的 scope。
