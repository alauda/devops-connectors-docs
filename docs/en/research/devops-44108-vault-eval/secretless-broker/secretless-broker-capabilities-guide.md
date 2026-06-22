# CyberArk Secretless Broker 能力调研指南

> **状态**：已完成（持续可追加）
> **覆盖版本**：Secretless Broker v1.7.32（2026-02-05 发布；[releases](https://github.com/cyberark/secretless-broker/releases)）
> **基于源**：官方仓库 `github.com/cyberark/secretless-broker` + 官方文档 `docs.secretless.io` / `docs.cyberark.com`（逐条带 URL）
> **edition 范围**：单一 edition —— **整个 Secretless Broker 是 Apache-2.0 开源**，无 Enterprise/付费分层（付费的是它对接的 *后端 vault*，如 CyberArk Secrets Manager / Conjur Enterprise，不是 broker 本身）
> **不覆盖**：CyberArk Secrets Manager / Conjur 本身的能力（broker 只是它们的消费端之一）；价格
> **未实测**：本指南未在集群实跑 demo，命令/YAML 均"未实测，基于官方文档"。

本文档**只讲 Secretless Broker 自身**：它有哪些能力、解决什么问题、适合什么场景、基本原理、收不收费。

---

## §0 心智模型 + 能力地图速览

**心智模型（4 行）**：Secretless Broker 是一个**本地连接代理（local connection proxy）**——应用不再持有数据库/服务的凭据，而是连接到一个跑在本机（K8s 里是同 Pod 的 sidecar）的 Secretless 进程；Secretless 通过 *credential provider* 取出真凭据（provider 背后可能是 vault，也可能是 K8s Secret / 环境变量 / 文件 / 字面量等，**不限于 vault**），**在后端协议的认证握手阶段把凭据注入出栈连接**，认证完成后在 client ↔ target 之间做**数据透传（pass-through）**。一份 `secretless.yml` 声明 `services`（每个 = 一个 `connector` + `listenOn` 监听地址 + `credentials`）。([README](https://github.com/cyberark/secretless-broker/blob/main/README.md)、[how-it-works](https://docs.secretless.io/Latest/en/Content/Overview/scl_how_it_works.htm))

**简化架构（运行时数据流）**：

```
                         +-----------------------------------+
                         |        Credential Provider        |
                         | conjur / vault / aws / k8s secret |
                         |        env / file / literal       |
                         +-----------------+-----------------+
                                           ^ (2) fetch latest creds on each new connection
   ========================================| in same Pod / loopback: App <-> Broker cleartext, never on the wire
                                           v
   +-----------+                 +---------+---------+                +-------------+
   |    App    |  (1) connect -> | Secretless Broker |  (3) inject -> | Real Server |
   | container |  <- response -  | Connector / Proxy |  <- response - |  DB / HTTP  |
   +-----------+                 +-------------------+                +-------------+
```

- **(1)** App 连本地端口：**DB/TCP 类**（pg/mysql/mssql/ssh）把 Broker 当「目标服务本身」直连；**HTTP 类**（basic_auth/generic_http/aws/conjur）把 Broker 当 `http_proxy`。
- **(2)** Broker 在**每条新连接建立时**从 credential provider 取最新真凭据（这是「轮换透明承接」的根因；provider 背后不限于 vault）。
- **(3)** Broker 注入真凭据完成对 Real Server 的认证：**DB/TCP** 认证握手注入一次 → 之后纯字节透传；**HTTP** 逐请求注入 `Authorization` 头（app→broker 明文、`forceSSL` 升级上游为 https）。
- **✦ 关键**：真凭据只活在 Broker↔provider 之间，**App 永不持有**；App↔Broker 的明文段（图中虚线边界）锁在同 Pod loopback、不出网。

**许可 / Fork / air-gap（先记这条）**：**Apache-2.0**，CyberArk 维护的独立开源社区项目，**无 fork、无 Enterprise tier**（[README license](https://github.com/cyberark/secretless-broker/blob/main/README.md)）。镜像发到 DockerHub `cyberark/secretless-broker`，`stable` tag 为稳定发布。air-gap 友好度取决于后端：用 `env`/`file`/`literal`/`keychain`/`kubernetes` provider 时 broker 自身无外呼、完全离线可跑；用 `conjur`/`vault` provider 时需能触达对应 vault。

### 能力地图速览（30 秒看全貌）

一行 = 一章。**全部 OSS（Apache-2.0），无付费分层**，故不分 OSS/付费两表；用 maturity（GA / Beta）区分。

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 | maturity |
|---|---|---|---|---|---|---|
| §1 | Service Connector（协议代理） | app 不持数据库/服务凭据 | 监听本地端口 → 后端协议认证阶段注入凭据 → 数据透传 | client 零改造（仍说原生协议） | app 连 Postgres 不知道密码 | 见各 connector |
| §2 | Credential Provider（取凭据） | 凭据从哪个 vault 取 | `from: <provider> / get: <id>` 解析出真凭据 | 8 种内置 provider 可混用 | 从 Conjur / K8s Secret / env 取密码 | GA |
| §3 | secretless.yml 配置模型 | 声明式定义代理服务 | `version/services/connector/listenOn/credentials/config` | 一份 YAML 描述多个 service | 一个 sidecar 同时代理 pg + http | GA |
| §4 | K8s sidecar 部署 + CRD 配置 | 在 K8s 里给 Pod 加 secretless | 同 Pod sidecar，配置走 ConfigMap 或 `configurations.secretless.io` CRD | CRD 改配置自动热加载 | 给 Deployment 注入 secretless sidecar | GA |
| §5 | 凭据轮换透明承接 | 后端轮换密码时 app 不用重启 | 下一条新连接时重新取最新 secret | rotation 对 client 透明 | vault 轮换 DB 密码、app 无感 | GA |
| §6 | Connector Plugin 扩展 | 支持内置之外的 target | 实现 Plugin Interface 编译进 binary | 扩展任意协议 | 自研协议接 secretless | GA（接口） |

**各 Service Connector 的 maturity（§1 细分）**：

| connector | target | maturity |
|---|---|---|
| `pg` | PostgreSQL（TCP + Unix socket） | **GA** |
| `mysql` | MySQL（TCP + Unix socket） | **GA** |
| `mssql` | Microsoft SQL Server | **未确认**（README 未列入连接器清单，见 §1） |
| `ssh` / `ssh-agent` | SSH | **Beta** |
| `basic_auth` / `generic_http` / `aws` / `conjur`（HTTP 系，正向代理形态，见 §1 小结） | 向出栈 HTTP 请求注入认证（Basic / 自定义头·queryParam / AWS SigV4 / Conjur token） | **Beta** |

> maturity 出处：[README](https://github.com/cyberark/secretless-broker/blob/main/README.md) **只对 SSH/SSH-Agent 与 HTTP（Basic/CyberArk SM/Conjur OSS/AWS）显式标注 `(Beta)`**；MySQL/PostgreSQL **未标 Beta**——README 并未使用 "GA" 字样，本文按「未标 Beta = 稳定可用」把它们记为 **GA-等同**（这是本文的标注，非 README 原话）。MSSQL 在源码中是已注册的 TCP connector（`internal/plugin/connectors/tcp/mssql`，id `mssql`），但 README 未把它列入展示清单，**maturity 未确认**。

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 让 app 连 Postgres/MySQL 时不持密码 | §1（GA） |
| 让 app 调 HTTP API 不持 token / SSH 不持 key | §1（Beta） |
| 决定凭据从 Conjur / K8s Secret / env / 文件 哪里取 | §2 |
| 写 secretless.yml 描述要代理哪些服务 | §3 |
| 在 K8s 里把 secretless 塞进 Pod、改配置自动生效 | §4 |
| 后端轮换密码后 app 不重启就用新密码 | §5 |
| 接一个内置不支持的协议/服务 | §6 |

---

## §1 Service Connector：协议感知的凭据注入代理（edition: OSS / Apache-2.0；各 connector GA 或 Beta）

### 解决什么问题
应用要连 PostgreSQL/MySQL/HTTP API/SSH，传统做法是把密码/token/私钥喂进 app（env、配置文件、代码），凭据会进 log、core dump、镜像。Secretless 把"持有凭据 + 做认证"从 app 里**整个搬到一个独立进程**，app 自己永不见真凭据。([README](https://github.com/cyberark/secretless-broker/blob/main/README.md))

### 核心模型 / 原理
一个 **Service Connector** = "某个后端协议的认证适配器"。app 把 Secretless 当成 target 本身去连（连本地端口/socket）；Secretless 用对应 connector **代说该协议的认证握手**，握手里填入从 provider 取来的真凭据；认证过后 Secretless 退化为 **pass-through 管道**，client ↔ target 的数据直接对穿。([how-it-works](https://docs.secretless.io/Latest/en/Content/Overview/scl_how_it_works.htm) 原文："a proxy that intercepts traffic to the Target Service and performs the authentication phase of the back-end protocol. The data-transfer phases of the protocol are direct pass-through")

**带编号的请求处理流程**（DevOps/数据库场景必须能复述）：
1. app 发起一条到 `listenOn`（如 `tcp://localhost:5432`）的**普通协议连接**（它以为对面就是 Postgres）。
2. connector 接住这条连接，进入后端协议的**认证阶段**。
3. connector 按 `credentials` 配置，调对应 **credential provider**（§2）取出真 host/username/password（或 token、私钥）。
4. connector **重写认证请求、注入真凭据**，向真正的 target 发起后端连接并完成认证握手。([connectors overview](https://docs.secretless.io/Latest/en/Content/References/connectors/scl_connectors_overview.htm))
5. 认证成功 → Secretless 把两端拼成透传管道，后续数据直穿，broker 不再参与业务字节的改写。
6. 连接关闭即结束；**下一条新连接重走 1–5**，因此能拿到轮换后的新凭据（§5）。

### 核心能力清单
- **GA connectors**：`pg`（PostgreSQL）、`mysql`（MySQL），均支持 **TCP 与 Unix socket** 两种 `listenOn`。([README](https://github.com/cyberark/secretless-broker/blob/main/README.md))
- **Beta connectors**：`ssh` / `ssh-agent`；HTTP 系（`basic_auth` 以及向 HTTP 请求注入 CyberArk Secrets Manager / Conjur OSS / AWS 授权头的策略）。([README](https://github.com/cyberark/secretless-broker/blob/main/README.md))
- MySQL/PostgreSQL 近期增强：支持 `verify-full` SSL 模式与 `sslhost` 参数做 SAN 校验（[v1.7.0 release](https://github.com/cyberark/secretless-broker/releases/tag/v1.7.0)）。
- Generic HTTP connector 支持 `queryParam`，可把凭据注入查询字符串（[v1.7.0 release](https://github.com/cyberark/secretless-broker/releases/tag/v1.7.0)）。
- **边界**：connector 只在**认证阶段**介入；不做 RBAC、不做 per-request 授权、不改业务数据。
- **DevOps 工具覆盖（GitLab / Harbor / Nexus）**：**无专用 connector**。这三类工具若走 HTTP Basic/Bearer，可勉强用 **Beta 的 `basic_auth`/HTTP connector** 注入凭据（把 Harbor/Nexus 当通用 HTTP target），但 Secretless **没有 Harbor/GitLab/Nexus 类型化 connector，也不理解它们的 API 语义、不做镜像协议（OCI distribution）代理**。OCI 镜像拉取这类非"认证头注入"的场景不在其能力内。

### 最小命令示例
> 未实测，基于官方文档 [README](https://github.com/cyberark/secretless-broker/blob/main/README.md) / [configuration](https://docs.secretless.io/Latest/en/Content/Get%20Started/configuration.htm) / [generic HTTP](https://docs.secretless.io/Latest/en/Content/References/connectors/http/scl_generic.htm)

每个场景都是**三步**：**① 运维/平台一次性写配置 → ② 部署一次性起 broker（K8s 里是 sidecar，见 §4）→ ③ app 运行态连本地端口**。关键点：**app 侧的命令里永远不出现凭据**——凭据只活在 broker 配置引用的后端里。

**场景 A：app 连 PostgreSQL 不持密码（connector: pg）**

```yaml
# ① 一次性配置（运维/平台写）：secretless.yml
version: "2"
services:
  pg-db:
    connector: pg
    listenOn: tcp://0.0.0.0:5432       # app 连这里，以为对面就是 Postgres
    credentials:
      host: pg.internal                # 真 DB 地址，app 不需要知道
      username: { from: conjur, get: app/pg/user }
      password: { from: conjur, get: app/pg/password }
      sslmode: require
```
```bash
# ② 一次性部署（本地 binary 形态；K8s 改用 sidecar，见 §4）
secretless-broker -f secretless.yml

# ③ app 运行态：连本地端口，命令里没有任何密码
psql "host=localhost port=5432 dbname=app user=app"
#    └ broker 接住连接 → 用 conjur 取的真 user/password 替 app 完成 Postgres 认证握手 → 之后纯透传
```

**场景 B：app 调受保护 HTTP API，自动注入 Basic Auth（connector: basic_auth，Beta）**

```yaml
# ① 一次性配置：把 broker 当出栈 HTTP 代理，只对匹配 URL 注入凭据
version: "2"
services:
  http-basic:
    connector: basic_auth
    listenOn: tcp://0.0.0.0:8080
    credentials:
      username: { from: env,    get: WEBAPP_USERNAME }
      password: { from: conjur, get: webapp/password }
    config:
      authenticateURLsMatching: [ "^http[s]?://api\\.internal/" ]   # 只对这些出栈 URL 加 Authorization
```
```bash
# ② 起 broker
secretless-broker -f secretless.yml

# ③ app 运行态：把 HTTP 代理指向 broker，请求里不带任何 Authorization 头
http_proxy=http://localhost:8080 curl http://api.internal/v1/orders
#    └ broker 对匹配 URL 自动补 Authorization: Basic <base64(user:password)>，app 永不见 token
```

### 一句话本质
**协议级"认证替身"——app 说原生协议连本地端口，Secretless 在认证握手里塞真凭据再透传数据。**

### 小结：HTTP 类 connector 是「正向代理」，与数据库类的「目标替身」相对

§1 的 connector 按工作形态分成两种，机制差别值得单独点明：

- **TCP / 数据库类（`pg` / `mysql` / `mssql` / `ssh`）= 目标替身**：app 把 broker 当成「目标服务本身」直接连（连 `listenOn` 那个本地端口），broker 替它做后端协议的认证握手。
- **HTTP 类（`basic_auth` / `generic_http` / `aws` / `conjur`）= 正向代理（forward proxy）**：app 把 broker 当成「出栈 HTTP 代理」，通过 `http_proxy` 把请求路由给它，broker 拆开请求、注入认证头、再转发到真 target。

**HTTP 类的请求处理流程**：

1. **配置（一次性）**：app 设 `http_proxy=http://localhost:<port>` 指向 connector 的 `listenOn`。
2. **运行态**：app 正常请求真实 URL，请求经代理出栈。
3. broker 按 `config.authenticateURLsMatching`（正则列表）判断这条请求要不要注入——**只对命中的出栈 URL 注入**，不命中的原样转发。
4. 命中则按 connector 类型注入凭据：`basic_auth` → `Authorization: Basic base64(user:password)`；`aws` → AWS SigV4 签名；`conjur` → Conjur 访问 token；`generic_http` → 自定义 header / `queryParam`（值走 Go text/template 插值）。
5. 注入后转发到真 target，响应透传回 app。

**关键细节 —— HTTPS 目标怎么注入（最易想岔的点）**：

正向代理要改 header，必须看得到**明文**。所以它**不是用 `CONNECT` 隧道做透明 HTTPS 拦截**——`CONNECT` 是一条不透明 TLS 隧道，broker 只能盲转、改不了 header。Secretless 的模型是：

- **app → broker 走明文 HTTP**（同 Pod loopback，不出网），**broker → 真 target 用 `config.forceSSL: true` 发起 HTTPS**。TLS 在 broker 这一跳重新建立。官方原话：代理「edit the outbound request to add the proper authorization header. It can also optionally forward the connection using HTTPS」（[connectors overview](https://docs.secretless.io/Latest/en/Content/References/connectors/scl_connectors_overview.htm)）；源码即 `generic/connector.go` 里 `if c.config.ForceSSL { r.URL.Scheme = "https" }`（把出栈请求 scheme 改写成 https）。
- **实操后果**：目标即使是 HTTPS 站点，app 也要把地址写成 `http://target/...` 经代理请求（让 broker 拿到明文），由 `forceSSL: true` 把上游升级成 https。官方明确要求「The client should always use plain `http://` URLs, otherwise Secretless cannot read the network traffic because it will be encrypted」（[connectors overview](https://docs.secretless.io/Latest/en/Content/References/connectors/scl_connectors_overview.htm)）。背后原理：若保留 `https://`，HTTP 客户端在设了代理时会发 `CONNECT`，落进不透明隧道、注入失效——所以"改成 http://"不是开关，是 HTTP 代理协议的必然结果。

**安全代价 / 前提**：

- HTTP 类等于 app **放弃了到真 server 的端到端 TLS**——TLS 在 broker 处终结再重起，broker 成了出栈方向的 TLS 中间人（它去校验 target 证书）。
- 能接受的唯一前提是 **app ↔ broker 那段明文只在同 Pod 的 loopback 上、永不出网**。一旦这段不是 loopback（broker 不在同 Pod），带凭据的明文请求就暴露在网络上了——这也是 HTTP connector 实际上强绑 sidecar 形态的原因。

> 一句话：数据库类 connector 是「协议替身」；HTTP 类是「会拆开明文改 header、再用 `forceSSL` 走 https 转发的正向代理」，代价是上游 TLS 终结在 broker、且明文段必须锁在 loopback。

---

## §2 Credential Provider：凭据来源抽象（edition: OSS / Apache-2.0；GA）

### 解决什么问题
凭据可能存在不同地方（Conjur、HashiCorp Vault、K8s Secret、环境变量、文件、系统 keychain）。Secretless 需要一个统一寻址方式，让 `secretless.yml` 不绑死某一种 vault。([providers overview](https://docs.cyberark.com/conjur-open-source/latest/en/content/references/providers/scl_providers_overview.htm))

### 核心模型 / 原理
每条 credential 的值写成 `{ from: <provider>, get: <id> }`：`from` 选 provider，`get` 是该 provider 内的凭据标识。常量也可直接写字符串。([configuration](https://docs.secretless.io/Latest/en/Content/Get%20Started/configuration.htm)) provider 是 broker 取真凭据的"驱动"，与 connector（用凭据的"协议适配器"）正交——任意 connector 可配任意 provider。

### 核心能力清单（内置 provider 关键字）
共 **8 种**内置 provider（factory key 全集：`aws, conjur, env, file, keychain, kubernetes, literal, vault`，见 [providers.go](https://github.com/cyberark/secretless-broker/blob/main/internal/providers/providers.go)）：
- `aws` — 从 **AWS Secrets Manager** 取（通过 `GetSecretValue()` 读取，见 [awssecrets/provider.go](https://github.com/cyberark/secretless-broker/blob/main/internal/providers/awssecrets/provider.go)）
- `conjur` — 从 CyberArk Conjur / CyberArk Secrets Manager 取（[providers overview](https://docs.cyberark.com/conjur-open-source/latest/en/content/references/providers/scl_providers_overview.htm)）
- `vault` — 从 HashiCorp Vault 取（同上）
- `kubernetes` — 从 K8s Secret 取（[K8s Secrets provider](https://docs.cyberark.com/conjur-enterprise/latest/en/Content/References/providers/scl_kubernetes.htm)）
- `env` — 从环境变量取
- `file` — 从文件取
- `literal` — 直接用配置里的字面量值
- `keychain` — 从操作系统 keychain 取（**仅 macOS、仅从源码构建时可用**，标准 Linux sidecar 镜像不可用，见 [keychain provider docs](https://docs.secretless.io/Latest/en/Content/References/providers/scl_keychain.htm)）
- 多 provider 可在同一 `secretless.yml` 内混用（如 username 走 `env`、password 走 `conjur`）。
- **均为 OSS、无 maturity 标注差异**（README 把 broker 整体描述为内置多种 provider）。
- **AWS 同时是两件事**：`aws` 既是 HTTP connector 的**授权策略**（给出栈 HTTP 请求签 AWS 签名），**也是一个独立的内置 credential provider**（从 AWS Secrets Manager 取 secret）—— 两者并存，不要只记其一。

### 最小命令示例
> 未实测，基于官方文档 [configuration](https://docs.secretless.io/Latest/en/Content/Get%20Started/configuration.htm) / [K8s provider](https://docs.secretless.io/Latest/en/Content/References/providers/scl_kubernetes.htm)

**场景：同一个 service 的不同字段从不同后端取**——username 走环境变量、apikey 走 K8s Secret、password 走 Conjur。provider 与 connector 正交，换后端不动 app、不动 connector。

```bash
# ① 一次性（运维）：把凭据预先放进各自后端，broker 只读不写
kubectl create secret generic app-creds --from-literal=api-key=ak_live_xxx   # → kubernetes provider 的来源
export WEBAPP_USERNAME=alice                                                  # → env provider 的来源
# Conjur 侧：把 password 灌进变量 webapp/password（conjur policy load + 写值，从略）→ conjur provider 的来源
```
```yaml
# ② 一次性配置：from 选后端、get 是该后端里的标识；broker 建连时解析 from/get 取真值
credentials:
  username: { from: env,        get: WEBAPP_USERNAME }   # 环境变量
  password: { from: conjur,     get: webapp/password }   # Conjur
  apikey:   { from: kubernetes, get: app-creds#api-key } # K8s Secret 用 <secret-name>#<key> 寻址
  fallback: just-a-literal-string                        # 字面量（等价 from: literal）
```

### 一句话本质
**`from/get` 把"凭据从哪取"与"凭据怎么用"解耦——8 种内置后端可混用。**

---

## §3 secretless.yml 配置模型（edition: OSS / Apache-2.0；GA）

### 解决什么问题
需要一种声明式方式描述"要代理哪些服务、各监听在哪、各用什么 connector 和凭据"，而不是命令行堆参数。([configuration](https://docs.secretless.io/Latest/en/Content/Get%20Started/configuration.htm))

### 核心模型 / 原理
顶层 `version: "2"` + `services` map。每个 service 一个名字，下挂 `connector`（§1 协议类型）、`listenOn`（`tcp://` 或 `unix://` 地址）、`credentials`（§2 的 from/get map）、可选 `config`（协议特定项，如 HTTP 的 `authenticateURLsMatching`）。([configuration](https://docs.secretless.io/Latest/en/Content/Get%20Started/configuration.htm)、[v2 config pkg](https://pkg.go.dev/github.com/cyberark/secretless-broker/pkg/secretless/config/v2))

### 核心能力清单
- 一份配置可定义**多个 service**，一个 broker 进程同时代理 pg + mysql + http。
- `listenOn` 支持 TCP 端口与 Unix socket（`unix:///abs/path`）。
- `config` 段承载 connector 专属选项（HTTP 的 URL 匹配、SSL 参数等）。
- 配置可来自文件、ConfigMap、或 CRD（§4）。

### 最小命令示例
> 未实测，基于官方文档 [configuration](https://docs.secretless.io/Latest/en/Content/Get%20Started/configuration.htm)

**场景：一个 broker 进程同时代理 Postgres + HTTP API**——一份 YAML 声明两个 service，各监听一个端口，一个进程全吃下。

```yaml
# 一次性配置（运维/平台写一次，可放文件 / ConfigMap / CRD）：secretless.yml
version: "2"
services:
  pg-db:                               # service 1：数据库，走 pg connector
    connector: pg
    listenOn: tcp://0.0.0.0:5432
    credentials:
      host: pg.internal
      username: { from: conjur, get: pg/user }
      password: { from: conjur, get: pg/pw }
  http-api:                            # service 2：HTTP，走 basic_auth connector
    connector: basic_auth
    listenOn: tcp://0.0.0.0:8080
    credentials:
      username: { from: env, get: U }
      password: { from: env, get: P }
    config:
      authenticateURLsMatching: [ "^http" ]
```
```bash
# 一次性启动：一个进程吃下整份配置，5432 / 8080 两个监听同时起来
secretless-broker -f secretless.yml
```

### 一句话本质
**一份 `services` YAML 同时声明多个"协议代理 + 凭据来源"。**

---

## §4 Kubernetes sidecar 部署 + CRD 配置（edition: OSS / Apache-2.0；GA）

### 解决什么问题
在 K8s 里要让某个工作负载 secretless，需要把 broker 摆在离 app 最近、共享 loopback 的位置，并能在不重建 Pod 的情况下更新代理配置。([k8s CRD blog](https://developer.cyberark.com/blog/using-kubernetes-custom-resources-to-configure-secretless/)、[sidecar tutorial](https://docs.secretless.io/Latest/en/Content/Get%20Started/using-kubernetes-secrets.htm))

### 核心模型 / 原理
Secretless 以 **sidecar 容器**进同一个 Pod，与 app 共享 `localhost`，app 连 `localhost:<listenOn>` 即连到 sidecar。配置两种供给方式：
- **ConfigMap（默认）**：把 `secretless.yml` 放进 ConfigMap，挂成 sidecar 的 volume。
- **CRD**：`configurations.secretless.io` CRD 承载配置，sidecar 启动参数 `-config-mgr k8s/crd#<name>` 指向它。

**带编号的数据流（CR/ConfigMap → sidecar → app 看到什么）**：
1. 平台在 Pod spec 里加一个 `cyberark/secretless-broker` sidecar 容器，挂 ConfigMap（或给 `-config-mgr` 指向 CRD）。
2. sidecar 启动读配置 → 在 Pod 的 `localhost` 上按 `listenOn` 开监听。
3. app 容器把 target 地址改成 `localhost:<port>`（**app 看到的"凭据"就是一个本地地址，没有任何密钥**）。
4. app 发连接 → 走 §1 流程，sidecar 注入真凭据连真 target。
5. **配置更新**：CRD 路径下，`kubectl apply` 改 CRD → "Secretless will automatically restart and update its configuration with the new data"（[k8s CRD blog](https://developer.cyberark.com/blog/using-kubernetes-custom-resources-to-configure-secretless/)），无需重挂 volume；ConfigMap 路径则依赖卷更新/重启。

> **与 Connectors 风格 CSI/webhook 的对照（仅事实，不评价）**：Secretless **不渲染工具配置文件、不改 Pod image、无准入 webhook 自动注入**——sidecar 与配置都需在 Pod spec 里**显式声明**。它落到 Pod 的不是"渲染好的 .gitconfig/docker config"，而是"一个监听本地端口的代理进程"。

### 核心能力清单
- sidecar 模式（官方文档只描述 sidecar；**未见独立 daemonset/node-daemon 模式**，标"未确认是否有 daemon 形态"）。
- 配置源：ConfigMap volume 或 `configurations.secretless.io` CRD。
- CRD 改配置 → broker 自动重载。
- 也有 Red Hat 认证镜像（[Red Hat catalog](https://catalog.redhat.com/en/software/containers/cyberark/secretless-broker/5e6f971069aea31642a95648)），可在 OpenShift 跑。

### 最小命令示例
> 未实测，基于官方文档 [k8s CRD blog](https://developer.cyberark.com/blog/using-kubernetes-custom-resources-to-configure-secretless/)

**场景：给一个工作负载加 secretless sidecar，用 CRD 下发配置，改配置免重建 Pod**。三步全部是**平台/运维侧**动作，app 容器只把目标地址改成 `localhost`。

```yaml
# ① 一次性（平台）：apply 配置 CRD（configurations.secretless.io）
apiVersion: secretless.io/v1
kind: Configuration
metadata: { name: my-app-secretless-config }
spec:
  services:
    pg-db:
      connector: pg
      listenOn: tcp://0.0.0.0:5432
      credentials:
        host: pg.internal
        username: { from: kubernetes, get: app-creds#pg-user }
        password: { from: kubernetes, get: app-creds#pg-password }
```
```yaml
# ② 一次性（平台）：Pod spec 同 Pod 放 sidecar，app 改连 localhost
spec:
  containers:
    - name: my-app
      image: my-app:1.0
      env:                                       # app 连本地 sidecar，不带密码
        - { name: PGHOST, value: localhost }
        - { name: PGPORT, value: "5432" }
    - name: secretless
      image: cyberark/secretless-broker:latest
      args: [ "-config-mgr", "k8s/crd#my-app-secretless-config" ]   # 指向 ① 的 CRD
```
```bash
# ③ 变更态（运维）：改 CRD 即热加载，无需重建 Pod
kubectl edit configuration my-app-secretless-config
#    └ 官方原文 "Secretless will automatically restart and update its configuration with the new data"
```

### 一句话本质
**同 Pod sidecar + ConfigMap/CRD 配置，CRD 改配置自动热重载。**

---

## §5 凭据轮换的透明承接（edition: OSS / Apache-2.0；GA）

### 解决什么问题
后端密码被轮换（手动或 rotator）后，传统 app 需要重读配置/重启才能用新密码。Secretless 让这件事对 app 透明。([how-it-works](https://docs.secretless.io/Latest/en/Content/Overview/scl_how_it_works.htm))

### 核心模型 / 原理
**Secretless 不自己造、不自己轮换凭据**——它是消费端。轮换由后端 vault / rotator 完成；Secretless 的承接逻辑是：**每建立一条新连接时，重新向 provider 取当前最新 secret**。官方原文："If a secret is changed either manually or with a rotator, the Broker automatically obtains the new secret and uses it when establishing new connections"（[how-it-works](https://docs.secretless.io/Latest/en/Content/Overview/scl_how_it_works.htm)）。

**带编号的轮换承接流程**：
1. 后端 vault 里 DB 密码从旧值轮换成新值（Secretless 不参与这一步）。
2. app 已有的长连接**不受影响**（数据透传阶段不重取凭据）。
3. app 发起**下一条新连接** → §1 流程第 3 步重新 `from/get` 取凭据 → 拿到的是新密码 → 用新密码完成认证。
4. 因此 rotation 对 client 完全透明，**不需 app 重启**；但生效时点是"下一条新连接"，不是"轮换瞬间作用到在途连接"。

> **边界**：Secretless **不是动态凭据引擎**——它不现造短寿命账号、不发 lease/TTL、不主动 revoke。它对接的后端（如 Conjur/Vault 的动态引擎）若提供短寿命凭据，Secretless 只负责"下一条连接取最新的那一份"。

### 最小命令示例
> 未实测，基于官方文档 [how-it-works](https://docs.secretless.io/Latest/en/Content/Overview/scl_how_it_works.htm)

**场景：后端把 DB 密码轮换掉，app 不重启继续工作**——没有独立的 secretless 命令，轮换动作发生在**后端**，broker 在「下一条新连接」自动取到新值。

```bash
# ① 运维 / rotator：在后端改密码（这里以 K8s Secret 后端为例）
kubectl patch secret app-creds -p '{"stringData":{"pg-password":"new-p@ss-v2"}}'
#    （Conjur/Vault 后端则由其 rotator 自动换，broker 同样无感）

# ② 验证：app 已有的长连接不受影响；下一条新连接由 broker 用新密码完成认证
psql "host=localhost port=5432 dbname=app user=app"   # ✓ 仍成功，app 配置/镜像没动、没重启
#    └ 生效时点 = 下一条新连接，不是「轮换瞬间作用到在途连接」
```

### 一句话本质
**轮换是后端的事；Secretless 只在"下一条新连接"重取最新凭据，对 client 透明。**

---

## §6 Connector Plugin 扩展（edition: OSS / Apache-2.0；GA）

### 解决什么问题
内置只有 pg/mysql/mssql/ssh/http 等少数 connector，要支持其它协议/服务需可扩展。([plugin connector README](https://github.com/cyberark/secretless-broker/blob/main/pkg/secretless/plugin/connector/README.md))

### 核心模型 / 原理
Secretless 暴露 **Plugin Interface**；service connector 以**内置插件**形式编进 binary。第三方实现该接口可加入新 target service 的认证逻辑（接收连接 → 用 provider 取凭据 → 注入认证 → 透传）。([README](https://github.com/cyberark/secretless-broker/blob/main/README.md)、[plugin connector README](https://github.com/cyberark/secretless-broker/blob/main/pkg/secretless/plugin/connector/README.md))

### 核心能力清单
- TCP connector plugin 与 HTTP connector plugin 两类接口。
- 内置 connector 本身也是按这套接口实现的（dogfooding）。
- 扩展需编译进 binary（Go 插件模型）。

### 最小命令示例
> 未实测，基于官方文档 [plugin connector README](https://github.com/cyberark/secretless-broker/blob/main/pkg/secretless/plugin/connector/README.md)

**场景：为内置不支持的协议加一个 TCP connector**——开发者实现 `Connector` 接口、编进 binary（**编译期动作**，不是运行态配置）。

```go
// 开发者实现（编译期）：TCP connector 插件接口（签名见 pkg/secretless/plugin/connector）
type Connector interface {
    // clientConn = app 进来的连接；creds = broker 已用 provider 取好的凭据集
    // 返回到真 target 的「已认证」后端连接，之后由 broker 在两端透传
    Connect(clientConn net.Conn, creds connector.CredentialValuesByID) (net.Conn, error)
}
// HTTP connector 接口则是：Connect(*http.Request, connector.CredentialValuesByID) error
```

### 一句话本质
**实现 Plugin Interface 即可为任意协议加一个认证替身。**

---

## §7 OSS 能力组合回顾 + 许可 / air-gap

**整体回顾**：Secretless Broker 是**单层 Apache-2.0 开源**，没有 Enterprise/付费功能边界——你看到的所有能力（协议代理、8 种 provider、sidecar/CRD 部署、轮换透明承接、插件扩展）都在 OSS 内。它的定位非常聚焦：**把"应用持有并使用凭据"这件事，搬到一个旁路代理进程里**，让 app 连本地端口、永不见真凭据。

它**不做**的（关键边界，避免误判为缺陷）：
- 不存储凭据（不是 vault，凭据来自 `aws`/`conjur`/`vault`/`kubernetes`/`env`/`file`/`literal`/`keychain` 后端）。
- 不造/不轮换/不吊销动态凭据（不是动态引擎，只在新连接重取后端最新值）。
- 无类型化的"工具连接"模型（无 Harbor/GitLab/Nexus 专用 connector）、无资源浏览 API、无 Pipeline UI、无 per-request RBAC 授权、无镜像协议代理 / image 改写。
- 无 OLM bundle 形态（以 DockerHub/Red Hat 镜像 + sidecar 交付）。

**许可 / Fork / air-gap**：
- **许可**：Apache-2.0，单一 edition，无 Enterprise（[README](https://github.com/cyberark/secretless-broker/blob/main/README.md)）。
- **Fork 关系**：CyberArk 维护的独立社区项目（历史上属 Conjur 生态，仓库早期为 `conjurinc/secretless`）。无下游 fork。
- **air-gap**：broker binary 自身无强制外呼；用 `env`/`file`/`literal`/`keychain`/`kubernetes` provider 可完全离线；用 `conjur`/`vault` provider 时需触达对应 vault（vault 本身可离线部署）。
- **维护状态**：活跃。最新 v1.7.32（2026-02-05），近期仍在出安全修复（如 PostgreSQL 协议长度限制防 DoS）（[releases](https://github.com/cyberark/secretless-broker/releases)）。命名上 Conjur 已更名为 **CyberArk Secrets Manager**，README 已对齐（[v1.7.29 起](https://github.com/cyberark/secretless-broker/releases)）。

---

## 附：额外有价值发现（技能范围外）

- **性能开销**：官方 README 明确给出，经 broker 的连接相对直连数据库约 **~9% 吞吐下降**（pgbench：through the broker 比 direct DB connection 少约 9% tps，[README](https://github.com/cyberark/secretless-broker/blob/main/README.md)）——data-plane 代理选型时的参考量级。
- **认证 vs 数据相位分离是其性能/安全设计核心**：Secretless 只在**认证相位**介入并注入凭据，**数据相位是直接 pass-through**（[how-it-works](https://docs.secretless.io/Latest/en/Content/Overview/scl_how_it_works.htm)）。这意味着它对"按每次业务调用做授权/审批/审计"天然无能力——一旦认证完成它就退出业务路径。这是与"全程协议感知代理"（每个请求都过 broker 逻辑）的结构性差异。
- **命名漂移坑**：文档跨 `secretless.io` / `conjur.org` / `docs.cyberark.com` 三个站点，且 Conjur→CyberArk Secrets Manager 更名，HTTP connector 文案里 "Conjur OSS" 与 "CyberArk Secrets Manager" 指同源后端的新旧叫法。检索时三个站点都要看。
- **OpenShift 一等支持**：有 Red Hat 认证容器镜像（[Red Hat catalog](https://catalog.redhat.com/en/software/containers/cyberark/secretless-broker/5e6f971069aea31642a95648)），对 OpenShift 客户是现成路径。

---

**相关文档**：`connectors-vs-secretless-broker.md`（与 Connectors 的对比 + 边界 + roadmap 启发）。
