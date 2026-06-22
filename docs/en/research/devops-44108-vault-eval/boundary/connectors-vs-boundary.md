# Connectors vs HashiCorp Boundary — 关系、边界、Roadmap 启发

> **结论摘要**：Boundary 是 Connectors **机制孪生环（①）**里的"人→主机会话访问代理"——controller/worker 架构、经代理免持凭据访问目标，与 Connectors 的"data-plane proxy + 真凭据不进客户端"在 secretless 机制上重合。但有**三条结构性分水岭**：(1) **会话级注入，非 per-request** —— Boundary 在会话授权时一次性取/注入凭据，会话时限内不再逐请求过中央鉴权；Connectors 每请求对中心 K8s RBAC 做 SubjectAccessReview，撤 RBAC 成员即刻断流。(2) **面向人类访问，非 CI/工作负载** —— Boundary 代理的是"人经 CLI/Client Agent 访问主机/DB/K8s"；它没有"给 Pod 挂工具配置 / 免 imagePullSecret 拉镜像 / Pipeline UI 选资源"这套 CI 面。(3) **BUSL 不可内嵌** —— Boundary `>=0.14.0` 为 BUSL-1.1，发行竞品平台的 ISV（Alauda）不能把它嵌进 ACP 分发。
> **两点额外要害**：Boundary 的 **secretless 注入（injected 凭据）是 Enterprise/HCP 限定**，Community 只有 brokered（凭据仍回到客户端手里）；且 Boundary **自身无任何 DevOps 工具动态凭据引擎**，动态能力全靠 broker Vault。
> **基于源**：`boundary-capabilities-guide.md` + 官方文档 URL。**覆盖范围**：Community（OSS）+ Enterprise/HCP（显式标注）。**不覆盖**：价格；Boundary 各主机协议深度机制。

---

## 1. Connectors 的问题域

| 问题域 | Connectors 的解法 | 体验 |
|---|---|---|
| **CI Secretless** | Proxy 在 connectors-system 持真凭据；CSI Driver 用 Pod SA 签短 token 挂面向工具的配置文件模板（`.gitconfig`/maven `settings.xml`/`.docker/config.json`）；Proxy 出栈方向注入真实 Basic/Bearer/OCI Token | 业务进程当普通配置读，真凭据不进 Pod |
| **K8S 镜像无凭据拉取** | OCI/Harbor reverse proxy + `PodWebhook` 改写 Pod image 到 proxy 地址；kubelet 走 proxy 拉镜像；真 robot 密码只在 connectors-system | Pod 加注解即可，无 imagePullSecret |
| **工具透传 API** | `ConnectorClass.spec.api.openapi` 暴露工具 API 子集；调用方走 Connectors API，server 代用户 SA 调 Proxy 拿真数据 | UI/SDK 统一调，不直连工具 |
| **Pipeline UI 选资源** | `ResourceInterface` + Tekton frontend descriptor + Connectors API | 编辑页下拉选 Git 分支 / Harbor tag |
| **审批门控** | `AccessPolicy` + `AccessRequest` + Tekton `ApprovalTask` 同 PipelineRun 联动；拒绝则 CSI 挂 `.error.json`，Pod 启动即失败 | Pipeline 内审批，与 ACP UI 一体 |
| **运行时按调用吊销** | Proxy 每请求做 SubjectAccessReview；撤 RBAC 即秒级生效 | 吊销不等会话/凭据过期 |
| **三级 scope 治理 + 委派** | cluster / project / namespace 三层；委派落 ACP IAM RoleBinding | 与 ACP RBAC 同源 |
| **air-gap 安装升级** | OLM bundle + 一个 CR，复用 ACP operator 体系 | OperatorHub 装 + 编辑一个 CR |

**Connectors 边界（不解决什么）**：不是人→主机的通用访问代理（无 SSH/RDP/DB 交互式会话与录屏）；不发人类身份 / SSO；不是通用 secret store / CA。

---

## 2. Boundary vs Connectors 能力对比

### §2.1 在 Connectors 问题域内的对比

| # | 问题域 | Connectors | Boundary | 关键差异 |
|---|---|---|---|---|
| 1 | CI Secretless | data-plane proxy 出栈注入真凭据，client 看不到真凭据；面向 **CI/工作负载** | 面向**人类访问**：**injected**（worker 代认证、client 永不见凭据）但**仅 Enterprise/HCP**；Community 只有 **brokered**（凭据回交 client） | Connectors：真凭据不进客户端 + 面向 CI；Boundary：同等"client 不持凭据"要付费版，且面向人不面向 Pod |
| 2 | K8S 镜像无凭据拉取 | PodWebhook 改 image + SA token 走 reverse proxy 拉 | **不覆盖**：无 imagePullSecret / image-rewrite 概念 | Boundary 不进入 kubelet 镜像拉取面 |
| 3 | 工具透传 API | OpenAPI schema + Connectors API + Proxy 透传工具数据 | **不覆盖**：只代理人对目标的会话，不聚合工具资源 API | Boundary 不返工具数据 |
| 4 | Pipeline UI 选资源 | ResourceInterface + descriptor 列 branch/tag/artifact | **不覆盖**：无 CI 编辑器内工具内容资源选择器 | Boundary 无此产品形态 |
| 5 | 审批门控 | AccessPolicy+AccessRequest+ApprovalTask，门控**运行时每次经 proxy 调用** | **无原生审批工作流**:文档无人工审批/门控原语,访问靠预配 role + JIT 凭据(官方强调 just-in-time access 与 RBAC,未提供 per-request 人工批准；属观察)（[what-is-boundary](https://developer.hashicorp.com/boundary/docs/overview/what-is-boundary)） | Connectors：审批挂"每次用"；Boundary：靠预配 RBAC 放行，**不做** per-request 人工批 |
| 6 | 运行时按调用吊销 | 每请求对中心 K8s RBAC 做 SubjectAccessReview，撤 RBAC 成员秒级失效 | **会话级**：会话授权后时限内不再逐请求过中央鉴权；改授权对**已建会话**不立即生效（可手动 cancel session） | Connectors：撤 RBAC 成员立即断；Boundary：要等会话过期或手动 cancel |
| 7 | 凭据短期化 / 轮换 | 短期化 client SA token，真凭据靠管理员轮换 | **brokered/injected 经 Vault 现造一次性凭据，会话结束撤 lease**（动态能力来自 Vault，非 Boundary 自造） | Boundary 把"一次性凭据"做到会话粒度，但需外接 Vault；Connectors 短期化 client token、工具真凭据另管 |
| 8 | 审计 | K8s audit + AccessRequest + Proxy access log（可 data-plane deny/rate-limit） | 会话/连接事件（OSS）+ **会话录制 BSR 回放（Enterprise/HCP Plus）** | Boundary 含交互式会话录屏回放；Connectors 审计聚焦工具调用与审批 |
| 9 | air-gap 安装升级 | OLM bundle + 一个 CR，复用 ACP operator | 自托管可离线（Controller+PG+Worker+Vault+S3），Enterprise 需 license（offline 机制未确认）；HCP 不适用 air-gap | Connectors：OperatorHub 一个 CR；Boundary：独立栈 + 多依赖 + Enterprise license |
| 10 | 三级 scope 治理 | cluster/project/namespace + 复用 ACP IAM RoleBinding | global/org/project 三层 scope + 自有 allow-only RBAC（非复用 K8s RBAC） | 都三层；Boundary 自带 RBAC 模型，Connectors 复用 ACP/K8s RBAC |
| 11 | 新工具 onboarding | 一份 ConnectorClass YAML（proxy + UI 资源 + API） | 建 target + host catalog + （可选）Vault 凭据库；**无工具内容资源 UI** | Connectors：完整代理 + UI 体验；Boundary：把目标建模为可代理主机/服务 |

#### §2.1 小结：基于对比的观察

- **相同点（机制孪生）**：都是"**经代理访问、客户端免持长期凭据**"的 secretless 范式；都做控制面/数据面分离（Connectors proxy+controller / Boundary worker+controller）；都能把"一次性/短期凭据"接进访问生命周期（Connectors 短期 SA token / Boundary broker Vault 动态凭据）。
- **Boundary 强于 Connectors 的点（值得借鉴）**：① 人→主机访问的成熟度（SSH/RDP/DB/K8s/TCP 多协议 + multi-hop 穿私网 + Transparent Sessions）；② 会话录制 BSR 回放（合规面 Connectors 没有）；③ 与 Vault 现造一次性凭据 + 会话结束撤 lease 的闭环干净。
- **Boundary 弱于 Connectors 的点（诚实标注边界）**：① **面向人类访问**，不覆盖 CI/工作负载 secretless、免 imagePullSecret 拉镜像、Pipeline UI 选资源、工具数据透传 API；② **无原生 per-request 审批工作流**（访问靠预配 RBAC + JIT 凭据,无人工批准原语）；③ 吊销是**会话级**非 per-request RBAC 成员级；④ **injection（client 永不见凭据）是付费能力**，OSS 只到 brokered；⑤ **无任何 DevOps 工具动态凭据引擎**（GitLab/Harbor/Nexus 全缺，靠 broker Vault）。
- **一句话结论**：Boundary 与 Connectors 在"**经代理免持凭据访问**"上机制重合，但 Boundary 是**人→主机会话访问代理**、注入是**会话级且付费**、且 **BUSL 不可内嵌**；Connectors 是 **CI/工作负载 secretless + 免 imagePullSecret + Pipeline 治理** 的深度——两者在 secretless 机制上重合，定位正交。

**架构安全属性：目标侧零入站端口（multi-hop reverse proxy）**：Boundary 的 egress worker 可反向拨回 ingress worker，目标资源待在私网零入站——与 Teleport reverse tunnel 同款收益。与 Connectors 是**中性差异**：Connectors proxy 在 connectors-system 内对外部工具是出站连接，本就不要求工具开入站；Boundary 的 multi-hop 在"目标分散于多个客户私网、要统一从中心接入人类访问"时更省网络改造。

### §2.2 不在 Connectors 问题域内的 Boundary 能力

> Connectors 不主动覆盖这些方向，不构成"Connectors 不足"——边界外，仅供参考。

| Boundary 能力 | 在 Connectors 问题域之外的原因 | Connectors 如何旁路 |
|---|---|---|
| **人→主机访问代理（SSH/RDP/DB/TCP）** | Connectors 面向 CI/工作负载→工具，不做人类交互式主机访问 | 客户用 Boundary/Bastion 解决人类访问，与 Connectors 正交 |
| **会话录制 / BSR 回放（Enterprise/HCP Plus）** | Connectors 无交互式会话概念 | 由 Boundary / 审计平台承担 |
| **Transparent Sessions（Client Agent，Enterprise/HCP）** | 透明代理人类桌面流量，超出 CI 面 | 不进入 |
| **人类 SSO / 身份目录（auth method）** | Connectors 复用 ACP IAM，不发人类身份 | ACP IAM / Keycloak |
| **动态主机发现（云 plugin host catalog）** | Connectors 不维护主机清单（工具是被建模的连接对象） | 不进入 |

---

## 3. 集成方向与 Roadmap 启发

**思路方向，不写实施草案。**

### 许可红线：不可内嵌（load-bearing 结论）

> Boundary 源码 `>= 0.14.0` 为 **BUSL-1.1**（4 年后转 MPL-2.0），禁止"与 HashiCorp 商业产品竞争的生产用途"（[HashiCorp 许可变更公告](https://discuss.hashicorp.com/t/hashicorp-projects-changing-license-to-business-source-license-v1-1/57106)、[boundary/LICENSE](https://github.com/hashicorp/boundary/blob/main/LICENSE)）。
>
> **结论**：Alauda 作为发行 ACP 的 ISV **不能把 Boundary 嵌进 ACP 分发**。这与 vault-eval / teleport 判定一致——机制最像 Connectors 的三个访问类产品（Teleport AGPL+禁嵌入、Boundary BUSL、Vault BSL）恰恰许可上都不可嵌入，**强化了 Connectors 自研 + K8s 原生 + Apache 生态的定位**。Boundary 只能作为**客户已有的、与 Connectors 正交并存**的产品看待，不作集成依赖。

### 自然边界

- Boundary 不替代 Connectors：**K8s 镜像无凭据拉取 / per-request RBAC 吊销 / Pipeline UI 工具资源选择器 / 工具数据透传 API / CI 工作负载 secretless** 它结构上不覆盖；且**许可不可内嵌**。
- Connectors 不替代 Boundary：人→主机访问代理、会话录屏、Transparent Sessions、人类 SSO、动态主机发现，不在 Connectors 问题域。

### 借鉴 / 启发候选（🟡 候选，不下结论；等 `/connectors-arch-review` / `/connectors-learn` 触发再沉淀）

- **🟡 "会话结束撤 Vault lease"是干净的一次性凭据闭环**：Boundary 在会话授权时从 Vault 现造、会话结束调 `sys/leases/revoke` 撤销。Connectors 的工具真凭据目前靠管理员/Automation 轮换；**若未来 Connectors 要为工具侧引入"用完即焚"动态凭据，Vault/OpenBao 作为 backend + 在 proxy 会话/请求边界撤 lease 是可参考的生命周期模型**（与 vault-eval / infisical-eval 结论呼应：动态/轮换应结合外部 secret 平台）。
- **🟡 注入点位置矩阵值得做成跨竞品表**：Connectors=connectors-system 中心 proxy 出栈逐请求注入；Secretless Broker=同 Pod sidecar loopback 注入；Teleport=中心 Proxy + 贴目标 agent 注入/认证；**Boundary=数据面 worker 在会话授权时一次性注入（injected，付费）**。把"注入点 + 注入粒度（per-request vs 会话级）+ 凭据是否回客户端"拉成一张表，能清楚讲出 Connectors 的 per-request + 真凭据不进客户端的差异化。
- **🟡 审批门控位置矩阵**（接 teleport 那条）：Vault Control Group=取凭据时 / Teleport Access Request=取权限时签升权证书 / **Boundary=无人工审批原语（靠预配 RBAC + JIT 凭据）** / Connectors ApprovalTask=运行时按 proxy 调用。Boundary 这格是"**反例**"——它无 per-request 人工审批原语,正好反衬 Connectors"按调用门控"的差异化定位，对外应讲清。
- **🟡 brokered vs injected 是讲清 secretless 程度的好框架**：Boundary 自己把"凭据回客户端（brokered）"和"客户端永不见（injected）"分成两档、且后者付费。Connectors 对外讲 secretless 时可借此框架强调：**Connectors 默认就是 injected 等级（真凭据永不进客户端），且不分版收费**。

### 明确不做

- **不内嵌 Boundary**（许可红线，见上）。
- 不自研人→主机访问代理 / 会话录屏 / Transparent Sessions / 人类 SSO（不在 Connectors 问题域）。
- 不把"per-request RBAC 吊销 + 免 imagePullSecret 拉镜像 + Pipeline UI 选资源 + CI 工作负载 secretless"让位——这是 Connectors 相对 Boundary 的硬边缘，应持续强化。

---

## 附：额外有价值发现（技能范围外）

- **Boundary 的 secretless 注入分版收费**是行业信号：连 HashiCorp 都把"client 永不见凭据"放进付费版（Community 只到 brokered）。Connectors 把"真凭据永不进客户端"作为**默认、免费、不分版**的基础属性，是对外定位时值得强调的反差点。
- **Boundary 无人工审批原语,访问模型是预配最小权限 RBAC + JIT 凭据**（属观察,非官方"取代审批"表述），与 Connectors"按调用人工审批门控"是两种治理范式。客户若问"你们为什么要审批、Boundary 说不需要"，应对话术：Connectors 的 ApprovalTask 面向 **CI/CD 高危 promotion 的运行时门控**（人为决策点），与 Boundary 的"预配最小权限免审批人类访问"是不同场景，不冲突。
- **许可演化再次印证"机制可借鉴、产品不可拿来嵌入"**：机制最像 Connectors 的 Teleport / Boundary / Vault 全部改了非 OSI/限制性许可。对 ISV（Alauda），这反复支撑 Connectors 自研的战略合理性。
- **Boundary 无 DevOps 工具动态引擎**：它对 GitLab/Harbor/Nexus/JFrog 没有任何"现造令牌"能力，动态全靠 broker Vault——这印证整条调研线的共识：**DevOps 工具侧的动态凭据是产业空白**，谁都靠 Vault 兜底；Connectors 若做工具侧动态凭据，是空白区而非红海。

---

**相关文档**
- `boundary-capabilities-guide.md` — Boundary 工具自身能力（作用域内：会话代理 / brokered·injected 凭据 / Vault 集成 / K8s 目标 / 审计录制 / RBAC）
- `../teleport/connectors-vs-teleport.md` — 同 ① 环 Teleport 对比（access-proxy + 短期身份 + JIT 审批 + 审计）
- `../secretless-broker/connectors-vs-secretless-broker.md` — 同 ① 环 Secretless Broker 对比（sidecar 注入）
- `../what-is-connectors.md` — Connectors 定位 + 竞品三环（Boundary 在第 ① 环"机制孪生"）
