# Vault 能力调研指南

> 本文档独立于 `REPORT.md`（最终结论 / 决策），用于**沉淀对 Vault 能力的理解**。
>
> **结构约定**：
> - §1-§3 是 Vault 通用基础能力（KV / 动态凭据 / K8s Auth），子标题用 "**关键概念**" 风格（偏术语字典）
> - §4 起按 "**核心能力清单**" 风格组织——每条能力一段 `痛点 → 怎么解 → 差别 → 理解`，最贴近"能解决哪些工程问题"
> - §6 是 OSS 部分收尾回顾；§7-§10 是 Pod 集成路径与选型；§11-§13 是 Vault Enterprise 三件套
> - 内容随调研推进持续追加

---

## 0. Vault 顶层心智模型

**Vault = 一组 HTTP API + 一套 plugin 化的" Secret 数据面"。**

- CLI `vault write/read/list/delete X` ≡ HTTP `POST/GET/LIST/DELETE /v1/X`
- 一切能力（KV、PKI、Database、K8s Auth、Transit、SSH、第三方 GitLab 等）都是 plugin
- plugin 决定 **某个 mount 下暴露哪些 path、每个 path 的语义、动静态行为**

```
路径模型: <mount> / <engine-API> / <你的实例>
         自己挂      引擎定义       你起名
         如 pki/    如 issue/      如 svc

例:  pki / issue / svc
     ssh-ca / sign / dev-access
     demo-kv / data / app1/db
     auth/kubernetes / login
     auth/kubernetes / role / git-reader
```

**扩展面有 3 类**

| 类型 | 干什么 | 例子 |
|---|---|---|
| Secrets engines | 管 secret 的产生 / 存储 / 读取 | KV / PKI / DB / GitLab |
| Auth methods | 决定调用者是谁，发 Vault token | Kubernetes / OIDC / AppRole / LDAP |
| Audit devices | 决定审计日志写哪 | file / syslog / socket |

> **关于 OpenBao**：Vault 2023 改 BSL 许可后，社区 fork 出 OpenBao（MPL-2.0，Linux Foundation 托管，API 兼容 Vault）。本指南所有 OSS 能力描述对 OpenBao 同样适用；Enterprise 能力在 OpenBao 中的状态另见 **§14 OpenBao**。

---

## 能力地图速览（先看这里）

> 给只想先 30 秒看全貌的读者。**3 张表 + 1 段索引**，决定要不要往下深读。
> 每张表一行 = 一章；下方括号里的 §X 是详细章节链接。

### 一、OSS 基础能力（§1-§5）

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 |
|---|---|---|---|---|---|
| §1 | **KV v2 静态 Secret ** | 替代散落各处的明文配置 / `.env` / K8s Secret | path 模型存取，每条 secret 自带版本、RBAC、审计 | 版本化回滚 + Policy RBAC + HMAC 审计（日志泄露不暴露明文）+ 软删 / 硬销分离对应合规 | 业务配置里的第三方 SaaS API key 集中存；凭据合规可追溯 |
| §2 | **动态凭据**<br>(PKI/SSH/DB/Cloud/GitLab) | 干掉"长寿命凭据"这个攻击面 | 业务现要，Vault 现造，TTL 过期或主动 revoke 立即作废 | "凭据短到不值得偷"——根本上消灭长寿命 DB 密码 / SSH key / Cloud IAM key | CI 任务现要 5min GitLab PAT 跑完即销毁；migration 任务现要 PG 临时账号 |
| §3 | **K8s Auth Method** | Pod 不持任何 Vault 凭据也能换 token | Pod 提交 SA token + role 名 → Vault 调 K8s TokenReview 验真 → 按 role 发短期 Vault token | 身份委托 K8s + 授权保留 Vault；Pod 集成 Vault 的统一钥匙 | Pod 启动时凭 SA 身份换 Vault token；Tekton task 不用人填 Vault 凭据 |
| §4 | **Transit 加密即服务** | 业务不持加密 key 还能加解密 / 签名 | 明文交 Vault，密文回；key 永远不离开 Vault | rotate + rewrap 老数据**业务零参与零见明文**；KMS 的开源对等物 | 用户表身份证号 / 银行卡列加密；备份文件用 datakey envelope 加密 |
| §5 | **凭据轮换** | 长期账号定期换密码 (`legacy DB user` / AD 服务账号) | Vault 直接调外部数据面改密码 → 业务读 static-creds 拿当前值 | 账号名固定 + 密码 Vault 周期换；engine-specific（DB / OpenLDAP / AD） | 遗留应用 DB 账号每 24h 自动换密码；AD 域服务账号按合规周期轮换 |

### 二、Pod 集成三路径（§7-§10）

> 共同前提：业务 0 代码改动，Vault 集中治理。三种形态按业务现状选。

| § | 路径 | 业务侧看到 | 大致逻辑 | 适合 | 典型场景 |
|---|---|---|---|---|---|
| §7 | **Vault Agent Injector** | `/vault/secrets/<file>` 文件 | annotation 触发 Mutating Webhook，注入 init + sidecar，sidecar 后台续 lease + 重写文件 | 历史应用 / 多语言栈 / 动态凭据 + `kill -HUP` reload | 老 Java 应用 0 改动读 `application.yml` 中的 DB 密码；Tekton task 用文件读 Vault secret |
| §8 | **VSO** (Vault Secrets Operator) | 普通 K8s Secret (envFrom / volume) | CRD 声明 → Operator reconcile → 同步成 K8s Secret，可 `rolloutRestart` 业务 | 现有 K8s Secret 栈 / 多副本共享 / GitOps 流 | 已用 envFrom 的 Deployment 改接 Vault；多副本 Web 服务共享同一份 Vault secret |
| §9 | **CSI Provider** | volume mount `/mnt/secrets` | Pod 声明 CSI volume → 节点 driver 调 Vault provider → 落 tmpfs | 合规不接受凭据落 etcd / volume 文化成熟 / 不信任控制面 | 金融业务 secret 不进 etcd；统一 volume 模式管所有外部凭据 |

详细选型表见 §10。

### 三、Vault Enterprise 三件套（§11-§13）

| § | 能力 | 解决什么问题 | 大致逻辑 | OSS 替代方案 | 典型场景 |
|---|---|---|---|---|---|
| §11 | **Replication + Namespaces** | 跨 region 部署 + 多团队 / 多客户隔离 | Performance / DR 流式复制；namespace = Vault 内的子 Vault | 自建多集群 + 数据同步脚本（粗糙），多团队靠 path 前缀（治理弱） | 全球三 region 各起一 Vault 按 region 复制（数据驻留合规）；一个集群给 N 个 BU 各自隔离 |
| §12 | **Control Groups** | path 级 N-of-M 审批工作流 | 请求 secret → 返回 wrap_token（请求者）+ accessor（审批人）；攒够审批后 unwrap 取真值 | 业务侧自建审批服务前置；缺 Vault 原生集成 | 取生产 root 密码需 ops 2 人 + 安全 1 人审签；跨 region rotation 触发安全官 sign-off |
| §13 | **Sentinel** | 复杂策略表达（时间 / IP / 行为 / 上下文） | Policy-as-Code 脚本挂 path / identity，每次请求求值 | OPA + 应用层校验，但不集成进 Vault 请求链 | 工作时间 + 公司 IP + MFA 才能读 prod；全集群写操作请求体 ≤ 10KB 强制约束 |

### 索引：按问题域反查"该看哪节"

| 我想做的事 | 看哪一节 |
|---|---|
| 给业务存配置中的 API key / 第三方账号 | §1 KV v2 |
| 让 CI 任务现要短期 GitLab PAT / DB 凭据 / cert | §2 动态凭据（按数据面选 plugin） |
| Pod 怎么拿 Vault token 不写死 | §3 K8s Auth Method |
| 业务表敏感列加密 / 文件加密 / 签部署清单 | §4 Transit |
| 遗留 DB 账号定期换密码 | §5 凭据轮换 |
| 历史业务 0 改动把 secret 喂进去 | §7 Injector（文件）/ §8 VSO（K8s Secret）/ §9 CSI（volume） |
| 跨 region 部署 + 多团队隔离 | §11（需 Enterprise） |
| 取生产 root 密码要双人审签 | §12（需 Enterprise） |
| 工作时间 + 公司 IP + MFA 才能取 secret | §13（需 Enterprise） |

---

## 1. KV v2 — 静态 Secret 集中存储

### 解决什么问题

替代散落各处的 `.env` / 配置中心明文 / K8s Secret，给"长期持有的 Secret "一个**集中、版本化、可审计、细粒度授权**的家。

### 核心模型

> Vault KV v2 = 「带版本的 JSON 字典 + path-level RBAC + HMAC 审计 + 软删硬销分离」

K8s 原生 Secret 任意一件（版本 / RBAC / 审计 / 删除策略）都不好做；Vault 一站式包齐。

### 关键概念

- **mount 路径** vs **API 路径**：`vault secrets enable -path=demo-kv kv` 是你挂的；`data/` `metadata/` `delete/` `destroy/` `undelete/` 是 KV v2 引擎定义的
- **版本**：每次 put 自动递增 version；可以按 version 读、删、恢复
- **软删 vs 硬销**：`delete` 可 `undelete` 恢复；`destroy` 不可逆
- **policy**：path-glob 配 capabilities (`read`/`create`/`update`/`delete`/`list`/`sudo`)，token 通过 policy 拿权限

### 最小命令示例

```bash
# 启用 KV v2 引擎（挂到 demo-kv/）
vault secrets enable -path=demo-kv -version=2 kv

# 写 secret
vault kv put demo-kv/app1/db username=alice password=p@ssw0rd-v1

# 读 secret
vault kv get demo-kv/app1/db
vault kv get -field=password demo-kv/app1/db    # 只要某字段

# 更新（产生 version 2）
vault kv put demo-kv/app1/db password=p@ssw0rd-v2

# 按版本读
vault kv get -version=1 -field=password demo-kv/app1/db

# 列出
vault kv list demo-kv/app1

# 看元信息（版本历史）
vault kv metadata get demo-kv/app1/db

# 软删 v1 → 可恢复
vault kv delete -versions=1 demo-kv/app1/db
vault kv undelete -versions=1 demo-kv/app1/db

# 硬销 v1 → 不可恢复
vault kv destroy -versions=1 demo-kv/app1/db

# 写 policy（只读 demo-kv/data/app1/*）
cat <<EOF | vault policy write demo-app1-reader -
path "demo-kv/data/app1/*" {
  capabilities = ["read"]
}
path "demo-kv/metadata/app1/*" {
  capabilities = ["list", "read"]
}
EOF

# 拿 policy 派一个限权 token
READER_TOKEN=$(vault token create -policy=demo-app1-reader -ttl=10m -field=token)
VAULT_TOKEN=$READER_TOKEN vault kv get demo-kv/app1/db  # ✓
VAULT_TOKEN=$READER_TOKEN vault kv put demo-kv/app1/db x=y  # ✗ permission denied

# 启用审计
vault audit enable -path=file file file_path=/var/log/vault-audit.log
```

### 使用场景

| 场景 | 为啥用 KV v2 |
|---|---|
| 业务配置里的 API key / token / DSN | 集中存放，离职/泄露只改一处 |
| TLS 证书的中间值 / DH params | 需版本化；审计要看谁取过 |
| 配合 Vault Agent / VSO 投递到 Pod | 业务侧 0 凭据，Vault 端集中治理 |
| 短期凭据"写一次、多处读"的桥接 | 比直接互相传 token 安全 |

**不该用 KV v2 的场景**：值天然短寿命且可以现造时（DB 密码 / 云 IAM key / cert）——用对应**动态引擎**而不是把"现造 + 存"硬塞进 KV。

> **理解**：KV v2 把"分散在各处明文的 Secret "集中起来，给每条 Secret 三件配套：
> **历史版本**（可按 version 回读、回滚） + **path-level RBAC**（policy 控读 / 写 / 删粒度到 path glob） + **审计**（每次访问留 HMAC 化日志，泄露不暴露明文）。
> **软删可恢复 / 硬销不可逆**让合规 "30 天可恢复后永久删除" 有现成机制。
> 对应到工程上：业务侧只关心调哪个 path，不再需要自己管"存哪、版本怎么走、谁有权限、谁取过"——这四件事 K8s 原生 Secret 都不好做。

## 2. 动态凭据 — PKI · SSH · Database · Cloud IAM · GitLab(plugin)

### 解决什么问题

凡是"长寿命凭据"都是攻击面。**业务不持有任何长寿命凭据**，要的时候跟 Vault 现要；Vault 现造、带 TTL、过期 / 主动 revoke 自毁。

### 核心模型

> "凭据短到不值得偷。" 业务从此**只持有"我要什么"的请求权（policy）**，不持有任何凭据本体。

```
                  ┌──────────┐
   业务调用 ────→ │ Vault    │ ──┬─ pki/issue   现签 X.509
                  │ 各种      │   ├─ ssh-ca/sign 现签 SSH cert
                  │ secrets   │   ├─ database/creds 现造 DB user
                  │ engines  │   ├─ aws/creds 现造 IAM key
                  └──────────┘   └─ gitlab/roles/.../token 现造 PAT
                       │
                       ▼
                   每个凭据带 lease + TTL
                       │
                       ▼
               到期 / revoke → 凭据自毁
                       │
                       ▼
               引擎调用对应数据面（CA / DB / IAM / GitLab API）撤销
```

### 关键概念

- **lease** = "这把凭据的契约"，包含 lease_id + TTL + renewable 标志
- **role** = "凭据签发模板"——参数化的"允许签啥、活多久、能干啥"
- **policy** 控制"谁能调这个 role"；**role** 控制"调了发啥"——两层解耦
- **revoke** 不只是 Vault 自己标记失效，是**反向调用数据面真正销毁**（CRL / DROP USER / IAM 删 key / GitLab 删 PAT）

### 2.1 PKI — 现签 X.509 证书

**最小命令**

```bash
# 让 Vault 当自签 CA
vault secrets enable pki
vault write pki/root/generate/internal common_name=demo.internal ttl=24h

# 定义签发 role
vault write pki/roles/svc \
    allowed_domains=demo.internal allow_subdomains=true \
    max_ttl=10m ttl=5m

# 业务现签一张证书（一行 API）
vault write pki/issue/svc common_name=app1.demo.internal
# → certificate / private_key / serial / lease_id (5min TTL)

# 提前撤销
vault lease revoke <lease_id>
```

**返回字段**：`certificate`（X.509 PEM）+ `private_key`（私钥 PEM）+ `serial_number` + `expiration`

**场景**：服务间 mTLS、短期 TLS server cert、签客户端证书做 zero-trust 接入。

### 2.2 SSH — 现签 OpenSSH 用户证书

**核心模型**：Vault 当 SSH CA；开发者本地生成 keypair，把**公钥**交 Vault 签 → 拿回短期证书；服务器 `sshd_config: TrustedUserCAKeys` 一次性信 CA，**永远不存 authorized_keys**。

**最小命令**

```bash
# 运维一次性
vault secrets enable -path=ssh-ca ssh
vault write ssh-ca/config/ca generate_signing_key=true  # 生成 CA keypair
vault write ssh-ca/roles/dev-access \
    key_type=ca \
    allowed_users=ubuntu \
    ttl=5m max_ttl=10m \
    allow_user_certificates=true

# 开发者每次登录前
ssh-keygen -t ed25519 -f mykey -N ""
vault write -field=signed_key ssh-ca/sign/dev-access \
    public_key=@mykey.pub valid_principals=ubuntu > mykey-cert.pub

# 登录
ssh -i mykey -i mykey-cert.pub ubuntu@target-host
```

**两个 `-i` 的含义**：
- `-i mykey` → 给 ssh 用的**私钥**（用于挑战签名）
- `-i mykey-cert.pub` → 出示给服务器的**证书**（带 CA 签名的公钥+元信息）

**OpenSSH 证书结构**

```
Cert = {
  Public key,        // 客户端公钥（明文）
  Key ID,            // CA 签时写入（Vault 塞 token 信息用于审计）
  Serial,            // 全局唯一，用于吊销
  Type: user|host,
  Valid principals,  // 能登的用户列表
  Valid after/before,
  Critical Options,  // 服务器必须懂的硬约束（force-command / source-address）
  Extensions,        // 服务器不懂可忽略（permit-pty / permit-port-forwarding）
  Signature          // CA 私钥签名
}
```

**场景**：跳板机登录 / 运维 SSH / 离职清理（撤 policy 就够，**不用动任何机器**）。

### 2.3 Database / AWS / GitLab — 同一模型，数据面不同

**Database（PG/MySQL/Mongo 等）**

```bash
vault secrets enable database
vault write database/config/postgres-prod \
    plugin_name=postgresql-database-plugin \
    connection_url="postgresql://{{username}}:{{password}}@pg.internal:5432/app" \
    allowed_roles=readonly \
    username=vault-admin password=<admin-pass>

vault write database/roles/readonly \
    db_name=postgres-prod \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl=10m max_ttl=1h

# 业务现要 DB 凭据
vault read database/creds/readonly
# → username=v-token-readonly-xxxxx password=<random> ttl=10m
```

**AWS IAM**

```bash
vault secrets enable aws
vault write aws/config/root access_key=<admin> secret_key=<admin>
vault write aws/roles/s3-reader policy_arns=arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
vault read aws/creds/s3-reader  # → 新 IAM user + key + secret, TTL 后自删
```

**GitLab Secrets Engine（社区 plugin，需单独装）**

> 有两个常见 fork，能力面差异显著：
> - **`splunk/vault-plugin-secrets-gitlab`** — 仅生成 GitLab Project Access Token
> - **`ilijamt/vault-plugin-secrets-gitlab`** — 通过 `token_type` 支持 personal / project / group / user-service-account / group-service-account / pipeline-trigger / deploy 等多种 token
>
> 下面命令以 ilijamt fork 为例（`token_type=project` 字段是该 fork 的扩展）。用 splunk fork 时去掉 `token_type` 即默认发 project token。各 fork 是否支持轮换 Vault 自己的 admin PAT（rotate-root）当前**均未在 README 中明示**，需以各 fork 自己的文档为准。

```bash
# 1. 下载 plugin binary 放入 plugin_directory
# 2. 注册
vault plugin register -sha256=$SHA secret vault-plugin-secrets-gitlab
vault secrets enable -path=gitlab vault-plugin-secrets-gitlab

# 3. 配 admin PAT
vault write gitlab/config base_url=https://gitlab.example.com token=glpat-<admin>

# 4. 定义 role (ilijamt fork 写法; splunk fork 去掉 token_type)
vault write gitlab/roles/ci-runner \
    path=team/project name=ci-{{.role_name}} \
    token_type=project scopes=api access_level=40 ttl=10m

# 5. 业务现要 GitLab token
vault read gitlab/roles/ci-runner/token
# → 真 GitLab PAT, 10min 后 Vault 调 GitLab API 删 token
```

> ⚠️ Vault OSS binary **不内置** `gitlab` plugin，需要先下载 binary 注册（之前说"1.18+ 官方"不准确，纠正：是 HashiCorp 在 community plugin 名录中收录，非 builtin）。

### 2.4 DevOps / ACP 领域相关插件清单

> 仅列与 DevOps（CI/CD、SCM、制品仓库、IaC）和 ACP（K8s 平台、服务网格、节点运维）业务域相关的引擎；其他通用引擎略。
> "Builtin" = Vault 二进制自带；"Community" = 需 `vault plugin register` 加载第三方 binary。

#### DevOps 领域相关引擎

| 引擎 | 类型 | 解决什么 | 典型场景 |
|---|---|---|---|
| `gitlab` (splunk/vault-plugin-secrets-gitlab) | Community | 现造 GitLab PAT / project token / group token | CI 任务 push 代码 / 调 GitLab API |
| `github` (martinbaillie/vault-plugin-secrets-github) | Community | 现造 GitHub App Installation token | CI 任务访问 GitHub repo |
| `artifactory` (JFrog 官方) | Community | 现造 JFrog Artifactory 用户 / 访问 token | 拉/推制品到 Artifactory |
| `terraform` | Builtin | 现造 Terraform Cloud team / org API token | IaC / GitOps 编排 |
| `aws` / `gcp` / `azure` / `alicloud` | Builtin | 现造云 IAM 用户 / 凭据 | CI 部署到云 / 拉跨云镜像 |
| `database` (PG / MySQL / Mongo / MSSQL / Oracle / ...) | Builtin | 现造 DB 用户跑 migration / 临时排查 | Schema migration、Tekton 临时 DB 凭据 |
| `kubernetes` (secrets engine) | Builtin | 在目标集群现造短期 SA + token + RoleBinding | 多集群 CI/CD 部署 |
| `pki` | Builtin | 现签 X.509 证书 | Pipeline task 间 mTLS、自签私有 cert |
| `ssh-ca` | Builtin | 签 OpenSSH 用户 / 主机证书 | 部署到裸金属、跳板机管理 |
| `transit` | Builtin | 加解密 / 签验签 API，key 不出 Vault | 签发部署包、敏感参数加密 |

#### ACP 领域相关引擎

| 引擎 | 类型 | 解决什么 | 典型场景 |
|---|---|---|---|
| `kubernetes` (secrets engine) | Builtin | 在集群里现造 SA + token，撤销后销毁 | 多租户：每租户现造短期 SA |
| `pki` | Builtin | 内置 CA，签服务 / 客户端 / 中间 CA 证书 | 服务网格 mTLS、Ingress 证书、内部 CA 自治 |
| `ssh-ca` | Builtin | 签 SSH 用户证书 / 主机证书 | 节点登录、跳板机零状态化 |
| `transit` | Builtin | 加密 / 解密 / HMAC，key 不出 Vault | etcd 加密、Secret 持久化前加密、敏感字段保护 |
| `database` | Builtin | 现造各类 DB 凭据 | 平台托管 DB 按租户发凭据 |
| `openldap` / `ldap` / `ad` | Builtin | 现造 / 轮换 LDAP / AD 账号密码 | 企业 SSO 集成、对接现有用户体系 |
| `aws` / `gcp` / `azure` / `alicloud` | Builtin | 现造云 IAM 凭据 | 多云 ACP 拉镜像 / Volume / LB |
| `auth/kubernetes` (auth method) | Builtin | Pod 用 SA token 换 Vault token | Pod 集成 Vault 的入口（详见 §3） |
| `gcpkms` | Builtin | 用 GCP KMS 当 key 后端 | seal / unseal 自动化 |

### 静态 vs 动态对照

| 维度 | 静态 KV | 动态引擎 |
|---|---|---|
| 凭据来源 | 人提前存 | Vault 现造 |
| 寿命 | 永不过期 | TTL，到期失效 |
| 撤销 | 改值后旧值仍有效 | `vault lease revoke` 立即作废 |
| 泄露代价 | 大（排查 + 改所有引用） | 小（短窗口后自死） |
| 适用 | 配置参数 / 第三方 API key | DB / SSH / Cloud / Git 凭据 |

### 使用场景速查

| 数据面 | 引擎 | 典型场景 |
|---|---|---|
| TLS / mTLS | `pki` | 服务间通信、短期 server cert |
| SSH | `ssh-ca` | 跳板机、运维登录 |
| 关系型数据库 | `database` | 应用读写凭据、临时排查窗口 |
| 云资源 | `aws` / `gcp` / `azure` | CI 拉镜像 / IaC 操作 |
| GitLab | `gitlab` (plugin) | CI 任务 push / 调 API |

> **理解**：动态凭据的核心是——**每次需要使用凭据时，由 Vault 现场统一生成短期凭据**；通过 policy 持续门控"是否还能再生成"，从而达成集中管理。
>
> 从扩展模型角度看，**Vault 用统一的 plugin 模型管所有 secret**（KV 也是 plugin）；**动态 vs 静态的差异不在框架，在 plugin 内部实现**：静态 plugin 落盘后取出（KV），动态 plugin 收到请求时调对应数据面现造（PKI 调 crypto / Database 调 SQL `CREATE USER` / GitLab 调 API 现申请 PAT）。对调用方完全一样，都是 `vault write <mount>/<path>`。
>
> 业务上的差别：以前散落各处的"长寿命 DB 密码 / 长寿命 SSH key / 长寿命云 IAM key" 全部转成"短寿命 + 自动撤销"——**根本上消灭长寿命凭据这个攻击面**。

---

## 3. K8s Auth Method — Pod 拿 Vault token 的钥匙

### 解决什么问题

K8s Pod 想读 Vault secret，得先有 Vault token。**Vault token 不能写死在 Pod 里**（轮换难、泄露难追）。怎么办？

### 核心模型

> Pod 不持有任何 Vault 凭据，**凭 K8s SA 身份现场换 Vault token**。身份验真权委托 K8s，授权权保留在 Vault。

```
Pod (sa=app-reader)
   │
   │ ① POST {"jwt":"<SA token>","role":"git-reader"}
   ↓
Vault auth/kubernetes/login
   │
   │ ② Vault 拿 SA token 调 K8s TokenReview API
   ↓
K8s: "真，是 ns=devops-valult-invest sa=app-reader"
   │
   ↓
Vault: 查 role git-reader → bound_* 白名单包含该身份？
         ✓ → 发 Vault token (policy=git-reader, ttl=5min)
         ✗ → 拒
   │
   ↓
Pod 用 Vault token 调 vault/v1/demo-kv/data/git/test → 拿到 secret
```

### 关键概念

- **K8s 给每个 Pod 自动挂的 SA token + CA**：路径固定 `/var/run/secrets/kubernetes.io/serviceaccount/{token,ca.crt}`
- **TokenReview API**：K8s 内置的"帮你验 SA token 是否有效 + 是哪个 ns/sa"的 API
- **Vault 自己也要一个 SA**：必须挂 `system:auth-delegator` ClusterRole 才能调 TokenReview
- **role**：把"K8s 身份 (bound_service_account_namespaces + bound_service_account_names)"映射到"Vault policy + TTL"
- **客户端指定 role 名**：login 请求体里带 `role: "<name>"`，Vault 查这个 role 再校验 bound_* 是否包含真实身份

### 最小命令示例

**装配（运维一次性）**

```bash
# ① 写 policy（限读 demo-kv/data/git/*）
cat <<EOF | vault policy write git-reader -
path "demo-kv/data/git/*" {
  capabilities = ["read"]
}
EOF

# ② 启用 K8s auth method
vault auth enable kubernetes

# ③ 配置 K8s auth（告诉 Vault K8s API 在哪 + 用什么身份调 TokenReview）
#    Vault 在集群内 Pod 跑时，CA 和 SA token 直接读 projected 路径
K8S_CA=$(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)
TOKEN_REVIEW_JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

vault write auth/kubernetes/config \
    kubernetes_host=https://kubernetes.default.svc:443 \
    kubernetes_ca_cert="$K8S_CA" \
    token_reviewer_jwt="$TOKEN_REVIEW_JWT"

# ④ 写 role（K8s 身份 → Vault policy 映射）
vault write auth/kubernetes/role/git-reader \
    bound_service_account_names=app-reader \
    bound_service_account_namespaces=devops-valult-invest \
    policies=git-reader \
    ttl=5m
```

**K8s 侧准备**

```yaml
# Vault 自己用的 SA（带 system:auth-delegator）
apiVersion: v1
kind: ServiceAccount
metadata: { name: vault-auth, namespace: devops-valult-invest }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: vault-auth-tokenreview }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: system:auth-delegator }
subjects:
- { kind: ServiceAccount, name: vault-auth, namespace: devops-valult-invest }
---
# 业务 Pod 用的 SA
apiVersion: v1
kind: ServiceAccount
metadata: { name: app-reader, namespace: devops-valult-invest }
```

**业务 Pod 跑时（pod 里跑这段 curl）**

```bash
SA_JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
VAULT=http://vault.devops-valult-invest.svc:8200

# 1) 换 Vault token
RESP=$(curl -s --data "{\"jwt\":\"$SA_JWT\",\"role\":\"git-reader\"}" \
  $VAULT/v1/auth/kubernetes/login)
VAULT_TOKEN=$(echo "$RESP" | grep -o '"client_token":"[^"]*"' | cut -d'"' -f4)
# → Vault 响应: client_token, policies=[default, git-reader], lease_duration=300

# 2) 读 secret（policy 允许）
curl -s -H "X-Vault-Token: $VAULT_TOKEN" $VAULT/v1/demo-kv/data/git/test
# → {"data":{"data":{"repo":"secret-repo","token":"ghp_demo_token_xxx"}}}

# 3) 越权读（policy 不允许）
curl -s -H "X-Vault-Token: $VAULT_TOKEN" $VAULT/v1/demo-kv/data/other/foo
# → {"errors":["permission denied"]}
```

### role 概念跨引擎复用

**role 是 Vault 跨引擎的通用抽象，含义统一为"参数化的发放模板"**

| 引擎 | role 路径 | role 控制 |
|---|---|---|
| K8s auth | `auth/kubernetes/role/<n>` | 谁能登 + 发什么 policy + TTL |
| AppRole auth | `auth/approle/role/<n>` | role_id/secret_id 准入 + 发什么 policy |
| PKI | `pki/roles/<n>` | 能签什么域名 + TTL + 算法白名单 |
| SSH | `ssh-ca/roles/<n>` | 能签什么用户 + TTL + key_type |
| Database | `database/roles/<n>` | 现造 DB user 跑什么 SQL |
| AWS | `aws/roles/<n>` | 现造 IAM user 带什么 policy ARN |
| GitLab (plugin) | `gitlab/roles/<n>` | 发什么类型 token + scope + TTL |

**两类的微妙区别**

- **Auth 引擎里的 role** = "身份映射器"：客户端身份 → Vault token
- **Secrets 引擎里的 role** = "凭据签发器"：参数请求 → 业务凭据

### 使用场景

| 场景 | 怎么用 |
|---|---|
| 业务 Pod 读配置中的 API key | K8s auth → KV v2 |
| CI 任务现要 DB 凭据 | K8s auth → database/creds |
| Tekton task 现要 GitLab PAT | K8s auth → gitlab/roles/.../token |
| 多团队共用集群、各团队独立读写域 | role 按 ns + sa 切片，policy 限路径 |

> **理解**：核心解决的是——**如果在 K8s Pod 中访问 Vault 获取 token，需要额外传递 Vault 认证信息**这个问题。
> Vault 提供了"用 K8s SA token 换短期 Vault token"的能力，业务再用 Vault token 取 secret，从而**规避在 K8s 侧维护 Vault 认证信息**。
>
> 拆成三件事：
> 1. **Vault 侧**：定义 role 概念——把"特定 ns + 特定 SA"绑定到"特定 policy"，并配置签发 Vault token 时的有效期。
> 2. **Vault 侧**：提供"用 SA token 换 Vault token"的 API；收到请求后调 K8s API 校验 SA token 有效性，并用客户端传上来的 role 名（确认该 role 绑定了这个 SA）签发短期 Vault token。
> 3. **客户端侧**：用 SA token 发起请求，携带 `token + role 名`，换取 Vault token；再用 Vault token 取 secret。
>
> 关键细节：**role 名由客户端在 login 请求里指定**，不是 Vault 搜索匹配——Vault 拿到 role 名直接查配置，再校验 SA 真实身份是否在该 role 的 `bound_*` 白名单里。同一 SA 可绑多个 role，业务在不同场景用不同 role 拿不同权限的 token（最小权限原则）。

---

## 4. Transit — 加密即服务（EaaS）

### 解决什么问题

业务要给敏感数据（PII / 银行卡 / 令牌 / 备份 / 日志 / DB 列）加密，但**自己持有 key 是噩梦**：分发难、轮换难、泄露难追、合规审计难。

### 核心模型

> Vault 提供一组**加 / 解 / 签 / 验 / HMAC / 随机数**的 API；业务把**明文**或**密文**发给 Vault，Vault 用**内部命名 key**处理后返回结果。
>
> **Key 永远不离开 Vault**——业务从此持有的是"调用权限（policy）"，而不是 key 本体。

```
业务 ──明文──→ Vault transit/encrypt/<key 名> ──密文──→ 业务
业务 ──密文──→ Vault transit/decrypt/<key 名> ──明文──→ 业务

       Vault 内部:
         ┌─────────────────┐
         │ key 材料 (32 字节) │  ← 落盘前用主 unseal key 包一层
         │ 算法 (aes256-gcm) │
         │ 版本 v1 / v2 / ...│
         └─────────────────┘
       业务和 K8s Secret 都看不到 key 字节
```

和 §1 / §2 的结构差别：**Transit 不签发凭据**，它本身是个**密码学微服务**。

### 核心能力清单

下面每条都是一个真实的工程痛点 → Transit 怎么解 → 解了之后的差别。

#### ① Key 分发 / 持有 → 业务从此 0 key

**痛点**：传统加密要给每个业务实例下发 key。下发就涉及"放哪、谁能读、轮换怎么同步、镜像里能不能 bake"——每一项都是事故源头。
**Transit**：业务只持 Vault token（短寿命 + RBAC），加解密走 API。Key 字节永远不离开 Vault。
**差别**：镜像 / Pod / Secret / 配置中心**永远不出现 key 字节**，离职审查 / 镜像扫描 / 合规问询都不再涉及 key。

> **理解**：业务需要保存敏感信息 → 需要加密 → key 本身又是敏感信息（**递归问题**）。
> 用 Vault 之后 key 永远只在 Vault 内，业务持有的是"调用加密 API 的权限"——
> **打破了 key 的递归** + **业务侧不再有 key 泄露这件事** + **风险集中到一个可重点防护的中心**（信任锚收敛，单点防护投入获得边际收益）。

#### ② 周期 / 应急轮换 → 一条命令，业务零参与

**痛点**：合规要求 key 每年轮换，传统做法是"解全部历史数据 + 重新加 + 验证 + 切换"，DB 大表全表扫描，停机窗口动辄数小时。key 疑似泄露时更紧急——窗口越短越好。

**为什么"应该定期更新"——三类触发原因**

| 触发 | 时间感 | 例子 |
|---|---|---|
| 合规要求 | 周期（年 / 季） | PCI-DSS / 等保三级 / SOX |
| 加密学最佳实践 | 时间感更长 | 同 key 用太久，密文样本增多反推风险增加 |
| 应急响应 | 立即 | key 疑似泄露、相关人员离职、密文被批量爬走 |

核心目的：缩小"任何单一 key 泄露后能解的密文范围"——即**爆炸半径**。

**Transit**：
```bash
vault write -f transit/keys/my-app-key/rotate   # 1 秒

# 也可以让 Vault 自己定期轮换，业务和运维都不用记日子
vault write transit/keys/my-app-key/config \
    auto_rotate_period=2160h    # 每 90 天自动 rotate
```

之后**新数据自动用 v2 加**，**老 v1 密文照样能解**（Vault 保留所有版本 key）。业务侧零代码改、零停机。

**差别（传统 vs Vault）**

```
传统轮换:                     Vault Transit 轮换:
─────────────                ─────────────────
1. 停写                       1. vault rotate (1 秒)
2. 解全部老数据                2. 新写入自动用 v2
3. 用新 key 重加               3. 老数据继续用 v1 解
4. 切换业务引用                4. (可选) 后台 rewrap 慢慢升级
5. 验证全部成功
6. 启用新 key, 删老 key

"big-bang" 一次性切换         "渐进式 + 持续可用"
要停机窗口 / 风险高           零停机 / 零业务参与
```

> **理解**：业务侧需要定期换 key（合规 + 加密学最佳实践 + 应急）→
> Vault 的 `rotate` 让"换 key" 变成 1 秒 1 条 API 的操作 →
> 新写入立刻用 v2，老数据**继续用 v1 安全解密**（Vault 保留所有版本 key） →
> **轮换从"项目"变"操作"，而且是渐进式的，业务零停机零参与。**

#### ③ 历史数据升 key → 后台异步 rewrap，业务不见明文

**痛点**：①②做到了，但老数据上还印着旧 key 的密文，合规要求"逐步迁移到新 key"。传统做法 = 业务后台 job 解密拿明文再加密——意味着这个 job 进程**必须有解密权限 + 处理明文的内存**，是新攻击面。
**Transit**：
```bash
vault write transit/rewrap/my-app-key ciphertext=vault:v1:...
# → vault:v2:...
```
Vault 内部解 v1 → 内存里明文一瞬 → 用 v2 加 → 清零。**业务侧从未接触明文**。
**差别**：迁移 job 仅需"调 rewrap"权限，不需要 decrypt 权限，不接触明文，攻击面降一个量级。

#### ④ 大数据 / 高频小数据加密 → Envelope encryption

**痛点**：直接每条调 transit/encrypt 走网络 RTT，TB 级日志 / 千万行 DB 列都顶不住延迟。
**Transit**：派生临时数据 key
```bash
vault write transit/datakey/plaintext/my-app-key
# → 返回 plaintext (32B) + ciphertext (~80B)
```
业务：拿 plaintext 在**本地**对大文件做 AES，把 ciphertext 和加密后的大文件一起存；用完立刻清零 plaintext。
**差别**：网络调用次数 = 文件数（不是字段数）；Vault 只为"加 / 解几十字节 datakey"忙活；性能与本地加密无差。

#### ⑤ 多算法一站式 → encrypt / sign / hmac / random 同接口

**痛点**：业务自己拼密码学库时，AES / RSA / HMAC / 随机数分散在不同 lib，各有各的 key 管理 / 错误处理 / 升级节奏。
**Transit**：一个引擎覆盖

| API | 解决什么 |
|---|---|
| `encrypt` / `decrypt` | 对称加解密（aes256-gcm96 / chacha20） |
| `sign` / `verify` | 数字签名（rsa / ecdsa / ed25519） |
| `hmac` / `verify-hmac` | 消息认证（HMAC-SHA256/384/512） |
| `random/<N>` | Vault 内置 CSPRNG，业务取真随机数 |
| `datakey/plaintext` | 派生 envelope encryption 用的临时 key |

**差别**：所有密码学操作集中到一个治理点，policy + 审计统一覆盖。业务从"维护 5 套密码学栈"变成"调 Vault"。

#### ⑥ 加密索引 / 去重 → Convergent key（同明文恒得同密文）

**痛点**：要对加密列做精确等值检索（"找邮箱 = x@y.com 的用户"），但 GCM 模式每次加密 IV 随机，密文每次不同，**没法 WHERE = 比较**。
**Transit**：
```bash
vault write -f transit/keys/email-cv \
    type=aes256-gcm96 convergent_encryption=true derived=true
```
开启 `convergent` 后，**同明文 + 同 context 必得同密文**——可以直接对密文列建索引、做等值检索。
**差别**：加密列也能像普通列一样查，业务 SQL 不用改。
（注意：convergent 牺牲了一部分语义安全性，仅在确实需要查询的列上开。）

#### ⑦ 集中审计 → 谁、什么时候、调了哪把 key、做了什么

**痛点**：传统加密散落各业务，"哪个服务调用过哪把 key"全靠日志拼。
**Transit**：每次 encrypt / decrypt / sign / rewrap 都进 Vault audit log，含 token accessor / policy / 操作 / key 名 / 时间。HMAC 隐藏明文和真 token，**审计日志泄露不暴露任何敏感数据**。
**差别**：合规审计直接拉 Vault audit log，不用对接 N 个业务的日志。

#### ⑧ 平台级数据加密 → 当 KMS 用

**痛点**：K8s Secret / etcd 想做"持久化前加密"，又不想依赖云厂商 KMS。
**Transit**：实现 KMS 协议（K8s `kms-plugin` 标准），etcd 端只看到密文，**Vault 是 key 持有方**。
**差别**：air-gap / 私有云环境获得云 KMS 同等能力，不绑云厂商。

---

### 最小命令示例

```bash
# 1. 启用 + 建 key
vault secrets enable transit
vault write -f transit/keys/my-app-key                       # 默认 aes256-gcm96
# 想用其他类型: vault write -f transit/keys/sig-key type=ed25519

# 2. 加密 (Vault API 要 base64 输入)
B64=$(printf "alice@email.com,SSN=123-45-6789" | base64)
CT=$(vault write -field=ciphertext transit/encrypt/my-app-key plaintext="$B64")
# → vault:v1:JCSFB7FoXUQY1Jhc...

# 3. 解密
vault write -field=plaintext transit/decrypt/my-app-key ciphertext="$CT" | base64 -d
# → alice@email.com,SSN=123-45-6789

# 4. 轮换 key (新 v2)
vault write -f transit/keys/my-app-key/rotate
vault read transit/keys/my-app-key | grep latest_version    # → 2

# 5. 用新 key 加密
NEW_CT=$(vault write -field=ciphertext transit/encrypt/my-app-key plaintext=$(printf "new" | base64))
# → vault:v2:...
# 老 v1 密文照样能解
vault write -field=plaintext transit/decrypt/my-app-key ciphertext="$CT" | base64 -d

# 6. rewrap: 老密文升到新 key 版本, 业务侧不见明文
REWRAPPED=$(vault write -field=ciphertext transit/rewrap/my-app-key ciphertext="$CT")
# → vault:v2:...

# 7. 签名 / 验签 (要用 rsa/ecdsa/ed25519 类型的 key)
vault write -f transit/keys/sig-key type=ed25519
SIG=$(vault write -field=signature transit/sign/sig-key input=$(printf "doc-hash" | base64))
vault write transit/verify/sig-key input=$(printf "doc-hash" | base64) signature="$SIG"
# → valid: true

# 8. HMAC
vault write -field=hmac transit/hmac/my-app-key input=$(printf "payload" | base64)
# → vault:v1:hmac-sha2-256:...

# 9. CSPRNG 随机字节
vault write -field=random_bytes transit/random/32 format=base64

# 10. Envelope encryption: 派生数据 key
vault write -format=json transit/datakey/plaintext/my-app-key   # 返回 plaintext + ciphertext
# (业务用 plaintext 加大文件, 只存 ciphertext, plaintext 内存中清零)
```

### 使用场景

| 场景 | 用法 |
|---|---|
| 数据库敏感列加密（身份证 / 银行卡 / 邮箱 / 手机号） | 业务读写时调 encrypt / decrypt |
| etcd / K8s Secret 持久化前加密 | KMS API 指向 Vault Transit |
| 文件 / 备份 / 日志加密 | Envelope encryption（datakey） |
| JWT / API token / SAML 断言签名 | sign / verify，私钥不出 Vault |
| 密码字段 HMAC 校验 | hmac / verify-hmac，HMAC key 不出 Vault |
| 应用内取 CSPRNG 随机数 | `transit/random/<N>` |

**不该用 Transit 的场景**：
- 业务每秒高频小数据加解密 + 网络延迟敏感（每次调 Vault 是网络 RTT）→ 用 envelope encryption 让业务本地干批量，只用 Vault 加解 datakey
- 业务只想"换 KMS"（已用云 KMS）→ 直接 datakey-only 模式，或评估 transit autoseal 反过来用 KMS 兜底

### 一句话本质

> Transit = "加密 / 签名 / HMAC / 随机数 都是 Vault 的 API"——业务永远不持 key，旋转一条命令，老数据 rewrap 平滑跟上。**KMS 的开源对等物。**

---

## 5. 凭据轮换 — 长期账号 + 周期换密码

### 解决什么问题

凡是"长期存在、不能销毁"的账号都有合规 / 安全压力——密码要周期换。但传统做法是 DBA / 运维定期登录改密码 + 手工同步到所有业务侧，**人为 + 散落 + 易过期 + 缺审计**。

§2 动态凭据解决的是"现造短命凭据"——账号每次都是全新对象，用完销毁。但下面这些场景动态凭据**搞不定**：

- **遗留应用**：DB 连接串里 hardcode 了固定用户名，不能每次换用户
- **审计 / 责任追溯**：合规要求 SQL 操作追到固定身份名，而不是 `v-token-readonly-xxxx` 这种动态名
- **建账号有审批流**：服务账号、AD 域账号建立要走 ticket，不能轻易销毁重建
- **第三方 SaaS 单 master 账号**：不允许子账号体系，只能定期换 master 密码

**凭据轮换正好填这个口子**：账号不变、密码定期换、业务通过 Vault 读"当前密码"。

### 核心模型

> Vault 帮你**直接调外部数据面 API（DB / LDAP / AD / IAM）改某个账号的密码**——新密码只 Vault 知道；业务通过 Vault `static-creds/<n>` 读"用户名（固定）+ 当前密码（变化）"，连外部系统时按当前密码登。

```
                       ┌──────────────────────────┐
                       │ Vault                    │
   ┌─────────────────→ │ static-role:             │
   │                   │   target = app_legacy    │ ← 账号名固定
   │                   │   rotation_period = 24h  │
   │                   └──────────┬───────────────┘
   │                              │ 每 24h
   │                              ↓
   │                   ┌──────────────────────────┐
   │                   │ Vault 调 DB API:          │
   │                   │ ALTER USER app_legacy    │
   │                   │ WITH PASSWORD '<新>'      │
   │                   └──────────┬───────────────┘
   │                              │
   │  ─ 业务 ─ vault read database/static-creds/legacy-app
   │            返回: username=app_legacy
   │                  password=<当前 24h 内有效密码>
   │
   └─ 业务用 (app_legacy, 当前密码) 连 DB
```

业务侧的事：
- 用户名引用**永远不变**（`app_legacy`）
- 密码**周期变**——业务定期重读 / 配合 §7 Injector / §8 VSO / §9 CSI 的自动 refresh

### 核心能力清单

#### ① Root rotation — Vault 自己用的管理员凭据自闭环

**痛点**：Vault 要管 DB 上的子用户，得有一把 DB admin 账号。这把 admin 密码如果还能给人 / 平台用，等于绕开 Vault 直接操控 DB——治理 / 审计失效。

**机制**：
```bash
vault write -force database/rotate-root/postgres-prod
```

执行后 Vault **直接调 DB API 改 admin 密码**，新密码**只 Vault 自己知道**——平台 / 人员从此再也登不上 DB admin。

> **理解**：root rotation 是"**强制集中治理**"的一锤定音——执行那一刻 Vault 把后端管理权转给自己，从此**只能通过 Vault** 操作 DB；想绕过 Vault 直连 DB 改东西，**没人有那个密码**。

#### ② Static roles — 帮你管一个已存在账号的密码

**痛点**：DB 上已有个长期账号 `app_legacy`（业务连接串 hardcode 了用户名），不能销毁。但密码想定期换。

**机制**：
```bash
# 一次性: 告诉 Vault "管这个已存在账号的密码, 每 24h 换一次"
vault write database/static-roles/legacy-app \
    db_name=postgres-prod \
    username=app_legacy \           # 已存在账号, 不变
    rotation_period=24h             # Vault 每 24h 改密码

# 业务消费: 读当前最新密码 (用户名固定不变)
vault read database/static-creds/legacy-app
# → username=app_legacy
#   password=<当前 24h 内有效密码>
#   last_vault_rotation=<上次轮换时间>
#   ttl=<距离下次轮换的秒数>
```

业务侧消费方式：**永远引用同一把 `app_legacy` 名字**（账号身份不变），但**密码值跟着 Vault 走**。

> **理解**：static-role 是"**账号外壳不变 + 内壳（密码）Vault 管**"——业务连接串 / 审计身份 / 第三方约束全保留，只是密码这个 secret 被 Vault 接管了。

#### ③ Password policy — 生成密码符合合规规则

**痛点**：合规要求密码必须 ≥ N 位、含大小写 + 数字 + 特殊字符；自动生成的密码必须满足这些规则才能过审。

**机制**：
```bash
vault write sys/policies/password/strong-policy policy=-<<EOF
length = 20
rule "charset" { charset = "abcdefghijklmnopqrstuvwxyz" min-chars = 1 }
rule "charset" { charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" min-chars = 1 }
rule "charset" { charset = "0123456789" min-chars = 1 }
rule "charset" { charset = "!@#\$%^&*" min-chars = 2 }
EOF

# 测试生成一条
vault read sys/policies/password/strong-policy/generate
# → password: <符合上述策略的随机密码>
```

引擎把 password policy 绑到 role / 连接配置上，所有 rotation 出来的新密码自动满足策略。

> **理解**：把"密码合规规则"也变成**集中声明 + 集中复用**的资源——避免每个 engine / role 写一份自己的密码规则。

#### ④ Schedule-based 自动轮换（**Enterprise**）

**痛点**：手动 cron 触发 rotation 容易漏 / 重；要按"每周六凌晨 1 点"这种业务窗口跑，缺机制。

**机制**（仅 Enterprise）：
```bash
vault write database/config/postgres-prod \
    rotation_schedule="0 1 * * SAT" \   # 每周六 1:00
    rotation_window="1h"                # 这个窗口内尝试
```

Vault 按 cron 自动跑 root rotation；`rotation_window` 限定尝试时段，超出窗口跳到下次。

> **理解**：把"运维记得改密码"这件事彻底交给 Vault scheduler，运维 / 合规审计的事件不再依赖人。**OSS 用户需手动 cron + `rotate-root` API 自己实现。**

### 完整工作流（Database 场景）

```
1. 配 engine 连 DB (Vault 一开始用 admin 账号登)
   vault write database/config/postgres-prod \
       plugin_name=postgresql-database-plugin \
       connection_url="postgresql://{{username}}:{{password}}@pg.internal:5432/app" \
       allowed_roles=legacy-app \
       username=vault_admin password=<initial-admin-pass>

2. rotate-root: admin 密码转给 Vault, 人从此登不上
   vault write -force database/rotate-root/postgres-prod

3. 把已存在的业务账号交给 Vault 管
   vault write database/static-roles/legacy-app \
       db_name=postgres-prod \
       username=app_legacy \
       rotation_period=24h \
       password_policy=strong-policy

4. 业务跑时: 每次连 DB 前读最新密码
   vault read database/static-creds/legacy-app
   → (username, password) → 用这对连 PG

5. 每 24h Vault 自动调 PG 改 app_legacy 密码
   下次 vault read 时业务就拿到新密码
```

### 哪些 engine 支持

| Engine | rotate-root | static roles |
|---|---|---|
| Database (PG / MySQL / Mongo / MSSQL / Oracle / ...) | ✅ | ✅ |
| OpenLDAP / AD | ✅ | ✅ |
| AWS | ✅（root IAM key） | ❌（动态为主） |
| Consul / RabbitMQ / Nomad | 部分（取决于 engine） | ❌ |
| KV / Transit / SSH / PKI | ❌ | ❌ |
| GitLab (社区 plugin) | ❌（splunk / ilijamt fork 均未明示） | ❌ |

**"凭据轮换" 是 engine-specific 能力**，**不是 Vault 通用模式**。Database / OpenLDAP / AD 类支持完整；GitLab / 其他 SaaS 类 plugin 当前主要靠"动态凭据"（§2）覆盖，**长期账号的密码周期换需自己实现**。

### 使用场景

| 场景 | 用法 |
|---|---|
| DB 上的长期业务账号定期换密码 | `database/static-roles` + `rotation_period` |
| Vault 自己用的 DB admin 自闭环 | `database/rotate-root`（一次性强制集中治理） |
| 长期 AD 服务账号密码轮换 | `ad/roles` static role（AD engine 支持） |
| 业务读最新密码 | `database/static-creds/<n>`，或配合 §7 Injector / §8 VSO / §9 CSI 自动 refresh |
| Enterprise: 按业务窗口自动跑 | `rotation_schedule="0 1 * * SAT"` + `rotation_window="1h"` |

**不该用凭据轮换的场景**：
- 凭据天然可以"每次现造 + 用完销毁" → 用 §2 动态凭据，更安全
- engine 不支持（如 KV / SSH / GitLab plugin） → 走业务自定义脚本 + Vault audit 兜底

### 一句话本质

> 凭据轮换 = "**账号永远是那个账号，密码 Vault 周期换**"——业务侧用户名固定 + 密码值随时间变 + 自动调外部数据面真改密码 + **engine-specific（database / openldap / ad / aws root）原生支持**。

---

## 6. OSS 五块能力如何在一条链路里组合（收尾回顾）

> §1-§5 是 Vault OSS 提供给业务的 5 块能力：**静态存储 / 动态凭据 / 身份桥接 / 加密服务 / 凭据轮换**。
> 本节用一条 CI 任务的链路把五块串起来，作为 OSS 部分的回顾。**§7 起进入"Pod 怎么集成这些能力"的不同形态**。

```
Pod (sa=ci-runner) 启动
   │
   │ ③ K8s Auth: SA token + role 名 → Vault token (policy=ci-policy, ttl=10m)
   ↓
Vault token 在手
   │
   ├── 读静态 (① KV v2):
   │      vault kv get demo-kv/config/webhook-url
   │      → 拿到第三方 webhook 配置
   │
   ├── 要凭据 (② 动态):
   │      vault read gitlab/roles/ci-runner/token   → 现造 GitLab PAT (10min)
   │      vault read database/creds/migration-rw    → 现造 PG user (5min)
   │      vault write pki/issue/svc common_name=... → 现签 mTLS cert (1min)
   │
   ├── 用加密服务 (④ Transit):
   │      vault write transit/encrypt/data-key plaintext=...   → 加密用户 PII 写库
   │      vault write transit/sign/sig-key input=...           → 签部署清单
   │
   └── 读长期账号当前密码 (⑤ 凭据轮换):
          vault read database/static-creds/legacy-app          → username 固定, 密码 Vault 周期换
   ↓
任务跑完 / TTL 到 / Pod 退出
   │
   ↓
所有短命凭据自动作废 + 长期账号密码已 Vault 接管 + Transit key 安然留在 Vault 内
```

**心智总结**

> Vault 把"长寿命 / 散落 / 不可审计 / 各种凭据 + 各种 key"变成"短寿命 / 集中 / 全审计 / 现要 + 永不出户"——
> - 一切都是 plugin 化的 path 模型
> - **静态** = 存了取（KV v2）
> - **动态** = 要了造（PKI / SSH / DB / Cloud / GitLab plugin）
> - **加密服务** = 借了用（Transit，key 永不出 Vault）
> - **凭据轮换** = 账号不变，密码 Vault 周期换（Database / OpenLDAP / AD 等）
> - **role** = 发放模板，**policy** = 准入规则
> - **K8s Auth** = 把 Pod 身份桥接进 Vault 体系，0 凭据分发

**接下来**：上面这个 Pod 直接调 Vault API 的形态最朴素，但要求业务进程嵌 Vault SDK + 自己写 token / lease 续期逻辑。§7-§9 介绍三条**业务 0 代码改动**的 Pod 集成路径（Injector / VSO / CSI），§10 给选型决策。

---

## 7. Vault Agent Injector — Pod 集成路径之一

> 本节是 **Pod 集成 Vault 的三大路径之一**（另两路径 VSO / CSI Provider 后续章节展开）。共同前提：§3 K8s Auth Method 提供身份桥接。

### 解决什么问题

§3 解决了"Pod 怎么拿 Vault token"，但还有两个真痛点没解决：
1. 业务进程要**自己写代码**调 Vault SDK：login / 取 secret / 续 lease / 处理 token 过期 / 监听 secret 变化——这是侵入式改造，对历史应用 / 多语言栈代价高。
2. 业务镜像里要内置 Vault SDK，跨语言每个栈一份实现。

### 核心模型

> Vault 装一个 **Mutating Admission Webhook（Injector）**。Pod 只要带几个 **annotation**，K8s 创建 Pod 时 Injector 自动给它**塞两个容器**：init 容器先拿 secret 写进共享 volume；业务容器读文件即可；sidecar 在后台续 lease、刷新文件、应急 reload。
>
> **业务代码 0 改动、不引 Vault SDK、不懂 Vault token——只要 `cat /vault/secrets/db.yaml`。**

```
开发者 apply 带 annotation 的 Pod
   ↓
MutatingWebhook (Injector) 改写 Pod spec
   ↓
Pod 真正起来时, 容器布局变成:
  ┌──────────────────────────────┐
  │ init: vault-agent-init       │ 阻塞业务启动直到拿到 secret
  │ business container           │ 你的业务镜像, 0 改动
  │ sidecar: vault-agent         │ 后台续 lease + 监听变化
  │ shared emptyDir /vault/secrets│
  └──────────────────────────────┘
```

### 核心能力清单

#### ① Pod 集成 Vault 0 业务代码改动

**痛点**：业务进程要写 login / get / renew 这一套，对历史 Java/Go/Python/PHP 应用要 PR 改代码 + 升级镜像 + 跨语言一份份实现。
**Injector**：只要 Pod 上贴 annotation，业务进程从 `/vault/secrets/<file>` 读文件就行。
**差别**：所有语言栈通吃；遗留系统从"要改源码"降级到"改 deployment yaml"。

> **理解**：把"业务集成 Vault" 这件事从**改业务代码**降级成**贴 annotation**——对**历史应用 / 多语言异构栈**是质的不同；业务进程从此把 Vault secret 当作普通**配置文件**读。

#### ② 自动续 lease / token / 应对动态凭据过期

**痛点**：业务自己接 Vault SDK 时，**最难写对的就是续期逻辑**——token TTL 到了要 renew，renew 失败要重新 login；动态凭据有 lease 也要续；写错就半夜被叫醒。
**Injector**：sidecar 后台跑一个 vault-agent 进程，**所有续期 / 重新 login / 重新拿 secret 都由它干**。业务侧没感知。
**差别**：业务侧从"必须懂 lease 续期 + token 轮换"降到"读文件即可"。

> **理解**：sidecar 是个**后台无声运行的"个人代理"**，替业务把 token 和 lease 永远维持活的，业务感觉是个**永不过期的配置**。

#### ③ Secret 变化的应用层反应

**痛点**：动态凭据 5 分钟一换，配置中心 secret 改了——业务进程怎么知道？传统做法要业务自己 watch / 轮询 / 重启。
**Injector**：
- secret 变 → sidecar 重写 `/vault/secrets/<file>`
- 可选 annotation: `agent-inject-command-<file>: "kill -HUP 1"` → 改完直接给业务进程发信号让它 reload

**差别**：业务侧不用任何 watch / 轮询代码；只需要支持 reload 信号（nginx / app server 一般都支持），自动跟随 secret 变化。

> **理解**：Vault 的"动态凭据自动旋转"能力终于真正穿透到了业务进程——以前业务没法消费动态凭据（不会续），现在 Injector 帮它续 + 自动 reload。

#### ④ Pod 退出自动清理

**痛点**：Pod 死了，但 Vault token 和 lease 还活着（要等 TTL 自然到期），留下小窗口的安全风险。
**Injector**：sidecar 在 Pod 退出时调用 `vault token revoke-self` + lease revoke，**Vault 端立即清零**。
**差别**：Pod 生命周期和 Vault 凭据生命周期**严格对齐**，无残留。

> **理解**：业务 Pod 死 = Vault 凭据死。"扩缩容 / 重调度 / 节点掉" 不会留下脏数据。

#### ⑤ 跨语言 / 文件协议作为统一接口

**痛点**：业务栈五花八门（Spring Boot / Node / Python / 老 PHP / Go），每个都要 Vault SDK 太贵。
**Injector**：用**文件**当接口——所有语言都会读文件。
**差别**：维护一个 Injector 替代维护 N 套 SDK；新加一种语言 0 工作量。

> **理解**：用最简单的"文件"做接口，反而**解放了语言绑定问题**——Injector 的方案在"集成成本"上对组织非常友好。

### 最小命令示例 / Pod YAML

**Injector 自身安装（运维一次性）**

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
    --set "injector.enabled=true" \
    --set "server.enabled=false"   # 只装 injector, 复用已有 Vault
```

装好后包括：
- `vault-agent-injector` Deployment
- `MutatingWebhookConfiguration vault-agent-injector-cfg`
- `vault-agent-injector-svc` Service

**业务 Pod 例**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "git-reader"                       # K8s auth role (§3)
    vault.hashicorp.com/agent-inject-secret-db.yaml: "demo-kv/data/git/test"
    vault.hashicorp.com/agent-inject-template-db.yaml: |
      {{- with secret "demo-kv/data/git/test" -}}
      repo: {{ .Data.data.repo }}
      token: {{ .Data.data.token }}
      {{- end }}
    # 可选: secret 变了让业务 reload
    vault.hashicorp.com/agent-inject-command-db.yaml: "kill -HUP 1"
spec:
  serviceAccountName: app-reader        # §3 里建的 SA
  containers:
  - name: app
    image: my-app:latest
    # 业务代码: 只需读 /vault/secrets/db.yaml
```

**Pod 起来后业务侧看到的**

```
$ cat /vault/secrets/db.yaml
repo: secret-repo
token: ghp_demo_token_xxx
```

业务进程把它当**普通配置文件**读。

**常用 Annotation 速查**

| Annotation | 含义 |
|---|---|
| `agent-inject: "true"` | 启用注入 |
| `role: "<name>"` | 用哪个 K8s auth role |
| `agent-inject-secret-<file>` | 哪条 Vault path → 落到这个文件名 |
| `agent-inject-template-<file>` | 自定义渲染（Go template） |
| `agent-inject-command-<file>` | secret 变了执行这个命令（如 `kill -HUP 1` 让业务 reload） |
| `agent-pre-populate-only: "true"` | 只 init 一次拿，不留 sidecar（**无续期**） |
| `agent-inject-status` | Injector 自动写入的注入状态标识（已注入会写成 `injected`），防止重复 mutate；与 secret 文件刷新机制无关。文件刷新由 sidecar template renderer 自动负责，按 `agent-inject-template`/`agent-inject-secret` 决定 |
| `tls-skip-verify: "true"` | 测试环境用 |

### 使用场景

| 场景 | 用法 |
|---|---|
| 历史 Java/Go/Python/PHP 应用接 Vault | 加 annotation；业务读 `/vault/secrets/<file>` |
| CI 任务现要 GitLab PAT / DB 凭据 | annotation + role + 动态凭据 path；sidecar 后台续 lease |
| 配置中心的 API key 集中下发 | annotation + role + KV v2 path；secret 变就 `kill -HUP` reload |
| 一次性 Job 不需要续期 | `agent-pre-populate-only: "true"`，只 init 一次拿 |

**不该用 Injector 的场景**：
- 业务**只接受 K8s Secret 资源**而不接受文件 → 用 **VSO**（§下节）
- 业务用 **CSI volume 模式**统一管理外部 secret → 用 **CSI Provider**（§下下节）
- **完全无业务 Pod**（如 CronJob 短任务）→ 用 Vault Agent standalone 或直接 vault CLI

### 一句话本质

> Vault Agent Injector = "**Pod 贴 annotation，Vault Agent 进 Pod 当个人秘书**"——业务进程从此把 Vault secret 当**配置文件**读；token / lease / 续期 / 应急 reload 都被 sidecar 接管，业务**永远不需要懂 Vault**。

---

## 8. VSO（Vault Secrets Operator）— Pod 集成路径之二

> 同样基于 §3 K8s Auth Method，但走 **K8s Operator + CRD** 的形态，把 Vault secret **同步成原生 K8s Secret 资源**，业务侧用任何"读 K8s Secret"的方式都行。

### 解决什么问题

Injector 给业务侧"文件接口"，但有些场景这条路不顺：
1. 业务**已经习惯了用 K8s Secret**（env var / volumeMount），改成读 `/vault/secrets/<file>` 反倒动了部署习惯。
2. **多个 Pod 要共享同一份 secret**（比如同一 Deployment 多副本、CronJob 与主服务共用）——Injector 每个 Pod 注入一份 sidecar 太重。
3. 业务镜像里不想被塞 sidecar 容器（资源占用、监控告警、调试干扰）。

### 核心模型

> 在集群里跑一个 **Vault Secrets Operator**。开发者写一类 CRD（`VaultStaticSecret` / `VaultDynamicSecret` / `VaultPKISecret`）声明"我要哪条 Vault path → 同步成哪个 K8s Secret"；VSO 周期 reconcile：用 K8s SA 换 Vault token、拉 secret、**写到目标 namespace 的 K8s Secret 资源里**。业务 Pod 用普通 `envFrom` / `volumeMount: secret:` 消费。

```
                  ┌──────────────────────────┐
   apply CRD ──→ │  VaultStaticSecret CR    │
                  │  "把 Vault demo-kv/data/git/test │
                  │   同步成 ns/git-secret"   │
                  └──────────┬───────────────┘
                             ↓
                  ┌──────────────────────────┐
                  │ Vault Secrets Operator   │ ← reconcile loop
                  │ (一个 Deployment, 一次装) │
                  └──────────┬───────────────┘
                             │ K8s Auth: SA → Vault token
                             ↓
                  ┌──────────────────────────┐
                  │ Vault: 读 secret         │
                  └──────────┬───────────────┘
                             ↓
                  ┌──────────────────────────┐
                  │ K8s Secret/git-secret    │ ← Operator 写进来
                  └──────────┬───────────────┘
                             ↓
                  ┌──────────────────────────┐
                  │ 任何业务 Pod              │
                  │  envFrom: git-secret      │ ← 用标准 K8s 方式消费
                  └──────────────────────────┘
```

### 核心能力清单

#### ① 业务侧零侵入 + 标准 K8s Secret 消费方式

**痛点**：业务镜像已经用了 `env:` / `envFrom:` / `volumeMount: secret:` 消费 K8s Secret，改去读 `/vault/secrets/<file>` 等于改部署模板。
**VSO**：业务 Deployment 0 改动，只是把 Secret 的"来源"从手工创建改成"VSO 同步出来"。
**差别**：现有应用接 Vault 完全不动应用层（包括 Helm chart、Kustomize、ArgoCD app），只在集群里多了几个 CRD。

> **理解**：VSO 把"接 Vault" 这件事**完全收敛到平台层**——应用层仍然只看到 K8s Secret，对部署链路、GitOps 流程、Helm Chart 都零冲击。

#### ② 多 Pod 共享同一份 secret，无需多套 sidecar

**痛点**：Injector 是 Pod 级注入——同一 Deployment 5 副本要 5 个 sidecar，CronJob 每次起一次任务要 init 一次拿 secret，资源浪费 + Vault 请求放大。
**VSO**：同一份 K8s Secret 任意多 Pod 共享，VSO 自己用一个 reconcile loop 维护就够。
**差别**：Vault 端 QPS 与 Pod 数解耦——10 个副本和 100 个副本对 Vault 的负担一样。

> **理解**：VSO 是**集群级单例代理**，对 Vault 的访问按"需求量"而非"Pod 数"聚合，对大规模部署更友好。

#### ③ CRD 是声明式的，与 GitOps 天然合拍

**痛点**：Injector annotation 散在每个 Pod 上；CronJob / Job / 独立 Pod 各自一份。同步关系不集中。
**VSO**：所有"我要什么 Vault path → 落哪个 K8s Secret" 集中在 CRD 里。可以 git 管、Argo 同步、统一 review。
**差别**：secret 同步配置变成**头等公民资源**，可观测 / 可审计 / 可回滚。

> **理解**：把"Vault 同步配置"也纳入 GitOps，**和应用 manifest 一起走 PR 评审**——平台治理上比 Injector annotation 更严谨。

#### ④ 自动周期 reconcile + 检测 secret 变化重写 K8s Secret

**痛点**：动态凭据 5 分钟一过期，谁刷新？静态 KV 改了，谁推到业务侧？
**VSO**：
- 静态 secret：可配 `refreshAfter`（duration，例如 `30s`/`1h`，无内置默认；不配则不周期 refresh，依赖 CR 变更触发 reconcile）
- 动态凭据：按 TTL 智能续期/重新发，并写回 K8s Secret
- K8s Secret 改了 → Deployment 不会自动重启，但可以配 `rolloutRestartTargets` 让 VSO **主动重启目标 Deployment / StatefulSet / DaemonSet**

**差别**：业务侧仍然用普通 K8s Secret 消费，但背后是一个会自动跟随 Vault 变化的 Secret。

> **理解**：VSO 让 K8s Secret 从"死的静态资源"升级成"活的、跟 Vault 同步的镜像"，业务层不变。

### 最小命令示例 / CRD 样例

**安装**

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
    -n vault-secrets-operator-system --create-namespace
```

**全局 VaultAuth + VaultConnection 配置（运维一次性）**

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault
  namespace: vso-system
spec:
  address: http://vault.devops-valult-invest.svc:8200
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth-default
  namespace: vso-system
spec:
  vaultConnectionRef: vault
  method: kubernetes
  mount: kubernetes              # vault auth/kubernetes 的 mount
  kubernetes:
    role: git-reader             # 见 §3 里建的 role
    serviceAccount: app-reader   # 业务 ns 里的 SA
```

**业务侧只写一条 CRD**

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: git-secret-sync
  namespace: my-app-ns
spec:
  vaultAuthRef: vault-auth-default
  mount: demo-kv
  type: kv-v2
  path: git/test                # Vault 路径
  refreshAfter: 30s             # 周期 reconcile 间隔
  destination:
    name: git-secret            # 同步成 K8s Secret 名字
    create: true
    type: Opaque
  rolloutRestartTargets:        # secret 变了 → 自动 rollout
  - kind: Deployment
    name: my-app
```

**业务 Pod 用普通方式消费**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
      - name: app
        image: my-app:latest
        envFrom:
        - secretRef:
            name: git-secret   # 普通 K8s Secret 引用, VSO 在背后自动同步
```

**动态凭据样例**

```yaml
kind: VaultDynamicSecret
spec:
  mount: database
  path: creds/readonly
  destination:
    name: db-creds
    create: true
  renewalPercent: 67          # 用掉 67% TTL 时自动续
  rolloutRestartTargets: [...]
```

### 使用场景

| 场景 | 用法 |
|---|---|
| 已有应用用 K8s Secret env / volume 消费 | VaultStaticSecret 同步成同名 K8s Secret 即可 |
| 多副本 / Job / CronJob 共用同一份 secret | 集群级 VSO 同步一次, 多消费方共享 |
| GitOps 流（ArgoCD / Flux）管 secret 来源 | CRD 进 git, 同 PR 流程评审 |
| 动态凭据 + 想自动 rollout 业务 | `VaultDynamicSecret + rolloutRestartTargets` |

**不该用 VSO 的场景**：
- 业务**只能从文件读**（不接受 env / volumeSecret） → Injector
- 需要**Pod 启动时强保证 secret 在文件里**（Pod 起来前必须就绪） → Injector 的 init container 保证更直接
- 业务对"K8s Secret 中转"的暴露面不接受（如 etcd 加密未开） → CSI Provider 可绕过 K8s Secret

### 一句话本质

> VSO = "**应用层不动，平台层引一个 Operator 把 Vault 同步成 K8s Secret**"——业务用最标准的 K8s 方式消费，所有"接 Vault" 的复杂度都收在一个集群单例里，CRD 进 GitOps。

---

## 9. CSI Provider — Pod 集成路径之三

> 走 Kubernetes 官方的 **Secrets Store CSI Driver** + **Vault Provider** 组合。Pod 在 spec 里挂一个 CSI volume，Pod 调度时 driver 调 Vault provider 拉 secret，**直接挂载成 volume**。可选同步到 K8s Secret。

### 解决什么问题

Injector 和 VSO 都有"secret 经过 K8s API / etcd"的暴露面，且需要"业务镜像 / Pod 接受改造"。某些场景要求更严：
1. **secret 绝不进 etcd / K8s Secret**（合规 / etcd 未加密 / 不信任 etcd 备份链）
2. **挂载语义统一**——业务已经用 CSI volume 模式管所有外部资源（云盘 / SMB / NFS），希望 secret 也走这套
3. **节点级凭据**——希望 secret 跟随 Pod 调度的节点动态获取（不通过控制面中转）

### 核心模型

> Pod spec 声明一个 **CSI volume**，driver 是 `secrets-store.csi.k8s.io`，参数指向一个 **SecretProviderClass** CRD。
> 调度后，**Secrets Store CSI Driver**（DaemonSet）在 kubelet 调 mount 时调 **Vault Provider**（gRPC），后者用 K8s auth 换 Vault token、读 secret，把内容**直接落进 tmpfs**挂给 Pod。**默认不经过 K8s Secret 资源**。

```
                ┌────────────────────────┐
   apply CRD ──→│  SecretProviderClass    │
                │  "从 Vault demo-kv/data/git/test │
                │   挂载到 /mnt/secrets/db.json"   │
                └────────────┬─────────────┘
                              ↓
                ┌────────────────────────────┐
                │ Pod spec 挂 CSI volume      │
                │ driver: secrets-store.csi.k8s.io│
                └────────────┬─────────────┘
                              │
                              ↓ kubelet 调 mount
                ┌────────────────────────────┐
                │ Secrets Store CSI Driver    │ ← DaemonSet 每节点一个
                └────────────┬─────────────┘
                              │ gRPC
                              ↓
                ┌────────────────────────────┐
                │ Vault CSI Provider          │ ← DaemonSet, 同节点
                │   K8s Auth → Vault token    │
                │   读 secret → 写 tmpfs       │
                └────────────┬─────────────┘
                              ↓
                ┌────────────────────────────┐
                │ Pod /mnt/secrets/db.json    │ ← tmpfs 挂载, 不进 etcd
                └────────────────────────────┘
```

### 核心能力清单

#### ① Secret 不进 etcd / K8s Secret，仅 tmpfs

**痛点**：K8s Secret 在 etcd 里默认明文存储；即使开了 EncryptionConfig，备份链 / 灾备 / kubectl get secret 都暴露面。
**CSI**：secret 在节点 tmpfs（内存盘），Pod 死 → 内存释放 → secret 消失，**etcd 全程无知**。
**差别**：合规更严 / 不信任控制面的场景下，CSI 是唯一可选路径。

> **理解**：CSI 把 secret "落地" 这件事从控制面（etcd）拉到节点（tmpfs），**信任锚只到 Vault 和当前节点的 kubelet**——暴露面最小。

#### ② Pod 级 volume 挂载，与现有 PV / PVC 习惯一致

**痛点**：业务团队已经习惯用 volume mount 管资源（云盘 / NFS / configMap），单独为 secret 用 Injector sidecar 或 VSO 等显得不一致。
**CSI**：和 PVC 同一套机制——`spec.volumes[].csi`，业务镜像里 mount 路径即用。
**差别**：运维 / 监控 / 故障排查链路全复用现有 volume 那套（kubelet 日志、节点诊断等）。

> **理解**：CSI 走的是 K8s 通用的 volume 协议，**和 Pod 已有的 volume 文化一致**——平台和业务运维都不增加新概念。

#### ③ 节点级 Provider，进程 / 连接按节点聚合

**痛点**：1000 Pod 各自跑 sidecar 时（如 Injector）= 1000 个进程 + 1000 条 Vault 连接，内存和连接数都吃紧。
**CSI**：Provider 是节点级 DaemonSet——一节点只 1 个 provider 进程，跑 N 个 Pod 的挂载也复用同一进程 + 同一份 gRPC 长连接。
**差别**：节点上**进程数 / 内存 / 连接数**按节点而非 Pod 算，超大集群和高副本场景资源占用低。

> **理解**：CSI Provider 在**节点这一层**做了**进程和连接的聚合**——**不是 token 共享**。每个 Pod 仍用自己 SA 单独 login Vault、拿独立 token，Vault 端审计粒度不变。聚合的是**节点上的运行时资源**，不是 Vault 端 QPS（QPS 仍按 Pod 算）。

#### ④ 可选同步到 K8s Secret（既要 tmpfs 又要给 env 用）

**痛点**：业务想用 envFrom（K8s Secret），又想 secret 落地在 tmpfs 而非 etcd。
**CSI**：SecretProviderClass 的 `secretObjects` 字段可选生成 K8s Secret——挂 volume 时同步写一份；Pod 死时清。**配 etcd EncryptionConfig 时合规上可接受**。
**差别**：可在"严格 tmpfs-only" 和 "兼容 envFrom" 之间灵活选。

### 最小命令示例 / Pod YAML

**安装（两个 DaemonSet）**

```bash
# 1. Secrets Store CSI Driver (K8s 官方)
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
    -n kube-system

# 2. Vault Provider (HashiCorp)
helm install vault-csi-provider hashicorp/vault \
    --set "injector.enabled=false" \
    --set "csi.enabled=true" \
    --set "server.enabled=false"
```

**SecretProviderClass（运维 / 应用一次性）**

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-git-secret
  namespace: my-app-ns
spec:
  provider: vault
  parameters:
    roleName: "git-reader"             # §3 里建的 K8s auth role
    vaultAddress: "http://vault.devops-valult-invest.svc:8200"
    objects: |
      - objectName: "db.json"
        secretPath: "demo-kv/data/git/test"
        secretKey: "token"             # 取这一个字段; 不写则全量 JSON
  # 可选: 同步成 K8s Secret 供 envFrom 使用
  secretObjects:
  - secretName: git-secret
    type: Opaque
    data:
    - objectName: db.json
      key: token
```

**业务 Pod**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  serviceAccountName: app-reader     # §3 SA
  containers:
  - name: app
    image: my-app:latest
    volumeMounts:
    - name: vault-secrets
      mountPath: /mnt/secrets
      readOnly: true
    # 可选: envFrom 用 secretObjects 生成的 K8s Secret
    envFrom:
    - secretRef:
        name: git-secret
  volumes:
  - name: vault-secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "vault-git-secret"
```

业务看到：
```
$ cat /mnt/secrets/db.json
ghp_demo_token_xxx
```

### 设计说明：为什么用 SecretProviderClass 这层抽象

Pod spec 里**不直接写** Vault path / role / 地址，而是引用一个 `SecretProviderClass`（SPC）的名字。原因有 5 个：

1. **关注点分离**：平台 / 安全团队握 SPC 创建权（写 Vault path + role 映射），开发团队只能引用；K8s RBAC 上把 SPC 和 Pod 分开授权，避免 Dev 自己在 Pod 里乱写 Vault path。
2. **复用 DRY**：一份 SPC 可被多个 Pod / Deployment / Job 引用；改 path 或 role 只动一处。
3. **治理点集中**：SPC 是 CRD，可走 webhook / OPA / Kyverno 审（只允许引用特定 mount、必须打 owner label 等）——比挨个 Pod 审简单一个量级。
4. **Provider 无关**：SPC 的 `provider:` 字段决定底层（Vault / AWS Secrets Manager / Azure Key Vault），换底层只动 SPC，业务 Pod 不变。
5. **K8s 范式一致**：和 `StorageClass`、`CSIDriver` 同一套"class + reference"抽象——Pod 持有"引用名"，详细配置住在 class 资源里。

**反例**：如果允许 Pod 直接声明，等于把 Vault 访问权下放给所有 deployer——治理 / 审计失控。

### 续期机制说明（CSI 在三路径里最弱的一环）

CSI Provider 不像 Injector 那样长期持 token 不停续；通常每次"挂载事件"（mount / rotation tick）现 login 一次拿短 TTL Vault token，用后短 TTL 自然失效（具体 token 生命周期由 provider 实现决定）。但 mount 完后**tmpfs 默认就静止了**——动态凭据 / 静态 secret 在 Pod 生命周期内不会自动跟随 Vault 变化。

| 想刷新怎么办 | 机制 | 局限 |
|---|---|---|
| A. 开 driver 级 rotation reconciler | `--enable-secret-rotation=true` + `--rotation-poll-interval=2m`，driver 轮询重做 mount | 轮询非事件驱动；**不会自动重启业务 Pod**；动态凭据没"按 TTL 智能续" |
| B. 同步成 K8s Secret 让业务消费 | SPC `secretObjects` 字段 | `envFrom` 模式 env 不会变（Pod 启动定型）；`volumeMount: secret:` 文件会变（延迟取决于 kubelet 同步周期，默认约 1min，可配 `--sync-frequency`）；失去"不进 etcd"卖点 |
| C. 依赖 Pod 重启换新 secret | 配合 HPA / 滚动更新 / 调度变更 | 长跑业务需外部触发重启；最常用于 Job / CronJob |

**实务结论**：CSI 选型主要是冲"**secret 不进 etcd**"这个合规属性，**不是冲"实时跟随 Vault"**。要实时跟随用 Injector / VSO。

### 使用场景

| 场景 | 用法 |
|---|---|
| 合规要求 secret 不进 etcd | CSI + 不开 secretObjects |
| 团队统一用 volume 模式管所有外部资源 | CSI + mountPath |
| 超大集群 / 高副本数 Pod 拉同一 secret | CSI Provider 节点级聚合 |
| 既要 volume 挂载又要 envFrom | CSI + secretObjects 同步一份 K8s Secret |

**不该用 CSI 的场景**：
- 集群没装 CSI driver / 不想新增基础设施依赖 → 用 Injector 或 VSO
- 业务镜像不支持读 volume 文件（只读 env） → VSO（K8s Secret + envFrom）
- 一次性 Job 不挂 volume 习惯 → Injector

### 一句话本质

> CSI Provider = "**Pod 挂 CSI volume，secret 落在节点 tmpfs，etcd 全程无知**"——合规最严、暴露面最小的 Pod 集成路径，与 K8s volume 文化一致；对集群基础设施依赖最重。

---

## 10. Pod 集成三路径选型决策

§7 / §8 / §9 三个路径**都**基于 §3 的 K8s Auth Method，差别只在**形态**和**信任面**。

| 维度 | §7 Injector | §8 VSO | §9 CSI Provider |
|---|---|---|---|
| 形态 | Pod 内 sidecar | 集群 Operator + K8s Secret | Pod 挂 CSI volume |
| 业务看到 | `/vault/secrets/<file>` | K8s Secret (env/volume) | volume 挂 tmpfs |
| 是否改 Pod spec | ✅ Injector 注入 init+sidecar | ❌ Pod 0 感知 | ✅ 声明 CSI volume |
| Secret 经过 etcd | ❌（只在 Pod 内 volume） | ✅（落到 K8s Secret） | ❌（默认 tmpfs；可选同步 K8s Secret） |
| 续期 / 自动 refresh | Sidecar 后台 | Operator reconcile | driver 拉新；secret 变化感知弱 |
| Vault 端 QPS | 每 Pod 一次 login | 集群级单次 | 每节点级聚合 |
| 多 Pod 共享 secret | ❌（每 Pod 独立 sidecar） | ✅（共享 K8s Secret） | ❌（每 Pod 各自挂载） |
| 业务代码改动 | 0 (读文件) | 0 (envFrom) | 0 (读 volume) |
| 适合 | 遗留应用 / 文件接口 / 动态凭据 + reload | 现有 K8s Secret 栈 / 多副本共享 / GitOps | 合规严苛 / 不信任 etcd / volume 文化 |
| 安装成本 | 1 个 Deployment + Webhook | 1 个 Operator + CRD | 2 个 DaemonSet（driver + provider） |

**一句话挑选**

- 历史应用、动态凭据 + 想要 `kill -HUP` reload、单 Pod 场景 → **Injector**
- 现有应用习惯 K8s Secret、多副本共享、GitOps 流 → **VSO**
- 合规不接受 etcd / 不信任控制面 / volume 文化已成熟 → **CSI Provider**

很多企业实际混用：**核心业务跑 VSO（共享 + GitOps），合规敏感链路跑 CSI（不进 etcd），遗留应用跑 Injector（0 改动）**。

---

## Vault Enterprise 三件套概览

§11-§13 是 Vault **Enterprise 专属**能力，OSS 没有原生对等物。三者分别覆盖企业级 Vault 部署的三个独立痛点：

| 章节 | 解决什么 | OSS 替代方案 |
|---|---|---|
| **§11 Replication + Namespaces** | 跨 region 部署 + 多团队 / 多客户隔离 | 自建多 Vault 集群 + 数据同步脚本（粗糙） |
| **§12 Control Groups** | path 级 N-of-M 审批工作流 | 业务侧自建审批 + 业务调 Vault 前先过审批服务 |
| **§13 Sentinel** | 策略即代码（条件 / 行为 / 上下文断言） | OPA + 应用层校验（不集成进 Vault 请求链） |

**许可与试用**
- Vault Enterprise 需 license，可向 HashiCorp 申请 30 天免费试用
- HCP Vault Dedicated（SaaS 托管 Vault）也提供 Enterprise 功能
- BSL 1.1 许可（2023 年从 MPL 改）——非 production 评估可用 Community Edition

**谁会买**
- 金融 / 政府 / 关键基础设施（合规驱动）
- 全球部署多 region 业务（性能 / 容灾驱动）
- 多团队 / 多 BU 共用一套 Vault（治理驱动）

---

## 11. Replication + Namespaces — 跨集群 + 多租户（**仅 Enterprise**）

> ⚠️ 本节涵盖的能力**只在 Vault Enterprise 版本**提供。OSS 单实例 / 单集群 HA 之外**没有原生对等物**，需要 Enterprise license。

### 解决什么问题

OSS Vault 是**单集群扁平共享**——所有团队 / 客户用同一份 policy / engine / token 命名空间，跨 region 调单一 Vault 延迟高且单点故障。两类企业级痛点没法覆盖：
1. **跨集群 / 跨 region 分发 + 容灾**：业务在全球多 region 都想读本地 Vault 低延迟；主集群挂了要能切换
2. **多团队 / 多客户隔离**：一个 Vault 集群给 N 个团队 / BU / 外部客户用，**它们的 policy / engine / token / 审计要完全隔离**

### 核心模型

**Replication**（跨集群复制）有两形态：

| 形态 | 干啥 | 特点 |
|---|---|---|
| **Performance Replication** | 把 primary 的状态流式复制到 N 个 secondary | secondary **接业务流量**：本地读，写自动转 primary；适合多 region 共享一份状态 |
| **DR (Disaster Recovery) Replication** | 备一个完全镜像的待命集群 | secondary **不接流量**，纯镜像；primary 死后 promote 切换；适合容灾 |

```
Performance Replication:           DR Replication:
─────────────────────             ─────────────
Primary (写+读)                    Primary (全量)
   │ stream                            │ stream
   ↓                                   ↓
Secondary-A (读)                   DR Secondary (待命, 不收流量)
Secondary-B (读)                   primary 挂时 promote
Secondary-C (读)
```

**Namespaces**（多租户）= **Vault 内的子 Vault**：

```
root namespace (/)
├── team-payments/        ← 完全独立的子 Vault
│   ├── secrets engines (KV / PKI / ...)
│   ├── auth methods (K8s / OIDC / ...)
│   ├── policies
│   ├── tokens
│   └── audit
├── team-ml/
└── customer-acme/        ← 外部客户隔离空间
```

每个 namespace 像独立 Vault 工作：policy / engine / token 全独立；team-payments 看不见 team-ml 任何东西。**和 K8s namespace 同名但毫无关系**——是 Vault 内的租户边界。

**两者怎么配合**：Performance Replication **可按 namespace 选择性复制**——payments 只复制到亚太 secondary，欧洲不复制，省带宽 + 满足数据驻留合规（数据不出指定 region）。

### 核心能力清单

#### ① 跨集群 HA + 跨 region 读热点

**痛点**：单 Vault 单 region 部署时，全球业务都得绕回那 1 个集群读 secret，跨洋 RTT 太高；主集群挂了所有业务停。
**Performance Replication**：每 region 一个 secondary，业务读本地，写自动转 primary；primary 挂了 promote secondary 接管。
**差别**：地理就近 + HA 能力一次性都有。

> **理解**：把"全球 1 个 Vault" 变成"全球同步状态的多副本 Vault"——业务在哪 region 都看到同一份 secret 状态，本地读不绕远。

#### ② 灾难恢复 + 数据驻留合规

**痛点**：合规要求"主集群整体崩 + 数据不能跨境"两类约束同时满足。
**DR Replication + namespace 选择性复制**：DR 满足容灾；按 namespace 决定哪些复制到哪 region 满足驻留。
**差别**：合规边界从"全集群同进同退" 变成"按 namespace 切分"。

> **理解**：复制颗粒度从"集群级"细化到"namespace 级"——金融 / 政府 / 跨境业务客户的真实合规需求都能落到这一层。

#### ③ 多团队 / 多客户隔离

**痛点**：OSS Vault 所有 token / policy / engine 全扁平，团队多了治理灾难；一个团队的失误能影响别的团队。
**Namespaces**：每个 namespace 是"独立的 Vault 实例体验"，policy / engine / token / 审计各自独立。
**差别**：1 个 Vault 集群可托管 N 个团队 / 客户，互不干扰。

> **理解**：Vault 从"单租户工具" 升级为"**平台化 Vault 服务**"——平台团队卖 namespace 给业务团队 / 外部客户。

#### ④ Namespace 级 policy + 审计 + 委派

**痛点**：root admin 必须直接管所有人的 policy 是不可扩展的；想下放权限又怕越权。
**Namespaces**：每个 namespace 有自己的 admin，**只能管本 namespace 内的 policy / engine / audit**，root admin 不必参与。
**差别**：治理层级化——root 管 namespace 创建 / 配额，namespace admin 管自家域内事。

> **理解**：把 "Vault 中心化治理" 变成 "**分层授权**"——大组织的 IAM 实际操作模式直接对齐。

### 使用场景

| 场景 | 用法 |
|---|---|
| 全球部署跨 region 业务 | Performance Replication 多副本 |
| 异地容灾 + 数据驻留 | DR Replication + namespace 选择性复制 |
| 一个集群给 N 个团队 / 客户用 | Namespaces 隔离 |
| 平台团队卖 Vault 服务给业务团队 | namespace + 委派 admin |

### 一句话本质

> Replication + Namespaces 把单集群单租户的 OSS Vault 扩成"**跨 region 多活 + 多团队隔离的平台化 Vault**"——大企业 / 多云 / 多客户场景治理整个组织的基础。**OSS 没有原生对等物**，必须 Enterprise。

---

## 12. Control Groups — 审批门控（**仅 Enterprise**）

> ⚠️ 仅 Vault Enterprise / HCP Vault Dedicated 提供。OSS 没有原生 N-of-M 审批工作流。

### 解决什么问题

高敏感 Vault 操作（读生产 root 密码 / 撤销关键 lease / 跨 region 配置变更）**不能任由单人完成**——合规和风控都要求"N 人审批后才放行"。OSS Vault 的 policy 只能"允许 / 拒绝"二元，缺**审批工作流**。

### 核心模型

> 在 policy 上给某些 path **挂"审批闸门"**。请求者调这条 path 时 Vault **不直接返回真值**，而是返回 `(wrap_token, accessor)`：
> - **wrap_token** = "提货单"，请求者持有，用于审批通过后 `vault unwrap` 取真值
> - **accessor** = "请求引用编号"，发给审批人 + 公开化的字符串
>
> 审批人用自己的 Vault token + accessor 调 `sys/control-group/authorize`；达到 **N-of-M** 阈值后请求者才能 unwrap。

**policy 大概长这样**：
```hcl
path "secret/production/root-password" {
  capabilities = ["read"]
  control_group = {
    factor "ops_team" {
      identity {
        group_names = ["ops-approvers"]    # 这个 Vault Identity group 的成员
        approvals = 2                       # 凑够 2 个
      }
    }
    factor "security" {
      identity {
        group_names = ["security-officers"] # 还得这个 group 出 1 人
        approvals = 1
      }
    }
  }
}
```

**多 factor 是 AND 关系**——要"2 个 ops + 1 个 security" **同时**满足。

### 核心能力清单

#### ① N-of-M 多人审批门控

**痛点**：高风险操作不能单人完成，OSS 的二元 policy 不够用。
**Control Groups**：policy 直接声明 "N-of-M" 阈值，Vault 内建审批工作流。
**差别**：高敏感 path 从"谁有权限谁就能拿" 升级到"凑齐人头才能拿"。

> **理解**：把"高风险操作" 从"单人完成" 升级到"N 人审签"——金融 / 政府 / 关键基础设施合规刚需。

#### ② 审批挂在 path 维度，可精确到操作粒度

**痛点**：传统审批是粗粒度的"账号离职" / "权限申请"，无法精确到"今天上午这个具体读操作"。
**Control Groups**：审批挂在 path（甚至特定 capability）上，每次调用都触发独立审批流。
**差别**：审批负担可控——不是"开权限给你管所有事"，而是"这一次操作单独审"。

#### ③ Multi-factor 复合审批（跨部门会签）

**痛点**：合规要求"既要业务负责人批又要安全官批"，要落实到机制层面。
**Control Groups**：一条 path 可挂多个 factor（不同 identity group），AND 关系。
**差别**：跨部门会签 / 多角色制衡有了机制保证，不靠流程纪律。

#### ④ Wrapping token + accessor 双轨设计（安全边界）

**核心安全设计**

```
请求者: 持 wrap_token (= 取真值的钥匙)  ← 死守, 别给别人
        持 accessor   (= 请求引用编号)   ← 公开发给审批人

审批人: 拿 accessor 知道"哪个请求要审"
        但拿 accessor 取不了真值
        即使邮箱/Slack 被入侵泄露 accessor → 攻击者只能"看到请求", 不能 unwrap
        要 unwrap 必须既有 wrap_token (在请求者手里), 又凑齐审批 → 流程不可绕
```

| | accessor | wrap_token |
|---|---|---|
| 谁拿 | 审批人 | 请求者 |
| 能干啥 | 审批 / 查元信息 / 撤销 | 取真值 |
| 泄露代价 | 攻击者只能批准，**取不到真值** | 攻击者能 unwrap 取真值 |

> **理解**：**审批信号和取值能力分离**——审批人邮箱 / Slack 被入侵也不会泄露 secret；请求者机器被攻破也无法绕过审批拿。

#### ⑤ 同一人不能重复投票

**机制**：每个 entity 投一票，同 entity_id 第二次 authorize 被拒；alice 重新登录拿新 token 也不行（entity 不变）。

### 完整流程（精确版）

> 1. **policy 声明**：哪些 path 触发审批 + 几人 + 来自哪些 group（可多 factor AND 组合）
> 2. **客户端读 path** → Vault 返回 `(wrap_token 取值钥匙, accessor 请求引用编号)`
> 3. **客户端把 accessor 发给审批人**（**wrap_token 自己留好**）
> 4. **审批人用自己 Vault token + accessor** 调 `sys/control-group/authorize`
> 5. **Vault 校验**：token 有效 + 对应 entity 在 policy 指定的 `group_names` 里 + 同 entity 未重复投过 → 计 1 票
> 6. 凑齐 factor 阈值后客户端 `vault unwrap <wrap_token>` **拿到真值**

### 使用场景

| 场景 | 用法 |
|---|---|
| 生产 root 密码取用要双人审签 | path `secret/production/*` 挂 CG，approvals=2 |
| 跨 region rotation 触发要安全官 sign-off | path `sys/replication/...` 挂 CG，factor 含安全组 |
| 跨团队 sensitive secret 跨借用 | path `secret/cross-team/<x>` 挂多 factor 审签 |
| 离职 / 应急访问审计追溯 | wrap accessor 记录全链路谁审了 |

### 关键限制（落地工程量）

- **无内建审批 UI**：所有交互走 CLI / API；通知 / 审批界面 / approver 身份发现等**必须集成方自建**——这是 CG 落地的最大工程量
- **审批人需要 Vault 身份**：要登 Vault（OIDC / LDAP / SSO 集成），意味着审批人也得是 Vault 用户
- **wrap token 有 TTL**：超时未 unwrap 自动作废，要重走流程
- **仅 Enterprise**：OSS 没有

### 一句话本质

> Control Groups = "**Vault path 级 N-of-M 审批工作流 + 取值能力与审批信号双轨分离**"——金融 / 政府 / 关键基础设施合规刚需；**仅 Enterprise + 无内建 UI**，落地集成成本可观。

---

## 13. Sentinel — 策略即代码（**仅 Enterprise**）

> ⚠️ 仅 Vault Enterprise 提供，OSS 没有原生对等物。

### 解决什么问题

OSS Vault 的 ACL policy（HCL）只能表达"path X + capability Y → 允许"。现实合规需求往往复杂得多：工作日 9-18 点 / 公司 IP 段 / 最近 5 分钟做过 MFA / 请求体大小限制 / 调用方属于某个 group……HCL 表达不了这种**条件 / 行为 / 跨上下文**的策略。

### 核心模型

> Sentinel = HashiCorp 自家的**策略表达语言**（Policy-as-Code）。在 Vault Enterprise 里以脚本形式挂到 path / identity 上，每次请求时**沿请求上下文求值**，决定放行 / 拒绝 / 警告。比 HCL 表达力强一个量级——能写"对请求做断言"。

**三类 Sentinel 策略在 Vault 里的载体**

| 类型 | 挂在哪 | 何时跑 |
|---|---|---|
| **RGP** (Role Governing Policy) | token / identity entity | 该身份每次请求 |
| **EGP** (Endpoint Governing Policy) | 特定 path | 该 path 被请求时 |
| **MFA Policy** | 触发二次认证流程 | 高敏请求 |

**示意（简化片段）**

```python
import "time"
workhours = time.now.weekday in [1,2,3,4,5] and
            time.now.hour >= 9 and time.now.hour < 18
ops_member = "ops-approvers" in identity.entity.group_names

main = rule { workhours and ops_member }
```

挂到 `secret/prod/*` 后，每次读都按这两个条件求值——任一不满足拒绝。

### 核心能力清单

#### ① 表达 HCL 表达不了的复杂策略

时间 / IP / 行为 / MFA 状态 / 上下文交叉，全是声明式。HCL 只能"匹配 path"，Sentinel 是"对请求做断言"。

> **理解**：从"权限矩阵"升级到"**条件式合规规则**"——满足合规、风控、行为约束这种现实业务规则。

#### ② 三种强制等级（Enforcement levels）

- **advisory** — 仅日志，不拒
- **soft-mandatory** — 拒，root 可 override
- **hard-mandatory** — 拒，谁也不能 override

同一条策略可分阶段推行：先 advisory 收集影响，再 soft，最后 hard。

> **理解**：让策略**渐进式上线**——先观察影响范围再硬执行，避免一刀切误伤。

#### ③ Policy-as-Code，可走 GitOps

Sentinel 脚本就是文本文件，可以 git 管 + PR review + CI 测试 + Argo 同步。策略和代码享同等工程纪律。

> **理解**：把"策略"也纳入工程协作流程——告别"管理员私自改"的灰盒治理。

### 和 ACL Policy / Control Groups 的关系

| | ACL Policy (HCL) | Sentinel | Control Groups |
|---|---|---|---|
| 表达力 | path + capability 二元 | 全语言断言 | N-of-M 审批 |
| OSS / Enterprise | OSS ✓ | Enterprise | Enterprise |
| 适合 | 静态权限矩阵 | 条件 / 行为 / 上下文 | 高风险人工把关 |

**三者可叠加**：先 ACL 过权限，再 Sentinel 过条件，再 CG 走审批——构成立体合规栈。

### 关键限制

- 仅 Enterprise
- Sentinel 是新语言，团队要学（语法接近 Python）
- 每次请求都求值，复杂策略会拖慢 Vault；建议先 advisory + 监控延迟

### 使用场景

| 场景 | 用什么 |
|---|---|
| 工作时间 + 公司 IP + MFA 才能读 prod | EGP |
| 某 entity 全部请求都受行为约束 | RGP |
| 全集群写操作请求体大小校验 | EGP 挂 `*` |
| 关键 path 强制 MFA | MFA policy |

### 一句话本质

> Sentinel = "**把 Vault 策略从匹配语言升级成断言语言**"——能表达条件 / 行为 / 上下文交叉的合规规则；与 ACL + CG 叠加成立体合规栈。

---

## 14. OpenBao — Vault 的开源 fork

### 背景

2023 年 8 月 HashiCorp Vault 从 MPL-2.0 改为 **BSL（Business Source License）**——不允许商业竞品使用、第三方集成受限。社区随即 fork 出 **OpenBao**：

- **MPL-2.0 许可**——纯开源，可商用、可二次分发
- **Linux Foundation 托管**（Sandbox 项目），独立于 HashiCorp（HashiCorp 已被 IBM 收购）
- **API 兼容 Vault**——大多数 Vault CLI / SDK / plugin / 集成（VSO / CSI Provider / Vault Agent Injector）直接复用
- 从 Vault 1.14.x fork 后持续独立演进，部分新功能已与 Vault 分歧

### OpenBao 对 Vault Enterprise 能力的现状（截至 2026-06）

| Vault Enterprise 能力 | OpenBao 状态 | 含义 |
|---|---|---|
| **Namespaces**（多租户） | ✅ **已开源实现** | Vault Enterprise-only 能力 OpenBao 已交付——免费可用，每个 namespace 是 mini-OpenBao |
| **Performance Replication** | ⏳ 未在主线 | 当前没有；未来不明 |
| **DR Replication** | ⏳ **2026-2027 roadmap** | automated DR replication 已立项筹资 |
| **Control Groups**（审批） | ⏳ **PR 中**（[#2241](https://github.com/openbao/openbao/pull/2241)） | 已通过 reviewer 本地测试，正在收尾；未来数月内可能合并 |
| **Sentinel**（策略即代码） | ❌ Sentinel 本身永远不会做 | HashiCorp 专有；OpenBao 走 **CEL 路线**（功能等价物） |
| **CEL Policy 表达**（Sentinel 等价物） | ⏳ **2025-2026 roadmap 重点** | "Expanding CEL Support for non-ACL policies"；功能等价 Sentinel，**和 K8s ValidatingAdmissionPolicy / GCP IAM 同语言**，业界成熟 |
| HSM auto-unseal | ❌ 当前没有 |  |

### 关键解读

- **Namespaces 免费可用**——对 ACP 客户场景重大：多租户 + 数据驻留等场景，OpenBao 可作为 **不需 Enterprise license** 的方案
- **Control Groups 在 PR 中**——一旦合并，OpenBao 用户也能拿到 Vault Enterprise 唯一的 N-of-M 审批能力；**Connectors "OSS 阵营无对位"的差异化卖点窗口正在收窄**，需要重新评估
- **Sentinel 走 CEL 等价路线**——OpenBao 选 CEL 而非自家专有 PaC 语言，与 K8s 生态对齐；**如果 Connectors 评估策略集成，CEL 是和 OpenBao + K8s 都兼容的路线**
- **DR Replication 2026-2027 落地后**，OpenBao 将进一步缩小与 Vault Enterprise 的功能差

### 适用场景

- 客户**不接受 BSL 许可**（合规 / 法务 / 国家政策）
- **严格 air-gap** 场景（无法用 HashiCorp 商业支持）
- 想保留**纯开源治理路径**
- HashiCorp 被 IBM 收购后的**供应链多样化**需求
- 需要 Vault Enterprise 部分能力（如 Namespaces）但不想买 license

### 实务建议

- 集成层（VSO / CSI / Injector / SDK）**优先复用 Vault 的**——OpenBao API 兼容大概率直接 work
- 涉及具体 plugin 时**先查 OpenBao 是否已 fork**对应版本
- 给客户做方案时**明确说明 Enterprise 能力对比 OpenBao 的现状表**，避免预期偏差

---

## 待补充

- [ ] **#4 PKI 深入**（中间 CA / CRL / OCSP / 自动续签）
- [ ] **#5 审计设备**（file / syslog / socket 详谈）

每个能力沉淀进来时，遵循同一结构：解决什么问题 → 核心模型 → 核心能力清单 → 使用场景 → 一句话本质。
