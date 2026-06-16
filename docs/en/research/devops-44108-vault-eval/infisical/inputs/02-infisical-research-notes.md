# Infisical 调研原始笔记（带 URL，供 fact-check 溯源）

> 来源：2026-06-16 派发 4 个独立 research Agent 抓 Infisical 官方文档（`infisical.com/docs`）+ GitHub 源码 license 得到的结构化笔记。
> 每条断言尽量带官方 URL + 引用原文，并标注 edition（OSS / Paid-Cloud / Paid-Enterprise / Uncertain）。
> 能力指南 `infisical-capabilities-guide.md` 与对比 `connectors-vs-infisical.md` 的事实都从这里取；二次核对时回到本文件比对 URL。

## Edition 框架（唯一的"硬"一手锚点）

- Infisical 核心仓库 **MIT 协议**，但 `ee/` 目录例外，是**专有 Enterprise License**：
  README — *"This repo available under the MIT expat license, with the exception of the `ee` directory which will contain premium enterprise features requiring a Infisical license"* — https://github.com/Infisical/infisical
  `backend/src/ee/LICENSE.md` — *"may only be used in production, if you… have a valid Infisical Enterprise License"*；dev/test 可免许可。
- Cloud SaaS 分层：**Free / Pro / Enterprise** — https://infisical.com/pricing
- 自托管：OSS 功能免费；付费功能需 `LICENSE_KEY`，**会 phone-home** 校验（air-gap 需向 Infisical 销售申请 **offline license key**）：
  *"Your Infisical instance will need to communicate with the Infisical license server to validate the license key."* / *"The system will automatically detect that it's an offline license based on the key format"* / 过期后 *"Infisical will continue to run, but EE features will be disabled"* — https://infisical.com/docs/self-hosting/ee
- **关键 wedge**：很多治理/身份/动态能力即使你**自托管也要买 license**（每个功能页都写 "contact sales@infisical.com to purchase an enterprise license"）。"自托管 = 全免费" 对这些功能为假。

---

## Cluster A — K8s 交付 / edition / air-gap / onboarding

- 层级模型 **Organization → Project → Environment → Folder → Secret** `[OSS]` — https://infisical.com/docs/documentation/guides/organization-structure
- 引用 / 导入（references / imports，仅同 project 内）`[OSS]` — 同上
- Secret 版本化（每次改动新版本，可回滚）`[OSS（PITR 为 Pro）；部分三方 teardown 把 versioning 列 Pro，存歧义]` — https://infisical.com/docs/documentation/platform/secret-versioning
- Point-in-Time Recovery（快照恢复）`[Paid-Cloud Pro / Paid-Enterprise 自托管]` — *"Point-in-Time Recovery is a paid feature. If you're using Infisical Cloud, then it is available under the Pro Tier. If you're self-hosting… contact sales@infisical.com"* — https://infisical.com/docs/documentation/platform/pit-recovery
- **K8s Operator CRD（当前 v1beta1）**：`InfisicalStaticSecret` / `InfisicalConnection` / `InfisicalAuth`；`v1alpha1` 的 `InfisicalSecret` 已 deprecated；`InfisicalPushSecret` / `InfisicalDynamicSecret` 仍活跃 `[OSS operator]` — https://infisical.com/docs/integrations/platforms/kubernetes/overview
- **交付 = 创建原生 K8s Secret**，workload 照常从 env/volume 读明文 `[OSS]` — `managedKubeSecretReferences`，operator "ensure it stays up-to-date" — https://infisical.com/docs/integrations/platforms/kubernetes/infisical-secret-crd
- `resyncInterval` 默认 `1m`（`instantUpdates=false`）/ `1h`（`instantUpdates=true`），最小 5s `[OSS]` — 同上
- `secrets.infisical.com/auto-reload: "true"` → operator 对消费该 secret 的 Deployment/DaemonSet/StatefulSet 触发 **rolling restart**（opt-in）`[OSS]` — 同上
- **Infisical Agent**：daemon，machine identity 认证，把 secret 渲染成**模板文件**（Go text/template），可跑 reload command；Agent Injector（mutating webhook）以 **init container** 注入、写共享 volume `[OSS]` — https://infisical.com/docs/integrations/platforms/infisical-agent ；https://infisical.com/docs/documentation/platform/secrets-mgmt/concepts/secrets-delivery
- **Infisical CLI**：`infisical run` 把 secret 作为 **环境变量** 注入子进程 `[OSS]` — https://infisical.com/docs/cli/usage
- **官方 CSI Provider**（`Infisical/infisical-csi-provider`，**MIT**）：以文件挂载，**不需要 K8s Secret 对象**（"secret-zero"），**仅支持 static secret** `[OSS]` — https://github.com/Infisical/infisical-csi-provider/blob/main/LICENSE ；https://infisical.com/docs/integrations/platforms/kubernetes-csi
- imagePullSecret：可用 `secretType: kubernetes.io/dockerconfigjson` 生成 `[OSS]`，但 **Pod/SA 仍须自己引用**该 secret；**没有任何 image-rewrite / 透明私有镜像拉取机制（CONFIRMED 缺失）** — 唯一 mutating webhook 是 Agent Injector（注 init container，不改 image）— https://infisical.com/docs/documentation/platform/secrets-mgmt/concepts/secrets-delivery
- 付费门控（自托管也需 license）：**Dynamic Secrets / SCIM / LDAP / Approval workflows / KMIP / HSM** = `[Paid-Enterprise]`；**SAML SSO / RBAC custom roles / IP allowlist / 90-day audit / PIT recovery** = `[Paid-Cloud Pro / Paid-Enterprise]`
- 自托管部署：Docker / Helm（Postgres + Redis）`[OSS]` — https://infisical.com/docs/self-hosting
- 新工具 onboarding：本质是"存一个 KV secret + 选一种交付/同步方式"，**没有 per-tool connector 类型**；它交付的是凭据，**不代理工具流量** — https://infisical.com/docs/documentation/platform/secrets-mgmt/concepts/secrets-delivery
- 低置信：精确价位/分层映射多来自三方 2026 teardown（dev.to/beton），**官方 pricing 页未逐条 quote**；"OSS 核心完全离线零 phone-home" 是 MIT + offline-license 的推断，官方未对免费功能集明文声明。

## Cluster B — Machine Identity / RBAC / 多租户 / 审计

- Machine Identity（拿 short-lived access token）`[OSS]` — https://infisical.com/docs/documentation/platform/identities/machine-identities
- 认证方法（均未标付费，视为 OSS）：Token / Universal（Client ID+Secret）/ **Kubernetes**（SA token → Infisical 转发 K8s TokenReview）/ AWS / Azure / GCP / OIDC / SPIFFE — 同上 + https://infisical.com/docs/documentation/platform/identities/kubernetes-auth
  - **LDAP Auth + JWT Auth 亦为官方独立 machine-identity 方法**（fact-check 更正：早期误标 UNVERIFIED）— [ldap-auth](https://infisical.com/docs/documentation/platform/identities/ldap-auth)（machine identity 配 LDAP directory，区别于人类 SSO LDAP）；[jwt-auth](https://infisical.com/docs/documentation/platform/identities/jwt-auth)（专属 `/api/v1/auth/jwt-auth/login`，独立于 OIDC/SPIFFE）
- 推荐 K8s 路径 = Kubernetes Auth（workload 读 SA JWT，Infisical 走 TokenReview 校验）`[OSS]` — https://infisical.com/docs/documentation/platform/identities/kubernetes-auth
- RBAC 内置角色：Org（Admin/Member/No Access）、Project（Admin/Member/Viewer/No Access）`[OSS]`；权限是 additive，subject-action-object（如 `secrets/read`）— https://infisical.com/docs/documentation/platform/access-controls/role-based-access-controls ；https://infisical.com/docs/internals/permissions
- **Custom Roles / 细粒度 conditions（per env / secretPath / secretName / tags，`$eq/$ne/$in/$glob`）= Paid**（Pro "advanced RBAC"，Enterprise "Custom Roles"）— https://infisical.com/pricing
- 多租户：Project 是隔离边界（*"Projects are isolated from one another… cannot be shared or referenced across different projects"*）`[OSS]`；**语义是 KV namespace，没有 "tool instance → credential" 对象** — https://infisical.com/docs/documentation/guides/organization-structure
- **审计日志 = 付费（自托管也要 license）** `[Paid-Cloud Pro/Enterprise / Paid-Enterprise]`：记录 actor / action（如 `create-secret`）/ project / userAgent(web/CLI/SDK) / 源 IP / 时间戳；保留 Pro 90 天、Enterprise 自定义 — https://infisical.com/docs/documentation/platform/audit-logs ；https://infisical.com/pricing
- **审计日志流式 = Enterprise only**：Splunk / Datadog / Microsoft Sentinel / Cribl / Better Stack / Palo Alto XSIAM / 自定义 HTTP — https://infisical.com/docs/documentation/platform/audit-log-streams/audit-log-streams
- SSO：SAML/OIDC `[Paid-Cloud Pro / Paid-Enterprise]`，LDAP 人类 `[Paid-Enterprise]`，SCIM `[Paid-Enterprise]` — https://infisical.com/docs/documentation/platform/sso/overview ；.../ldap/overview ；pricing
- Secret Sharing `[Free core；自定义 branding 为 Enterprise]` — https://infisical.com/pricing
- Access Requests（临时/JIT 访问 project）`[Paid Pro/Enterprise]` — https://infisical.com/docs/documentation/platform/access-controls/access-requests
- IP Allowlisting（machine identity 的 trusted IP）`[Paid Pro]` — https://infisical.com/docs/documentation/platform/identities/universal-auth

## Cluster C — 审批 / 动态凭据 / 轮换

- **Secret approval policies / change requests** `[Paid Pro/Enterprise]`：*"This feature is available under the Pro Tier and Enterprise Tier"*；**门控点 = secret 改动提交到环境的那一刻**（改动挂成 change request，须满足 approver 阈值才能 Merge）；可配 approvers / 目标环境 / self-approve / bypass；Hard vs Soft enforcement(轻度佐证) — https://infisical.com/docs/documentation/platform/pr-workflows
- **Access approval policies / access requests（JIT）** `[Paid Pro/Enterprise]`：**门控点 = 授予 privilege 的那一刻**；支持多步顺序审批；approver 可改时长、可随时 revoke（立即删 privilege）— https://infisical.com/docs/documentation/platform/access-controls/access-requests
  - **两种审批都不是 per-read / per-call 门控**：change-request 门控"写 secret"，access-request 门控"取得权限"。对比 Connectors ApprovalTask 是在 PipelineRun 内门控"每次经 proxy 调用工具"（运行时、按调用）。
- **Dynamic Secrets** `[Paid-Enterprise]`：*"Dynamic Secrets is a paid feature"*，Cloud 需 Enterprise Tier — https://infisical.com/docs/documentation/platform/dynamic-secrets/overview
  - backend（约 29 种）：PostgreSQL/MySQL/MSSQL/OracleDB/MongoDB/MongoDB Atlas/Cassandra/Redis/ClickHouse/Couchbase/Elasticsearch/Milvus/Snowflake/Vertica/SAP ASE/SAP HANA/Azure SQL/AWS IAM/AWS ElastiCache/AWS MemoryDB/GCP IAM/Azure Entra ID/Kubernetes/LDAP/RabbitMQ/GitHub/IBM API Connect/SSH/TOTP — https://github.com/Infisical/infisical/tree/main/docs/documentation/platform/dynamic-secrets
  - lease：default-TTL / max-TTL，可 create/renew/delete lease；`InfisicalDynamicSecret` CRD 把 lease 同步成**原生 K8s Secret**，`leaseTTL` 须 < 1 天，到期前自动轮换，可 auto-reload 触发 rolling update — https://infisical.com/docs/integrations/platforms/kubernetes/infisical-dynamic-secret-crd
- **Secret Rotation** `[Pro（pricing 列 "Secret Rotation — Pro"）；Cluster C 官方功能页无 edition banner → 标轻度不确定]`：约 **22** provider（fact-check 实点 GitHub docs `secret-rotation/`，早期 ~17 偏低；AWS IAM User / Azure Client Secret / Auth0 / Okta / Databricks / Postgres / MySQL·MariaDB / MSSQL / Oracle / Redis / LDAP password / Windows/Unix local account 等）；Rotation Interval(天)+Rotate At；Dual-Phase（零停机）vs Single-Phase；active→inactive→revoked — https://infisical.com/docs/documentation/platform/secret-rotation/overview ；https://infisical.com/pricing
- **关键对比结论**：动态凭据 / 轮换都让 workload **仍持有真实可用的明文凭据**（只是短寿命 + 自动吊销）。`InfisicalDynamicSecret` 把 lease 写成 K8s Secret 的 base64（= 明文）。所以 Infisical 收益是"短寿命明文 + 自动吊销"，**不是"凭据缺席"**；proxy 模型才能宣称 workload 永不持有真凭据。
- 低置信：secret rotation edition（官方页无 banner）；change-request Hard/Soft 字样（搜索片段佐证）；动态凭据各 backend 精确 TTL 数值。

## Cluster D — Connectors 问题域之外的 Infisical 能力（"有价值的额外内容"）

- **PKI** `[OSS core / Cloud Free；ML-DSA 后量子签名为 Enterprise]`：X.509 全生命周期；私有 CA 层级或接 DigiCert/Let's Encrypt/AWS PCA；签发走 **API / ACME / EST / SCEP**；自动续期；到期告警 Slack/PagerDuty/webhook；把证书 push 到 AWS ACM/Azure KV/Cloudflare；基础设施证书清点扫描 — https://infisical.com/docs/documentation/platform/pki/overview
  - **官方 cert-manager issuer**（`Infisical/infisical-issuer`）→ 可做 K8s 集群证书签发器 — https://github.com/Infisical/infisical-issuer
- **KMS** `[OSS core；ML-DSA / HSM / KMIP 为 Enterprise；外部 KMS/BYOK UNVERIFIED]`：encrypt/decrypt as a service（AES-256/128-GCM）、RSA/ECC 签名验签，*"Keys… not extractable"*，操作不落盘 — https://infisical.com/docs/documentation/platform/kms/overview ；HSM/KMIP 见 https://infisical.com/pricing
- **SSH** `[edition UNVERIFIED；SSH 概览页直连 404，引自搜索片段]`：SSH CA 签发**短寿命、身份绑定**证书取代长期 SSH key；host CA + user CA 双 CA；`infisical ssh connect`；`/ssh/sign`、`/ssh/issue`；现归入更大的 **PAM**（session recording 等，likely Enterprise，无一手 tier quote）— https://infisical.com/docs/documentation/platform/ssh/overview ；https://github.com/Infisical/infisical/pull/2830
- **Secret Scanning**：
  - CLI `infisical scan` `[OSS 免费]`：扫 repo/目录/文件，>140 种 secret 类型，解析 `git log -p`，pre-commit hook，`git-changes` — https://infisical.com/docs/cli/scanning-overview
  - 忽略机制 = **自有 `infisical-scan:ignore`**（fact-check 更正：**不** honor `gitleaks:ignore` / `gitleaksAllowSignature`，那是未实现的社区请求 [issue #2904](https://github.com/Infisical/infisical/issues/2904)）
  - 与 **gitleaks 的关系 = 强证据（>140 类型 + `git log -p` + ignore-pragma 模型）但官方未明文 fork/维护（UNVERIFIED 不要写"fork/维护"，也不要写"兼容 gitleaks 指令"）**
  - 平台 "Radar" 持续扫描 `[tier UNVERIFIED]`：接 GitHub/GitLab/Bitbucket 实时监控仓库泄漏，按 commit diff 扫，finding 可 resolve/ignore/false-positive — https://infisical.com/docs/documentation/platform/secret-scanning/overview
- **Secret Sync（把 secret 推出去，方向与 ESO/Connectors 的拉取相反）** `[OSS / Cloud]`：基于 App Connections 单向同步，约 **42 个目的地** ~10 类（AWS Param Store/Secrets Manager、Azure KV/App Config、GCP SM、Vercel/Netlify/Railway/Fly/Render/Heroku、GitHub Actions/GitLab/Azure DevOps/CircleCI/Bitbucket、Terraform Cloud、Databricks、HashiCorp Vault、1Password 等）— https://infisical.com/docs/integrations/secret-syncs/overview
- **Gateway** `[Paid-Enterprise]`：*"Gateway is a paid feature available under the Enterprise Tier"*；Relay Server 让 Infisical SaaS 安全到达私网资源（主要为私网动态凭据 backend）— https://infisical.com/docs/documentation/platform/gateways/overview
- **SDK / IaC 生态** `[OSS]`：SDK = Node/Python/Java/.NET/C++/Rust/Go/PHP/Ruby；官方 Terraform provider、Ansible collection — https://infisical.com/docs/sdks/overview
- **ESO 关系**：Infisical 是 External Secrets Operator 的一等 provider，但官方建议新项目用**自家 native operator** — *"For new, Infisical-focused setups, the native Infisical Kubernetes Operator is generally recommended."* — https://infisical.com/docs/documentation/platform/secrets-mgmt/concepts/secrets-delivery
- 低置信：gitleaks fork 措辞、KMS 外部 KMS/BYOK edition、SSH tier、Radar tier、PKI 各 tier 限额、Secret Sync tier；honey tokens / agent vault / code signing 仅见 README feature list，无 detail/edition。
