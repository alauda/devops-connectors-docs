# 技术架构 Review — DEVOPS-44108

> Reviewer 视角：高级技术架构师（K8s / Vault / Tekton / secret management 方向）。本 review 只评技术准确性与论证严密性，不评商业 / 客户 / ROI。

---

## 总评

**一句话**：核心结论（Vault 不能替代 Connectors）方向正确、与代码事实一致；但报告把"论证"和"实证"的边界处理得偏松，license 数字、Enterprise 边界、PoC 因果链与"工程量估算"四处存在可被对手在评审会上当场扯开的论据漏洞，建议在公开发布前做 P0/P1 修订。

**技术可信度评分：3.5 / 5**
（结构与代码层论断扎实 → 加分；license 数字无源、PoC 因果链表述夸大、§8 工程量估算缺颗粒度 → 扣分）

---

## 准确的技术论断（≤5 条）

1. **CSI token TTL 默认 30m**（§5 矩阵第 1 行、`inputs/01` §1、§7）—— 与 connectors 源码一致：`pkg/csidriver/types.go:187` 显式设 `attri.TokenExpiration = 30 * time.Minute`，并有 `types_test.go:73-78` 单测保护"default expiration (30m)"。可以放心写"30m"。
2. **OCI/Harbor PodWebhook `verbs=create` only**（§5 第 2 行、§7.2、`inputs/01` §2）—— 代码层面与 `connectors-extensions/connectors-oci/pkg/apis/v1alpha1/pod_webhook.go:43` 的 `// +kubebuilder:webhook:...verbs=create,...` 完全对齐；OCI/Harbor 共享 `PodWebhook` 类型也与 `connectors-oci/cmd/oci/main.go:80` + `connectors-harbor/cmd/harbor/main.go:84` 对得上。
3. **Vault kubelet 镜像拉取结构性 gap**（§5 第 2 行、§7.2 第 1 项、PoC-2、`inputs/02` §2）—— 论据扎实：kubelet 拉镜像协议层只承认 Pod spec / SA / 节点级 credential provider 三种来源，VSO/ESO/Agent Injector 均不改 `spec.containers[*].image`，因此 Vault 路线必须自建 OCI distribution proxy + Pod admission webhook。这是 review 中最强的一条论据，全篇可立住。
4. **Vault Control Groups 无内建 approver UI**（§5 第 5 行、§6.3、`inputs/02` §5、PoC-3 §1）—— 与 HashiCorp 官方文档一致：approver 走 `/sys/control-group/authorize`，没有 GUI 流程，approver 必须有自己的 Vault token。这条对"审批门控不能给 ACP 一体化 UX"是结构性论据。
5. **Connectors 三级 scope 与三类 RBAC 区分**（§5 第 3-4 行、`inputs/01` §3-§4）—— `kube-public` cluster scope / `cpaas.io/inner-namespace` namespace-group / 普通 ns 三级，以及"资源 vs 能力"两套权限（`connectors/proxy` / `connectors/apis` subresource）与文档/代码一致。

---

## 不准确 / 需修正的技术论断

### P0（必改才能公开发布）

#### P0-1. Vault Enterprise license "$50k-$200k+/集群/年" 无出处，且数量级不准

- **位置**：§1 关键论据 (2)、§2.2 表"Vault Enterprise license"行、§2.4 商业冲击、§7.3、`inputs/02` §13。多处反复出现。
- **原文**：『每集群 $50k-$200k+/年；多集群、HSM auto-unseal、global namespace 显著上浮』。
- **问题**：
  1. 报告全篇未给该数字任何出处链接（HashiCorp 不公开 list price，公开渠道只有 Gartner / Forrester 的 inferred range，AWS Marketplace / IBM 收购公告均无明文）。"公开口径"四个字在 `inputs/02` §13 出现一次，但无引用。
  2. HashiCorp Vault Enterprise 实际计费是按 **client-based licensing**（active clients），不是按 "cluster" 也不是按 "node"。报告 §1/§2.2/§7.3 都写"每集群 $50k-$200k+/年"，把计费单位描述错了。
  3. IBM 完成对 HashiCorp 的收购是 2025-02（参考 IBM 官方公告），到 2026-05 已 15 个月，"路线图不确定性"叙述仍可保留，但应给具体观察事实（如 IBM 公告、产品发布节奏）而不是泛泛口号。
- **修订建议**：
  - 把价格表述改成"按 active client 计费，单客户 TCO 量级数十万到数百万美元/年，具体取决于集群规模、租户数、HSM/replication 等加件；公开 list price 不可得，量级以 HashiCorp 客户案例与第三方分析（如 Gartner）为参考"。
  - 把"每集群 $50k-$200k+/年"替换为"客户侧 TCO 显著（数量级 $100k-$1M+/年）"，并加一句"准确价格以 IBM / HashiCorp 商务报价为准"。
  - §10.2 决策动作里有"客户额外承担 license"的论断不变，但论据强度从"具体数字"退到"商业边界"——商业 agent 自然会接住。

#### P0-2. "改造范围 5.5-9 人年"——拆解颗粒度不足，且对 Vault 生态可复用部分严重低估

- **位置**：§8.1 表、§1 决策树（"工程量 ≈ 重写 Connectors"）、§10.4。
- **原文**：HTTP/Git/OCI/Maven proxy = 2-3 人年；OCI reverse proxy + PodWebhook = 1-2 人年；UI 后端 = 1-2 人年；审批桥 = 0.5-1 人年；Vault operator = 0.5 人年；多租户对齐 = 0.5 人年；**累计 5.5-9 人年**。
- **问题**：
  1. 表内没给单个组件的"假设规模"（多少 connector type、多少 ResourceInterface、单工具下 OpenAPI schema 行数等），无法被 review 者重算。
  2. 部分组件**已有上游可复用**：
     - **OCI reverse proxy** 可以基于 `distribution/distribution`（CNCF Sandbox）或 `goharbor/harbor` 的 proxy-cache 模式起；不是从零写；
     - **PodWebhook 改 image** 可以用 **Kyverno** `mutate` 规则覆盖大部分场景，自研代码量大幅减少；
     - **Vault HA + operator** 直接用 hashicorp/vault-helm chart + banzaicloud/bank-vaults operator（社区成熟）；
     - **审批桥**可基于 Tekton `CustomRun` + 现成 `manual-approval-gate`（PoC-3 自己就用了）；
   - 这些可复用部分至少能把估算的 30-50% 切掉。
  3. "1-2 人年"区间宽度本身意味着 ±50% 误差，但表里几乎每一行都是 1.5-2x 区间——叠加后实际不确定性 > 报告给的 5.5-9 人年。应给"中性 / 悲观 / 乐观"三档。
- **修订建议**：
  - 表里每行加"假设规模 + 上游可复用项 + 自研增量"三列。
  - 把累计改成"中性 4-6 人年，悲观 6-9 人年；其中 1-2 人年是 Vault 生态无可复用部分（审批桥的 ACP IAM 联动、ResourceInterface 跨工具抽象、PodWebhook 与 SA token 校验绑定）——这部分才是"重写 Connectors"的真实下限"。
  - §1 决策树里"工程量 ≈ 重写 Connectors"改成"工程量 ≈ 重写 Connectors 中 ACP 平台耦合的那一半"，更准确也更难被反驳。

#### P0-3. PoC-2 因果链"kubelet 不消费 ns 内 dockercfg"表述夸张，没有对 SA-bound 路径做实验

- **位置**：§6.2、PoC-2 `REPORT.md` §3 表与结论、`gap-analysis.md` §3 Gap 1。
- **原文**："kubelet **完全没有**自动使用同 ns 的 vault-synced-dockercfg" / "K8s 只承认 Pod spec / SA / 节点级 credential provider 三种凭据来源"。
- **问题**：
  1. **PoC-2 实际上只跑了"Pod spec 不引用"一条路径**（场景 1）—— 真实的反驳路径"VSO + 把同步出的 Secret 挂到 SA 的 `imagePullSecrets[]`"没有跑。Vault 倡导者会立刻指出："VSO 的标准实践是同步 + Mutating webhook 把 SA 改写为引用该 Secret"，PoC-2 没证伪这条。
  2. 因此 "kubelet 完全不消费" 这个表述在 PoC 证据范围上越界——更准确的表述是 "kubelet 不会扫描 ns 内 dockercfg 并自动选用"。
  3. `gap-analysis.md` §3 Gap 1 自己脚注里也承认了"把 SA 的 imagePullSecrets 改写也算一种曲线救国"，但主表与主结论却把这条选择性删掉了。
- **修订建议**：
  - PoC-2 §3 表中"业务 Pod 是否要写 imagePullSecrets"加脚注："或将其挂到 Pod 的 ServiceAccount.imagePullSecrets[]，但这会污染 ns 内所有 Pod；本 PoC 未覆盖该路径实测"。
  - 主结论改为："kubelet 不会自动扫描 ns 内 dockercfg；要让 Vault 同步的 dockercfg 生效，必须显式落到 Pod spec 或 SA spec —— 两条路径都不能做到 Connectors 的'按 Pod annotation 精准命中'语义"。
  - 这样把结论从"Vault 结构性不覆盖"软化为"Vault 路径不能覆盖 Connectors 的核心 DX 承诺"——同样足够支撑总结论，但 PoC 因果链不被攻破。

### P1（公开发布前应改）

#### P1-1. PoC-1 实际证明的是"我们故意暴露它"，而非"Vault 必然暴露"

- **位置**：§6.1、PoC-1 `REPORT.md` §4 威胁模型。
- **原文**："Vault 路径下凭据可在 4 条路径暴露" / "覆盖矩阵第 1 项的'否定'判定升级为可观测事实"。
- **问题**：4 条路径（cat 文件 / env / 拼 URL / `set -x`）都是 PoC step 2 故意写的代码——这证明的是"如果 client 不防护，凭据会暴露"，而非"Vault 模型必然暴露"。Vault 倡导者会反驳：客户端可以用 `vault read -field=token | use-without-logging` 等防护手法，PoC 没有证伪这一点。
  - 真正成立的论断（PoC-1 §4 后半段已经写到，但没在 §6.1 凸显）是：**凭据一旦进入 client 进程地址空间，Vault 没有任何机制约束 client 后续行为**——这是结构论据，不需要靠 4 条暴露路径来证。
- **修订建议**：
  - §6.1 结论段改成："PoC-1 演示的不是 Vault 必然泄漏，而是 **凭据进入 client 地址空间后约束权移交给 client 应用层**——是否泄漏取决于 client 实现质量。Connectors 的 secretless 路径在 client 地址空间内根本没有凭据，约束权始终在 connectors-system。"
  - 把"4 条暴露路径"从主论据降级为"演示用例"，避免被对手反驳"那是你 client 写得烂"。

#### P1-2. PoC-3 OSS 近似 vs Enterprise 的 fairness 未标注

- **位置**：§6.3、PoC-3 `REPORT.md` §3、§5。
- **原文**："Vault Enterprise（未真跑，仅 spec 调研）" / 结论"Enterprise 也只解一半"。
- **问题**：
  1. Enterprise Control Groups 是关键论据，但承认了"未真跑"。这是合理的（license 限制），但报告只在 PoC-3 §1 一句话提到，**§6 / §10 都引用"Enterprise 也只解一半"这个结论时没复述这个限制**。
  2. "OSS 近似工程量 ≈ 重写 Connectors `AccessPolicy`/`AccessRequest`/`ApprovalTask` 三件套"—— OSS 近似 PoC 实际只跑了 ConfigMap + 复用现成 `manual-approval-gate`，没自建那三件套。从 PoC 跑通的 manifest 推出"工程量 ≈ 重写三件套"是大跳跃。
- **修订建议**：
  - §6.3 与 §10 引用"Enterprise 也只解一半"时都加脚注："基于 HashiCorp 官方文档与 API spec 推断；未做 Enterprise license 实测"。
  - "OSS 近似工程量"改为"如果要在 OSS 上达到生产可用（per-team RBAC、IAM 解析、审批 UI、通知），仍需补 controller / API / UI 组件，等价工程量量级与 Connectors `AccessPolicy`/`AccessRequest`/`ApprovalTask` 三件套相当——这是基于组件清单类比的估算，未走完整实现验证"。

#### P1-3. Vault Enterprise 边界描述不全 / 部分描述不准

- **位置**：§5 矩阵第 3-5 行、§2.2、§7.3、`inputs/02` §3 / §13。
- **原文**：『Namespaces / Control Groups / Sentinel 是 Enterprise』。
- **问题**：
  1. **Sentinel 准确**（Enterprise only）。
  2. **Namespaces 准确**（Enterprise only，Vault Enterprise 1.x 以来一贯如此）。
  3. **HSM auto-unseal 准确**（Enterprise only）。
  4. **Performance Standby**（Enterprise only）—— 报告未提，但与"Vault 高可用性能"相关，应至少提一句"OSS Raft 也能 HA 但只能 leader 读写"。
  5. **Audit Devices 全 OSS** —— `inputs/02` §8 已正确写出。
  6. **Kubernetes Auth Method、KV v2、PKI、SSH、Database engine、AppRole** 全 OSS —— `inputs/02` 各节正确。
  7. **第三方社区 plugin（如 GitLab Secrets Engine、社区 GitHub PAT engine）** 报告在 `inputs/02` §7 提了一句"社区维护"，但 §1 高管摘要、§5 矩阵第 7 行没提"如果使用社区 plugin 能补哪些 dynamic 能力"。Vault 倡导者会拿这条反驳。
- **修订建议**：
  - 在 §5 矩阵第 7 行（dynamic secret）加："社区 plugin 可补 GitLab PAT、GitHub App token 等，但需客户承担 plugin 安全审计 + 升级跟进成本，air-gap 客户场景不可接受"。
  - §13 / §2.2 license 描述里把 "Enterprise only" 的具体清单更准确表达："Namespaces、Sentinel、Control Groups、HSM auto-unseal、Performance Replication、DR Replication、Performance Standby、MFA-on-namespace"。

#### P1-4. 历史考古"未找到正式 Vault 评估记录" + 5 条推断 —— 推断的成立度标注不够保守

- **位置**：§4.3、§4.4、`inputs/04` §3-§5。
- **原文**：5 条推断里 4 条标"推断成立度：高"，1 条"中"。结论："不是当年没想清楚"。
- **问题**：
  1. "未找到正式 Vault 评估记录"这一事实可能意味着两种情况：(a) 评估过但没文档化（口头/PPT），(b) 完全没评估。报告偏向 (a)，但**没有给出区分两者的证据链**。
  2. 推断 (1) air-gap 摩擦标"高"—— 这条其实是反向：air-gap Vault 已被多家金融客户在 ACP 之外用过（Vault on OpenShift、Vault on Rancher 都有 air-gap 部署案例），不能仅凭"摩擦大"就推断"立项时排除了"。建议降为"中"。
  3. 推断 (4) 凭据分发是 3.x 痛点 —— 这条最强（有 `diff-with-3.x.md` 直接证据），标"高"准确。
  4. 推断 (5) K8s-native + ACP IAM 复用标"中" 恰当。
  5. §4.4 结论"不是当年没想清楚"是合理的，但措辞可更严谨："立项决策与 3.x 反面教材一致；即便没有正式评估 Vault，方向选择仍然 defensible"——而不是"没想清楚"的二元判断。
- **修订建议**：
  - 推断 (1) 成立度由"高"改为"中"。
  - §4.4 增加一句："本节为基于代码与文档的事后重构，不排除当年存在未文档化的口头讨论。"
  - §1 关键论据 (3) "历史决策仍然成立"保留，但措辞改为"立项方向 defensible"，避免把"推断"包装成"事实"。

### P2（nice-to-have）

#### P2-1. Vault Agent Injector "改 env / 不改 image" 描述完整性

- **位置**：`gap-analysis.md` §3 Gap 2、§5 矩阵第 2 行。
- **问题**：报告说 "vault-agent-injector 只改 env 和注入 init/sidecar 容器，不改 image"。技术上准确，但漏了一条：Agent Injector 默认 mutate Pod 的 `spec.containers[*].volumeMounts` 与 `spec.volumes` 来挂 sidecar 的共享卷，"改 env" 措辞不全。
- **修订建议**：改成"Agent Injector mutate Pod 的 env / volumeMounts / volumes / initContainers / sidecarContainers，但不改 image"。

#### P2-2. CSI Driver 节点失效场景描述过简

- **位置**：§11.1 "CSI driver 高可用与节点失效场景"。
- **问题**：报告承认"CSI DaemonSet 节点故障时短暂影响 Pod 启动"。准确，但没具体说"已运行 Pod 不受影响（CSI 只在 mount 阶段介入）",这点其实有利于 Connectors。
- **修订建议**：补"已运行 Pod 不受影响，仅新 Pod 在该节点的启动延迟到 CSI driver 恢复"。

#### P2-3. SA token 30m TTL "可调"未给上下限

- **位置**：§5 矩阵第 1 行、`inputs/01` §1、§7。
- **问题**：报告说"默认 30m，可调"，没说"可调范围 = K8s `TokenRequest API` 允许的 10m - 系统配置上限"。
- **修订建议**：补"调节范围由 K8s `--service-account-max-token-expiration` flag 限定（默认 1y，cluster admin 可下调）；下限由 kube-apiserver 强制 ≥ 10m"。

---

## 论证薄弱 / 需补强的逻辑

1. **§1 决策树"判断点 1"过于宽**：『客户场景是否包含 CI secretless / kubelet 代拉镜像 / UI 工具选择器三项中任一』 → "Alauda 当前 100% 客户场景"。"100%" 无证据来源，§11.2 自己也列了"air-gap 客户实际是否能/愿用 Vault 需向 product/sales 验证"——"100%" 与 "需向 sales 验证" 是矛盾的。建议改"绝大多数（按已知客户访谈）"。
2. **§3.1 团队规模/commit 数据**：报告自己标"以财务/HR 口径为准"是 hedge，但表本身在 §2 / §3.2 被用来论证"切换不能节省团队"。论据强度不够，建议要么提供 git log + cloc 实际数据，要么删除具体数字保留定性描述。
3. **§7.3 与"开源标准 + 全栈自主"定位的张力**：这条是商业论据夹在结构性差异章里——技术 review 不评，但建议章节归位到 §2 / §3，§7 只保留 data-plane vs secret injection 与 ACP 耦合两项。
4. **§9.2 八项生产化工作**：技术内容准确，但与 §8 改造范围拆解不互相印证（八项里至少 5 项与 §8 表中"Vault operator / 多租户" 重叠）。建议在两处加交叉引用。

---

## PoC 证据强度评估

- **PoC-1（secretless 威胁模型）**：**weak（论证夸大）**。
  - 实测的是"client 写法有意暴露凭据"，不是"Vault 必然暴露"。结构性论据成立（凭据进 client 后约束权移交），但 4 条暴露路径不是 Vault 模型的必然产物。
  - 建议调整论述定位：从"否定升级为事实"改为"演示凭据进 client 后的攻击面"。

- **PoC-2（kubelet 镜像拉取）**：**medium-strong（结论方向对，PoC 实验未覆盖 SA-bound 路径）**。
  - 证明了"Pod spec 不引用 + ns 内有 dockercfg → ErrImagePull"，这点扎实。
  - 没有跑"SA `imagePullSecrets` 改写"的对照路径，gap-analysis 自己脚注承认了，但主结论选择性忽略。建议补"该路径下 ns 内 Pod 全污染，不能命中 Connectors 的 annotation 精准注入语义"——结论方向不变但因果链严密。

- **PoC-3（审批门控）**：**medium（OSS 跑通，Enterprise 未跑）**。
  - OSS 近似实测扎实，但"Enterprise 也只解一半"是文档推断不是实测。这一点 PoC-3 §1 诚实标注了 "未真跑"，但 §6.3 / §10 引用时该限制被忽略。
  - 工程量 "≈ 重写 Connectors 三件套" 是组件清单类比的推断，不是 PoC 实证范围。

---

## 报告内部一致性问题

| # | 矛盾位置 | 内容 |
|---|---------|-----|
| 1 | §1 决策树 "Alauda 当前 100% 客户场景" vs §11.2 "air-gap 客户实际是否能/愿用 Vault 需向 sales 验证" | 100% 与 需验证 矛盾。 |
| 2 | §5 矩阵第 7 行 "Vault 在 Connectors 实际工具上无官方 dynamic engine" vs `inputs/02` §7 "GitHub App 有官方 auth method 可发短期 installation token" + "GitLab 有社区 plugin" | 主报告矩阵把例外删掉了；应在矩阵第 7 行加脚注。 |
| 3 | §8.1 "审批桥 0.5-1 人年" vs §6.3 / §10 "等于重写 Connectors AccessPolicy/AccessRequest/ApprovalTask 三件套" | 0.5-1 人年与"重写三件套"工作量在量级上对不上；要么前者偏低，要么后者夸张。 |
| 4 | §1 关键论据 (2) "每集群 $50k-$200k+" vs §11.2 "未与典型客户做正式访谈，license 估算基于公开 license 数据" | 前者写得像 hard fact，后者承认是推断。 |
| 5 | §6.2 "kubelet 完全没有自动使用" vs `gap-analysis.md` §3 Gap 1 脚注 "把 SA 的 imagePullSecrets 改写也算一种曲线救国" | 主报告与 gap 文件的严谨度不一致。 |
| 6 | §10.1 "PoC-3 实测：Enterprise Control Group 才有但仍无 UI 一体" vs PoC-3 §1 "未真跑，仅 spec 调研" | 把 spec 调研写成"实测"。 |

---

## Vault 倡导者可能的反驳点 + 报告是否回应

| # | 反驳点 | 报告是否回应 | 评价 |
|---|------|------------|------|
| 1 | "凭据下发是 client 写法问题，不是 Vault 模型问题；用 Vault SSH cert / GitHub App 短期 token + 不落盘可做到接近 secretless" | §5 矩阵第 7 行 + `inputs/02` §1 提了 SSH cert 和 GitHub App，但仅一句话；主论据 §7.1 没回应"模型 vs 写法"的边界 | **回应弱**，需补"即便短期化，client 进程地址空间内已有明文，约束权移交"这个结构论据 |
| 2 | "VSO + Kyverno mutating webhook 改 SA imagePullSecrets，可达到 imagePullSecret-less" | §5 矩阵第 2 行未提；`gap-analysis.md` §3 Gap 1 脚注提了一次但说"会污染 ns 内所有 Pod" | **回应较弱**，反驳论据（"污染所有 Pod"）准确但没在主表呈现 |
| 3 | "可以用 Bank-Vaults operator + cert-manager + Vault Agent Injector，把 Vault 治理工程量打掉一半" | §8 / `inputs/03` 提了 ESO / Crossplane / cert-manager，但没把 Bank-Vaults / Vault Helm chart 的成熟度计入 | **未回应**，是 P0-2 工程量估算偏高的主要原因 |
| 4 | "ACP 集群多但客户已经买了 Vault Enterprise 给其他业务用，复用零边际成本" | §2.2 没提"客户已有 Vault Enterprise 的复用场景"；§10.2 第 4 项"明确 Vault 互操作姿态"间接覆盖（"如客户已有 Vault，ESO 同步 KV 为 K8s Secret"）但论述偏弱 | **回应中等**，可强化"互操作"作为正式答案 |
| 5 | "Vault Audit Devices + Splunk 已是行业标准，Connectors 的'依赖 ACP 日志平台聚合'反而是劣势" | §5 矩阵第 8 行承认"双方部分覆盖（互补）"，§11.1 也承认 "Connectors 无原生 audit dashboard"  | **回应得体**，但建议在 §10 / §2 增加 "Connectors audit 演进是 Connectors 的合理 roadmap 项"的承认 |
| 6 | "IBM 收购后 HashiCorp 路线图反而更稳定" | §1 / §2.4 一律负面解读"路线图不确定"，未给反方向证据 | **回应弱**，建议改为"路线图节奏待观察"中性表述 |
| 7 | "ConnectorClass + ResourceInterface 是 Alauda 自创抽象，客户也要学" | §2.3 "平台管理员: 本来 OperatorHub 一键装"忽略了学习成本 | **未回应**，需承认 Connectors 自身的学习曲线 |

---

## 是否技术上 ready 公开发布？

**结论：尚未 ready**。

技术结论方向正确（这是 review 的核心判定），但当前版本存在 3 个 P0 与 4 个 P1 问题，任何一个被 Vault 资深用户在评审会上当场指出都会损害报告整体的可信度。

**最小修订集**（推荐顺序）：
1. P0-1：删除/改写"每集群 $50k-$200k+"硬数字（约 30 分钟）。
2. P0-2：§8 改造范围表补"假设规模 + 上游可复用项 + 自研增量"列（约 2-3 小时）。
3. P0-3：PoC-2 + §6.2 主结论加 SA-bound 路径脚注（约 1 小时）。
4. P1-1：§6.1 + PoC-1 主结论从"4 条暴露事实"改为"结构性约束权移交"（约 1 小时）。
5. P1-2：§6.3 / §10 引用 Enterprise 处加"未实测，基于 spec"脚注（约 30 分钟）。
6. P1-3：§5 矩阵第 7 行加社区 plugin 脚注 + §13 Enterprise 清单补全（约 1 小时）。
7. P1-4：§4 推断成立度复评 + 措辞软化（约 1 小时）。

完成 P0 修订后即可达到"对外白皮书"可用强度；P1 完成后达"对外评审 / 客户访谈"强度。当前版本只适合 Connectors 团队内部 review。
