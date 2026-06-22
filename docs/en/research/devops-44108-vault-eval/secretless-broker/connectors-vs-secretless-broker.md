# Connectors vs CyberArk Secretless Broker — 关系、边界、Roadmap 启发

> **结论摘要**：Secretless Broker 是 Connectors 在赛道里**最近的"机制孪生"**——两者都用代理在**出栈方向注入真凭据、让客户端永不持有凭据**。但 Secretless 只做到了 Connectors **三条数据面通道里的一条（Proxy）的一部分**：它是一个通用的、协议级的"认证替身 sidecar"，**没有**类型化工具连接模型（ConnectorClass）、没有 CSI 配置渲染、没有资源浏览 API / Pipeline UI、没有 per-request SubjectAccessReview 授权、没有镜像协议代理与 image 改写、没有 OLM 化的平台交付与审批门控。Connectors 是"嵌入 ACP/Tekton 的工具接入平台"，Secretless 是"给单个工作负载加一个旁路认证代理的库/sidecar"。
>
> Secretless 背景见 `secretless-broker-capabilities-guide.md`。Connectors 11 问题域机制见同目录 vault-eval 的 `inputs/01-connectors-domain-map.md`。
>
> **覆盖范围**：Secretless Broker 全部为 Apache-2.0 OSS（无 Enterprise tier）。
> **不覆盖**：CyberArk Secrets Manager / Conjur 本身（它们是 Secretless 的后端 vault，不是 Secretless）。

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

**Connectors 边界（不解决什么）**：不是通用 secret store / KV；不是 KMS / PKI / SSH CA；不是凭据轮换器或动态凭据引擎（依赖后端或 Automation Task）；不做 secret 泄漏扫描。

---

## 2. Secretless Broker vs Connectors 能力对比（Connectors 11 问题域）

评级：**substitute（替代/同机制覆盖）** / **partial（部分，受限或要拼装）** / **none（不覆盖/边界外）**。

### 2.1 在 Connectors 问题域内的对比

| # | 问题域 | Connectors 解法 | Secretless Broker 解法 | 判定 | 关键差异 |
|---|---|---|---|---|---|
| 1 | CI Secretless | data-plane proxy，client 看不到真凭据；CSI 挂渲染配置 | sidecar 协议代理，**client 同样看不到真凭据**（连 localhost） | **partial（同机制，覆盖面窄）** | 机制一致（出栈注入）；但 Secretless 只做"连接代理"，**不渲染工具配置文件**；连接器覆盖互有取舍——Secretless 有 SSH / 数据库（pg/mysql/mssql）而无 Git/Maven/OCI 类型化支持，Connectors 反之（详见 2.2 小结） |
| 2 | K8S 镜像无凭据拉取 | PodWebhook 改 image + kubelet 走 reverse proxy 拉 | **无** —— Secretless 不代理 OCI distribution 协议、不改 Pod image、kubelet 不经它 | **none** | Secretless 只在认证相位注入头/握手，镜像拉取不是它的协议范畴 |
| 3 | 平台治理 + 委派 | 三级 scope + 复用 ACP IAM | **无** —— 无授权模型，授权交给后端 vault | **none** | Secretless 不做谁能用哪个 connector 的授权；RBAC 在 vault 侧（如 Conjur policy） |
| 4 | 项目级多租户 | namespace-group 自然隔离 | **无** —— 每个 Pod 各自配 sidecar，无租户概念 | **none** | 多租户隔离靠 K8s namespace + 各自配置，Secretless 本身无租户单元 |
| 5 | 审批门控 | `AccessPolicy`+`AccessRequest`+`ApprovalTask`，门控**运行时每次经 proxy 调用** | **无** —— 认证完成即透传，无门控点 | **none** | Secretless 数据相位是 pass-through，**结构上无法**挂 per-call 审批 |
| 6 | 工具透传 API | OpenAPI + Connectors API server 代调工具 | **无** —— 只代理协议连接，不暴露工具 API | **none** | 不在 Secretless 范围 |
| 7 | Pipeline UI 选资源 | ResourceInterface + descriptor + Connectors API | **无** | **none** | 无此产品形态 |
| 8 | 凭据轮换 / 短期化 / 吊销 | 短时 SA token + **撤 RBAC/per-request SAR 即时吊销** | **承接后端轮换**：下一条新连接重取最新 secret；**不造、不轮换、不吊销** | **partial（承接，非引擎）** | Secretless 透明用上后端轮换后的值；但**吊销要靠后端**，无 per-request 授权，无法"撤 RBAC 秒级断流" |
| 9 | 审计 | K8s audit + AccessRequest + Proxy access log（可 deny/rate-limit） | **partial** —— broker 进程日志，但数据相位透传、**无法记每次业务调用** | **partial（弱）** | Secretless 认证后退出业务路径，审计粒度到"连接建立"，非"每次工具操作" |
| 10 | air-gap 安装/升级 | OLM bundle + 一个 CR，复用 ACP operator 体系 | **partial** —— sidecar 镜像离线可跑；但需逐 Pod 注入 + 配 ConfigMap/CRD，无平台化装升 | **partial** | Secretless 无 operator/OLM 形态；air-gap 取决于后端 vault 可达性 |
| 11 | 热轮换不断流 | 反向代理 + SA token TTL，请求级注入，客户端零感知 | **substitute** —— 新连接重取最新 secret，对 client 透明、不重启 | **substitute（机制一致）** | 二者都对 client 透明；Connectors 是请求级注入，Secretless 是"下一条新连接"取值，生效粒度略粗但等价透明 |
| 12 | 新工具 onboarding | 一份 ConnectorClass YAML（含 proxy + UI 资源 + API） | 加一个 service 到 `secretless.yml` + 选 connector | **partial（仅连接层）** | Secretless onboard 的是"一条协议代理"，无 UI/API/资源浏览；且非内置协议要写 Go 插件编译进 binary |

### 2.2 小结：从对比中提炼的结论

**一句话**：Secretless 与 Connectors 是「机制孪生」——都把「工具连接配置」抽象成一等概念、都让客户端永不持有真凭据、出栈注入的基本机制一致；但 Connectors 是「嵌入 ACP 的工具接入平台」，Secretless 是「贴着单个工作负载的旁路认证代理」，范围悬殊。

**相同点（机制孪生）**

- 都把「工具/服务的连接配置」抽象成一等概念（Connectors 的 `ConnectorClass` / `Connector` ↔ Secretless 的 `service` / `connector`），理念与基本机制类似。
- 真凭据死守在代理进程、客户端只连本地、出栈方向注入认证——这条护城河式机制两者一致。
- 凭据轮换都对 client 透明（"热轮换不断流"判 substitute）。

**Secretless 强于我们的点（值得借鉴）**

- **非 HTTP 协议有现成支持**：`ssh` 与数据库（`pg` / `mysql` / `mssql`）是内置 connector；Connectors 当前覆盖的工具（git/maven/oci/harbor/npm/pypi/sonarqube/k8s）**全是 HTTP/HTTPS 类，没有 SSH / 数据库协议代理**。
- **SecretBackend 抽象成型**：8 种可混用 credential provider（aws/conjur/vault/kubernetes/env/file/literal/keychain）；Connectors 当前只引用 K8s Secret（见 §3 方向 1）。

**Secretless 弱于我们的点（要诚实看待边界）**

- **不支持配置文件投射**：只做「连接代理」，不像 Connectors CSI 那样把渲染好的工具配置文件（`.gitconfig` / maven `settings.xml` / docker config）投射进 Pod 让业务零 SDK 直接读。
- **HTTPS 正向代理 app→broker 明文透传**：HTTP 类放弃了到真 server 的端到端 TLS，安全前提是 app↔broker 锁在同 Pod loopback（见 §1 小结 / §2.4）。
- **默认 sidecar、数据面随工作负载复制**：loopback 明文前提决定它必须贴着 app，每个工作负载各带一份 broker 进程；Connectors 的 Proxy 是**共享服务 + CSI 投射**，一份 Proxy 服务多个消费者。

**结论**：Secretless 印证了 Connectors Proxy 通道的机制成熟可落地，并在「非 HTTP 协议 + SecretBackend 多源」两点上**领先、值得借鉴**；但它只有「通用协议连接代理」这一条通道，缺少类型化建模、配置投射、资源浏览/UI、治理/审批/审计、镜像拉取与 OLM 平台化交付——这些是 Connectors 的增量，也是两者**不构成替代关系**的根因。

### 2.3 不在 Connectors 问题域内的 Secretless 能力

> Secretless 比 Connectors **窄**而非**正交**：它的特性多数落在 Connectors 已覆盖的范围内。**真正值得 Connectors 反向借鉴的有两点**——非 HTTP 协议的现成 connector（SSH / 数据库，见 §2.2）与多源 SecretBackend 抽象（见 §3 方向 1）。下表是其余特性在 Connectors 视角下的对位。

| Secretless 能力 | 含义 | 对位 |
|---|---|---|
| **通用协议 sidecar（任意 app，loopback 注入）** | 不依赖 CI 平台，任何 K8s Pod 都能加 | **不是 Connectors 短板**：Connectors 并非只服务 Tekton——普通 K8s Pod / Job 也能通过 CSI 挂载渲染配置、或在 Pod 内访问 Connectors Proxy（用户文档有多处 Job 使用场景）。真正差异在**形态**：Secretless 是贴 Pod 的 sidecar 进程，Connectors 是共享 Proxy + CSI 投射 |
| **8 种可混用 credential provider** | aws/conjur/vault/kubernetes/env/file/literal/keychain（`keychain` 仅 macOS、仅源码构建可用） | Connectors 当前只引用 K8s Secret —— provider 抽象是借鉴点（见 §3 方向 1） |
| **Connector Plugin 接口（编译进 binary）** | 第三方扩展协议需写 Go 插件、编译进 broker binary | Connectors 扩展是 **`ConnectorClass` 声明 + 可选的 Proxy Workload**：无需改 binary、声明式、对交付更友好——扩展成本与交付摩擦都低于"编译进 binary"的插件模型 |

### 2.4 对比补充说明：secretless sidecar 的信任边界是 Pod 级、不是容器级

> 这是评估"凭据由代理层持有"这类方案时最容易被忽视、却直接决定安全收益的一条边界。结论均经独立核实并带官方出处。

**问题**：sidecar 模式下，broker 用 **Pod 的 projected ServiceAccount token** 向后端认证（Conjur authn-jwt / Vault K8s auth）。该 token 是 **Pod 级**、挂在 `/var/run/secrets/kubernetes.io/serviceaccount/token`，**同 Pod 的 app 容器能读到同一份**——被 RCE 的 app 可以复刻 broker 的认证、取到等价凭据。**信任边界是 Pod，不是容器。**

**官方态度（核实结论）**：官方文档**未把这点列为具名 limitation**；但 [Secretless README](https://github.com/cyberark/secretless-broker) 明确把"应用漏洞（如 remote code execution、环境变量 dump）"列为它要防的风险，[Security 页](https://docs.secretless.io/Latest/en/Content/Overview/scl_security.htm)又把保护范围界定为"通信不离开 host/pod"。两者合起来印证：**token-based 认证下 broker 的信任根确实只到 Pod**，sibling-container replay 是文档既不否认、也未点破的推断。

**能把信任根收窄到容器级的手段（均已核实）**：

| 手段 | 粒度 | 机制 | 出处 |
|---|---|---|---|
| **Conjur authn-k8s 证书注入** | **容器级** | Conjur 经 K8s API 把短寿命 cert 注入**指定名字的容器**（默认 `authenticator`，注解 `authn-k8s/authentication-container-name` 可改），cert 用完即从磁盘删除 → 只有该容器能完成 mTLS | [authn-k8s-client README](https://github.com/cyberark/conjur-authn-k8s-client)、conjur `inject_client_cert.rb` / `extract_container_name.rb` |
| authn-jwt / Vault K8s auth | **Pod 级** | 基于 SA token，`sub = system:serviceaccount:<ns>:<sa>`，无容器维度 | [Conjur JWT 文档](https://docs.cyberark.com/conjur-enterprise/latest/en/content/integrations/k8s-ocp/k8s-jwt-authn.htm)、[Vault K8s auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes) |
| **SPIFFE / SPIRE** | **子 Pod / per-workload** | workload attestation 用 `container-name` / `container-image` 选择器（"只匹配联系 SPIRE 的那个容器"）；CyberArk 有一等 SPIFFE 集成（SWA，Conjur Cloud），但**未接入 Secretless Broker** | [SPIRE k8s attestor](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_workloadattestor_k8s.md)、[CyberArk SWA](https://docs.cyberark.com/secrets-manager-saas/latest/en/content/conjurcloud/ccl-swa-overview.htm) |

> ⚠️ 两条诚实边界（不可假托官方）：
> 1. **"authn-k8s 比 authn-jwt 更隔离" 是本调研的工程推断**，CyberArk 官方**未**把两者框定为"隔离 vs 简单"的安全权衡，反而把 JWT/SPIFFE 作为现代推荐路径。对外材料不要写成官方结论。
> 2. authn-k8s 只收窄"**谁能认证**"；若代理把取到的 token 落到 Pod 内**共享卷**，RCE 的 app 仍可能读到结果——收窄的是**认证面**，不必然是**结果暴露面**。

**对 Connectors 的对照（为什么这对我们有价值）**：

- Connectors 走 **CSI + 短时 SA token + per-request SubjectAccessReview**：CSI 把渲染好的配置挂进**指定容器的 volumeMount**，信任根同样落在 Pod SA；但叠加 per-request SAR 后，**吊销 = 撤 RBAC → 下一个请求即拒**，不依赖"换哪种认证器收窄认证面"。
- **启示**：Connectors 若推 `SecretBackend` 抽象（见 §3 方向 1），**"信任根落在哪一层（Pod SA / 容器 / SPIFFE）"应成为 backend 选型与安全评审的一个显式维度**——这正是 Secretless 这类 sidecar 暴露出来、值得我们在设计阶段前置回答的问题。

---

## 3. 集成方向与 Roadmap 启发

**思路方向，不写实施草案。**

**自然边界**

- Secretless 不替代 Connectors：K8S 镜像拉取 / 工具透传 API / Pipeline UI 资源选择 / 运行时按调用审批 / 三级 scope 治理 / OLM 平台化装升，Secretless **结构上不覆盖**。
- Connectors 不"需要"Secretless：在 Proxy 通道这件事上，Connectors 已**自建了等价机制并做得更宽**（类型化、CSI、UI、治理、镜像）。Secretless 的价值更多在**架构印证与个别借鉴点**，而非作为 backend 集成。

**核心思路**

> **Secretless Broker 是 Connectors Proxy 通道的"机制对照样本"，不是后端候选。** 与 Vault/Infisical（可作 `SecretBackend` 后端）不同，Secretless 与 Connectors 在**同一层**（出栈注入代理）竞争同一个机制位，因此集成价值低、定位印证价值高。

### 集成 / 借鉴方向

**方向 1：`SecretBackend` 抽象——把 Secretless 的 8-provider 模型作为参照（架构演进）**

- 背景：Secretless 用 `from/get` 把"凭据从哪取"与"凭据怎么用"彻底解耦，内置 aws/conjur/vault/kubernetes/env/file/literal/keychain 八种 provider 可混用（`keychain` 仅 macOS、仅源码构建可用）。Connectors 当前 Connector 只引用 K8s Secret。
- 借鉴点：Connectors 引入 `SecretBackend` 抽象时（与 vault-eval / infisical-eval 的方向 1 同构），可参考 Secretless 的 **per-credential provider 选择**粒度（同一连接里 username 走 env、password 走 vault）。CyberArk 的 credential provider 是一套**成型、多源、可混用**的设计，值得作为 `SecretBackend` 抽象的主要参照样本之一。
- **安全维度（接 §2.4）**：provider 抽象不只是"从哪取值"的 UX，还要把**"信任根落在哪一层（Pod SA / 容器 / SPIFFE）"**作为每个 backend 的显式属性——Secretless 的 sidecar 信任边界只到 Pod 这件事，正说明这个维度不能在抽象里缺位。
- **定位**：这是**借鉴 provider 抽象的设计与 UX**，不是"集成 Secretless"。Secretless 本身不作为 backend。

**方向 2：通用协议 sidecar 形态作为"非 Tekton 场景"的轻量参考（🟡 待审视）**

- Secretless 证明了"平台无关、任意 Pod 可加的 secretless sidecar"是可行形态。Connectors 当前强绑 Tekton/ACP 工具语义。
- 待审视：Connectors 是否需要一个"脱离 Tekton、面向普通工作负载"的轻量 Proxy sidecar 部署形态（当前主路径是 CSI + webhook）。**结论待审视**——这与 Connectors "工具接入平台"的定位是否一致需 PM 判断。

**方向 3：不集成（明确不做）**

- 不把 Secretless 作为 backend / 依赖：它与 Connectors Proxy 在同一机制位，引入它等于在 Connectors 里塞第二个出栈代理，无收益。
- 不重造 Secretless 的通用 sidecar：Connectors 的 Proxy 通道已覆盖且更宽（类型化 + 镜像 + 治理）。

### Roadmap 启发

**短期可考虑**
- **provider 抽象借鉴**：在 `SecretBackend` 设计评审里，把 Secretless 的 `from/get` per-credential provider 模型作为一个 UX 参照样本（与 Vault/Infisical 一并）。

**中长期考虑 / 待审视**
- **对外话术：机制孪生但范围悬殊**。客户若问"你们和 Secretless Broker 啥区别"——核心回答：机制（出栈注入、client 不持凭据）一致，但 Secretless 是"给单个工作负载加认证 sidecar"，Connectors 是"嵌入 ACP/Tekton 的工具接入平台"（类型化连接 + CSI 配置 + 资源浏览 UI + 镜像无凭据拉取 + per-request RBAC 吊销 + 审批门控 + OLM 装升）。**不贬低**：Secretless 在它的范围内是干净的 Apache-2.0 方案。

**🟡 待审视的开放问题**
- **信任根落在哪一层（见 §2.4）**：sidecar 用 Pod SA token 认证后端时，信任边界是 Pod 而非容器，RCE 的同 Pod app 可复刻取密。Connectors 的 CSI + per-request SAR 把吊销做到请求级，但**信任根同样是 Pod SA**——`SecretBackend` 设计应把"容器级 / SPIFFE 级身份"列为可选演进方向，并在安全评审里显式回答。
- **吊销语义对位**：Secretless 的"吊销"完全依赖后端 vault（撤 Conjur/Vault 凭据），且因数据相位透传，**已建立的连接不会被立即切断**。Connectors 的 per-request SubjectAccessReview 能做到"撤 RBAC → 下一个请求即拒"。这是 Connectors 的真实差异化点，但需注意 Connectors 自身对"已建立长连接"的即时切断粒度也要核实（per-request 是请求级，非连接级强杀）。
- **审计粒度差异**：Secretless 认证后退出业务路径 → 无法做"每次工具操作"审计；Connectors Proxy 全程在路径上可记每请求。对安全合规客户这是卖点，但要在材料里诚实区分"连接级 vs 请求级"。

**明确不做**
- 不集成 Secretless 作为后端（同机制位，无收益）。
- 不把"通用协议 sidecar"当作 Connectors 主路径（CSI + webhook 已是更贴合 ACP/Tekton 的形态）。

### 借鉴 / 启发候选（🟡 候选）

> 仅记录，不下结论；等 `/connectors-arch-review`（原则）或 `/connectors-learn`（教训/话术）触发再决定是否沉淀。

- **"机制孪生 ≠ 竞品威胁"是一类重要的竞品判读**：Secretless 与 Connectors 机制几乎相同，但产品范围悬殊——竞品分析里应区分"机制相同"与"能替代我们"，避免把同机制工具误判为正面竞品。
- **审批门控位置矩阵补一列**：Vault Control Groups（取凭据时）/ Infisical change·access request（写 secret·取权限时）/ **Secretless（无门控点，认证后透传）** / Connectors ApprovalTask（运行时按 proxy 调用）。Secretless 的"无门控"正好凸显 Connectors 把治理织进数据面的价值。
- **per-credential provider 选择**是个干净的小 UX 点（同连接不同凭据来自不同 provider），值得在 `SecretBackend` 设计里参考。

---

**相关文档**

- `secretless-broker-capabilities-guide.md` — Secretless Broker 工具自身能力（能力地图 + 分章 + 每章 demo）
- （同目录其他调研）`../infisical/connectors-vs-infisical.md`、`../connectors-vs-vault.md` — 方向 1（`SecretBackend` 抽象）同构；注意 Vault/Infisical 是**后端候选**，Secretless 是**机制孪生**，定位不同
- `../what-is-connectors.md` — Connectors 同心环竞品分级（Secretless 落在第 ① 环"机制孪生"）
