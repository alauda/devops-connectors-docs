# Connectors vs Infisical — 关系、边界、Roadmap 启发

> **摘要**：Connectors 与 Infisical 不是替代关系，是不同问题域的不同范式。Connectors 是 CI/CD 场景下的**业务侧 secretless**（凭据进不了 Pod，靠 in-cluster data-plane proxy）；Infisical 是**集中式 secret 平台**（存储 + 交付凭据，凭据进入工作负载，即使短寿命/动态）。Infisical 在"凭据轮换 / 动态凭据"维度结构性强于 Connectors，并在 Connectors 域外提供 PKI/KMS/SSH/扫描一揽子；Connectors 在"CI secretless / 镜像无凭据拉取 / 工具透传 API / Pipeline UI 选资源 / 运行时按调用审批"上 Infisical 结构性不覆盖。
>
> Infisical 背景见 `infisical-capabilities-guide.md`。Connectors 11 问题域机制见 `inputs/01-connectors-domain-map.md`。

---

## 1. Connectors 的问题域

| 问题域 | 解决什么 | 大致做法 |
|---|---|---|
| **CI Secretless** | Tekton task 里业务永远拿不到真凭据 | Connectors Proxy 在 connectors-system 持真凭据；CSI Driver 用 Pod SA 签短 token（默认 30m），通过面向工具的配置文件模板（`.gitconfig`/`glab config`/`maven settings.xml`）挂进 tmpfs；Proxy 出栈方向注入真实 Basic/Bearer/OCI Token |
| **K8S 镜像无凭据拉取** | 业务 Pod 不引用 imagePullSecret 即可拉私有镜像 | `PodWebhook` 改写 Pod image 到 reverse proxy 地址；kubelet 走 reverse proxy 拉镜像；真 robot 密码只存在 connectors-system |
| **工具透传 API** | 业务/UI 不直连工具 API，统一走 Connectors API server | `ConnectorClass.spec.api.openapi` 声明对外暴露的工具 API 子集；调用方走 Connectors API，server 后端代用户 SA token 调 Proxy 拿真实数据 |
| **Pipeline UI 展示工具资源** | Pipeline 编辑页直接列 Harbor tag / Git 分支 / Maven artifact 供下拉 | 前端 Tekton descriptor 调 Connectors API；认证统一在 Proxy 层 |
| **审批门控原生** | 通过 proxy 访问/操作工具时需先经审批 | `AccessPolicy` + `AccessRequest` CR 与 Tekton `ApprovalTask` 在同一 PipelineRun 内联动；拒绝则 CSI 挂 `.error.json`，Pod 启动即失败 |
| **三级 scope 治理 + 委派** | Connector 资源天然有 cluster/project/namespace 三层 | `kube-public`=cluster；`cpaas.io/inner-namespace` 标签的 namespace-group=project；普通 ns=namespace；委派落到 ACP IAM RoleBinding |
| **项目级多租户** | 项目天然隔离 | 复用 ACP namespace-group / project 模型 |

**Connectors 边界（不解决什么）**：不是通用 KV / 配置中心；不是 KMS / 加密服务 / PKI / SSH CA；不是凭据轮换器；不做 secret 泄漏扫描。

---

## 2. Infisical vs Connectors 能力对比（Connectors 11 问题域）

评级：**原生**（开箱即用、核心场景之一）/ **部分**（能做但要拼装或受 edition 限制）/ **不覆盖**（不在产品边界）。

| # | 问题域 | Connectors | Infisical | 判定 | 用户体验差异 |
|---|---|---|---|---|---|
| 1 | CI Secretless | data-plane proxy，client 看不到真凭据 | 把凭据交付进 workload（K8s Secret/文件/env），即使动态也是短寿命**明文** | **仅 Connectors 覆盖** | Connectors：client 配 `http_proxy` 或读配置文件，零 SDK，真凭据不进 Pod；Infisical：workload 持有真凭据，`cat`/`env`/core dump 可见 |
| 2 | K8S 镜像无凭据拉取 | PodWebhook 改 image + SA token 拉 | 能生成 `dockerconfigjson` imagePullSecret(OSS)，但 **Pod/SA 仍须引用**；**无 image-rewrite / 透明拉取** | **仅 Connectors 覆盖**（Infisical 部分=仅同步 secret） | Connectors：Pod 加 annotation 即可；Infisical：每 ns 投递 Secret + 所有工作负载引用，等同 ESO |
| 3 | 平台治理 + 委派 | 三级 scope + 复用 ACP IAM | 内置 RBAC(粗粒度,OSS)；细粒度 custom role=Paid；**自成一套权限模型** | **双方覆盖（模型不同）** | Connectors：与 ACP RBAC 同源，零额外学习；Infisical：另一套 org/project 角色，需独立培训 + 与 ACP 双向同步 |
| 4 | 项目级多租户 | namespace-group 自然隔离 | project 硬隔离(OSS)，但**与 ACP 项目解耦**、是 KV namespace 非"工具实例→凭据" | **双方覆盖（解耦）** | Connectors：天然复用 ACP 项目；Infisical：在 Infisical 内重建 project 树 + 与 ACP project 对齐 |
| 5 | 审批门控 | `AccessPolicy`+`AccessRequest`+`ApprovalTask`，门控**运行时每次经 proxy 调用** | change request 门控**写 secret**；access request 门控**取得权限**(均 Paid) | **双方覆盖（门控位置不同）** | Connectors：与 ACP Pipeline 审批 UI 一体，审批人 PipelineRun 同屏点；Infisical：门控在 secret 写入/取权时刻，**非按调用**，且付费 |
| 6 | 工具透传 API | OpenAPI schema + Connectors API + Proxy 透传 | 不在 Infisical 范围 | **仅 Connectors 覆盖** | Connectors：统一 API server 代调工具；Infisical：每工具自己写 API client |
| 7 | Pipeline UI 选资源 | ResourceInterface + descriptor + Connectors API | 不在 Infisical 范围 | **仅 Connectors 覆盖** | Connectors：UI 下拉选 branch/tag/project；Infisical：无此产品形态 |
| 8 | 凭据轮换 / 短期化 / 吊销 | 短期化客户端 SA token(30m)，真凭据靠管理员轮换 | **动态凭据(Enterprise) + 自动轮换(Pro*)**，~29 dynamic backend / ~22 rotation provider | **双方部分覆盖（Infisical 在轮换/动态结构优势）** | Connectors：客户端只看 SA token；Infisical：现造短寿命凭据并自动吊销，但凭据已落进 workload |
| 9 | 审计 | K8s audit + AccessRequest + Proxy access log（可 data-plane deny/rate-limit） | 操作审计 + IP/userAgent，**Paid（自托管也要 license）**，流式 Enterprise | **双方部分覆盖（互补）** | Connectors：能在 data plane 拦截；Infisical：记"对 secret 的操作"非"对工具的使用"，且付费 |
| 10 | air-gap 可安装可升级 | OLM bundle + 一个 CR，复用 ACP operator 体系 | OSS 核心 Docker/Helm 可离线；但付费功能需 **offline enterprise license**，Postgres+Redis 依赖，独立栈 | **双方覆盖（成本不同）** | Connectors：OperatorHub 装 operator + 编辑一个 CR；Infisical：自建一套独立平台 + 申请离线 license 解锁治理/动态/审批 |
| 11 | 热轮换不断流 | 反向代理 + SA token TTL，请求级注入，客户端零感知 | operator 更新 K8s Secret + auto-reload 注解触发 **rolling restart**；env 注入需重启 | **双方部分覆盖（Connectors 优）** | Connectors：客户端零感知；Infisical：滚动重启或依赖 app reload |
| 12 | 新工具 onboarding | 一份 ConnectorClass YAML（含 proxy + UI 资源） | 存一个 KV secret + 选交付方式，但 onboard 的是"secret"非"工具集成" | **语义不同** | Connectors：完整代理 + UI 体验；Infisical：仅交付凭据，消费方访问路径自理 |

### 域覆盖总览（粗评）

| 问题域 | Connectors | Infisical | ESO（参考，见 vault-eval archive/inputs/03） |
|--------|-----------|-----------|------|
| 1 CI secretless | 原生 | **不覆盖** | 不覆盖 |
| 2 K8s 镜像拉取 | 原生 | 部分（仅同步） | 部分（仅同步） |
| 3 治理+委派 | 原生(ACP) | 部分(自成模型,细粒度 Paid) | 部分 |
| 4 项目多租户 | 原生(ACP) | 部分(解耦 ACP) | 部分 |
| 5 审批门控 | 原生(按调用) | 部分(写/取权时,Paid) | 不覆盖 |
| 6 工具透传 API | 原生 | 不覆盖 | 不覆盖 |
| 7 Pipeline UI 选资源 | 原生 | 不覆盖 | 不覆盖 |
| 8 凭据轮换/动态 | 部分(只短期化 SA token) | **原生(动态=Ent + 轮换=Pro*)** | 部分(依赖后端) |

> *轮换 edition：pricing 列 "Secret Rotation — Pro"，但官方功能页无 edition banner，免费自托管归属有争议（[issue #2043](https://github.com/Infisical/infisical/issues/2043)）——标 Pro 但带不确定。
| 9 审计 | 部分(data-plane) | 部分(Paid) | 部分 |
| 10 air-gap | 原生(OLM,复用 ACP) | 部分(付费需离线 license) | 原生 |
| 11 热轮换不断流 | 原生(请求级) | 部分(滚动重启) | 部分 |

**与 ESO 的关系**：Infisical 的 K8s 交付（operator/CSI/agent → K8s Secret）与 External Secrets Operator 是**同一形态**（都把外部凭据落成 K8s Secret，client 仍持明文）。Infisical 本身也是 ESO 的一个 provider；官方建议新项目用自家 native operator。所以 vault-eval 里"ESO 对 Connectors 11 域的覆盖评分"基本可平移到 Infisical 的 K8s 交付侧——差异在 Infisical 在 ESO 之上**还自带** secret 存储、PKI、KMS、SSH、扫描、审批、动态凭据这些平台能力。

### 不在 Connectors 问题域内的 Infisical 能力

> Connectors 不主动覆盖这些方向，不构成"Connectors 不足"——边界外，仅供参考。这些正是用户要求补充的"有价值的额外内容"。

| Infisical 能力 | 含义 | edition | 对位 |
|---|---|---|---|
| **通用 KV secret 存储 + 版本 + PITR** | 集中、分层、版本化的凭据字典 | OSS（PITR=Pro） | Vault KV / 配置中心 |
| **PKI / 私有 CA** | X.509 全生命周期，ACME/EST/SCEP，cert-manager issuer | OSS（部分 Ent） | Vault PKI / cert-manager |
| **KMS / 加密即服务** | encrypt/decrypt/签名，key 不出平台 | OSS（HSM/KMIP=Ent） | Vault Transit / 云 KMS |
| **SSH CA** | 短寿命 SSH 证书取代长期 key | 未确认 | Vault SSH / Teleport |
| **Secret 扫描（CLI+Radar）** | 代码库泄漏检测 / git DLP | CLI=OSS；Radar 未确认 | gitleaks / GitGuardian |
| **Secret Sync（推出去 ~42 目的地）** | 把 secret 单向推送到第三方平台 | OSS/Cloud | 与 ESO/Connectors 方向相反 |
| **SDK / Terraform / Ansible 生态** | 应用层多语言 secret SDK | OSS | 应用集成广度 |

### 哲学差异一句话

> **Connectors = "凭据永远进不了客户端"**（data-plane proxy，真凭据死守在 connectors-system，吊销=撤 RBAC）。
> **Infisical = "集中存储 + 把凭据交付进工作负载，用短寿命/动态/轮换把凭据缩到不值得偷"**（凭据仍进 workload，再叠加 PKI/KMS/SSH/扫描一揽子安全制品）。

---

## 3. 集成方向与 Roadmap 启发

**思路方向，不写实施草案。**

**自然边界**

- Infisical 不替代 Connectors：CI Secretless / K8S 镜像无凭据拉取 / 工具透传 API / Pipeline UI 资源选择 / 运行时按调用审批，Infisical 结构上不覆盖。
- Connectors 不替代 Infisical：通用 KV / PKI / KMS / SSH CA / secret 扫描 / 动态凭据 / 凭据轮换，不在 Connectors 问题域。

**核心思路**

> **Infisical 负责凭据的"存储 + 短期化/动态/轮换"，Connectors 负责凭据的"使用 + 客户端永远拿不到"。**
>
> 当前 Connectors 用 Automation Task 刷新工具凭据；结合 Infisical 后这一职责可迁移给 Infisical（动态凭据 + 轮换）——Connectors 中所有"短周期凭据"问题都应思考如何结合外部 secret 平台实现。这与 vault-eval 的结论一致（Infisical 与 Vault/OpenBao 在此处是可互换的 backend 候选）。

### 集成方向

> 三个方向逻辑递进：方向 1 是架构基础（不依赖 Infisical），方向 2 是在它上面的具体集成，方向 3 是另一条无侵入路径。与 vault-eval 的三方向同构——**Infisical 是 `SecretBackend` 的又一个候选实现**，不是新范式。

**方向 1：在 Connectors 内抽象 `SecretBackend` interface（架构演进，独立于具体 backend）**

- 解耦"Connector 引用的 secret 从哪来"：默认 K8s Secret（air-gap 开箱即用）；可选 Vault / OpenBao / **Infisical** / AWS SM / Azure KV。
- **价值独立**：Connectors 不绑死 K8s Secret，复用客户已有 secret store 投资——即便客户不用 Infisical，这件事本身有价值。
- **定位**：产品架构演进，**不是为 Infisical 而做**，Infisical 只是众多 backend 之一。

**方向 2：基于方向 1，以 Infisical 为后端实现短周期凭据**

- 在 `SecretBackend` 抽象上落地 Infisical backend：Infisical 动态凭据（DB/AWS/GCP/K8s 等）或轮换后的短寿命 secret 同步进 Connectors 引用的 Secret，Proxy 出栈注入。
- **效果**：管理侧凭据短周期 + 业务侧永远拿不到真凭据——两优势叠加。替代当前 Automation Task 刷新。
- ⚠️ **edition 现实**：Infisical 动态凭据是 **Enterprise**，轮换是 **Pro**——走这条路 = 让客户买 Infisical license。对 air-gap 客户还需 offline license。这是相对"OpenBao（动态凭据开源）"的劣势点，需在选型时摆明。

**方向 3：Infisical operator/CSI 直接挂载 + Connectors 配置模板**

- 不走 Connectors Proxy，把 Infisical 交付的短寿命凭据通过 Connectors 的配置文件模板机制直接挂进 Pod。
- Task 层 0 侵入，集成路径极简；折中是业务进程持有了凭据（即便短期），哲学上不再 secretless。

### Roadmap 启发

**短期可考虑**

- **方向 1 优先**：评估 `SecretBackend` 抽象工程量；即便不上 Infisical 也有独立价值（Vault/OpenBao/云 SM 客户场景）。
- **方向 2 谨慎**：Infisical 作为 backend 可行，但动态/轮换全付费——优先评估 **OpenBao**（动态凭据开源、air-gap 无 license 负担）作为同一抽象下更友好的 backend；Infisical 更适合"客户已有 Infisical 投资"的场景。

**中长期考虑**

- **多租户/治理对齐**：Infisical 有自己的 project/RBAC 树，与 ACP IAM 解耦——若集成，要解决"Infisical project ↔ ACP project"映射与权限同步，否则两套治理面割裂。这是 ACP 相对纯 Infisical 路线的真实差异化点（Connectors 复用 ACP IAM，零第二套权限模型）。
- **PKI / KMS / SSH 不重复造轮子**：客户若需要这些，对接 Infisical/Vault/cert-manager，Connectors 不进入这些域。

**🟡 待审视的开放问题**

- **审批门控对位**：Infisical 的审批（change request / access request）门控在"写 secret / 取权限"，Connectors 门控在"运行时每次经 proxy 调用工具"——**门控位置不同，不构成直接竞争**，但客户可能误以为等价。需 PM 准备话术区分"secret 变更审批"与"凭据使用审批"。
- **"免费开源 secret 平台"叙事的真相**：Infisical MIT 开源，但治理/动态/审批/审计/SSO 几乎全付费，自托管 air-gap 还需 offline license。对比 ACP + Connectors（这些能力随平台打包、复用 IAM、OLM 升级、无第二份 license），这是销售层面值得讲清的差异——但要客观，不贬低（Infisical 的 OSS 核心 + PKI/KMS/扫描在免费层确实可用）。

**明确不做**

- 不做 Infisical OSS 替代品（KV / PKI / KMS / 扫描不进入 Connectors 问题域）。
- 不重写 Infisical 成熟能力（动态凭据 / 轮换 / PKI）。
- 不把 Infisical Enterprise 作为强依赖（air-gap 客户大量无 Enterprise license；可推 OpenBao 等开源 backend 替代）。

### 借鉴 / 启发候选（🟡 候选，原 insights 副产物并入）

> 仅记录，不下结论；等 `/connectors-arch-review`（原则）或 `/connectors-learn`（教训/话术）触发再决定是否沉淀。

- **"workload 是否持有真凭据"是 Connectors 最硬的差异化轴**：Infisical 即便上动态/轮换，凭据仍落进 K8s Secret（base64=明文）。Connectors proxy 模型是少数能宣称"客户端永不持有真凭据"的——对外材料应反复强化，但诚实标注代价（每类工具需 protocol-aware proxy）。
- **PM 话术：Infisical 是"安全制品中台"不只 secret store**（KV+PKI+KMS+SSH+扫描+动态一锅端）。客户可能拿"人家一个产品全包"来比；应对：Connectors 是 **CI/CD 凭据使用面**的深度，不是 secret 平台的广度，广度交给 ACP 生态里的 Vault/OpenBao/cert-manager。
- **edition 诚实是我方优势但别夸大**：Infisical 治理/动态/审批/审计/SSO 几乎全付费 + 自托管要 license + air-gap 要 offline license；ACP+Connectors 这些随平台打包、复用 IAM、OLM 升级、无第二份 license。真实差异，但对外要客观（Infisical OSS 核心 + PKI/KMS/扫描免费层确实可用）。
- **审批门控位置矩阵值得做成跨竞品一张表**：Vault Control Groups（取凭据时）/ Infisical change·access request（写 secret·取权限时）/ Connectors ApprovalTask（运行时按 proxy 调用）——门控位置各不同，易被误读为等价。

---

**相关文档**

- `infisical-capabilities-guide.md` — Infisical 工具自身能力（能力地图速览 + 分章详谈 + 每章 demo + edition 总表）
- `inputs/01-connectors-domain-map.md` — Connectors 11 维问题域机制说明
- `inputs/02-infisical-research-notes.md` — 带 URL 的原始调研笔记
- （跨调研参考）`../connectors-vs-vault.md` — Vault 同维度对比，方向 1/2/3 同构
