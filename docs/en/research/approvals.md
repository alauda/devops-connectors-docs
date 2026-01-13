# Connector Approvals & Checks 产品调研

## Azure DevOps Service Connections 的 Approvals & Checks

### 概述

Azure DevOps 提供了以资源为粒度的 "Approvals & checks（审批与检查）" 框架，可附加到 Service connections、Environments、Repositories、Variable groups、Secure files、Agent pools 等流水线资源上。该框架允许资源所有者配置多种检查，在消费该资源的流水线 stage 开始执行之前必须满足所有检查。若任一检查被最终拒绝或超时，相关 stage 将被跳过或标记为失败。

### 内置检查类型

| 类型 | 分类 | 说明 |
|------|------|------|
| **Branch control** | 静态检查 | 分支控制，限制只允许特定分支触发 |
| **Required template** | 静态检查 | 必需模板，强制流水线使用指定模板 |
| **Approvals** | 动态检查 | 人工审批，指定用户/组为审批者，可设置说明、是否允许自审批、超时等 |
| **Business hours** | 动态检查 | 时间窗口控制，配置允许执行的时间段，流水线在窗口外会等待 |
| **Invoke Azure Function** | 动态检查 | 调用 Azure Function 以判断是否放行，支持轮询/重试 |
| **Invoke REST API** | 动态检查 | 调用外部 REST API 以判断是否放行，支持轮询/回调 |
| **Query Azure Monitor** | 动态检查 | 在评估期间确保未触发告警 |
| **Evaluate artifact** | 动态检查 | 基于自定义策略对容器镜像等 artifact 执行评估 |
| **Exclusive lock** | 锁 | 互斥锁，确保共享资源上仅允许一个运行继续 |

### 总结

**核心设计**
- Checks 作为独立抽象，可绑定到 Service Connections、Environment 等资源上

**执行机制**
- 流水线使用含 Checks 的资源时，触发所有绑定检查，进入 Pending 状态
- 详情页展示审批等待或检查结果，全部通过或超时后继续执行

**Checks 类型**
- 有多种类型，包括人工审批、延迟审批、时间窗口控制、外部系统集成、策略评估和独占锁等。
- 这些类型，可以分为两类：
  - 静态检查：Branch Control、Required Template 等，不依赖外部环境
  - 动态检查：人工审批、外部 API 调用等，依赖外部输入或系统状态. 依靠外部 API 调用实现扩展能力。
- 资源适配：不同资源适合不同检查类型（如 Evaluate artifact 适合 Environment，用于部署前制品评估）

**执行策略**
- 单资源可绑定多个 Checks，触发时并行执行，汇总最终结果

**管控能力**
- Bypass 机制：授权用户可绕过检查直接使用资源
- 使用追踪：提供使用历史，管理员可查看资源被哪些流水线及 API 调用使用

### 典型使用场景

| 场景 | 检查类型 | 说明 |
|------|----------|------|
| 生产环境部署审核 | Approvals | 对连接到生产集群的 service connection 配置人工审批，确保变更经过审核 |
| 定时发布 | Approvals + Defer | 配置延迟审批，审批通过后在预定时间（如维护窗口）才生效 |
| 维护窗口控制 | Business hours | 配置业务时间窗，确保变更仅在允许的时间窗口内执行 |
| 外部系统集成 | Invoke REST / Azure Function | 与 ServiceNow 等变更管理系统集成，只有变更单完成后才允许继续 |
| 镜像合规检查 | Evaluate artifact | 部署前校验镜像签名或安全策略是否通过 |
| 共享资源串行化 | Exclusive lock | 确保对共享资源（如数据库迁移）仅允许一个运行同时执行 |
| 第三方凭据管控 | Approvals + Required template | 对外部仓库、包管理的连接设置审批与模板强制，保证符合组织策略 |

## Harness Approvals

### 概述

Harness 将 Approval 作为流水线中的一个 Step 来执行，通过不同的 Step 类型扩展 Approval 方式， 通过 脚本支持自定义 Approval 逻辑。

### Approval 类型

| 类型 | 说明 |
|------|------|
| **Harness Approval** | 内置审批，支持单人/多人审批、自定义消息、表单输入、自动审批窗口等 |
| **Jira Approval** | 读取 Jira 工单状态进行审批（商业版） |
| **ServiceNow Approval** | 读取 ServiceNow 工单状态进行审批（商业版） |
| **Custom Approval** | 通过脚本运行并根据输出变量判断通过/拒绝，支持与任意有 API 的审批系统集成 |

### 核心能力

**内置 Approval**

- Built-in Harness Approval supports single/multiple approvers, disallowing pipeline executors, custom approval messages, approval input forms, auto-approval time windows, and other configurations. It sends two types of notifications ("Approval Required" and "Approved or Rejected") through the notification channels of the approver's user groups (currently does not support PagerDuty).
- Supports configurable approval messages, displaying previous stage execution details, auto-rejecting old executions, disallowing specific email/executor approvals, and allowing approvers to fill in custom inputs (supporting default values, required fields, regex/enum constraints). Approvers and user groups support expression-based combinations.
- The commercial version additionally supports Jira/ServiceNow approval steps, directly reading external ticket status.
- Provides Custom Approval, allowing scripts to run in pipelines and determining pass/reject based on output variables, enabling integration with any approval system that has an API.

**Approval Message & Input Forms**

| 阶段 | 功能 |
|------|------|
| 流水线编排 | 指定 Approver 审批时需要展示的提示信息，可以使用变量 |
| 流水线编排 | 定义 Approver 审批时需要填写的表单 |
| 流水线执行 | Approver 收到请求时，展示当前流水线执行的上下文信息，辅助决策 |
| 流水线执行 | Approver 可填入评论及表单信息，表单数据作为变量传递给后续步骤 |

**Auto-Approval Time Windows**

可配置自动审批的时间，在该时间 Approval 自动通过。

### 资源追踪

Harness Connector 提供 **Referenced By** 功能，可查看 Connector 被哪些流水线引用。

## TektonCD Approvals

### 概述

TektonCD 将 Approval 作为流水线中的一个 Task 来执行，通过 ApprovalTask CRD 支持手动审批，通过 ApprovalRequest 扩展外部审批系统集成。

### Approval 类型

| 类型 | 说明 |
|------|------|
| **ApprovalTask** | 内置手动审批，支持单人/多人/组审批 |
| **Jira Approval** | 通过 ApprovalRequest 集成 Jira 工单审批 |
| **Custom Script Approval** | 通过 ApprovalRequest 执行自定义脚本审批 |
| **Email/Slack Approval** | 通过 ApprovalRequest 集成邮件/Slack 审批 |

### 核心能力

**流水线编排**

| 功能 | 说明 |
|------|------|
| Task 编排 | 将 Approval Task 作为普通 Task 编排到流水线中 |
| 审批人配置 | 支持单人、多人审批，可配置通过所需人数 |
| 组审批 | 支持配置用户组进行审批 |
| 审批消息 | 支持配置 Approval 时的提示信息 |

**流水线执行**

| 功能 | 说明 |
|------|------|
| 等待状态 | Approval Task 执行时，流水线进入等待审批状态 |
| 审批页面 | 提供 Approvals 页面，展示当前运行中所有待审批的 Task 列表 |

**审批操作**

| 功能 | 说明 |
|------|------|
| 审批入口 | 审批人在 Approvals 页面查看待审批 Task 列表 |
| 审批动作 | 填入审批原因，执行通过或拒绝 |

### 审批查看

| 视图 | 说明 |
|------|------|
| 全局视图 | 与 Pipelines 同级展示 Approvals 列表 |
| Pipeline 视图 | 单个 Pipeline 内展示当前 Pipeline 相关的 Approvals 列表 |

### 技术实现

| CRD | 用途 |
|-----|------|
| **ApprovalTask** | 支持手动审批 |
| **ApprovalRequest** | 支持扩展外部审批（Jira、Custom Script、Email/Slack 等） |
