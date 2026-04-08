# Harbor Connector Automatic Creating Task

## Goal

提供 TektonCD Task, 使用 `harbor-cli` 二进制 完成如下内容
  - 在 Harbor 上创建，Harbor Project，Robot Account 创建； 
  - 集群中创建 Secret， Connector；
  - 集群的目标 NS 中，创建 imagePullSecrets

## Story

**前置准备**:

- 管理员准备一个 私有的 namespace, 例如: connectors-management
- 在 ns 中，创建一个高权限的 harbor & k8s connector， 通过 AccessPolicy 限定只有特定 sa 能使用该 connector
- 在 ns 中，准备一个 sa， 授予 Connectors 和 Secret 的创建和更新权限

### Story 1

**项目级共享仓库初始化**

- 当平台新建一个 ACP Project 时，管理员触发该 Task。
- Task 在 Harbor 中创建项目级 Harbor Project。
- Task 创建对应的 Robot Account，并授予项目级共享所需权限。
- Task 在集群中创建 Secret、Harbor Connector，并按需下发到多个 namespace 的 `imagePullSecrets`。

适用场景：同一 ACP Project 下多个 namespace 共享一组 Harbor 资源。

### Story 2

**namespace 级独立仓库初始化**

- 当某个 namespace 需要独立 Harbor 资源时，管理员触发该 Task。
- Task 为该 namespace 创建独立 Harbor Project。
- Task 创建仅面向该 namespace 使用的 Robot Account。
- Task 在对应 namespace 或指定管理 namespace 中创建 Secret、Connector，并只向目标 namespace 分发 `imagePullSecrets`。

适用场景：不同 namespace 之间需要严格隔离镜像资源和凭据。

### Story 3

**批量初始化多个 Harbor Project**

- 管理员一次传入多个 Harbor Project 和不同 Project 的权限配置。
- Task 统一创建或更新这些 Harbor Project，并创建一个可访问这些 Project 的 Robot Account。
- Task 基于返回 token 统一生成 Secret、Connector 和目标 `imagePullSecrets`。

适用场景: 项目下的不同 NS， 需要有自己独立的镜像仓库， 也有一个项目共享的仓库。

## Task 设计

**Step1**: 

- 目标: 创建 Harbor Projects, 创建 RobotAccounts, 保存 robot account token 信息。
- Image: harbor-cli 镜像， 构建 harbor-cli 镜像，包含一些使用到的脚本。
- 核心逻辑
  - 创建 harbor projects， 忽略已存在.
  - 创建 harbor robot account，配置为指定的 projects，每个 project 权限为指定索引配置的 permission . 
    - robot account 不存在时，创建，获取 返回的 Token
    - 存在时进行更新,刷新 Token
  - 返回 harbor robot account 的token 存储在内存文件中。（tmpfs）

**Step2**: 

- 目标: 在集群中，创建 Secret, 创建 Connector, 创建 ImagePullSecret
- Image: 复用已有的 kubectl 镜像
- 核心逻辑
  - 根据 robot account token 在目标集群创建 secret 
  - 根据 harbor 地址和 secret 创建 connector.
  - 根据 robot account token 在目标集群创建 imagePullSecrets

**Task Params**

- connector: 字符串，必填。
  - 字段含义： 在集群中创建的 connector 名称
  - 格式: <ns>/<name>
- secret: 字符串，非必填。
  - 字段含义: 在集群中创建的 secret 名称， 作为 connectors 的 secret 存在。 
  - 格式: <ns>/<name>
  - 为空时， 默认为 <connector-ns>/<connector-name>

- harbor projects: 数组。必填。
  - 字段含义: 目标 harbor project 名称列表
- robot account: 字符串，非必填。
  - 字段含义: 目标创建的 robot account 名称。 
  - 为空时， 默认为 connector-<connector-ns>-<connector-name>
- permissions: 数组，不能为空。
  - 字段含义: 依靠索引和 projects 对齐，表示不同 harbor project 的权限配置。
  - 值格式：<resource>:<verbs>
  - resource 为 harbor 权限中的资源名称， 和 harbor api 对齐。
  - verbs 为harbor 权限中的动作名称，多个使用逗号分割, 和 harbor api 对齐。 
- imagePullSecrets: 数组，非必填。
  - 字段含义: 要在哪些 namespace 中生成 image pull secret. secret 内容来自 robot account 的 secret 值。
  - 值格式: <namespace>/<name>
  - 为空时，不创建任何 imagePullSecrets
- verbose: bool 字符串, 默认为 false
  - 字段含义: 当为 true 时， 执行过程输出详细信息
- image: 字符串， 不能为空
  - 字段含义: harbor-cli 的镜像地址

**Task Workspace**

- harbor-config: harbor 的配置
- kube-config: 目标集群
