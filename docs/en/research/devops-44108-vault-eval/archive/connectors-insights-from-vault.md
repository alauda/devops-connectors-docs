# Connectors 从 Vault 调研中得到的启发（草稿）

> **状态**：草稿，持续追加。
> **定位**：Vault 调研的副产物，捕捉对 Connectors 自身设计 / 演进有启发的点。
> **不是**：替代决策报告（`REPORT.md`）或能力阐述（`vault-capabilities-guide.md`）。

---

## 1. 初步想法（用户原话留底）

### 已写下的几点

1. **Vault 提供了强大的动态凭据能力**。Connectors 的 secret 目前是固定的，可以结合 Vault，将 Connectors 的凭据对接到 Vault 上，由 Vault 来提供。凭据只存在 Connectors 的内存中，在集群中完全不落盘。

2. **Vault 提供的动态凭据能力，最大的好处是对客户端的侵入非常小**。或许可以直接将这个动态的短期凭据透传到配置中，这样几乎是无侵入的。

3. **凡是涉及到动态短期凭据的，都应该交给 Vault 来处理**。我们可以完成若干插件（比如 harbor / sonarqube）。Connectors 不应该再针对短期凭据制造轮子。

4. **跨集群、多租户能力 Vault 只在企业版提供——而 ACP 场景下这两个都是我们要解决的问题**。Vault Enterprise 用 Replication（Performance + DR）和 Namespaces 覆盖：
    - 跨集群：跨 region 读热点 + 容灾切换；可按 namespace 选择性复制（数据驻留合规）
    - 多租户：每个 namespace 是子 Vault，policy / engine / token / 审计完全隔离；支持 namespace-admin 委派

   含义：ACP / Connectors **不能假设客户都买 Vault Enterprise**——OSS 没有原生对等物。
   - 客户若用 Vault OSS，跨集群和多租户**仍是 Alauda 自己要解决**的问题域
   - 客户若用 Vault Enterprise，可参考它的 namespace + replication 模型，但**集成层（如何让 Connectors 跑在多 namespace 下、跨集群同步 Connector CR）仍是 Alauda 自研的**
   - 对 ACP 产品故事是个真实差异化点：ACP 把多集群（federation / cluster registry）+ 多租户（namespace / project / IAM）**默认就解决**了，与 Vault OSS 相比更"开箱即用"

5. **🟡 待讨论：Vault Control Groups 的审批能力和 Connectors 的审批能力看起来重合，这部分要怎么考虑？**
    - Vault CG：path 级 N-of-M 审批、wrap_token 取值 / accessor 审批信号双轨分离、policy + Identity group 校验、**仅 Enterprise**
    - Connectors 现有：`AccessPolicy` + `AccessRequest` + Tekton `ApprovalTask` 联动，pipeline 内审批；审批挂在"用 connector / 取 secret 的 proxy 行为"上
    - 重合面：都是"高风险操作 N 人审签"
    - 差异面（初判，待充实）：
        - CG 审批"取凭据这一刻"；Connectors 审批"用 proxy 的每次调用"——粒度和触发位置不同
        - CG 无内建 UI，集成方自建通知 / 审批界面；Connectors 直接走 ACP IAM + PipelineRun 同屏审批
        - CG 是 Vault 内能力，仅 Vault 资源涉及；Connectors 是 K8s CRD 一等公民，能挂任何 connector 类型
    - 待回答的问题：
        - Connectors 是否继续自建审批层，还是在 Enterprise 客户场景下"借用" Vault CG？
        - 审批能力对外是否成为 Alauda Connectors 的差异化卖点（OSS Vault 没有此能力）？
        - 两者是否有"共生 / 协同"的设计模式（如 Connectors 审批层底下接 Vault CG 做 Enterprise 客户额外保险）？
    - **结论：待审视思考后再下定论**

6. **Connectors 审批 + Vault/OpenBao 审批的协同模式（区别于 5：5 谈"是否重合该取舍"，6 谈"两者如何叠加增益"）**
    - **思路**：在 Enterprise 客户场景下，可设计**双层串联**：
        - **第一层**（Connectors AccessPolicy / AccessRequest / ApprovalTask）：挂在"用 Connector 这一刻"，由 ACP IAM 出审批 UI，pipeline 内同屏审签 —— 治"使用意图"
        - **第二层**（Vault Control Group / OpenBao CG 等价物）：挂在"Connector 后端从 Vault 取真凭据这一刻"，由 Vault policy + Identity group 二次卡 —— 治"凭据出库"
    - **价值**：
        - 客户**已有 Vault 投资 + 已有合规审计要求**时，第二层 CG 提供"凭据出库的独立审计轨"，与 Connectors 的"使用审计轨"互不污染，满足"四眼原则" / SOX / 等保 N 级
        - 第一层用户感知好（IAM + Pipeline UI），第二层底层兜底（policy-as-code，不依赖前端被绕过）
        - 两层**故障域独立**：Connectors 审批挂了不影响 Vault 出库；Vault CG 挂了 Connectors 还是会卡在前端 —— 纵深防御
    - **未决问题**：
        - 谁来 hold "正在审批中" 的 AccessRequest 状态？两层各自一份，要不要 reconcile？
        - 审批超时语义对齐：Connectors 侧 7d 默认，Vault CG max-ttl 怎么协商？
        - 两层都 reject 时，错误信息如何串起来给用户（避免"前端通过了，凭据还是没拿到，不知道哪一层卡了"）？
    - **触发探索的最小场景**：Harbor connector + 一个 production registry path + Vault CG 卡 image push secret 出库
    - **🟡 状态**：待 Connectors 审批领域的 owner 评估可行性

7. **K8s Image Pull Secret 用 Vault 提供 Harbor 短周期凭据的可能性**
    - **现状**：K8s 拉镜像走 `imagePullSecrets` 引用 `dockerconfigjson` 类型 Secret，凭据**长期落盘**在 K8s etcd 里；轮转纯手工。Connectors OCI/Harbor 的 reverse proxy + PodWebhook 拓扑当前主要解决"proxy URL 重写"，**凭据本身仍是静态**。
    - **思路**：让 Vault Harbor secrets engine（或 Harbor robot account API + Connectors 包一层）按需签发**短周期 robot account**，由 Connectors controller 在 reconcile 时 fetch 进 `connectors-system` 内存 → 渲染成 `dockerconfigjson` → 短 TTL Secret 注入到 workload namespace。lease 到期前 controller 主动 rotate Secret + 触发 Pod 滚动（或借助 reloader / 重启策略）。
    - **价值**：
        - **etcd 不再持久化长效 Harbor 凭据** —— 满足"凭据离机不超过 X 小时"的合规要求
        - 凭据泄露的爆破窗口从"无限" → "TTL"
        - 与 Vault DB credentials / AWS IAM 的 lease 模型对齐，运维心智一致
        - 客户已有 Vault 投资时直接复用，不必再买另一个轮转工具
    - **未决问题**：
        - **kubelet 拉镜像与 Secret rotate 的竞态**：rotate 那一刻新启动 Pod 可能拿到旧 dockerconfigjson —— 是 dual-Secret 滚动还是 lease 重叠期？
        - **TTL 下限**：Harbor robot account 创建/删除 API 的 rate limit、Vault lease minimum、kubelet image pull retry 三者的最佳交集
        - **Vault Harbor secrets engine 是否原生存在**：community plugin 的成熟度 / OpenBao 是否同步 / air-gap 客户能否跑 —— 需在能力指南 §2.4 plugin 矩阵里专门核对
        - **PodWebhook 的角色**：是 PodWebhook 注入 imagePullSecrets 引用 + Connectors controller 管 Secret rotate？还是让 CSI Driver 直接挂载（CSI mode 下没 imagePullSecret 语义，要走 kubelet credential provider plugin 路径）？
        - **降级**：Vault 不可用时是 fail-closed（Pod 拉不到镜像）还是 fail-open（用上一份缓存的）？
    - **可借鉴的现有上游**：External Secrets Operator + Harbor secrets-backend、cert-manager 的 cert rotation + Secret reload 模式
    - **🟡 状态**：值得开 PRD 单独评估；与"动态凭据"主线（点 1-3）共生但**触发位置和 actor 不同**（前者是 CI job 取凭据，这条是 kubelet 拉镜像）

### 待展开的几个维度

- **A. Connectors 和 Vault 的能力如何结合，双方的边界**
- **B. Vault 和 Connectors 的能力定位差异**
- **C. Vault 特有的几个亮点，值得我们反思的**

---

## 2. 维度展开（待充实）

### A. Connectors 和 Vault 的能力如何结合，双方的边界

*待写：*
- 哪些场景 Connectors + Vault 组合最有价值（CI/CD 取临时 GitLab/Harbor/Sonar 凭据）
- 哪些场景仍由 Connectors 单独承担（secretless proxy 拓扑、ResourceInterface 兼容、PodWebhook 改写）
- 接口契约：Connectors 是 Vault 的"消费者 + 适配层"还是"Vault 集成代理"
- 部署形态：Connectors 默认 secret store + Vault optional adapter，还是 Vault 一等公民

### B. Vault 和 Connectors 的能力定位差异

*待写：*
- "短寿命凭据集中签发" vs "secretless proxy" 哲学
- 业务侧持有什么 vs 业务侧零持有
- 治理模型：policy + role vs ResourceInterface + AccessPolicy
- 审计边界：每次 API 调用 vs 每次 proxy 转发

### C. Vault 特有的几个亮点，值得我们反思的

*待写：*
- **统一 plugin 模型**：扩展面统一为 secrets / auth / audit 三类；Connectors 的 connector 类型是否值得也做类似抽象
- **path-as-API + role + policy 三层解耦**：发放模板（role）和准入规则（policy）分离；Connectors 当前是否过度耦合
- **lease 作为运行时记账**：Vault 凭据有"账"；Connectors 当前缺乏这种全局可追溯
- **Transit 加密即服务**：业务永不持 key 的模式；Connectors 是否可以在 secret 持久化前对接 Vault Transit
- **K8s Auth Method 的身份桥接**：identity 委托 K8s + 授权保留 Vault 的解耦；Connectors 当前如何让 Pod 拿到 Connector 访问权
- **Injector / VSO / CSI 三路径 Pod 集成**：业务 0 改动 + 三种形态可选；Connectors 当前是否可以借鉴 sidecar/operator/CSI 中的一种或多种
- **凭据轮换（static-roles）**：长期账号 + 周期换密码模式；Connectors 是否有类似需求

---

## 3. 待补充的角度（建议持续追加）

- 与 ESO（External Secrets Operator）、cert-manager、SPIRE 等同问题域工具的对照
- 客户场景里"已有 Vault 投资"如何最大化复用
- air-gap / 不能上云 KMS 的场景下，Vault 作为 KMS 等价物的价值
- Sales / SE 视角：什么时候推 "Connectors + Vault" 组合方案、什么时候推 Connectors 单卖

---

## 4. 与现有文档的关系

- `REPORT.md` §5 覆盖矩阵和 §7 结构差异已经描述了"Vault 替代不了 Connectors"
- 本文档相反：**Vault 能补强 Connectors 哪些地方**——是从竞品分析转向**借鉴 + 协同** 的视角
- 后续可能孵化出：一篇集成方案文档、一篇 sales narrative、若干 PRD 草案