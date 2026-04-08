# Harbor Connector Secret Rotation Task

## GOAL

- 提供一个 Harbor CLI Task, 使用 `harbor-cli` 完成如下内容
  - 根据用户指定的 Robot Account 名称，调用 harbor-cli 刷新
  - 根据用户指定的 Connector， 刷新其 Secret 内容
  - 刷新用户指定的 ImagePullSecret 的内容

## 使用体验

**前置准备**:

- 管理员准备一个 私有的 namespace, 例如: connectors-management
- 在 ns 中，创建一个高权限的 harbor & k8s connector， 通过 AccessPolicy 限定只有特定 sa 能使用该 connector
- 在 ns 中，准备一个 sa， 授予 Connectors 和 Secret 的创建和更新权限

**凭据刷新**

配置一个定时任务, 定期触发刷新 harbor secret token 的 Task

## Task 设计

**Step1**: 

- 目标: 调用 harbor-cli , 刷新 Harbor Robot Account
- Image: harbor-cli 镜像
- 逻辑:
  - 根据指定的 robot account 名称，调用 harbor-cli 刷新 token
  - 将刷新后的 token 写入到 tmpfs

**Step2**:

- 目标: 更新 Connector Secret，更新 ImagePullSecrets
- Image: kubectl 镜像
- 逻辑:
  - 读取 token, 更新指定的 Connector 关联的 Secret 内容
  - 根据指定的 Image Pull Secrets, 获取 harbor config.yaml 中的地址， 构建 secret， 进行更新。

**Task 参数**: 

- connector: 字符串， 必填 
  - 字段含义: 目标要刷新的 secret connector
  - 字段格式: <ns>/<connector-name>
- robot account: 字符串， 必填 
  - harbor 上 robot account 的名称
- imagePullSecrets: 数组，非必填。
  - 字段含义: 要刷新哪些 namespace 中的 image pull secret. secret 内容来自 robot account 的 secret 值。
  - 值格式: <namespace>/<name>
  - 为空时，不刷新任何 imagePullSecrets
- verbose: bool 字符串, 默认为 false
  - 字段含义: 当为 true 时， 执行过程输出详细信息
- image: 字符串， 不能为空
  - 字段含义: harbor-cli 的镜像地址


**Task Workspace**
  - harbor-config: harbor 配置
  - kube-config: 目标集群
