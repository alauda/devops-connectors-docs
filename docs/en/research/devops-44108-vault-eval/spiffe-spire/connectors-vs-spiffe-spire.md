# Connectors vs SPIFFE / SPIRE — 关系、边界、集成候选、Roadmap 启发

> **结论摘要**：SPIFFE/SPIRE **不是 Connectors 的替代品**，而是工作负载身份的**厂商中立原语 / benchmark**，且是**集成候选**——它可以成为 Connectors 客户端身份的底层 substrate（替代 / 补充当前的 K8s SA token）。两者在层次上互补、不竞争：**SPIRE 止于"发一个可验证身份"；Connectors 在身份之上多做两步——在集群内 broker 真实工具凭据（真凭据永不进 Pod）+ 改写镜像拉取**。SPIRE 把短寿命身份交给工作负载后就结束，工作负载自己持有 SVID 去用；Connectors 的 data-plane proxy 让工作负载连身份对应的真凭据都拿不到。这正是 moat-by-contrast：Connectors = "SPIFFE 式短寿命身份" + "在集群内 broker 真凭据" + "镜像改写"，SPIRE 只交付第一项。
>
> SPIFFE/SPIRE 背景见 `spiffe-spire-capabilities-guide.md`。Connectors 问题域见 `../what-is-connectors.md`。

---

## §1 Connectors 问题域（精简）

| 问题域 | Connectors 的解法 | 体验 |
|---|---|---|
| CI Secretless | Proxy 在 connectors-system 持真凭据；CSI Driver 用 Pod SA 签短 token（默认 30m）挂工具配置模板；Proxy 出栈方向注入真实 Basic/Bearer/OCI Token | 业务进程当普通配置读，真凭据不进 Pod |
| K8S 镜像无凭据拉取 | `PodWebhook` 改写 Pod image 到 reverse proxy；kubelet 走 proxy 拉镜像；真 robot 密码只在 connectors-system | Pod 加 annotation 即可，kubelet 无感 |
| 客户端身份 substrate | 客户端用 **K8s 短期 SA token** 向 Proxy 鉴权（**这一项正是 SPIFFE/SPIRE 的对位点**） | Pod 用自身 SA token，无额外密钥 |
| 工具透传 API | ConnectorClass.spec.api.openapi 暴露上游 API 子集，Connectors API server 代调 | UI/SDK 直接调用 |
| Pipeline UI 选资源 | ResourceInterface + Tekton descriptor + Connectors API | Pipeline 编辑器下拉选 branch/tag/artifact |
| 审批门控 | AccessPolicy + AccessRequest + ApprovalTask 联动，**运行时每次经 proxy 调用** | Pipeline 内审批，拒绝则 CSI 挂错误占位文件 |
| 吊销 | 每请求 SubjectAccessReview 撤 RBAC，**秒级生效**（非等 lease/TTL 过期） | 撤权即时阻断 |

**Connectors 边界（不解决什么）**：不是通用工作负载身份框架；不发厂商中立身份标准；不做跨组织 trust-domain 联邦。

---

## §2 SPIFFE/SPIRE vs Connectors 能力对比

### §2.1 在 Connectors 问题域内的对比

| 问题域 | Connectors 解法 | SPIFFE/SPIRE 解法 | 关键差异 |
|---|---|---|---|
| **客户端身份 substrate** | K8s 短期 SA token 向 Proxy 鉴权 | SPIFFE ID + SVID（X.509/JWT），两段式 attestation 发身份 | **同层、可互换**——SPIRE 是更通用、跨平台、厂商中立的身份原语；K8s SA token 绑死 K8s。**这是唯一真正"同台"的一项，也是集成点** |
| CI Secretless（真凭据隔离） | data-plane proxy 持真凭据，client 永不接触 | **不覆盖**——SPIRE 发**身份**不发业务凭据；身份对应的真凭据由工作负载自己持有/换取 | **仅 Connectors 覆盖**。SPIRE 给身份后即结束，没有"出栈注入真凭据、客户端永不接触"这层 |
| K8S 镜像无凭据拉取 | PodWebhook 改 image + SA token 走 reverse proxy | **不覆盖**——SPIRE 不碰镜像拉取 | **仅 Connectors 覆盖** |
| 工具透传 API | OpenAPI + Connectors API + Proxy 透传 | **不覆盖** | **仅 Connectors 覆盖** |
| Pipeline UI 选资源 | ResourceInterface + descriptor | **不覆盖** | **仅 Connectors 覆盖** |
| 审批门控 | 运行时每次经 proxy 调用门控 | **不覆盖**——SPIRE 只管签发身份，无使用门控 | **仅 Connectors 覆盖** |
| 凭据短寿命 / 轮换 | 客户端 SA token 短期（30m）；真凭据靠管理员轮换 | SVID 短寿命（X.509 默认 1h / JWT 默认 5m）+ agent 半衰期自动轮换 | **身份层都做短寿命+自动轮换（SPIRE 更标准化）**；但 SPIRE 轮换的是**身份**，Connectors 还隔离了身份背后的**真凭据** |
| 吊销 | 每请求 SubjectAccessReview 撤 RBAC，秒级 | 靠 SVID 短 TTL 到期 + registration entry 删除（非每请求强校验） | Connectors 吊销**即时**；SPIRE 主要靠短 TTL 收敛窗口 |
| air-gap 装升 | OLM bundle + 一个 CR，复用 ACP operator | 自托管 SPIRE Server/Agent，全 OSS、无 license、air-gap 友好 | **双方都 air-gap 友好**；Connectors 复用 ACP 体系，SPIRE 是独立栈 |

**哲学差异（散文）**：SPIRE 回答"**这个工作负载是谁**"，交付一个可验证身份后即止——工作负载**持有** SVID（含私钥 / JWT），自己拿去做 mTLS 或换云凭据。Connectors 回答"**这个工作负载怎么安全地用外部工具**"——它在身份之上再做两步：(1) 在 `connectors-system` 内 data-plane proxy 持有工具**真凭据**并在出栈方向注入，工作负载连真凭据都拿不到；(2) 改写镜像拉取让 kubelet 走 proxy。**两者是上下层关系，不是替代**：SPIRE 可以是 Connectors 客户端身份的更强 substrate，Connectors 是 SPIRE 不做的"凭据 broker + 工具接入面"。

### §2.2 不在 Connectors 问题域内的 SPIFFE/SPIRE 能力

| SPIFFE/SPIRE 能力 | 在 Connectors 问题域之外的原因 | Connectors 如何旁路 / 集成 |
|---|---|---|
| 厂商中立工作负载身份标准（SPIFFE ID/SVID） | Connectors 复用 K8s RBAC/SA，不发身份标准 | 可作 substrate 集成（见 §3 方向 1） |
| 跨 trust-domain 联邦（SPIRE↔SPIRE） | Connectors 不做跨组织身份联邦 | 客户已有 SPIRE 联邦不影响 Connectors |
| OIDC 联邦换云凭据（JWT-SVID → AWS STS / GCP WIF / Vault） | Connectors 不做"工作负载换云凭据"，它做"工作负载用工具" | 互补：SPIRE 换云凭据，Connectors broker 工具凭据；可叠加 |
| 非 K8s 工作负载身份（VM / 裸机 / 多云） | Connectors 锚在 K8s/Tekton | SPIRE 可覆盖 Connectors 触及不到的非 K8s 工作负载 |

**为什么拆两张表**：§2.1 是身份层的"同台 + 集成点"，§2.2 是 SPIRE 在 Connectors 边界外的能力——避免读者误以为"SPIRE 缺很多"或"SPIRE 更全"。真相是：**两者大部分能力根本不在同一层**，唯一真正重叠的是"客户端身份 substrate"那一行，而那一行恰是集成机会而非竞争。

---

## §3 集成方向与 Roadmap 启发

> **核心立场：SPIFFE/SPIRE 是集成候选 + benchmark，不是替代品。** 思路方向，不写实施草案。允许 🟡 草稿态。

**自然边界**

- SPIRE 不替代 Connectors：CI 真凭据隔离 / 镜像无凭据拉取 / 工具透传 API / Pipeline UI 选资源 / 运行时按调用审批 / 即时吊销——SPIRE 结构上不覆盖（它发身份就结束）。
- Connectors 不替代 SPIRE：厂商中立身份标准 / 跨域联邦 / 非 K8s 工作负载身份 / OIDC 换云凭据——不在 Connectors 问题域。

**核心思路**

> **SPIRE 负责"工作负载是谁"（可验证身份），Connectors 负责"工作负载怎么用工具、且永远拿不到真凭据"。**
>
> 当前 Connectors 客户端用 K8s 短期 SA token 向 Proxy 鉴权。SPIFFE/SPIRE 是这个 substrate 的**更强、更标准、跨平台**候选——但**不是必须**，因为 Connectors 已锚在 K8s 且 SA token 够用。SPIRE 的价值在于"跨 K8s/VM/多云统一身份"或"客户已投资 SPIRE"的场景。

### 集成方向

**方向 1：SPIFFE ID/SVID 作为 Connectors 客户端身份的可选 substrate（benchmark 对齐）**

- **背景**：Connectors Proxy 当前认 K8s SA token；SPIFFE/SPIRE 提供同层但厂商中立、跨平台的身份（SVID）。把 Proxy 的客户端身份校验抽象成"可插拔 identity provider"，K8s SA token 为默认实现，SPIFFE SVID 为可选实现。
- **价值**：(1) 覆盖非 K8s 工作负载（VM/裸机 CI runner）接入 Connectors；(2) 客户已有 SPIRE trust domain 时复用其身份；(3) 对齐 CNCF 工作负载身份标准，强化"K8s 原生 + 开放标准"定位。
- **风险**：Connectors 已深度绑定 K8s SA token + SubjectAccessReview 即时吊销；换成 SVID 后"每请求 RBAC 吊销"如何保持（SVID 靠短 TTL 收敛，非即时撤销）需重新设计。这是**真实 trade-off**，不是低风险。
- **定位**：架构演进 + benchmark 对齐，**非为替代**——SPIRE 只是 substrate 候选之一。

**方向 2：JWT-SVID / OIDC 联邦与 Connectors 互补（不冲突的叠加）**

- SPIRE 的 OIDC 联邦解决"工作负载换**云**凭据"，Connectors 解决"工作负载用**工具**凭据"——两条正交。客户可同时用：SPIRE 给工作负载身份 + 换 AWS STS；Connectors 给同一工作负载 broker GitLab/Harbor 访问。
- **效果**：在已部署 SPIRE 的客户环境，Connectors 不与之争身份层，反而坐在它之上消费身份。

**🟡 待审视：吊销语义对位**

- **重合点**：双方都追求短寿命凭据。
- **差异面**：Connectors **每请求 SubjectAccessReview 撤 RBAC = 即时吊销**；SPIRE 主要靠 **SVID 短 TTL 到期 + 删 registration entry** 收敛窗口（非每请求强校验）。
- **未决问题**：若方向 1 落地、客户端身份换成 SVID，"即时吊销"这条护城河如何保留？是在 Proxy 侧对 SVID 再叠一层 per-request 授权检查，还是接受 TTL 收敛？
- **结论**：**待审视后再下定论**。

### Roadmap 启发

**短期可考虑**
- **把 SPIFFE/SPIRE 当 benchmark 而非威胁**：它证明"工作负载免预置 secret 取短寿命身份"是 CNCF graduated 的成熟标准——Connectors 的 SA-token-to-Proxy 模型与之同源，对外材料可借 SPIFFE 标准为 Connectors 身份层背书。
- **moat-by-contrast 话术**：Connectors = "SPIFFE 式短寿命身份" **+** "在集群内 broker 真凭据（真凭据永不进 Pod）" **+** "镜像改写"。SPIRE 止于第一项。对外强调 Connectors 多做的两步，而非贬低 SPIRE。

**中长期考虑**
- **方向 1 评估**：客户端身份可插拔抽象，即便不接 SPIRE 也有价值（解耦 Proxy 与 K8s SA token）；接 SPIRE 用于跨平台 / 已投资场景。先评估"即时吊销 vs SVID TTL"的语义保留方案。

**明确不做**
- 不把 SPIRE 当 secret store / 凭据 broker（它不发业务凭据，这是 Connectors 的活）。
- 不为接 SPIRE 放弃"真凭据永不进 Pod"和"每请求即时吊销"两条护城河——除非方向 1 能保留它们。
- 不重复造身份标准——若要厂商中立身份，对接 SPIFFE/SPIRE，不自研。

### 借鉴 / 启发候选（🟡 候选）

> 仅记录，不下结论；等 `/connectors-arch-review` 或 `/connectors-learn` 触发再决定是否沉淀。

- **客户端身份 substrate 可插拔化**是 Connectors 与 SPIRE 唯一真正同台的轴——值得做成架构原则候选："Proxy 的客户端身份校验不应绑死单一 token 来源"。
- **"发身份"与"broker 真凭据"是两层**——这条边界可与 vault-eval 的"injection vs proxy 分水岭"并列，构成 Connectors 定位矩阵的另一根轴：SPIRE 在"发身份"层，Vault/Infisical 在"存/造凭据"层，Connectors 横跨"用凭据 + 隔离凭据"层。
- **跨竞品身份/凭据分层图值得做成一张表**：SPIRE（身份）/ Vault·Infisical（凭据存储+动态）/ Connectors（凭据使用+隔离+工具接入），三层不竞争、可叠。

---

**相关文档**
- `spiffe-spire-capabilities-guide.md` — SPIFFE/SPIRE 自身能力（精简版能力地图 + 6 章详谈 + 每章 demo + 许可/air-gap）
- `../what-is-connectors.md` — Connectors 产品定位与同心环竞品分类（SPIFFE/SPIRE 落在 ① 机制孪生环，标注"身份原语，非代理；可作集成对象/护城河对照"）
- （跨调研参考）`../infisical/connectors-vs-infisical.md`、`../connectors-vs-vault.md` — 凭据存储层对比，与本文身份层对比互补
