# Connectors 立项历史追溯

> 目的：为"Vault 能否替代 Connectors"调研提供"当年为什么没选 Vault"的历史证据。所有时间戳来源 git log，无直接证据的事项明确标注"推断"。

## 1. 立项时间轴

### connectors（核心仓库）

- **2024-10-20** — kubebuilder 项目启动（commit `ad685c2`）
- **2024-10-16 / 2024-10-28** — KEP-0001 `connectors-basic-types`：`ConnectorClass` / `Connector` CRD 设计与合入
- **2024-11-21** — KEP-0002：Connectors API 定义文档
- **2025-07** — KEP-0003：CSI Driver 设计与初步实现（Pod 挂载凭据配置）
- **2025-08-05** — Forward Proxy 模式在 `ConnectorClass` 上的支持（覆盖 Tekton task 出站代理场景）
- **2025-08-19** — HTTP Proxy 特性合入（commit `9b876ad`）
- **2026-02-14** — `enable-connectors-approval` feature flag 启用 + `AccessPolicy` / `AccessRequest` CRD（commit `ec11ea5f`）
- **2026-05-15** — `enable-pod-image-pull-via-connector` feature flag：Pod 镜像拉取通过 connector 的能力（OCI/Harbor PodWebhook 改写 image）

### connectors-extensions

- **2025-07-22** — 仓库初始化，K8s connector 设计先行
- **2025-08-05** — 各 connector（git/gitlab/harbor/oci/maven/npm/pypi/sonarqube）的 forward proxy 配置统一收口

### connectors-operator

- **2024-11-20** — 仓库初始化（commit `ec2b4f9`）
- **2024-11-22** 及后续 — `ConnectorsConfig` 单例 CR、`InstallManifest` 四阶段 apply、各组件 sub-CR 翻译

## 2. 立项时的核心假设（带出处）

1. **Kubernetes-Native 设计优先**
   - 出处：`/connectors/docs/en/keps/0001-connectors-basic-types.md` line 12-18
   - 内容：目标是设计 `ConnectorClass` / `Connector` 两个 K8s 资源，**MVP 阶段明确 Non-objectives** —— "The Connector will not manage secure storage for credentials"。即一开始就把"密钥存储"划出范围、由 K8s Secret 承担。

2. **Secretless 访问是核心价值（proxy 模式而非分发）**
   - 出处：`/connectors/README.md` + `/connectors/docs/en/development/diff-with-3.x.md` line 82
   - 内容：通过 Proxy + CSI Driver 实现"客户端不接触凭据"，明确对标 3.x 的痛点："凭证分发到多个业务集群导致泄露风险"。**这从立项即写死了 data-plane proxy 路线**。

3. **协议优先 + 工具灵活集成**
   - 出处：`/connectors/docs/en/development/diff-with-3.x.md` line 48-71
   - 内容：不限定特定工具，而是基于行业标准协议（Git、OCI 等）做分层：纯地址 → 标准协议 → 特定工具类型。这与"为每个工具实例存一份 KV"的 Vault 模型走了不同路线。

4. **Kubernetes 镜像拉取链路特殊处理**
   - 出处：`/connectors/docs/en/development/diff-with-3.x.md` line 86-95
   - 内容：明确认知"镜像拉取等 kubelet 级操作无法完全避免在 K8s namespace 存储凭据"，并标注 "Solutions are to be determined, and credential security issues will be considered as much as possible"。**承认此问题域的难度，预留了后续 PodWebhook + reverse proxy 路线的空间**。

5. **Approval 与 RBAC 是后置但必需的能力**
   - 出处：`AccessPolicy/AccessRequest` 设计文档 + DEVOPS-43959/44094 Jira
   - 内容：审批与细粒度授权不在 MVP 范围，2026-02 才以 feature flag 引入，说明立项时认知到"凭据治理 + 审批门控"是平台级问题，但实现优先级低于"先把 secretless data plane 跑通"。

## 3. 当年没有选 Vault 的原因

**直接证据**：仓库代码、KEP、commit message 中**未找到任何明确陈述"为什么不用 Vault"**的文档或注释。

**推断**（结合立项时间 2024-10 + 当时 Vault 1.15.x 能力 + Alauda 客户场景）：

1. **air-gap 客户场景的天然摩擦**
   - 2024-10 时 Vault 1.15.x 在 K8s 上的 secretless 方案仍以 Agent Injector + JWT-OIDC 为主，**air-gap 客户内网没有云 KMS**，Vault unseal 需要 Shamir 多人持密钥或 Transit-as-KMS 形成鸡蛋问题。
   - Alauda 客户以金融/国央/电信 air-gap 部署为主，引入 Vault 会增加客户 SRE 学习成本与 unseal 流程治理。
   - **推断成立度：高**——这是结构性约束。

2. **kubelet 镜像拉取链路无 Vault 介入路径**
   - kubelet 走 imagePullSecrets 协议，Vault 只能下发 dockerconfigjson，**无法提供"代拉镜像"能力**。
   - Connectors 通过 PodWebhook 改写 image + reverse proxy 持有凭据回源，是**协议级**而非**凭据级**方案。这条路径走 Vault 完全走不通，Connectors 团队的产品意图是"业务 Pod 完全不持有 dockerconfigjson"。
   - **推断成立度：高**——技术路径在 Vault 模型外。

3. **多工具集成的统一抽象需求**
   - Vault 的 Secret Engine 是层次化 path，无"工具集成 catalog"概念。Alauda 平台需要为 Git/GitLab/Harbor/OCI/Maven/NPM/PyPI/SonarQube/K8s 多种工具提供**统一 UI 选择器、统一审计、统一 Pipeline 集成**。
   - 自研 ConnectorClass + ResourceInterface 的模式与 Alauda Tekton 前端、IAM、Pipeline Integration descriptor 深度耦合，**这层产品形态在 Vault 内不可能复用**。
   - **推断成立度：高**——这是产品 vs 基础设施层的定位差异。

4. **凭据"分发到 client"在 Alauda 3.x 是已知痛点**
   - 出处：`diff-with-3.x.md` 明确把"凭证分发风险"作为 3.x 的核心问题。Vault 模式无论 Agent / VSO / CSI，最终都把凭据物化到 client Pod 内（文件或 env），与 3.x 模型在威胁面上无本质改善。
   - Connectors 4.x 的产品差异化承诺是"凭据永不出 connectors-system"，**这本身就排斥任何把秘密下发到 client 的模型**。
   - **推断成立度：高**——基于明确的反面教材。

5. **K8s-native 对象级共享 + ACP IAM 复用**
   - Connectors 用 `kube-public` / namespace-group / namespace 三级 scope 直接挂 ACP IAM RBAC，治理委派**复用平台已有体系**。
   - Vault 的 policy / namespace / entity 是另一套模型，与 K8s RBAC 不同源，跨系统对齐成本高。
   - **推断成立度：中**——是工程合理性而非硬约束。

## 4. 假设的现状评估（2026-05）

| # | 假设 | MVP 时形式 | 2026-05 是否仍成立 | 备注 |
|---|------|-----------|-----------------|------|
| 1 | Secretless（不下发到 client）是关键差异化 | CSI + Proxy 实现 | **仍高度成立** | 2025-2026 持续优化 plugin metadata 转发（DEVOPS-43925/43992） |
| 2 | air-gap 客户无法用 Vault | 隐含假设，未显式记录 | **推断需向 product/sales 验证** | Vault Enterprise 离线部署技术上可行，但运维负担与 license 成本仍是客户决策痛点 |
| 3 | kubelet 镜像拉取需 ACP 自控 | 长期挑战 | **部分成立，实现复杂** | 2026-05 仍在 feature flag（DEVOPS-43259），说明此路径非平凡，但 Vault 路径完全不通 → 假设方向正确 |
| 4 | Forward proxy 支持是必需 | 2025-08 后逐步落地 | **成立，演进中** | 动态 CA 池（DEVOPS-43784）、Rego 生成器（DEVOPS-43992）说明持续发现新需求，proxy 模式在演进 |
| 5 | 权限/审批模型需要细粒度 | Approval CRD 于 2026-02 引入 | **成立且在升级** | DEVOPS-44094（2026-05）继续优化 RBAC 生成逻辑，说明权限需求未简化反而上升 |
| 6 | 工具集成需统一 UI 资源选择器 | `ConnectorClass.spec.api.openapi` + `ResourceInterface` | **完全成立** | 该层与 ACP Tekton 前端 descriptor 深度集成，无 Vault 等价物 |

## 5. 关键洞察

1. **从立项就排斥"把凭据发到 client"**：`diff-with-3.x.md` 明确把"凭据下发"列为 3.x 痛点，4.x Connectors 的 secretless 是反过来的产品承诺。Vault 模型本质上仍是"先发凭据再让 client 自己用"，与该承诺方向相反——**这不是"当年没想清楚"的问题，是产品定位选择**。

2. **难点正是后期加上来的 feature**：审批（2026-02）和镜像拉取（2026-05）这两个最后加入的特性，恰恰是 Vault + native 方案在客户实践中暴露出来的核心痛点。Connectors 通过自研补齐，**说明客户对这两个能力的需求强烈到值得自建**。

3. **2026-05 当下镜像拉取仍在 feature flag**：说明该问题域的技术实现难度超出预期。Vault 在此问题域是**结构性不覆盖**——即便 Alauda 用 Vault，仍要自建 PodWebhook + reverse proxy 才能达到"业务 Pod 无 imagePullSecret"。所以这条 Connectors 的"投入"无法被 Vault 节省。

4. **核心假设大部分至今成立**：5 条核心假设中 1/3/4/5 都仍然完全成立，2（air-gap 不能用 Vault）需要向客户验证。**没有证据显示"当年决策错了"**。
