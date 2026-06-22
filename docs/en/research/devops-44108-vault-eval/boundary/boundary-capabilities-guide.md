# HashiCorp Boundary 能力调研指南（聚焦 session-access proxy / brokered·injected 凭据 / Vault 集成 / 审计录制）

> **状态**：已完成（持续可追加）
> **覆盖版本**：Boundary 0.21.x（仍 0.x；`>= 0.14.0` 起 BUSL-1.1，`<= 0.13.1` 为 MPL-2.0）（截至 2026-06-18）
> **基于源**：官方文档 `developer.hashicorp.com/boundary` + 官方 license/edition 页（逐条带 URL）
> **edition 范围**：Community（OSS 自托管，免费）+ Enterprise（自托管付费）+ HCP Boundary（HashiCorp 托管）
> **作用域（重要）**：本指南**只深挖** Connectors 相关面 —— controller/worker 访问代理架构、**brokered vs injected 凭据**、Vault 凭据库（动态凭据来源）、Kubernetes 目标、RBAC/会话授权、审计与会话录制。人→主机访问（SSH/RDP/DB/TCP）在 §1 给出**统一访问流程 + 最小使用场景**示范（体现"一个代理管多协议"）；但每协议主机访问的深度内部机制不展开。
> **不覆盖**：价格数字（以官网 pricing 为准）；与 Connectors / ACP 的对比（见 `connectors-vs-boundary.md`）。
> **未实测，基于文档**：本指南未在集群实跑 demo，命令/YAML 均"未实测，基于官方文档"。

本文档**只讲 Boundary 自身**：它有哪些能力、解决什么问题、基本原理、哪些收费。

---

## §0 心智模型 + 能力地图速览

**心智模型（5 行）**：Boundary 是一个**身份驱动的「人→主机」会话访问代理**，控制面 / 数据面分离：**Controller**（控制面）是 API + RBAC + 会话授权 + Postgres 状态库，给认证过的**人**（OIDC/password/LDAP 登录）做鉴权并签发**一次性 session authorization token**；**Worker**（数据面）按 controller 指派为这次会话建代理隧道、把客户端流量代理到目标主机。凭据有两种交付方式：**brokered**（凭据回交给客户端，用户自己拿去认证目标 —— OSS 可用）与 **injected**（worker 代用户认证目标，用户**永不见凭据** —— Enterprise/HCP 限定）。安全模型核心是**"短期 session + 按目标预配的最小权限 + （付费）会话录制"**，而**不是**"每次请求都过一次中央审批"。

**简化架构（运行时数据流）**：

```
   +---------+---------+                       +---------+---------+
   |   boundary CLI    |  (1) authenticate     |    Controller     |
   |   human / desktop |  ------------------>  |  API + RBAC + DB  |
   +---------+---------+  <-- (2) session ---  |   (control plane) |
             |               authz token       +---------+---------+
             |                                       ^       |
             | (3) connect via token                 |       | (4) assign worker
             v                                       (6) audit|     + creds
   +---------+---------+                       +---------+----v----+               +-------------------+
   |   Ingress Worker  |  (5) proxy / tunnel   |   Egress Worker   |  (7) connect  |    Real Target    |
   |   (data plane)    | <-------------------> |   (data plane)    | -- auth ----> |  SSH/DB/K8s/RDP   |
   +-------------------+   multi-hop chain     +---------+---------+  <-- data --> +-------------------+
                                                         ^
                                                         | (4b) fetch credential
                                               +---------+---------+
                                               |  Credential Store |
                                               |  static / Vault   |
                                               +-------------------+
```

- **(1)(2) 控制面（认证 + 授权）**：人用 `boundary authenticate`（OIDC / password / LDAP）登录 **Controller**；Controller 做 RBAC 鉴权，对目标的 `authorize-session` 动作签发**一次性 session authorization token**（[domain-model: session](https://developer.hashicorp.com/boundary/docs/concepts/domain-model)）。
- **(3) 持 token 发起会话**：客户端拿该 token 调 `boundary connect`，把会话接到 **Worker**——这是"出示会话授权"，不是再登录一次。
- **(4) 控制面指派 + 取凭据**：Controller 把这次代理会话**指派给某个活跃 Worker 节点**（[recommended-architecture](https://developer.hashicorp.com/boundary/docs/install-boundary/architecture/recommended-architecture)）；若目标绑定了 credential source，则从 **Credential Store** 取凭据（static 或经 Vault 现取）。
- **(5) 数据面（Worker 代理隧道）**：**Ingress Worker** 接客户端，**Egress Worker** 连目标；二者可链成 multi-hop（egress 反向拨回 ingress/中间 worker），目标侧可待在私网（[multi-hop](https://developer.hashicorp.com/boundary/docs/workers/multi-hop)）。
- **(6) 审计 / 录制（右竖线）**：会话事件回 Controller；**会话录制（BSR）写 S3 兼容存储**——**Enterprise / HCP Plus 限定**（[session-recording](https://developer.hashicorp.com/boundary/docs/session-recording)）。
- **(7) Worker → Real Target**：**brokered** 时凭据已回交客户端、客户端自己认证目标；**injected** 时 **worker 用凭据代客户端完成目标认证**，客户端永不见凭据（[credential-management](https://developer.hashicorp.com/boundary/docs/concepts/credential-management)）。
- **✦ 信任边界**：真凭据（injected 时）只在 **Credential Store ↔ Worker** 之间；Controller 持会话状态与 Vault token，但**不在数据路径上**。

**许可 / edition / air-gap（先记这条，§9 详述）**：Boundary 源码 `<= 0.13.1` 为 **MPL-2.0**；**`>= 0.14.0` 起改为 BUSL-1.1**（Business Source License，4 年后转 MPL-2.0），BUSL 禁止"提供与 HashiCorp 商业产品竞争的生产用途"——对发行竞品的 ISV **不可内嵌**（[HashiCorp 许可变更公告](https://discuss.hashicorp.com/t/hashicorp-projects-changing-license-to-business-source-license-v1-1/57106)）。三 edition：**Community**（OSS、免费、自托管，仅 brokered 凭据、无 injection、无会话录制）/ **Enterprise**（自托管付费、比 Community 多 injection/录制/Transparent Sessions 等付费能力、需 license key）/ **HCP Boundary**（HashiCorp 托管）（[enterprise overview](https://developer.hashicorp.com/boundary/docs/enterprise)、[licensing](https://developer.hashicorp.com/boundary/docs/enterprise/licensing)）。

### 能力地图速览（30 秒看全貌）

一行 = 一章。先看这里决定往下读哪节。

**一、Community Edition（OSS / 自托管基础）能力**

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 |
|---|---|---|---|---|---|
| §1 | Controller/Worker 会话访问代理 | 统一身份化的人→主机访问入口 | Controller 鉴权签会话 token → Worker 代理隧道到目标 | 控制面/数据面分离、multi-hop 穿私网 | 工程师经代理 SSH 一台私网主机 |
| §2 | 身份与认证（auth method） | 人用企业 IdP 登录、免散落账号 | OIDC / LDAP / password → account → user/group | 复用 OIDC IdP、managed group 映射 | 用 Okta 登录 Boundary |
| §3 | Scope + RBAC 授权 | 谁能对哪个目标做什么 | global/org/project 三层 scope + role(grant) | 三层 scope + 组合式 grant | 项目管理员只授本项目目标 |
| §4 | Targets + Host Catalog | 把"可访问的服务"建模、可发现 | target 绑 host source；static / 动态(plugin) host catalog | 动态主机目录自动发现云主机 | 按云标签自动发现 SSH 主机 |
| §5 | **Brokered 凭据**（含 Vault 凭据库） | 客户端免预存长期密码 | 会话授权时从 Credential Store / Vault **现取**凭据回交客户端 | Vault 动态凭据现取、会话结束撤 lease | 连 DB 时 Vault 现造一次性账号 |
| §7 | 审计事件 | 谁何时连了什么 | 结构化会话/连接事件 | 会话级审计 | 合规留存会话发起记录 |

**二、付费（Enterprise / HCP）能力**

| § | 能力 | 解决什么问题 | 大致逻辑 | edition |
|---|---|---|---|---|
| §6 | **Injected 凭据**（含 SSH 证书注入） | 客户端**永不见**凭据的 secretless 体验 | worker 用凭据代客户端认证目标（SSH cert / user-pass / pubkey） | **Enterprise / HCP** |
| §7.1 | 会话录制（BSR）| 录制 + 回放会话内容供合规 | worker 录会话写 S3 兼容存储，BSR 文件格式 | **Enterprise / HCP Plus** |
| §8 | Transparent Sessions | 经 Client Agent 透明代理、无需手动 connect | Client Agent 拦截目标域名透明接管 | **Enterprise / HCP** |

> 人→主机访问族（SSH / RDP / Database / Kubernetes / TCP 通用代理）是 Boundary 主营面；§1 给统一访问流程 + 最小使用场景，K8s 单列 §4.1 画数据流，其余协议深度机制不展开。

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 理解 Boundary 整体"控制面+数据面代理"是怎么回事 | §1 |
| 让人用企业 IdP（OIDC/LDAP）登录 | §2 |
| 控制谁能访问哪些目标 | §3 |
| 自动发现云上主机当作访问目标 | §4 |
| 让客户端连目标时不预存密码（凭据回交客户端） | §5（brokered，OSS） |
| 经 Vault 现造一次性 DB/SSH 凭据、会话结束自动撤销 | §5（Vault 凭据库，OSS 即可 broker） |
| 让客户端**永不见**凭据（worker 代认证、SSH 证书注入） | §6（injection，**Enterprise/HCP**） |
| 经 Boundary 用 kubectl 访问 K8s 集群 | §4.1 |
| 录制并回放会话内容 | §7.1（**Enterprise/HCP Plus**） |
| 无需手动 `boundary connect` 透明接管目标流量 | §8（**Enterprise/HCP**） |

---

## §1 Controller/Worker 会话访问代理（edition: Community / Enterprise / HCP）

### 解决什么问题
传统人→主机访问散落着堡垒机、VPN、长期 SSH key、共享 DB 密码，无统一身份、无统一审计、目标侧要开入站端口。Boundary 用"Controller 鉴权 + Worker 代理"把"认证 → 授权 → 代理到目标 → 审计"收成一条链，目标侧可待私网零入站。

### 核心模型 / 原理
三个核心角色（[recommended-architecture](https://developer.hashicorp.com/boundary/docs/install-boundary/architecture/recommended-architecture)）：
- **Controller（控制面）** —— API server + RBAC 引擎 + 会话授权 + 状态库（Postgres）+ KMS（封装根密钥）。人登录、授权、目标/凭据配置都在这里；它**指派**会话给 worker，但**不在数据路径上转流量**。
- **Worker（数据面）** —— 代理进程，按 controller 指派为单次会话建隧道、把客户端流量转给目标；可作 **ingress**（客户端可达）/ **egress**（目标可达）/ 中间跳，链成 **multi-hop** 让 egress 反向拨回 ingress，目标侧零入站端口（[multi-hop](https://developer.hashicorp.com/boundary/docs/workers/multi-hop)）。
- **Session** —— 一组"用户↔目标"的相关连接；可携带凭据，定义该会话内的权限与时限（[domain-model](https://developer.hashicorp.com/boundary/docs/concepts/domain-model)）。

**处理流程（`boundary connect ssh -target-id=...` 全链路）**：
1. **`boundary authenticate`（发会话能力的前提）**：人向 Controller 用 OIDC/password/LDAP 认证，拿到一张 Boundary auth token（身份令牌，存本地）。
2. **`authorize-session`（控制面授权，签一次性会话 token）**：客户端对某 target 请求 `authorize-session`；Controller 做 RBAC 鉴权（该 principal 能否 connect 该 target）→ 选 host → 若目标绑 credential source 则取凭据 → 生成 **session authorization token** 并**指派一个活跃 worker**（[hcp-manage-sessions](https://developer.hashicorp.com/boundary/tutorials/hcp-administration/hcp-manage-sessions)）。
3. **`connect`（数据面）**：客户端拿会话 token 连指派的 **ingress worker**；worker 经隧道（必要时多跳）把流量送到目标。
4. **目标认证**：**brokered** → 凭据已回交客户端、客户端自己认证目标（§5）；**injected** → worker 用凭据代客户端认证目标，客户端永不见凭据（§6）。

> 一句话：authenticate 拿身份令牌 → authorize-session 经 RBAC 换一次性会话 token + 指派 worker → connect 经 worker 隧道到目标。

**关键边界**：Boundary 代理的是"**人**对**主机/服务**的访问"，它本身**不是 CI/工作负载的凭据使用层**——没有"给 Pod 注入工具配置 / 免 imagePullSecret 拉镜像"这类机制（见 §1 边界 + `connectors-vs-boundary.md`）。会话授权一旦签出，在其时限内不再逐请求过中央鉴权。

### 核心能力清单
- 多协议代理：SSH、RDP、Database（pg/mysql/mssql…）、Kubernetes API、通用 TCP。
- 控制面/数据面分离；worker 可 ingress/egress/multi-hop、目标零入站端口。
- 一次性 session authorization token + 会话时限（`session_max_seconds`）。
- 连接经 worker 代理；连接事件写审计（§7）。

### 最小使用场景（未实测，基于文档；[get-started](https://developer.hashicorp.com/boundary/docs/getting-started)）

**场景 A：admin 建好一个 SSH 目标，end user 经 worker 访问私网主机**
```bash
# ① 一次性配置（admin）：建 scope 层级 org -> project
boundary scopes create -scope-id=global   -name="acme"     -skip-admin-role-creation -skip-default-role-creation   # org
boundary scopes create -scope-id=<org-id> -name="webapp"   -skip-admin-role-creation -skip-default-role-creation   # project
#    └ 资源都挂在 scope 下；project 是 target/host/cred-store 的归属层

# ② 一次性配置（admin）：建 static host catalog + host + host-set
boundary host-catalogs create static -scope-id=<project-id> -name="onprem"
boundary hosts create static -host-catalog-id=<hc-id> -address=10.0.0.21 -name="web-1"
boundary host-sets create static -host-catalog-id=<hc-id> -name="web"
boundary host-sets add-hosts -id=<hs-id> -host=<host-id>
#    └ host = 一个可达网络地址；host-set = 等价主机集合（访问控制单位）

# ③ 一次性配置（admin）：建 SSH target，绑 host source
boundary targets create ssh -scope-id=<project-id> -name="web-ssh" \
  -default-port=22 -session-max-seconds=3600
boundary targets add-host-sources -id=<target-id> -host-source=<hs-id>
#    └ target = "可被连接的服务 + 一组权限"；session-max-seconds 限会话时长

# ④ 一次性配置（admin）：grant 角色给 principal（谁能 connect 该 target）
boundary roles create -scope-id=<project-id> -name="web-users"
boundary roles add-grants -id=<role-id> -grant="ids=<target-id>;actions=authorize-session"
boundary roles add-principals -id=<role-id> -principal=<user-or-group-id>
#    └ grant = action+resource；authorize-session 是连接目标所需动作

# ⑤ 运行态（end user）：登录 -> 经 worker 连主机
boundary authenticate oidc -auth-method-id=<am-id>     # 或 password / ldap
boundary connect ssh -target-id=<target-id>
#    └ authorize-session 经 RBAC 签一次性会话 token + 指派 worker；connect 经 worker 隧道到 10.0.0.21:22
#      此场景无 credential source，用户自带 SSH key 认证目标（brokered/injected 见 §5/§6）
```

### 一句话本质
Boundary = 控制面鉴权签一次性会话、数据面 worker 代理到目标的"人→主机"访问代理。

---

## §2 身份与认证（auth method）（edition: Community / Enterprise / HCP）

### 解决什么问题
人访问基础设施时，账号散落在各主机/各 DB，无统一身份。Boundary 让人**用企业 IdP 登录一次**，身份在 Boundary 内统一表达。

### 核心模型 / 原理
- **Auth Method** —— 认证机制：**OIDC**、**LDAP**、**password**（[domain-model](https://developer.hashicorp.com/boundary/docs/concepts/domain-model)）。
- **Account** —— 某 auth method 下的一份凭据，用来确立 user 身份。
- **User / Group / Managed Group** —— principal；**managed group** 按上游 IdP（OIDC/LDAP）的 claim/属性自动归组，免手工维护成员。

### 核心能力清单
- OIDC / LDAP / password 三类 auth method。
- account → user 绑定；group / managed group 做集合授权。
- managed group 按 IdP claim 动态成员。

### 最小使用场景（未实测，基于文档）

**场景 A：admin 配 OIDC 登录，end user 用企业 IdP 登录**
```bash
# ① 一次性配置（admin）：在 org scope 建 OIDC auth method（省略 issuer/client 等参数）
boundary auth-methods create oidc -scope-id=<org-id> -name="okta" \
  -issuer="https://acme.okta.com" -client-id=<id> -client-secret=<secret> \
  -signing-algorithm=RS256 -api-url-prefix="https://boundary.acme.com"
boundary auth-methods change-state oidc -id=<am-id> -state=active-public
#    └ active-public 后该 auth method 才对用户可见可用

# ② 运行态（end user）：用 OIDC 登录（浏览器跳 IdP）
boundary authenticate oidc -auth-method-id=<am-id>
#    └ Boundary 作 OIDC RP 完成登录 -> account -> user；managed group 按 claim 自动归组
```

### 一句话本质
Auth method = 人用 OIDC/LDAP/password 登录 Boundary，managed group 按 IdP claim 动态归组。

---

## §3 Scope + RBAC 授权（edition: Community / Enterprise / HCP）

### 解决什么问题
控制"谁能对哪个目标/资源做什么动作"，并按组织结构分层隔离资源。

### 核心模型 / 原理
- **Scope** —— 三层容器：**global**（顶层）→ **org**（业务单元）→ **project**（具体工作负载；target/host/cred-store 归此层）（[domain-model](https://developer.hashicorp.com/boundary/docs/concepts/domain-model)）。
- **Role / Grant** —— role 含一组 grant；**grant = action(s) + resource(s)**；assign 给 principal。模型是**组合式、allow-only 的 RBAC**（[rbac](https://developer.hashicorp.com/boundary/docs/rbac)）。
- 资源 ID / 类型 / 通配可作 grant 的 resource 选择器。

### 核心能力清单
- 三层 scope（global/org/project）隔离资源。
- role + grant（action+resource）+ principal。
- allow-only、组合式 grant（无 deny 规则，靠"不授"实现拒绝）。

### 最小使用场景（未实测，基于文档；[assignable-permissions](https://developer.hashicorp.com/boundary/docs/rbac/assignable-permissions)）

**场景 A：admin 只给某组授本 project 内目标的连接权**
```bash
# ① 一次性配置（admin）：在 project scope 建 role
boundary roles create -scope-id=<project-id> -name="db-operators"
# ② grant：仅允许对该类型资源做 authorize-session（连接）
boundary roles add-grants -id=<role-id> \
  -grant="type=target;actions=list,authorize-session"
# ③ 把组绑上
boundary roles add-principals -id=<role-id> -principal=<group-id>
#    └ allow-only：未授的动作即拒；改授权即改 grant/principal，下次 authorize-session 生效
```

### 一句话本质
Boundary RBAC = 三层 scope 隔离 + role(grant=action+resource) allow-only 授权。

---

## §4 Targets + Host Catalog（edition: Community / Enterprise / HCP）

### 解决什么问题
把"可被访问的服务"建模为一等资源，并能**自动发现**云上动态主机，免手工维护主机清单。

### 核心模型 / 原理
- **Host Catalog** —— 装 host / host-set 的容器，两类：**static**（手工录地址）与 **plugin / 动态**（按云 API 发现主机，如 AWS/Azure plugin）（[domain-model](https://developer.hashicorp.com/boundary/docs/concepts/domain-model)）。
- **Host / Host Set** —— host = 一个可达网络地址；host-set = 等价主机集合（访问控制单位）。
- **Target** —— "可被连接的网络服务 + 关联权限"；绑 **host source**（host-set）或直接写 address，可选绑 **credential source**（§5/§6）。

### 核心能力清单
- static host catalog（手工）/ plugin 动态 host catalog（云发现）。
- target 类型：`tcp`、`ssh`（injection 走 ssh target）等。
- target 绑 host source + credential source + 会话时限/连接数限制。

### §4.1 Kubernetes 目标（edition: 连接 Community 可用；injection 取决于凭据交付方式）

**Boundary 对 K8s 做什么 / 不做什么（精确）**：Boundary 把 **K8s API server 当作一个访问目标**来代理 —— `boundary connect kube` 授权会话后调起 kubectl，经 worker 把 kubectl 流量代理到集群 API（[connect kube](https://developer.hashicorp.com/boundary/docs/commands/connect/kube)）。它**不做** K8s 工作负载侧的任何事（不发 SA token 给 Pod、不改 imagePullSecret、不在集群内当 operator/CSI 跑）——它是"**人**经代理 `kubectl`"，不是"**工作负载**的凭据使用层"。

**典型组合（官方教程）**：用 **Vault 现造 just-in-time K8s 凭据**，让远端用户本地不存常驻 K8s token（[kubernetes-getting-started](https://developer.hashicorp.com/boundary/tutorials/kubernetes-connect/kubernetes-getting-started-intro)）。

**数据流（人经 Boundary 用 kubectl 访问集群）**：
```
  boundary CLI ──authenticate──> Controller ──authorize-session(RBAC)──> 签会话 token + 指派 worker
       │                                              │
       │                                  (绑 Vault cred lib 时) 从 Vault 现取 K8s 凭据
       ▼                                              ▼
  kubectl  ──(本地端口)──> Worker(代理) ──> K8s API server  ──(brokered: 客户端持凭据 / injected: worker 代认证)
```
1. admin 把 K8s API 建成一个 target（直接 address 或经动态 host catalog），可绑 Vault 凭据库现造 K8s 凭据。
2. user `boundary connect kube -target-id=...`；Controller 经 RBAC 授权、（如绑 Vault）现取 K8s 凭据、指派 worker。
3. worker 把 kubectl 流量代理到 API server；凭据 **brokered**（客户端拿到 kubeconfig 用，OSS）或 **injected**（worker 代认证，Enterprise/HCP）。

### 最小使用场景（未实测，基于文档）

**场景 A：admin 配动态 AWS host catalog，end user 连发现到的主机**
```bash
# ① 一次性配置（admin）：建 AWS plugin 动态 host catalog（省略 AWS 凭据/region 参数）
boundary host-catalogs create plugin -scope-id=<project-id> -plugin-name=aws \
  -attr disable_credential_rotation=true -attr region=us-east-1 \
  -secret access_key_id=<k> -secret secret_access_key=<s>
# ② 一次性配置（admin）：host-set 用云标签过滤主机
boundary host-sets create plugin -host-catalog-id=<hc-id> \
  -attr filters="tag:service=web"
#    └ Boundary 周期性按 filter 调 AWS API 发现主机，自动同步进 host-set
boundary targets add-host-sources -id=<target-id> -host-source=<hs-id>
# ③ 运行态（end user）：照常连，目标主机由动态目录提供
boundary connect ssh -target-id=<target-id>
```

### 一句话本质
Target = "可连服务+权限"；host catalog static 手录或 plugin 云发现，K8s 即"人经代理 kubectl"。

---

## §5 Brokered 凭据（含 Vault 凭据库）（edition: Community / Enterprise / HCP）

> **本章为深度展开章**（动态凭据 / 凭据来源是 Connectors 核心问题域）。

### 解决什么问题
客户端连目标时不该预存长期密码/密钥。Boundary 在**会话授权时现取凭据**回交客户端（brokered），凭据可来自**静态库**或**经 Vault 现造的动态凭据**，会话结束即撤销。

### 核心模型 / 原理（带编号流程，要能复述）

两层抽象（[domain-model](https://developer.hashicorp.com/boundary/docs/concepts/domain-model)、[credential-management](https://developer.hashicorp.com/boundary/docs/concepts/credential-management)）：
- **Credential Store** —— 取/存/（可能）生成凭据的资源，两类：**static**（Boundary 自存的静态凭据，如 user-pass / ssh key）与 **Vault**（持一个 Vault token，向 Vault 现取）。
- **Credential Library** —— 从某 credential store 取**同类型同权限**凭据的"取法"。Vault 库两个子类型：
  - **vault-generic**：按配置的 Vault path + HTTP method 取，可映射成 username/password 等（覆盖 DB / kv / k8s 等任意 Vault 引擎产物）。
  - **vault-ssh-certificate**：专门走 Vault SSH secrets engine 现签 SSH 证书（注入场景见 §6，**Enterprise** 才能 inject；brokered 形态 OSS 可取回客户端）。

**关键定性（必须明说）**：**Boundary 自身不内置任何 DevOps 工具的动态凭据引擎**。它**没有** GitLab / Harbor / Nexus / JFrog 的"现造令牌"backend；对 DB / SSH / K8s 的"动态/一次性凭据"，Boundary 是**从 Vault broker/代取**——动态凭据由 **Vault 的 secrets engine 现造**，Boundary 只负责"会话授权时取、会话结束时通知 Vault 撤"。即：**动态能力 = Vault 的能力，Boundary 是会话生命周期粘合 + 交付通道**。

**带编号处理流程（连 DB，Vault 动态凭据 brokered，全链路）**：
1. **配置（admin）**：在 Vault 配好一个能现造 DB 账号的 secrets engine + policy；Boundary 建一个 **Vault credential store**（持有限权 Vault token），其 policy 需含 `sys/leases/renew` 与 **`sys/leases/revoke`**（[community-vault-cred-brokering-quickstart](https://developer.hashicorp.com/boundary/tutorials/credential-management/community-vault-cred-brokering-quickstart)）。
2. **建库 + 绑目标（admin）**：建 **vault-generic credential library**（指向 Vault DB 引擎的 path），把它作为 **brokered credential source** 绑到 DB target。
3. **会话授权（运行态）**：user `authorize-session` → Controller 调 Vault **现取一份一次性 DB 凭据**（Vault 现造、带 lease）→ 凭据**随会话授权回交客户端**。
4. **客户端使用（运行态）**：客户端拿这份现造凭据连 DB（经 worker 隧道）。
5. **会话结束（变更态）**：会话终止时 Boundary **通知 credential library,并具 `sys/leases/revoke` 权限撤销该 lease** —— 凭据生命周期 = 会话生命周期，"等价一次性密码"（[search 结论引官方 quickstart](https://developer.hashicorp.com/boundary/docs/vault)）。

**lease / TTL / 撤销定性**：动态凭据 TTL 由 **Vault** 决定；Boundary 在会话内可 renew、会话结束主动 revoke。SSH 证书注入场景另有约束："证书按整个会话签发，若 `ttl` < 目标的 `session_max_seconds`，后续连接可能失败"（[credential-libraries](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/credential-libraries)）。

### 核心能力清单
- credential store：static（自存）/ Vault（现取）。
- credential library：vault-generic（任意 Vault 引擎产物）/ vault-ssh-certificate（SSH 证书）。
- brokered：凭据回交客户端（OSS 可用）。
- 会话结束撤 Vault lease（dynamic = 一次性）。
- **无** DevOps 工具（GitLab/Harbor/Nexus/JFrog）原生动态引擎——经 Vault 才有动态能力。

### 最小使用场景（未实测，基于文档；[oss-vault-cred-brokering-quickstart](https://developer.hashicorp.com/boundary/tutorials/access-management/oss-vault-cred-brokering-quickstart)）

**场景 A：admin 配 Vault 动态 DB 凭据 brokered，end user 连 DB 时拿一次性账号**
```bash
# ① 一次性配置（admin，在 Vault 侧）：DB secrets engine + 一个最小权限 token 给 Boundary（命令略）

# ② 一次性配置（admin，在 Boundary 侧）：建 Vault credential store（持 Vault token）
boundary credential-stores create vault -scope-id=<project-id> \
  -vault-address="https://vault.acme.com:8200" -vault-token=<boundary-token>
#    └ 该 token 的 Vault policy 必须含 sys/leases/renew 与 sys/leases/revoke，否则会话结束撤不掉

# ③ 一次性配置（admin）：建 vault-generic 库，指向 Vault DB 引擎 path
boundary credential-libraries create vault-generic -credential-store-id=<cs-id> \
  -vault-path="database/creds/readonly" -name="db-readonly"

# ④ 一次性配置（admin）：把库作为 brokered credential source 绑到 DB target
boundary targets create tcp -scope-id=<project-id> -name="pg" -default-port=5432
boundary targets add-credential-sources -id=<target-id> \
  -brokered-credential-source=<cred-lib-id>
#    └ 关键：用 -brokered-credential-source（凭据回交客户端）；injected 见 §6

# ⑤ 运行态（end user）：连接，Boundary 现取 Vault 一次性账号并回交
boundary connect postgres -target-id=<target-id> -- -d appdb
#    └ authorize-session 时 Boundary 调 Vault 现造 DB 账号(带 lease)；会话结束 Boundary 调 Vault revoke
```

### 一句话本质
Brokered = 会话授权时从 static/Vault **现取**凭据回交客户端、会话结束撤 lease；动态能力来自 Vault，非 Boundary 自造。

---

## OSS（Community Edition）能力组合回顾

**Community Edition 单独能交付什么**：Controller/Worker 会话访问代理（§1）、OIDC/LDAP/password 身份（§2）、三层 scope + RBAC（§3）、static / 动态 host catalog + targets（§4）、**brokered 凭据**（含 Vault 动态凭据 broker、会话结束撤 lease，§5）、会话级审计事件（§7）。即"人经身份化代理访问私网主机/DB/K8s + 经 Vault broker 一次性凭据 + 基础审计"这条主链 OSS 即可跑通。

**需要 Enterprise / HCP 才有的**：**Injected 凭据**（worker 代认证、客户端永不见凭据、SSH 证书注入，§6）、**会话录制 BSR**（§7.1，需 HCP Plus / Enterprise）、**Transparent Sessions**（§8）。**注意**：OSS 缺的恰是"客户端永不持有凭据"的 injection ——**Community 的 secretless 程度止于 brokered（凭据仍回到客户端手里）**。

---

# Enterprise / HCP 章节（以下能力**仅 Enterprise / HCP 提供**）

> **edition 提醒**：从此章节起所有能力默认需要 Enterprise license 或 HCP Boundary，除非另注。客户场景下不要假设 Community 可用。

## §6 Injected 凭据（含 SSH 证书注入）（edition: Enterprise / HCP）

> **本章为深度展开章**（"客户端永不持有凭据"的 secretless 注入是 Connectors 机制孪生点）。
>
> ⚠️ **Enterprise / HCP 限定**：credential injection 是付费能力；Community 只有 brokered（[credential-management](https://developer.hashicorp.com/boundary/docs/concepts/credential-management)）。

### 解决什么问题
brokered 把凭据回交客户端——客户端**仍持有**一份能直连目标的凭据（泄漏窗口 = 凭据有效期）。injection 让 **worker 代客户端完成目标认证**，客户端**永不见**凭据，达成真正的 passwordless / secretless 体验。

### 核心模型 / 原理（带编号流程，要能复述）

- **注入点 = worker**：会话授权后，凭据交给被指派的 **worker**；worker 在数据面用它完成对目标的认证握手，再把已认证的会话透传给客户端。客户端看到的是"已连上的目标"，从不接触凭据（[credential-management](https://developer.hashicorp.com/boundary/docs/concepts/credential-management)）。
- **可注入的凭据类型**：username/password、username/public-key（来自 Vault 通用库），以及 **SSH 证书**（来自 **vault-ssh-certificate 库**，走 Vault SSH secrets engine 现签）（[credential-libraries](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/credential-libraries)）。RDP credential injection 同属 Enterprise/HCP（beta 0.20 / GA 0.21）。
- **限制**：keyboard-interactive 认证不支持注入（[credential-management](https://developer.hashicorp.com/boundary/docs/concepts/credential-management)）。

**带编号处理流程（SSH 证书注入，全链路）**：
1. **Vault 侧（admin）**：配 SSH secrets engine（CA 模式），目标主机的 sshd 信任该 Vault CA（`TrustedUserCAKeys`）。
2. **Boundary 侧（admin）**：建 Vault credential store + **vault-ssh-certificate library**；把它作为 **injected credential source**（`-injected-application-credential-source`）绑到 **ssh target**。
3. **会话授权（运行态）**：user `authorize-session` → Boundary 调 Vault SSH 引擎**现签一张短期 SSH 证书**（按整个会话的 TTL）→ 证书交给 worker，**不回客户端**。
4. **目标认证（数据面）**：worker 用该 SSH 证书代客户端完成对目标 sshd 的认证（目标信任 Vault CA）→ 客户端经 worker 进入已认证会话，全程未持证书。
5. **会话结束**：证书随会话过期失效（按会话签发）；Vault lease 由 Boundary 在会话结束时清理。

**与 brokered 的唯一分水岭**：凭据**是否回到客户端**。brokered = 回（OSS）；injected = 不回、worker 代认证（Enterprise/HCP）。

### 核心能力清单
- worker 代认证，客户端永不见凭据。
- 可注入：user-pass / user-pubkey（Vault 通用库）、SSH 证书（vault-ssh-certificate 库）、RDP（Enterprise/HCP）。
- 限制：keyboard-interactive 不支持注入。

### 最小使用场景（未实测，基于文档）

**场景 A：admin 配 SSH 证书注入，end user 连主机时永不见凭据**
```bash
# ① 一次性配置（admin，Vault）：SSH secrets engine CA 模式；目标 sshd 配 TrustedUserCAKeys（命令略）

# ② 一次性配置（admin，Boundary）：vault-ssh-certificate 库
boundary credential-libraries create vault-ssh-certificate \
  -credential-store-id=<cs-id> -vault-path="ssh/sign/boundary" \
  -username=ubuntu -name="ssh-cert"

# ③ 一次性配置（admin）：作为 INJECTED 源绑到 ssh target（注意标志不同于 §5）
boundary targets create ssh -scope-id=<project-id> -name="web-ssh" -default-port=22
boundary targets add-credential-sources -id=<target-id> \
  -injected-application-credential-source=<cred-lib-id>
#    └ -injected-application-credential-source = worker 代认证；客户端永不见凭据（Enterprise/HCP）

# ④ 运行态（end user）：连接，全程无凭据落到本地
boundary connect ssh -target-id=<target-id>
#    └ authorize-session 时 Boundary 调 Vault 现签 SSH 证书 -> 交 worker -> worker 代认证目标 sshd
```

### 一句话本质
Injected = worker 代客户端认证目标、客户端永不见凭据；SSH 证书经 Vault 现签注入（Enterprise/HCP）。

---

## §7 审计事件 + §7.1 会话录制（BSR）

### §7 审计事件（edition: Community / Enterprise / HCP）

**解决什么问题**：留存"谁、何时、对哪个目标、发起了什么会话/连接"的结构化记录。
**核心模型**：Boundary 产出结构化事件（认证、会话授权、连接），可观测/外送。
**核心能力清单**：会话/连接事件、可对接日志管道。
**最小使用场景（未实测，基于文档）**：
```bash
# 运行态（审计员）：列出会话与状态
boundary sessions list -scope-id=<project-id>
boundary sessions read -id=<session-id>
#    └ 看到会话发起者/目标/起止；内容回放需 §7.1 会话录制（付费）
```
**一句话本质**：审计 = 会话/连接级结构化事件（OSS 即有）。

### §7.1 会话录制（BSR）（edition: Enterprise / HCP Plus）

> ⚠️ **Enterprise / HCP Plus 限定**（[session-recording](https://developer.hashicorp.com/boundary/docs/session-recording)）。

**解决什么问题**：合规/威胁管理要求录制会话内容并可回放。
**核心模型**：worker 录制会话，写 **S3 兼容存储**；产物是 **BSR（Boundary Session Recording）文件格式**——分层目录 + 二进制，含会话内全部传输数据（[bsr-file-structure](https://developer.hashicorp.com/boundary/docs/session-recording/data/bsr-file-structure)）。
**核心能力清单**：在 target 上开启录制、S3 兼容（含 MinIO）存储、BSR 回放。
**最小使用场景（未实测，基于文档；[enable-session-recording](https://developer.hashicorp.com/boundary/docs/session-recording/configuration/enable-session-recording)）**：
```bash
# ① 一次性配置（admin）：建 storage bucket（S3 兼容）资源（参数略），再在 target 开启录制
boundary targets update ssh -id=<target-id> \
  -enable-session-recording=true -storage-bucket-id=<sb-id>
#    └ 之后该 target 的会话由 worker 录制写 BSR 到 S3 兼容存储，供合规回放
```
**一句话本质**：会话录制 = worker 录会话写 S3、BSR 格式可回放（Enterprise/HCP Plus）。

---

## §8 Transparent Sessions（edition: Enterprise / HCP）

> ⚠️ **Enterprise / HCP 限定**（GA 2025-05,Boundary 0.19.x / Client Agent 0.19.5;[GA 公告](https://www.hashicorp.com/en/blog/transparent-sessions-now-ga-in-hashicorp-boundary)）。

**解决什么问题**：用户每次访问要手动 `boundary connect` 太繁琐；希望像直连一样透明访问目标。
**核心模型**：通过 **Boundary Client Agent** 拦截到目标的流量、自动接管会话授权与代理，用户无需手动 connect。
**核心能力清单**：Client Agent 透明拦截、自动授权、对用户近乎无感。
**最小使用场景（未实测，基于文档）**：用户装 Client Agent + 登录后，直接 `ssh user@<target-dns>`，Agent 透明接管经 Boundary 代理（无需 `boundary connect`）。
**一句话本质**：Transparent Sessions = Client Agent 透明接管目标流量、免手动 connect（Enterprise/HCP）。

---

## §9 许可 / edition / air-gap 边界（关键）

### 许可证模型（load-bearing）
- **源码 `<= 0.13.1` = MPL-2.0**；**`>= 0.14.0` 起 = BUSL-1.1（Business Source License v1.1）**，**4 年后该版本转 MPL-2.0**（[HashiCorp 许可变更公告](https://discuss.hashicorp.com/t/hashicorp-projects-changing-license-to-business-source-license-v1-1/57106)、[boundary/LICENSE](https://github.com/hashicorp/boundary/blob/main/LICENSE)）。
- **BUSL 约束**：禁止把产品用于"与 HashiCorp 商业产品/服务竞争的生产用途"。对发行竞品平台的 **ISV 而言不可内嵌**（与 Vault BSL / Teleport AGPL+禁嵌入同类许可陷阱）。
- **无知名社区 fork 接管 OSS**（与 Vault→OpenBao 不同）；截至 2026-06 未确认有活跃 fork。

### edition 能力切分（销售/SE 雷区）
| 能力 | Community（OSS） | Enterprise / HCP |
|---|---|---|
| Controller/Worker 代理、scope/RBAC、auth method、host catalog、targets | ✅ | ✅ |
| **Brokered 凭据**（含 Vault 动态凭据 broker） | ✅ | ✅ |
| **Injected 凭据**（worker 代认证、SSH 证书注入、RDP 注入） | ❌ | ✅ |
| **会话录制 BSR** | ❌ | ✅（HCP **Plus** / Enterprise） |
| **Transparent Sessions** | ❌ | ✅ |
| Enterprise binary 需 license key | — | ✅（[licensing](https://developer.hashicorp.com/boundary/docs/enterprise/licensing)） |

### air-gap 友好度
- 自托管 Community/Enterprise 可离线部署（Controller + Postgres + Worker + KMS 都可自管）；动态凭据需自管 Vault，会话录制需 S3 兼容存储（MinIO 可离线）。Enterprise 需 license key（offline license 机制未深挖，**未确认**）。HCP 是托管 SaaS，**air-gap 不适用**。

---

## 附：fact-check 待核（2026-06-18，落版后派 Agent 核）

- §5 会话结束撤 Vault lease 的精确路径（`sys/leases/revoke`）— 已核：官方 quickstart 要求该 policy 权限。
- §6 RDP injection — Enterprise/HCP；beta 0.20 / GA 0.21（[0.21 GA](https://www.hashicorp.com/en/blog/boundary-0-21-improves-remote-access-security-and-ux-for-rdp-connections)）。
- §7.1 "HCP Plus vs HCP 标准"会话录制归属 — 已核需 HCP Plus / Enterprise；HCP tier 命名以官网为准。
- §9 Enterprise offline license（air-gap）机制 — 未深挖（**未确认**）。
- §0/§8 Transparent Sessions — GA 2025-05（Boundary 0.19.x / Client Agent 0.19.5）,Enterprise/HCP（已核）。

**相关文档**：`connectors-vs-boundary.md`（与 Connectors 的对比 + 边界 + roadmap 启发）。
