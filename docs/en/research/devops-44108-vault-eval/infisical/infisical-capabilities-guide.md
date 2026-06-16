# Infisical 能力调研指南

> **状态**：已完成（持续可追加）
> **覆盖版本**：Infisical v0.158.0 / K8s Operator（CRD 跨 `InfisicalSecret` 与较新的 `InfisicalStaticSecret`，schema 不同，见 §2）（截至 2026-06-16）
> **基于源**：官方文档 `infisical.com/docs` + GitHub 源码 license（逐条带 URL，溯源见 `inputs/02-infisical-research-notes.md`）
> **edition 范围**：OSS（MIT 核心）+ 付费（Cloud Pro / Enterprise、自托管 Enterprise license）
> **不覆盖**：价格数字（以官网 pricing 为准）；与 Connectors / ACP 的对比（见 `connectors-vs-infisical.md`）
> **未实测**：本指南未在集群实跑 demo，命令/YAML 均"基于文档"。

本文档**只讲 Infisical 自身**：它有哪些能力、解决什么问题、适合什么场景、基本原理、哪些收费。

---

## §0 心智模型 + 能力地图速览

**心智模型（3 行）**：Infisical 是一个**集中式 secret 平台**——以 `Organization → Project → Environment → Folder → Secret` 的 KV 层级**存储**凭据，再用十余种方式（K8s Operator / CSI / Agent / CLI / SDK / Secret Sync…）把凭据**交付**给消费者；消费者拿到的是真实可用的明文凭据（静态长寿命，或动态/轮换后的短寿命）。围绕这个 store，它又长出 PKI、KMS、SSH CA、secret 扫描、审批工作流等一揽子安全制品。

**许可 / Fork / air-gap（先记这条）**：核心仓库 **MIT**，但 `ee/` 目录是**专有 Enterprise License**。自托管 OSS 免费、无 user/project 上限；但动态凭据、审批、审计、SSO/SCIM/LDAP、KMIP/HSM 等**自托管也要买 license**。付费 license 默认 phone-home 校验，air-gap 需 Infisical 签发 **offline license key**；license 过期后核心继续跑、EE 功能停用。

### 能力地图速览（30 秒看全貌）

一行 = 一章。先看这里决定往下读哪节。

**一、OSS 基础能力**

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 |
|---|---|---|---|---|---|
| §1 | KV secret 管理 | 替代散落的 `.env`/明文配置 | 分层 path 存取，每条带版本 | 版本化 + 回滚 + 引用复用 | 团队集中存第三方 API key |
| §2 | 交付到 K8s/进程 | 把 secret 喂进工作负载 | Operator/CSI/Agent/CLI → K8s Secret 或文件或 env | 一键同步 + 可选自动滚更 | Deployment `envFrom` 读 Infisical secret |
| §3 | Machine Identity | 工作负载免预埋长期密钥取 token | 多种平台原生认证换短 token | K8s Auth 走 TokenReview | Pod 用 SA 身份登录 Infisical |
| §4 | RBAC + 多租户 | 谁能对哪些 secret 做什么 / 多团队隔离 | 内置角色 + project 硬隔离 | project 间不可互引 | 一实例多团队各自 project |
| §10 | Secret Sync | 把 secret 推到外部系统 | App Connection 单向同步 ~42 目的地 | secret 作单一事实源向下游分发 | 推 secret 到 GitHub Actions/Vercel |
| §11 | PKI / 私有 CA | X.509 全生命周期 | 私有 CA + ACME/EST/SCEP + 自动续期 | cert-manager issuer 可做集群签发器 | 内网服务 mTLS 证书 |
| §12 | KMS / 加密即服务 | 业务不持 key 也能加解密 | key 不出平台，明文进密文出 | AES/RSA/ECC + 签名验签 | 敏感字段加密 |
| §14 | Secret 扫描(CLI) | 代码库泄漏检测 | 扫 `git log -p`，>140 类型 | 免费 CLI + pre-commit hook | CI 里扫提交防泄漏 |

**二、付费能力（Cloud Pro/Enterprise 或自托管 Enterprise license）**

| § | 能力 | 解决什么问题 | 大致逻辑 | edition |
|---|---|---|---|---|
| §5 | 审批工作流 | secret 变更 / 访问取权前置审批 | change request（写时）+ access request（取权时） | Pro/Enterprise |
| §6 | 动态凭据 | 干掉长寿命凭据 | 现要现造短寿命凭据 + lease/TTL/吊销（~29 backend） | **Enterprise** |
| §7 | 凭据轮换 | 长期账号周期换密 | 到点自动换（~22 provider，双相零停机） | Pro |
| §8 | 审计日志 | 谁动了哪个 secret 可追溯 | 操作日志 + 源 IP + 流式到 SIEM | Pro/Enterprise（流式 Enterprise） |
| §9 | SSO/SCIM/LDAP | 企业 IdP 接入与自动开通 | SAML/OIDC/LDAP/SCIM | Pro(SSO)/Enterprise |
| §13 | SSH CA | 短寿命 SSH 证书取代长期 key | host CA + user CA 签发 | 未确认 |
| §15 | Gateway | SaaS 安全触达私网资源 | Relay Server 转发 | **Enterprise** |

> §13 SSH、§14 平台 Radar 扫描、§12 外部 KMS/BYOK 的 edition 一手文档查不到明确出处，标"未确认"。

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 集中存团队 API key / 配置 | §1 |
| 把 secret 喂进 Pod（K8s Secret / 文件 / env） | §2 |
| Pod 怎么免密钥拿 Infisical token | §3 |
| 多团队隔离 + 控制谁能读写 | §4 |
| 改 prod secret 要审批 / 临时申请访问 | §5（付费） |
| CI 现要一次性 DB 账号 | §6（Enterprise） |
| 长期账号定期换密码 | §7（Pro） |
| 谁读过 prod 密码要可追 | §8（付费） |
| 把 secret 同步到 GitHub Actions / 云 SM | §10 |
| 签发 / 管理 X.509 证书、做集群 CA | §11 |
| 加解密敏感字段 / 签名 | §12 |
| 扫代码库防 secret 泄漏 | §14 |

---

## §1 KV secret 管理（OSS）

**解决什么问题**：给长期持有的凭据/配置一个集中、分层、带版本、可回滚的家，替代散落的 `.env` 与明文配置。

**核心模型/原理**：`Organization → Project → Environment(dev/staging/prod) → Folder → Secret`。Project 之间完全隔离；references/imports 只在同 project 内复用。每次改动生成新版本，可回看/回滚。

**核心能力**：分层 KV + folder 分组 · secret 引用/导入 · 版本化（OSS 自托管含；Cloud Free 不含，pricing 列 Pro）· Point-in-Time Recovery 快照恢复（付费 Pro）。

**最小命令示例**（基于文档，[cli/usage](https://infisical.com/docs/cli/usage)）：
```bash
infisical login                                   # 登录
infisical init                                    # 关联本地目录到某 project
infisical secrets set DB_URL=postgres://… --env=dev --path=/app
infisical secrets --env=dev --path=/app           # 列出
infisical secrets get DB_URL --env=dev --path=/app
```

**一句话本质**：带版本和回滚的集中式凭据字典。

---

## §2 凭据交付到 K8s 与进程（OSS）

**解决什么问题**：把 Infisical 里存的 secret 喂进工作负载——落成 K8s Secret、挂成文件、或注入 env。

**核心抽象**：四条并列交付路径，差别只在"凭据最终以什么形态出现在 Pod 里"——K8s Secret 对象 / 挂载文件 / env 变量；但**无论哪条，Pod 拿到的都是明文凭据**（Infisical 不在数据面做代理）。

**处理流程（Operator 路径，最常用；CR → 控制器 → Pod 全链路）**：
1. 在 namespace apply 一个 `InfisicalSecret` CR：声明用哪个 machine identity 认证（`authentication.kubernetesAuth`）、拉哪个 project/env/path、同步成哪个 `managedKubeSecretReferences`（目标 K8s Secret 名）。
2. Infisical operator（集群内 Deployment）**watch 该 CR** → 用 CR 里的 SA 走 Kubernetes Auth 换 Infisical token → 拉对应 secret。
3. operator **创建/更新目标原生 K8s `Secret`**（值 base64=明文）→ 业务 Pod 照常 `envFrom`/volume 消费，对 Infisical 无感知。
4. **刷新**：operator 每 `resyncInterval`（默认 `1m`；`instantUpdates=true` 时 `1h`，最小 5s）回拉一次；Infisical 改了值 → 同步进 K8s Secret。
5. **传导到运行中 Pod**：env 注入的 Secret 改了 kubelet **不会**自动重启 Pod；带 `secrets.infisical.com/auto-reload:"true"` 注解的 Deployment/DaemonSet/StatefulSet，operator 会**触发滚动重启**让新值生效。
- CRD 命名提示：上面这套字段（`authentication.kubernetesAuth` + `managedKubeSecretReferences` + `resyncInterval` + auto-reload）属**文档化的 `InfisicalSecret` CRD**。另有一个较新的 `InfisicalStaticSecret`，**schema 不同**（用 `infisicalAuthRef` 引用独立 `InfisicalAuth`、用 `targets` 而非 `managedKubeSecretReferences`）；还有 `InfisicalPushSecret`/`InfisicalDynamicSecret`。v1alpha1 的老 `InfisicalSecret` 已 deprecated。

**另外三条路径（同抽象，不同落点）**：
- **CSI Provider**（官方，MIT）：Pod 声明 CSI volume → 节点 driver 拉 secret 挂成**文件**，**不建 K8s Secret 对象**（"secret-zero"），仅 static secret。
- **Agent**：sidecar/daemon 把 secret 渲染成模板**文件**、可跑 reload command；Agent Injector（mutating webhook）以 **init container** 注入共享 volume。
- **CLI**：`infisical run` 把 secret 作为 **env** 注入子进程，最轻量。

**最小命令示例**（基于文档）：
```yaml
# InfisicalSecret —— 同步成原生 K8s Secret（字段以文档化的 InfisicalSecret 为准）
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata: { name: app-secrets, namespace: app }
spec:
  resyncInterval: 60
  authentication:
    kubernetesAuth: { identityId: <id>, serviceAccountRef: {name: infisical, namespace: app} }
  managedKubeSecretReferences:
    - secretName: app-secret
      secretNamespace: app
```
```bash
infisical run --env=dev --path=/app -- node server.js     # CLI 注入 env
```

**一句话本质**：Infisical 版"外部 secret 同步器"——凭据最终落进工作负载（K8s Secret / 文件 / env）。

---

## §3 Machine Identity 与认证方法（OSS）

**解决什么问题**：让非人类工作负载免预埋长期密钥地向 Infisical 证明身份并取 short-lived token。

**核心模型/原理**：Machine Identity 实体 → 选一种认证方法 → 拿短期 access token。**Kubernetes Auth**（推荐 K8s 路径）：workload 提交 SA JWT，Infisical 转发 K8s **TokenReview** 校验后发 token。

**核心能力**：Token / Universal（Client ID+Secret）/ Kubernetes / AWS / Azure / GCP / OIDC / SPIFFE / **LDAP Auth** / **JWT Auth**（后两者为官方独立 machine 方法，各有专属登录端点）——均 OSS。

**最小命令示例**（基于文档，[machine-identities](https://infisical.com/docs/documentation/platform/identities/machine-identities)）：
```bash
# Universal Auth：用 Client ID/Secret 换 token
infisical login --method=universal-auth \
  --client-id=<id> --client-secret=<secret>
# Kubernetes Auth：operator/agent 内部用 SA JWT 调 /api/v1/auth/kubernetes-auth/login
```

**一句话本质**：用平台原生身份换 Infisical 短 token。

---

## §4 RBAC + 多租户（OSS；细粒度自定义角色付费）

**解决什么问题**：控制"谁能对哪些 secret 做什么"，并让多团队/多环境互不串。

**核心模型/原理**：subject-action-object 权限（如 `secrets/read`），additive 叠加；角色分 Org 级与 Project 级；Project 是隔离边界（跨 project 不可引用）。

**核心能力**：内置 Org 角色 Admin/Member/No-Access、Project 角色 Admin/Member/Viewer/No-Access（OSS）· Environment/Folder 内部分隔（OSS）· **Custom Roles + 细粒度 conditions**（按 env/secretPath/secretName/tags）= **付费**（Pro advanced RBAC / Enterprise Custom Roles）。

**最小操作示例**：Web UI → Project Settings → Access Control → 选内置角色或（付费）自定义角色 + 加 condition（`secretPath` glob）。

**一句话本质**：粗粒度内置 RBAC 免费，细到 secret 路径的授权要付费；多租户单元是 KV namespace（project）。

---

## §5 审批工作流（付费：Pro / Enterprise）

**解决什么问题**：让敏感 secret 的**变更**或对环境的**访问**先过审批。

**核心抽象**：两类 Policy 把"某个动作"拦成一张待审 Request，攒够 approver 才放行。门控点不同——一个拦"写"，一个拦"取权限"，**都不拦"读/用"**。

**处理流程 A — change request（拦"写 secret"，基于 [pr-workflows](https://infisical.com/docs/documentation/platform/pr-workflows)）**：
1. 管理员对某环境（如 `prod`）建 Change Policy：approvers、最少批准数、Hard/Soft enforcement。
2. 用户改该环境 secret → 改动**不直接落库**，挂成一条 change request（pending）。
3. approver 审：批准数达标 → 状态 approved → **Merge** 把改动真正写进环境；拒绝 → closed、改动丢弃。Soft enforcement 下可 break-glass 绕过，但会通知 approver。

**处理流程 B — access request / JIT（拦"取得权限"，基于 [access-requests](https://infisical.com/docs/documentation/platform/access-controls/access-requests)）**：
1. 管理员建 Access Policy（哪个环境/路径、可申请的权限级别、最大时长、审批链）。
2. 用户申请临时访问（选权限 + 时长）→ 挂 pending。
3. approver（可多步顺序）批准 → 系统**临时授予该用户一段时长的 privilege**；到期自动回收，approver 也可随时 revoke 立即删除该 privilege。

**关键边界**：两条流程都**不是 per-read / per-call 门控**——change request 拦"写 secret 这一刻"，access request 拦"取得权限这一刻"；一旦 secret 写入或 privilege 到手，后续读取/使用不再逐次过审。

**一句话本质**：审批挂在"写 secret"和"取得权限"上，不挂在"每次用凭据"上。

---

## §6 动态凭据（付费：Enterprise）

**解决什么问题**：按需现造短寿命凭据（DB 账号、云 IAM key），用完即焚，缩小泄露窗口。

**核心抽象**：`Dynamic Secret(配置模板) → Lease(一次性凭据实例)`。Dynamic Secret 描述"怎么造"（连哪个后端、用什么常驻管理员凭据、生成什么权限、TTL 多长）；Lease 是"造出来的一份"短寿命凭据，带独立到期时间，可单独续租/吊销。管理员凭据常驻 Infisical，业务永远只拿 Lease。

**处理流程（基于文档）**：
1. 管理员建 Dynamic Secret：填后端连接 + 一段创建语句/策略（如 Postgres `CREATE ROLE … VALID UNTIL`）+ default/max TTL。
2. 消费者请求一份 → Infisical 用常驻管理员凭据连后端，**当场执行创建语句**生成新账号/密钥，记一条 Lease（leaseID + 到期时间）。
3. 凭据交付消费者（K8s 路径见下方 CRD：写进原生 K8s Secret）。
4. 到期前可 renew-lease 续租；用完 delete-lease 主动吊销 → Infisical 连后端**执行删除语句**（`DROP ROLE …`）使其立即失效；不续则到 max-TTL 自动回收。

**DevOps 工具覆盖（GitLab / Harbor / Nexus）**：据 dynamic-secrets 文档目录，**29 种 backend** 集中在 **DB（Postgres/MySQL/MSSQL/Oracle/Mongo/Redis/Cassandra/Snowflake…16 种）+ 云 IAM（AWS iam/elasticache/memorydb、GCP IAM、Azure entra/sql、6 种）+ Kubernetes/LDAP/RabbitMQ/SSH/TOTP/IBM API Connect**，SaaS 侧仅 **GitHub（App token）**。**无 GitLab / Harbor / Nexus 专用动态凭据 backend** —— 这三个 DevOps 工具的短寿命凭据 Infisical **不原生覆盖**（Vault 生态另有 GitLab secrets engine，但属社区插件、非内置，未确认）。要给它们做动态凭据需自己包一层。

**最小命令示例**（K8s 消费，[InfisicalDynamicSecret CRD](https://infisical.com/docs/integrations/platforms/kubernetes/infisical-dynamic-secret-crd)）：
```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalDynamicSecret
spec:
  dynamicSecret: { secretName: dyn-db, projectId: <id>, environmentSlug: dev, secretsPath: /db }
  leaseTTL: 1h            # 必须 < 1 天；operator 到期前自动重建 Lease
  managedSecretReference: { secretName: db-creds, secretNamespace: app }
# operator 流程：建 Lease → 写 db-creds(原生 K8s Secret，base64=明文) → 临到期重建 Lease 刷新 → 可选 auto-reload 滚动重启消费 Pod
```

**一句话本质**：现造短寿命明文凭据 + 自动吊销（"短到不值得偷"，但凭据仍落进工作负载）；DevOps 工具只覆盖 GitHub，GitLab/Harbor/Nexus 无原生 backend。

---

## §7 凭据轮换（付费：Pro）

**解决什么问题**：周期性轮换长寿命凭据，限制单条有效期。

**核心抽象**：轮换的是**同一个账号的密钥/密码**（账号名不变），不像动态凭据那样新建/销毁账号。`Rotation(配置) → 当前 active 值 + 上一个 inactive 值` 双版本并存，给在途消费一个过渡窗口。

**处理流程（Dual-Phase，零停机，多数 provider；基于文档）**：
1. 配 Rotation：选 provider + 连接 + Rotation Interval（天）+ Rotate At（时刻）。
2. 到点 Infisical 连后端**生成新密钥并写回后端**，把它设为 **active**，旧值降为 **inactive**（仍可用，留过渡窗口）。
3. 消费者下次读到的是 active 新值；上一轮 inactive 值在下次轮换时才 **revoked**。
- **Single-Phase**（少数 provider）：旧值立即失效、无过渡窗口，文档建议关掉自动轮换。生命周期统一是 `active → inactive → revoked`。

**DevOps 工具覆盖（GitLab / Harbor / Nexus）**：据 secret-rotation 文档目录（约 23 个，含一个 mysql 重复，去重 ~22 个 provider），分四类 —— **云/IdP 客户端密钥（AWS IAM User / Azure·Auth0·Okta·Databricks·Salesforce）+ DB（Postgres/MySQL/MSSQL/Oracle/Redis/Mongo）+ LDAP password + Windows·HP iLO·Unix 本地账号**，外加一批 **SaaS API-key（Datadog / SendGrid / Supabase / Convex / dbt / OpenRouter）**。**无 GitLab / Harbor / Nexus 专用轮换 provider** —— 这三个工具的凭据轮换 Infisical **不原生覆盖**。

> edition：pricing 列 "Secret Rotation — Pro"，但官方功能页无 edition banner，免费自托管归属有争议（[issue #2043](https://github.com/Infisical/infisical/issues/2043)）——标 Pro 但带不确定。

**最小操作示例**：Project → Secret Rotation → New Rotation → 选 provider + 连接 + interval。

**一句话本质**：同账号密钥双版本周期轮换、零停机过渡；DevOps 工具同样无 GitLab/Harbor/Nexus 原生 provider。

---

## §8 审计日志（付费：Pro/Enterprise；流式 Enterprise）

**解决什么问题**：留存"谁、何时、对哪个 secret、做了什么、从哪个 IP"的可追溯记录。

**核心模型/原理**：记录 actor（user/identity）+ action（如 `create-secret`）+ project + userAgent(web/CLI/SDK) + 源 IP + 时间戳。保留 Pro 90 天 / Enterprise 自定义（"90 天"出处是 [pricing](https://infisical.com/pricing)，audit 页只说 "varying retention"）。**审计日志流式 = Enterprise**：Splunk / Datadog / Microsoft Sentinel / Cribl / Better Stack / Palo Alto XSIAM / 自定义 HTTP。

**最小操作示例**：Organization → Audit Logs（筛 actor/action/project）；流式：Org Settings → Audit Log Streams → 配目的地。

**一句话本质**：记录的是"在 Infisical 里对 secret 的操作"，整块能力付费。

---

## §9 SSO / SCIM / LDAP（付费）

**解决什么问题**：企业 IdP 接入与用户自动开通。

**核心能力**：SAML SSO / OIDC SSO（人类登录）= Pro/Enterprise（注意 **Google/GitHub SSO 免费**）· LDAP 人类认证 = Enterprise · SCIM 自动开通 = Enterprise。

**一句话本质**：企业级 IdP 接入全是付费。

---

## §10 Secret Sync（OSS/Cloud）

**解决什么问题**：把 Infisical 里的 secret **单向推送**到第三方系统，让那些系统用各自原生方式消费。

**核心模型/原理**：基于 App Connections 的单向同步，约 **42 个目的地** ~10 类：AWS Param Store/Secrets Manager、Azure KV/App Config、GCP SM、Vercel/Netlify/Railway/Heroku、GitHub Actions/GitLab/Azure DevOps/CircleCI、Terraform Cloud、HashiCorp Vault、1Password 等。

**最小操作示例**：Project → Integrations → Secret Syncs → New（选 App Connection + 源 env/path + 目的地）。

**一句话本质**：secret 作单一事实源，向 ~42 个下游平台分发（与"拉取型"同步方向相反）。

---

## §11 PKI / 私有 CA（OSS core；ML-DSA 后量子为 Enterprise）

**解决什么问题**：组织级 X.509 证书全生命周期管理。

**核心能力**（[pki/overview](https://infisical.com/docs/documentation/platform/pki/overview)）：私有 CA 层级 / 接外部 CA（DigiCert、Let's Encrypt、AWS PCA）· 签发走 **API / ACME / EST / SCEP** · 自动续期 + 到期告警（Slack/PagerDuty/webhook）· 把证书 push 到 AWS ACM/Azure KV/Cloudflare · 官方 **cert-manager issuer**（`Infisical/infisical-issuer`）可做集群证书签发器 · ML-DSA 后量子签名 = Enterprise。

**最小命令示例**（基于文档，cert-manager issuer）：
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
spec:
  issuerRef: { group: infisical-issuer.infisical.com, kind: Issuer, name: infisical-issuer }
  secretName: app-tls
  dnsNames: [app.svc.cluster.local]
```

**一句话本质**：私有 CA + 多协议签发 + cluster issuer，证书全生命周期。

---

## §12 KMS / 加密即服务（OSS core；HSM/KMIP/ML-DSA 为 Enterprise）

**解决什么问题**：业务不持加密 key 也能加解密 / 签名。

**核心能力**（[kms/overview](https://infisical.com/docs/documentation/platform/kms/overview)）：encrypt/decrypt as a service（AES-256/128-GCM）· RSA/ECC 签名验签 · key 不可导出、操作不落盘 · HSM 根密钥保护 / KMIP = Enterprise · 外部 KMS（AWS/GCP）/ BYOK = 未确认。

**最小命令示例**（基于文档，REST）：
```bash
curl -H "Authorization: Bearer $TOKEN" \
  -d '{"plaintext":"<base64>"}' \
  https://app.infisical.com/api/v1/kms/keys/<keyId>/encrypt
```

**一句话本质**：加密即服务，key 永不出平台。

---

## §13 SSH CA（edition 未确认）

**解决什么问题**：用短寿命、身份绑定的 SSH 证书取代长期 SSH key。

**核心能力**（[ssh/overview](https://infisical.com/docs/documentation/platform/ssh/overview)，概览页直连 404、引自搜索片段，轻度来源）：SSH CA 签发短寿命证书 · host CA + user CA 双 CA · `infisical ssh connect` · `/ssh/sign`、`/ssh/issue` · 现归入更大的 PAM（session recording 等，likely Enterprise，无一手 tier quote）。

**最小命令示例**（基于文档）：`infisical ssh connect --host <host>`（取一次性证书登录）。

**一句话本质**：SSH 证书化访问，取代长期 key。

---

## §14 Secret 扫描（CLI=OSS；平台 Radar 未确认）

**解决什么问题**：检测代码库 / 提交里的 secret 泄漏。

**核心能力**：CLI `infisical scan`（扫 repo/目录/文件，>140 类型，解析 `git log -p`，pre-commit hook）= OSS 免费 · 忽略机制用**自有 `infisical-scan:ignore`** pragma（**不**兼容 `gitleaks:ignore`，那是未实现的请求 [issue #2904](https://github.com/Infisical/infisical/issues/2904)）· 平台 "Radar" 持续扫描接 GitHub/GitLab/Bitbucket 实时监控 = tier 未确认。

> 与 gitleaks 的关系：>140 类型 + `git log -p` + ignore-pragma 模型强证据指向 gitleaks 衍生，但官方未明文 fork/维护——不要写"Infisical 维护 gitleaks"。

**最小命令示例**（[cli/scanning-overview](https://infisical.com/docs/cli/scanning-overview)）：
```bash
infisical scan                      # 扫当前仓库历史
infisical scan git-changes          # 扫未提交改动
infisical scan install --pre-commit-hook
```

**一句话本质**：免费 CLI 泄漏扫描 + 平台侧仓库监控。

---

## §15 Gateway（付费：Enterprise）

**解决什么问题**：让 Infisical（尤其 SaaS）安全触达私网里的资源（如私网 DB 做动态凭据），无需开放入站。

**核心能力**（[gateways/overview](https://infisical.com/docs/documentation/platform/gateways/overview)）：在私网部署 Gateway，Relay Server 转发加密流量、不检视不存储。*"Gateway is a paid feature available under the Enterprise Tier"*。

**一句话本质**：SaaS 反向触达私网资源的 relay。

---

## §16 SDK / IaC 生态（OSS）

SDK：Node / Python / Java / .NET / C++ / Rust / Go / PHP / Ruby；官方 Terraform provider、Ansible collection（[sdks/overview](https://infisical.com/docs/sdks/overview)）。**一句话本质**：作为应用层 secret SDK，语言/IaC 覆盖面广。

---

## §17 OSS 能力组合回顾

OSS（MIT 核心、自托管免费、无 user/project 上限）真正包含：核心 KV + 版本化、K8s Operator/CSI/Agent/CLI 交付、Machine Identity 全部认证方法、内置粗粒度 RBAC、project 多租户隔离、Secret Sync、PKI 基础、KMS 基础、CLI secret 扫描、SDK/Terraform/Ansible。对"想要一个免费 secret store + K8s 同步 + PKI + 扫描"的 air-gap 客户，OSS 核心够用且干净。

**OSS 边界（这些要付费）**：动态凭据（Enterprise）、凭据轮换（Pro）、审批工作流（Pro/Ent）、审计日志（Pro/Ent）、SSO/SCIM/LDAP、细粒度自定义 RBAC、PITR、Gateway、HSM/KMIP。自托管解锁这些需 Enterprise license，air-gap 需 offline license。

---

## §18 许可 / Fork / air-gap 边界

- **许可**：核心 MIT；`ee/` 目录专有 Enterprise License（[README](https://github.com/Infisical/infisical) / [ee/LICENSE.md](https://github.com/Infisical/infisical/blob/main/backend/src/ee/LICENSE.md)）。
- **无上游 fork 关系**：Infisical 是独立产品（非某闭源产品的 fork），自身是 External Secrets Operator 的一个 provider，但官方建议新项目用自家 native operator。
- **air-gap**：OSS 核心 Docker/Helm 离线自托管（Postgres+Redis）；付费功能 license 默认 phone-home，air-gap 需 offline license key；过期后核心继续跑、EE 停用（[self-hosting/ee](https://infisical.com/docs/self-hosting/ee)）。

---

## 附：fact-check 处置（2026-06-16）

文档落版后派独立 Agent 逐条回查官方文档。已修正 3 处硬错：LDAP/JWT Auth 实为官方独立认证法（曾误标未确认）；secret 扫描用 `infisical-scan:ignore` 而非兼容 gitleaks 指令；rotation provider ~22 而非 ~17。保留的不确定项（确无一手出处）：SSH edition、平台 Radar tier、外部 KMS/BYOK、rotation edition。详见 `inputs/02-infisical-research-notes.md`。

§2/§5/§6/§7 扩写后**再次**派独立 Agent 核对：机制/流程全部有据；**最关键的"§6 无 GitLab/Harbor/Nexus 动态凭据 backend、SaaS 仅 GitHub"与"§7 无 GitLab/Harbor/Nexus 轮换 provider"经 GitHub docs 目录全清单核实，准确**。据此修正：§2 CRD 命名/字段对齐到文档化的 `InfisicalSecret`（原误挂 `InfisicalStaticSecret` 名下）；§6 补 IBM API Connect；§7 补 SaaS API-key provider（Datadog/SendGrid/Supabase 等）、计数口径 23 文件/~22 去重。

**相关文档**：`connectors-vs-infisical.md`（与 Connectors 的对比 + 边界 + roadmap 启发）· `inputs/02-infisical-research-notes.md`（带 URL 原始笔记）。
