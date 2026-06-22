# CyberArk Conjur 能力调研指南

> **状态**：已完成（持续可追加）
> **覆盖版本**：Conjur OSS server v1.27.0（2026-06-16 发布，[releases](https://github.com/cyberark/conjur/releases)）；Enterprise = "CyberArk Secrets Manager, Self-Hosted" 13.x（截至 2026-06）
> **基于源**：官方文档 `docs.cyberark.com`（conjur-open-source / secrets-manager-sh）+ `docs.conjur.org` + GitHub `github.com/cyberark/conjur`（逐条带 URL）
> **edition 范围**：Conjur OSS（LGPL v3 server）+ Enterprise（Secrets Manager, Self-Hosted）+ 必要处旁注 SaaS（Secrets Manager, SaaS）
> **不覆盖**：价格数字（以官网/销售为准）；CyberArk PAM Vault 自身能力；与 Connectors / ACP 的对比（见 `connectors-vs-conjur.md`）
> **未实测**：本指南未在集群实跑 demo，所有命令/YAML 均标 `> 未实测，基于官方文档 <url>`。

本文档**只讲 Conjur 自身**：它有哪些能力、解决什么问题、适合什么场景、基本原理、哪些收费、OSS/Enterprise 边界在哪。

---

## §0 心智模型 + 能力地图速览

**心智模型（4 行）**：Conjur 是一个**以"策略即代码（policy-as-code）"为核心的机器身份 secret 管理服务**。一切都是 RBAC 图里的对象——`!user`/`!host`/`!group`/`!layer` 是**角色（role）**，`!variable`/`!webservice` 是**资源（resource）**，`!permit`（角色→资源权限）和 `!grant`（角色→角色成员）是**关系**；声明这些的 YAML 叫 policy，按 `!policy` 嵌套形成**分支（branch）命名空间**。机器（host）通过一种**authenticator**（authn-k8s/jwt/iam/azure/gcp…）证明身份换取短期 access token，再凭 RBAC 读取 `variable` 里的 secret。Secret 既可静态存，也可（Enterprise/SaaS）由 issuer **动态现造**或由 rotator **周期轮换**。

**许可 / 归属 / air-gap（先记这条）**：
- **许可分裂**：Conjur **server**（本仓库代码）是 **GNU LGPL v3.0**；**client/API/扩展**（CLI、各语言 SDK、authn-k8s-client、Secretless 等）是 **Apache-2.0**（[README license](https://github.com/cyberark/conjur#licensing)）。⚠️ 不要笼统说"Conjur 是 Apache-2.0"——那只对客户端成立，server 是 LGPL。
- **归属**：CyberArk 于 2025-07-30 宣布被 **Palo Alto Networks** 以约 $25B 收购，交易 **2026-02-11 完成**（[GovCon Wire](https://www.govconwire.com/articles/palo-alto-networks-cyberark-25b-acquisition)）。Conjur OSS 仍在活跃维护（最新 server v1.27.0，2026-06-16）。
- **air-gap**：OSS 用 Docker / `conjur-oss` Helm chart 自托管（自带 PostgreSQL），无 phone-home，离线可跑（[conjur-oss-helm-chart](https://github.com/cyberark/conjur-oss-helm-chart)）。Enterprise 自托管同样可 air-gap，但是商业 license。

### 能力地图速览（30 秒看全貌）

一行 = 一章。先看这里决定往下读哪节。**最大的 edition 陷阱**：policy/RBAC、authenticators、静态 secret、**rotation 都是 OSS**；**dynamic/ephemeral secrets、HA 集群、审计数据库/流、Web UI、PAM Vault 同步是 Enterprise/SaaS**。

**一、OSS 基础能力（LGPL server，自托管免费）**

| § | 能力 | 解决什么问题 | 大致逻辑 | 亮点 | 典型场景 |
|---|---|---|---|---|---|
| §1 | Policy-as-code + RBAC | 谁能对哪个 secret 做什么，声明式可审 | YAML 声明 role/resource/permit/grant，按 branch 嵌套 | 整个授权面是版本化的代码 | GitOps 式管理 secret 授权 |
| §2 | 机器身份（host）+ authenticators | 工作负载免预埋长期密钥取 token | host 选一种 authenticator 证明身份换短 token | authn-k8s/jwt/iam/azure/gcp 全内置 | Pod 用 SA JWT 登录 Conjur |
| §3 | 静态 secret（variable） | 集中存长期凭据 | secret = `!variable` 资源，受 RBAC + 审计约束 | 每个 secret 是 RBAC 一等对象 | 集中存第三方 API key |
| §4 | Secret 检索（API/CLI/Summon/SDK） | 把 secret 喂给应用/进程 | REST `variable/value` + CLI + Summon 注入 env + SDK | Summon 把 secret 作 env 注入子进程 | CI 任务用 Summon 包裹命令 |
| §5 | 凭据轮换（rotators） | 长期账号周期换密码 | variable 加 `rotation/rotator`+`rotation/ttl` 注解，到点 Conjur 改后端密码 | 内置 postgresql / aws 等 rotator | DB 账号每天自动换密码 |
| §6 | K8s 集成（authn-jwt + Secrets Provider） | Pod 免凭据取 secret | SA 投影 token → authn-jwt → Secrets Provider 写 K8s Secret 或文件 | sidecar / init / job 多形态 | Pod 启动前把 secret 落成文件 |

**二、Enterprise / SaaS 能力（"Secrets Manager, Self-Hosted / SaaS"，商业 license）**

| § | 能力 | 解决什么问题 | 大致逻辑 | edition |
|---|---|---|---|---|
| §7 | 动态 / 临时（ephemeral）secret | 干掉长寿命凭据，按需现造 | issuer 现造短寿命凭据（AWS federation/assumed-role 等），TTL 到期即焚 | **Enterprise + SaaS**（OSS 无） |
| §8 | HA 集群（Master/Standby/Follower） | 高可用 + 读扩展 | Master 写 + Standby 自动故障转移 + Follower 只读扩展 | **Enterprise** |
| §9 | 审计数据库 / 审计流 | 全量可追溯审计 + SIEM | Follower 写审计转发 Master；专用审计服务 | **Enterprise** |
| §10 | PAM Vault 同步 + Web UI | 复用既有 CyberArk Vault 凭据 + 图形管理 | Vault Synchronizer 把 PAM Vault secret 复制进 Conjur；Web dashboard | **Enterprise** |

> dynamic/ephemeral secret 的 OSS 缺位是本调研最关键的 edition 结论：OSS 文档**只有 rotation，无 dynamic secrets**；dynamic/ephemeral 仅出现在 secrets-manager-sh（Enterprise）与 secrets-manager-saas 文档（[AWS dynamic secrets - Enterprise](https://docs.cyberark.com/conjur-enterprise/latest/en/content/operations/dynamic-secrets-aws.htm)）。

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 声明"谁能读哪个 secret"并版本化管理 | §1 |
| 让 Pod / CI / 云工作负载免密钥登录 Conjur | §2 |
| 集中存团队长期 API key | §3 |
| 把 secret 注入进程 env / 取值给应用 | §4 |
| DB / 云账号定期换密码 | §5（OSS） |
| K8s 里把 secret 落给 Pod | §6 |
| CI 现要一次性短寿命 AWS 凭据 | §7（Enterprise/SaaS） |
| 跨节点高可用 + 只读扩展 | §8（Enterprise） |
| 全量审计 + 推 SIEM | §9（Enterprise） |
| 复用已有 CyberArk PAM Vault 里的凭据 | §10（Enterprise） |

---

## §1 Policy-as-code + RBAC（edition: OSS）

### 解决什么问题
把"谁（角色）能对哪个 secret（资源）做什么（权限）"这件事，从散落的 ACL 配置变成**声明式、版本化、可 code review、可 GitOps 的 YAML**——授权面本身成为代码。

### 核心模型 / 原理
Conjur 内部是一张 RBAC 图，只有三类基本元素：

- **角色（role）**：能持有权限的主体——`!user`（人）、`!host`（机器/工作负载）、`!group`、`!layer`（host 的集合）。
- **资源（resource）**：被保护的对象——`!variable`（secret）、`!webservice`（如某个 authenticator 端点）、`!policy`（分支自身也是资源）。
- **关系（两类语句）**：
  - `!permit` —— 给某 role 在某 resource 上某些 **privilege**（`read` / `execute` / `update`）。`read` 看元数据，`execute` 才能取 secret 值，`update` 能写值。
  - `!grant` —— 把某 role **作为成员加入**另一个 role（角色继承），权限随成员关系传递。
- **分支 / 命名空间**：`!policy` 可嵌套，`id` 形成 `branch/sub-branch/resource` 的命名空间树，而非扁平 ACL。每个对象有 **owner**，owner 自动拥有该对象全部权限。
- **默认拒绝 + 图遍历**：RBAC 默认 deny，仅当认证主体所持的某个 role 链上存在到该 resource 的 permit 才放行（[policy basic concepts](https://docs.cyberark.com/conjur-open-source/latest/en/content/operations/policy/policy-basic-concepts.htm)）。

加载方式：policy YAML 通过 CLI / API `load`/`replace`/`update` 三种模式装入一个 branch（replace 会删除该 branch 下不再声明的对象）。

### 核心能力清单
- 4 类角色 + 资源 + permit/grant 两类关系语句（`!deny`/`!revoke`/`!delete` 做撤销）
- `!policy` 嵌套 = 分支命名空间，天然支持多团队按分支切分授权
- owner 模型 + 默认拒绝 + 图遍历授权
- 三种加载模式（POST=append / PUT=replace / PATCH=update）
- 注解（annotations）挂在对象上，驱动 rotator（§5）、authn-jwt 身份匹配（§2）等

### 最小命令示例
> 未实测，基于官方文档 [policy guide](https://docs.cyberark.com/conjur-open-source/latest/en/content/operations/policy/policy-overview.htm)、[permit 语句](https://docs.cyberark.com/conjur-open-source/latest/en/content/operations/policy/statement-ref-permit.htm)

**场景 A：声明一个分支 + 一个 secret + 授权一个机器读它**
```yaml
# app.yml —— 加载到 root：conjur policy load -b root -f app.yml
- !policy
  id: myapp                     # 分支命名空间 myapp/
  body:
    - !variable db/password     # 资源：myapp/db/password
    - !host ci-runner           # 角色：机器身份 myapp/ci-runner
    - !permit
        role: !host ci-runner
        privileges: [ read, execute ]   # execute 才能取值
        resource: !variable db/password
```
```bash
# 写入 secret 值（需 update 权限）
conjur variable set -i myapp/db/password -v 's3cr3t'
# 机器读取（需 execute）
conjur variable get -i myapp/db/password
```

### 一句话本质
**整个授权面是一棵版本化的 RBAC 代码树：role + resource + permit/grant。**

---

## §2 机器身份（host）+ authenticators（edition: OSS）

### 解决什么问题
让非人类工作负载（Pod、EC2、CI runner、云函数）**不预埋任何长期 Conjur 凭据**就能向 Conjur 证明身份，换取短期 access token。

### 核心模型 / 原理
- **host = 机器角色**：在 policy 里声明的 `!host`，是工作负载在 RBAC 图里的身份。
- **authenticator = 身份证明方式**：Conjur **server 内置**多种 authenticator，把"平台原生身份凭证"翻译成 Conjur 身份：
  - `authn`（默认，username/API key）
  - `authn-k8s`（K8s SA，基于注入证书的早期方式）
  - `authn-jwt`（通用 JWT，**当前 K8s/OIDC/CI 的推荐方式**，校验 JWKS + claims）
  - `authn-iam`（AWS IAM 签名身份）、`authn-azure`、`authn-gcp`（云实例元数据 token）
  - `authn-oidc`（人类走 OIDC SSO 登录 UI/CLI）、`authn-ldap`（LDAP 目录认证）
  - 以上 authenticator **均编译进 Conjur server，OSS 即可用**（OSS server 代码树 [`app/domain/authentication/`](https://github.com/cyberark/conjur/tree/master/app/domain/authentication) 含 authn_k8s/authn_jwt/authn_iam/authn_azure/authn_gcp/authn_oidc/authn_ldap；另见 [supported authenticators](https://docs.cyberark.com/conjur-open-source/latest/en/content/operations/authn/cjr-authn-support.htm)）。

**处理流程（authn-jwt for K8s，最常用；身份 → token 全链路）**：
1. 运维在 policy 里声明一个 authn-jwt webservice（含 `jwks-uri` 或 `public-keys`、`token-app-property`、`audience` 等变量），并声明各 host，host 上用 annotation 描述它的 JWT claim（如 `authn-jwt/<service>/kubernetes.io/namespace`）。
2. Pod 挂载**投影 SA token**（带指定 audience），向 `POST /authn-jwt/<service>/<account>/authenticate` 提交该 JWT。
3. Conjur 用 JWKS 验签 JWT，再把 JWT 里的 claim 与目标 host 的 annotation 逐项比对（namespace / serviceaccount / 等）。
4. 全部匹配 → 颁发短期 Conjur access token（默认短 TTL）；不匹配 → 拒。Pod 凭该 token 再走 RBAC 读 variable。
- host 命名约定（K8s）：`system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT>`（[K8s JWT authn](https://docs.cyberark.com/conjur-open-source/latest/en/content/integrations/k8s-ocp/k8s-jwt-authn.htm)）。

**whitelist 机制**：除默认 `authn` 外，所有 authenticator 必须经 `CONJUR_AUTHENTICATORS` 环境变量白名单 + 在 policy 里声明为 webservice 才生效。

### 核心能力清单
- 8 类 authenticator 全部 OSS 内置；同类型可多实例（`authn-jwt/<service-id>`）
- host 注解驱动的 claim 匹配（最小权限 + 防 token 跨用）
- 短期 access token（默认短 TTL，凭 RBAC 取值）
- 人类侧 authn-oidc / authn-ldap；机器侧 authn-jwt/k8s/iam/azure/gcp

### 最小命令示例
> 未实测，基于官方文档 [K8s JWT authentication](https://docs.cyberark.com/conjur-open-source/latest/en/content/integrations/k8s-ocp/k8s-jwt-authn.htm)

**场景 A：声明 authn-jwt webservice + 一个 K8s host**
```yaml
- !policy
  id: conjur/authn-jwt/k8s         # authn-jwt webservice 分支
  body:
    - !webservice
    - !variable jwks-uri
    - !variable token-app-property
    - !variable audience
    - !group consumers
    - !permit { role: !group consumers, privilege: [ authenticate ], resource: !webservice }
- !host
  id: system:serviceaccount:myns:ci-sa     # K8s host 命名约定
  annotations:
    authn-jwt/k8s/kubernetes.io/namespace: myns
- !grant { role: !group conjur/authn-jwt/k8s/consumers, member: !host system:serviceaccount:myns:ci-sa }
```
```bash
# Pod 内：用投影 SA token 换 Conjur token（伪示意）
curl -X POST -H "Content-Type: text/plain" \
  --data "$(cat /var/run/secrets/tokens/conjur-token)" \
  "$CONJUR_URL/authn-jwt/k8s/myaccount/authenticate"
```

### 一句话本质
**host 是机器角色，authenticator 把平台原生身份翻译成短期 Conjur token——全部 OSS 内置。**

---

## §3 静态 secret（variable）（edition: OSS）

### 解决什么问题
给长期持有的凭据/配置一个集中、受 RBAC 约束、可审计的家，替代散落的 `.env` 与明文配置。

### 核心模型 / 原理
Secret = policy 里的 `!variable` 资源。它和别的资源一样受 §1 RBAC 约束：`read`=看元数据，`execute`=取值，`update`=写值。值存进 Conjur 后端 PostgreSQL（落盘前加密）。variable 可带 `mime_type`、`kind` 等注解，也可挂 rotation 注解交给 §5。secret 有版本（可按版本读历史值）。

### 核心能力清单
- secret 是 RBAC 一等资源（与 host/group 同图）
- 加密落盘（PostgreSQL 后端）
- 版本化（可读历史版本）
- 注解驱动 rotation / 元数据

### 最小命令示例
> 未实测，基于官方文档 [variables](https://docs.cyberark.com/conjur-open-source/latest/en/content/developer/conjur_api.html)
```bash
conjur variable set -i myapp/db/password -v 's3cr3t-v1'   # 写（需 update）
conjur variable get -i myapp/db/password                  # 读（需 execute）
conjur variable get -i myapp/db/password --version 1      # 读历史版本
```

### 一句话本质
**secret 就是一个受 RBAC 管的 `!variable` 资源，集中、加密、可审计。**

---

## §4 Secret 检索：API / CLI / Summon / SDK（edition: OSS）

### 解决什么问题
认证拿到 token 后，把 secret **取出来交给应用 / 进程**——以 REST、CLI、env 注入、或语言 SDK 多种形态。

### 核心模型 / 原理
四条并列检索路径，差别只在"secret 以什么形态到达消费者"：
- **REST API**：`GET /secrets/{account}/variable/{id}` 直取值；CLI 是它的封装。
- **CLI**（`conjur` / 旧 `conjur-cli`）：实现 REST，管理 policy/role/secret。
- **Summon**（Apache-2.0 独立工具）：读一份 `secrets.yml`，从 Conjur（或其他 provider，如 AWS SM/S3）取 secret，**作为环境变量注入子进程**，子进程退出即销毁；secret 从不落盘（[Summon](https://docs.cyberark.com/conjur-open-source/latest/en/content/tools/summon.html)）。
- **SDK**：Ruby/Go/Java/Python/.NET 等官方 client（Apache-2.0）。

无论哪条，消费者拿到的都是**明文 secret 值**（Conjur 是 secret store，不是数据面代理）。

### 核心能力清单
- REST `variable/value` 批量/单条取
- CLI 管理 + 取值
- Summon env 注入（subprocess 模型，不落盘）
- 多语言 SDK
- ESO（External Secrets Operator）社区 provider：apikey 或 jwt 认证，把 Conjur variable 同步成 K8s Secret（[ESO Conjur provider](https://external-secrets.io/latest/provider/conjur/)）

### 最小命令示例
> 未实测，基于官方文档 [Summon](https://docs.cyberark.com/conjur-open-source/latest/en/content/tools/summon.html)

**场景 A：Summon 把 Conjur secret 作 env 注入命令**
```yaml
# secrets.yml
DB_PASSWORD: !var myapp/db/password
```
```bash
summon -p conjur ./run-migration.sh    # DB_PASSWORD 仅在子进程 env 内存中存在
```

### 一句话本质
**REST / CLI / Summon / SDK 把 secret 明文取给消费者；Summon 用"注入 env + 子进程退出即销毁"最常见。**

---

## §5 凭据轮换 rotators（edition: OSS）

### 解决什么问题
长期账号（DB user、云 IAM user）不能销毁，但合规要求密码周期换。Conjur 直接调后端改密码，业务读 variable 永远拿当前值。

### 核心模型 / 原理
轮换的是**同一账号的密码/密钥**（账号名不变），不新建/销毁账号——这是 rotation 与 §7 dynamic secret 的根本区别。

**处理流程（带编号；DevOps 工具覆盖见下）**：
1. 在 policy 里给目标 `!variable` 加注解：`rotation/rotator: <类型>`（如 `postgresql/password`、`aws/secret-access-key`）+ `rotation/ttl: <ISO8601 周期>`（如 `P1D`=1 天），可选 `length` 等。
2. Conjur server 启动时自动加载所有 rotator class；带 rotation 注解的 variable 进入轮换调度。
3. 每到 TTL 间隔，对应 rotator 通过 facade 调**后端系统 API**（如 PostgreSQL `ALTER USER ... PASSWORD`、AWS IAM 换 access key）生成新值，**原子地同步**更新后端密码与 Conjur variable 值，旧值过期（[ROTATORS.md](https://github.com/cyberark/conjur/blob/master/design/ROTATORS.md)、[rotation-secrets](https://docs.cyberark.com/conjur-open-source/latest/en/content/operations/services/rotation-secrets.html)）。
4. 业务下次 `variable get` 即拿到新密码；账号名/连接串不变。
- AWS rotator 维持"两把 active key"以避免轮换瞬间的竞态。

**DevOps 工具覆盖（GitLab / Harbor / Nexus）**：内置 rotator 主要是 **PostgreSQL + AWS**（官方文档/设计文档明确列出这两类；rotator 架构可扩展但需自写 rotator class 加载进 server）。**无 GitLab / Harbor / Nexus 专用 rotator** —— 这三个 DevOps 工具的凭据轮换 Conjur OSS **不原生覆盖**，要做需自写 rotator 或走外部流程。

### 核心能力清单
- 注解驱动（`rotation/rotator` + `rotation/ttl` + `length`）
- 内置 postgresql / aws rotator（OSS）
- facade 模式可扩展自定义 rotator（编译进 server）
- 账号名不变、密码周期换、业务零改

### 最小命令示例
> 未实测，基于官方文档 [rotation-secrets](https://docs.cyberark.com/conjur-open-source/latest/en/content/operations/services/rotation-secrets.html)
```yaml
- !variable
  id: myapp/db/password
  annotations:
    rotation/rotator: postgresql/password
    rotation/ttl: P1D            # 每天轮换
```

### 一句话本质
**注解一挂，Conjur 周期改后端账号密码、业务读到的永远是当前值——OSS 内置 postgresql/aws，无 GitLab/Harbor/Nexus rotator。**

---

## §6 K8s 集成：authn-jwt + Secrets Provider（edition: OSS）

### 解决什么问题
让 K8s 里的 Pod 免预埋凭据地取 Conjur secret，并把 secret 落成 Pod 能直接消费的形态（K8s Secret 或文件）。

### 核心模型 / 原理
两件套：**authn-jwt 认证**（§2）+ **Secrets Provider 交付**。Secrets Provider（容器，Apache-2.0 client）有三种部署形态，决定 secret 最终落点：

**处理流程（CR/部署 → 控制器/容器 → Pod 看到什么）**：
1. **认证**：Secrets Provider 容器用所在 Pod 的投影 SA token 走 authn-jwt 登录 Conjur，拿短期 token。
2. **取值**：按配置（要哪些 variable）凭 RBAC 取 secret 明文。
3. **交付**（三形态）：
   - **init container**：启动时把 secret 写进一个 emptyDir 共享卷的**文件**，业务容器读文件；Pod 生命周期内不刷新。
   - **sidecar**：常驻，周期刷新文件（应对 §5 轮换或 §7 动态值更新）。
   - **Kubernetes Job**：把 secret 写成**原生 K8s Secret 对象**，业务 Deployment 照常 `envFrom`/volume 消费（[Secrets Provider as K8s Job](https://docs.cyberark.com/conjur-open-source/latest/en/content/integrations/k8s-ocp/cjr-k8s-jwt-sp-ac.htm)）。
4. **传导到运行中 Pod**：Job 模式写 K8s Secret 后，env 注入的值改了 kubelet 不会自动重启 Pod（与所有 K8s Secret 一样）；文件模式 sidecar 刷新后业务需自行 reload。
- 另有 **authn-k8s-client**（早期基于注入证书的 sidecar/init），现多被 authn-jwt 路径取代。
- 社区也可用 **External Secrets Operator** 的 Conjur provider 做同步（§4）。

### 核心能力清单
- authn-jwt（投影 SA token + audience 校验）
- Secrets Provider 三形态：init / sidecar / Job
- 落点：共享卷文件 或 原生 K8s Secret
- 适配 OpenShift（authn-jwt 同路径）

### 最小命令示例
> 未实测，基于官方文档 [Secrets Provider K8s Job](https://docs.cyberark.com/conjur-open-source/latest/en/content/integrations/k8s-ocp/cjr-k8s-jwt-sp-ac.htm)
```yaml
# Secrets Provider 作为 init container（节选）：把 Conjur secret 写进共享卷文件
initContainers:
- name: cyberark-secrets-provider
  image: cyberark/secrets-provider-for-k8s
  env:
  - { name: SECRETS_DESTINATION, value: file }
  - { name: CONTAINER_MODE, value: init }
  - { name: JWT_TOKEN_PATH, value: /var/run/secrets/tokens/jwt }
  volumeMounts: [ { name: shared, mountPath: /opt/secrets } ]
```

### 一句话本质
**authn-jwt 认证 + Secrets Provider（init/sidecar/Job）把 secret 落成文件或 K8s Secret——Pod 拿到的是明文。**

---

## §11 OSS 能力组合回顾（edition: OSS）

Conjur **OSS（server LGPL v3 + client Apache-2.0，自托管免费、无 user/host 上限）** 真正包含：完整的 **policy-as-code + RBAC**（§1）、**全部 8 类 authenticator**（§2，机器身份是 Conjur 的核心卖点且全 OSS）、**静态 secret + 版本**（§3）、**REST/CLI/Summon/SDK 检索**（§4）、**rotation rotators**（§5，含 postgresql/aws）、**K8s Secrets Provider 多形态交付**（§6）。对"想要一个免费、air-gap 干净、机器身份 + policy-as-code 强的 secret store + K8s 集成"的客户，OSS 核心够用。

**OSS 边界（这些 OSS 没有，要 Enterprise/SaaS）**：
- **动态 / 临时（ephemeral）secret**（§7）—— OSS 文档无此能力，只有 rotation。
- **HA 集群（Master/Standby/Follower）**（§8）—— OSS 是**单节点**部署。
- **审计数据库 / 审计流**（§9）—— OSS 无专用审计服务。
- **PAM Vault 同步 + Web UI**（§10）。

---

# Enterprise 章节（以下能力**仅 Enterprise / SaaS 提供**）

> **edition 提醒**：从此章节起所有能力默认需要 **CyberArk Secrets Manager（Self-Hosted = Enterprise，或 SaaS）** 商业 license，OSS 不含。客户场景下不要假设可用。

## §7 动态 / 临时（ephemeral）secret（edition: Enterprise + SaaS）

⚠️ **Enterprise/SaaS 限定**。

### 解决什么问题
按需现造短寿命凭据（云 IAM 临时凭据等），用完即焚，缩小泄露窗口——根除长寿命凭据。

### 核心模型 / 原理
- **issuer**：持有"怎么造"的配置（连哪个目标、用什么常驻凭据、生成什么权限）。
- **dynamic secret resource**：消费者请求时，issuer 现造一份短寿命凭据，带 TTL；到期凭据自动失效/删除。
- 与 §5 rotation 的区别：dynamic 是**新建+销毁凭据实例**，rotation 是**同账号改密码**。

**处理流程**：
1. 管理员配 issuer（如 AWS issuer，持常驻 AWS 凭据）。
2. 消费者请求 dynamic secret → issuer 现造短寿命凭据。AWS 侧支持 **federation token** 与 **assumed role** 两种发放方式（[AWS dynamic secrets](https://docs.cyberark.com/conjur-enterprise/latest/en/content/operations/dynamic-secrets-aws.htm)）。
3. 凭据交付消费者，TTL 到期即焚。

**DevOps 工具覆盖（GitLab / Harbor / Nexus）**：dynamic secret 的目标当前主要是**云（AWS 等）**；**无 GitLab / Harbor / Nexus 专用 dynamic backend**（未在文档中发现）—— 这三个工具的短寿命凭据 Conjur 不原生覆盖。

### 核心能力清单
- issuer + dynamic secret resource 模型
- AWS：federation token / assumed role
- 短寿命 + 自动失效
- **OSS 不提供**（关键 edition 边界）

### 最小命令示例
> 未实测，基于官方文档 [Manage dynamic secret resources (SaaS)](https://docs.cyberark.com/secrets-manager-saas/latest/en/content/conjurcloud/ccl-dynamic-secrets.htm)
```text
# 概念示意：消费者向 Conjur 请求一个 AWS dynamic secret，
# 返回一组短寿命 AWS 凭据（access key/secret/session token），TTL 到期作废。
# 具体 API/CLI 因 Self-Hosted vs SaaS 而异，见上方文档。
```

### 一句话本质
**issuer 现造短寿命云凭据、TTL 到期即焚——Enterprise/SaaS 限定，OSS 无。**

---

## §8 HA 集群：Master / Standby / Follower（edition: Enterprise）

⚠️ **Enterprise 限定**。

### 解决什么问题
OSS 单节点无高可用；Enterprise 用集群拓扑提供故障转移与读扩展。

### 核心模型 / 原理
- **Master**：唯一可写节点。
- **Standby**：Master 的热备，Master 不健康时**自动故障转移**晋升。最小推荐 3 节点 active-passive 集群，前置负载均衡。
- **Follower**：只读副本，水平扩展读吞吐 + 就近服务客户端；Master 临时不健康时 Follower 仍可服务读（[architecture reference](https://docs.cyberark.com/secrets-manager-sh/latest/en/content/references/cjr-architecture.htm)）。

### 核心能力清单
- Master + Standby 自动故障转移
- Follower 只读水平扩展
- 负载均衡前置的集群
- **OSS 为单节点**

### 最小命令示例
> 未实测，基于官方文档 [architecture reference](https://docs.cyberark.com/secrets-manager-sh/latest/en/content/references/cjr-architecture.htm)
```text
# 拓扑示意（无单条命令）：
# LB → [Master(rw) | Standby(hot) ] + 多个 Follower(ro)
# 部署经 Enterprise 安装流程（容器/appliance），非 OSS Helm chart。
```

### 一句话本质
**Master 写 + Standby 自动接管 + Follower 只读扩展——OSS 单节点没有。**

---

## §9 审计数据库 / 审计流（edition: Enterprise）

⚠️ **Enterprise 限定**。

### 解决什么问题
全量、可追溯的"谁对哪个 secret 做了什么"审计，并能转发到 SIEM。

### 核心模型 / 原理
Enterprise 有专用**审计服务**：Follower 写审计数据并转发给 Master（文档提及 port 1999），集中留存；可对接外部 SIEM（[audit service](https://docs.cyberark.com/conjur-enterprise/latest/en/content/operations/services/audit/dap-overview-audit-service.htm)）。OSS 无此专用审计数据库/流能力。

### 核心能力清单
- 专用审计数据库
- Follower → Master 审计转发
- SIEM 集成
- **OSS 无**

### 最小命令示例
> 未实测，基于官方文档 [audit service](https://docs.cyberark.com/conjur-enterprise/latest/en/content/operations/services/audit/dap-overview-audit-service.htm)
```text
# 审计经 Enterprise 服务采集，非 OSS 命令；查询走 Enterprise UI / API。
```

### 一句话本质
**Enterprise 专用审计服务做全量审计 + SIEM 转发——OSS 不含。**

---

## §10 PAM Vault 同步 + Web UI（edition: Enterprise）

⚠️ **Enterprise 限定**。

### 解决什么问题
让已有 CyberArk PAM Vault 投资的客户把 Vault 里的凭据复用到 Conjur，并提供图形化管理界面。

### 核心模型 / 原理
- **Vault Synchronizer / Conjur Sync**：自动把 CyberArk PAM Vault 的 secret **复制进** Conjur Enterprise，使 Conjur 成为 DevOps/机器侧消费入口、Vault 仍为权威源（[OSS vs Enterprise](https://docs.cyberark.com/secrets-manager-sh/latest/en/content/get%20started/enterprise_vs_opensource.htm)）。
- **Web UI**：Enterprise 提供 dashboard 管理 policy/secret/role；OSS 无内置 Web UI（靠 CLI/API）。

### 核心能力清单
- PAM Vault → Conjur 单向同步
- 图形 dashboard
- **OSS 无（无 UI、无 Vault 同步）**

### 最小命令示例
> 未实测，基于官方文档 [enterprise_vs_opensource](https://docs.cyberark.com/secrets-manager-sh/latest/en/content/get%20started/enterprise_vs_opensource.htm)
```text
# Synchronizer 经 Enterprise 安装与配置，非 OSS 能力；无对应 OSS 命令。
```

### 一句话本质
**Vault Synchronizer 复用既有 PAM Vault 凭据 + Web UI——Enterprise 专属。**

---

## §12 部署 / 生态 / 许可 / air-gap 边界

- **部署（OSS）**：Docker 镜像 `cyberark/conjur` + **`conjur-oss` Helm chart**（自带 PostgreSQL，单节点；[conjur-oss-helm-chart](https://github.com/cyberark/conjur-oss-helm-chart)）。Enterprise 走容器/appliance 集群安装。
- **许可**：server = **GNU LGPL v3.0**；client/API/CLI/SDK/Secretless/authn-k8s-client = **Apache-2.0**（[README licensing](https://github.com/cyberark/conjur#licensing)）。无第三方 fork（CyberArk 单一上游）。
- **生态周边（均 CyberArk，多为 Apache-2.0）**：Secretless Broker（出栈注入代理，已独立深挖，见 `../secretless-broker/`）、Summon、Secrets Provider for K8s、conjur-authn-k8s-client、各语言 SDK、ESO 社区 provider。
- **归属**：CyberArk 已于 2026-02-11 完成被 **Palo Alto Networks** 收购（[GovCon Wire](https://www.govconwire.com/articles/palo-alto-networks-cyberark-25b-acquisition)）；Conjur OSS 截至 2026-06 仍活跃维护（server v1.27.0、helpnetsecurity 2025-12 报道其"在开源中维护、有用户与贡献者社区"，[helpnetsecurity](https://www.helpnetsecurity.com/2025/12/24/conjur-open-source-secrets-management/)）。**未发现** OSS 停服/弃维公告（未确认收购后的长期 roadmap 影响）。
- **air-gap 友好度**：OSS 离线自托管干净（无 phone-home、自带 PG）；Enterprise 自托管可 air-gap 但需商业 license。

---

## 附：额外有价值发现（技能范围外）

- **命名史 = 销售/SE 高频混淆点**：同一产品族经历 **Conjur → Conjur Enterprise / DAP（Dynamic Access Provisioning）→ "CyberArk Secrets Manager"**（Self-Hosted = 原 Conjur Enterprise；SaaS = 原 Conjur Cloud）。文档站点路径仍混用 `conjur-enterprise` / `secrets-manager-sh` / `secrets-manager-saas` / `conjur-open-source`。读文档时认路径前缀判 edition 比认产品名可靠。
- **安全公告**：曾有 Conjur OSS + Secrets Manager Self-Hosted 的 RCE 安全公告（[GHSA-93hx-v9pv-qrm4](https://github.com/cyberark/conjur/security/advisories/GHSA-93hx-v9pv-qrm4)）——若客户用旧版本需提醒升级。
- **Secretless Broker 关系**：Secretless 是 Conjur 生态里的"出栈注入代理"，可用 conjur provider 从 Conjur 取凭据；它是 Conjur 的**消费端**，不是 Conjur 本身。已在 `../secretless-broker/` 单独深挖。

---

**相关文档**：`connectors-vs-conjur.md`（与 Connectors 的对比 + 边界 + roadmap 启发）· `conjur-vs-vault.md`（Conjur vs Vault 正面对照）· `../secretless-broker/`（机制孪生，已单独深挖）。
