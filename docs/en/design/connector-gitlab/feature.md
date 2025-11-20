# GitLab Connector Requirements

## Overview

用户可以通过 GitLab Connector 在 Kubernetes 集群中以 SecretLess 的形式完成对 GitLab 的一些操作。

GitLab Connector 基于 Connector 框架实现，提供了与 GitLab 平台集成的能力，支持通过 Git CLI 和 GitLab CLI 以及 其他自定义的 CLI 进行 secretless 操作，同时提供 API 能力以支持 UI 客户端的资源浏览和选择。

## Core Concepts

### GitLab Connector 的核心能力

GitLab Connector 作为面向特定工具的 ConnectorClass，提供了以下 GitLab 特定的能力：

- **认证方式**：支持 Private Access Token (PAT) 认证，用于访问 GitLab API 和执行 Git 操作
- **配置能力**：
  - 提供 `gitconfig` 配置，使 Git CLI 能够以 secretless 方式访问 GitLab 仓库
  - 提供 `gitlabconfig` 配置，使 GitLab CLI 能够以 secretless 方式访问 GitLab API
- **API 能力**：提供 Group List、Repository List、Revision List（Branches、Tags、MergeRequests）等 API，支持 UI 客户端的动态表单和资源选择
- **Proxy 能力**：通过反向代理，使 Git CLI、GitLab CLI 以及其他自定义 CLI 能够以 secretless 方式访问 GitLab

## Requirements

### 功能需求清单

基于用户故事和验收标准，GitLab Connector 需要满足以下功能需求：

1. **Connector 创建和管理**：用户可以创建 GitLab Connector，并满足 Connector 定义的基本能力（工具访问检查、认证检查、配置能力）

2. **Secretless 操作支持**：在 K8S Workload / Pipeline 中，能够使用 GitLab Connector 以 secretless 形式进行 GitLab 相关操作，包括：
   - Git 操作：通过 Git CLI 完成 git clone 等相关操作
   - GitLab CLI 操作：通过 GitLab CLI 进行 GitLab 操作（如列出项目、创建 issue 等）
   - 自定义 CLI 操作：支持其他自定义 CLI 工具访问 GitLab
   所有操作均无需在工作负载中直接配置 GitLab 凭据

3. **UI 资源浏览和选择**：GitLab Connector 可提供 Group API List、Repository API List、Revision List（Branches、Tags、MergeRequests）等 API，使得以 Pipeline 为例的 UI 客户端可以使用 Connector 这些 API，完成 GitLab 资源的下拉展示和选择

### 认证需求

- 支持无认证访问，支持匿名访问 GitLab 实例
- 支持 Private Access Token (PAT) 认证方式
- 支持认证检查，验证 PAT 的有效性和权限

### 配置需求

- 提供 `gitconfig` 配置，用于 Git CLI 的 secretless 访问
- 提供 `gitlabconfig` 配置，用于 GitLab CLI 的 secretless 访问
- 配置应支持通过 CSI Driver 挂载到 Pod 中

### Proxy 需求

- 支持反向代理模式，使 Git CLI、GitLab CLI 以及其他自定义 CLI 工具能够以 secretless 方式访问 GitLab
- Proxy 服务支持 Bearer Token 认证方式，支持通过 Proxy 访问工具原始 API

### API 与 UI 需求 （API 列表待定）

- 提供 Group List API，支持列出用户可见的 Groups（包括 subgroups）, 支持搜索和分页功能
- 提供 Repository List API，支持列出用户可见的 Projects（包括 subgroup 内的项目）, 支持搜索和分页功能
- 提供 Revision List API，支持列出 Branches、Tags 和 MergeRequests, 支持搜索和分页功能
- 支持在 以 Pipeline 为例的 UI 客户端中使用如上 API，完成相应 UI 控件的展示和资源下拉。

### 前提条件

- 部署 Connectors-Operator
- 安装 ConnectorsCore 和 ConnectorsGitLab 组件
- 使用的 GitLab 实例具备 API 访问能力
- 已具备可用的 GitLab PAT token（若目标仓库匿名可读，可不配置凭据）

## Usage Scenarios

### 创建 GitLab Connector

按照以下操作流程，完成 GitLab Connector 的创建，并且 GitLab Connector 的状态为 Ready 状态。

#### UI 创建 GitLab Connector

前提：需要在集群安装 ConnectorsCore

1. 访问平台页面：`http://<platform-url>/console-connectors-plugin/`
2. 点击创建 Connector 按钮，选择 GitLab 类型
3. 输入 GitLab 实例的地址，例如 `https://gitlab.example.com`
4. 输入 GitLab 的凭据：
   - 凭据支持 Private Access Token (PAT)
   - 能够正常完成 PAT 的校验
5. （可选）配置认证检查参数，例如指定用于测试的 repository 路径
6. 点击提交，完成创建

#### YAML 创建 GitLab Connector

在指定的命名空间中，创建 Secret 和 Connector 资源完成创建（具体 YAML 配置以最终开发设计为准）。

### User Story 1: Git Clone 操作

描述：作为平台用户，我希望以无密钥（SecretLess）的方式在 Kubernetes 中执行 `git clone`，从而避免在工作负载中直接暴露 GitLab 凭据。

#### 前置条件

- 已安装 Connectors Operator、ConnectorsCore 与 ConnectorsGitLab 组件
- 已具备可用的 GitLab 实例地址与 PAT token（若目标仓库匿名可读，可不配置凭据）

#### 操作步骤

1. 在指定的命名空间中，（可选）创建凭据与 GitLab Connector

2. 在指定的命名空间中，创建执行 `git clone` 的 Job，并通过 CSI 挂载 Connector 和 `gitconfig` 配置

#### 验收标准

- `Connector` 资源 `READY=True`
- `Job` 成功完成，日志包含成功克隆仓库的记录，能够正常执行 `git log` 等操作
- 工作负载中不包含 GitLab 原始凭据

### User Story 2: GitLab CLI 操作

描述：作为平台用户，我希望在 Kubernetes 中以无密钥（SecretLess）的方式使用 GitLab CLI 进行 GitLab 操作，安全地管理 GitLab 资源。

#### 前置条件

- 与 User Story 1 相同，目标 GitLab 实例需支持 API 访问
- GitLab CLI 工具已安装在容器镜像中，或通过其他方式可用

#### 操作步骤

1. 在指定的命名空间中，复用或创建可用的 GitLab Connector

2. 在指定的命名空间中，创建执行 GitLab CLI 操作的 Job，通过 CSI 挂载 Connector 和 `gitlabconfig` 配置

#### 验收标准

- `Connector` 资源 `READY=True`
- `Job` 日志显示 GitLab CLI 命令成功执行，能够正常列出 projects、issues 等资源
- 工作负载中不包含 GitLab 原始凭据

### User Story 3: 自定义 CLI 操作

描述：作为平台用户，我希望在 Kubernetes 中以无密钥（SecretLess）的方式使用自定义 CLI 工具进行 GitLab 操作，安全地管理 GitLab 资源。

#### 前置条件

- 与 User Story 1 相同，目标 GitLab 实例需支持 API 访问
- 自定义 CLI 工具已安装在容器镜像中，或通过其他方式可用

#### 操作步骤

说明: 以 reviewdog CLI 为例

1. 在指定的命名空间中，复用或创建可用的 GitLab Connector

2. 在指定的命名空间中，创建执行 reviewdog CLI 操作的 Job，通过 CSI 挂载 Connector 和 配置 （具体配置名称，以技术方案为准）

#### 验收标准

- `Connector` 资源 `READY=True`
- `Job` 日志显示 reviewdog CLI 命令成功执行，能够正常在 GitLab MR 中创建评论
- 工作负载中不包含 GitLab 原始凭据
- 用户参考文档，能够了解其他自定义 CLI 工具，如何以 Secretless 的方式访问 GitLab

### User Story 4: UI 资源浏览和选择

描述：作为平台用户，我希望在 Pipeline 配置界面中，通过下拉选择的方式选择 GitLab 的 Group、Repository 和 Revision，而不需要手动输入路径。

#### 前置条件

- 已创建可用的 GitLab Connector
- UI 客户端已集成 Connector API 调用能力

#### 操作步骤

1. 在 Pipeline 配置界面中，选择使用 GitLab Connector 作为代码源

2. UI 客户端调用 GitLab Connector 的 API：
   - **认证信息**: 使用 ACP Token 或者 当前 集群的 K8S Token
   - **选择 Group**：调用 Group List API，展示 Group 下拉列表
   - **选择 Repository**：调用 Repository List API，展示 Repository 下拉列表
   - **选择 Revision**：根据选中的 Repository，调用相应的 Revision List API（Branches、Tags 或 MergeRequests）

3. 用户从下拉列表中选择资源，UI 自动填充到 Pipeline 配置中

#### 验收标准

- UI 能够正常调用 GitLab Connector 的 API, API 返回和 GitLab 一致的数据。
- 下拉列表能够正确展示 Group、Repository 和 Revision
- 用户选择资源后，Pipeline 配置能够正确填充
- 支持搜索和分页功能，能够快速找到目标资源，提升用户体验

## Error Handling and Edge Cases

### GitLab API 调用失败

**场景**：GitLab API 调用失败或超时

**可能原因**：
- GitLab 实例网络不可达
- GitLab 实例服务异常
- API 请求超时
- GitLab API rate limit 限制

**处理方式**：
- 系统应显示清晰的错误信息，指明是 GitLab API 调用失败
- UI 客户端应提供手动输入的回退方案

**恢复**：等待 GitLab 服务恢复或解决网络问题后，系统自动重试

### GitLab PAT Token 权限不足

**场景**：PAT token 权限不足，无法访问某些资源

**可能原因**：
- PAT token 的 scope 不足
- PAT token 所属用户对目标资源没有访问权限
- PAT token 已过期或被撤销

**处理方式**：
- 当访问特定资源失败时，应显示明确的权限错误信息

**恢复**：用户更新 PAT token 后自动恢复

### GitLab 资源不存在或不可访问

**场景**：用户选择的 Group、Repository 或 Revision 不存在或当前用户无权限访问

**可能原因**：
- 资源已被删除
- 用户权限变更，失去访问权限
- 资源路径输入错误

**处理方式**：
- API 调用应返回明确的错误信息（404 Not Found 或 403 Forbidden）
- UI 客户端应显示友好的错误提示

**恢复**：用户使用有效的资源自动恢复

## Non-Functional Requirements

### 升级需求说明

- 系统升级后，ConnectorsGitLab 组件能够平滑升级
- 系统升级后，用户存量的 GitLab Connector 资源状态正常，使用存量 GitLab Connector 创建的 K8S Workload 能够正常运行

### 安全需求说明

- 用户进入到运行的 k8s workload 中，无法获取原始的 GitLab PAT token
- k8s workload 中的中间凭据（如 Proxy token），应具有有效期，在有效期过期后，该凭据无法使用
- 在 k8s workload 中，用户应当仅能挂载自己有权限访问的 Connector
- PAT token 应存储在 Kubernetes Secret 中

### 兼容性需求说明

- 参考升级需求说明，存量的 GitLab Connector 资源状态以及使用正常，用户无需做资源变更
- GitLab Connector 应兼容不同版本的 GitLab 实例（GitLab CE 和 GitLab EE）

## Future Considerations

:::note
以下内容尚未实现，属于未来计划。
:::

### OAuth2 认证支持

GitLab Connector 计划支持 OAuth2 认证方式，以提供更灵活的认证选项。

**框架支持**：
- Connector 框架将提供 OAuth2 认证的开箱支持
- 支持 OAuth2 token 的获取、刷新和管理

**GitLab ConnectorClass 实现**：
- GitLab ConnectorClass 将实现 OAuth2 认证类型
- 支持 GitLab 的 OAuth2 流程
- 提供 OAuth2 token 的自动刷新机制

## Limitations and Considerations

### 已知局限

1. **API Rate Limit**：GitLab API 存在 rate limit 限制，当 API 调用频繁时可能触发限制。在使用 GitLab Connector 的 API 功能时，需要合理控制调用频率，避免触发 rate limit。 (文档中说明)

### 注意事项

1. **PAT Token 权限**：创建 PAT token 时，需要确保具有足够的 scope（如 `api`、`read_repository`、`write_repository` 等）。建议在相关文档中明确说明不同使用场景所需的 PAT token scope。

2. **Subgroup 支持**：GitLab API 需要支持列出 subgroup 内的资源。由于 GitLab API 在请求路径中对 subgroup 有特殊要求，实现时需要进行相应的路径处理。
