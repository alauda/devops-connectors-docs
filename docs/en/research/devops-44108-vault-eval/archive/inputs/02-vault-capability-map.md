# Vault 能力图：对照 Connectors 11 个用户问题域的客观调研

> 范围：HashiCorp Vault（OSS Community Edition）+ Vault Enterprise + 其 Kubernetes 生态（Vault Agent、Vault Secrets Operator (VSO)、Vault CSI Provider、Kubernetes Auth Method）。
> 调研立场：客观，不预设"能/不能替代 Connectors"的结论，逐项说明 Vault 用何机制覆盖（或不覆盖）该问题。
> 主要权威来源：`developer.hashicorp.com/vault/docs`、`developer.hashicorp.com/vault/api-docs`、Vault Secrets Engines（kv / pki / ssh / database / aws / gcp / azure）、Auth Methods（kubernetes / jwt / approle）、Audit Devices、Vault Agent Injector、Vault Secrets Operator、Vault CSI Provider、Enterprise 文档（Namespaces / Control Groups / Performance Standby / Sentinel / Performance Replication）。

---

## 0. Vault 的核心架构哲学

Vault 是一台 **secret broker**：所有秘密集中存放在一个加密 backend（默认 integrated Raft storage 或外部 Consul），客户端通过 token 化身份调用 Vault API 拿一份**带 TTL 和 lease 的凭据**，到期由 Vault 主动 revoke。其三大设计支柱：

1. **Secret Injection（注入式交付）**：秘密由 Vault 推/拉到 workload（Agent sidecar 写文件、VSO 同步成 K8s Secret、CSI 挂载 tmpfs），workload 直接持有明文凭据后再去访问目标系统。Vault 本身**不在 data path 上**——它只是发凭据，不代为转发数据。
2. **Dynamic Secrets**：对支持的后端（DB、AWS IAM、SSH cert、PKI），每次请求**现场生成一对一短期凭据**（user/password 或 cert），由 lease 跟踪，TTL 到期或被 revoke 时 Vault 反向调用后端 API 删用户/吊销 cert。
3. **Lease / Token / Identity 模型**：所有授权挂在 token → policy → path → capability 上；policy 是 HCL，按 mount path（如 `secret/data/team-a/*`）细粒度授权。

这与 Alauda Connectors 的 **data-plane proxy 模式**有根本差异：Connectors 的 Git proxy、OCI reverse proxy、Maven proxy 是**协议级中继**——CI/kubelet 看见的是"工具本身"的 endpoint，凭据在 proxy 进程里注入到上游请求，client 全程**拿不到明文 token**。Vault 是"先把 secret 发给你，你自己拿去用"；Connectors 是"我替你用，secret 永远不离开服务端"。

---

## 1. CI secretless

**Vault 解决路径**：CI Pod 通过 **Kubernetes Auth Method**（OSS）以自身 ServiceAccount JWT 换取 Vault token（`auth/kubernetes/login`），再用 token 读 KV secret 或申请 dynamic credential。落地形态主要三种：

- **Vault Agent Injector**（OSS，sidecar 模式）：mutating webhook 注入 init/sidecar container，sidecar 把秘密**写到 `emptyDir` 共享卷文件**（如 `/vault/secrets/git-token`），CI task 用 `cat` 读取。
- **Vault Secrets Operator (VSO)**（OSS controller，独立项目）：把 Vault 秘密**物化为 K8s Secret**，CI task 通过 `envFrom` / `volumeMount` 消费。
- **Vault CSI Provider**（OSS）：tmpfs 挂载，仅在 Pod 生命周期内可见。

**能否真正 secretless？** 否。三种模式 client 都能 `cat /vault/secrets/git-token` 看到明文 PAT，凭据会进入 task script 环境变量、git CLI 进程命令行、Tekton step log（若 `set -x` 或 git 默认 verbose）。**唯一接近 secretless 的路径是 dynamic secrets**：

- Git/GitLab 没有 Vault 原生 dynamic engine（社区只有 GitLab API token 的非官方插件）；
- SSH 走 **SSH Secrets Engine (signed certificate)**（OSS），Vault 签发短期 SSH cert，client 凭 cert + private key 推 Git，cert 几分钟过期；
- Harbor / OCI / Maven / NPM / PyPI 全无 dynamic engine，只能下发长期 robot account / API key。

**改造工作量**：每个 CI task 改成 `vault read` + 环境注入；Tekton task 模板需要重写以引用 Vault 路径而非 Connector ResourceInterface；Git 仍需明文 token（PAT 或 BasicAuth）才能完成 HTTPS clone，**与 Connectors 的"git push 经过 proxy，token 永不出服务端"不等价**。

---

## 2. K8s 镜像拉取

**Vault 解决路径**：业界标准做法是用 **Vault Secrets Operator (VSO)** 把 registry 凭据物化为类型为 `kubernetes.io/dockerconfigjson` 的 Secret，再通过 ServiceAccount `imagePullSecrets` 或 Pod `spec.imagePullSecrets` 引用。VSO 支持周期性 sync 实现凭据刷新。

**能力边界**：

- **每个 namespace 都要绑 imagePullSecret**：Vault 不改变 kubelet 的镜像拉取协议——kubelet 仍然走 `imagePullSecrets`。要做到"集群任意 Pod 都能拉"，必须给每个 namespace 投递 Secret + 让所有 SA 引用，VSO 可以批量做但运维成本非零。
- **无 mutating webhook 自动注入 imagePullSecret**：Vault 生态官方不提供"自动改 Pod spec 加 pullSecret"的 webhook，需要自研或用 third-party（如 kyverno）。
- **凭据轮换需 kubelet 重新认证**：Secret 刷新后已运行 Pod 不会重新拉镜像；新 Pod 调度时会拿到新 Secret。
- **完全没有"代拉镜像"机制**：与 Connectors OCI **reverse proxy**（kubelet 把 image ref 指向集群内 proxy，proxy 用集中凭据回源 Harbor，业务 Pod / ServiceAccount **完全不需要 dockerconfigjson**）相比，Vault 模式是 dockerconfigjson-everywhere 模式的"集中签发"，不是"集中代理"。

**OSS vs Enterprise**：上述全部 OSS 即可。

---

## 3. 平台治理 + 委派

**Vault 解决路径**：

- **Policy（OSS，HCL）**：按 path glob + capability（read/list/create/update/delete/sudo）控制访问。可写出"只能读 `secret/data/github/approved-orgs/*`"这类 policy。
- **Identity / Groups / Entity Aliases（OSS）**：把多 auth method 身份聚合到 entity，给 group 绑 policy 实现 RBAC。
- **Namespaces（Enterprise only，关键）**：多租户硬隔离，每个 namespace 独立 policy / mount / token，跨 namespace 必须显式 path 引用。**这是企业级平台治理的核心特性**。
- **Sentinel（Enterprise only）**：策略即代码，写更复杂规则（time-of-day、source IP、MFA 状态）。
- **Control Groups（Enterprise only）**：访问敏感 path 需 N 人审批（详见问题域 5）。

**委派模型**：管理员预先在 Vault 中按 Org/Project 维度建 path（如 `secret/data/projects/team-a/github/`），policy 只授权该 path 子树；用户/CI 拿到的 token 物理上看不到未授权 path（`list` 都返回空）。

**与 Connectors 的差异**：Connectors 的"平台凭据 → 项目可见性"是**对象级 RBAC + label selector**（GlobalConnector 在 platform namespace，通过 sharing 机制对项目可见），UI 直接呈现"这个项目能用哪些 Connector"。Vault 没有内建对象级"已批准列表"概念，必须靠 path 约定 + policy 模拟，UI 工具链也不内建。

**成本**：Namespaces 强依赖 Enterprise license，按 cluster + node 计费，对 100+ 项目的多租户场景几乎是必选。

---

## 4. 项目级多租户

**Vault 解决路径**：

- **Namespaces（Enterprise）**：每个项目可以是一个 namespace（如 `vault namespace create team-a`），项目 A 在自家 namespace 里挂自家 GitLab 凭据；项目 B 在另一个 namespace 挂公司 GitLab 凭据。互不可见。
- **OSS 替代**：只能用 **path prefix + policy 约定**模拟，如 `secret/data/team-a/*` vs `secret/data/team-b/*`。所有项目共享同一组 mount，policy 错配即跨项目泄漏；mount-level 调优（如不同 KV v2 配置、不同 audit）不可能按项目独立。
- **Auth Method 隔离**：每个 namespace 可独立配置 Kubernetes Auth、JWT Auth（接不同 OIDC issuer），项目 A 可用自家 GitLab 作为 JWT issuer，项目 B 用公司 IdP。

**对照 Connectors**：Connectors 中"项目 A 用自家 GitLab"等同于在项目 namespace 创建 `GitLabConnector` CR，控制器在该 namespace 起 proxy，pipeline 引用 `ResourceInterface` 即可。无需 Vault 多 namespace 切换、无需 token 在跨 namespace 间转移。

**OSS 局限**：OSS 多租户在 Alauda 目标客户场景（数十到数百项目、强隔离、独立审计）**事实上不可用**，必须 Enterprise。

---

## 5. 审批门控

**Vault 解决路径**：

- **Control Groups（Enterprise only）**：在 policy 上加 `control_group { factor "approver" { identity { group_names = ["sec-team"] } approvals = 2 } }`，用户读敏感 path 时返回一个 `wrapping_token`，需 N 个 approver 调 `/sys/control-group/authorize` 后才能 unwrap。可写出"prod GitHub push token 需 2 人审批，dev 直接给"。
- **Sentinel EGP（Enterprise only）**：endpoint governing policy 可拦请求做更复杂的 pre-check（含 MFA、time-window）。
- **OSS 完全无审批门控**：OSS 没有任何"二次确认"机制，policy 是布尔（allow/deny）。

**与 Connectors 现状**：Connectors 当前也没有原生审批门控；CEO 问题里"生产推送走审批"在 Connectors 侧通常靠**Tekton Pipeline manual approval task** + RBAC + EventListener filter 实现，与凭据系统解耦。Vault 的 Control Group 是把审批**绑死在凭据领取上**，更强，但需 Enterprise。

**成本**：Control Groups 是 Enterprise 顶层 feature，license 量级显著。

---

## 6. UI 资源选择器

**Vault 解决路径**：**Vault 不覆盖此问题域**。Vault 的职责是签发/存储凭据，不是"代理工具 API 返回可选资源列表"。要实现 UI 选 Git branch / OCI tag：

- 调用者必须**自己**用 Vault 发的 token 调 GitLab API `/projects/:id/repository/branches`、Harbor API `/projects/:project/repositories/:repo/artifacts`；
- UI 组件、缓存、错误处理、限流、协议适配（GitLab vs Gitea vs GitHub Enterprise）都要自研；
- Vault 也不存"branch list 这个能力是否在当前 namespace/project 可见"——这是上层 catalog 层职责。

**对照 Connectors**：Connectors 的核心增值之一就是**统一 ResourceInterface API**——一个 `git/branches` 端点屏蔽 GitLab/Gitea/GitHub/Gerrit 协议差异；Tekton style descriptor + dynamic form 可直接绑该 endpoint 渲染下拉框。Vault 没有任何对应物，要补这层至少需要：
- 自研一个跨 Git/OCI/Maven 的 proxy gateway，
- 或在 UI 层为每种工具单独写 SDK + 鉴权适配，
- 凭据仍从 Vault 拿，但**Connectors 这层逻辑等于全部要重做**。

**OSS / Enterprise**：与 Vault 版本无关，**结构性 gap**。

---

## 7. 凭据轮换 / 短期化 / 吊销

**Vault 解决路径**：Vault 在此问题域**能力最强**，分两类：

- **Dynamic secrets（OSS 大部分 engine）**：
  - **Database** engine：CI 跑前申请一个 PostgreSQL/MySQL 临时用户，TTL=10min，跑完 Vault 自动 `DROP USER`。
  - **AWS / GCP / Azure** engine：临时 IAM credential。
  - **PKI** engine：短期 cert。
  - **SSH** engine：signed SSH cert。
- **KV v2 + 版本化 + 主动 rotate**：静态 KV 支持版本和 rotate API。
- **Lease revoke**：`vault lease revoke -prefix sys/leases/...` 可批量吊销。

**到外部工具的 Connectors 场景**：
- **Harbor robot、Nexus deploy token、Artifactory token（部分）**：**无 Vault 官方 dynamic engine**。需用户手工产、放 KV，rotate 要自己写 cron。
- **GitLab**：**自 Vault 1.18（2024-09）起 GitLab Secrets Engine 已是官方 engine**（`vault secrets enable gitlab`），可 dynamic 创建短期 PAT；早于 Connectors 4.x 立项时点（2024-10）。
- **GitHub App**：官方提供 GitHub App auth method（OSS），可发短期 installation token，最接近 Connectors 现状对 GitHub App 的处理。
- **Artifactory**：JFrog 与 HashiCorp 官方合作的 Artifactory secrets engine 可 dynamic 发 access token。
- **其他官方 engine**：Terraform Cloud / Kubernetes（dynamic SA token）/ Consul / Nomad / RabbitMQ / Kerberos 等。在 Connectors 实际工具集外的覆盖面相当广。

**短期化的真实约束**：即使凭据从 Vault 取到 CI pod 后是 10min TTL，**该凭据在 10min 内已被写入 Git URL（`https://oauth:TOKEN@gitlab.com/...`）、可能被 `git config` 缓存、可能在日志里出现一次**。Vault 不能保证"client 不会泄漏它已经收到的明文"。Connectors proxy 模式下 token 从未离开 proxy 进程，**这是 Vault 无法企及的边界**。

---

## 8. 审计

**Vault 解决路径**：**Audit Devices**（OSS）—— file / syslog / socket sink，记录每个 API 请求的 request + response（含 hmac 化的 token、policy、path、client IP、entity ID、timestamp）。可对接 Splunk / ELK / Loki。

**能审什么**：
- 谁（entity / token / alias）；
- 何时（精确到 ms）；
- 调了哪个 path（`secret/data/github/team-a/token`）；
- HTTP method、capability、source IP；
- 是否成功（含 policy deny 也记录）。

**能力边界**：
- Vault audit log 只能告诉你"谁从 Vault 取了凭据"，**取不到"凭据被取走后实际做了什么"**——CI 拿到 GitHub token 后 push 了哪个 commit、推到哪个 branch、是否触发 protected branch policy，Vault 不知道。
- 与 Connectors proxy 模式相比，Connectors 在 data plane 上能看到具体 HTTP method + path（`POST /api/v4/projects/123/repository/commits`）、可做 deny / rate-limit，**Vault 完全没有这一层**。

**结合外部审计**：要拼出"谁通过 GitHub token X 推了 commit Y"，需要把 Vault audit log + GitHub audit log + CI run log 三方关联，工程量非小。

**OSS / Enterprise**：Audit Devices 全 OSS。Enterprise 多一个 `audit-as-leader` 等运维优化但能力等价。

---

## 9. air-gap 可安装可升级

**Vault 解决路径**：

- **离线安装**：Vault 是单二进制 + helm chart，镜像可从 `hashicorp/vault` 拉到客户内网 Harbor，helm chart 拉到内网 chart museum。**air-gap 友好**。
- **HA**：默认 Integrated Storage（Raft），推荐 3 或 5 节点。无需外部 Consul。
- **Auto-unseal**：
  - **OSS 支持**：Transit auto-unseal（另一个 Vault 做 KMS）、Shamir manual unseal（开机要人工输 3/5 key）。
  - **Enterprise 必需**：云 KMS auto-unseal（AWS KMS、Azure Key Vault、GCP KMS、HSM PKCS#11）在 OSS 也可用，**但 HSM auto-unseal 是 Enterprise only**。
  - **air-gap 痛点**：客户内网没有云 KMS，Transit auto-unseal 需要"另一个 Vault"，先有鸡还是先有蛋；纯 Shamir 意味着集群每次重启要召集 3 个 key holder 联合解封——运维上非常痛。
- **备份恢复**：`vault operator raft snapshot save/restore`（OSS），需自建定时任务和异地存储。
- **升级**：Helm 滚动 + Raft leader step-down，无重大兼容性事故，但 storage schema 升级需停机的版本要看 release note。

**对照 Connectors**：Connectors 是 K8s 原生组件（CRD + controller + proxy Deployment），随 ACP 标准升级流程走，无独立 unseal 概念，无"key holder 群体"运维负担。Vault 的 **unseal key 治理在 air-gap 环境是真实的组织级问题**——3 个 key holder 谁在哪个 KMS 里存了哪一份 share，灾难恢复时谁能联络上，需要客户侧建立独立流程。

**成本估算**：3-5 节点 HA Vault 集群（CPU 2c / RAM 4G / 持久盘 / 跨 AZ）+ TLS cert + 监控（Prometheus / Vault telemetry）+ unseal key 流程文档 + DR 演练。初装 1-2 人周，长期 0.2-0.5 SRE FTE。

---

## 10. 热轮换不断流

**Vault 解决路径**：

- **Vault Agent 自动 renew**：sidecar 监控文件 mtime + lease TTL，到点重新 render 模板文件（`vault.hashicorp.com/agent-inject-template-*`），可触发 `command` 让 app reload（如 `nginx -s reload`）。**前提是 app 支持热 reload**。
- **VSO 周期 sync**：K8s Secret 被更新后，**已挂载该 Secret 的 Pod 的 volume 会异步刷新**（kubelet sync period 约 60s），**但 `envFrom` 注入的环境变量不会刷新**——Pod 必须重启或重读文件。
- **Dynamic secret + 双 lease**：标准做法是发新 lease 前不 revoke 老 lease，留 grace period 让 in-flight 请求完成。Vault `max_ttl` 控制硬性失效。

**对照 Connectors 现状**：
- Connectors **OCI reverse proxy** 持有 Harbor 凭据，proxy 进程 reload 凭据时正在拉镜像的 kubelet 连接由 proxy 透明续传——业务 Pod 完全无感。
- Connectors **Git proxy** 同理，CI task 正在 `git push` 时 proxy 后端凭据轮换不会中断当次 push。
- Vault 模式下凭据已经在 CI pod 里被注入到 `git push` 命令行，**轮换发生在 push 进行中时**：旧 token 必须等 in-flight 请求完成才能 revoke，否则当次 push 失败需 retry。**热度是"两个 lease 重叠"，不是"零中断"**。

**结论**：Vault 能做到接近不断流（grace period + double-write），但**完全零中断的连接级透明轮换需要 data-plane proxy**——Vault 模型本身不具备。

---

## 11. 新工具 onboarding 成本

**Vault 解决路径**：分两层成本：

- **凭据存储侧（Vault 内）**：
  - 静态 KV：在 KV mount 下加 path 即可，几乎零成本。
  - Dynamic engine：若目标工具有官方 engine（DB / 云），enable mount + 配 connection + 配 role，1-2 天。
  - 若**没有**官方 engine（Jira / Artifactory / Bitbucket / 大部分 SaaS），只能用 KV 存静态 token，rotate 自写。**Vault 不会替你写适配**。

- **消费侧（CI / Pod 拿到凭据后做什么）**：
  - Vault 只发凭据。每接一个新工具，CI task 模板要新写一份（包含 vault 取 secret → 调用该工具 CLI → 错误处理）；
  - **资源选择器**（branch / repo / tag list）要新写 UI 组件 + API client；
  - 没有"工具元数据 catalog"层——每个工具是一组分散的 KV path + Tekton task + UI 组件。

**对照 Connectors**：Connectors 接新工具是**实现一个 ConnectorClass + 一组 ResourceInterface handler**——proxy 协议、UI 资源选择器、Tekton task adapter 走统一框架，新工具能立即接入"凭据治理 + Tekton 选择器 + Pod imagePull"等所有已有能力。Vault 模式下每个新工具的**消费侧基础设施需各自实现一遍**。

**成本量级**：在 Vault 上为一个新 SaaS 工具加完整体验（凭据 + UI 选择器 + Tekton 模板 + 审计），与在 Connectors 上加同等体验，**Vault 工程量是数倍**。

---

## 12. Vault 的能力红线（结构性无法解决）

按 11 个问题域归纳 Vault **结构上不覆盖**的部分：

1. **完全的 client-side secretless**：凡是 client 需要直接调用目标工具（git push、docker pull、curl Harbor）的场景，Vault 必须把凭据物化到 client，client 即拥有明文凭据的全部能力。Connectors data-plane proxy 模式下凭据从未离开服务端——Vault 模型本质上做不到。
2. **kubelet 维度的"代拉镜像"**：Vault 只能下发 dockerconfigjson，不能让 kubelet 把镜像请求转发到一个集中 proxy 用集中凭据回源。Connectors OCI reverse proxy 这一形态无 Vault 等价物。
3. **跨工具统一 ResourceInterface（branch / tag / repo list 等元数据 API）**：Vault 不在 data path 上，没有协议适配层，UI 选择器要全自研。
4. **data-plane 维度的细粒度审计与拦截**：Vault 审计只到"谁取了凭据"，不到"用这个凭据做了什么 HTTP 调用"。
5. **零中断的连接级凭据热轮换**：Vault 模型必然有"client 已经拿到旧 token 在用"的窗口；只能靠 lease 重叠模拟，无法做到 proxy 进程内 in-flight 连接的透明续期。
6. **统一的"工具集成 catalog"抽象**：Vault 没有 ConnectorClass / Integration 概念，新工具的 UI、Tekton 模板、审计、imagePullSecret 注入都要各自实现。
7. **K8s-native 对象级共享与可见性模型**：Connectors 的 GlobalConnector 共享给项目、CR 跨 namespace 引用是 K8s 对象语义；Vault 是另一套权限模型（policy / namespace / entity），与 K8s RBAC 不同源、不能直接复用 K8s Project / Tenant 抽象。

---

## 13. Vault Enterprise 商业冲击

**必须 Enterprise 才能拿到的关键 feature**：Namespaces（项目级多租户隔离）、Control Groups（审批门控）、Sentinel（策略即代码）、Performance Replication / DR Replication（多集群）、HSM auto-unseal、Performance Standby（读扩展）、MFA on namespace、Filtered/Paths-aware replication。

**对 Alauda 目标客户的影响**：金融 / 国央 / 电信场景几乎必然需要 Namespaces（多项目硬隔离）+ Control Groups（合规审批）+ DR Replication（异地容灾），即**必须 Enterprise license**。HashiCorp Vault Enterprise 按 cluster + node 计费，公开口径年订阅量级**每集群 $50k-$200k+**（按规模与 SKU 浮动），多集群、HSM、global namespace 进一步上浮。Alauda 客户多为成本敏感、且要求源码可控的环境，**引入 Vault Enterprise 既增加直接 license 成本，又把核心治理能力压在 HashiCorp 商业路线图上**，与 Alauda"开源标准 + 全栈自主"定位存在冲突。
