# 其他对标工具能力对照表（ESO / SPIFFE+cert-manager / Crossplane）

> 配套 `02-vault-capability-map.md`，目的是把 Vault 之外、与 Connectors 落在**同一问题域**的三类典型工具放进同一张能力矩阵，供 CEO 级"Vault 能否替代 Connectors"调研横向比较。
>
> 评级规则（与 Vault 报告一致）：
>
> - **原生支持**：开箱即用，是该工具的核心场景之一
> - **部分支持**：能做但需要拼装多个组件 / 自定义开发
> - **不支持**：完全不在该工具的产品边界内
>
> 每一格只描述"它在这个问题域上**做什么 / 不做什么**"，不复述工具的全功能。

---

## 工具 1：External Secrets Operator (ESO) + 后端

### 定位

ESO 是 Kubernetes 上的"**外部密钥同步器**"——把外部 secret store（AWS Secrets Manager / Azure Key Vault / GCP Secret Manager / HashiCorp Vault / 1Password 等 80+ provider）里的 secret 拉到集群里**生成 K8s 原生 Secret 对象**，并按 `refreshInterval` 周期性 reconcile。CRD：`SecretStore` / `ClusterSecretStore`（定义后端 + 鉴权）+ `ExternalSecret` / `ClusterExternalSecret`（声明"我要哪些 key、生成什么 Secret"）。

**关键架构事实**：ESO 自己**不存** secret，只做同步；最终 client 仍然消费的是 K8s `Secret`。这决定了它在很多问题域上的能力边界。

### 11 问题域评分

| # | 问题域 | 评分 | 说明 |
|---|--------|------|------|
| 1 | CI secretless | **不支持** | ESO 把 secret 落到 K8s `Secret`，CI Task 通过 `secretRef` 挂载 → **凭据明文进入 Pod env / volume**。client 仍能 `cat` 出来。这恰恰是 Connectors 的反面：Connectors 不下发凭据，只下发 endpoint。 |
| 2 | K8s 镜像拉取 | **部分支持** | 可以同步外部 store 里的 dockerconfigjson 到 `imagePullSecret`，但**每个 namespace 仍需挂载该 Secret**、CR 仍要写 `imagePullSecrets:`；ClusterExternalSecret + namespace selector 可以批量复制。**不解决** "Pod 无需声明 imagePullSecret"。Connectors 的 PodWebhook 拦截方案 ESO 没有。 |
| 3 | 平台治理 + 委派 | **部分支持** | `ClusterSecretStore` 定义全局后端连接（治理面），`ExternalSecret` 在租户 namespace 里按需引用（委派面）。但"谁能引用哪个 ClusterSecretStore"靠 RBAC + Kubernetes namespace 隔离实现，**没有"项目→工具实例→credential"的语义层**，治理粒度只到 secret key 本身。 |
| 4 | 项目级多租户 | **部分支持** | 多租户依赖底层 secret store 的多租户（如 Vault namespace、AWS SM 路径前缀）。ESO 本身的多租户就是 K8s namespace + RBAC，**不提供"工具实例分组"概念**。 |
| 5 | 审批门控 | **不支持** | ESO 是声明式 reconcile，无审批工作流；要做"prod 推送审批"需要在 GitOps（Argo CD sync wave）或 CI 流水线层面外接审批。 |
| 6 | UI 资源选择器 | **不支持** | ESO 没有面向最终用户的 UI；它是后端工程师 / 平台 SRE 的工具。"列 branch/tag/project"完全不在它的范围里。 |
| 7 | 凭据轮换 / 短期化 / 吊销 | **部分支持** | `refreshInterval` 周期性拉取 → 后端轮换后 ESO 会同步到 K8s Secret，但**已挂载的 Pod 不会自动 reload**（kubelet 对 env 注入的 Secret 完全不重启；mount 的 Secret 会更新文件但应用未必感知）。短期化能力 = 后端能力（Vault dynamic secret 时）。吊销 = 删 ExternalSecret，K8s Secret 被 GC，但泄露副本不可追。 |
| 8 | 审计 | **部分支持** | "谁创建/修改 ExternalSecret" 走 K8s audit log；"谁实际读了 secret 值"完全无法追（K8s Secret 被任何有 RBAC `get secret` 的主体读到都不留痕）。审计粒度远不如 Vault 自身 audit device，更不如 Connectors 的 proxy 层访问日志。 |
| 9 | air-gap 可安装可升级 | **原生支持** | 单一 Helm chart + 单一 controller 镜像，CRD 集合明确，离线安装容易。后端如果选 Vault/internal 也能完全离线。是所有 4 个工具里**air-gap 最干净**的。 |
| 10 | 热轮换不断流 | **部分支持** | Secret 文件更新是热的，但应用层是否 reload 取决于应用本身；env 注入的根本不更新，必须重建 Pod → 不能算"不断流"。Connectors 通过 proxy + 中央 token 实现真正的对消费者透明。 |
| 11 | 新工具 onboarding 成本 | **低** | 加一个新 provider = 写一个 ESO Provider 插件（已有 80+），或新工具直接复用通用 K/V provider。但 onboarding 的是"secret 同步"，不是"工具集成"——CI Task / 镜像拉取链路要不要改造仍然是消费者自己的事。 |

### 与 Connectors 重叠区域 + 互补区域（150 字）

**重叠**：都解决"把外部凭据交付到 K8s 工作负载"的问题，且都提供 namespace 维度的多租户隔离与基础治理。**互补**：ESO 把凭据**实体下发**到 K8s Secret，Connectors 通过 proxy **不下发**凭据；ESO 没有 PodWebhook 注入 imagePullSecret 的能力，没有面向终端用户的资源选择器 UI，没有审批门控，审计只到 K8s API 层；Connectors 没有 ESO 那种 80+ provider 的广度，且 Connectors 是 **proxy 化集成**而非 **secret 同步**。在 Alauda 场景里 ESO 更像是 Vault 的"K8s 适配层"而非 Connectors 的替代品；如果走 Vault 路线，ESO 通常会跟着进来兜底"必须给 client 一个 K8s Secret"的场景（如 sealed legacy 应用）。

---

## 工具 2：cert-manager + SPIFFE/SPIRE（workload identity / 短期凭据）

### 定位

**SPIFFE** 是"workload identity"规范，**SPIRE** 是它的参考实现。模型：每个工作负载通过**attestor**（K8s SA + Pod metadata、节点 TPM、AWS IID 等多重证明）拿到一个 **SVID**（X.509 证书或 JWT），SVID 里写明工作负载身份（`spiffe://trust-domain/ns/<ns>/sa/<sa>`），TTL 默认 1 小时，自动轮换。**cert-manager** 是 K8s 上的 X.509 证书签发与轮换 controller，可以作为 SPIRE 的下游消费者，或者独立作为 mTLS 证书来源。

二者组合后能给工作负载提供"**短生命周期、自动轮换、可被服务端验证**"的身份凭据。

### 11 问题域评分

| # | 问题域 | 评分 | 说明 |
|---|--------|------|------|
| 1 | CI secretless | **部分支持（理论上）** | 如果 CI Task Pod 能拿到 SPIFFE SVID，且**目标外部工具（Harbor / GitLab / Nexus）支持 SPIFFE 身份验证或 OIDC JWT 联邦**，就能彻底无 static credential。**现实 gap**：绝大多数企业内部工具（GitLab CE、Harbor、Nexus、JFrog、SonarQube、内网 K8s API、各种 SaaS）**不接受 SPIFFE SVID**，需要在它们前面架一层 OIDC/SAML 转换网关。Alauda 客户的工具生态以 legacy 自部署为主，这条路在多数场景走不通。 |
| 2 | K8s 镜像拉取 | **不支持** | OCI distribution 协议有 Bearer token / Basic auth，**没有 SPIFFE 通道**。kubelet 镜像拉取链路里也没有任何位置消费 SVID。要走通必须改 registry + kubelet，工程量与协议变更等价。 |
| 3 | 平台治理 + 委派 | **部分支持** | SPIRE Server 是治理面（trust domain / registration entries），SPIRE Agent + workload selector 是委派面。但治理对象是"workload 身份"，不是"对外部工具的访问凭据"，**层不对**。 |
| 4 | 项目级多租户 | **部分支持** | 通过 trust domain 拆分或 SPIFFE ID path 命名空间约束。粒度细，但运维复杂度也高。 |
| 5 | 审批门控 | **不支持** | 不在产品边界。 |
| 6 | UI 资源选择器 | **不支持** | 不在产品边界。 |
| 7 | 凭据轮换 / 短期化 / 吊销 | **原生支持（这是其最强项）** | SVID 默认 1h TTL，自动轮换；吊销通过删除 registration entry + 等待 TTL 到期（或主动 reissue trust bundle）。短期化是**默认行为**而非可选项。这一格的能力**强于 Vault dynamic secret**（后者要应用主动 lease renew）。 |
| 8 | 审计 | **部分支持** | SPIRE Server 记录 SVID 签发事件，外部工具如果消费 SVID 也能记录身份。但端到端"谁用这个身份对外做了什么"要把 SVID 审计与目标工具审计串起来。 |
| 9 | air-gap 可安装可升级 | **原生支持** | SPIRE Server / Agent 是 Go 二进制，cert-manager 是单一 controller，都能离线部署。生态简单。 |
| 10 | 热轮换不断流 | **原生支持** | SVID 在 TTL 到期前由 Agent 主动续期推送，SPIFFE Workload API 是 streaming，应用监听新 SVID 即可热更新。设计目标就是"不断流"。 |
| 11 | 新工具 onboarding 成本 | **极高（致命）** | 接入一个新工具 = 该工具必须**改造为接受 SPIFFE/OIDC 身份**。对 Alauda 这种"客户带各种 legacy 工具进来"的场景几乎全部需要前置转换网关。这一格直接否定了 SPIFFE 作为 Connectors 替代品的可行性。 |

### 与 Connectors 重叠区域 + 互补区域（150 字）

**重叠**：都试图解决"工作负载在不持有静态凭据的前提下访问外部服务"——SPIFFE 通过短期身份证书替代 static credential，Connectors 通过 proxy 不下发凭据。**互补**：SPIFFE 的短期化、自动轮换、热推送能力远强于 Connectors 当前架构；但 SPIFFE 要求**对端工具支持 SVID/OIDC**，Connectors 不要求任何对端改造。两者本质上是"改造对端 vs. 屏蔽对端"两条路线。在云原生新工具（Istio、Consul、Vault 自身）里 SPIFFE 优雅；在企业 legacy 工具（GitLab CE、Harbor、Nexus、内网 Jenkins）里 SPIFFE 不可行。Connectors 的产品定位恰好填了 SPIFFE 走不通的那一半。

---

## 工具 3：Crossplane Provider 模型

### 定位

Crossplane 是"**通用 Kubernetes 控制平面**"——把云资源 / SaaS API / 任意外部资源建模成 K8s CRD，用 controller 协调。核心抽象：**Provider**（一个 IaC-style 后端的封装，如 `provider-aws`）+ **ProviderConfig**（连接信息 + credentials，可多实例）+ **CompositeResourceDefinition (XRD)** + **Composition**（把多个 managed resource 组装成业务级抽象）。多租户主要靠 **ProviderConfigRef**：不同 Claim 引用不同 ProviderConfig 即可路由到不同后端账号。

### 11 问题域评分

| # | 问题域 | 评分 | 说明 |
|---|--------|------|------|
| 1 | CI secretless | **不支持** | Crossplane 本身就是要**消费** credential 去调外部 API，credential 存在 K8s Secret 里给 ProviderConfig 用。不解决 client 侧 secretless。 |
| 2 | K8s 镜像拉取 | **不支持** | 不在产品边界。 |
| 3 | 平台治理 + 委派 | **原生支持（这是其最强项）** | Composition + Claim 模型是为"平台团队定义抽象、租户团队按需消费"设计的。平台 SRE 定义 `XPostgreSQL`，租户写一行 `PostgreSQL` Claim 就拿到一个数据库 + 备份 + 监控。治理 = Composition + RBAC，委派 = Claim。**这是 Crossplane 真正强的地方**。 |
| 4 | 项目级多租户 | **原生支持** | ProviderConfig 多实例 + ProviderConfigRef 路由 + namespace 隔离 + Composition `writeConnectionSecretToRef`，多租户模型清晰成熟。 |
| 5 | 审批门控 | **部分支持** | Crossplane 没内置审批，但 Claim 是 GitOps 友好的，可以接 Argo CD sync wave / OPA Gatekeeper / Kyverno 实现策略门控。原生审批仍要外挂。 |
| 6 | UI 资源选择器 | **不支持** | 不在产品边界。 |
| 7 | 凭据轮换 / 短期化 / 吊销 | **不支持** | Crossplane 用的是静态长生命周期 cloud credential（ProviderConfig 里挂的 K8s Secret），由运维手工或外部工具轮换。Crossplane 自身不做凭据生命周期。 |
| 8 | 审计 | **部分支持** | K8s audit log 记录 Claim / Composition 变更；"Crossplane 实际向外部 API 发的请求"由各 provider 自行决定是否记录。粒度不均。 |
| 9 | air-gap 可安装可升级 | **部分支持** | Crossplane core 离线没问题，但 **Provider 包是 OCI artifact**，每个 provider 自己一个镜像，需要离线仓库镜像。比 ESO / SPIRE 复杂，但比 Vault 简单。 |
| 10 | 热轮换不断流 | **不支持** | 凭据轮换需要更新 ProviderConfig 引用的 Secret，新请求才用新 cred；正在进行的请求不在 Crossplane 关心的范畴。 |
| 11 | 新工具 onboarding 成本 | **高** | 每个新工具 = 写一个 Crossplane Provider（CRD + controller + sdk 适配），这是**完整的 operator 开发**。社区已有 100+ provider 但企业 legacy 工具基本要自己写。**比 Connectors 写一个 ConnectorClass + ResourceInterface 重得多**。 |

### 与 Connectors 重叠区域 + 互补区域（150 字）

**重叠**：都用"平台定义抽象 + 租户按需消费"的多租户模型，都把外部系统建模成 K8s CRD，都有"Provider/Class 多实例 + 引用路由"的委派结构。**互补**：Crossplane 强在**资源生命周期管理**（创建/更新/删除云资源），Connectors 强在**凭据/访问路径治理**（不创建外部资源，只管访问与凭据）。Crossplane 完全不解决 secretless、不做凭据轮换、不做 imagePullSecret 注入、没有 UI 选择器、新工具 onboarding 是 operator 开发量级。Crossplane 适合用来管理"Alauda 平台需要在公有云上拉起的资源"，但**不替代** Connectors 对"客户带进来的 legacy 工具"的集成职责。两者可在同一平台并存，不冲突。

---

## 对照总览（300 字）

按"对 Connectors 11 问题域的覆盖度"粗略评分（原生 / 部分 / 不覆盖）：

| 问题域 | Vault | ESO | SPIFFE+cert-mgr | Crossplane |
|--------|-------|-----|-----------------|------------|
| 1 CI secretless | 部分 | 不覆盖 | 部分（需对端改造） | 不覆盖 |
| 2 K8s 镜像拉取 | 不覆盖 | 部分（仅同步） | 不覆盖 | 不覆盖 |
| 3 治理+委派 | 部分 | 部分 | 部分 | **原生** |
| 4 项目级多租户 | 部分（namespace） | 部分 | 部分 | **原生** |
| 5 审批门控 | 部分（Sentinel 企业版） | 不覆盖 | 不覆盖 | 部分 |
| 6 UI 资源选择器 | 不覆盖 | 不覆盖 | 不覆盖 | 不覆盖 |
| 7 凭据轮换/短期化/吊销 | **原生** | 部分 | **原生（最强）** | 不覆盖 |
| 8 审计 | **原生（最强）** | 部分 | 部分 | 部分 |
| 9 air-gap | 部分（企业版+复杂） | **原生** | **原生** | 部分 |
| 10 热轮换不断流 | 部分 | 部分 | **原生** | 不覆盖 |
| 11 新工具 onboarding | 部分 | 低成本（仅同步） | 极高（对端改造） | 高（写 Provider） |

**必须组合才能逼近 Connectors 的覆盖面**：单一工具没有任何一个能覆盖 Connectors 一半的问题域。最贴近的组合是 **Vault（凭据存储 + 轮换 + 审计） + ESO（同步到 K8s） + Crossplane（多租户委派抽象） + 自研 PodWebhook（imagePullSecret 注入） + 自研 UI 后端（资源选择器） + 自研审批工作流**。

**组合后的复杂度成本**：6 个组件、3 个独立 controller、2 套 RBAC 模型、2 套多租户语义需要对齐，air-gap 升级要协调 6 条独立的版本矩阵，新工具 onboarding 时 ESO provider / Crossplane provider / UI 后端三处都要改。问题域 1（CI secretless）和问题域 2（镜像拉取）即便组合完仍**只有部分覆盖**——secretless 的关键点是"client 看不到原始凭据"，组合方案最终还是把凭据落到了 K8s Secret，没有 proxy 层就拿不到这个属性。结论：组合方案的工程复杂度 ≈ 重写一个 Connectors，且仍然达不到 Connectors 的覆盖完整度。
