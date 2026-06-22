# Conjur vs Vault — 一眼看懂优劣与社区选择倾向

> 定位：两个**企业级 secret/身份产品**的正面对照（不是和 Connectors 比）。给想快速判断"该选谁、社区怎么选、air-gap/自托管选型"的读者。
> 基于源：`conjur-capabilities-guide.md`（本轮）+ `../vault.md`（已 fact-check）+ 公开行业事实。社区倾向部分标注为**社区常见倾向（非官方共识）**。日期 2026-06-17。

---

## 一句话定位

- **Vault** = 成熟、深、plugin 化的 secret/身份**基础设施**：一切是 secrets engine / auth method / audit device 三类 plugin，HCL policy + Raft 存储 + seal/unseal。久经大规模生产验证。2023-08 许可从 MPL 2.0 改 **BSL**（source-available，**不再是 OSS**）→ 催生 **OpenBao**（MPL-2.0、Linux Foundation 托管、API 兼容）。母公司 HashiCorp 已被 **IBM 收购**。
- **Conjur** = 以 **policy-as-code + 机器身份**为核心的 secret 管理：role/resource/permit/grant 的 RBAC 图用 YAML 声明，host + 多 authenticator 让工作负载免密钥取 token。**OSS server = LGPL v3**（client = Apache-2.0）。Enterprise = **"CyberArk Secrets Manager, Self-Hosted"**（原 Conjur Enterprise/DAP）。母公司 CyberArk 已被 **Palo Alto Networks 收购**（2026-02 完成）。

> 两者纸面都做"集中 secret + 机器身份 + K8s 集成 + 轮换"，但**设计哲学不同**：Vault 是"path 化的 plugin 数据面"，Conjur 是"声明式 RBAC 图 + 机器身份优先"。差别在**深度/广度 vs policy-as-code 与 CyberArk 生态**，以及**两边各自的 OSS/Enterprise 付费线位置**。

---

## 能力 / edition 对照（一眼看优劣）

> 关键看**哪些能力在免费层**。Vault 免费层 = OSS（已 BSL）或 OpenBao；Conjur 免费层 = OSS（server LGPL）。

| 维度 | Vault | Conjur | 谁更强 |
|---|---|---|---|
| 上手 / UX | CLI/HCL/Raft/unseal，学习曲线陡 | policy YAML + CLI；OSS **无 Web UI**（UI 是 Enterprise） | 各有学习成本；Vault 生态文档更厚 |
| 架构 | 集成存储 Raft + seal/unseal | server + **PostgreSQL** 后端 | 看团队栈偏好 |
| 授权模型 | **HCL policy**（path-glob capabilities） | **policy-as-code RBAC**（role/resource/permit/grant + branch，声明式、GitOps 友好） | **Conjur**（授权面即版本化代码） |
| 认证方式 | auth methods（k8s/jwt/approle/oidc/ldap/aws/azure/gcp…），OSS 免费 | authenticators（authn-k8s/jwt/iam/azure/gcp/oidc/ldap），**全 OSS 内置** | 接近；Conjur 机器身份是核心卖点且全 OSS |
| 静态 secret | KV v2，OSS，版本化 | variable 资源，OSS，版本化 | 接近 |
| 凭据轮换 | static roles（DB/AD/LDAP），**OSS 免费** | rotators（postgresql/aws），**OSS 免费** | 接近；Vault rotator 覆盖更广 |
| 动态 / 临时凭据 | 动态引擎（DB/Cloud/PKI/SSH/…），**OSS 免费、引擎丰富** | dynamic/ephemeral（AWS 等），**Enterprise/SaaS（OSS 无）** | **Vault**（OSS 免费 + 深 + 广） |
| PKI / 私有 CA | `pki` 引擎，OSS，成熟 | **无原生 PKI 引擎**（靠生态/外部） | **Vault** |
| 加密即服务 / KMS | `transit`，OSS，成熟 | **无 transit 等价物** | **Vault** |
| SSH CA | `ssh-ca`，OSS | **无原生 SSH CA 引擎** | **Vault** |
| 多租户 / 隔离 | **Namespaces=Enterprise**（OSS 仅 path 约定）；OpenBao 已开源 namespace | policy **branch** 命名空间，**OSS 免费** | **Conjur**（免费即 branch 隔离）/ OpenBao（免费 namespace） |
| 审批门控 | Control Groups（**Enterprise**），OSS 无 | **无运行时审批工作流**（改 policy 即改授权） | **Vault**（至少 Enterprise 有；Conjur 无原生） |
| 审计 | Audit devices，**OSS 免费、全请求** | 审计数据库/流 = **Enterprise**；OSS 弱 | **Vault**（免费且强） |
| HA / 扩展 | Raft 集群 + Performance Standby（PS=Enterprise） | **Master/Standby/Follower = Enterprise**；OSS 单节点 | **Vault**（OSS 即可 HA via Raft）/ Conjur OSS 单节点 |
| K8s 集成 | Agent Injector / VSO / CSI | Secrets Provider（init/sidecar/Job）+ authn-jwt + ESO | 接近 |
| CyberArk PAM Vault 集成 | 无 | **Vault Synchronizer（Enterprise）** | **Conjur**（生态独有） |
| air-gap | 可，OSS/OpenBao 干净；Enterprise 复杂 | OSS Docker/Helm 离线（单节点）；Enterprise 集群 + license | 接近；Vault OSS HA 更省事 |
| 许可 | **BSL**（非 OSS）；开源走 OpenBao（MPL-2.0） | server **LGPL v3** / client Apache-2.0；Enterprise 商业 | Conjur OSS 是真 OSI 许可，Vault 已非 OSS |
| 规模 / 成熟度 | 多年大规模生产验证、生态最厚 | 企业（尤金融/政府）验证，CyberArk 生态 | **Vault**（广度/生态）；Conjur（CyberArk 客户深度） |

**付费线位置不同（社区最常拿来说事）**：

- **Vault OSS（/OpenBao）免费**就给**动态凭据 / PKI / Transit / SSH CA / 轮换 / 审计 / Raft HA**；Enterprise 才收 Namespaces / Replication / HSM / Sentinel / Control Groups / Performance Standby。
- **Conjur OSS 免费**给 **policy-as-code RBAC / 全部 authenticator / 静态 secret / rotation / branch 多租户 / K8s 集成**；但 **dynamic secret / HA 集群 / 全量审计 / Web UI / PAM Vault 同步全是 Enterprise**。
- → 想要"动态凭据 + PKI + 加密服务"且免费，Vault OSS/OpenBao 远胜（Conjur 这些要么 Enterprise 要么没有）；想要"声明式 RBAC + 强机器身份 + 真 OSI 许可"，Conjur OSS 更对味。

---

## DevOps 工具（GitLab / Harbor / Nexus）专项

对 Connectors 团队关心的工具：

- **Vault**：生态有 **GitLab secrets engine**（社区插件、非 binary 内置，走 PAT）；**Harbor / Nexus 无专用引擎**。
- **Conjur**：rotation 内置 rotator 只有 **postgresql / aws**；dynamic 目标主要是**云（AWS 等）**；**无 GitLab / Harbor / Nexus 专用 rotator 或 dynamic backend**。

→ 两者对 Harbor / Nexus 的动态/轮换凭据都**不原生覆盖**；GitLab 上 Vault 生态有社区插件、Conjur 没有。这两个 DevOps 工具的短寿命凭据都需自己包一层。

---

## 各自优势（什么时候选谁）

**选 Vault（或 OpenBao）当：**

- 重度用**动态凭据 / PKI / Transit / SSH CA**——这些在 Vault OSS 免费且引擎丰富，Conjur 要么 Enterprise（dynamic）要么没有（PKI/Transit/SSH）。
- 要 **OSS 即可 HA**（Raft 集群）+ 免费全量审计。
- 已有 Terraform/HashiCorp 生态投资。
- 要**真开源 / air-gap 无 license 负担** → 走 **OpenBao**（MPL-2.0、含已开源 namespace）。

**选 Conjur 当：**

- 看重**policy-as-code 声明式 RBAC**（授权面版本化、GitOps、code review）和**机器身份优先**的设计。
- 已是 **CyberArk 客户**（银行/政府）——可用 **Vault Synchronizer** 复用 PAM Vault 凭据，Conjur 当 DevOps/机器侧消费入口。
- 要 OSS 即用的**真 OSI 许可**（server LGPL v3）+ branch 多租户 + 全 authenticator，且**不需要** dynamic/PKI/Transit。
- 主要诉求是"机器身份 + 集中 secret + K8s 集成"，而非"全功能 secret 数据面"。

---

## 社区选择倾向（社区常见倾向，非官方共识）

- **大致分水岭**：要全功能 secret 数据面（动态/PKI/Transit/SSH）+ 大规模 + 厚生态 → **Vault**（开源诉求选 **OpenBao**）；要 policy-as-code + 强机器身份，或已有 CyberArk 投资 → **Conjur**。
- **常见吐槽**：Vault — 学习曲线陡、BSL 许可争议、unseal 运维复杂；Conjur — **dynamic/PKI/Transit/SSH 缺位或要 Enterprise**、OSS 无 HA/UI/全量审计、文档站点命名混乱、社区/生态比 Vault 薄。
- **普遍共识**：Vault 是更"全栈"的 secret 基础设施（广度+深度+生态领先）；Conjur 在 **policy-as-code 与机器身份**上设计更纯粹，且在 **CyberArk 存量客户**里是默认选择。二者不是"谁淘汰谁"，是"全功能数据面 vs 声明式 RBAC+机器身份+CyberArk 生态"的取舍。

---

## 许可 / 生态背景（一眼记住）

| | Vault | Conjur |
|---|---|---|
| 许可 | MPL 2.0 → **BSL**（2023-08，source-available，非 OSS） | server **GNU LGPL v3.0** / client/SDK/CLI **Apache-2.0** |
| 真开源选项 | **OpenBao**（MPL-2.0、Linux Foundation、API 兼容） | OSS 本身即 OSI 许可（无需 fork）；无第三方 fork |
| Enterprise 名 | Vault Enterprise | **CyberArk Secrets Manager, Self-Hosted**（原 Conjur Enterprise/DAP）；SaaS = Secrets Manager, SaaS |
| 母公司 | HashiCorp（被 **IBM 收购**） | CyberArk（被 **Palo Alto Networks 收购**，2026-02 完成） |
| 起步年代 | 2015，老牌 | 2016 开源（CyberArk 收购 Conjur Inc.），企业市场深 |
| 收购后 OSS 状态 | OpenBao 兜底开源延续 | Conjur OSS 当前活跃（server v1.27.0, 2026-06）；**收购对长期 roadmap 影响未确认** |

---

**相关文档**：`conjur-capabilities-guide.md`（Conjur 能力详谈，含 OSS/Enterprise 边界）· `../vault.md`（Vault 能力详谈，含 §14 OpenBao）· `connectors-vs-conjur.md` / `../connectors-vs-vault.md`（各自与 Connectors 的对比）。
