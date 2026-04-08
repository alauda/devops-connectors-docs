# Automatic Project, Connector, Secret Creation - Harbor

## 背景

本文用于描述 Harbor 场景下 automatic project / connector / secret creation 的方案。

相关需求来自 `DEVOPS-42609` 和 `DEVOPS-43147`。

当前在新租户、项目或 namespace 创建后，管理员仍需要手动完成一系列 Harbor 相关操作：

- 创建 Harbor Project
- 创建或更新具备正确权限的 Robot Account
- 在目标集群中创建 Secret 和 Harbor Connector
- 按需向目标 namespace 分发 `imagePullSecrets`
- 定期轮转 Harbor 凭据，并同步更新集群中的 Secret

这套流程重复度高，也容易出错，尤其是在多租户场景下：一部分资源是项目级共享的，另一部分资源又需要 namespace 级隔离。

对 Harbor 来说，问题不仅是初始化 provisioning，还包括凭据生命周期管理：

- Harbor 访问通常通过 Robot Account 凭据交付
- secret 必须在创建或刷新时被及时获取并保存
- 同一份凭据可能同时用于 Connector 访问和 Kubernetes 镜像拉取

因此，这里要解决的是一个完整生命周期问题：**初始化 + 凭据轮转**。

同时面临的挑战有

- 不同的工具 API 完全不同，复杂度也不同。
- 同一工具的不同 API 版本， 也可能存在差异。 
- 不同工具的“资源层级”，“权限模型” 差异也较大。

## 方案

使用 **两个 Tekton Task** ， 依赖 harbor-cli 来完成 Harbor 场景的流程。

### Task 1：初始化与资源创建

设计文档：`harbor.task-1.design.md`

该 Task 负责初始化流程：

- 创建 Harbor Project
- 创建或更新 Harbor Robot Account
- 获取返回的 token
- 在目标集群中创建 Secret 和 Harbor Connector
- 创建 `imagePullSecrets`

该 Task 适用于新项目或新租户初始化时触发。

### Task 2：凭据轮转

设计文档：`harbor.task-2.design.md`

该 Task 负责凭据刷新流程：

- 刷新 Harbor Robot Account 凭据
- 更新 Connector 使用的 Secret
- 更新关联的 `imagePullSecrets`

该 Task 适合通过定时任务或其他自动化方式周期性触发。

## 当前方案的优缺点

### 优点

- **工具多版本适配友好**: 
  - 依赖 harbor-cli， 可以减少 harbor API 变化，带来的适配成本。
  - 可以使用 tektoncd task 的版本机制。
- **灵活度较高和低成本**:
  - 可以方便的定制自己

### 缺点

- **幂等与补偿需要仔细处理**：如果 Harbor 侧成功、集群侧失败，或者中途部分成功，重试和回滚逻辑需要明确。 

## 其他可选方案

### 方案一：定义 CRD ,把完整流程放到 controller 中实现

定义 CRD ,把 Harbor Project 创建、Robot Account 管理、Secret 同步和轮转逻辑都放进 controller 中实现。

- **优点**：可靠性和易用性更优。
- **缺点**：实现和维护成本更高，需要做更复杂的建模。 每个工具都要搞一遍，成本扩张较快。


## Harbor 版本的兼容性

**兼容性**

- 主要兼容性在 harbor-cli 层面解决
- 官方声明: 

  ```
  At the moment, the Harbor CLI is developed and tested with Harbor 2.13. The CLI should work with versions prior to 2.13, but not all functionalities may be available or work as expected.
  
  Harbor <2.0.0 is not supported.
  ```

**成本**

- 验证成本： Task 对不同  Harbor 版本的兼容性  --- 自动化
- 适配成本:  
  - 兼容情况下，原 Task 升级 Harbor CLI ， 支持更新的 Harbor 版本
  - 不兼容的情况下，增加新版本的 Task， 升级 Harbor CLI， 修改 Task 内容， 支持 更新的 Harbor 版本

## 交付内容

- connectors-harbor 中提供基于 harbor-cli 的镜像， 维护 task 定义 和 运行集成测试。
- alauda/knowledge 提供文档， 文档中提供 task 定义(来自 connectors-harbor) 和使用方式。
