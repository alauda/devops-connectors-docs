# Connectors vs Vault — 关系、边界、Roadmap 启发

> **摘要**：Connectors 与 Vault 不是替代关系，而是不同问题域的不同范式。Connectors 是 CI/CD 场景下的"业务侧 secretless"（凭据进不了 Pod），Vault 是组织级"secret 集中数据面"（凭据短寿命 + 全 Vault 治理）。建议对 Connectors 内"短期凭据"问题域优先考虑 Vault 集成；对 Connectors 独有问题域（CI Secretless / 镜像拉取 / UI 资源选择 / 审批等）继续自研。
>
> Vault 背景见 `vault-capabilities-guide.md`。

---

## 1. Connectors 的问题域

| 问题域 | 解决什么 | 大致做法 |
|---|---|---|
| **CI Secretless** | Tekton task 里业务永远拿不到真凭据 | Connectors Proxy 在 connectors-system 持真凭据；CSI Driver 用 Pod SA 签短 token（默认 30m TTL），通过**面向协议 / 工具的配置文件模板**（`.gitconfig` / `glab config` / `maven settings.xml` 等）挂进 tmpfs，业务进程当普通配置读；Proxy 出栈方向走**面向协议 / 工具的认证注入**——协议层（HTTP Basic / Bearer）保协议**通用性**，工具层（OCI Token Auth / Harbor Token Auth 等）保**面向工具的 native 体验** |
| **K8S 镜像无凭据拉取** | 业务 Pod 不引用 imagePullSecret 即可拉私有镜像 | `PodWebhook` 改写 Pod image 到 reverse proxy 地址；kubelet 走 reverse proxy 拉镜像；imagePullSecret 用 SA token 包装，Harbor robot 真密码只存在 connectors-system |
| **CI/CD 集成原生** | Connector 作为 Tekton 一等公民可被 task 直接消费 | CSI workspace 绑定 Connectors & 渲染配置，task 使用配置文件 |
| **工具透传 API** | 业务 / UI 不直连工具 API，统一走 Connectors API server，认证由 Proxy 层处理 | `ConnectorClass.spec.api.openapi` 声明对外暴露的工具 API 子集；调用方走 `Connectors API`（用 SA token），server 后端代用户 SA token 调 Proxy 拿真实数据 |
| **Pipeline UI 展示工具资源** | Pipeline 编辑页直接列出 Harbor 镜像  / Git 分支 / Github PR，用户下拉选择 | 前端 Tekton descriptor 调 `Connectors API` 拿工具数据；与 1.4 同根，区别在 1.4 是后端 API，1.5 是前端 UX，**认证统一在 Proxy 层** |
| **审批门控原生** | 使用 connector 访问敏感工具时需先经审批才能调用 API | `AccessPolicy` + `AccessRequest` CR 与 Tekton `ApprovalTask` 在同一 PipelineRun 内联动；拒绝则 CSI 挂 `.error.json`，Pod 启动即失败 |
| **三级 scope 治理** | Connector 资源天然有 cluster / project / namespace 三层，满足集群共享，项目共享，命名空间隔离 三种场景 | `kube-public` = cluster-level；带 `cpaas.io/inner-namespace` 标签的 namespace-group = project-level；普通 ns = namespace-level；委派落到 RBAC RoleBinding |

**Connectors 边界（不解决什么）**：不是通用 KV / 配置中心；不是 KMS / 加密服务；不是凭据轮换器（外部工具真密码靠管理员手工或外部流程轮换）。

---

## 2. Vault vs Connectors 能力对比

| # | 问题域 | Connectors | Vault | 判定 | 用户体验差异 |
|---|---|---|---|---|---|
| 1 | CI Secretless | data-plane proxy，client 看不到真凭据 | secret injection 把凭据物化到 Pod 文件 / env | 理念差异， 仅 Connectors 覆盖 | Connectors：client 配 `http_proxy` 或读 `.gitconfig` / `glab config` / `maven settings.xml` 即可，零 SDK；Vault：每个 task 写"取 secret → 用 secret"，PAT 仍可能被日志 / git config / env 泄漏 |
| 2 | K8S 镜像无凭据拉取 | PodWebhook 改 image + SA token 拉 | 只同步 dockerconfigjson，无"代拉镜像"机制 | 仅 Connectors 覆盖 | Connectors：Pod 加 annotation 即可；Vault：每 ns 投递 Secret + 所有 SA 引用 + 凭据轮换不影响运行中 Pod 下次拉取 |
| 3 | 平台治理 + 多租户 | 三级 scope (cluster, project, namespace) | OSS：path-glob；Enterprise：Namespaces | 双方覆盖（模型不同） | Connectors：与 ACP RBAC 同源，平台管理员零额外学习；Vault：HCL policy / entity / namespace 另一套权限模型，需独立培训，在 Vault 内重建 namespace 树 + 与 ACP project 双向同步 |
| 4 | 审批门控 | `AccessPolicy` + `AccessRequest` + `ApprovalTask` | Control Groups（Enterprise only），OSS 无 | 双方覆盖（模型不同） | Connectors：与 ACP Pipeline 审批 UI 一体，审批人 PipelineRun 同屏点击；Vault：审批人走 vault CLI / API，需自建一套 UI |
| 5 | 工具透传 API / Pipeline UI 选资源 | ResourceInterface + Connectors API + Proxy 透传 | 不在 Vault 范围内 | 仅 Connectors 覆盖 | Connectors：UI 下拉选 branch / tag / project；Vault 路线：每个工具单独写 UI + API client + 跨工具适配 |
| 6 | 凭据轮换 / 短期化 / 吊销 | 短期化客户端 SA token（30m），**真凭据靠管理员手工轮换** | 动态凭据现造 + lease；database / openldap / ad engine 原生轮换 | 理念差异， 双方部分覆盖（Vault 在动态维度结构优势） | Connectors：客户端只看 SA token，30m TTL 自动失效；Vault：即使短期化，凭据"取下来已被写进 git config / log / env"，Vault 无法约束 client 拿明文后的行为 |
| 7 | 审计 | K8s audit + AccessRequest + Proxy access log | Audit Devices 全 API 请求 | 双方部分覆盖（互补） | Connectors：data plane 上能 deny / rate-limit；Vault：只能事后追溯 |
| 8 | 热轮换不断流 | 反向代理 + SA token TTL，请求级注入 | Vault Agent / VSO + 业务 reload | 双方部分覆盖（Connectors 优） | Connectors：客户端零感知；Vault：取决于 app 是否支持 SIGHUP / reload；env 注入必须重启 |
| 9 | 新工具 onboarding 成本 | 一份 ConnectorClass YAML + 可选 Proxy Workload | KV 存凭据 + 每工具重写消费方式 | Connectors 优（数量级差异） | 接入新 SaaS 到完整体验：Connectors 数天到数周；Vault 路线数倍工程量 |

### 不在 Connectors 问题域内的 Vault 能力

> Connectors 不主动覆盖这些方向，不构成 "Connectors 不足"——边界外，仅供参考。

| Vault 能力 | 含义 | 备注 |
|---|---|---|
| **通用 secret 存储（KV v2）** | 集中、版本化、RBAC、审计的 KV 字典 | Connectors 仅管"工具凭据"，不是通用 KV |
| **加密即服务 / KMS 对等物（Transit）** | 业务不持 key 加解密 / 签名，key 永不出 Vault | 不在 Connectors 问题域 |
| **跨集群复制 / 容灾（Replication）** | Performance + DR 流式复制（Enterprise only） | ACP federation 层解决，不在 Connectors 范围 |
| **复杂策略表达（Sentinel）** | 条件 / IP / MFA / 行为断言的 Policy-as-Code（Enterprise only） | Connectors 用 K8s RBAC + AccessPolicy，不引第二套策略语言 |

### 哲学差异一句话

> **Connectors = "凭据永远进不了客户端"**（data-plane proxy，真凭据死守在 connectors-system）。
> **Vault = "凭据短到不值得偷 + key 永不出 Vault"**（集中数据面 + 动态短寿命 + 加密服务）。

---

## 3. 集成边界与 Roadmap 启发

**自然边界**

- Vault 不替代 Connectors：CI Secretless / 工具透传 API / Pipeline UI 资源选择 K8S 镜像无凭据拉取 - Vault 结构上不覆盖
- Connectors 不替代 Vault：通用 KV / Transit 加密 / 凭据轮换 - 不在 Connectors 问题域

**集成边界**

> **Vault 负责凭据存储(长周期/短周期)，Connectors 负责使用 & 客户端永远拿不到凭据。**
>
> **Connectors 中所有"短周期凭据" 诉求都应思考如何结合 Vault 实现**。
> 例如: 当前 Connectors 用 Automation Task 刷新工具凭据；结合 Vault 后这一职责可考虑移给 Vault 插件

### 集成方向

> 三个方向逻辑递进：方向 1 是架构基础（不依赖 Vault），方向 2 是在它上面的具体集成（带 Vault），方向 3 是另一条无侵入路径。

**方向 1：在 Connectors 内抽象 `SecretBackend` interface（架构演进，独立于 Vault）**

- 解耦 "Connector 引用的 secret 从哪来" 这件事：
  - 默认实现：K8s Secret（保持现状，air-gap 客户开箱即用）
  - 可选实现：**Vault**、**OpenBao**（Vault 的 AGPL fork，Linux Foundation 托管，API 兼容）、AWS Secrets Manager、Azure Key Vault 等
- **价值**：Connectors **不绑死 K8s Secret**，复用客户已有 secret store 投资；这件事本身价值独立——即便客户不用 Vault，AWS SM / Azure KV 投资也能直接对接
- **关键定位**：这是产品架构演进，**不是为 Vault 而做**——Vault 只是它众多 backend 实现之一

**方向 2：基于方向 1，以 Vault / OpenBao 为后端实现短周期凭据**

- 在方向 1 的 `SecretBackend` 抽象之上，落地 Vault / OpenBao backend 实现
- VSO 把动态凭据（GitLab Project token / GitHub App / Artifactory / DB 等；按需新建 SonarQube / Harbor 短周期凭据 vault 插件）同步到 K8s Secret 或 Connectors 内存
- Connectors 引用这份短周期 Secret 作为工具凭据，Proxy 出栈方向注入
- **价值**：`短周期凭据` + `客户端永远拿不到真凭据`—— 两个优势叠加

**方向 3：Vault 动态凭据 + 工具配置模板，直接挂载到 Pod**

- 简化架构，不走 Connectors Proxy，把 Vault 动态凭据通过 Connectors 的配置文件模板机制（`.gitconfig` / `glab config` 等）直接挂载到 Pod
- Task 层面 0 侵入（业务读配置文件即可）
- **优势**：极简集成路径，无需经过 Connectors Proxy
- **折中**：
  - 业务进程持有了凭据（即便短期），哲学上不再是 secretless——适合不要求 client 完全无凭据的场景
  - 需要额外考虑 透传 API / Pipeline 资源选择 场景如何实现

**🟡 待审视的开放问题**

- **Connectors 审批 + Vault/OpenBao 审批的协同模式**
  - **价值**: 客户 已有 Vault 投资 + 已有合规审计要求 时，复用已有 Vault 审批机制。
- **K8s Image Pull Secret 用 Vault 提供 Harbor 短周期凭据的可能性**
  - 提供 Harbor 短周期凭据 Vault 插件 + VSO
  - **价值**: 与社区标准生态对接


### Roadmap 启发

**可考虑**

- **方向 1 优先**：评估 `SecretBackend` 抽象的工程量；即便不上 Vault 也有独立价值（AWS SM / Azure KV 客户场景）
- **方向 2 紧随**：基于方向 1 落地 Vault / OpenBao backend，优先 GitLab / GitHub App / Artifactory / DB 等已有 vault 插件的工具
- **按需新建 SonarQube / Harbor / Nexus 短周期凭据 vault 插件**

**探索**

- Vault 动态凭据 + 工具配置模板，直接挂载到 Pod
- Connectors 审批 + Vault/OpenBao 审批的协同模式
- K8s Image Pull Secret 用 Vault 提供 Harbor 短周期凭据


**明确不做**
- 不做 Vault OSS 替代品（KV / Transit 不进入 Connectors 问题域）
- 不重写 Vault 已经成熟的能力（凭据轮换 / PKI / Transit）
- 不引入 Vault Enterprise 作为强依赖（air-gap 客户场景大量没有 Enterprise；可推 OpenBao 替代）

---

**相关文档**
- `vault-capabilities-guide.md` — Vault 能力速览 + 13 章详谈 + §14 OpenBao 详谈
- `connectors-insights-from-vault.md` — Vault 给 Connectors 的启发清单
- `inputs/01-connectors-domain-map.md` — Connectors 11 维问题域机制说明
