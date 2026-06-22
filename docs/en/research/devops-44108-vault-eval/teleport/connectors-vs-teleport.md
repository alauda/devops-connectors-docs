# Connectors vs Teleport — 关系、边界、Roadmap 启发

> **结论摘要**：Teleport 是 Connectors **产品愿景上最完整的对标物** —— "access-proxy + 短期身份 + JIT 审批 + 审计"四件套它都有，且更成熟、更广（覆盖人 + 机器 + 工作负载，跨 SSH/K8s/DB/Web/Git）。但两者机制范式有**两条结构性分水岭**：(1) Teleport 是 **identity-passthrough**（代理用户/机器**自己的**短期证书去访问目标；Teleport 每次访问会用最新 role 定义重新评估 role 规则，但证书携带的 **role 集合在签发时固定**，改 role *成员* 需重签 / lock），Connectors 是 **credential-injection / secretless**（真凭据死守 `connectors-system`，客户端只拿短期 SA token + proxy 地址，出栈方向注入后端真凭据，客户端**永不持有任何能直连后端的凭据**）；(2) Teleport 改 role **成员关系**要等证书重签 / `lock`，Connectors 的吊销靠**每请求对中心 K8s RBAC 做 SubjectAccessReview，撤 RBAC 成员即刻生效**。
> **两条 Connectors 独有边缘（Teleport 不覆盖）**：**per-request RBAC-成员吊销**（Connectors 每请求 SAR 命中外部 K8s RBAC，撤成员即刻断；Teleport 的 role *成员* 变更要重签 / lock）与 **image-pull rewrite**（Teleport 无"免 imagePullSecret 透明拉镜像"）。
> **许可红线（决定不可内嵌）**：Teleport Community 官方二进制 v16 起为商用 license，**明文禁止 resale / embed 进产品**；core 源码 AGPLv3。Alauda 作为发行 ACP 的 ISV **不能把 Teleport 嵌进 ACP**（见 §3）。
>
> Teleport 能力背景见 `teleport-capabilities-guide.md`。Connectors 11 域机制见 `../infisical/inputs/01-connectors-domain-map.md`（若存在）。

---

## 1. Connectors 的问题域

| 问题域 | Connectors 的解法 | 体验 |
|---|---|---|
| **CI Secretless** | Proxy 在 connectors-system 持真凭据；CSI Driver 用 Pod SA 签短 token（默认 ~30m）挂面向工具的配置文件模板（`.gitconfig`/`maven settings.xml`/`.docker/config.json`）；Proxy 出栈方向注入真实 Basic/Bearer/OCI Token | 业务进程当普通配置读，真凭据不进 Pod |
| **K8S 镜像无凭据拉取** | OCI/Harbor reverse proxy + `PodWebhook` 改写 Pod image 到 proxy 地址；kubelet 走 proxy 拉镜像；真 robot 密码只在 connectors-system | Pod 加注解即可，无 imagePullSecret |
| **工具透传 API** | `ConnectorClass.spec.api.openapi` 暴露工具 API 子集；调用方走 Connectors API，server 代用户 SA 调 Proxy 拿真数据 | UI/SDK 统一调，不直连工具 |
| **Pipeline UI 选资源** | `ResourceInterface` + Tekton frontend descriptor + Connectors API | 编辑页下拉选 Git 分支 / Harbor tag |
| **审批门控** | `AccessPolicy` + `AccessRequest` + Tekton `ApprovalTask` 同 PipelineRun 联动；拒绝则 CSI 挂 `.error.json`，Pod 启动即失败 | Pipeline 内审批，与 ACP UI 一体 |
| **运行时按调用吊销** | Proxy 每请求做 SubjectAccessReview；撤 RBAC 即秒级生效 | 吊销不等证书过期 |
| **三级 scope 治理 + 委派** | cluster / project（namespace-group）/ namespace 三层；委派落 ACP IAM RoleBinding | 与 ACP RBAC 同源 |
| **air-gap 安装升级** | OLM bundle + 一个 CR，复用 ACP operator 体系 | OperatorHub 装 + 编辑一个 CR |

**Connectors 边界（不解决什么）**：不是人→主机的通用访问代理（无 SSH/RDP/DB 交互式会话与录屏）；不发人类身份 / SSO；不是通用 secret store / CA / SPIFFE 身份提供方。

---

## 2. Teleport vs Connectors 能力对比（Connectors 11 域）

评级：**原生**（开箱即用、核心场景之一）/ **部分**（能做但要拼装或受 edition 限制）/ **不覆盖**（不在产品边界）。

### §2.1 在 Connectors 问题域内的对比

| # | 问题域 | Connectors | Teleport | 判定 | 关键差异 |
|---|---|---|---|---|---|
| 1 | CI Secretless | data-plane proxy 出栈注入真凭据，client 看不到真凭据 | tbot 给 CI 发**短期证书**（client **持有该证书**去直连/经 proxy 访问目标） | **双方覆盖（范式不同）** | Connectors：真凭据不进 Pod；Teleport：client 持短期证书（短寿命但仍是可直连目标的凭据），泄漏窗口=证书 TTL |
| 2 | K8S 镜像无凭据拉取 | PodWebhook 改 image + SA token 走 reverse proxy 拉 | **不覆盖**：无 imagePullSecret 透明拉取 / image-rewrite 概念 | **仅 Connectors 覆盖** | Teleport 不进入 kubelet 镜像拉取面 |
| 3 | 工具透传 API | OpenAPI schema + Connectors API + Proxy 透传工具数据 | 部分：Application Access 反代 HTTP 应用 + 注入**身份 JWT**（不是工具数据 API 聚合） | **Connectors 原生 / Teleport 部分（语义不同）** | Connectors 代调工具并返工具数据；Teleport 只把流量身份化反代，不聚合工具资源 |
| 4 | Pipeline UI 选资源 | ResourceInterface + descriptor 列 branch/tag/artifact | **不覆盖**：无 CI 编辑器内工具内容资源选择器 | **仅 Connectors 覆盖** | Teleport 无此产品形态 |
| 5 | 审批门控 | AccessPolicy+AccessRequest+ApprovalTask，门控**运行时每次经 proxy 调用** | Access Requests（JIT）门控**取得权限时刻**，产物是**有时限升权证书**（Role Request 有 Community CLI-only preview；审批规则/阈值、Resource Request、Web UI、插件属 Enterprise） | **双方覆盖（门控位置不同）** | Connectors：审批挂"每次用"；Teleport：挂"取权限"，升权后 TTL 内不再逐次审；Teleport 完整审批工作流（规则/阈值/插件）需 Enterprise，Community 仅 CLI-only Role Request preview |
| 6 | 运行时按调用吊销 | 每请求对中心 K8s RBAC 做 SubjectAccessReview，撤 RBAC 成员秒级失效 | **部分**：每次访问会用最新 role 定义重评 role 规则，但改 role **成员**（增删 role）要重签证书 / `lock` 才生效 | **Connectors 在 RBAC-成员吊销粒度上独有** | Connectors：撤 RBAC 成员立即断；Teleport：会重评 role 规则，但已签证书携带的 role 集合固定，role 成员变更需重签 / lock |
| 7 | 凭据短期化 / 轮换 | 短期化 client SA token（~30m），真凭据靠管理员轮换 | **原生**：人/机/工作负载全短期证书（tbot 默认 cert TTL 1h / 续期 20m；SVID 短寿命） | **双方部分（Teleport 短期化更彻底）** | Teleport 把"短期化"做成全局范式（含人类访问）；Connectors 只短期化 client token，工具真凭据另管 |
| 8 | 审计 | K8s audit + AccessRequest + Proxy access log（可 data-plane deny/rate-limit） | **原生**：结构化事件 + 会话录像 + SIEM 导出，默认存 1 年 | **双方覆盖（Teleport 更全）** | Teleport 含交互式会话录屏回放 + git 命令审计；Connectors 审计聚焦工具调用与审批 |
| 9 | air-gap 安装升级 | OLM bundle + 一个 CR，复用 ACP operator | 部分：自托管可离线，但 Enterprise 功能需 license（offline 机制未确认） | **双方覆盖（成本不同）** | Connectors：OperatorHub 一个 CR；Teleport：独立栈 + Enterprise license |
| 10 | 热轮换不断流 | reverse proxy + SA token TTL，请求级注入，client 零感知 | tbot 后台续证书，长任务/服务零感知；交互会话内不断流 | **双方覆盖** | 机制不同但都做到运行中不断流 |
| 11 | 新工具 onboarding | 一份 ConnectorClass YAML（proxy + UI 资源 + API） | 注册一类 resource（app/db/k8s…）+ 配 RBAC；**无工具内容资源 UI** | **语义不同** | Connectors：完整代理 + UI 体验；Teleport：身份化访问该资源，不聚合其内容资源 |

### §2.1.1 域覆盖总览（粗评）

| 问题域 | Connectors | Teleport |
|---|---|---|
| 1 CI secretless | 原生（真凭据不进 client） | 部分（client 持短期证书） |
| 2 K8s 镜像拉取 | 原生 | **不覆盖** |
| 3 工具透传 API | 原生 | 部分（身份反代，非工具数据聚合） |
| 4 Pipeline UI 选资源 | 原生 | **不覆盖** |
| 5 审批门控 | 原生（按调用） | 原生（取权限时；Role Request 有 Community CLI preview，完整工作流 Enterprise） |
| 6 per-request RBAC-成员吊销 | **原生（唯一）** | **部分（重评 role 规则，但 role 成员变更需重签 / lock）** |
| 7 短期化/轮换 | 部分（只 client token） | **原生（全局短期证书）** |
| 8 审计 | 部分（工具调用面） | **原生（事件+录屏+SIEM）** |
| 9 air-gap | 原生（OLM 复用 ACP） | 部分（Enterprise 需 license） |
| 10 热轮换不断流 | 原生 | 原生 |

**哲学差异（散文点明）**：Teleport 与 Connectors 是 access 安全的**两种范式**。Teleport = **"让你用一张短命证书去访问目标"**（identity-passthrough；每次访问会用最新 role 定义重评规则，但证书携带的 role 集合在签发时固定，改 role 成员=重签/lock）；Connectors = **"你永远拿不到能直连目标的凭据"**（credential-injection，真凭据死守 connectors-system，吊销=每请求对中心 K8s RBAC 撤成员）。Teleport 的短期证书**仍是 client 手里一份能用的凭据**（短寿命 ≠ 不存在）；Connectors 的 SA token **只能向 proxy 自证身份，不能直连后端工具**。这条线决定了二者在"凭据是否进入业务进程地址空间"上根本不同；同时在吊销粒度上，Connectors 的 RBAC-成员变更即刻生效，Teleport 的 role-成员变更需重签 / lock。

**架构安全属性：目标侧零入站端口（reverse tunnel）**：Teleport 的请求方向是 **Agent 主动拨出连 Proxy**（出站建反向隧道），用户流量经 Proxy 顺隧道**下行**到 Agent——目标资源**无需开任何入站端口**，可整体待在防火墙 / 私网后，攻击面只暴露中心 Proxy 一处。这是把访问入口收敛到中心代理的安全收益。与 Connectors 对照是**中性差异**：Connectors 的代理在 `connectors-system` 内、对外部工具是**出站**连接，本就不要求工具开入站；二者都规避了"为接入而在目标侧开入站端口"，但 Teleport 的 reverse-tunnel 模型在"目标分散于多个私网 / 客户环境、要统一从中心接入"时更省网络改造。

### §2.2 不在 Connectors 问题域内的 Teleport 能力

> Connectors 不主动覆盖这些方向，不构成"Connectors 不足"——边界外，仅供参考。

| Teleport 能力 | 在 Connectors 问题域之外的原因 | Connectors 如何旁路 |
|---|---|---|
| **人→主机访问代理（SSH/K8s/DB/RDP）** | Connectors 面向 CI/工作负载→工具，不做人类交互式主机访问 | 客户用 Teleport/Bastion 解决人类访问，与 Connectors 正交 |
| **会话录制 / 回放** | Connectors 无交互式会话概念 | 由 Teleport / 审计平台承担 |
| **SPIFFE 工作负载身份提供方** | Connectors 复用 K8s SA，不自建 SPIFFE CA | 客户需 SPIFFE 时接 SPIRE/Teleport |
| **人类 SSO / 身份治理** | Connectors 复用 ACP IAM，不发人类身份 | ACP IAM / Keycloak |
| **Git 命令短证书代理（Enterprise）** | Connectors 走 proxy 注入凭据，不签 SSH 证书冒充 GitHub 身份 | Connectors Git connector 走 proxy 注入 token |
| **Device Trust / Identity Security** | 治理/态势面，超出 Connectors 边界 | 不进入 |

---

## 3. 集成方向与 Roadmap 启发

**思路方向，不写实施草案。**

### 许可红线：不可内嵌（load-bearing 结论）

> Teleport Community 官方二进制 **v16 起为商用 Community license**，明文 ***"Companies cannot resell or embed Teleport Community Edition in their products or services."***（[community-license](https://goteleport.com/blog/teleport-community-license/)）；core 源码 **AGPLv3**（[oss-agpl-v3](https://goteleport.com/blog/teleport-oss-switches-to-agpl-v3/)），自编译嵌入会让 ACP 染上 AGPL copyleft。
>
> **结论**：Alauda 作为发行 ACP 的 ISV **不能把 Teleport（Community 或 Enterprise）嵌进 ACP 分发**。这与 vault-eval 里 Teleport/Boundary "许可陷阱"判定一致——机制最像的产品恰恰许可上不可嵌入，反而**强化了 Connectors 自研 + K8s 原生 + Apache 生态的定位**。Teleport 只能作为**客户已有的、与 Connectors 正交并存**的产品看待，不作集成依赖。

### 自然边界

- Teleport 不替代 Connectors：**K8s 镜像无凭据拉取 / per-request RBAC 吊销 / Pipeline UI 工具资源选择器 / 工具数据透传 API** Teleport 结构上不覆盖；且**许可不可内嵌**。
- Connectors 不替代 Teleport：人→主机访问代理、会话录屏、SPIFFE 身份提供、人类 SSO 治理，不在 Connectors 问题域。

### 借鉴 / 启发候选（🟡 候选，不下结论；等 `/connectors-arch-review` / `/connectors-learn` 触发再沉淀）

- **🟡 "零常驻权限 + 时限升权"是 JIT 审批的成熟范式**：Teleport Access Request 产物是"有时限升权证书"，到期自动回收。Connectors 的 ApprovalTask 是"运行时按调用门控"。两者门控位置不同（取权限时 vs 每次调用），**值得做进"审批门控位置矩阵"跨竞品表**（Vault Control Group=取凭据时 / Infisical change·access request=写 secret·取权限时 / Teleport Access Request=取权限时签升权证书 / Connectors ApprovalTask=运行时按 proxy 调用）。Connectors 的"按调用"粒度是差异化优势，对外应讲清。
- **🟡 审批的多渠道集成（Slack/PagerDuty/Mattermost/Jira）是成熟 UX**：Connectors 审批目前绑 Tekton ApprovalTask + ACP UI；若未来要扩审批触达面，Teleport 的插件化审批通知是参考样板（但不内嵌，借鉴 UX）。
- **🟡 SPIFFE 兼容是工作负载身份的事实标准**：Teleport Workload Identity 选择"在自家身份上长 SPIFFE 兼容层"。Connectors 复用 K8s SA token，若未来客户要求工作负载身份跨集群/跨信任域互信，**SPIFFE/SPIRE 是该评估的标准**（与 what-is-connectors §竞品环 ① 的 SPIFFE/SPIRE 判定一致）——作为集成对象而非自研。
- **🟡 "短期证书取代长期密钥"作为全局范式的彻底性**：Teleport 把短期化推到人类访问层。Connectors 只短期化 client SA token，工具真凭据仍靠管理员/Automation Task 轮换——这与 vault-eval / infisical-eval 的结论呼应：**Connectors 所有"短周期凭据"问题都应思考结合外部 secret 平台（Vault/OpenBao/Infisical）实现工具侧动态/轮换**，Teleport 不是该路径的 backend 候选（它是访问代理，不是 secret 引擎）。

### 明确不做

- **不内嵌 Teleport**（许可红线，见上）。
- 不自研人→主机访问代理 / 会话录屏 / 人类 SSO（不在 Connectors 问题域）。
- 不自建 SPIFFE CA（需要时接 SPIRE/Teleport 作集成对象）。
- 不把"per-request RBAC 吊销 + 免 imagePullSecret 拉镜像"让位——这是 Connectors 相对 Teleport 的两条硬边缘，应持续强化。

---

## 附：额外有价值发现（技能范围外）

- **Teleport 是"人 + 机器 + 工作负载"统一身份平台**，覆盖面远超 Connectors（含 SSH/K8s/DB/Desktop/Web/Git/MCP）。客户可能拿"一个产品全包基础设施访问"来比；应对话术：Connectors 是 **CI/CD 凭据使用面 + K8s 工作负载 secretless** 的深度（真凭据不进 client + per-request 吊销 + 免 imagePullSecret 拉镜像 + Pipeline UI），不是通用基础设施访问代理的广度。
- **许可演化是行业信号**：机制最像 Connectors 的两个产品（Teleport AGPL+禁嵌入、Boundary BUSL）都在 2023–2024 改了非 OSI/限制性许可。对 ISV（Alauda）而言，这反复印证"机制可借鉴、产品不可拿来嵌入"，间接支撑 Connectors 自研的战略合理性。
- **Git 命令短证书代理（§6.1）是一个有意思的工具接入范式**：让 git 走短 SSH 证书 + GitHub 信任 Teleport CA。与 Connectors 的 Git connector（proxy 注入 token）目标相近但机制相反（证书冒充 vs 凭据注入），且限 Enterprise + GitHub Enterprise Cloud——可作为"工具接入的另一种范式"案例存档，不构成集成方向。

---

**相关文档**
- `teleport-capabilities-guide.md` — Teleport 工具自身能力（作用域内：MWI / Proxy / Access Requests / Git·App 代理 / 审计 / RBAC）
- `../infisical/connectors-vs-infisical.md` — 同维度 Infisical 对比（存储层，第 ③ 环）
- `../what-is-connectors.md` — Connectors 定位 + 竞品三环（Teleport 在第 ① 环"机制孪生"）
