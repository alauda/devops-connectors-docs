# Infisical vs Vault — 一眼看懂优劣与社区选择倾向

> 定位：两个**外部 secret 产品**的正面对照（不是和 Connectors 比）。给想快速判断"该选谁、社区怎么选"的读者。
> 基于源：`infisical-capabilities-guide.md`（已 fact-check）+ `../vault.md`（已 fact-check）+ 公开行业事实。社区倾向部分标注为**社区常见倾向（非官方共识）**。日期 2026-06-16。

---

## 一句话定位

- **Vault** = 成熟、深、企业级的 secret/身份**基础设施**：plugin 化数据面（secrets engine / auth method / audit device），HCL policy + Raft 存储 + seal/unseal。久经大规模生产验证。2023-08 许可从 MPL 2.0 改 **BSL**（source-available，**不再是 OSS**）→ 催生 **OpenBao**（AGPL-3.0、Linux Foundation 托管、API 兼容）。
- **Infisical** = 开发者友好、UI 完整、Postgres+Redis 栈的**现代 secret 平台**：MIT 核心 + 付费 `ee/`。能力面这两年在快速对齐 Vault，但深度/成熟度/规模验证不及。

> 纸面能力已高度重合（都做 KV + 动态凭据 + PKI + KMS/加密 + SSH CA + 身份 + 审计 + 审批）。差别主要在**深度 / 上手 / 许可 / 付费线位置**，不在"有没有"。

---

## 能力 / edition 对照（一眼看优劣）

> 标注哪些是**免费**可用（关键差异点）。Vault 免费层 = OSS（或 OpenBao）；Infisical 免费层 = MIT 自托管。

| 维度 | Vault | Infisical | 谁更强 |
|---|---|---|---|
| 上手 / UX | CLI/HCL/Raft/unseal，学习曲线陡 | UI 完整、Postgres 熟悉栈、几小时跑通 | **Infisical** |
| 架构 | 集成存储 Raft + seal/unseal | Postgres + Redis | 看团队栈偏好 |
| 许可 | **BSL**（source-available，非 OSS）；开源走 OpenBao | **MIT** 核心 + ee 专有 | 各有取舍 |
| 动态凭据 | **OSS 免费**，引擎丰富（DB/Cloud/PKI/SSH…） | **付费 Enterprise** | **Vault**（免费 + 深） |
| 凭据轮换 | OSS 免费（DB/AD/LDAP…） | 付费 Pro | **Vault** |
| PKI / 私有 CA | OSS 免费，成熟 | OSS 免费 + cert-manager issuer | 接近，Vault 更深 |
| KMS / 加密即服务 | Transit，OSS 免费，成熟 | OSS 免费 | 接近，Vault 更深 |
| SSH CA | OSS 免费 | 有（edition 未确认） | Vault 更明确 |
| 多租户 / namespace | **Enterprise**（OSS 仅 path 约定）；OpenBao 已开源 namespace | project 硬隔离，OSS 免费 | **Infisical**（免费即真隔离） |
| 审批门控 | Control Groups（**Enterprise**），OSS 无 | change/access request（**付费 Pro/Ent**） | 都付费，模型不同 |
| 审计 | Audit devices，OSS 免费、全请求 | **付费**（自托管也要 license），流式 Enterprise | **Vault**（免费且强） |
| 集成 / 生态 | Terraform/工具链成熟，生态厚 | SDK 9 语言 + Secret Sync 推 ~42 目的地 + 免费扫描 CLI | 各有侧重 |
| K8s 集成 | Agent Injector / VSO / CSI | Operator / CSI / Agent / Injector | 接近 |
| air-gap | 可，但 Enterprise 复杂 | OSS 核心可离线；付费功能需 offline license | 接近 |
| 规模 / 成熟度 | 多年大规模生产验证 | 较新，规模验证少 | **Vault** |

**付费线位置不同（社区最常拿来说事）**：

- **Vault OSS 免费**就给**动态凭据 / PKI / Transit / 轮换 / 审计**；Enterprise 才收 namespace / replication / HSM / Sentinel。
- **Infisical 免费**给 **KV / PKI / KMS / 扫描 / project 隔离**；但**动态凭据(Ent) / 轮换(Pro) / 审批 / 审计 / SSO 全付费**。
- → 想要"Vault 式动态凭据"，Vault OSS / OpenBao 免费，Infisical 要给钱——这是社区反复提的点。

---

## DevOps 工具（GitLab / Harbor / Nexus）专项

对 Connectors 团队关心的工具：

- **Vault**：生态有 **GitLab secrets engine**（社区插件、非 binary 内置，走 PAT）；**Harbor / Nexus 无专用引擎**。
- **Infisical**：动态凭据 SaaS 侧**只有 GitHub（App token）**，**无 GitLab / Harbor / Nexus** 动态或轮换 backend。

→ 两者对 Harbor / Nexus 的动态凭据都**不原生覆盖**；GitLab 上 Vault 生态有社区插件、Infisical 没有。

---

## 各自优势（什么时候选谁）

**选 Vault（或 OpenBao）当：**

- 要**深度 + 成熟 + 大规模高保障**的 secret/身份基础设施。
- 重度用**动态凭据 / PKI / Transit**——这些在 Vault OSS 免费且引擎丰富。
- 已有 Terraform/HashiCorp 生态投资。
- 有**真开源 / air-gap 无 license 负担**诉求 → 走 **OpenBao**（含已开源的 namespace 多租户）。

**选 Infisical 当：**

- 重点是**应用 secret 管理 + K8s 同步**，要**好 UX、快上手、完整 UI / 协作**。
- 团队偏好 **Postgres 栈**、不想碰 Raft/unseal。
- 想要免费的 **secret 泄漏扫描 CLI** + **Secret Sync 向下游推**（~42 目的地）+ 一站式（PKI/KMS/SSH/scan 一个产品）。
- 小到中团队，或已经在用 Infisical Cloud。

---

## 社区选择倾向（社区常见倾向，非官方共识）

- **大致分水岭**：应用 secret + K8s 同步 + 好 UX 快上手 + 小到中团队 → **Infisical**；组织级深度 secret/PKI/动态凭据基础设施 + 大规模 + 高保障 → **Vault**（开源诉求选 **OpenBao**）。
- **常见吐槽**：Vault — 学习曲线陡、BSL 许可争议；Infisical — 把动态凭据等核心安全能力放 EE 付费（Vault OSS 免费）、成熟度/规模验证不及。
- **普遍共识**：Infisical 能力面在快速追赶，但还没到 Vault 的深度与生态厚度；二者不是"谁淘汰谁"，是"现代 DX vs 成熟深度"的取舍。

---

## 许可 / 生态背景（一眼记住）

| | Vault | Infisical |
|---|---|---|
| 许可 | MPL 2.0 → **BSL**（2023-08，source-available） | **MIT** 核心 + `ee/` 专有 |
| 真开源选项 | **OpenBao**（AGPL-3.0、Linux Foundation、API 兼容） | 无 fork（核心本身 MIT） |
| 母公司 | HashiCorp（被 **IBM 收购，$6.4B**） | Infisical（独立） |
| 起步年代 | 2015，老牌 | 较新 |

---

**相关文档**：`infisical-capabilities-guide.md`（Infisical 能力详谈）· `../vault.md`（Vault 能力详谈，含 §14 OpenBao）· `connectors-vs-infisical.md` / `../connectors-vs-vault.md`（各自与 Connectors 的对比）。
