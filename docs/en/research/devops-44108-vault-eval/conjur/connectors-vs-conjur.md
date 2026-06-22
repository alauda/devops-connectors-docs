# Connectors vs CyberArk Conjur — 关系、边界、Roadmap 启发

> **摘要**：Connectors 与 Conjur 不是替代关系，是不同问题域的不同范式。Conjur 是**机器身份 + policy-as-code 的 secret store**（凭据交付进工作负载，即便短寿命也是明文）；Connectors 是 CI/CD 场景下的**业务侧 secretless**（凭据进不了 Pod，靠 in-cluster data-plane proxy）。Conjur 在赛道里有**两副面孔**：它本身是第 ③ 环的**存储后端**（Connectors 可引用的 SecretBackend 候选），而它的**配套 Secretless Broker 才是机制孪生**（出栈注入代理，已在 `../secretless-broker/` 单独深挖）。Conjur 在客户侧常是**银行/政府已有的 CyberArk 投资**——因此核心叙事是"共存（coexistence）"而非替代。
>
> Conjur 背景见 `conjur-capabilities-guide.md`。Conjur vs Vault 正面对照见 `conjur-vs-vault.md`。Connectors 11 问题域机制见 `../what-is-connectors.md` 与 vault-eval 的 `inputs/01-connectors-domain-map.md`。
>
> **edition 提醒**：Conjur 的对比必须按 edition 谈——policy/RBAC/authenticators/静态 secret/rotation 是 **OSS**；dynamic/ephemeral secret、HA、审计、PAM Vault 同步、Web UI 是 **Enterprise/SaaS**。

---

## 1. Connectors 的问题域

| 问题域 | Connectors 的解法 | 体验 |
|---|---|---|
| **CI Secretless** | Proxy 持真凭据 + CSI Driver 用短时 SA token（默认 30m）挂**渲染好的工具配置文件模板**（`.gitconfig`/`maven settings.xml`/`docker config`）；出栈方向注入真 Basic/Bearer/OCI token | 业务进程当普通配置读，零 SDK |
| **K8S 镜像无凭据拉取** | OCI/Harbor reverse proxy + `PodWebhook` 改写 Pod image 到代理地址；kubelet 走 reverse proxy 拉镜像 | Pod 加 annotation 即可，无 imagePullSecret |
| **工具透传 API** | `ConnectorClass.spec.api.openapi` 暴露工具 API 子集，Connectors API server 代用户 SA 调 Proxy | UI/SDK 直接调用 |
| **Pipeline UI 选资源** | `ResourceInterface` + Tekton frontend descriptor 调 Connectors API | Pipeline 编辑页下拉选 Git 分支 / Harbor tag |
| **审批门控** | `AccessPolicy` + `AccessRequest` + Tekton `ApprovalTask` 联动；拒绝则 CSI 挂 `.error.json` | Pipeline 内审批，Pod 自然失败 |
| **三级 scope 治理 + 委派** | cluster / project(namespace-group) / namespace 三层；委派落 ACP IAM RoleBinding | 与 K8s RBAC 同源 |
| **项目级多租户** | 复用 ACP namespace-group / project 模型 | 项目天然隔离 |
| **凭据轮换 / 短期化 / 吊销** | 客户端只拿短时 SA token；吊销 = **撤 RBAC + per-request SubjectAccessReview**，非等 lease 过期 | 撤权即时生效，无需等 TTL |
| **审计** | K8s audit + AccessRequest + Proxy access log（可 data-plane deny/rate-limit） | 记"对工具的使用"，可在数据面拦截 |
| **air-gap 安装/升级** | OLM bundle + 一个 CR，复用 ACP operator 体系 | OperatorHub 装 + 编辑一个 CR |
| **热轮换不断流** | 反向代理 + SA token TTL，请求级注入，客户端零感知 | 客户端零感知 |
| **新工具 onboarding** | 一份 ConnectorClass YAML（含 proxy + UI 资源 + API） | 完整代理 + UI 体验 |

**Connectors 边界（不解决什么）**：不是通用 KV / 配置中心；不是 KMS / PKI / SSH CA；不是凭据轮换器或动态凭据引擎（依赖后端或 Automation Task）；不做 secret 泄漏扫描；不是机器身份/policy-as-code 平台。

---

## 2. Conjur vs Connectors 能力对比（Connectors 11 问题域）

评级：**substitute（替代/同机制覆盖）** / **partial（部分，受限或要拼装/受 edition 限制）** / **none（不覆盖/边界外）**。
> 对 Conjur 每格都标 edition——这是评级的前提（dynamic 等是 Enterprise/SaaS，rotation 是 OSS）。

| # | 问题域 | Connectors 解法 | Conjur 解法 | 判定 | 关键差异 |
|---|---|---|---|---|---|
| 1 | CI Secretless | data-plane proxy，client 看不到真凭据；CSI 挂渲染配置 | 把 secret 交付进 workload（Summon env / Secrets Provider 文件 / K8s Secret），**即便短寿命也是明文** | **仅 Connectors 覆盖** | Connectors：真凭据不进 Pod；Conjur：workload 持有真凭据，`cat`/`env`/core dump 可见。**注意**：Conjur 的 Secretless Broker 才在此机制上与 Connectors 同类（见 §2.2） |
| 2 | K8S 镜像无凭据拉取 | PodWebhook 改 image + SA token 拉 | **无** —— Conjur 不代理 OCI distribution、不改 Pod image、kubelet 不经它 | **none** | 镜像拉取不在 Conjur 范畴 |
| 3 | 平台治理 + 委派 | 三级 scope + 复用 ACP IAM | **policy-as-code RBAC**（OSS）：role/resource/permit/grant + branch 命名空间，**自成一套强权限模型** | **双方覆盖（模型不同）** | Connectors：复用 ACP RBAC 零额外学习；Conjur：另一套 RBAC 图 + policy YAML，需独立培训 + 与 ACP 双向映射。Conjur 这套是它最强的能力之一 |
| 4 | 项目级多租户 | namespace-group 自然隔离 | policy **branch** 命名空间隔离（OSS），但**与 ACP 项目解耦** | **双方覆盖（解耦）** | Connectors：天然复用 ACP 项目；Conjur：在 Conjur 内重建 branch 树 + 与 ACP project 对齐 |
| 5 | 审批门控 | `AccessPolicy`+`AccessRequest`+`ApprovalTask`，门控**运行时每次经 proxy 调用** | **无原生审批工作流**（RBAC 是静态授权，无"请求→审批→放行"状态机；无 Vault Control Groups 等价物） | **仅 Connectors 覆盖** | Conjur 靠 policy 改授权，但没有运行时审批门控；要审批需外部流程改 policy |
| 6 | 工具透传 API | OpenAPI + Connectors API server 代调工具 | **无** —— 只存/发 secret，不暴露工具 API | **none** | 不在 Conjur 范围 |
| 7 | Pipeline UI 选资源 | ResourceInterface + descriptor + Connectors API | **无** | **none** | 无此产品形态 |
| 8 | 凭据轮换 / 短期化 / 吊销 | 短时 SA token + **撤 RBAC/per-request SAR 即时吊销** | **rotation（OSS，postgresql/aws）** + **dynamic/ephemeral（Enterprise/SaaS）**；吊销靠 TTL/改 policy | **双方部分覆盖（Conjur 在轮换/动态结构优势，但分裂在两个 edition）** | Connectors：客户端只看 SA token，撤 RBAC 秒级断流；Conjur：现造/轮换短寿命凭据，但凭据已落进 workload，且 dynamic 要 Enterprise |
| 9 | 审计 | K8s audit + AccessRequest + Proxy access log（可 data-plane deny/rate-limit） | **审计数据库/流 = Enterprise**；OSS 审计弱。记"对 secret 的操作" | **双方部分覆盖（互补，Conjur 审计需 Enterprise）** | Connectors：data plane 上能拦截，记"对工具的使用"；Conjur：记"对 secret 的操作"，全量审计要 Enterprise |
| 10 | air-gap 安装/升级 | OLM bundle + 一个 CR，复用 ACP operator 体系 | OSS Docker/`conjur-oss` Helm 可离线（单节点）；Enterprise 集群 air-gap 但商业 license | **双方覆盖（成本不同）** | Connectors：OperatorHub 装 + 编辑一个 CR；Conjur：自建 secret 平台（OSS 单节点 / Enterprise 集群 + license） |
| 11 | 热轮换不断流 | 反向代理 + SA token TTL，请求级注入，客户端零感知 | Secrets Provider sidecar 刷新文件/K8s Secret；env 注入需重启 | **双方部分覆盖（Connectors 优）** | Connectors：客户端零感知；Conjur：sidecar 刷新或依赖 app reload/重启 |
| 12 | 新工具 onboarding | 一份 ConnectorClass YAML（含 proxy + UI + API） | 写一段 policy 存 secret + 选交付方式，但 onboard 的是"secret/机器身份"非"工具集成" | **语义不同** | Connectors：完整代理 + UI 体验；Conjur：仅交付凭据 + 机器身份，工具访问路径自理 |

### 2.1 域覆盖总览（粗评）

| 问题域 | Connectors | Conjur（标 edition） |
|--------|-----------|------|
| 1 CI secretless | 原生 | **none**（注入模型；机制孪生在 Secretless Broker） |
| 2 K8s 镜像拉取 | 原生 | none |
| 3 治理+委派 | 原生(ACP IAM) | partial（policy-as-code RBAC，OSS，自成模型） |
| 4 项目多租户 | 原生(ACP) | partial（branch，OSS，解耦 ACP） |
| 5 审批门控 | 原生(按调用) | **none**（无运行时审批工作流） |
| 6 工具透传 API | 原生 | none |
| 7 Pipeline UI 选资源 | 原生 | none |
| 8 轮换/短期化/吊销 | partial(短期化 SA token + 撤 RBAC 即时吊销) | **partial（rotation=OSS；dynamic=Enterprise/SaaS）** |
| 9 审计 | partial(data-plane) | partial（全量审计=Enterprise） |
| 10 air-gap 装升 | 原生(OLM,复用 ACP) | partial（OSS 单节点 / Enterprise license） |
| 11 热轮换不断流 | 原生(请求级) | partial(sidecar 刷新/重启) |

### 2.2 关键：Conjur=存储，Secretless=机制——两副面孔，都"邻接非替代"

> Conjur 在 Connectors 同心环里**横跨两环**，必须分开看：

- **Conjur 本体落在第 ③ 环（存储后端）**：它是 secret store（注入模型），与 Connectors 是"后端 vs 使用面"的互补关系——可作 Connectors 的 `SecretBackend` 候选（见 §3）。本体**不是**机制孪生：它把凭据交付进 workload，不在数据面代理。
- **Conjur 的配套 Secretless Broker 落在第 ① 环（机制孪生）**：出栈方向注入真凭据、client 永不持有，与 Connectors Proxy 通道同机制。**已在 `../secretless-broker/connectors-vs-secretless-broker.md` 单独深挖**——本文不重复，只强调：Connectors 在 Proxy 通道上已自建等价机制并做得更宽（类型化连接 + CSI 配置 + UI + 镜像 + per-request RBAC 吊销）。Secretless 常以 Conjur 为后端 vault，三者关系是 **Conjur(存储) ← Secretless(机制) ← 应用**。

**结论**：谈"Connectors vs Conjur"时，本体是**存储后端**（互补），机制孪生是**它的 Secretless 配件**（同机制位、低集成价值）。两者都**邻接非替代**。

### 2.3 不在 Connectors 问题域内的 Conjur 能力

> Connectors 不主动覆盖这些方向，不构成"Connectors 不足"——边界外，仅供参考。

| Conjur 能力 | 含义 | edition | 对位 |
|---|---|---|---|
| **policy-as-code RBAC** | 声明式 role/resource/permit/grant + branch | OSS | Vault HCL policy / OPA（但 Conjur 是 secret-native） |
| **机器身份 + 多 authenticator** | host + authn-k8s/jwt/iam/azure/gcp/oidc/ldap 全内置 | OSS | Vault auth methods；Conjur 机器身份是核心卖点 |
| **通用 secret 存储 + 版本** | 集中、加密、RBAC、版本化 secret | OSS | Vault KV / 配置中心 |
| **rotation rotators** | 同账号周期换密码（postgresql/aws） | OSS | Vault static roles |
| **dynamic / ephemeral secret** | 现造短寿命云凭据 | Enterprise/SaaS | Vault 动态引擎 |
| **PAM Vault 同步** | 复用既有 CyberArk Vault 凭据 | Enterprise | （CyberArk 生态特有） |

### 哲学差异一句话

> **Connectors = "凭据永远进不了客户端"**（data-plane proxy，真凭据死守在 connectors-system，吊销=撤 RBAC）。
> **Conjur = "机器身份 + policy-as-code + 把凭据交付进工作负载"**（凭据仍进 workload，靠短寿命/rotation/dynamic 缩小窗口；机器身份与声明式 RBAC 是其护城河）。

---

## 3. 集成方向与 Roadmap 启发

**思路方向，不写实施草案。**

**自然边界**

- Conjur 不替代 Connectors：CI Secretless / K8S 镜像无凭据拉取 / 工具透传 API / Pipeline UI 资源选择 / 运行时按调用审批，Conjur 结构上不覆盖。
- Connectors 不替代 Conjur：通用 secret 存储 / policy-as-code RBAC / 机器身份多 authenticator / rotation / dynamic secret / PAM Vault 同步，不在 Connectors 问题域。

**核心思路**

> **Conjur 负责凭据的"存储 + 机器身份 + 短期化/轮换/动态"，Connectors 负责凭据的"使用 + 客户端永远拿不到"。**
>
> 当前 Connectors 用 Automation Task 刷新工具凭据；结合 Conjur 后这一职责可迁移给 Conjur（rotation + dynamic）——与 vault-eval / infisical-eval 结论一致：Conjur 是 `SecretBackend` 的又一个候选实现，不是新范式。
>
> **客户共存（coexistence）才是 Conjur 的主叙事**：银行/政府客户大量已有 CyberArk（Conjur/PAM Vault）投资。对这类客户，正确姿态不是"换掉 Conjur"，而是"**Conjur 当后端，Connectors 当 CI/CD 使用面**"——真凭据存在客户既有 Conjur 里，Connectors 引用它并在数据面注入，客户端永不持有。这是相对 Vault/Infisical 更突出的差异化场景。

### 集成方向

> 三个方向逻辑递进：方向 1 是架构基础（不依赖 Conjur），方向 2 是在它上面的具体集成，方向 3 是另一条无侵入路径。与 vault-eval / infisical-eval 的三方向同构——**Conjur 是 `SecretBackend` 的又一候选实现**。

**方向 1：在 Connectors 内抽象 `SecretBackend` interface（架构演进，独立于具体 backend）**

- 解耦"Connector 引用的 secret 从哪来"：默认 K8s Secret（air-gap 开箱即用）；可选 Vault / OpenBao / Infisical / **Conjur** / AWS SM / Azure KV。
- **价值独立**：复用客户已有 secret store 投资——对 CyberArk 客户（银行/政府）尤其有价值。
- **定位**：产品架构演进，**不是为 Conjur 而做**，Conjur 只是众多 backend 之一。

**方向 2：基于方向 1，以 Conjur 为后端实现凭据来源（含客户共存场景）**

- 在 `SecretBackend` 抽象上落地 Conjur backend：Connectors 引用 Conjur variable（通过 Conjur API / ESO provider / Secrets Provider）作为工具凭据，Proxy 出栈注入。
- **客户共存价值最高**：客户既有 Conjur 是凭据权威源（甚至由 PAM Vault 同步而来），Connectors 只做"安全地用出去"。真凭据不离开客户既有合规边界 + 客户端永远拿不到——两套合规叠加。
- ⚠️ **edition 现实**：若要用 Conjur 的 **dynamic secret**，那是 **Enterprise/SaaS**；但客户既然已有 CyberArk 投资，往往已有 Enterprise license——这与"让 air-gap 客户新买 license"不同，是**复用既有投资**，劣势点弱于 Infisical 路线。若只用 Conjur OSS，则 dynamic 不可用，只能 rotation + 静态。

**方向 3：Conjur Secrets Provider 直接挂载 + Connectors 配置模板**

- 不走 Connectors Proxy，把 Conjur Secrets Provider 交付的 secret 通过 Connectors 的配置文件模板机制直接挂进 Pod。
- Task 层 0 侵入；折中是业务进程持有了凭据（即便短期），哲学上不再 secretless。
- ⚠️ 注意：Conjur 的 **Secretless Broker** 也提供一条出栈注入路径——但那与 Connectors Proxy 同机制位，**不作为集成对象**（见 `../secretless-broker/`），别把它当 backend。

### Roadmap 启发

**短期可考虑**

- **方向 1 优先**：评估 `SecretBackend` 抽象工程量；即便不上 Conjur 也有独立价值（Vault/OpenBao/云 SM/Conjur 客户场景共用一个抽象）。
- **方向 2 针对 CyberArk 客户**：把"Conjur 当后端、Connectors 当使用面"做成一个**明确的客户共存方案**——这是 Connectors 在金融/政府市场（CyberArk 大本营）的差异化切入点。优先支持 Conjur OSS 的静态 secret 取值（API/ESO），dynamic 留给已有 Enterprise 的客户。

**中长期考虑**

- **多租户/治理对齐**：Conjur 有自己的 policy branch + RBAC 图，与 ACP IAM 解耦——若深度集成，要解决"Conjur branch ↔ ACP project"映射与权限同步，否则两套治理面割裂。这是 ACP 相对纯 Conjur 路线的差异化点（Connectors 复用 ACP IAM，零第二套权限模型）。
- **policy-as-code 的借鉴**：Conjur 把整个授权面做成版本化 YAML（GitOps 友好），是其最受认可的设计。Connectors 的 AccessPolicy/治理若要往声明式 + GitOps 走，Conjur policy 模型是值得参考的样本（但不引入第二套策略语言）。
- **机器身份对位**：Conjur 的 authn-jwt（投影 SA token + claim 匹配）与 Connectors 的"Pod SA 短 token"在身份来源上同源（都是 K8s SA）。这印证 Connectors 的身份模型方向正确，且暗示二者在 K8s 身份层可平滑对接。

**🟡 待审视的开放问题**

- **审批门控对位**：Conjur **没有**运行时审批工作流（不像 Vault Control Groups）——这反而凸显 Connectors 的 ApprovalTask 是差异化点。但客户可能误以为"改 policy = 审批"；需 PM 话术区分"改授权（静态）"与"运行时按调用审批"。
- **edition 诚实**：Conjur 的 dynamic secret 是 Enterprise/SaaS，rotation 才是 OSS——对外谈 Conjur 能力时不要把 dynamic 当成 OSS 免费能力（这是 Conjur 最易被误述的点）。
- **收购后 roadmap 不确定**：CyberArk 已被 Palo Alto Networks 收购（2026-02 完成）。Conjur OSS 当前活跃，但收购对 OSS 长期投入的影响**未确认**——作为后端依赖前需评估持续性。

**明确不做**

- 不做 Conjur OSS 替代品（secret 存储 / policy-as-code / 机器身份不进入 Connectors 问题域）。
- 不重写 Conjur 成熟能力（rotation / dynamic / authenticators）。
- 不集成 Conjur 的 Secretless Broker 作为后端（同机制位，无收益；见 `../secretless-broker/`）。
- 不把 Conjur Enterprise 作为强依赖（OSS 客户无 dynamic；按 edition 摆明能力边界）。

### 借鉴 / 启发候选（🟡 候选）

> 仅记录，不下结论；等 `/connectors-arch-review`（原则）或 `/connectors-learn`（教训/话术）触发再决定是否沉淀。

- **"客户既有投资 → 共存而非替代"是 CyberArk 类竞品的标准姿态**：与 Vault/Infisical（多为新选型）不同，Conjur 多是存量。对外材料应把 Conjur 单独列为"共存后端"叙事，而非"竞品对比胜负"。
- **policy-as-code（版本化授权树）是值得做成跨竞品一张表的设计点**：Vault HCL policy / Conjur policy YAML（role/resource/permit/grant + branch）/ Connectors AccessPolicy + K8s RBAC——授权表达范式各不同，Conjur 的"授权面即代码 + GitOps"最彻底。
- **审批门控位置矩阵补一列**：Vault Control Groups（取凭据时）/ Infisical change·access request（写 secret·取权限时）/ **Conjur（无运行时审批，只能改 policy）** / Secretless（无门控）/ Connectors ApprovalTask（运行时按 proxy 调用）。Conjur 的"无运行时审批"正好凸显 Connectors 把治理织进数据面的价值。
- **edition 分裂（rotation=OSS / dynamic=Enterprise）是 Conjur 独有的解读陷阱**：竞品分析里凡谈 Conjur 能力必须带 edition，否则会高估 OSS。

---

**相关文档**

- `conjur-capabilities-guide.md` — Conjur 工具自身能力（能力地图 + 分章 + 每章 demo + OSS/Enterprise 边界）
- `conjur-vs-vault.md` — Conjur vs Vault 正面对照（policy/authn/dynamic/rotation/HA/审计/air-gap/license）
- `../secretless-broker/connectors-vs-secretless-broker.md` — 机制孪生（Conjur 的配套出栈代理），方向区分：Secretless=机制孪生（不集成），Conjur 本体=后端候选（可集成）
- `../what-is-connectors.md` — Connectors 同心环竞品分级（Conjur 落第 ③ 环存储、Secretless 落第 ① 环机制）
- `../../connectors-vs-vault.md` / `../infisical/connectors-vs-infisical.md` — 方向 1（`SecretBackend` 抽象）同构
