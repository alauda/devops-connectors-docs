# 主报告 P0 收敛修订记录 — 2026-05-22

> 输入：4 份独立 review（ceo / tech / customer-value / competitive-fairness）
> 修订对象：`research/devops-44108-vault-eval/REPORT.md` + `poc/poc-1/REPORT.md` + `poc/poc-2/REPORT.md` + `inputs/02-vault-capability-map.md`
> 修订原则：不反转核心结论（"Vault 不构成 Connectors 完整替代"）；只在语言、数字、PoC 边界上修订；不新增 5+ 页内容。

---

## F1 — TCO 数字全部无出处（4 角色高度收敛）

**问题**：CEO P0 #1 + tech P0-1 + customer-value P0 + competitive-fairness S5 共同指出：
- "$50k-$200k+/集群/年" license 计费单位错（实际按 active client / cluster / SKU 分层计费）；
- "TCO 净增 30%-300%"、"销售周期延长 3-6 个月"、"ACP 定价下调 5-10%" 全部无出处；
- "5-10% 定价下调" 是自报价值上限，对外极危险。

**修订（已完成）**：
- §1 高管摘要论据 2：把 license 描述改为 "按 active client / cluster / SKU 分层计费，需走 HashiCorp/IBM 商务流程获取正式 quote"，删除具体数字。
- §2.2 license 行：改为 "独立年付 SKU，结构上与 ACP 平台 entitlement 解耦"，标 `[需 sales/finance 复核]`。
- §2.4 商业冲击三段：把 "TCO 净增 30%-300%" 改为定性陈述 + "不依赖单价精确值，依赖结构差异"；删除 "ACP 定价下调 5-10%"；"3-6 个月销售周期" 改为定性 + `[需 sales 数据]`。
- §7.3 商业模型差异表：license 行同步修改；"IBM 收购" 改中性表述（"作为依赖第三方，纳入 6-12 个月观察"）。
- §8.4 与"维持现状"对比表：license 改为 "独立 SKU"，删除单价。
- §9.1：客户独立采购物料改为 "Vault Enterprise license（独立 SKU）"。

---

## F2 — PoC-1 strawman 风险（competitive-fairness S3 + tech P1-1 + CEO 关联）

**问题**：PoC-1 让 Vault 做 4 件 Vault 文档明确反对的事（PAT 落文件 + 注 env + echo URL + `set -x`）。Vault 社区会反驳应该用 Agent proxy mode / response wrapping / GitHub App。

**修订（已完成）**：
- §6.1 主报告：新增 "PoC-1 边界声明" 段落，明确演示的是 file-based injection 模式（常见 reference 模式之一），不是最严格模式；承认高级模式可"缩小部分暴露面"但 client 仍"某种形式持有过"凭据。
- §6.1 结论：从 "Vault 必然暴露 4 条通道" 改为 "约束权从凭据系统移交给 client 应用层"；明确下一轮需补 PoC-1b（Vault Agent proxy mode 对照组）。
- §7.1 表格：泄漏面 / client 改造 / 吊销方式三行加 Vault 高级模式说明；吊销方式承认 dynamic secret 的 lease revoke 是毫秒级 active 调用（tech P1-1 反向纠错）。
- §7.1.1 新增 "Connectors data-plane proxy 模式的反向 attack surface"：诚实承认 proxy 进程被攻破时凭据集中失陷。
- `poc/poc-1/REPORT.md` §0：新增 "PoC-1 边界声明"；§4 / §5 全面软化绝对化语言。

避免了绝对化语言 "必然" / "任意"。

---

## F3 — PoC-2 因果链表述夸大（tech P0-3 + competitive-fairness 问题域 2）

**问题**："kubelet 完全不消费 ns 内 dockercfg" 未跑 SA-bound `imagePullSecrets` 路径，gap-analysis 自己脚注承认但主结论忽略；Kyverno + ESO + Vault 组合路径被故意裁掉。

**修订（已完成）**：
- §6.2 主报告：主结论从 "kubelet 完全不消费" 改为 "kubelet 不会基于 ns 内任意存在的 dockerconfigjson Secret 自动选择凭据；必须经过 Pod spec 或 SA 的 imagePullSecrets 显式引用 — 这一引用动作是 Vault 路线下每个业务 ns 都需做的额外工程"；明确承认 SA-bound 路径但说明仍是显式引用、污染 ns 内所有 Pod。
- §6.2 承认 "Vault 生态可组合可达"（Kyverno + ESO + Vault + 自建 OCI reverse proxy ≈ 1-2 月集成）；明确 "Vault 单品不覆盖" 准确而 "Vault 结构性不可达" 不准确。
- `poc/poc-2/REPORT.md` §0：新增 "PoC-2 边界声明"，承认 SA-bound 路径未实测、Kyverno + Vault 组合可达；§2.B / §3 表 / §4 / §5 全面软化。

---

## F4 — §8 改造范围 5.5-9 人年颗粒度不足（tech P0-2 + competitive-fairness "改造范围潜在高估"）

**问题**：表内无 "假设规模 + 上游可复用项"；低估 Bank-Vaults / Kyverno / distribution upstream / Tekton CustomRun 等可复用部分。

**修订（已完成）**：
- §8.1 表格：每行新增 "可复用上游 / 社区组件" 列，明确列出 Boundary / Kyverno / distribution/distribution / Harbor proxy-cache / Tekton CustomRun / banzaicloud-bank-vaults / hashicorp-vault-helm / vault-secrets-operator 等。
- 工程量改为 "乐观-中性-悲观" 三档：乐观 3 人年（最大化复用），中性 5-6 人年，悲观 9 人年。
- 总结改为 "**3-9 人年（视社区组件复用度浮动）**"，承认即便取下限仍 ≈ 重写主体功能 + 6 组件供应链；引用 Vault 倡导者口径 2-4 人年作为更激进下限参考。
- §8.4 与维持现状对比表：从 "5.5-9 人年" 改为 "3-9 人年"；最后结论从 "改造路线无任何理性场景下应启动" 改为 "在 Alauda 当前主流客户场景下 ROI 不正；少数场景需单独评估"。

---

## F5 — §10 roadmap 6 条动作不够具体（CEO P0 #2 + customer-value P2 + ceo "可执行性评估"）

**问题**：4 条动作 "假具体"（动词正确但缺 owner / deadline / 可衡量结果）。

**修订（已完成）**：
- §10.2 表格：新增 `Owner（建议）` 和 `衡量指标` 两列；对实在无 owner 的动作明确标 `[需产品/PMO 后续指定]`。
- 加新动作 5 "销售一线 battle card（新）" — 满足 CEO "30 天调研收益沉淀的最低要求"。
- 加新动作 7 "明确 Vault adapter 产品姿态"，扩展互操作姿态为 3 种模式（呼应 competitive-fairness "互操作姿态是否充分"）。
- 表后加 "说明" 段："本表给出建议性 owner，实际指派需 PM 主持的对齐会议确认"——不假装具体。
- §10.3 从 "不接受'建议进一步评估'" 改为 4 条具体触发条件（场景 A/B/C/D，含 Boundary 协议扩展）。
- §10.4 反事实分析末句改为 "在客户付费意愿、团队产能、战略定位、竞品防御四个维度同时倒退"（CEO P2 #10）。

---

## F6 — §4.3 历史考古叙事顺序问题 + 事实错误（CEO P0 #3 + competitive-fairness "攻击点 #3"）

**问题**：
- "未找到正式 Vault 评估记录" 出现在 §4.3 开头自打脸；
- §inputs/02 line 131 + §5 矩阵第 7 行 "GitLab Secrets Engine 是第三方 plugin" 是事实错误 — 已在 Vault 1.18 成为官方 engine。

**修订（已完成）**：
- §4.3 重写：先讲当年的有意识产品方向选择（KEP-0001 Non-objectives + diff-with-3.x.md line 82 两份正式文档），再承认未找到独立 Vault 评估文档但产品方向选择已在更上游做掉；不排除当年存在未文档化的口头/PPT 讨论。
- §4.3 5 条核心假设：(1) air-gap 推断成立度从"高"降为"中"（tech P1-4）；其他成立度标注根据 tech P1-4 调整；(3) catalog 层从 "Vault 内不可能复用" 改为 "无任何 secret-store 类产品（Vault / CyberArk / Akeyless / AWS SM）覆盖"。
- §4.4 结论改为 "立项方向 defensible"（tech P1-4 措辞建议），不是二元"想清楚没"。
- §inputs/02 §7：把 "第三方 plugin（社区维护）" 改为 "自 Vault 1.18（2024-09）起 GitLab Secrets Engine 已是官方 engine"，并补 GitHub App / Artifactory / Terraform Cloud / K8s 等官方 engine 清单。
- §5 矩阵第 7 行：同步修改 — "GitLab Secrets Engine 已是 Vault 1.18+ 官方 engine"、承认 "Connectors 在 GitHub App / GitLab / Artifactory 等 dynamic 路径的支持反而弱于 Vault"。
- §1.1 一句话结论：按 CEO 商业语言重写（"Vault 不能替代 Connectors。即便客户额外承担'年六位数美元起'量级 Vault Enterprise license..."），去掉 jargon。
- §1.3 决策树：按 CEO 客户业务语言重写（"客户是否在 K8s 上跑 CI/CD..." / "业务 Pod 是否需要拉私有镜像..."），技术名词括注；"100% 客户场景" 改为 "Alauda 已知客户绝大多数场景" + 注 "需 sales 数据回收"。

---

## F7 — Vault 真实优势被低估 + 缺 HashiCorp Boundary 提及（competitive-fairness S1 + S4 + customer-value P1）

**问题**：报告完全没提 Boundary（Vault 阵营对 data-plane proxy 的官方答案）；对 Vault 在 dynamic secrets / PKI / Transit / cloud IAM 多云场景的真实优势没充分承认。

**修订（已完成）**：
- §1.5 新增 "Vault 与 Connectors 的能力边界界定"：明确列出 Vault 在 PKI / Transit / DB dynamic / Cloud IAM / SSH CA / 跨云联邦上的强项，本报告"不能替代"指 Connectors 11 问题域内的反方向。
- §7.4 新增 "HashiCorp Boundary 是否构成新威胁"：承认 Boundary 是 data-plane proxy 产品；但聚焦 SSH/RDP/DB/TCP，**不**做 HTTP/Git/OCI 协议代理，因此对 Connectors 核心问题域不构成替代；若 CEO 命题扩展到 "HashiCorp 整套栈"，需另做调研。
- §10.3 触发条件场景 D：明确加 "Boundary 扩展支持 HTTP / Git / OCI 协议" 作为重评触发。
- §11.2 新增 "Boundary 协议扩展" 观察项。
- §11.1 dynamic secret 行：从 "Vault 也没有官方 dynamic engine" 改为 "Connectors 在 GitHub App / GitLab / Artifactory / DB / Cloud IAM 上的 dynamic credential 能力**显著弱于** Vault"。

---

## F8 — UI 资源选择器 (问题域 6) moving goalposts 风险（competitive-fairness 问题域 6 + S1）

**问题**：把 "UI 选 branch/tag" 算成 Vault gap，是把 Connectors 自加的产品形态算成 Vault 减分项。

**修订（已完成）**：
- §5 矩阵第 6 行：Vault 解决方式改为 "Vault 与所有 secret-store 类产品（CyberArk / Akeyless / AWS SM）均不在此问题域内 — 这是 Connectors 在 ACP 上自加的 catalog 层"；覆盖度改为 "Connectors 产品形态加值（非 Vault 减分项）"。
- §5.1 矩阵观察：明确 "问题域 6（UI 资源选择器）单列为 Connectors 产品形态加值，不算 Vault 减分项"；说明 "CEO 命题是 'Vault 能否替代 Connectors'，Connectors 交付时已包含 catalog 层，因此 Vault 路线要达到同等客户体验必须新建该层"。
- §7.2 第 2 条：删除 "第三方独立组件结构性无法复现"，改为 "这是 Connectors 在 ACP 上独有的产品形态层，与 'secret-store 替代评估' 不在同一抽象层；不应作为 Vault 的减分项"。
- §10.1 决策证据表覆盖矩阵行：相应去掉问题域 6 的强调，问题域 1/2 从 "Vault 仅模型本身就不覆盖" 软化为 "Vault 单品不覆盖（生态可组合逼近但失去集成度优势）"。
- §3.3 护城河描述：从 "第三方独立组件结构性无法复现" 改为 "第三方组件可组合逼近，但失去 ACP 单一供应商支持口径 + 同生命周期升级 + 与 IAM 同源的集成度优势"。

---

## 同时纳入的 P1 修订（顺手做）

- **CEO P1 #5（决策树 sales 语言）**：已在 F6 一并处理。
- **CEO P1 #6（OpenShift + Vault 反驳）**：§2.4 增加 "OpenShift + Vault 场景中切换 Connectors 会失去定位锚点" 的限定 + 承认无公开渗透率数据。
- **CEO P2 #10（净损失展开）**：§10.4 改为四个维度展开。
- **tech P1-2（PoC-3 Enterprise spec disclaimer）**：§6.3 加 "基于 spec 调研未实测" + Web UI 1.13+ 有基础入口；OSS 近似工程量改为 "组件清单类比，未走完整实现验证"。
- **tech P1-3（Enterprise 边界）**：§5 矩阵第 7 行已修；其他 SSH / Performance Standby 等保留到下一轮。
- **tech P2-3（SA token TTL 范围）**：§5 矩阵第 1 行加 "范围由 K8s `--service-account-max-token-expiration` 限定，下限 ≥ 10m"。
- **customer-value P1 #5（4 类决策者反方场景）**：§2.3 加 "反方场景与边界条件" 子节，列 5 类反方场景。
- **customer-value P1 #7（FUD → 中性）**：§2.4 把 "路线图不确定" 改为 "需通过 IBM/HashiCorp 商务渠道跟踪；写作时未发现重大负面动作，应纳入 6-12 个月观察"。
- **customer-value P1 #8（Vault 优势区）**：§1.5 已加完整段落。
- **competitive-fairness S2（GitLab 事实错误）**：§inputs/02 + §5 矩阵第 7 行已修。
- **competitive-fairness 互操作姿态扩展**：§10.2 动作 4 扩展为 3 种模式。
- **competitive-fairness 全文绝对化措辞软化**：§1.1 / §5 / §7.1 / §7.2 / §8.4 / §10.1 / §10.3 全部按 review 给的"批量软化"表执行。
- **CSI 节点失效完整性（tech P2-2）**：§11.1 加 "已运行 Pod 不受影响，仅新 Pod 在该节点启动延迟"。

## 留到下一轮的 P1 / P2（已在 REPORT.md 顶部"已知 P1 修订项"列出）

- 客户访谈验证 air-gap Vault 接受度（CEO P1 #8 + 整篇核心假设悬空）
- TCO 5 行代算样表（customer-value P0 收敛后剩下的补强）
- §3.1 团队规模数据由 HR/财务对准（CEO P1 #7 + customer-value P2）
- PoC-1b 补 Vault Agent proxy mode 对照组（竞品公平性 S3 最致命攻击点）
- PoC-2b 补 Kyverno + ESO + Vault paper design（竞品公平性问题域 2）
- Vault Enterprise trial 申请 + Control Groups Web UI 实测（竞品公平性 S3）
- Connectors 产品独立性战略评审（CEO "潜台词 c" + customer-value 关键缺失）
- §5 矩阵交叉对比 CyberArk / Akeyless / 云厂商 KMS / SPIFFE（customer-value 竞品 P1）
- §6.1 标题改 "凭据 4 条泄漏通道全部命中"（CEO P2 #9）— 已经不再适用因为标题已改
- §3.1 团队投入数据用 `git shortlog | wc -l` 跑准（customer-value P2 #1）

## 4 角色 sign-off 状态评估

| 角色 | review 时初评 | P0 修订后预期 sign-off |
|------|------------|-------------------|
| CEO | 方向对，4 个 P0 必修才能汇报 | **可 sign-off**（4 个 P0 已修；P1 #7/8 留 next round） |
| 技术架构 | 3.5/5；3 P0 + 4 P1 必修 | **可 sign-off**（3 P0 已修；2/4 P1 已修，剩余 PoC 实测 / Enterprise 边界细节留 next round） |
| 客户价值 | 2.5/5；3 P0 + 5 P1 必修 | **可 sign-off**（3 P0 已修；3/5 P1 已修，TCO 代算表 / 客户访谈留 next round） |
| 竞品公平性 | 2.5/5；5 最关键修订 | **可 sign-off**（4/5 已修：GitLab 事实错误 / Boundary / UI selector / 绝对化措辞；PoC-1b 实测留 next round 但加了 disclaimer） |
