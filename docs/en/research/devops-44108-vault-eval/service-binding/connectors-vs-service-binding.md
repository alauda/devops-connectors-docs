# Connectors vs Kubernetes Service Binding — 关系、边界、Roadmap 启发

> **结论摘要**：Kubernetes Service Binding 是 Connectors 的**形态邻接（②环）参考，不是竞品**。它是一套 K8s 社区标准（spec 1.1.0，Apache-2.0），把「后端服务的连接 **Secret** → 投射进 workload 容器（`$SERVICE_BINDING_ROOT/<name>/<key>` 文件 + 可选 env）」标准化。它与 Connectors 在**机制上根本不同**：Service Binding 做 **secret/config 投射**（明文 Secret 落进 Pod，app 自己持凭据去连后端），Connectors 做 **data-plane proxy**（真凭据永不进客户端、出栈注入、撤 RBAC 秒级吊销）。Service Binding **没有**工具协议代理、没有资源浏览 API、没有 Pipeline 资源选择、没有运行时审批、没有镜像无凭据拉取。它的价值对 Connectors 是 **UX / 兼容性参考**（绑定抽象 + well-known key + 投射目录约定），可启发 Connectors 的 CSI/onboarding UX。
>
> Service Binding 自身能力见 `service-binding-capabilities-guide.md`。Connectors 11 问题域机制见同目录 vault-eval 的 `inputs/01-connectors-domain-map.md` 与 `../what-is-connectors.md`。
>
> **覆盖范围**：Service Binding spec 1.1.0 + 参考实现 `servicebinding/runtime`（均 Apache-2.0 社区开源）。
> **不覆盖**：被绑定的后端服务自身；厂商私有发行版增强；已弃用的 Red Hat SBO 的私有超集行为细节。

---

## 1. Connectors 的问题域

| 问题域 | Connectors 的解法 | 体验 |
|---|---|---|
| **CI Secretless** | Proxy 持真凭据 + CSI Driver 用短时 SA token 挂**渲染好的工具配置文件**（`.gitconfig`/maven `settings.xml`/docker config）；出栈方向注入真 Basic/Bearer/OCI token | 业务进程当普通配置读，零 SDK，真凭据不进进程 |
| **K8S 镜像无凭据拉取** | OCI/Harbor reverse proxy + `PodWebhook` 改写 Pod image 到代理地址；kubelet 走 reverse proxy 拉镜像 | Pod 加 annotation 即可，无 imagePullSecret |
| **工具透传 API** | `ConnectorClass.spec.api.openapi` 暴露工具 API 子集，Connectors API server 代用户 SA 调 Proxy | UI/SDK 直接调用 |
| **Pipeline UI 选资源** | `ResourceInterface` + Tekton frontend descriptor 调 Connectors API | Pipeline 编辑页下拉选 Git 分支 / Harbor tag |
| **审批门控** | `AccessPolicy` + `AccessRequest` + Tekton `ApprovalTask` 联动；拒绝则 CSI 挂 `.error.json` | Pipeline 内审批，Pod 自然失败 |
| **三级 scope 治理 + 委派** | cluster / project / namespace 三层；委派落 ACP IAM RoleBinding | 与 K8s RBAC 同源 |
| **项目级多租户** | 复用 ACP namespace-group / project 模型 | 项目天然隔离 |
| **凭据轮换 / 短期化 / 吊销** | 客户端只拿短时 SA token；吊销 = **撤 RBAC + per-request SubjectAccessReview** | 撤权即时生效，无需等 TTL |
| **审计** | K8s audit + AccessRequest + Proxy access log（可 data-plane deny/rate-limit） | 记"对工具的使用"，可在数据面拦截 |
| **air-gap 安装/升级** | OLM bundle + 一个 CR，复用 ACP operator 体系 | OperatorHub 装 + 编辑一个 CR |

**Connectors 边界（不解决什么）**：不是通用 secret store / KV；不是 KMS / PKI；不是凭据轮换器或动态凭据引擎；不做 secret 泄漏扫描。

---

## 2. 基于对比的观察

> 不做逐问题域 ✅/⚠️/❌ 评分网格——Service Binding 与 Connectors 是**不同层、不同机制**的东西，逐域打分会制造"谁更全"的错觉。下面是几条凝练观察。

**机制分水岭：投射（projection）vs 代理（proxy）。** Service Binding 把后端服务的 **Secret 明文摊成 Pod 内文件**（`$SERVICE_BINDING_ROOT/<name>/<key>`），app 读到真实的 host/username/password，**自己**发起到后端的连接——**凭据进 app 地址空间**。Connectors 走 data-plane proxy：app 拿到的是**代理地址 + 短时 SA token**，真凭据死守在 `connectors-system`，Proxy 在出栈方向注入，**真凭据永不进客户端**。这是结构性差异，不是功能多少之差。因此 Service Binding **结构上无法**提供"零客户端凭据""撤 RBAC 秒级吊销""per-request 授权/审计"——这些恰是 Connectors 的护城河。

**覆盖面：Service Binding 只触及 Connectors 11 域里的一条边，且机制相反。** Service Binding 对应的只有 "CI/workload 拿到连接信息" 这一面，且它给的是明文 Secret 投射而非 secretless proxy。Connectors 的其余域——镜像无凭据拉取（PodWebhook + reverse proxy）、工具透传 API、Pipeline UI 资源选择（ResourceInterface）、运行时审批门控（AccessPolicy/ApprovalTask）、三级 scope 治理、OLM 平台化装升——Service Binding **完全不涉及**。它不是"窄一点的 Connectors"，是"另一层的东西"。

**Service Binding 真正值得借鉴的是 UX/约定，不是机制。** 三样东西成熟且有 app 侧生态：(a) **绑定抽象**——`ServiceBinding` 把"把服务连接送进 workload"做成一等声明式 CR，与 workload 解耦；(b) **`$SERVICE_BINDING_ROOT/<name>/<key>` 投射目录约定** + **well-known key**（`type`/`provider`/`host`/`port`/`uri`/`username`/`password`/`certificates`/`private-key`）；(c) **现成 consumer 库**（Spring Cloud Bindings、Quarkus `quarkus-kubernetes-service-binding`）能直接读这套目录。Connectors 的 CSI 投射的是**渲染好的工具配置文件**（更贴 Tekton 工具语义），与 Service Binding 的"摊平 Secret"路线不同；但 Connectors 若想让普通（非 Tekton）K8s 工作负载更易消费，**Service Binding 的目录约定与 well-known key 是现成的兼容层参考**。

**为什么它不是数据面竞品（一句话）**：Service Binding 没有 Proxy、没有 Connectors API、没有 Pipeline 资源选择、没有运行时审批，且它把明文凭据交给 app——它解决的是"如何标准化地把 Secret 喂给 workload"，Connectors 解决的是"如何让 workload 在不持有凭据的前提下使用工具"。**同一个'让 workload 接上外部依赖'的诉求，两条相反的技术路线。**

**生态生死要分清（销售/SE 易踩）**：外部材料常说"Service Binding 已弃用"——那指的是 **Red Hat SBO 这一个实现**（2024-02 弃用、2024-06-26 归档）。**规范本身（spec 1.1.0）与官方参考实现 `servicebinding/runtime`（v1.0.0, 2024-07）仍活跃**。对外对比时不要错说成"这个标准死了"。

---

## 3. 集成方向与 Roadmap 启发

**思路方向，不写实施草案。**

**自然边界**

- Service Binding 不替代 Connectors：镜像无凭据拉取 / 工具透传 API / Pipeline UI 资源选择 / 运行时审批 / 三级 scope 治理 / data-plane secretless，Service Binding **结构上不覆盖**。
- Connectors 不"需要"集成 Service Binding 作为 backend：它不是凭据来源（不像 Vault/Infisical），它是"把 Secret 投进 Pod 的约定"——与 Connectors 的 CSI 投射处于**同一层、机制相反**（明文投射 vs secretless 配置渲染）。它对 Connectors 的价值是**兼容/UX 参考**，不是依赖项。

**核心思路**

> **Service Binding 是 Connectors CSI/onboarding 通道的"UX/兼容样本"，不是后端候选、也不是竞品。** 与 Vault/Infisical（可作 `SecretBackend` 后端）不同，与 Secretless Broker（机制孪生）也不同：Service Binding 是**形态邻接的社区标准**——它把"绑定 + 投射"做成了有 app 侧生态的约定，Connectors 可借鉴其约定来降低消费侧门槛。

### 集成 / 借鉴方向

**方向 1：CSI 投射可选兼容 `$SERVICE_BINDING_ROOT` 约定（🟡 待审视，兼容层）**

- 背景：Connectors CSI 当前投射的是渲染好的工具配置文件（`.gitconfig` 等），针对 Tekton 工具语义。Service Binding 定义了一套跨语言、有 Spring Cloud Bindings / Quarkus 等 consumer 库支持的 `$SERVICE_BINDING_ROOT/<name>/<key>` + well-known key 约定。
- 借鉴点：对**非 Tekton 的普通 K8s 工作负载**，Connectors 可考虑提供一个**可选的 Service-Binding-兼容投射模式**（额外把连接信息按 well-known key 摊进 `$SERVICE_BINDING_ROOT`），让已用 Spring Cloud Bindings / Quarkus 的应用零改造接入。
- **关键张力**：Service Binding 投的是**明文 Secret**，与 Connectors "真凭据不进客户端"的护城河**直接冲突**。若要兼容，投进去的应是**代理地址 + 短时 token**（secretless 形态），而非真凭据——即"借用目录约定的壳，不借用明文投射的里"。这一点必须在设计时守住，否则会侵蚀核心价值。
- **定位**：借鉴**投射目录约定与 well-known key（UX/兼容）**，不是集成 Service Binding 本身、不引入其 reconciler。

**方向 2：`ServiceBinding`-style 声明式绑定 CR 作为 onboarding UX 参照（🟡 待审视）**

- Service Binding 用一个 `ServiceBinding` CR 把"服务 ↔ workload"解耦地声明出来，体验干净。Connectors 当前消费侧主路径是 CSI volume + annotation / webhook。
- 待审视：Connectors 是否需要一个更声明式的"把某 Connector 绑进某 workload"的 CR 形态（而非每个 workload 各配 volumeMount/annotation），以贴近用过 Service Binding 的用户心智。**结论待 PM 判断**——是否与 Connectors 现有 CSI/annotation 心智冲突需评估。

**方向 3：不集成（明确不做）**

- 不把 Service Binding reconciler 作为依赖或 backend：它与 Connectors CSI 同层、机制相反，引入它等于在 Pod 里塞明文凭据，违背核心定位。
- 不实现 Provisioned Service duck type 让 Connector 被 Service Binding 投射：那会把真凭据通过明文 Secret 暴露给任意 workload，绕过 Connectors 的 secretless 路径——绝不做。

### Roadmap 启发

**短期可考虑**
- **兼容约定的设计调研**：在 CSI/onboarding UX 评审里，把 Service Binding 的 `$SERVICE_BINDING_ROOT` 目录约定 + well-known key 作为"非 Tekton 工作负载消费侧"的兼容参照样本记录在案。

**中长期考虑 / 待审视**
- **对外话术：形态邻接、机制相反、非竞品**。客户若问"你们和 Kubernetes Service Binding 啥区别"——核心回答：Service Binding 是 K8s 社区把"把服务 Secret 投进 workload"标准化（**明文投射，app 持凭据**）；Connectors 是"让 workload 不持凭据就能用工具"的数据面代理（**secretless proxy + 撤 RBAC 吊销 + 镜像/审批/UI/治理**）。**不贬低**：Service Binding 在它的范围内是干净的社区标准，且 Connectors 可借鉴其投射约定降低消费门槛。

**🟡 待审视的开放问题**
- **兼容 vs 护城河的边界**：若做 Service-Binding-兼容投射，务必只投"代理地址 + 短时 token"而非明文凭据，否则侵蚀"真凭据不进客户端"。这条红线要在 `SecretBackend`/CSI 设计评审里显式回答。
- **声明式绑定 CR 是否值得**：引入 `ServiceBinding`-style CR 会不会与现有 CSI annotation 心智重复/冲突，需 PM/UX 判断。

**明确不做**
- 不集成 Service Binding reconciler 作为后端/依赖（同层、机制相反，无收益）。
- 不让 Connector 实现 Provisioned Service duck type 被外部 reconciler 明文投射（违背 secretless 核心）。

### 借鉴 / 启发候选（🟡 候选）

> 仅记录，不下结论；等 `/connectors-arch-review`（原则）或 `/connectors-learn`（教训/话术）触发再决定是否沉淀。

- **"形态邻接 + 机制相反" 是又一类竞品判读**：Service Binding 与 Connectors 形态相邻（都"把外部依赖接进 workload"）但机制相反（明文投射 vs secretless 代理）。竞品分析里应区分"形态像""机制像""能替代"三件事——形态像不等于能替代。
- **投射目录约定（`$SERVICE_BINDING_ROOT` + well-known key）是个可复用的兼容资产**：有现成 app 侧库（Spring Cloud Bindings / Quarkus）。Connectors 想扩大非 Tekton 工作负载覆盖面时值得参考——但只借约定的壳，不借明文投射的里。
- **审批门控位置矩阵再补一列**：Vault Control Groups（取凭据时）/ Infisical change·access request（写 secret·取权限时）/ Secretless（无门控点）/ **Service Binding（无门控点，纯投射）** / Connectors ApprovalTask（运行时按 proxy 调用）。Service Binding 的"无门控、纯投射"再次凸显 Connectors 把治理织进数据面的价值。

---

## §末 哲学差异（1 段散文）

> **Service Binding 的哲学**是"标准化地把后端服务的连接 Secret **摊进** workload 容器，app 像读本地文件一样拿到 host/username/password 自己去连"。**Connectors 的哲学**是"workload **永不持有**真凭据，Proxy 在数据平面做认证注入，app 拿到的是代理地址 + 短时身份"。两者不是替代关系，是**对'让 workload 接上外部依赖'这同一诉求的两条相反路线**——投射把凭据交给 app，代理把凭据锁在数据面。Service Binding 把"绑定 + 投射"的 UX 约定做成了社区标准，这是 Connectors 在消费侧 UX/兼容层值得借鉴的地方；但它无法、也不试图提供 secretless、吊销、镜像、治理、审批这些 Connectors 的核心面。

---

**相关文档**

- `service-binding-capabilities-guide.md` — Service Binding 标准自身能力（能力地图 + 分章 + 每章 demo + 规范/实现/SBO 弃用辨析）
- `../what-is-connectors.md` — Connectors 同心环竞品分级（Service Binding 落在第 ② 环"形态孪生"，已有 "Service Binding 的位置" 注）
- 同目录 vault-eval：`../connectors-vs-vault.md`、`../infisical/connectors-vs-infisical.md`（Vault/Infisical 是**后端候选**）、`../secretless-broker/connectors-vs-secretless-broker.md`（Secretless 是**机制孪生**）—— 三者定位与 Service Binding（**形态邻接的社区标准/兼容参考**）各不相同，对比时注意区分
