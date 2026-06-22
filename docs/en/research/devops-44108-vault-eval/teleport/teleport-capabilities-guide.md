# Teleport 能力调研指南（聚焦 Machine & Workload Identity / Access Proxy / JIT 审批 / 审计）

> **状态**：已完成（持续可追加）
> **覆盖版本**：Teleport 17.x（Git proxy 需 ≥17.2 Enterprise；个别字段标版本）（截至 2026-06-16）
> **基于源**：官方文档 `goteleport.com/docs` + 官方 blog/license 页（逐条带 URL）
> **edition 范围**：Community Edition（自编译 = AGPLv3；官方二进制 = 商用 Community license）+ Enterprise（含 Identity Governance / Identity Security 等付费模块）
> **作用域（重要）**：本指南**只深挖** Connectors 相关面 —— Machine & Workload Identity（tbot / SPIFFE SVID / 短期证书）、identity-aware Proxy、Access Requests（JIT 审批）、Git/Application 代理、审计日志、RBAC。SSH / Kubernetes / Database / Web 应用访问，§1 给出**统一的访问流程 + 最小命令**示范（体现"一个 proxy 管多协议"）；但每协议的**深度内部机制**（RBAC 字段语义、各协议会话录制模式、数据库自动建/销用户等）不展开。Windows Desktop 仅列存在性（§10）。
> **不覆盖**：价格数字（以官网 pricing 为准）；与 Connectors / ACP 的对比（见 `connectors-vs-teleport.md`）；各协议主机访问的深度内部机制（§1 只到访问流程层面）。
> **未实测**：本指南未在集群实跑 demo，命令/YAML 均"基于文档"。

本文档**只讲 Teleport 自身**：它有哪些能力、解决什么问题、基本原理、哪些收费。

---

## §0 是什么 + 架构 + 能力概览

**是什么**：Teleport 是一个"身份原生的基础设施访问平面"——用一个**内置 CA 的 identity-aware proxy**，把对 SSH / K8s / 数据库 / Web 应用 / Windows 桌面的访问统一收敛成"**短期证书取代长期密钥 + 零常驻权限**"，并全程审计。解决的问题：基础设施访问散落着长期 SSH key / kubeconfig / DB 密码 / VPN 凭据，无统一身份、无统一审计、无即时吊销。

**组织主轴**：本指南聚焦 Connectors 相关能力面，大致按 **by-mechanism-layer** 展开——底座（§1 Proxy+CA）→ 主体身份接入（§2 机器 / §3 工作负载 / §4 join / §5 RBAC）→ 协议化访问（§6 App）→ 治理面（§7 审计 / §8 JIT 审批）；SSH/K8s/DB/Web 的访问流程并入 §1 多协议小节，不单独成章。

**心智模型（4 行）**：Teleport 是一个**内置 CA 的 identity-aware access proxy**。它的 Auth Service 是集群的根 CA，给**人**（SSO 登录）和**机器/工作负载**（tbot 通过 join method 加入）签发**短期证书**（X.509 / SSH cert / SPIFFE SVID / JWT）；所有访问统一经 Proxy Service 出栈，Proxy 用证书里编码的身份做 RBAC 鉴权、路由到目标资源、并把每次会话/命令写进审计日志。安全模型的核心是**"短期证书取代长期密钥 + 零常驻权限（JIT 审批临时升权）"**，而不是"代用户注入真凭据"。

**简化架构（运行时数据流）**：

```
   +---------+---------+                      +---------+---------+
   |  tsh user / tbot  |   (1) login / join   |    Auth Service   |
   |  human / CI / svc |  ---------------->   |  CA + Backend DB  |
   +---------+---------+  <--- (2) cert ---   +---------+---------+
             |                                          ^
             | (3) present cert                         | (5) audit / heartbeat
             v                                          |
   +---------+---------+                      +---------+---------+               +-------------------+
   |   Proxy Service   |  (4) reverse tunnel  |   Teleport Agent  |  (6) backend  |    Real Server    |
   |  authn+RBAC+route |  <--------------->   |  ssh/kube/db/app  | --- auth ---> |  Node/K8s/DB/App  |
   +-------------------+  user <-> resource   +-------------------+  <-- data --> +-------------------+
```

- **(1)(2) 控制面（签发 + 授权）**：人（`tsh`，SSO/OIDC 登录）或机器（`tbot`，§4 join method）向 Auth Service 证明身份；Auth Service 作为集群 CA 签发**短期证书**（X.509 / SSH cert / SPIFFE SVID / JWT），证书里编码 roles/traits。
- **(3) 持证访问（左竖线 tsh ↓ Proxy）**：客户端拿短期证书连 **Proxy Service**——这一步是"出示证书"，不是再登录一次。
- **(4) 数据面（Proxy ↔ Agent，reverse tunnel）**：Proxy 校验证书 + RBAC 鉴权 + 路由；**Agent 主动拨出**建 reverse tunnel 连回 Proxy（**目标侧零入站端口**），用户流量经 Proxy 顺隧道**下行**到 Agent（Agent 端再二次校验证书）。
- **(5) 审计 / 心跳（右竖线 Agent ↑ Auth）**：会话/命令事件 + agent 心跳流式回 Auth Service 后端（§7）。
- **(6) Agent → Real Server**：**Agent 贴着目标、握有目标的真实地址 + 连接凭据**，用真/现签凭据或 impersonation 连真服务器（SSH 证书 / k8s impersonation / DB 现签短期凭据）；**App 协议则注入身份断言 JWT 而非凭据**。Real Server 的地址与凭据**只在 Agent 侧**，Proxy 不持有。
- **✦ 信任锚 = Auth Service 的 CA**：目标信任 **User CA** 才接受用户证书；客户端信任 **Host CA** 才认目标节点。控制面（签发+授权）与数据面（转发）分离。

**许可 / air-gap（先记这条，§9 详述）**：core 仓库源码 **AGPLv3**（2023-12-01 起，从 Apache 2.0 切换）；但**官方编译的二进制/镜像/AMI 从 v16 起改为商用 Community license**，带使用门槛（<100 员工且 <$10MM 年收入）且**禁止 resale / 禁止 embed 进产品**。Enterprise 是商用付费。本指南深挖的能力里，**Access Requests（JIT 审批）是分版能力**：Role Access Request 在 Community 有 **CLI-only preview**（`tsh request create` / `tsh login --request-roles` + 管理员 `tctl` 手动审批），完整工作流（审批规则 / approver 角色、dual-authorization 阈值、**Resource** Access Request、可搜索 Web UI、Slack/PagerDuty/Mattermost/Jira 插件）属 **Enterprise（Identity Governance）**（[oss-role-requests](https://goteleport.com/docs/identity-governance/access-requests/oss-role-requests/)）；Workload Identity 的 **federation / TPM join 属 Enterprise**；audit log 流式导出基础能力 OSS 也有。

### 术语消歧（开篇必读，本产品最高频理解障碍）

| 同名词 | 含义 A | 含义 B | 怎么区分 |
|---|---|---|---|
| **agent** | **服务端 Teleport Agent**：贴在目标资源旁、向 Proxy 建反向隧道、代理流量的进程（SSH/K8s/DB/App Service） | **客户端 `tbot`**：跑在需要访问资源的机器/CI 上、为机器/工作负载领证书的 Machine ID 二进制 | A 在**被访问侧**注册资源；B 在**访问侧**领凭据。tbot 是"客户端 agent"，**不是**服务端 Agent |
| **token** | **join token（资源）**：admin 提前配好的 Teleport 资源，声明"用哪种 join method、可发哪些角色、什么上下文限制"，委派 join 时**不含 secret**，决定**谁能加入集群** | **运行时 OIDC / SVID JWT**：运行态由外部 IdP（GitHub/GitLab）或 Teleport 自己签的 JWT，带真实 repo/branch 值，用于**证明身份 / 携带身份断言** | A 是**静态配置规则**（admin 先写好、CI 跑之前就存在）；B 是**运行态动态签发的凭据**。"CI 跑起来才有的 token"指 B，不是 A |
| **certificate** | **bot / renewable 证书**：tbot 自身用于持续续期的证书 | **access / impersonated 证书**：为访问后端现发的短期证书 | renewable 证书**不能**直接访问后端、只能换新证书；二者刻意分离，防止偷到一张能无限续期的访问证书 |

### 能力地图速览（30 秒看全貌）

一行 = 一章。先看这里决定往下读哪节。

**一、Community Edition（OSS / 自托管基础）能力**

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 |
|---|---|---|---|---|---|
| §1 | Identity-aware Proxy + 内置 CA | 统一身份化访问入口 + 短期证书取代长期密钥 | Auth Service 签短证书 → Proxy 按身份鉴权路由 → 写审计 | 一个 proxy 管多协议、全程审计 | 工程师 SSO 登录后访问 SSH/K8s |
| §2 | Machine ID（tbot agent） | 机器/CI 免预埋长期密钥取身份 | join method 证明身份 → tbot 持续换发短证书 → 写文件/K8s Secret | 委派 join（github/gitlab/k8s）零长期 secret | CI pipeline 拿短证书访问受保护资源 |
| §3 | Workload Identity / SPIFFE SVID | 工作负载间标准化短期身份 | tbot 暴露 SPIFFE Workload API，签 X.509-SVID + JWT-SVID | 兼容 SPIFFE 生态、可做 mTLS | 服务间 mTLS / 拿 JWT 调云 API |
| §4 | Join Methods | 加入集群时如何免长期 secret 证明身份 | 委派（云/CI 平台原生身份）或 token | github/gitlab/k8s/aws… 全覆盖 | GitHub Actions 用 OIDC 委派 join |
| §5 | RBAC 角色 | 谁能访问什么 / 能否请求升权 | allow/deny 规则 + 模板 + trait 映射 | deny 优先 + SSO trait 映射 | 角色限定可见 label 的资源 |
| §6 | Application Access（HTTP 代理 + JWT） | 给内部 Web 应用加身份层 | Proxy 反代 HTTP，注入 `teleport-jwt-assertion` | 应用免改造拿到签名身份 | Grafana/Kibana 前置统一鉴权 |
| §7 | 审计日志 + 会话录制 | 谁何时对什么做了什么、可回放 | 结构化事件 + 会话录像，可导出 SIEM | 事件 + 录像统一、可导 Splunk/Elastic | 合规审计 / 事后复盘 |
| §8（preview） | Role Access Request（CLI-only preview） | 零常驻权限的最小可用形态 | `tsh request create` / `tsh login --request-roles` → 管理员 `tctl` 手动批 | 不需 Enterprise 也能临时升权（仅 CLI、无 Web UI / 插件） | 小团队临时升权 |

**二、Enterprise（付费）能力**

| § | 能力 | 解决什么问题 | 大致逻辑 | edition |
|---|---|---|---|---|
| §8 | Access Requests 完整工作流 | 零常驻权限、临时升权前置审批 | Role/**Resource** Request → 审批规则/approver 角色 + dual-auth 阈值 → Web UI / 插件审批 → 临时重签升权证书 | **Enterprise（Identity Governance）**（Role Request 的 CLI-only preview 见上 Community 表） |
| §6.1 | Git 命令代理（GitHub） | git 操作用短期 SSH 证书冒充身份 + 审计 | git 走 Teleport，短 SSH cert 签发，GitHub 信任 Teleport CA | **Enterprise ≥17.2 + GitHub Enterprise Cloud** |
| §3.1 | Workload Identity Federation / TPM Join | 跨信任域 / 非云工作负载身份 | SPIFFE Federation / TPM 服务端 attest | **Enterprise** |

> 主机访问族（SSH / Kubernetes / Database / Windows Desktop access）是 Teleport 的主营面，但**不在本指南作用域**，仅在 §1 一句话带过。

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 理解 Teleport 整体"代理+CA"是怎么回事 | §1 |
| 让 CI / 机器免长期密钥拿身份 | §2 + §4 |
| 给工作负载发 SPIFFE 短期身份做 mTLS | §3 |
| GitHub Actions / GitLab CI 委派加入 | §4 |
| 控制谁能访问哪些资源 / 能否升权 | §5 |
| 给内部 Web 应用前置统一身份层 | §6 |
| 让 git 操作走短期证书 + 审计 | §6.1（Enterprise） |
| 留存 + 回放谁访问了什么 | §7 |
| 临时申请高权限走审批 | §8（Role Request 有 Community CLI-only preview；完整工作流 Enterprise） |

---

## §1 Identity-aware Proxy + 内置 CA（edition: Community / Enterprise）

### 解决什么问题
传统基础设施访问散落着长期 SSH key、kubeconfig、DB 密码、VPN 凭据，无统一身份、无统一审计。Teleport 用一个 identity-aware proxy + 内置 CA 把"身份签发 → 鉴权 → 路由 → 审计"收成一条链，短期证书取代所有长期密钥。

### 核心模型 / 原理
三个核心角色：
- **Auth Service** —— 集群内部 CA，给人和机器签发**短期 X.509 / SSH 证书**（用户证书默认 12h，最大 30h，`default_session_ttl` 可配），证书里编码身份、roles、traits（[architecture](https://goteleport.com/docs/reference/architecture/)）。
- **Proxy Service** —— identity-aware 反向代理 + Web UI，拦截 SSH/K8s/HTTPS/DB 等多协议流量，校验客户端证书、按 RBAC 放行、路由到目标（目标 agent 经 reverse tunnel 连回 Proxy），并把命令/查询流式写审计（[proxy](https://goteleport.com/docs/reference/architecture/proxy/)）。
- **Agent（目标侧服务）** —— 贴着目标资源运行的 `teleport` 进程，**主动拨出** reverse tunnel 连回 Proxy（目标侧零入站端口），承接 Proxy 下发的请求并连真目标（[agents architecture](https://goteleport.com/docs/reference/architecture/agents/)）。

**Agent 概念要点（最易误解，先厘清）**：
- **不是"一种 agent 对一种协议"**：agent 是**同一个 `teleport` 二进制**按配置启用的 service（`ssh_service` / `kubernetes_service` / `db_service` / `app_service`），一个 agent 进程可**同时**跑多个 service。
- **部署位置 = "网络能到目标、且握有目标真实地址 + 连接凭据的地方"**，不一定物理在目标上：SSH 原生模式 agent 就是主机上的 SSH 服务；K8s agent 可在集群内（Helm Pod）或集群外（kubeconfig）；DB agent 在网络可达 DB 处握连库凭据。
- **它是协议适配器**：对目标说该协议、用目标真/现签凭据或 impersonation 认证（App 协议则注入身份断言 JWT），见下方「多协议访问」小节。

**处理流程（`tsh ssh root@node-1` 全链路——两个校验点 + 双 CA）**：
1. **`tsh login`（发证书，不是交证书）**：用户向 Auth Service 做 SSO/本地认证，Auth **签发**一张短期 SSH 用户证书（默认 12h）下发到本地 `~/.tsh`。
2. **`tsh ssh root@node-1` → Proxy（第一个校验点）**：tsh 把该证书**出示**给 Proxy；Proxy 做三件事——① 认证（验证书是否 User CA 签发、未过期、未被 `lock`）② RBAC 鉴权（按证书里 roles/traits + **最新** role 定义，判断能否访问 node-1、能否用 `root` 这个 login）③ 路由（经 node-1 拨回的 reverse tunnel 接通）。
3. **到达 node-1（第二个校验点）**：目标 SSH 服务**独立再验一次**——签名是否来自它信任的 **User CA**、且 `root` 是否在证书 principals 列表里。
4. **双 CA 双向信任**：节点认这张证书，是因为它信任 **User CA**（**原生 Teleport 节点**加入集群时自动信任；**复用现有 OpenSSH** 时才需手工配 `TrustedUserCAKeys`）；客户端认这个节点，是因为 tsh 信任 **Host CA**（写进 known_hosts），防 MITM。

> 一句话：login 发短期证书 → `tsh ssh` 出示给 Proxy（认证 + RBAC + 路由）→ node 二次验证（User CA 签名 + principal）。

**关键边界**：Teleport 是"代理用户**自己的**身份去访问目标"（证书冒充 / 协议感知鉴权），**不是**"代理在出栈方向替客户端注入一份后端真凭据让客户端看不到凭据"。需要厘清的是：Teleport 组件**在每次访问时会用最新的 role 定义重新评估 role 规则**（rule re-evaluation 用 up-to-date role），并非"签证书后就不再过授权"；**在签发时固定下来的是证书携带的 role 集合** —— 改一个用户的 role *成员关系*（增删其 role）需要**重签证书或 `lock`** 才能生效（[authorization architecture](https://goteleport.com/docs/reference/architecture/authorization/)）。因此真正的差异更窄：Connectors 对每个请求做一次**针对集群外部/中心 K8s RBAC 的 SubjectAccessReview**，撤 RBAC 成员关系**即刻**断流；Teleport 的 role *成员* 变更要等重签 / lock。

### 核心能力清单
- 多协议统一代理：SSH、Kubernetes API、HTTPS Web 应用、SQL/NoSQL 数据库、Windows Desktop（RDP）—— **后四类即本指南作用域外的"主机访问族"，此处一句话带过**。
- 内置 CA 签短期证书，支持 CA rotation。
- reverse tunnel：firewall 后的 agent 主动连 Proxy，无需开入站。
- 所有会话流式写审计日志（§7）。

### 最小命令示例（基于文档，[get-started](https://goteleport.com/docs/)）
**场景 A：用户经 Proxy 用短期证书访问主机（两个校验点全链路）**
```bash
# ① 一次性（运维）：目标主机起 Teleport SSH 服务并加入集群
teleport node configure --token=<join-token> --proxy=teleport.example.com:443 > /etc/teleport.yaml
teleport start -c /etc/teleport.yaml
#    └ 原生节点作为集群成员自动获 Host 证书、自动信任 User CA（复用现有 OpenSSH 才需手工配 TrustedUserCAKeys）

# ② 运行态（开发者）：SSO 登录领短期证书（默认 12h，存 ~/.tsh）—— 这步是发证，不是交证
tsh login --proxy=teleport.example.com:443
# ③ 运行态（开发者）：列出有权访问的资源
tsh ls
# ④ 运行态（开发者）：访问 node-1 —— 这步才出示证书
tsh ssh root@node-1
#    └ Proxy 验证书有效性 + RBAC + 路由；node 端再验 User CA 签名 + principal(root)
```

#### 多协议访问：K8s API / 数据库 / Web 应用（同一套机制换协议复用）

和 SSH 一样，每条链都分**①前置（运维一次性把资源接进来）**和**②③运行态（开发者每次用）**两段。"出示证书 → Proxy 鉴权 → 目标二次认证"的骨架不变，差异只在"前置怎么把资源注册成 agent / 目标端拿什么短期凭据"。**关键共性**：目标的真地址与连接凭据始终锚在 **agent 侧**，Proxy 只认证用户 + 按名查 agent + 顺 reverse tunnel 转发。

**场景 B：Kubernetes API（`kubectl` 经 Proxy + impersonation）**
- 处理流程（前置 → 运行态）：①运维把 **Kubernetes Service agent** 部署进目标集群、注册成 `my-cluster`，agent 入会 + 拨 reverse tunnel + 把 `kube_cluster` 心跳给 Auth（真 API 地址与凭据只在 agent 侧）→ ②开发者 `tsh kube login` 写一份指向 Proxy 的 kubeconfig → ③`kubectl` 经 Proxy（验证书 + RBAC + 按名查 agent）顺隧道到 agent → agent 用**自己的 SA 凭据**按角色映射的 `kubernetes_groups/users` 做 **impersonation** 调真 API server（再过 k8s RBAC）。
```bash
# ① 一次性（运维）：把 Kubernetes Service agent 装进目标集群（in-cluster Helm），注册集群名 my-cluster
helm install teleport-kube-agent teleport/teleport-kube-agent \
  --set proxyAddr=teleport.example.com:443 --set authToken=<join-token> \
  --set roles=kube --set kubeClusterName=my-cluster
#    └ agent 用 join token 入会 → 拨 reverse tunnel 连 Proxy → 把 kube_cluster:my-cluster 心跳给 Auth；
#      其 ServiceAccount 需有 impersonation RBAC（chart 默认配好）。真集群地址 + 凭据只在 agent 侧。

# ② 运行态（开发者）：登录目标集群（写指向 Proxy 的 kubeconfig，含短期证书）
tsh kube login my-cluster
# ③ 运行态（开发者）：正常 kubectl —— Proxy 验证书 + RBAC + 按名查 agent → 顺隧道转给 agent
kubectl get pods
#    └ agent 用自己的 SA 凭据 + 你角色映射的 kubernetes_groups/users 做 impersonation，目标端再过 k8s RBAC
```

**场景 C：SQL/NoSQL 数据库（现签短期凭据，用户永不持密码）**
- 处理流程（前置 → 运行态）：①运维部署 **Database Service agent**、注册数据库 `pg-main`，目标库配置**信任 Teleport `db_client` CA**（云托管库则改用 IAM 授权）→ ②开发者 `tsh db login` 领短期连接凭据 → ③`tsh db connect` 经 Proxy 到 Database Service，由它**现签短期凭据**替用户认证后端库（连库凭据只在 agent 侧，用户命令里无密码）。
```bash
# ① 一次性（运维）：部署 Database Service agent 并注册数据库（teleport db configure / Helm，基于文档）
#    └ agent 经 join token 入会 + 拨 reverse tunnel；目标库需信任 Teleport db_client CA（或对 agent 开 IAM 授权）

# ② 运行态（开发者）：登录数据库（领取短期连接凭据）
tsh db login pg-main
# ③ 运行态（开发者）：连接 —— 命令里没有任何数据库密码
tsh db connect --db-user=readonly --db-name=app pg-main
#    └ Database Service 现签 db_client CA 短期证书（或云 IAM token）替用户完成对后端库认证，到期即失效
```

**场景 D：HTTPS Web 应用（注入身份断言 JWT，机制详见 §6）**
- 处理流程（前置 → 运行态）：①运维在 `app_service` 注册应用（命令见 §6）→ ②开发者 `tsh apps login` 经 Proxy 反代访问 → Proxy 逐请求注入 **Teleport 签名 JWT**（`teleport-jwt-assertion` 头）告诉应用"调用方是谁"——身份断言，非后端真凭据。
```bash
# ① 一次性（运维）：在 app_service 注册 grafana（最小配置见 §6 命令示例）
# ② 运行态（开发者）：登录应用，经 Proxy 反代访问
tsh apps login grafana
#    └ Proxy 逐请求补 teleport-jwt-assertion JWT，应用用 /.well-known/jwks.json 验签（详见 §6）
```

### 一句话本质
Teleport = 内置 CA 的身份感知代理，用短期证书取代长期密钥，统一鉴权与审计。

---

## §2 Machine ID（tbot agent）（edition: Community / Enterprise）

### 解决什么问题
机器、CI pipeline、自动化任务需要访问受 Teleport 保护的资源，但不该预埋长期密钥（写进 env / Secret 容易泄漏）。Machine ID 让机器**用平台原生身份证明自己**，再持续换发短期证书。

### 核心模型 / 原理
- **Bot** —— Teleport 里代表一个机器身份的实体，绑定一组 roles。
- **tbot** —— 跑在机器/CI 上的轻量 agent，用 **join method**（§4）向 Auth Service 证明身份，拿到短期证书，写成**配置文件 artifacts**（落盘 / K8s Secret / SPIFFE Workload API），并在到期前自动续期（[introduction](https://goteleport.com/docs/machine-workload-identity/introduction/)）。

**处理流程（CI → 受保护资源，CR/文件全链路）**：
1. 管理员建一个 **join token**：声明它授予哪个 bot、需要什么 join method（proof），例如 `github` / `gitlab` / `kubernetes`（[join-methods](https://goteleport.com/docs/reference/deployment/join-methods/)）。
2. tbot 在 CI/机器上启动 → 用平台签发给它的身份（如 GitHub Actions OIDC token、K8s SA JWT）走对应 join method **登录** Auth Service。
3. Auth Service 校验该 proof（如向 GitHub OIDC / K8s TokenReview 核验）→ 签发**短期证书**给 bot。
4. tbot 把证书/kubeconfig/identity 文件**写到磁盘或 K8s Secret**，供同机的工具（git / kubectl / tsh / 自定义客户端）使用。
5. **续期**：tbot 默认每 `renewal_interval` **20m** 续一次，证书 `credential_ttl` 默认 **1h**、普通 output **最大 24h**（[configuration ref](https://goteleport.com/docs/reference/machine-workload-identity/configuration/)；早期版本字段名为 `certificate_ttl`；renewal_interval 必须 < credential_ttl）。**注意不要把 `credential_ttl` 与 bot 证书的 `MaxSessionTTL` 混为一谈**：近期提到延长到 **7 天**的是 bot 证书的 **MaxSessionTTL**（`tctl bots add --max-session-ttl`），是另一条轴，与单次 output 的 `credential_ttl`（默认 1h / 最大 24h）不同（[PR #53893](https://github.com/gravitational/teleport/pull/53893)，backport 至 v17）。

**关键抽象**：tbot 是**身份的"续期泵"** —— 它本身不持长期 secret（委派 join 时），持续把短期证书刷新到一个消费点（文件 / K8s Secret / gRPC API）。

### 核心能力清单
- 委派 join（无长期 secret）或 token join。
- 输出 artifacts：identity 文件 / kubeconfig / TLS 证书 / SPIFFE SVID。
- 自动续期、过期前轮换。
- 可作为 service 跑后台（`ssh-multiplexer`、`workload-identity-api` 等）。

### 最小命令示例（基于文档，[github-actions deployment](https://goteleport.com/docs/machine-workload-identity/deployment/github-actions/)）
**场景 A：CI 用平台 OIDC 委派 join，免长期 secret 拿短期证书**

> ⚠️ **GitHub 在此是"身份提供方（join）"，不是被访问目标**：`join_method: github` 只决定"CI 怎么证明自己是谁"；tbot 拿到的短期证书用于访问 **Teleport 保护的资源**（DB / K8s / SSH …），**不是用来访问 GitHub**。要让 git 操作本身走 Teleport 是另一独立功能（§6.1 Git 命令代理，Enterprise）。
>
> 注意分清两个 "token"：**join token 资源**（下方 `gh-ci`，管理员提前建的**规则**，不含 secret）vs **OIDC JWT**（GitHub 在 CI 运行时现签、带真实 repo/branch 值）。运行时 Teleport 从 OIDC JWT 解析 repo/ref，跟 join token 里的 `allow` 规则比对，命中才签证。

```yaml
# ① 一次性（管理员）：github join token —— 核心是 allow 规则"只接受这个 repo/分支签发的 OIDC token"
kind: token
version: v2
metadata: { name: gh-ci }
spec:
  roles: [Bot]
  bot_name: ci-bot
  join_method: github
  github:
    allow:
      - repository: my-org/my-repo      # └ 只认这个 repo
        ref: refs/heads/main            # └ 且这条分支签发的 OIDC token
```
```bash
# ① 一次性（管理员）：建 bot 身份 + 创建上面那条 token 规则
tctl bots add ci-bot --roles=access
tctl create -f gh-token.yaml
#    └ token 资源不含 secret，只是规则；运行时 Teleport 从 GitHub 签的 OIDC JWT 解析 repo/ref，跟 allow 比对

# ② 运行态（CI / tbot）：tbot 用 GitHub Actions 现签的 OIDC token 走 github join，换短期证书落盘
tbot start \
  --destination-dir=/opt/machine-id \
  --token=gh-ci \
  --join-method=github \
  --auth-server=teleport.example.com:443
#    └ Auth 用 GitHub 公钥验签 + 核对 repo/ref 命中 allow → 签短期证书写 /opt/machine-id，供 tsh/kubectl/db 访问 Teleport 资源用
#    └ --destination-dir 为简化示意；v17 推荐用 tbot.yaml 的 outputs 配置（以官方 tbot ref 为准，未实测）

# ③ 变更态（自动）：tbot 默认每 20m 续期、credential_ttl 默认 1h，无需人工
```

### 一句话本质
tbot = 机器身份的短期证书续期泵，靠平台原生 join 免长期 secret。

---

## §3 Workload Identity / SPIFFE SVID（edition: Community；Federation/TPM = Enterprise）

### 解决什么问题
工作负载之间（service-to-service）、工作负载对云 API，需要可验证的短期身份做 mTLS / 鉴权，而不是共享长期 secret。Teleport Workload Identity 在 Machine ID 之上长出 **SPIFFE** 兼容的身份层。

### 核心模型 / 原理
- **SPIFFE ID** —— URI 形态的身份（如 `spiffe://example.com/ci/job`）。
- **SVID** —— SPIFFE Verifiable Identity Document，两种形态：**X.509-SVID**（做 mTLS）和 **JWT-SVID**（调第三方/云 API）。由 Teleport 根 CA 签发，短寿命、自动续期（[workload-identity intro](https://goteleport.com/docs/machine-workload-identity/workload-identity/introduction/)）。
- **WorkloadIdentity 资源** + **Workload Attestation** —— tbot 暴露 SPIFFE **Workload API**（gRPC），工作负载直接请求自己的 SVID；attestation 按 Linux UID/GID 或 K8s Pod 限定"谁能拿哪个 SVID"，免 bootstrap secret。

**处理流程（K8s 工作负载拿 SVID）**：
1. tbot 以 service 模式跑 `workload-identity-api`，暴露 SPIFFE Workload API（Unix socket / gRPC）。
2. 同 Pod/同节点工作负载连该 API 请求 SVID。
3. tbot 按 attestation（K8s pod 元数据 / UID）核验调用方 → 向 Auth Service 请求签发 → 返回 X.509-SVID + 信任 bundle。
4. 工作负载用 X.509-SVID 与对端做 mTLS，或用 JWT-SVID 调云 API；SVID 短寿命，tbot 持续续期。

### 核心能力清单
- X.509-SVID（mTLS）+ JWT-SVID（API 鉴权）。
- SPIFFE Workload API（免落盘直接 gRPC 取）或落盘 / K8s Secret。
- Workload Attestation（UID/GID、K8s pod）。
- Sigstore 集成（供应链场景，[blog](https://goteleport.com/blog/workload-identity-meets-supply-chain-security/)，细节未深挖）。

### §3.1 Federation / TPM Join（edition: Enterprise）
- **SPIFFE Federation**（跨信任域互信）**需 Enterprise license**（[federation](https://goteleport.com/docs/machine-workload-identity/workload-identity/federation/)）。
- **TPM join**（非云工作负载用 TPM 做服务端 attestation）规划为 Enterprise-only（[workload-identity blog](https://goteleport.com/blog/workload-identity/)，版本归属未确认）。

### 最小命令示例（基于文档）
**场景 A：K8s 工作负载经 SPIFFE Workload API 拿 X.509-SVID 做 mTLS**
```yaml
# ① 一次性（管理员）：声明 WorkloadIdentity——谁能拿、SPIFFE ID 模板
kind: workload_identity
version: v1
metadata: { name: ci-job }
spec:
  spiffe:
    id: /k8s/{{ workload.kubernetes.namespace }}/{{ workload.kubernetes.service_account }}   # └ 模板化 SPIFFE ID（官方文档示例属性，未实测）
```
```bash
# ② 一次性部署（运维）：tbot 以 DaemonSet 跑 workload-identity-api service，暴露 SPIFFE Workload API（Unix socket）
tbot start -c tbot.yaml
#    └ tbot.yaml 内声明 workload-identity-api service；K8s 里需 hostPID + 查 pod 的 RBAC 做 attestation
# ③ 运行态（工作负载）：同节点 Pod 连 Workload API 取自己的 SVID（无需落盘 secret）
#    └ tbot 按 K8s pod attestation 核验调用方 → 向 Auth 请求签发 X.509-SVID + 信任 bundle → 用于 mTLS
```

### 一句话本质
Workload Identity = Teleport 在 Machine ID 上长出的 SPIFFE 短期身份层（X.509-SVID + JWT）。

---

## §4 Join Methods（edition: Community；部分委派依平台）

### 解决什么问题
机器/CI 加入 Teleport 集群时如何**免长期 secret** 地证明"我是谁"。Join method 决定证明方式，是 Machine ID 零长期 secret 的根基。

### 核心模型 / 原理
join token 声明授予哪个 bot + 需要哪种 proof。两类：
- **委派 join（推荐）** —— 用运行平台**原生签发的身份**做 proof：`github` / `gitlab` / `circleci` / `spacelift` / `terraform_cloud`（CI 平台）、`kubernetes`（SA JWT，走 TokenReview）、`iam`(AWS) / `gcp` / `azure` / `ec2`（云）、`tpm`（硬件，**Enterprise**，见 §3.1）。无需任何长期 secret。
- **token join** —— 预共享 token（有长期 secret 风险，适合无委派可用时）。

主要支持列表（非穷尽，以官方 join-methods ref 为准）：`azure, azure_devops, bitbucket, bound_keypair, circleci, ec2, env0, gcp, github, gitlab, iam, kubernetes, oracle, spacelift, terraform_cloud, token, tpm`（[join-methods](https://goteleport.com/docs/reference/deployment/join-methods/)）。

### 核心能力清单
- CI 平台委派：GitHub Actions / GitLab CI / CircleCI / Spacelift / Terraform Cloud。
- 云委派：AWS IAM / EC2、GCP、Azure。
- K8s：SA JWT → TokenReview。
- 硬件：TPM（**Enterprise**，见 §3.1）。

### 最小命令示例（基于文档，[gitlab join](https://goteleport.com/docs/reference/machine-id/gitlab/)）
**场景 A：GitLab CI 委派 join token（管理员一次性 apply）**
```yaml
# ① 一次性（管理员）：定义一个 GitLab CI 委派 join token
kind: token
version: v2
metadata: { name: gitlab-bot }
spec:
  roles: [Bot]
  bot_name: ci-bot
  join_method: gitlab
  gitlab:
    allow:
      - project_path: my-group/my-project    # └ 只有该 project + 分支的 CI OIDC 才能用此 token join
        ref: refs/heads/main
```
```bash
# ② 一次性（管理员）：创建该 token 资源
tctl create -f gitlab-token.yaml
#    └ 之后 CI 里 tbot --join-method=gitlab --token=gitlab-bot 即可零长期 secret 入会（§2）
```

### 一句话本质
Join method = 机器用"运行平台的原生身份"换 Teleport 信任，免长期 secret 入会。

---

## §5 RBAC 角色（edition: Community 基础；细粒度治理偏 Enterprise）

### 解决什么问题
控制"谁能访问哪些资源、能做什么、能否请求升权"。证书里编码的 roles/traits 是鉴权的依据。

### 核心模型 / 原理
角色 = `allow` / `deny` 规则集合，作用在资源 label 选择器 + verbs 上；**deny 贪婪匹配、优先于 allow**。角色可模板化：`internal` trait（本地 logins/kubernetes_groups 等）+ `external` trait（来自 SSO：OIDC claims / SAML assertions）。`where` 字段按 trait 做条件过滤（[roles ref](https://goteleport.com/docs/reference/access-controls/roles/)）。

> edition 边界：基础 RBAC 在 Community 可用；OSS 用户被赋予近似只读的内建角色，**部分高级 RBAC / 治理特性（如 Access Requests）是 Enterprise**（[RBAC OSS RFD](https://github.com/gravitational/teleport/blob/master/rfd/0007-rbac-oss.md)，OSS/Enterprise 切分细节随版本变化，未逐条确认）。

### 核心能力清单
- allow/deny + label 选择器 + verbs。
- 角色模板 + SSO trait 映射。
- `request.roles` 声明本角色可请求哪些升权角色（喂给 §8 JIT）。

### 最小命令示例（基于文档）
**场景 A：定义一个可 JIT 申请升权的 dev 角色（管理员一次性）**
```yaml
# ① 一次性（管理员）：tctl create -f role.yaml
kind: role
version: v7
metadata: { name: dev }
spec:
  allow:
    logins: ['{{internal.logins}}']          # └ 模板：从用户 trait 注入允许的系统登录名
    node_labels: { env: ['dev'] }            # └ 只能访问带 env=dev 标签的节点
    request:
      roles: ['prod-access']                 # └ 该角色可 JIT 申请升到 prod-access（§8）
  deny:
    node_labels: { env: ['prod'] }           # └ deny 优先：显式禁 prod
```

### 一句话本质
Teleport RBAC = 证书里编码 roles/traits，allow/deny + 模板按身份放行，deny 优先。

---

## §6 Application Access（Identity-Aware Proxy：HTTP 代理 + JWT 身份注入）（edition: Community；对接上游 IdP 偏 Enterprise）

### 解决什么问题
内部 Web 应用（Grafana、Kibana、自研后台）通常没有统一身份层——要么每个应用各自接一遍 SSO/OIDC（逐个改造），要么裸奔。Application Access 让应用**免改造**地获得统一身份层，本质是给应用前置一个 **Identity-Aware Proxy（IAP）**。**注意：这是认证 / 身份层能力，不是 secretless**——secretless 是"藏后端凭据、消费者不持有"，这里是"给应用发一个'调用方是谁'的身份断言"，方向相反。

### 核心模型 / 原理
做 IAP 的两件标准动作：
- **① 认证卸载（authentication offload）**：用户认证集中在 Proxy/Auth 做一次——**复用 Teleport 集群级、跨协议通用的那套认证**（SSH/K8s/DB/App 共享，不是每个应用各自接 IdP），认证可 federate 上游 IdP（SAML/OIDC：Okta/Entra/Google/GitHub）。应用**不再自己实现 OIDC 登录流程**。
- **② 身份传播（identity propagation）**：Proxy 反代 HTTP 流量，把认证后的身份以 **Teleport 签名的 JWT** 注入请求头 `teleport-jwt-assertion`（或用 `{{internal.jwt}}` 模板写进任意自定义头，如 `Authorization: Bearer {{internal.jwt}}`）；应用读该头即知调用方身份（roles/traits），用 Teleport 的 `/.well-known/jwks.json` 验签（[JWT app access](https://goteleport.com/docs/enroll-resources/application-access/jwt/introduction/)）。

**OIDC 角色映射**：对应用而言 **Teleport 充当 IdP**——那张 JWT 等价于一张 Teleport 颁发的 OIDC ID Token，应用是只验签读 claims 的 Relying Party；而 Teleport 对上游真 IdP 又是 RP，即夹在中间的 **token broker**。

**业界同类 / 与 Dex 的区别**：这层等同 **oauth2-proxy / Pomerium / Cloudflare Access / Google Cloud IAP**（代理认证 + 注入身份头、应用免改造）。**≠ Dex**：Dex 是纯 OIDC IdP（只发 token、不在流量路径上），用 Dex 应用**仍要自己实现 OIDC 客户端**；IAP 坐在流量路径上做认证卸载，应用**零 OIDC 代码**。典型组合是 Dex(IdP) + oauth2-proxy(IAP)；Teleport 把这两个角色合在一身。

> **edition**：HTTP 反代 + JWT 注入（IAP 基础）在 Community 可用；但**对接 SAML/OIDC 上游 IdP（Okta/Entra/Google）属 Enterprise/Cloud**，仅 GitHub SSO 是 OSS。

**与 Connectors 易混点**：Teleport 注入的是**它自己签发的身份断言 JWT**（告诉应用"这是谁"），**不是**后端工具的真凭据。这是 identity passthrough，不是 credential injection。

### §6.1 Git 命令代理（edition: Enterprise ≥17.2 + GitHub Enterprise Cloud）

> **与 §6 的关系（重要）**：§6.1 与 §6 同属"应用层 / SaaS 访问"大伞，但**机制不是一回事**——§6 是 IAP / **JWT 身份注入**（identity passthrough）；§6.1 走的是 §1 SSH 那套"**Teleport 当 SSH CA 签短期证书、目标(GitHub)信任该 CA**"的**证书 / 凭据模型**。放在 §6 下只因都属"应用层服务接入"，别把它当成 JWT 注入的子情形。

- git 操作配置走 Teleport，Teleport 用**短期 SSH 证书**（其 CA 签）冒充用户 GitHub 身份对 GitHub 鉴权；GitHub org 把 Teleport CA 注册为可信 SSH CA。每条 git 命令写审计（[github-integration](https://goteleport.com/docs/zero-trust-access/management/guides/github-integration/)）。
- 取用户 GitHub 身份：`tsh` 走 GitHub OAuth flow（或复用 GitHub SSO）。机器侧由 tbot 续短证书。
- **限定**：Enterprise v17.2+、仅 GitHub Enterprise Cloud（self-hosted GHE Server 当前不支持）。

### 核心能力清单
- HTTP 反代 + JWT 身份断言注入。
- header 重写 / JWKS 验签。
- Git over SSH 短证书代理（Enterprise，§6.1）。

### 最小命令示例（基于文档，[grafana jwt](https://goteleport.com/docs/enroll-resources/application-access/jwt/grafana/)）
**场景 A：把内部 Grafana 反代到 Proxy 并注入身份断言 JWT**
```yaml
# ① 一次性（运维）：app_service 注册应用，按 header 注入 JWT 身份断言（未实测）
app_service:
  enabled: true
  apps:
    - name: grafana
      uri: http://localhost:3000                       # └ 真实后端，仅 Proxy 可达
      rewrite:
        headers:
          - 'Authorization: Bearer {{internal.jwt}}'   # └ 注入 Teleport 签名 JWT（身份断言，非后端真凭据）
```
```bash
# ② 运行态（开发者）：经 Proxy 访问该应用
tsh apps login grafana
#    └ Proxy 反代请求并补 teleport-jwt-assertion 头，Grafana 用 /.well-known/jwks.json 验签
```

### 一句话本质
Application Access = 给应用前置一个 **IAP（统一认证代理）**：集中认证（可 federate 上游 IdP）+ 把身份注入成 JWT 写进 HTTP 请求，应用免改造消费——是身份层能力，非 secretless。

---

## §7 审计日志 + 会话录制（edition: Community；外部存储/部分导出偏 Enterprise）

### 解决什么问题
留存"谁、何时、对哪个资源、做了什么"的结构化记录，并能回放交互式会话，满足合规与事后复盘。

### 核心模型 / 原理
两层：**结构化审计事件**（登录、命令、API 调用、git 命令等，带 actor / IP / 时间 / session ID）+ **会话录制**（SSH/K8s/Desktop 交互式会话可回放）。事件可流式导出到 SIEM（Splunk / Elastic / 等）。默认保留期 **1 年**，可用 `retention_period` 覆盖（[audit ref](https://goteleport.com/docs/reference/deployment/monitoring/audit/)）。

> edition 边界：基础审计 + 会话录制 Community 即有；**External Audit Storage**（Athena/S3 长存、Parquet）等偏 Cloud/Enterprise（[external-audit-storage](https://goteleport.com/docs/zero-trust-access/management/external-audit-storage/)）。

### 核心能力清单
- 结构化事件（含 §6.1 git 命令、§8 access request 事件）。
- 交互式会话录制 + 回放。
- 导出 Splunk / Elastic Stack 等。
- 后端：File / DynamoDB / Firestore / Athena。

### 最小命令示例（基于文档）
**场景 A：查看与回放会话录制（审计员运行态）**
```bash
# ① 运行态（审计员/运维）：列出会话录制
tsh recordings ls
# ② 运行态（审计员/运维）：回放某次会话
tsh play <session-id>
#    └ 交互式 SSH/K8s 会话可逐帧回放；结构化事件可流式导出 SIEM（见 export-audit-events/splunk 文档）
```

### 一句话本质
审计 = 结构化事件 + 会话录像，统一可导 SIEM，默认存 1 年。

---

## §8 Access Requests（JIT 审批）（edition: 分版 —— Role Request 有 Community CLI-only preview；完整工作流 Enterprise / Identity Governance）

### 解决什么问题
实现**零常驻权限（Zero Standing Privilege）**：用户平时不预分配高权限，需要时临时申请，经审批后获得**有时限**的升权，到期自动回收。

### edition 边界（先读）
- **Community Edition**：**Role Access Request 以 CLI-only preview 形式提供** —— `tsh request create`、`tsh login --request-roles` 发起，管理员经 `tctl` 手动审批；无审批规则 / 阈值、无 Resource Request、无可搜索 Web UI、无插件（[oss-role-requests](https://goteleport.com/docs/identity-governance/access-requests/oss-role-requests/)）。
- **Enterprise（Identity Governance）**：完整工作流 —— 审批*规则* / approver 角色、dual-authorization 阈值、**Resource** Access Request、可搜索 Web UI、Slack / PagerDuty / Mattermost / Jira 插件。

### 核心抽象
两类请求把"取得权限"拦成一张待审 Request：
- **Role Access Request** —— 直接申请某个升权角色（用户知道要哪个 role）。
- **Resource Access Request** —— 申请访问某个具体资源，Teleport 反推该给哪些 role（用户不需懂 RBAC）。

门控挂在**"取得权限"这一刻**（升权证书签发前），**不是 per-request / 每次使用都过审**——一旦升权证书签发，在其 TTL 内的后续访问不再逐次审批。

### 处理流程（请求 → 审批 → 升权证书，状态机）
1. 角色里用 `allow.request.roles`（或 resource 维度）声明"本角色可申请升到哪些角色 / 哪些资源"（[role-requests](https://goteleport.com/docs/identity-governance/access-requests/role-requests/)）。
2. 用户 `tsh request create`（或 Web UI）发起请求，附 reason → 状态 **PENDING**。
3. 审批人 review：可配**审批阈值**（如 dual authorization：**两名审批人**才放行），可经 Slack / PagerDuty / Mattermost 等插件通知与审批（[access-requests](https://goteleport.com/docs/identity-governance/access-requests/)）。也可按 role/context 配置**自动审批**。
4. **批准** → Teleport **重新签发一张带升权 role 的短期证书**，TTL = 配置的访问时长；到期自动回收（无需手动降权）。**拒绝** → 状态 DENIED，证书不变，无升权。

**关键抽象**：JIT 审批的产物是**一张有时限的升权证书**，不是"一次性放行某个调用"。撤销靠证书过期 / 主动撤销，而非每请求重新中央授权。

### 核心能力清单
- Role Access Request（Community CLI-only preview + Enterprise）/ **Resource** Access Request（Enterprise only）。
- 审批*规则* / approver 角色、审批阈值（含 dual authorization）+ 自动审批规则（**Enterprise**；Community 仅 `tctl` 手动审批）。
- 可搜索 Web UI + Slack / PagerDuty / Mattermost / Jira 等审批集成（**Enterprise**）。
- 时限升权 + 到期自动回收 + 审计。

### 最小命令示例（基于文档，[access-requests](https://goteleport.com/docs/identity-governance/access-requests/)）
**场景 A：临时申请升权角色，经审批后领时限升权证书**
```bash
# ① 运行态（申请者）：发起升权申请并附理由 → 状态 PENDING
tsh request create --roles=prod-access --reason="incident-1234"
# ② 运行态（审批人）：review 批准（Enterprise 可配双人/插件审批；Community 用 tctl 手动批）
tsh request review --approve <request-id>
# ③ 运行态（申请者）：领取带 prod-access 的短期升权证书
tsh login --request-id=<request-id>
#    └ 门控挂在"签升权证书"这一刻；证书 TTL 到期自动回落，无需手动降权
```

### 一句话本质
JIT 审批 = 申请→审批后重签一张"有时限的升权证书"，零常驻权限（Role Request 有 Community CLI-only preview，完整工作流 Enterprise）。

---

## OSS（Community Edition）能力组合回顾

**Community Edition 单独能交付什么**：identity-aware Proxy + 内置 CA（§1）、Machine ID / tbot（§2）、Workload Identity / SPIFFE SVID 基础形态（§3，不含 Federation/TPM）、全部 Join Methods（§4）、基础 RBAC（§5）、Application Access + JWT 注入（§6，不含 Git proxy）、审计 + 会话录制基础形态（§7，外部审计存储偏 Cloud/Enterprise）、Role Access Request 的 **CLI-only preview**（§8）。即"短期证书取代长期密钥 + 机器/工作负载零长期 secret + 基础审计"这条主链 OSS 即可跑通。

**需要 Enterprise 才有的**：Access Requests 完整审批工作流（审批规则/阈值/Resource Request/Web UI/插件，§8）、Workload Identity Federation + TPM join（§3.1）、Git 命令代理（§6.1）、Identity Security / Device Trust 等治理面（§10）。**门槛额外注意**：官方编译的 Community 二进制从 v16 起是商用 Community license（<100 员工且 <$10MM 营收、禁 resale/embed，§9）。

---

## §9 许可 / Fork / air-gap 边界（关键）

### 许可证模型（load-bearing）
- **core 源码 = AGPLv3**：2023-12-01 起从 Apache 2.0 切到 AGPLv3，覆盖 `github.com/gravitational/teleport` core 仓库源码。**自己 clone + 编译 = 受 AGPLv3 约束**（[oss-agpl-v3](https://goteleport.com/blog/teleport-oss-switches-to-agpl-v3/)）。
- **仍 Apache 2.0**：OSS 文档、client libraries、官方此前编译的 OSS 二进制（v16 前）。
- **官方编译的 Community 二进制/镜像/AMI = 商用 Community license（v16 起，2024-06）**，带明确门槛（[community-license](https://goteleport.com/blog/teleport-community-license/)）：
  - *"Individuals are free to use Teleport Community Edition for personal and hobby use with no restrictions."*
  - *"Companies may use Teleport Community Edition on the condition they have less than 100 employees and less than $10MM in annual revenue (AR)."*
  - ***"Companies cannot resell or embed Teleport Community Edition in their products or services."*** ← **禁 resale / 禁 embed**
  - *"Companies larger than 100 employees or more than $10MM AR need to contact our sales team…"*
- **Enterprise** = 商用付费，含 Identity Governance（Access Requests §8）、Identity Security、Workload Identity Federation/TPM（§3.1）、Git proxy（§6.1）等。

### air-gap 友好度
- 自托管可离线部署（self-hosted 文档支持 air-gap），但 Enterprise 功能需 license。具体离线 license 机制未在本轮深挖（未确认）。

### 没有 Fork 上游（与 Vault→OpenBao 不同）
Teleport 无知名社区 fork 接管 OSS（截至 2026-06，未确认有活跃 fork）。AGPLv3 + 商用 Community license 组合本身就抑制了 ISV 二次分发。

---

## §10 作用域外能力（一句话带过）

> 以下是 Teleport 主营的主机访问族。SSH / K8s / Database / Web 的**访问流程 + 命令**已在 §1 多协议小节示范；此处仅补定位，**深度内部机制不展开**：
- **SSH Access**：短期 SSH 证书 + 会话录制取代静态 SSH key（流程见 §1 场景 A）。
- **Kubernetes Access**：identity-aware 代理 K8s API，impersonation + RBAC + 审计（流程见 §1 场景 B）。
- **Database Access**：代理 SQL/NoSQL，现签短期凭据取代 DB 密码；含自动建/销库用户等深度机制（流程见 §1 场景 C）。
- **Windows Desktop Access**：无密码 RDP + 录屏（仅列存在性，未在 §1 示范）。
- **Identity Security / Device Trust / MCP Access**：Enterprise 治理与新兴 AI 场景，未深挖。

---

## 附：fact-check 待核（2026-06-16，落版后派 Agent 核）

- §2 bot 最大 TTL 7 天的**版本归属** — 已核：[PR #53893] backport 至 v17。
- §3.1 TPM join 的 Enterprise-only 与**起始版本** — 未确认。
- §5 OSS vs Enterprise RBAC 的逐条切分（随版本变化）— 未逐条确认。
- §9 air-gap offline license 机制 — 未深挖。
- §3 `workload_identity` 资源字段名 / 模板语法 — 以官方 configuration ref 为准，未实测。

**相关文档**：`connectors-vs-teleport.md`（与 Connectors 的对比 + 边界 + roadmap 启发）。
