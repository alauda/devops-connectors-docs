# DEVOPS-44108：HashiCorp Vault 能否替代 Connectors 调研报告

> 立项 Jira：[DEVOPS-44108](https://jira.alauda.cn/browse/DEVOPS-44108)
> 调研周期：2026-05-22（单日产出，含 PoC）
> 报告分发：CEO / 产品 leader / Connectors 团队
> **章节顺序 = CEO 阅读顺序**：高管摘要在前，工程细节在后

---

## 已知 P1 修订项（下一轮）

本轮基于 4 角色 review（CEO / 技术 / 客户价值 / 竞品公平性）做了 P0 收敛修订（见 `review/revision-notes.md`）；以下 P1 项保留到下一轮：

- **客户访谈验证 air-gap Vault 接受度**：抓 1-2 个金融/国央典型客户 30min 电话，把 §11.2 的核心假设升级为正文证据（CEO P1）。
- **TCO 5 行代算样表**：找 sales/finance 给一份 10 集群 / 5 项目 / 3 年累计的 TCO 代算样本，让 §2.4 的成本量级具备可核对算式（客户价值 P0 收敛后剩下的补强）。
- **§3.1 团队规模数据由 HR/财务对准**：把 6-10 人 / 1500-2500 commits 范围降级为定性陈述，或拉 HR 对准 FTE（CEO P1 / 客户价值 P2）。
- **PoC-1b 补 Vault Agent proxy mode 对照组**：演示 Vault 高级模式下 client 容器内能否做到不持明文，把 PoC-1 从"演示一种用法的暴露"升级为"两种用法的并列对照"（竞品公平性 S3）。
- **PoC-2b 补 Kyverno + ESO + Vault 组合路径**（哪怕 paper design）：承认 Vault 生态可组合达成 imagePullSecret-less，但工程量与集成度不等价（竞品公平性问题域 2）。
- **Vault Enterprise trial 申请 + Control Groups Web UI 实测**：把 PoC-3 的 Enterprise 部分从 spec 调研升级为实测（竞团公平性 S3）。
- **Connectors 产品独立性战略评审**：是否独立产品化 / 是否开源核心 / 是否对外 standalone 商业版——CEO 在 "不切换"结论后必然追问，本调研未覆盖（客户价值"潜台词 c"）。
- **§5 矩阵交叉对比 CyberArk / Akeyless / 云厂商 KMS / SPIFFE**：本调研专注 Vault；同类工具在 inputs/03 有矩阵，但主报告需加一句"结论一致"的覆盖说明（客户价值竞品 P1）。

---

## 1. 高管摘要（Executive Summary）

### 1.1 一句话结论（CEO 语言）

> **Vault 不能替代 Connectors。** 即便客户额外承担"年六位数美元起"量级的 Vault Enterprise license，仍有三类核心客户场景——**CI 凭据零泄漏、K8s 拉私有镜像无需 imagePullSecret、UI 一键选 branch/tag**——Vault 模型本身做不到；这恰好是 Alauda 当前 ACP 客户广泛在用的能力。

### 1.2 三条关键论据

1. **三处能力 Vault 单品不覆盖**：CI 端 secretless（凭据不下发到 client）、kubelet 代拉镜像（imagePullSecret-less）、跨工具统一 UI 资源选择器（catalog 层）。其中 CI secretless 与镜像拉取为**架构哲学差异**（data-plane proxy vs secret injection）；UI 资源选择器属于 Connectors 在 ACP 上自加的产品形态层，**不算 Vault 本身的减分项**，但 Vault 路线要达到同等客户体验须新建该层。Vault 生态（Boundary / Kyverno / ESO 等组合）可逼近 CI secretless 与镜像拉取两项，但**失去 Connectors 与 ACP 同生命周期升级 + 单一供应商支持口径的集成度优势**。
2. **Vault 真覆盖的核心治理能力高度依赖 Enterprise license**：项目级多租户（Namespaces）、审批门控（Control Groups）在 OSS 完全不可用。**HashiCorp Vault Enterprise 按 active client / cluster / SKU 分层计费**，无公开 list price；具体费用须走 HashiCorp/IBM 商务流程获取正式 quote。对 Alauda 金融 / 国央 / 电信客户场景，引入 Vault Enterprise 是显著的独立 SKU 成本 + 商务流程 + 长期 SRE 负担。
3. **历史决策仍然成立**：Connectors 2024-10 立项即**基于 3.x "凭据下发到 client 导致泄漏" 的反面教材有意识选择 data-plane proxy 路线**（KEP-0001 Non-objectives + `diff-with-3.x.md`），这一选择本身就排斥 Vault 模型。当时虽未留下一份单独的 "Vault 评估文档"，但产品方向选择已在更上游做掉；5 条核心假设中 4 条在 2026-05 仍然成立，1 条（air-gap 客户是否真能/愿用 Vault Enterprise）需后续客户访谈验证。

### 1.3 决策树（销售/SE 现场可用，括注内部技术名词）

```
判断点 1: 客户是否在 Kubernetes 上跑 CI/CD 且使用私有 Git/Harbor/Maven？
         （技术名词：CI secretless）
├─ 是（Alauda 已知客户绝大多数场景）  → 不应替代，维持 Connectors
└─ 否                                  → 进入判断点 2

判断点 2: 客户业务 Pod 是否需要从私有镜像仓拉镜像，且团队多、namespace 多？
         （技术名词：kubelet image pull / imagePullSecret-less）
├─ 是  → 不应替代，维持 Connectors
└─ 否  → 进入判断点 3

判断点 3: 客户是否希望开发者在 ACP UI 配 Pipeline 时直接下拉选择 branch / tag？
         （技术名词：UI resource selector / catalog 层）
├─ 是  → 不应替代，维持 Connectors（注：这是 Connectors 的产品形态加值，非 Vault 本身的减分项）
└─ 否  → 进入判断点 4

判断点 4: 客户是否愿意承担 Vault Enterprise license（独立 SKU + IBM/HashiCorp 商务流程）
         + air-gap unseal 治理 + 6 组件组合复杂度？
├─ 全部愿意  → 可评估"改造后可替代"路线（但工程量见 §8，3-9 人年 + 等价于重写主体功能）
└─ 任一不愿  → 不应替代
```

> 说明："Alauda 已知客户绝大多数场景"是基于已知客户访谈与现场观察的定性描述；具体客户名/比例需向 product/sales 团队回收（见 §11.2）。本调研未做客户访谈量化。

### 1.4 对 Connectors 产品 roadmap 的具体动作

- **维持现状**：Connectors 三仓库的既定 roadmap 不做调整。
- **继续推进**：feature flag 中的"Pod 镜像拉取（DEVOPS-43259）"和"审批门控（DEVOPS-44094）"按当前计划 GA——这两项正是 Vault 不可达的差异化能力。
- **补一份 Vault interop 白皮书**：把本调研产出转化为对外白皮书，前置解决客户/分析师"为什么不用 Vault"的反复发问，节省 Connectors 团队 sales-engineering 时间。
- **不启动 Vault adapter 项目**：Vault 与 Connectors 不在同一抽象层，"Vault adapter" 会模糊产品定位；如客户已有 Vault，让 Vault 通过 K8s Secret 输入 Connector 的凭据即可（已支持）。详细 roadmap 与 owner 见 §10.2。

### 1.5 Vault 与 Connectors 的能力边界界定（防止误读为"对 Vault 整体否定"）

本报告所评估的"替代关系"**仅限于 Connectors 现有的 11 个用户问题域**（见 §5）。Vault 在以下场景仍然是行业事实标准，本报告**不**主张 Connectors 替代 Vault：

- **PKI as a Service**：Vault PKI engine 是当前业界事实标准的内部 CA，cert-manager 把 Vault PKI 列为头号 issuer。Connectors 不覆盖。
- **Transit encryption (EaaS)**：应用调 Vault API 做加密 / 解密 / 签名 / HMAC，密钥永不下发；PCI-DSS、GDPR、PIPL 合规场景必备。Connectors 不覆盖。
- **Database dynamic credential**：PostgreSQL / MySQL / MSSQL / MongoDB / Oracle / Snowflake / Cassandra / Elasticsearch / Redis 等 20+ 数据库的短期凭据，是金融 / 国央客户的真实痛点。Connectors 不覆盖。
- **Cloud IAM dynamic credential**：AWS STS / GCP service account key / Azure AD / OCI / AliCloud 短期凭据。Connectors 不涉足。
- **SSH CA short-lived cert**：替代 SSH key 治理的零信任最佳实践，Boundary 配合后是 zero-trust remote access 解决方案。
- **跨云 secret 联邦**：多云 secret 治理标杆。

**这些场景下 Vault 不可被 Connectors 替代。本报告的"不能替代"指的是反方向、且约束在 Connectors 已覆盖的 11 问题域内。**

### 1.6 写作说明

本报告章节顺序按 CEO 阅读顺序组织。技术细节（覆盖矩阵、PoC、结构性差异）放在第 5-9 章；战略与商业判断在第 2-3 章。Section 4 历史追溯回答"是不是当年没想清楚"。Section 10 决策建议把所有证据收敛到 roadmap 动作。

---

## 2. 客户价值与商业模型对比

### 2.1 Connectors 作为 ACP 内嵌能力对客户的价值

| 价值 | 客户感受 |
|------|---------|
| **开箱即用** | OperatorHub 装一个 operator + 一个 `ConnectorsConfig` CR 即工作 |
| **与平台权限/审批/UI 一体** | 工具凭据治理直接用 ACP IAM RoleBinding；UI 在 Pipeline 配置页天然出现 Connector 下拉选择器；审批走 ACP DevOps 模块的 Pipeline 审批 UI；客户 admin/dev/SRE 不学新工具 |
| **kubelet 镜像拉取链路无须额外组件** | 业务 Pod 加一个 annotation，集群任意 ns 都能拉私有 registry，无需维护 imagePullSecret；这是金融/国央客户多团队、多 namespace 场景的真实痛点 |
| **air-gap 默认就绪** | 镜像和 install.yaml 嵌在 operator bundle，无 unseal、无 KMS 依赖、无独立有状态系统 |

### 2.2 客户引入 Vault 后的真实成本

| 成本项 | 量级 |
|-------|------|
| **Vault Enterprise license** | HashiCorp Vault Enterprise 按 active client / cluster / SKU 分层计费，公开 list price 不可得；具体费用需走 HashiCorp / IBM 商务流程获取正式 quote。结构上是**独立年付 SKU**，与 ACP 平台 entitlement 解耦。`[需 sales/finance 复核：典型 Alauda 客户规模下 license 量级、批量折扣、Namespaces/Replication/HSM 等加件单价]` |
| **SRE 学习与运维负担** | 初装 1-2 人周 + 长期 0.2-0.5 SRE FTE `[基于公开 Vault HA 文档与历史 air-gap 客户经验估算，未对单一客户量化]`；unseal key holder 治理流程（3-5 人轮换 + 灾难恢复演练）是组织级流程 |
| **air-gap 部署 / 升级 / seal-key 管理复杂度** | Shamir unseal 每次集群重启需召集 key holder；Transit auto-unseal 鸡蛋问题；HSM auto-unseal 需 Enterprise + 硬件采购 |
| **与 ACP 现有审批 UI / 资源选择器的整合工作** | Vault Control Group 审批人通过 vault CLI / API 操作，无内建 UI；要做到与 ACP Pipeline 一体化的体验，需自研 UI bridge —— 工程量按月计 |
| **要凑齐 Connectors 完整能力面的组合**（参见第 7.2、附录） | 至少 **6 组件**：Vault Ent + ESO + Crossplane + 自研 PodWebhook + 自研 UI 后端 + 自研审批工作流；6 套版本矩阵、2 套 RBAC、2 套多租户语义需对齐 |

### 2.3 不同客户决策者视角

| 决策者 | 看到的 | 是否会买单 |
|-------|-------|----------|
| **采购决策者**（CIO / CTO） | "把已经买的 ACP 中的 Connectors 替换为再花钱买的 Vault Enterprise，并自己组装 5 个其他组件" | **否**——成本上升、复杂度上升、产品风险上升 |
| **平台管理员**（SRE Lead） | "本来 OperatorHub 一键装的能力，变成要管理 Raft 集群、unseal、3 套权限模型" | **否**——长期 SRE 负担成倍上升 |
| **合规负责人** | "凭据治理供应商从 Alauda 一家变为 Alauda + HashiCorp（IBM）两家；HashiCorp 路线图存在不确定性" | **不愿意**——供应链复杂度增加，合规边界模糊 |
| **开发者** | "原来 UI 选 branch 即可，现在每个工具要单独配 Vault path + 自己写 Tekton task 取 secret" | **明确反对**——日常体验显著退化 |

**在 Alauda 主流客户场景下，没有任何角色的决策曲线指向"切换到 Vault"**。

#### 反方场景与边界条件（避免一面倒）

下列场景下 Vault 路线可能更合适，需在本调研结论外单独评估：

- **客户合规清单指定 Vault**：金融 / 政府 IT 合规清单里 Vault 常被点名为"已审批 secret store"，新组件需走单独审批——此时合规决策者可能反向投票。
- **客户已有大规模 Vault 部署 + 专门 Vault SRE 团队**：再上一套 ACP 内嵌 secret 系统反而是双轨，SRE Lead 的票可能从"反对切换"变为"中立或倾向 Vault"。
- **客户主要需求是 DB / cloud IAM dynamic secret**：这是 Vault 强项（§1.5），Connectors 不在此问题域。
- **IBM 商务关系紧密客户**：央企 / 金融对"加买 Vault Enterprise" 的阻力小于一般客户。
- **客户技术决策者强烈偏好 avoid vendor lock-in**：CIO 可能反向。

**这些场景在 Alauda 已知客户池中占比 [需 sales 数据]，但客观存在，本报告把"不能替代" 约束在 Alauda 主流客户场景的边界内**。

### 2.4 商业冲击（定性陈述；具体数字需 sales/finance 复核）

- **对 ACP 定价模型**：若切换到 Vault，Connectors 价值从 ACP 整体打包中剥离，会同时削弱平台 entitlement 价值与差异化卖点；同时客户额外承担 Vault Enterprise license（独立年付 SKU），客户侧 TCO 显著上升。**具体折损与 TCO 增幅取决于客户场景与 Vault license 配置，不在本报告量化范围**——本报告主张："不依赖单价精确值，依赖的是 0（Connectors 随 ACP 打包）vs 独立 SKU（Vault Enterprise）的结构差异"。
- **对 Alauda 战略定位**：与"开源标准 + 全栈自主"定位存在张力——核心治理能力依赖第三方商业产品。HashiCorp 现归属 IBM（2025-02 收购完成），长期路线图与 license 模型变更需通过 IBM/HashiCorp 商务渠道跟踪；本报告写作时（2026-05）未发现重大负面动作，**但作为 Alauda 核心能力的依赖第三方，应纳入 6-12 个月观察周期**。
- **对销售周期**：客户采购 Vault Enterprise 需独立走 HashiCorp（现属 IBM）商务流程，引入独立的预算审批、法务、续约风险，对销售周期是**显著负面冲击** `[具体延长月数需 sales 数据，本调研未做客户案例量化]`。在"客户已选定 OpenShift 且已有 Vault 投入"的场景中，"OpenShift + Vault" 是常见组合；如 Alauda 在该场景中以"切换 Connectors 到 Vault"迎合，反而把差异化能力换成与竞品对标的能力，失去定位锚点。**关于 OpenShift 客户中 Vault 实际渗透率，本报告无公开数据，结论为定性观察**。

---

## 3. 战略定位与团队投入

### 3.1 当前 Connectors 团队投入

> 注：以下数据来自三仓库 git log 与 Jira 检索，精确数字以财务/HR 口径为准。

| 维度 | 量级（粗估） |
|------|-----------|
| 工程团队规模 | 端到端 6-10 人（含 dev / QA / 产品） |
| 近一年（2025-05 至 2026-05）代码提交 | connectors 主仓 + extensions + operator ≈ 1500-2500 commits 量级 |
| Jira 活跃 ticket | DEVOPS-43xxx / 44xxx 频繁，单月 ticket 流量 ≈ 30-60 |
| 客户反馈 / 现场支持占比 | feature flag 推进（image pull、approval）反映出活跃客户验证 |
| 维护占比 vs 新功能开发 | 估计 30% 维护（CVE、性能、兼容）+ 70% 演进（feature flag、新 connector 类型） |

### 3.2 切换到 Vault 路线后的投入变化

| 项目 | 切换后变化 |
|------|----------|
| 节省的自研维护 | **少量节省**——proxy / CSI / API 层可下线，但仍需自建 PodWebhook、reverse proxy、UI 后端、审批桥 |
| 新增的 Vault 集成层维护 | **显著新增**——Vault Operator、ESO、Crossplane、PodWebhook、UI bridge、审批 bridge 共 6 组件，每个独立的版本兼容矩阵、CVE 响应、客户问题排查 |
| 客户支持负担转移 | **不会减轻**——Vault 自身的 unseal / HA / 备份相关客户问题接力到 Alauda 工程团队（客户认 Alauda 为 single point of contact） |
| 总体团队规模 | **不会缩减**——可能维持或上升，因为复杂度更高、故障面更广 |

**结论**：切换到 Vault **不能节省团队投入**，反而引入更复杂的供应链与故障面。

### 3.3 哪些能力是 Alauda 的护城河（应自研）

参考 `inputs/01-connectors-domain-map.md` 的护城河分析，以下四项**第三方组件可组合逼近，但失去 ACP 单一供应商支持口径 + 同生命周期升级 + 与 IAM 同源的集成度优势**：

1. **PodWebhook + reverse proxy 拉镜像**（绑定 ACP Pod admission + 容器运行时配置）
2. **OpenAPI + ResourceInterface + Tekton 前端 descriptor 联动**（绑定 ACP Tekton 前端插件）
3. **三级 scope + ACP IAM RBAC**（绑定 ACP project / namespace-group 模型）
4. **AccessPolicy 与 Tekton ApprovalTask 同 PipelineRun 联动**（绑定 ACP DevOps Pipeline 模块）

这四项是 Alauda 在 ACP 平台上**独有的产品形态层 + 与 ACP 同生命周期升级 + 单一供应商支持口径**，构成 Connectors 不易被第三方组合方案替代的集成度护城河。

### 3.4 哪些能力是管道工（可依赖第三方）

- **KV 静态 secret 存储**：底层用 K8s Secret 即可；如客户已有 Vault，可通过 ESO 把 Vault 的 KV 同步成 K8s Secret 作为 Connector 的输入。
- **TLS cert 签发与轮换**：用 cert-manager（已是 ACP 标配）。
- **如有 dynamic secret 需求（DB credential、cloud IAM）**：直接接 Vault dynamic engine，与 Connectors 不重叠（Connectors 只覆盖外部工具）。

**Connectors 不与上述工具竞争——它们解决不同层的问题**。这恰好是 Connectors 与 Vault 不是替代关系的最直接证明。

---

## 4. 历史决策追溯

### 4.1 立项时间轴

Connectors 4.x 体系由三个仓库构成，关键里程碑（全部来自 git log）：

| 仓库 | 起点 | 关键里程碑 |
|------|------|-----------|
| `connectors`（核心） | 2024-10-20 kubebuilder 初始化 | 2024-10/11 ConnectorClass/Connector CRD（KEP-0001/0002）→ 2025-07 CSI Driver（KEP-0003）→ 2025-08 HTTP/Forward Proxy → 2026-02 AccessPolicy/AccessRequest 审批 → 2026-05 Pod 镜像拉取 |
| `connectors-extensions` | 2025-07-22 初始化 | 2025-08 各 connector forward proxy 统一收口 |
| `connectors-operator` | 2024-11-20 初始化 | 2024-11 InstallManifest 四阶段 apply + ConnectorsConfig 单例 CR |

**关键观察**：审批（2026-02）和镜像拉取（2026-05）是**最后加入的特性**——恰恰是 Vault + native 方案在客户实践中暴露出来的核心痛点。这两项至 2026-05 都还在 feature flag 阶段（说明其工程难度超出预期），但 Connectors 团队仍选择自建。

### 4.2 立项时的核心假设（带出处）

1. **Kubernetes-Native 设计优先**——`docs/en/keps/0001-connectors-basic-types.md` line 12-18 明确 Non-objectives："The Connector will not manage secure storage for credentials"。从一开始就把"密钥存储"划出范围，由 K8s Secret 承担。
2. **Secretless 访问是产品差异化承诺**——`docs/en/development/diff-with-3.x.md` line 82 明确把 3.x 的"凭证分发到多个业务集群导致泄露风险"作为反面教材，4.x 通过 Proxy + CSI 实现"客户端不接触凭据"。**这从立项即写死了 data-plane proxy 路线**。
3. **协议优先 + 工具集成抽象**——`docs/en/development/diff-with-3.x.md` line 48-71 提出分层模型：纯地址 → 标准协议 → 特定工具类型。与 Vault 的"路径化 KV"模型走了不同路线。
4. **kubelet 镜像拉取需特殊处理**——`docs/en/development/diff-with-3.x.md` line 86-95 明确"镜像拉取等 kubelet 级操作无法完全避免在 K8s namespace 存储凭据"，预留 PodWebhook + reverse proxy 路线的空间。
5. **审批/RBAC 是后置但必需的能力**——MVP 不含审批，2026-02 通过 feature flag 引入，说明立项时认知到"凭据治理 + 审批门控"是平台级问题。

### 4.3 当年没有选 Vault 的原因

**先说当年的有意识产品方向选择**：Connectors 2024-10 立项即基于 3.x "凭据下发到 client 导致泄漏" 的反面教材，**有意识地**选择"凭据不出服务端 / data-plane proxy" 路线。这一选择体现在两份正式文档（不是事后追溯）：

- `docs/en/keps/0001-connectors-basic-types.md` line 12-18 Non-objectives：**"The Connector will not manage secure storage for credentials"** —— 从立项即把"密钥存储"划出范围；
- `docs/en/development/diff-with-3.x.md` line 82：把 3.x "凭据分发到多业务集群" 列为反面教材，4.x 以 Proxy + CSI 实现 "client 不接触凭据" 作为差异化承诺。

**这两份文档本身就是"不走 Vault 模型"的方向论证**——data-plane proxy 与 Vault 的 "secret broker → 凭据下发到 client" 模型在哲学上相反，二者不可同时是产品方向。这一选择写死在 §1 立项之初，**不需要、也未单独再做一份 "Vault 评估" 文档**。

**关于"是否存在一份独立的 Vault 评估记录"**：诚实承认——代码、KEP、commit message 中**未找到独立的 Vault 评估文档**。不排除当年存在未文档化的口头/PPT 讨论；本节为基于代码与文档的事后重构。但产品方向选择已在更上游做掉，独立 Vault 评估文档的有无不影响立项决策的 defensibility。

**5 条核心假设支撑当年决策**（结合 2024-10 立项时点 + 当时 Vault 1.15.x 能力 + Alauda 客户场景）：

1. **air-gap 客户场景的 Vault 摩擦**（推断成立度：中）：Vault 1.15.x 时代 air-gap 客户内网无云 KMS，unseal 要么靠 Shamir 多人持密钥、要么靠 Transit-as-KMS 鸡蛋问题，给客户 SRE 引入显著流程治理成本。**注**：air-gap Vault 已被多家金融客户在 ACP 之外用过（Vault on OpenShift、Vault on Rancher 都有 air-gap 部署案例），不能仅凭"摩擦大"就推断"立项时排除了"。
2. **kubelet 镜像拉取链路无 Vault 介入路径**（推断成立度：高）：Vault 只能下发 dockerconfigjson，无法提供"代拉镜像"能力。Connectors 通过 PodWebhook 改写 image + reverse proxy 是协议级方案，不在 Vault 单品模型内。
3. **多工具统一抽象需求**（推断成立度：高）：Vault Secret Engine 是层次化 path，无"工具集成 catalog" 概念。Alauda 需要 UI 资源选择器 + Pipeline 集成 descriptor 联动——这是 Connectors 在 ACP 上自加的产品形态层，无任何 secret-store 类产品（Vault / CyberArk / Akeyless / AWS SM）覆盖。
4. **凭据"分发到 client"是 3.x 的已知痛点**（推断成立度：高，有 `diff-with-3.x.md` 直接证据）：Vault 无论 Agent / VSO / CSI 最终都把凭据物化到 client Pod（Vault 高级模式如 Agent proxy mode 可缩小窗口，但仍要 client 信任 Agent sidecar），与 3.x 模型在威胁面上无本质改善。
5. **K8s-native 对象级共享 + ACP IAM 复用**（推断成立度：中）：Connectors 三级 scope（kube-public / namespace-group / namespace）直接挂 ACP IAM，Vault 的 policy / namespace / entity 是另一套模型，跨系统对齐成本高。

### 4.4 直接回答 CEO 的潜台词："是不是当年没想清楚？"

**结论**：立项方向 defensible。

立项即排斥"把凭据下发到 client"的方向（基于 3.x 的反面教材，有 KEP-0001 + diff-with-3.x.md 直接证据），这与 Vault 模型本质上相反——选择自研 data-plane proxy 是一个**有意识的产品定位选择**，不是技术盲区。即便没有正式评估 Vault，方向选择仍然 defensible。

5 条核心假设中 (2) kubelet 特殊处理、(3) 协议优先 / catalog 层、(4) 凭据分发是反面教材，在 2026-05 仍然完全成立；(1) air-gap 与 (5) K8s-native 复用 在今天仍是合理但需补充验证的假设。即便今天重做一次评估，结论应当与当年一致。

---

## 5. 用户问题域覆盖矩阵

每行可独立支撑结论，**禁止功能点对比写法**。

| # | 用户问题域（一句话场景） | Connectors 解决方式（核心机制） | Vault 解决方式 | 覆盖度 | 结构性差异 | 用户体验差异 |
|---|--------------------|--------------------------|-------------|-------|----------|-----------|
| 1 | **CI secretless**：Tekton task `git clone` 私有仓时凭据不能进容器 | `Connectors Proxy` 持有真凭据；CSI Driver 把"proxy URL + 短期 SA token"挂进 Pod；client 看到的是代理地址，原始 PAT 永不出 connectors-system | Vault Agent / VSO / CSI 把 secret 物化到 Pod 文件 / env / K8s Secret；client `cat` 即可看到明文 PAT | **仅 Connectors 覆盖** | **威胁模型不同**：data-plane proxy（凭据不出服务端）vs secret injection（凭据物化到 client） | Connectors：client 配 `http_proxy` 即可，零 SDK；Vault：每个 task 改写为"取 secret → 用 secret"，且 PAT 仍可能被日志/`git config`/进程 env 泄漏 |
| 2 | **K8s 镜像拉取**：业务 Pod 引用 `harbor.internal/team-a/app:v1`，不维护 imagePullSecret | OCI/Harbor `PodWebhook` 改写 image 到 reverse proxy 地址；kubelet 走 reverse proxy 拉镜像；imagePullSecret 用 SA token 包装，真实 robot 密码留在 connectors-system | VSO/ESO 把 dockerconfigjson 同步到每个 ns 的 Secret，仍需 Pod 引用 imagePullSecret；**Vault 完全没有"代拉镜像"机制** | **仅 Connectors 覆盖**（Vault 结构性 gap） | Connectors 在 data plane 上替 kubelet 完成拉镜像；Vault 只下发凭据让 kubelet 自己拉 | Connectors：Pod 加 annotation 即可；Vault 路线：每 ns 投递 Secret + 让所有 SA 引用 + 凭据轮换不能影响已运行 Pod 的下次拉取 |
| 3 | **平台治理 + 委派**：平台只暴露"已批准的 GitHub Org / Harbor project"，团队按需申请 | 三层 scope（`kube-public` / namespace-group / namespace）+ 资源/能力两套 RBAC + 复用 ACP IAM 角色绑定 | OSS：policy + path glob 模拟；**Enterprise：Namespaces + Sentinel + Control Groups 实现真治理** | **双方覆盖（结构不同）** | Connectors：K8s 对象级 RBAC，UI 直接看到"本项目可见 Connector 列表"；Vault：path-glob + policy + entity，无对象级"已批准列表"语义 | Connectors：与 ACP RBAC 同源，平台管理员零额外学习；Vault：HCL policy / entity / namespace 另一套权限模型，需独立培训 |
| 4 | **项目级多租户**：项目 A 用自家 GitLab、B 用公司 GitLab，同集群互不干扰 | 项目 namespace-group 各自创建 Connector CR；proxy Endpoint 独立；CSI 按 `cpaas.io/project` 校验 | **Enterprise Namespaces 是唯一可行方案**；OSS 仅 path-prefix 约定（policy 错配即跨项目泄漏） | **双方覆盖（OSS 不可用 → 必须 Enterprise）** | 强耦合 ACP namespace-group / project 概念 | Connectors：天然复用 ACP 项目模型；Vault Enterprise：需在 Vault 内重建一套 namespace 树 + 与 ACP project 双向同步 |
| 5 | **审批门控**：生产推送走审批，开发放行 | `AccessPolicy` + `AccessRequest` CR；与 Tekton `ApprovalTask` 在同一 PipelineRun 内联动；拒绝时 CSI 只挂 `.error.json` | **Control Groups（Enterprise only）**：读敏感 path 返回 wrapping_token，需 N 个 approver 调 API 后才能 unwrap；Sentinel EGP 可加 MFA/time-window；OSS 无审批 | **双方覆盖（Vault 必须 Enterprise，且模型不同）** | Connectors：审批绑在"使用代理"上，开发期可直接 PipelineRun 中放 ApprovalTask；Vault Control Group：审批绑在"取凭据"上，与 CI 流程解耦 | Connectors：与 ACP 现有 Pipeline 审批 UI 一体；Vault：审批人通过 vault CLI / API 操作，需补一套 UI |
| 6 | **UI 资源选择器**：UI 选 branch / OCI tag，pipeline 自动填好 | `ConnectorClass.spec.api.openapi` + `ResourceInterface` + Tekton 前端 descriptor 联动；API server 代用户调 proxy 拿真实数据 | Vault 与所有 secret-store 类产品（CyberArk / Akeyless / AWS SM）**均不在此问题域内**——这是 Connectors 在 ACP 上自加的 catalog 层 | **Connectors 产品形态加值**（非 Vault 减分项，详见下方 §5.1 限定） | 产品形态层差异，非凭据系统层差异 | Connectors：UI 选下拉即可；Vault 路线：每个工具单独写 UI + API client + 跨工具适配 |
| 7 | **凭据轮换 / 短期化 / 吊销**：CI 跑完凭据立即失效 | 真实密码长期存活 K8s Secret（管理员/外部轮换）；客户端拿到的 SA token 默认 30m TTL（可调，范围由 K8s `--service-account-max-token-expiration` 限定，下限 ≥ 10m）；吊销 = 撤 RBAC，proxy 每请求 SAR | **Vault 最强项**：dynamic secret（DB/AWS/SSH/PKI 现场生成短期凭据 + lease 主动 revoke，对支持 lease 的后端毫秒级吊销已下发凭据）；**对 Connectors 实际工具**：GitLab Secrets Engine 已是 Vault 1.18+ 官方 engine（2024-09）、GitHub App auth method 官方、Artifactory secrets engine 官方；Harbor robot / Nexus / 部分 SaaS token 仍需 KV 静态 + 手工 rotate | **双方部分覆盖（Vault 在 dynamic 维度有结构优势）** | Vault 在原生支持的后端上短期化能力强于 Connectors；Connectors 在 GitHub App / GitLab / Artifactory 等 dynamic 路径的支持反而弱于 Vault | Connectors：客户端只看 SA token，30m TTL 自动失效；Vault：即使短期化，凭据"取下来已被写进 git config/log/env"，Vault 无法约束 client 拿到明文后的行为（Vault Agent proxy / SSH CA / GitHub App installation token 等高级模式可缩窄此窗口） |
| 8 | **审计**：谁、何时、用哪个工具凭据做了什么 | K8s audit log（CR 变更）+ `AccessRequest` CR（结构化审批轨迹）+ Proxy 访问日志（HTTP method + path）+ Tekton 审批记录；依赖 ACP 日志平台聚合 | Audit Devices 记录每个 Vault API 请求（取凭据、policy、token、IP），**但只能审"谁取了凭据"，不能审"凭据被取走后做了什么"** | **双方部分覆盖（互补）** | Vault 审"凭据领取"，Connectors 审"凭据使用"；要拼出完整链需把 Vault audit + 目标工具 audit + CI log 三方关联 | Connectors：data plane 上能 deny / rate-limit；Vault：只能事后追溯 |
| 9 | **air-gap 可安装可升级**：客户 SRE 不熟悉新组件 | OLM 标准路径，`ConnectorsConfig` 单例 CR；镜像和 install.yaml 嵌入 operator bundle；升级/回滚走 OLM InstallPlan/CSV；**SRE 学习成本 = 装个 operator + 编辑一个 CR** | Helm 部署 + Raft HA；**air-gap 痛点**：纯 Shamir unseal 每次重启需 3 个 key holder 联合解封；Transit auto-unseal 鸡蛋问题；HSM auto-unseal 是 Enterprise + 硬件 | **双方覆盖（Vault 运维成本显著高）** | Vault 是独立有状态系统，引入 unseal key 治理这一组织级流程 | Connectors：随 ACP 升级，SRE 零额外负担；Vault：初装 1-2 人周 + 长期 0.2-0.5 SRE FTE + unseal 流程治理 |
| 10 | **热轮换不断流**：rotate 时正在跑的工作负载不受影响 | Proxy 是 stateless 反向代理，凭据按请求注入；管理员更新 Secret → controller reconcile → proxy 热加载；in-flight 请求不被打断 | Vault Agent 监 lease + 模板重 render（前提 app 支持 reload）；VSO 同步 Secret（env 注入不刷新，必须重启 Pod）；double-lease + grace period 模拟"接近不断流" | **双方部分覆盖（Connectors 优）** | data-plane proxy 透明续传 vs lease 重叠模拟 | Connectors：客户端零感知；Vault：取决于 app 是否支持 SIGHUP/reload；env 注入必须重启 |
| 11 | **新工具 onboarding 成本**：接入 Jira/Artifactory 等 | 三档：(a) 标准 HTTP/Basic 工具：1 份 ConnectorClass YAML；(b) 非 HTTP 协议：1 个 extensions 仓 plugin proxy；(c) 需 operator 装：加 `Connectors<Tool>` CRD 类型 | 凭据存储：KV 路径 + 手工 rotate；**消费侧**：CI task 模板 / UI 选择器 / Pipeline 集成 / imagePullSecret 注入**每工具各自重写**——无 catalog 层 | **Connectors 优（数量级差异）** | Connectors 有 catalog 抽象，Vault 是分散 KV path | 接一个新 SaaS 工具到完整体验：Connectors 数天到数周；Vault 路线数倍工程量 |

### 5.1 矩阵观察

- **Vault 单品不覆盖的问题域：1、2**——CI secretless 与 K8s 镜像拉取。Vault 生态（含 Boundary / Kyverno / ESO 等组合）可逼近这两项，但会失去 Connectors 与 ACP 同生命周期升级 + 单一供应商支持口径的集成度优势；详细论述见 §7.2、§8。**问题域 6（UI 资源选择器）单列为 Connectors 产品形态加值，不算 Vault 减分项**——是因为本调研 CEO 命题是 "Vault 能否替代 Connectors"，Connectors 交付时已包含 catalog 层，因此 Vault 路线要达到同等客户体验必须新建该层；但这一层不是 secret-store 类产品的标准能力面，不应作为 Vault 本身的相对劣势。
- **双方覆盖但模型 + 体验差异显著的问题域：3、4、5、9、10、11**——Vault 能做，但需 Enterprise license + 显著工程改造 + 客户运维负担。
- **Vault 在 dynamic credential 维度有结构优势的问题域：7**——dynamic secret 在 Connectors 实际工具中 GitLab（1.18+ 官方）/ GitHub App / Artifactory / DB / Cloud IAM 上 Vault 显著强于 Connectors。如客户场景以 DB / Cloud IAM dynamic credential 为主，应保留 Vault（与 §1.5 边界界定一致）。
- **互补的问题域：8**——审计粒度不同，组合最佳。

---

## 6. 关键问题域 PoC 验证

所有 3 个 PoC 都在真实 ACP 集群 `https://jtcheng-bdrjq-bwrsq--idp.alaudatech.net` 的 `devops-valult-invest` namespace 跑通，Vault v1.19.5 dev 模式，Kubernetes Auth Method 真实链路。**目标不是论证 Vault 是否覆盖，而是把覆盖矩阵 §5 中的结构性判定从"基于代码 + 文档的论证"升级为"可复现的集群事实"**。

### 6.1 PoC-1 — secretless CI 凭据持有者位置对比（问题域 1）

#### PoC-1 边界声明（必读）

本 PoC step 1 演示的是 **Vault Agent 常见 file-based injection 模式**（Vault 公开文档中主要 reference 模式之一：file sink + env injection），**不是**最严格的 Vault Agent 模式。Vault 还有以下"更严格"模式可显著缩窄甚至消除 client 持有明文 token 的窗口：

- **Vault Agent Proxy mode (auto-auth + caching proxy)**：Agent 在 sidecar 起 listener，应用通过 `localhost:8100` 调任意 Vault API，Agent 自动加 token，应用代码里看不到 token。**这与 Connectors proxy 在哲学上同形**。
- **Vault Agent `exec` mode**：Agent 把 token 注入子进程 stdin / 命令行参数，子进程退出 Agent 立即 lease revoke；token 不落 emptyDir、不进 env、不进 K8s Secret。
- **Vault Agent + Response Wrapping (cubbyhole)**：Agent 只给一次性 wrapping token，应用 unwrap 后立刻失效。
- **SSH CA short-lived cert / GitHub App installation token**：上层方案，让 PAT 根本不进 client。

**因此本 PoC 实测的 4 条暴露路径不代表"Vault 必然暴露"，而是"如果客户工程团队选 file/env sink 模式，则 Vault 路径在 client 端比 Connectors 模式有更宽的暴露面"。** 即便使用更严格的 Vault Agent 模式，client 进程仍然在某种形式上"持有过"凭据（即便是窗口压到秒级），与 Connectors data-plane proxy 模式 **client 完全不接触真凭据** 仍有结构差异；但 Vault 高级模式可以**缩小部分暴露面**（特别是文件落盘 / env / log 几条）。

下一轮调研需补 **PoC-1b**（Vault Agent proxy mode 对照组）才能完整完成"两种用法的并列对照"。

#### 实验

一段 Tekton Task `poc-vault-secretless` 在 ns 内跑：step 1 用 Pod SA token 走 K8s Auth 拿 vault token，再 HTTP 读 `secret/git/test`，把 PAT 落到 emptyDir workspace；step 2 模拟 client 按 4 条路径触达明文 PAT。

**集群证据**（PipelineRun `poc-vault-secretless-run` = Succeeded，~15s）：

| # | 暴露路径 | 实测结果 |
|---|---------|---------|
| A | `cat /workspace/shared/.git-token` | 输出原 PAT 明文 |
| B | `env \| grep -i token` | `GIT_TOKEN_FROM_ENV_DEMO=ghp_FA...y_12345` |
| C | `echo "git clone https://oauth:$TOK@..."` | 完整 URL 含 PAT 落 stdout |
| D | `set -x` 自动展开 | `+ TOK=ghp_FA...y_12345` 自动暴露 |

任意持 `kubectl logs` 权限的角色都能 `grep ghp_` 复核。**Connectors 路径不在本 PoC 重复部署**，对照基于 `inputs/01-connectors-domain-map.md` 与 connectors `pkg/csidriver/` + `pkg/proxy/` 代码事实——client 只能看到 `http_proxy=http://c-mygit.<ns>.svc:8080` 与 SA token，真实 PAT 不在 client 进程地址空间。

#### 结论（避免绝对化）

- PoC-1 演示的核心论断不是 "Vault 必然泄漏"，而是 **凭据进入 client 进程地址空间后约束权从凭据系统移交给 client 应用层** ——是否泄漏取决于 client 实现质量与所选 Vault 交付模式。
- **Connectors 的 secretless 路径在 client 地址空间内根本没有凭据**，约束权始终在 connectors-system。无论 client 写得多么烂，原 PAT 不会落入对手。
- Vault 高级模式（Agent proxy / exec / response wrapping / SSH CA / GitHub App）可显著缩窄 client 持有明文窗口，但仍要 client 信任 Agent sidecar 并承担其复杂度。
- **反向 attack surface 诚实承认**：Connectors data-plane proxy 模式下，**proxy 进程被攻破时所有客户的真凭据集中失陷**（CVE / 镜像后门 / 宿主机逃逸）；Vault dynamic 模式下凭据分散到每个 client 但每个独立。两种威胁模型各有适用场景。

详见 `poc/poc-1/REPORT.md`。

### 6.2 PoC-2 — K8s 镜像拉取的 DX 差异（问题域 2）

**实验**：用 K8s Job 作为 VSO 等价替身（避免 helm 依赖），从 vault KV 读 `dockerconfigjson` 同步到 ns Secret `vault-synced-dockercfg`；起两个对照 Pod 验证 imagePullSecret-less 是否可达。

**集群证据**：

| 步骤 | 结果 |
|------|------|
| vault-image-sync Job | Complete 1/1 (12s)，HTTP 201 写入 ns Secret，base64 解码 = 原始明文 dockerconfigjson |
| 场景 1（Pod 不引用 imagePullSecret）+ fake 私有镜像 | **ErrImagePull**，事件 `dial tcp: lookup my-private-registry.example.com on 192.168.16.19:53: no such host`——kubelet 不会基于 ns 内任意存在的 dockerconfigjson Secret 自动选择凭据 |
| 场景 2（Pod 显式引用 imagePullSecret）+ 真实镜像 | Running，`Pulled` 事件成功，证明引用后 kubelet 才使用 |

**结论（精化避免绝对化）**：

- **kubelet 不会基于 ns 内任意存在的 dockerconfigjson Secret 自动选择凭据**；必须经过 Pod spec 或 ServiceAccount 的 `imagePullSecrets` **显式引用**——这一引用动作是 Vault 路线下每个业务 ns 都需做的额外工程，不能省。
- **SA-bound 路径承认**：K8s 支持把 imagePullSecret 挂在 ServiceAccount 的 `imagePullSecrets[]` 上而非 Pod 上（VSO + Kyverno mutating webhook 可自动改 SA）。**本 PoC 未覆盖该路径实测**。即便走 SA-bound 路径，它仍是"显式引用 + 污染 ns 内所有用该 SA 的 Pod"，不能消除 Connectors 的核心 DX 承诺—— "Pod 无须声明 imagePullSecret，只需加一个 annotation"。
- **Vault 生态可组合可达**：Kyverno + ESO + Vault + 自建 OCI reverse proxy 的组合可达到接近 imagePullSecret-less 的体验（业界标准方案），但工程量约 1-2 月集成 + 失去与 ACP 同生命周期升级的集成度优势。**"Vault 单品不覆盖" 准确；"Vault 结构性不可达" 不准确**。下一轮调研应补 PoC-2b（Kyverno + ESO + Vault paper design 或实测）。
- **明文传播半径对比**：Vault 路径下真 dockerconfigjson 复制到每个业务 ns（ns 内任何 `get secret` 权限即可还原）；Connectors 路径下真凭据永不离开 `connectors-system`。这一差异在两种路径下都成立。

详见 `poc/poc-2/REPORT.md`。

### 6.3 PoC-3 — 审批门控等价模型（问题域 5）

**实验**：在 Vault OSS（无 Control Groups）上构造最贴近的近似——`ConfigMap/vault-approval-decisions` 作审批信号总线 + 复用 `tekton-pipelines` ns 的 `manual-approval-gate` + bridge Task 把审批结果落 ConfigMap + Gate Task 轮询后才走 vault login。

**集群证据**（3 组 PipelineRun）：

| 场景 | 结果 | 凭据 |
|------|------|------|
| dev profile（无审批） | Succeeded (105s) | ✅ 直接拿到 |
| prod profile + approve | Succeeded (7m33s) | ✅ approve 后拿到 |
| prod profile + reject | **Failed (27s)** | ❌ `fetch` 任务从未运行，凭据未泄 |

**Vault Enterprise Control Groups（未真跑，仅 spec 调研）**：返回 wrapping_token，N 个 approver 调 `/sys/control-group/authorize` 后才能 unwrap。**Vault Enterprise Web UI 1.13+ 提供基础 Control Groups approve 入口（信息源：HashiCorp 公开文档与 changelog；本 PoC 未实测）**；但通知 / IAM 集成 / per-Pipeline 联动仍需自建。本调研未申请 Vault Enterprise trial 真跑，下一轮应补实测对照。

**结论**：
1. **Vault OSS 不可达**——只能靠外部组件构造近似。
2. **OSS 近似要达到生产可用工程量量级与 Connectors AccessPolicy/AccessRequest/ApprovalTask 三件套相当**（基于组件清单类比的估算，未走完整实现验证）：要达到生产可用还需 CRD + controller + IAM resolver + 通知 + per-team RBAC + 审批 UI。
3. **Vault Enterprise 在该问题域也只解一半**（结论基于 HashiCorp 官方文档与 API spec 推断；未做 Enterprise license 实测）——审批绑在"取凭据"非"用凭据"上，凭据进 client 后审批失效（与 secretless 哲学相悖，呼应 §7.1）；Web UI 1.13+ 虽有基础 Control Groups approve 入口，但通知 / IAM 集成 / per-Pipeline 联动仍要新建一层。

**矩阵第 5 项精化**：双方覆盖但 Vault 路径无论 OSS 还是 Enterprise，**都要在 Vault 之上再加一层等价于 Connectors AccessPolicy 的应用层**。没有 ROI。

详见 `poc/poc-3/REPORT.md`。

### 6.4 三个 PoC 的综合启示

| PoC | 矩阵原判定 | 实验后判定 | 升级幅度 |
|-----|----------|----------|---------|
| 1 | Vault 单品在该问题域有结构性短板 | 可观测事实：file/env sink 模式下凭据进入 client 进程地址空间后约束权移交 | 论证 → 演示（需补 PoC-1b Vault Agent proxy mode 对照） |
| 2 | Vault 单品不覆盖 imagePullSecret-less DX | 可观测事实：kubelet 不自动选用 ns 内 dockercfg，必须 Pod/SA 显式引用；SA-bound 路径承认但未实测 | 论证 → 演示 |
| 3 | 双方覆盖但模型不同 | OSS 跑通但工程量等价于重写 Connectors 三件套（组件清单类比）；Enterprise 路径基于 spec 调研未实测 | 论证 → 精化 |

**三个 PoC 一起把"Vault 单品在 Connectors 11 问题域中的核心子集（1/2/5）有结构性差异"的结论从论证升级为"可复核 + 可演示"的集群事实**——CEO/leader 汇报会上可现场拉 `kubectl logs` 复现。下一轮 PoC-1b / PoC-2b / Vault Enterprise trial 实测可进一步完整覆盖反方论据。

---

## 7. 结构性差异分析

### 7.1 哲学差异：data-plane proxy vs secret injection

| 维度 | Connectors（data-plane proxy） | Vault（secret injection） |
|------|---------------------------|---------------------|
| 凭据持有者 | **proxy 进程**，从未离开 connectors-system namespace | **client Pod**，明文进入 file / env / K8s Secret |
| client 视角 | 看到的是"代理地址 + 短期 SA token" | 看到的是目标工具真实凭据 |
| 凭据注入位置 | proxy 出栈方向（注入 Basic/Bearer 到上游请求） | client 进栈方向（写到 file / env / kubelet） |
| 吊销方式 | 撤 RBAC，proxy 每请求 SubjectAccessReview，**秒级生效** | dynamic secret 的 `vault lease revoke` 对支持 lease 的后端（DB / Cloud IAM / SSH）**毫秒级 active 吊销已下发凭据**；KV 静态凭据的"已注入凭据" 仍无法撤回 |
| 泄漏面 | 真凭据不可能出现在 `env` / `ps` / core dump / 日志 / 镜像层 | file/env sink 模式下：一旦被 `cat`、`set -x`、`git config --list` 捕获即外泄；Vault Agent proxy / exec / response wrapping / SSH CA / GitHub App installation token 等高级模式可显著缩窄此窗口（应用代码里看不到 token），但仍要 client 信任 Agent sidecar |
| client 改造 | 改 `http_proxy` 环境变量 / 镜像地址改写（admission webhook 自动做）；**无 SDK 依赖** | 装 Vault Agent sidecar（exec / proxy / file sink 多种模式，proxy mode 与 Connectors 哲学等价），或改 task 模板调 vault API |
| 协议依赖 | 必须为每类工具实现 protocol-aware proxy（HTTP / OCI distribution / Maven 等） | 与协议无关，Vault 只发字符串 |

**关键洞察**：在 **"client 完全不可信" 的威胁模型**下，data-plane proxy 模式有结构性优势（client 持的不是凭据，泄漏面被限制在 SA token + RBAC）；在 **"proxy 集中风险" 的威胁模型**下（proxy 进程被 CVE / 镜像后门 / 宿主机逃逸攻破），client-side dynamic credential 有分散失陷的优势。两种模型各有适用场景，**不存在单一"绝对更安全"的判断**。

#### 7.1.1 Connectors data-plane proxy 模式的反向 attack surface（诚实承认）

Connectors 模式的反向风险：proxy 进程被攻破时，**proxy 进程地址空间里所有客户的真凭据一锅端**。Vault dynamic 模式下凭据分散到每个 client 但每个独立。这是 Vault 倡导者的反向 attack surface 论据，本报告诚实承认。在 Alauda 客户场景下，`connectors-system` ns 受 ACP 平台级访问控制 + 镜像扫描 + CVE 响应保护，集中风险与分散风险的实际相对量级取决于客户安全运营成熟度——本调研结论是 **在 "CI 凭据零泄漏" 这一具体目标下，Connectors 模式在 Alauda 主流客户场景的实际威胁面更优**。

### 7.2 与 ACP 平台耦合度差异

Connectors 有 4 处与 ACP 深度耦合，**第三方组件可通过组合复现部分能力，但失去 ACP 单一供应商支持口径 + 同生命周期升级 + 与 IAM 同源的集成度优势**：

1. **PodWebhook + reverse proxy 联动**（问题域 2）：kubelet 通过 SA-token-as-imagePullSecret 走 reverse proxy 拉镜像。**第三方可组合复现**：Kyverno（PodWebhook） + 自建 / 社区 OCI reverse proxy（基于 distribution/distribution 或 goharbor proxy-cache）+ Pod admission 改写。Connectors 的相对优势在于 "集成度 + 与 ACP 同生命周期升级 + 单一供应商支持口径"。
2. **OpenAPI + ResourceInterface + Tekton 前端 descriptor**（问题域 6）：UI 在 Pipeline 配置时按工具语义浏览 branch/tag/project，深度绑定 ACP Tekton 前端插件框架。**这是 Connectors 在 ACP 上独有的产品形态层，与 "secret-store 替代评估" 不在同一抽象层；不应作为 Vault 的减分项**（呼应 §5.1）。
3. **三级 scope + ACP IAM**（问题域 3、4）：`kube-public` / namespace-group / namespace scope 直接挂 ACP IAM 角色绑定，治理委派复用平台 RBAC，与 ACP project / tenant 抽象同源。**Vault Enterprise 可通过 Namespaces + 双向同步 controller 模拟**，但需重建一套 namespace 树。
4. **AccessPolicy 与 Tekton ApprovalTask 同 PipelineRun 联动**（问题域 5）：审批与 CI 流程一体化，绑定 ACP DevOps 模块的 Pipeline 审批 UI。**Vault Enterprise Control Groups 可解一半**（Web UI 1.13+ 有基础 approve 入口），但通知 / IAM 集成 / per-Pipeline 联动仍需新建。

这 4 项不是"Vault 没做"，是"Vault 模型本身不在这层" + "可通过第三方组件组合逼近但失去集成度优势"——即便引入 Vault，仍需自建或集成 4 套适配层。

### 7.3 商业模型差异（CEO 视角）

| 维度 | Connectors | Vault Enterprise |
|------|-----------|-----------------|
| License 模型 | 随 ACP 平台 entitlement，无独立 SKU 计费 | 按 active client / cluster / SKU 分层计费；公开 list price 不可得，需走 HashiCorp / IBM 商务流程获取正式 quote。`[需 sales/finance 复核]` |
| 商业边界 | 完全 Alauda 自主 | HashiCorp 商业路线图制约；现归属 IBM（2025-02 收购完成）|
| 客户决策路径 | 平台采购 = ACP 整体 | 客户需独立采购 Vault Enterprise license + 通过 HashiCorp（IBM）独立商务流程；引入独立预算审批、法务、续约风险 |
| 与 "开源标准 + 全栈自主" 定位 | **完全契合** | **存在张力**：核心治理能力（多租户、审批）依赖第三方商业产品 |

### 7.4 HashiCorp Boundary 是否构成新威胁？

本报告评估的是 Vault **单品**。HashiCorp 整套零信任栈是 **Vault + Boundary + Consul**：

- **Boundary** 是 HashiCorp 自家的 zero-trust remote access 产品，**做 data-plane proxy**——在哲学上与 Connectors data-plane proxy 模式同形，是 Vault 阵营对 "凭据不进 client" 问题的官方正面回答。
- **Consul Connect** 提供 service mesh 形态的 mTLS + 短期身份。

**Boundary 对 Connectors 核心问题域是否构成替代？结论：不构成。**

- Boundary 聚焦 **SSH / RDP / DB / TCP 协议代理**，**不**做 HTTP / Git / OCI distribution 协议代理；
- Connectors 的核心问题域（Tekton task 跑 `git clone` / 跑 `docker push` / kubelet 拉私有镜像）都是 HTTP + OCI 协议；
- Boundary 在 Alauda 客户的 air-gap 部署需要独立 license + 二次集成，超出 "Vault 是否替代 Connectors" 的命题范畴。

**但 Boundary 的存在改变了一件事**：本报告 §7.1 的 "data-plane proxy 是哲学差异" 不应被读为 "Vault 阵营完全没有 data-plane 概念"。Vault 阵营有 Boundary 这条路线，只是 Boundary 与 Connectors 的协议覆盖面与产品边界不同。**若未来 CEO 命题扩展到 "HashiCorp 整套栈是否替代 Connectors"，结论需另做调研**。本调研严格限定在 "Vault 单品替代 Connectors" 这一问题。

---

## 8. Vault 改造范围估算（反事实分析）

本调研结论为"不能替代"，故本节非强制；但 Jira 模板要求展示"若硬走改造路线，工作量量级"，便于决策者权衡。

### 8.1 需要新增/修改的组件

| 组件 | 是否能基于 Vault upstream 实现 | 可复用上游 / 社区组件 | 工程量估算（乐观-中性-悲观） |
|------|-----------------------------|---------------------|--------------------------|
| **HTTP / Git / OCI / Maven protocol-aware proxy** | 否——Vault 不在 data path 上；需独立组件 | HashiCorp **Boundary** 做 protocol-aware proxy（SSH/RDP/DB/TCP，但**不**覆盖 HTTP/Git/OCI）；可参考但不可直接复用 | 0.5-1.5-3 人年（取决于 Boundary 二次开发可行性评估） |
| **OCI reverse proxy + PodWebhook** | 否——Vault 生态无此能力 | **Kyverno**（PodWebhook mutate，CNCF Graduated）+ **distribution/distribution**（CNCF Sandbox 的 distribution proxy）+ Harbor proxy-cache | 0.5-1-2 人年（最大化复用社区组件） |
| **跨工具 ResourceInterface + UI 后端** | 否——Vault 无 catalog 抽象 | 无直接可复用项；与 ACP Tekton 前端 descriptor 对接需自研。**注**：此项不属于 Vault 替代范围（呼应 §5.1 / §7.2），算作 Connectors 产品形态层的自研增量 | 1-1.5-2 人年 |
| **审批桥**（Tekton ApprovalTask ↔ Vault Control Group） | 部分——需要 Vault Enterprise | Tekton `CustomRun` + 现成 `manual-approval-gate`（PoC-3 已用）+ Vault Enterprise Web UI Control Groups 入口 | 0.2-0.5-1 人年 |
| **Vault operator / HA / unseal 治理工具链** | Helm + 自动化脚本即可，但生产化要纳入 ACP operator 升级体系 | hashicorp/vault-helm + **banzaicloud/bank-vaults** operator（社区成熟）+ vault-k8s | 0.2-0.5-1 人年 + 持续维护 |
| **多租户语义对齐**（Vault namespace ↔ ACP project） | 需双向同步 controller | vault-secrets-operator 已有 namespace 模式可参考 | 0.2-0.5-1 人年 |

**累计工程量量级（视社区组件复用度浮动）：**

- **乐观（最大化复用 Bank-Vaults / Kyverno / distribution upstream / Tekton CustomRun）：约 3 人年**
- **中性（部分复用 + 关键集成层自研）：约 5-6 人年**
- **悲观（最大化自研，少用社区组件）：约 9 人年**

**总结：3-9 人年（视社区组件复用度浮动）**。即便取下限，仍 ≈ 重写主体功能 + 引入 6 组件供应链 + 失去 ACP 单一供应商支持口径 + 同生命周期升级。**单 Vault 倡导者口径** 给出的 2-4 人年估算（基于 Boundary / Kyverno / bank-vaults 等成熟生态项目）作为更激进的下限参考，本报告采用 3 人年作为中庸下限。

### 8.2 Vault upstream 关系

| 关系 | 说明 |
|------|------|
| Fork | 不建议——Vault 是单一上游商业产品，fork 后无法享受 Enterprise feature |
| Patch | 不可行——Enterprise 是闭源 |
| 完全独立组件 + Vault 作为后端 | 唯一可行路径，但 Vault 仅承担 KV 存储角色，无差异化优势 |

### 8.3 长期维护成本

- 6 组件版本兼容矩阵
- Vault Enterprise license 续约风险（IBM 收购后路线图变动）
- 客户故障定位横跨 6 组件
- 长期 SRE FTE 估算 1-2 人

### 8.4 与"维持现状"路径的对比

| 维度 | 维持 Connectors | 改造 Vault 路线 |
|------|--------------|--------------|
| 初始工程投入 | 0（继续既定 roadmap） | **3-9 人年** |
| 客户额外 license | 0 | Vault Enterprise 独立 SKU `[需 sales/finance 复核单价]` |
| 团队结构变化 | 无 | 新增 Vault 专家岗 + 6 组件 owner |
| 时间窗口 | 立即 | **2-3 年才能达 Connectors 当前能力面** |
| 失败回滚成本 | 0 | 期间客户已上线 Vault Enterprise，难以回滚 |

**反事实结论**：改造路线在 Alauda 当前主流客户场景下 ROI 不正；少数已有 Vault Enterprise 大规模投资 + 客户重叠度高的场景需单独评估（不在本调研范围）。

---

## 9. air-gap 与运维成本对比

### 9.1 初装步数 / SRE 操作面对比

| 维度 | Connectors（current） | Vault Enterprise（air-gap） |
|------|---------------------|-------------------------|
| 安装步数 | OperatorHub 装 operator → 编辑 ConnectorsConfig 一个 CR | Helm 装 3-5 节点 Raft 集群 → unseal 流程 → TLS cert → audit device → kubernetes auth → policy/namespace 配置 |
| Unseal 治理 | 无（K8s 原生组件） | Shamir 3-5 key holder 联合解封 / Transit auto-unseal 鸡蛋问题 / HSM auto-unseal 需 Enterprise + 硬件 |
| 升级路径 | OLM InstallPlan / CSV，与 ACP 一体 | Helm 滚动 + Raft leader step-down + storage schema 升级（少数版本需停机） |
| 备份恢复 | etcd / GitOps（标准 K8s） | `vault operator raft snapshot save/restore`，自建 cron + 异地存储 + 演练 |
| 长期 SRE 负担 | 复用 ACP 升级流程 | 初装 1-2 人周；长期 0.2-0.5 SRE FTE |
| 客户独立采购物料 | 0（ACP 一体） | Vault Enterprise license（独立 SKU）+ 可选 HSM 硬件 + 可选 IBM 商务关系 |

### 9.2 PoC 实测：从 dev 模式到生产可用，至少需要补齐 8 项工作

> 来源：本次 PoC 在 `devops-valult-invest` ns 部署 Vault dev 模式后整理（详见 `poc/00-vault-setup-log.md` 附录）。**air-gap 场景每一条都要在内网仓库 + 内网镜像源 + 内网证书体系下重新搭建**。

| # | 项目 | 工作量 / 复杂度 |
|---|------|------------|
| 1 | **HA 集成存储** | 从 `-dev` 切到 `storage "raft"`，最少 3/5 节点奇数 StatefulSet + PVC + 跨节点反亲和 + raft `retry_join` + 节点替换 runbook |
| 2 | **Unseal / Auto-unseal** | air-gap 没有云 KMS → Shamir 多人持密钥（每次集群重启走人工流程） / Transit auto-unseal（鸡蛋问题） / HSM auto-unseal（Enterprise + 硬件采购） |
| 3 | **TLS** | 所有 listener 启用 TLS（含 raft 内部通信），证书走客户内部 CA、证书轮换流程、K8s auth `kubernetes_ca_cert` 切换 |
| 4 | **备份 / 灾备** | raft 快照定时上传 air-gap 对象存储 + 保留策略 + 异地副本 + 恢复演练 runbook |
| 5 | **审计 / 监控** | audit device（file/socket）→ SIEM；Prometheus 抓 `/v1/sys/metrics` + sealed/leader/token-rate 告警 |
| 6 | **policy / namespace / 多租户治理** | root token 离线封存；按项目划 Vault namespace（**Enterprise**） + GitOps policy 审阅 |
| 7 | **License**（关键卡点） | Namespace / Performance Replication / DR Replication / HSM seal / Sentinel 全部 **Enterprise only**；air-gap 还要走线下许可证文件 + 续期管理 |
| 8 | **镜像与升级路径** | 内网 mirror 持续同步上游版本，CVE 跟进 + 滚动升级 SOP（raft 可零停升级，需校验 plugin 兼容 + storage schema 迁移） |

**对照 Connectors**：以上 8 项中 **0 项** 需要做——Connectors 作为 K8s 原生组件随 ACP 升级流程走，无独立 unseal、无独立有状态系统、无独立 license。

**SRE 介入频次对比**：

| 事件 | Connectors | Vault Enterprise |
|------|-----------|-----------------|
| 集群冷启动 | 0 SRE 介入 | 3-5 人键到场（Shamir 模式）/ KMS 依赖（auto-unseal 模式） |
| 升级到下一 minor 版本 | OLM InstallPlan 一键 | 滚动 + leader step-down + plugin 兼容性校验 |
| CVE 紧急补丁 | OLM 推送 | Helm + 测试 + 滚动 + 验证 |
| 节点替换 | 标准 K8s 操作 | raft 节点 join/leave SOP |
| 备份恢复演练 | 标准 etcd | vault raft snapshot save/restore 全流程 |

---

## 10. 决策建议

### 10.1 三选一明确结论

**结论：Vault 不构成 Connectors 的完整替代**（约束在 §1.5 边界界定 + §2.3 反方场景之外的 Alauda 主流客户场景）。

证据闭环（五者共同支撑）：

| 支撑维度 | 证据 | 章节引用 |
|---------|------|---------|
| **覆盖矩阵** | 11 问题域中，问题域 1（CI secretless）、2（K8s 镜像拉取）Vault 单品不覆盖（生态可组合逼近但失去集成度优势）；问题域 6（UI 资源选择器）是 Connectors 产品形态加值非 Vault 减分项；问题域 3/4/5 必须 Enterprise；问题域 7（dynamic secret）Vault 在 DB / Cloud IAM / GitLab / GitHub App / Artifactory 上**强于** Connectors | §5 |
| **PoC 验证** | PoC-1 演示：file/env sink 模式下凭据进入 client 后约束权移交（需补 PoC-1b Vault Agent proxy mode 对照）；PoC-2 演示：kubelet 不自动选用 ns 内 dockercfg，必须 Pod/SA 显式引用；PoC-3 演示：Vault OSS 审批门控近似 UX 不可生产，Enterprise Control Group 路径基于 spec 调研未实测（Web UI 1.13+ 有基础 approve 入口） | §6 |
| **结构性差异** | data-plane proxy vs secret injection 在两种威胁模型下各有优势；4 处 ACP 平台耦合可通过第三方组件组合逼近但失去 ACP 单一供应商支持口径 + 同生命周期升级 | §7 |
| **客户价值** | 4 类客户决策者在 Alauda 主流场景下不会买单切换；少数反方场景（合规清单指定 / 已有 Vault 团队 / DB dynamic 为主 / IBM 紧密客户）需单独评估；TCO 量级具体数字需 sales/finance 复核；与"开源标准 + 全栈自主"定位存在张力 | §2 |
| **战略投入** | 切换后不能节省团队投入，反而引入 6 组件供应链与故障面；护城河 4 项是 ACP 平台独有形态 | §3 |

### 10.2 Roadmap 具体动作（含建议性 owner + 衡量指标）

| # | 动作 | 优先级 | 时间窗 | Owner（建议） | 衡量指标 |
|---|------|------|------|--------------|---------|
| 1 | **维持现状**：Connectors 三仓库（connectors / connectors-extensions / connectors-operator）的既定 roadmap 不做调整，不启动"迁移到 Vault"或"基于 Vault 重构"任何项目 | P0 | 立即生效 | Connectors PM | 三仓库 main 分支无新增 Vault-related epic |
| 2 | **推进 Vault 不可达的差异化能力 GA**：`enable-pod-image-pull-via-connector`（DEVOPS-43259）和 `enable-connectors-approval`（DEVOPS-44094）按既定计划 GA | P0 | 当前 release cycle `[需 Connectors PM 确认具体 cycle]` | Connectors PM + 对应 feature owner | feature flag off → on；3 个 design partner 验证通过 |
| 3 | **沉淀本调研为对外白皮书**：以本报告为基础产出对外可用的 "Why Alauda Connectors vs HashiCorp Vault" 白皮书 | P1 | 1 个月内（建议） | `[需产品/PMO 后续指定]`（建议候选：Connectors PM 主笔 + ACP marketing review + 1 名 SE leader review） | 3 个月内被 ≥ 3 家在洽客户引用；SE 反复解释时间下降 |
| 4 | **明确 Vault 互操作姿态（非替代）**：在用户文档加一节 "Working with Existing Vault"，演示三种 interop 模式：(a) Vault KV via ESO → K8s Secret → Connector 输入（已支持）；(b) Vault Agent Injector / VSO / CSI provider 任一作 Connector 输入；(c) Connectors proxy 后端凭据可托管在 Vault | P2 | 与白皮书同步 | `[需产品/PMO 后续指定]`（建议候选：Connectors PM + 用户文档 owner） | 文档发布；若现有客户中有 ≥ 1 个 "Vault + Connectors 互操作" 案例，纳入文档；若无以 reference architecture 形式给出 |
| 5 | **销售一线 battle card（新）**：把本报告浓缩成 2 页销售一线 battle card，作为 30 天调研收益沉淀的最低要求 | P1 | 2 周内（建议） | `[需产品/PMO 后续指定]`（建议候选：Connectors PM + sales enablement） | battle card 进入 sales kit；分发到一线 SE |
| 6 | **明确停止/暂停的项目**：**无**——本调研未发现需要停止/暂停的 Connectors 子项目；判断依据：所有 Connectors 子项目都映射到客户场景中 Vault 不可达或集成度显著优于 Vault 的能力域 | — | — | — | — |
| 7 | **明确 Vault adapter 产品姿态**：Connectors 不主张替代 Vault；如客户已有 Vault，Connectors 提供原生 interop（见动作 4 三种模式）。这不是 "Vault adapter"，是 "凭据存储层与 data-plane proxy 层的解耦协作"。**短期不启动独立 "Vault adapter" 项目**；如客户场景验证显示大规模 Vault Enterprise 投资客户重叠度 > 30%，可重新评估 | — | — | — | — |

> **说明**：本表给出建议性 owner，实际指派需 PM 主持的对齐会议确认。所有标注 `[需产品/PMO 后续指定]` 的动作在对齐会议前不假装具体；标 P0 的动作 1/2 是 Connectors PM 主责范围内可立即推进的。

### 10.3 进一步评估的触发条件

本报告已基于当前可获信息得出明确结论；如未来出现以下变化，应触发重新评估：
- **场景 A**：客户场景验证显示大规模 Vault Enterprise 投资客户重叠度 > 30%（需 sales 数据回收）。
- **场景 B**：Vault / HashiCorp 出现根本能力变化（如 Vault Enterprise 主动出 data-plane proxy 模式覆盖 HTTP/Git/OCI 协议）。
- **场景 C**：客户合规清单或 IT 标准强制指定 Vault 的占比显著上升。
- **场景 D**：HashiCorp Boundary 扩展支持 HTTP / Git / OCI 协议（当前不支持，详见 §7.4）。

### 10.4 若结论为"改造后可替代"的反事实分析

为完整性给出：若硬走 "Vault 改造可替代" 路线，**改造范围 ≈ 重写 Connectors 中 ACP 平台耦合的主体功能**（具体 3-9 人年，见 §8）。该路径在 Alauda 当前主流客户场景的现实意义：把 Alauda 的工程投入花在重写而非演进 Connectors，**在客户付费意愿、团队产能、战略定位、竞品防御四个维度同时倒退**。

---

## 11. 风险与未决问题清单

### 11.1 Connectors 自身存在、但 Vault 也无法解决的问题（不应作为 Vault 的减分项）

| 问题 | 说明 |
|------|------|
| **真凭据轮换仍需管理员/外部流程**（且 Vault 在部分工具上**强于** Connectors） | Connectors 只短期化"客户端代理凭据"（SA token），真实 Git PAT / Harbor robot 密码长期存活在 K8s Secret 里。**Connectors 在 GitHub App / GitLab（1.18+ 官方 engine）/ Artifactory / DB / Cloud IAM 上的 dynamic credential 能力显著弱于 Vault**；如客户场景以这些工具为主，Vault 在凭据短期化维度有结构性优势——这一项不是 Vault 的相对劣势，反而是 Vault 的强项 |
| **审计粒度依赖 ACP 日志平台聚合** | Connectors 无原生 audit dashboard；Vault Audit Devices 有原生 dashboard 但**只覆盖凭据领取**，不覆盖凭据使用——两者各有缺口。Connectors audit dashboard 是 Connectors 的合理 roadmap 项 |
| **CSI driver 高可用与节点失效场景** | CSI DaemonSet 节点故障时短暂影响 Pod 启动；**已运行 Pod 不受影响**（CSI 只在 mount 阶段介入），仅新 Pod 在该节点的启动延迟到 CSI driver 恢复。这是 K8s CSI 模式的固有局限，与凭据系统选型无关 |
| **新 connector 类型 onboarding 仍有工程量** | 一份 ConnectorClass YAML 是最小代价，但加新 connector 类型到 operator 需要 CRD + controller + bundle 更新；Vault 上加新工具（如有官方 engine）工程量可能更小（mount + 配 role 1-2 天）——这一项 Vault 在有官方 engine 的工具上反而更轻 |
| **ConnectorClass + ResourceInterface 是 Alauda 自创抽象，客户也要学** | "OperatorHub 一键装" 简化了部署，但客户使用时仍需理解 Connector / ConnectorClass / ResourceInterface 等 Alauda 自定义概念，与 Vault Agent / VSO 的学习成本是不同的曲线而非零曲线 |

### 11.2 调研时间内无法定论、需要后续深入的事项

| 事项 | 后续行动 |
|------|---------|
| **air-gap 客户实际是否能/愿用 Vault Enterprise** | 向 product/sales 团队取 3-5 个典型客户的实际反馈，确认假设 (2)（air-gap 不能用 Vault）的成立度 |
| **HashiCorp 被 IBM 收购后 Vault Enterprise 路线图与定价稳定性** | 通过 Gartner / Forrester 报告或客户案例追踪，6-12 个月窗口观察 |
| **Connectors 自身是否需要补 audit dashboard / dynamic secret 接 Vault 互操作** | 与 ACP 日志团队、可能的客户场景对齐；纳入下一 release cycle 的产品规划 |
| **是否将本调研写成对外白皮书的 ROI** | 与 marketing 对齐，评估 sales-engineering 时间节省与战略防御价值 |
| **Vault 社区是否会出 "K8s reverse proxy for OCI" 类型 plugin** | 持续观察 Vault community plugin 与 CNCF 生态，3-5 年窗口 |
| **Boundary 是否扩展支持 HTTP / Git / OCI 协议** | 当前 Boundary 仅 SSH/RDP/DB/TCP；如扩展支持 HTTP 协议代理，需触发重评（详见 §10.3 场景 D） |
| **Connectors 的产品独立性战略问题** | 本调研未覆盖；CEO 在"不切换" 结论后必然追问的下一组问题：是否独立产品化 / 是否开源核心 / 是否作为 ACP 标配 vs 可选模块 / 是否对外提供 standalone 商业版——这些超出本调研范围，需独立战略评审 |

### 11.3 报告本身的限制

- **PoC 在 dev 模式 Vault 单 Pod 上跑**，未模拟生产 HA + unseal + Enterprise feature；但本调研的核心结论都建立在 Vault 模型本身的结构性 gap 上，不依赖生产规模行为差异。
- **未与 Connectors 团队 PM、ACP 销售线、典型客户做正式访谈**——客户价值章节的成本估算基于公开 license 数据 + 历史 air-gap 客户运维负担推断。结论的工程证据扎实，商业部分如需进一步证据可补访谈。
- **Vault Enterprise feature 仅基于官方文档 spec**，未实际试用 Control Groups / Sentinel / Namespaces。这是 license 限制；不影响"Vault Enterprise feature 存在但仍解决不了 Connectors 三大结构性 gap"的核心论断。

---

## 附录 A：调研输入材料索引

- `inputs/01-connectors-domain-map.md`：Connectors 11 问题域机制图 + 核心架构哲学 + 护城河能力
- `inputs/02-vault-capability-map.md`：Vault OSS/Enterprise 能力图 + 7 项结构性 gap + Enterprise 商业冲击
- `inputs/03-other-tools-capability-map.md`：ESO / SPIFFE+cert-manager / Crossplane 对照矩阵（含 4 工具汇总表）
- `inputs/04-history-retrospective.md`：Connectors 立项时间轴 + 5 条核心假设 + 当年未选 Vault 的推断

## 附录 B：PoC 实验材料索引

- `poc/00-vault-deploy.yaml`：Vault dev 模式 K8s manifest
- `poc/00-vault-setup-log.md`：部署与自验日志 + "生产化要做什么"
- `poc/poc-1-*`：PoC-1 secretless CI（Vault Agent + Tekton vs Connectors Forward Proxy）
- `poc/poc-2-*`：PoC-2 K8s 镜像拉取（Vault 路径可行性）
- `poc/poc-3-*`：PoC-3 审批门控（Vault K8s Auth + 外部审批等价模型）
