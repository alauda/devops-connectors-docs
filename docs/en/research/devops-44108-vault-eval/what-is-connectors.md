# Alauda Connectors 产品定位

> 基于 connectors-operator `docs/en/` 提炼。**目标**:让完全没接触过 Connectors 的读者 2 分钟内理解产品定位。

## 1. 是什么

Connectors 把"**集群内统一接入外部工具 + 使用时无凭据**"作为单一关注点。让平台租户、工作负载、CI 任务在使用外部工具(Git 仓库、镜像仓库、K8s 集群、制品库 ...)时,**不需要分发或持有原始凭据**。

## 2. 解决什么问题

在没有 Connectors 的世界,**每个团队各自处理工具接入这件事**,代价是:

- 凭据散落在 Secret + envFrom + shell 脚本里,容易漏进 commit log / pipeline log / 环境变量
- 不同工具(Git / Harbor / kubeconfig / Maven settings)凭据格式各异,每个团队重写一遍
- 凭据轮换时几十条 pipeline 同时红,没人知道该改哪份 Secret
- 平台 UI 要列"用户可访问的 Git repo / 镜像 tag",得为每个工具单独写一份 API client + 权限模型

Connectors 把这些统一收编 —— 平台/项目管理员一次性建好工具接入对象;CI 任务/业务负载拿到的是渲染好的配置文件,指向集群内的认证代理;**原始凭据从此只在控制面流动,业务进程永不接触**。

## 3. 不是什么(与相邻能力的边界)

| 类别 | 例子 | 关注点 | 与 Connectors 的差异 |
|------|------|--------|---------------------|
| 秘密管理 | Vault、External Secrets Operator | 通用 secret 存储 / 动态凭据 / 加密 | Connectors **不存** secret,引用的还是 K8s Secret;Vault 可作 backend |
| API 网关 | Kong、APISIX、Istio Gateway | 通用 HTTP/gRPC 流量入口 | Connectors 只代理"外部工具"协议,不是通用网关 |
| CSI Secret Store | secrets-store-csi-driver | 把外部 secret 系统的**明文密钥**挂进 Pod | Connectors CSI 挂的是**渲染后的工具配置**(如 `.gitconfig` + 代理地址 + 短期 token),不挂原始凭据 |
| 策略校验 | OPA / Gatekeeper | 通用 K8s 资源策略 DSL | Connectors 的 AccessPolicy 只管"运行时使用 Connector 时要不要先审批" |
| Operator 上架 | OperatorHub / OLM | 通用 Operator 生命周期 | connectors-operator 自身**由 OLM 管**,Connectors 解决的是 OLM 之上的工具接入问题 |
| CI/CD 平台 | Tekton、Argo、Jenkins | 流水线调度引擎 | Connectors 是**被 Pipeline 消费的资源**,不调度 Pipeline 本身 |
| 镜像/制品仓库 | Harbor、Nexus、Artifactory | 制品存储 | Connectors 把它们包成 secretless 入口,不取代存储 |
| 身份系统 | ACP IAM、Keycloak、Dex | 用户身份与 SSO | Connectors 复用 K8s RBAC,不发身份、不管用户目录 |

## 4. 核心价值

- **Connectors 不替代 Secret 管理**,它是 Secret 的**消费层** —— 已有的 Vault / K8s Secret 仍是凭据来源,Connectors 只把它们安全地"用出去"
- **Connectors 不是工具本身**,只关心**统一接入与使用** —— Git / Harbor / K8s 仍在原处,Connectors 让它们在集群内一致呈现
- **接入即工具能力开放**:10+ 内置工具类型,统一以"建模 + 鉴权 + 资源浏览 + secretless 调用"四个面打开;新接一个工具是写一份 ConnectorClass YAML,不是写一套消费胶水

## 5. 一句话总结

**Connectors = 让外部工具在 K8s 集群里"被使用,但凭据不被分发"的统一接入层。**

---

## 更多细节(机制层)

> 想进一步理解 Connectors 怎么实现"是什么/解决什么"的读者读这里。术语首次出现处带 1 句解释,完整概念文档见 `docs/en/connectors/concepts/`。

**核心抽象**

| 抽象 | 角色 |
|------|------|
| **ConnectorClass**(集群级) | 声明一类工具的接入契约 —— 地址形态、认证方式、可达性/鉴权探活、是否带 API 透传、是否带 Proxy、CSI 渲染模板。新接一种工具 = 新写一份 ConnectorClass |
| **Connector**(命名空间级,带集群/项目/命名空间三层 scope) | 一个具体工具实例 —— 地址 + 引用一个 K8s Secret 作为凭据来源。系统按 ConnectorClass 自动算出对外的 Proxy 地址与 API 路径 |
| **ResourceInterface**(集群级) | 标准化"可被 Pipeline 选择的资源类型"(如 Git 仓库、OCI 制品、Maven 包),让 Pipeline 编辑器统一展示与选择,而不是硬编码 URL |
| **AccessPolicy / AccessRequest**(命名空间级) | 在 Proxy 之上叠加门控。AccessPolicy 是长期规则(谁要先审批才能用);AccessRequest 是一次运行时使用尝试 + 审批结果 |

**统一接入建模 + 类型扩展**

Connectors 的关键设计是把"接入一种工具"做成可扩展点 —— 内置 10+ ConnectorClass 覆盖常见工具(Git / GitLab / GitHub / Harbor / OCI / Maven / NPM / PyPI / SonarQube / K8s),客户若要接入企业自研工具或非标外部系统,**写一份 ConnectorClass YAML 即可**(含可选的 Rego 自定义认证逻辑),无需改 Connectors 源码或写新的消费胶水。每个工具一旦建模为 Connector,平台、UI、CI 任务、工作负载就用同一套方式访问它。

**运行时:控制面 + 三条数据面通道**

控制面由 operator + 各 controller 构成,负责 reconcile 资源、跑可达性/鉴权探活、生成审批结果。数据面由三条通道并行承载工具访问:

- **Proxy** —— 协议代理。客户端用 K8s 短期 SA token 鉴权,Proxy 在后端注入真凭据。HTTP 工具走内置正/反向代理,OCI / Harbor 等带自定义代理
- **CSI Driver** —— 配置文件挂载。把 ConnectorClass 渲染模板 + 短期 token + Proxy 地址挂进 Pod 指定路径,业务进程当普通配置读
- **Connectors API** —— 统一资源浏览。让 UI 列出"用户可访问的 Git 分支 / 镜像 tag / 项目仓库",平台不必为每个工具单独写 API client

真凭据的流动范围只有两处:controller 读 K8s Secret + Proxy 注入后端请求,**永不到达业务进程**。

**5 类典型场景**

1. **CI 任务 secretless 访问外部工具** —— Tekton task clone/pull/push 不再把 token 写进 env/log;挂 CSI 卷即拿到指向 Proxy 的 `.gitconfig` / `.docker/config.json` / `KUBECONFIG` 等渲染好的配置
2. **K8s workload 镜像拉取 secretless** —— OCI/Harbor 的反向代理 + 准入 Webhook 让 kubelet 通过 Proxy 拉镜像,业务负载不再依赖各处分发的 imagePullSecrets
3. **Pipeline UI 选资源** —— 在 Pipeline 编辑页直接下拉选 Git 仓库 / 分支 / 镜像 tag,而不是手敲 URL
4. **敏感操作审批门控** —— 生产 promotion 等高风险使用,挂 AccessPolicy + Tekton ApprovalTask;审批未过时 CSI 只挂错误占位文件,Pod 自然失败
5. **三层 scope 治理** —— 同一份 GitHub 在集群级共享、项目级 Harbor 在项目内共享、敏感工具在命名空间私有,凭据按需流动

---

## 竞品与同类产品

Connectors 不是 secrets vault,而是"协议感知的数据面代理 + K8s 短期工作负载身份,嵌入 CI/CD 的连接(Connection)抽象"。按"与 Connectors 像在哪"把社区产品分为三个同心环,**越靠内越像 Connectors、越有定位参考价值**。下面每个环一张表 + 一段描述。

**总览**:第 ③ 环是"可作为 Connectors 后端凭据来源 / 部分功能重合"的**存储层**(本轮 Vault/Infisical 调研即落在此环);第 ①、② 环才是**产品定位上真正对标**的对象,而它们恰恰是过去调研的空白。Connectors 的结构性差异在于:真凭据永不出 `connectors-system`、吊销靠每请求 SubjectAccessReview 撤 RBAC(非等 lease 过期)、且把"免 imagePullSecret 拉镜像"和"air-gap 装升"当一等需求——这三点在下列所有产品里都缺位或仅部分覆盖。

### ① 机制孪生

与 Connectors 的**架构机制**相同:用代理在出栈方向注入真凭据 / 发放短期工作负载身份,客户端永不接触真凭据。这一环是 Connectors 的护城河所在,也是定位参考价值最高、过去调研最缺的一环——它们证明"代理注入凭据"是可落地的成熟架构,同时也凸显 Connectors 独有的"每请求 RBAC 吊销 + 镜像改写"。

| 产品 | 一句话定位 | 与 Connectors 关系 | OSS / 许可 | air-gap 自托管 |
|------|-----------|--------------------|-----------|----------------|
| **CyberArk Secretless Broker** | 本地代理→出栈注入真凭据,client 永不见 | 最近的机制孪生;无每请求 RBAC、无镜像改写 | Apache-2.0 | ✅(依赖后端 vault) |
| **Teleport** | 访问代理 + 短期 SPIFFE 身份 + 审计 + 审批一体 | 最完整的"代理+身份+审计+审批"形态;**AGPL+禁嵌入**不可内嵌 ACP | AGPLv3 / 企业版 | 仅企业版 |
| **HashiCorp Boundary** | 身份感知访问代理,会话级注入凭据 | 概念匹配,但面向人→主机会话非 CI→工具 | BUSL(待核实) | 受限 |
| **SPIFFE / SPIRE** | CNCF 短期工作负载身份标准(SVID) | 身份原语,非代理;可作集成对象/护城河对照 | Apache-2.0 CNCF | ✅ |

### ② 形态孪生

与 Connectors 的**产品形态**相同:CI/CD 平台里的"连接(Connection)抽象 + UI 资源选择器 + 治理/审批"。这一环最值得借鉴连接抽象的 UX、作用域共享与连接级审批,同时是 Connectors 的定位靶子——它们的短板(OIDC 覆盖面、无内容资源浏览、无免-imagePullSecret 拉镜像)恰是 Connectors 的差异点。

| 产品 | 一句话定位 | 与 Connectors 关系 | OSS / 许可 | air-gap 自托管 |
|------|-----------|--------------------|-----------|----------------|
| **Azure DevOps Service Connections** | ~25 种 typed 连接 + UI + 跨项目共享 + 连接级审批 | 最近的形态孪生;OIDC 仅覆盖 Azure 目标、UI 不浏览工具内容资源 | 闭源 SaaS/Server | 仅 Server 版 |
| **Harness Connectors** | 同名;连接 + delegate + 可插拔外部 secret manager | 形态孪生;**赛道里除我们外唯一有真 UI 资源选择器者** | 闭源 SaaS/Self-Managed | 半友好 |

### ③ 替代 / 重合的存储与下发

在"凭据存储 / 下发"问题域上与 Connectors 重合,但走 **secret-injection**(把短期 secret 推进客户端 env/file)而非 **data-plane proxy**。这一环是"可作 Connectors 后端凭据来源 / 部分功能重合"的存储层,不是产品定位上的对标对象——本轮 Vault/Infisical 调研即落在此环。

| 产品 | 一句话定位 | 与 Connectors 关系 | OSS / 许可 | air-gap 自托管 |
|------|-----------|--------------------|-----------|----------------|
| **HashiCorp Vault** | 通用 secrets 引擎 + 动态凭据 | 后端凭据来源/部分重合;注入模型(本轮已深挖) | BSL | ✅ |
| **Infisical** | 开发者友好的 secrets 平台 | 同 Vault;注入模型(本轮已深挖) | MIT core / 付费版 | ✅ |
| **CyberArk Conjur** | 企业机器身份 secrets 管理 | 客户既有投资;Conjur=存储、Secretless=机制 | Apache-2.0 / 企业版 | ✅ |
| **OpenBao** | Vault 的社区 fork,无 BSL | air-gap 干净的 Vault 替代;**许可是 MPL-2.0** | MPL-2.0 LF | ✅ |
| **External Secrets Operator** | 从外部 store 同步出 K8s Secret | "注入模型"的标杆反例,用于 proxy-vs-injection 对照 | Apache-2.0 | ✅ |
| **Secrets Store CSI Driver** | 把外部 store 的 secret 挂进 Pod 卷 | 下发层;Connectors 自身也用 CSI,机制相邻 | Apache-2.0 | ✅ |

> **补充说明**
>
> - **注入 vs 代理是分水岭**:第 3 环几乎全是 secret-injection(把短期 secret 推进客户端);Connectors 的 data-plane proxy(真凭据永不进客户端地址空间)+ 撤 RBAC 秒级吊销,是结构性差异而非功能多少之差——对外定位都应锚在这条线上。
> - **上游趋同风险**:K8s KEP-4412(v1.34 beta 默认开)让 kubelet 用 Pod 的 bound SA token 换 registry 凭据,是上游首次直接碰 Connectors 的"免 imagePullSecret 拉镜像";但它需每节点装 credential-provider 插件且只解决镜像拉取,Connectors 的 webhook 改写无需节点侧配置且统一了 CI-secretless+镜像+治理+审计+UI。需持续盯。
> - **许可陷阱**:机制最像的两个(Teleport、Boundary)都改了非 OSI 许可(AGPL+禁嵌入 / BUSL),作为 ISV 无法拿来嵌入 ACP——这反而强化了 Connectors "K8s 原生 + 可嵌入 + Apache 生态"的位置。
> - **air-gap 出局**:Akeyless / Doppler / 1Password / 云 KV(AWS SM、GCP SM、Azure KV)+IRSA 等 SaaS 锚定产品与 Alauda air-gapped 交付模型冲突,未纳入上表。
> - **待核实(单源,落正式结论前需核)**:CyberArk 被 Palo Alto 收购及 Conjur OSS roadmap;"External Secrets Operator 已暂停维护"(来自竞品博客);Boundary 当前 LICENSE 是否仍 BUSL。
> - 形态环两个孪生的详细机制见同目录 [`azure-and-harness.md`](./azure-and-harness.md);Connectors 与 Vault 的逐项对比见 [`connectors-vs-vault.md`](./connectors-vs-vault.md)。
