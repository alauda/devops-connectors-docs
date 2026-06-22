# SPIFFE / SPIRE 能力调研指南（精简版）

> **状态**：已完成（精简深度——SPIFFE/SPIRE 与 Connectors 关系弱，仅作工作负载身份**原语 / benchmark / 集成候选**，不做替代品深挖）
> **覆盖版本**：SPIFFE 规范 + SPIRE（spiffe.io/docs/latest，截至 2026-06-16；未钉具体 release tag，文档为 "latest"）
> **基于源**：官方文档 `spiffe.io/docs` + CNCF 公告（逐条带 URL）
> **edition 范围**：全部 OSS（SPIFFE 规范 + SPIRE 实现均 Apache-2.0，CNCF graduated）；无 Enterprise edition
> **不覆盖**：SPIRE 全部 node/workload attestor 插件清单、全部部署拓扑、SPIFFE Helper / Tornjak UI、service mesh（Istio）集成细节——本指南只覆盖 Connectors 相关核心
> **未实测**：本指南未在集群实跑 demo，命令/YAML 均"未实测，基于官方文档"

本文档**只讲 SPIFFE/SPIRE 自身**：核心抽象、原理、能力边界。**有意写短**。

---

## §0 心智模型 + 能力地图速览

**心智模型（4 行）**：SPIFFE 是一个**厂商中立的工作负载身份规范**——给每个工作负载一个 URI 形态的身份 `spiffe://<trust-domain>/<path>`（SPIFFE ID），用一份可验证文档（SVID，X.509 证书或 JWT）承载它。SPIRE 是该规范的运行时实现：先对**节点**做 attestation、再对节点上的**进程**做 attestation，确认"你是谁"后通过 **Workload API** 把短寿命 SVID 发给工作负载——**整个过程工作负载不需要预置任何 secret**。SPIRE 只**发身份**，不存业务凭据、不做出栈代理。

**许可 / 治理 / air-gap（先记这条）**：SPIFFE 规范仓库与 SPIRE 实现仓库均 **Apache-2.0**（[spire/LICENSE](https://github.com/spiffe/spire/blob/main/LICENSE)）；两者均为 **CNCF Graduated**（2022-08，announced 2022-09-20，[CNCF 公告](https://www.cncf.io/announcements/2022/09/20/spiffe-and-spire-projects-graduate-from-cloud-native-computing-foundation-incubator/)）。纯自托管、无 phone-home、无 license server，**air-gap 友好**（自建 trust domain 即可，不依赖任何外部 IdP；OIDC 联邦才需外部云，见 §6）。

### 能力地图速览（30 秒看全貌）

一行 = 一章。全部 OSS，无付费分表。

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 |
|---|---|---|---|---|---|
| §1 | SPIFFE ID + SVID | 给工作负载一个可验证的身份 | URI 身份编码进 X.509 证书或 JWT | 厂商中立标准 + 两种格式 | 服务间 mTLS / 向云换 token |
| §2 | Trust Domain 模型 | 划定信任根边界 | 一个 trust domain = 一套根密钥 | 边界清晰 + 可跨域联邦 | 一组织一 trust domain |
| §3 | 节点 + 工作负载 attestation | 不预置 secret 也能证明身份 | 先验节点、再验进程 selectors | 多因子证明、零预置密钥 | K8s Pod 凭 SA + 节点属性取身份 |
| §4 | Workload API | 工作负载免密钥拿到 SVID | 本地 unix socket，内核校验调用方 | 调用方无需任何 token | Pod 挂 socket 即取 SVID |
| §5 | SVID 轮换 / 短寿命 | 缩小凭据泄露窗口 | Agent 到半衰期自动续 | 全自动、工作负载无感 | X.509-SVID 默认 1h 自动轮换 |
| §6 | OIDC 联邦（换云/外部 token） | 干掉长寿命云凭据文件 | JWT-SVID 经 OIDC 换云临时凭据 | keyless 访问 AWS/GCP/Azure/Vault | Pod 用 JWT-SVID 换 AWS STS 临时凭据 |

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 理解 SPIFFE ID / SVID 是什么 | §1 |
| 理解信任边界 / 多组织隔离 | §2 |
| Pod 怎么免预置 secret 证明身份 | §3 |
| 工作负载怎么本地拿到 SVID | §4 |
| 凭据多久轮换一次、谁来轮 | §5 |
| 用 SPIRE 身份换 AWS / Vault 凭据 | §6 |

---

## §1 SPIFFE ID 与 SVID（OSS）

### 解决什么问题
工作负载之间互相调用时需要一个**厂商中立、可加密验证**的身份，替代"靠网络位置 / 靠共享密钥"的脆弱身份判定。

### 核心模型
- **SPIFFE ID**：一个 URI，格式 `spiffe://<trust domain>/<workload identifier>`，"唯一且具体地标识一个工作负载"（[spiffe-concepts](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)）。例：`spiffe://acme.com/billing/payments`。
- **SVID**（SPIFFE Verifiable Identity Document）："工作负载用来向调用方证明身份的文档"，把一个 SPIFFE ID 编码进一份**可加密验证**的文档，目前两种格式：**X.509 证书**或 **JWT token**（同上）。

### 核心能力清单
- **X.509-SVID**：含 SPIFFE ID（写在证书 URI SAN）+ 绑定的私钥 + 短寿命 X.509 证书 + 用于验证对端的 trust bundle。适合 mTLS。
- **JWT-SVID**：含 SPIFFE ID + JWT token + trust bundle。适合面向不支持 mTLS 的 L7 / 跨边界（OIDC）场景。
- 两种 SVID 共用同一个 SPIFFE ID 身份语义，按场景选格式。

### 最小命令示例
> 未实测，基于官方文档 [deploying/svids](https://spiffe.io/docs/latest/deploying/svids/)
```bash
# 取 X.509-SVID（证书 + 私钥 + bundle 写到 /tmp）
./spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock -write /tmp/
# 取 JWT-SVID（指定 audience）
./spire-agent api fetch jwt -audience my-audience -socketPath /run/spire/sockets/agent.sock
```

### 一句话本质
SPIFFE ID 是工作负载的 URI 身份，SVID 是装着它的可验证证书 / JWT。

---

## §2 Trust Domain 模型（OSS）

### 解决什么问题
需要一个清晰的**信任根边界**：哪些身份归我管、哪些来自外部组织。

### 核心模型
- **Trust Domain** "对应一个系统的信任根"，代表"运行自己独立 SPIFFE 基础设施的个人 / 组织 / 环境 / 部门"（[spiffe-concepts](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)）。同一 trust domain 内的工作负载都能用该域的根密钥互相验证。
- **跨域信任 = Federation**：两个 trust domain 通过**交换 trust bundle**（公共证书）互信，bundle 经各自的 federation endpoint 获取，认证 profile 为 `https_spiffe` 或 `https_web`（[architecture/federation](https://spiffe.io/docs/latest/architecture/federation/readme/)）。
  - ⚠️ 这里的 **trust-domain federation（SPIRE↔SPIRE）** 与 §6 的 **OIDC federation（SPIRE→云 IdP）** 是两回事，别混。

### 核心能力清单
- 一个 trust domain 一套根 CA / 根签名密钥。
- 跨域：bootstrap 阶段手动 `spire-server bundle show` / `bundle set` 交换 bundle，之后自动经 endpoint 刷新。
- 两种 bundle endpoint 认证 profile：SPIFFE 自验（`https_spiffe`）/ Web PKI（`https_web`）。

### 最小命令示例
> 未实测，基于官方文档 [architecture/federation](https://spiffe.io/docs/latest/architecture/federation/readme/)
```bash
# 域 A 导出自己的 trust bundle
spire-server bundle show -format spiffe > trustdomainA.bundle
# 域 B 导入域 A 的 bundle（建立单向信任）
spire-server bundle set -format spiffe -id spiffe://domainA -path trustdomainA.bundle
```

### 一句话本质
Trust domain 是信任根边界，跨域靠交换 bundle 联邦。

---

## §3 节点 + 工作负载 attestation（OSS）

### 解决什么问题
工作负载要拿身份，但**不能预置长期密钥**去证明"我是我"——否则又回到分发 secret 的老路。

### 核心模型 / 原理（展开：这是 SPIRE 的核心抽象，必须能复述）
SPIRE 用**两段式 attestation**确认身份，先节点后进程：

1. **Node attestation（节点证明）**："每个 agent 首次连 server 时必须认证并验证自己"（[spire-concepts](https://spiffe.io/docs/latest/spire-about/spire-concepts/)）。node attestor "盘问节点及其环境，取只有该节点才有的信息"来证明节点身份（如云厂商身份文档、K8s token）。成功后 **agent 获得一个 SPIFFE ID，该 ID 成为它所管工作负载的 "parent"**。
2. **Workload attestation（工作负载证明）**：回答"这个进程是谁？"。agent "盘问本地权威（节点 OS 内核、或同节点的 kubelet）"取得调用 Workload API 的进程属性。
3. **比对 selectors**：agent 把发现的属性与**注册时声明的 selectors** 比对——"registration entry 把一个身份（SPIFFE ID）映射到一组 selectors，工作负载必须具备这些 selectors 才能被发给特定身份"（同上）。
4. **签发 SVID**：匹配通过 → server 为该进程签发对应 SPIFFE ID 的 SVID，经 agent 经 Workload API 交付。

**状态流转**：`agent 连 server → node attestation → agent 拿到 parent SPIFFE ID → 工作负载调 Workload API → agent 做 workload attestation 取 selectors → 与 registration entry 比对 → 命中则 server 签发 SVID`。整条链路工作负载**零预置 secret**。

### 核心能力清单
- node attestor 多种（K8s、AWS IID、GCP、Azure、TPM、join token 等——清单不展开）。
- workload attestor：K8s（按 ns / SA / pod label 等 selector）、Unix（uid/gid/path）、Docker 等。
- registration entry = `SPIFFE ID + parent ID + selectors`，是身份的授权来源。

### 最小命令示例
> 未实测，基于官方文档 [spire-concepts](https://spiffe.io/docs/latest/spire-about/spire-concepts/) + [getting-started-k8s](https://spiffe.io/docs/latest/try/getting-started-k8s/)
```bash
# 注册一个 K8s 工作负载身份：parent=agent 的 node ID，selectors 限定 ns + SA
spire-server entry create \
  -spiffeID spiffe://example.org/ns/default/sa/myapp \
  -parentID spiffe://example.org/spire/agent/k8s_psat/<cluster>/<node-uid> \
  -selector k8s:ns:default \
  -selector k8s:sa:myapp
```

### 一句话本质
先证明节点、再证明进程；身份靠 attestation 挣来，不靠预置密钥。

---

## §4 Workload API（OSS）

### 解决什么问题
工作负载要拿到 SVID，但**调用取身份的接口时本身还没有任何凭据**——典型的"secret zero / 鸡生蛋"问题。

### 核心模型 / 原理（展开：K8s 数据流，必须画清 CR→驱动→Pod）
Workload API 是一个 **gRPC 接口，经本地 Unix domain socket 暴露**；"不要求调用方有任何显式认证（如 secret）"（[deploying/svids](https://spiffe.io/docs/latest/deploying/svids/)、[spiffe-concepts](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)）。调用方身份靠 **SPIRE Agent 检查内核元数据**（uid/gid/进程信息）来判定，而非靠 token。

**K8s 完整数据流（DaemonSet + CSI 路径）**：
1. **SPIRE Agent 以 DaemonSet 跑在每个节点**，暴露 Workload API 的 Unix socket（如 `/run/spire/sockets/agent.sock`），目录用 hostPath 卷持有（[spiffe-csi](https://github.com/spiffe/spiffe-csi)）。
2. **SPIFFE CSI Driver 也以 DaemonSet 跑在每节点**，唯一职责是把 agent 的 Workload API socket 目录**只读 bind-mount 进工作负载 Pod**的请求路径（同上）。
3. 工作负载 Pod 声明一个 CSI volume → 节点 driver 把 socket 挂进 Pod。
4. **Pod 内进程连这个 socket 调 Workload API** → agent 做 workload attestation（§3）→ 命中 registration entry → 把 SVID（证书+私钥+bundle，或 JWT）流式返回给进程；**Pod 里不出现任何 K8s Secret 对象、不预置任何 token**。
5. SVID 临到期由 agent 经同一 socket 推送新值（§5），进程用 SDK 监听更新。

### 核心能力清单
- gRPC API，protobuf 定义，官方多语言 client（go-spiffe 等）。
- 调用方零 secret，身份靠内核 attestation。
- 三种交付：X.509-SVID（含私钥）/ JWT-SVID / trust bundle（CA 公钥）。
- K8s 下经 SPIFFE CSI Driver 把 socket 挂进 Pod（不建 K8s Secret）。

### 最小命令示例
> 未实测，基于官方文档 [deploying/svids](https://spiffe.io/docs/latest/deploying/svids/)
```bash
# 以某用户身份调 Workload API 取 X.509-SVID（agent 按内核 uid 判定身份）
sudo -u webapp ./spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock -write /tmp/
```
```yaml
# Pod 通过 SPIFFE CSI Driver 挂载 Workload API socket（不建 K8s Secret）
volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true
# 容器 volumeMounts 挂到 /spiffe-workload-api，进程连 socket 取 SVID
```

### 一句话本质
本地 socket 发身份，调用方无需任何 token，agent 用内核元数据认你。

---

## §5 SVID 轮换 / 短寿命（OSS）

### 解决什么问题
身份凭据应**短寿命且自动轮换**，缩小泄露窗口，且不能让工作负载手动续期。

### 核心模型 / 原理
SPIRE Agent **缓存 SVID 并主动监控其生命周期**，到**默认半衰期（生命周期 1/2）触发续期**，经 Workload API 把新 SVID 推给工作负载（[spire_agent doc](https://github.com/spiffe/spire/blob/main/doc/spire_agent.md)，轮换策略；TTL 见下）。工作负载用 go-spiffe 等 SDK 订阅更新，无感切换。

### 核心能力清单
- X.509-SVID 默认 TTL：`default_x509_svid_ttl` 默认 **1h**（[spire_server 配置参考](https://spiffe.io/docs/latest/deploying/spire_server/)）。
  - 注：部分文档示例用 `6h`，但官方配置参考表列默认 **1h**——示例值 ≠ 默认值。
- JWT-SVID 默认 TTL：`default_jwt_svid_ttl` 默认 **5m**（同上）。
- 轮换由 agent 自动完成，默认在生命周期 1/2 处续；阈值可配（经 `availability_target`，仅作用于 agent / workload X.509-SVID；JWT-SVID 不受其影响，见 [spire_agent 配置参考](https://spiffe.io/docs/latest/deploying/spire_agent/)）。
- SVID TTL 受 CA TTL 约束（SVID TTL 应 ≤ CA TTL 的一定比例）。

### 最小命令示例
> 未实测，基于官方文档 [spire_server 配置参考](https://spiffe.io/docs/latest/deploying/spire_server/)
```hcl
server {
  default_x509_svid_ttl = "1h"   # X.509-SVID 默认 1h
  default_jwt_svid_ttl  = "5m"   # JWT-SVID 默认 5m
}
```

### 一句话本质
SVID 短寿命（X.509 默认 1h / JWT 默认 5m），agent 到半衰期自动轮换、工作负载无感。

---

## §6 OIDC 联邦：JWT-SVID 换外部 / 云凭据（OSS）

### 解决什么问题
工作负载要访问 **AWS / GCP / Azure / Vault** 等外部系统，但不想给它分发**长寿命云凭据文件**（最常见的云审计红线）。

### 核心模型 / 原理（展开：keyless 换 token 全链路，必须能复述）
SPIRE 通过 **OIDC Discovery Provider**（独立辅助组件）把自己变成一个**外部可信的 OIDC IdP**，让云厂商用标准 OIDC 验证 JWT-SVID（[keyless/oidc-federation-aws](https://spiffe.io/docs/latest/keyless/oidc-federation-aws/)）：

- OIDC Discovery Provider 暴露两个端点：
  - `/.well-known/openid-configuration`——OIDC 发现文档（含 `issuer`、`jwks_uri`、支持的签名算法 RS256/ES256/ES384）。
  - `/keys`——JWKS，发布 trust domain 的 JWT 签名公钥。

**AWS 换凭据全链路**：
1. 工作负载经 Workload API 取一个 **JWT-SVID**（指定 `audience`，如 `mys3`）：`spire-agent api fetch jwt -audience mys3`。
2. 工作负载把 JWT token 交给 AWS STS（如经 `AWS_WEB_IDENTITY_TOKEN_FILE` 环境变量）发起 `AssumeRoleWithWebIdentity`。
3. **AWS 验证 token**：查 OIDC Discovery Provider 的发现端点拿 issuer + JWKS → 验签 → 确认 token 的 subject（SPIFFE ID）匹配 IAM Role 信任策略里的条件（issuer + audience + 授权的 SPIFFE ID，如 `spiffe://example.org/ns/default/sa/default`）。
4. 验证通过 → **AWS STS 颁发临时 IAM Role 凭据**（短寿命），工作负载拿它访问 S3。**全程无静态云密钥**。

同一模型适用 GCP / Azure WIF / Vault JWT auth（[keyless/vault](https://spiffe.io/docs/latest/keyless/vault/readme/)）。

### 核心能力清单
- OIDC Discovery Provider 暴露 `/.well-known/openid-configuration` + `/keys`（JWKS）。
- JWT-SVID 携带 `aud`（audience）+ `sub`（SPIFFE ID），云侧按二者授权。
- 支持 AWS STS Web Identity / GCP WIF / Azure WIF / HashiCorp Vault JWT auth。
- 把"长寿命云凭据文件"换成"现取的短寿命云 token"。

### 最小命令示例
> 未实测，基于官方文档 [keyless/oidc-federation-aws](https://spiffe.io/docs/latest/keyless/oidc-federation-aws/)
```bash
# 1) 工作负载取一个绑定 audience 的 JWT-SVID
spire-agent api fetch jwt -audience mys3 -socketPath /run/spire/sockets/agent.sock
# 2) 把 JWT 喂给 AWS（AssumeRoleWithWebIdentity）换临时 IAM 凭据，全程无静态 AK/SK
```
IAM Role 信任策略关键条件（基于文档）：限定 `aud=mys3` 且 `sub=spiffe://example.org/ns/default/sa/default`。

### 一句话本质
SPIRE 当 OIDC IdP，工作负载拿 JWT-SVID 换云临时凭据，干掉长寿命云密钥。

---

## §7 OSS 能力组合回顾 + 边界

**SPIFFE/SPIRE 全部 OSS（Apache-2.0，CNCF Graduated），无 Enterprise edition、无付费功能、无 license server。** 一套自托管即得：URI 工作负载身份（SPIFFE ID）+ 两种可验证文档（X.509 / JWT SVID）+ 信任域模型 + 两段式 attestation（节点+进程，零预置 secret）+ Workload API（本地 socket 免 token 取身份）+ 自动短寿命轮换 + OIDC 联邦换云凭据。

**能力边界（SPIRE 明确不做的）**：
- **不存业务凭据**——SPIRE 发的是**身份**（SVID），不是 GitLab token / Harbor robot 密码 / DB 密码。它**不是 secret store、不是动态凭据引擎**。要访问需要业务凭据的系统，靠 §6 OIDC 联邦换外部凭据，或上层自己拿 SVID 做 mTLS。
- **不做出栈代理 / 凭据注入**——SPIRE 把 SVID 交给工作负载后就结束了；工作负载**持有** SVID 私钥 / JWT，自己拿去用。没有"数据面代理在出栈方向注入真凭据、客户端永不接触"这一层。
- **不针对 GitLab / Harbor / Nexus 等 DevOps 工具发凭据**——无任何"为 DevOps 工具现造短寿命账号"的 backend（那是 Vault/Infisical 动态凭据域）。SPIRE 只给工作负载一个可验证身份；该身份能否换到这些工具的访问权，取决于工具侧是否信任 SPIRE 的 OIDC（多数 DevOps 工具不原生信任）。
- **不做镜像拉取改写 / 不做 Pipeline UI 资源浏览 / 不做工具透传 API**——完全在 SPIRE 范围外。

---

## §8 许可 / 治理 / air-gap 边界

- **许可**：SPIFFE 规范仓库与 SPIRE 实现均 **Apache-2.0**（[spire/LICENSE](https://github.com/spiffe/spire/blob/main/LICENSE)、[spiffe repo](https://github.com/spiffe/spiffe)）。无 Enterprise/Fork 双轨，无 BSL/AGPL 陷阱——作为 ISV 可自由嵌入。
- **治理**：CNCF **Graduated**（SPIFFE 2022-08-23 / SPIRE 2022-08-22，[CNCF 公告](https://www.cncf.io/announcements/2022/09/20/spiffe-and-spire-projects-graduate-from-cloud-native-computing-foundation-incubator/)）。厂商中立、规范与实现分离。
- **air-gap 友好度**：✅ 高。自建 trust domain + 自托管 SPIRE Server/Agent，无 phone-home、无外部 license。唯一需外网的能力是 §6 OIDC 联邦的**对端**（公有云 STS）——但这是联邦目标在外网，SPIRE 自身仍可全离线运行；纯内网场景不用 OIDC 联邦即可。

---

## 附：fact-check 处置（2026-06-16）

文档落版后将派独立 Agent 逐条回查官方文档。已主动标注的不确定项：
- **SVID 默认 TTL**：官方配置参考表列 X.509=`1h` / JWT=`5m`；部分文档示例用 `6h`——本指南以配置参考表的默认值为准，并显式提示"示例值 ≠ 默认值"。
- **轮换半衰期（1/2 生命周期）**：来源 `spire_agent.md` + 社区说明，标注为默认策略、阈值可配。
- 未钉具体 SPIRE release tag（文档为 "latest"）。

**相关文档**：`connectors-vs-spiffe-spire.md`（与 Connectors 的关系 / 边界 / 集成候选 / roadmap 启发）。
