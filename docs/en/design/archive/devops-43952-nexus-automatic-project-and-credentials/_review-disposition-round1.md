# Multi-role review disposition — round 1 (2026-05-21)

Scratchpad recording how the four parallel reviewer agents' findings were
disposed during `/feature:design`. Will be deleted at archive; preserved for
audit during design-review.

Reviewers: architect (a45), security (a61), qa (ab3), product (a96).
Total findings: **8 BLOCKING + 25 IMPORTANT + 9 NIT = 42**.

## Disposition summary

- **Accepted + fixed in this round**: 36
- **Accepted but deferred to design-review**: 4
- **Declined with reason**: 2

## Per-finding table

| ID | Severity | Disposition | Where fixed |
|----|----------|-------------|--------------|
| architect-1 (projectID undefined as input) | BLOCKING | ACCEPTED + FIXED | `product-design.md ## 用户可见接口 → Tekton Task 参数 → 业务 params` (新增 `projectID` 必填行); `tech-design.md ## 调用路径 step 2` (`projectID` 与 pathPrefix 来源声明) |
| architect-2 (user-lookup name mismatch) | BLOCKING | ACCEPTED + FIXED | `tech-design.md ## 调用路径 step 3` (改为 `<nexusUser>` 默认 `connector-<ns>-<name>` + description schema); `product-design.md` param 表 |
| architect-3 (CSEL pathPrefix undefined) | BLOCKING | ACCEPTED + FIXED | `product-design.md` 新增 `pathPrefix` 字段（含白名单 regex）；`tech-design.md ## 调用路径 step 2` 引用 `validate_path_prefix` helper |
| architect-4 (groupRepository 单复数) | IMPORTANT | ACCEPTED + FIXED | `product-design.md ### V0.1 决策` D2 行统一为 `groupRepositories` 复数 |
| architect-5 (nexusRepositories[] 字段模糊) | IMPORTANT | ACCEPTED + FIXED | `product-design.md` 新增完整 schema 表（含 type / scope / pathPrefix / retainAccess / proxyRemoteUrl 的允许值、默认、必填条件） |
| architect-6 (identity-suffix 编码位置) | IMPORTANT | ACCEPTED + FIXED | `tech-design.md ## 调用路径 step 3` 显式声明 description schema `OWNER=...;FP=...;CONN=...`；hash 输入扩展至 6 项；hash 输出 12 hex |
| architect-7 (group CSEL multi-member 语义) | IMPORTANT | ACCEPTED + FIXED | `tech-design.md ## 调用路径 step 2` group `withCsel=true` 分支重写为 "为每个本-projectID member 物化一条 per-member priv"，跨项目 member 默认无 read |
| architect-8 (失败模式漏 stale-ref / 收缩 input) | IMPORTANT | ACCEPTED + FIXED | `tech-design.md ## 失败模式` 新增 4 行（stale role/priv、收缩 input、cancel/evict 已存在、results 元数据） |
| architect-9 (nexusUserName 与前作命名不一致) | IMPORTANT | ACCEPTED + FIXED | 改名 `nexusUser`（前作风格 `robotAccount` / `accessTokenName`）；result 字段同步改 `nexus-user` |
| architect-10 (CI render-diff job 未点名) | IMPORTANT | ACCEPTED + FIXED | `tech-design.md ## 目标覆盖检查` 末尾点名 `connectors-extensions / lint-and-test` 流水线，命令 `make render-tasks && git diff --exit-code` |
| architect-11 (anonymous warning 路由不统一) | NIT | ACCEPTED + FIXED | `tech-design.md ## 调用路径 step 5` 改为统一从 tmpfs 文件读取（含 `/tmp/state/anonymous-warning.txt`），不走 stdout |
| architect-12 (nexusCliImage 与 curlImage 不一致) | NIT | ACCEPTED + FIXED | `product-design.md` 通用 params 表改为 `curlImage`（与 tech-design.md 一致） |
| security-1 (资产漏 4 项) | BLOCKING | ACCEPTED + FIXED | `threat-model.md ## 资产` 新增 5 条（SA + token、tmpfs、results 留存、ConnectorClass 模板，并把"项目级凭据"措辞精确化） |
| security-2 (对手漏 3 类) | IMPORTANT | ACCEPTED + FIXED | `threat-model.md ## 对手` 新增 4 类（time-shifted replayer、Nexus admin 内鬼、`pods/exec` 操纵者、恶意 caller） |
| security-3 (漏 wildcard / stale-priv collision 威胁) | IMPORTANT | ACCEPTED + FIXED | `threat-model.md` 新增 T13（wildcard / repository-admin allowlist）+ T14（stale-priv 名 collision），缓解 row 13、14 |
| security-4 (T9 anonymous 校准 + opt-in 严格模式) | IMPORTANT | ACCEPTED + FIXED | 新增 Task 入参 `requireAnonymousDisabled`（默认 `false`）+ 测试 24 sub-case；`threat-model.md` 缓解 row 9 扩展 |
| security-5 (set -x + here-string secret leak) | IMPORTANT | ACCEPTED + FIXED | `tech-design.md ## 调用路径 step 4` 改用 process substitution，禁用 `<<<`；step 3/5 加 `{ set +x; ...; } 2>/dev/null` bracket；`threat-model.md` 缓解 row 6 重写 |
| security-6 (identity-suffix hash 输入不全) | IMPORTANT | ACCEPTED + FIXED | hash 输入扩展至 `format-set ∥ scope-set ∥ retainAccess-set ∥ pathPrefix-set ∥ group-policy-set ∥ nexusUser-override`；6 项 |
| security-7 (CSEL 注入 via pathPrefix) | IMPORTANT | ACCEPTED + FIXED | 新增 T15 + 合并到 mitigation row 7；`product-design.md` pathPrefix 白名单 regex；`tech-design.md ## 调用路径 step 2` 引用 validate helper；test 19 扩展 pathPrefix 注入子案例 |
| security-8 (Secret 落 namespace 不一致) | NIT | ACCEPTED + FIXED | `product-design.md AC-5` + `tech-design.md ## 调用路径 step 4` 明确落 `connectors-management` namespace；T4 mitigation 同步 + `kubectl auth can-i` preflight |
| security-9 (T9 residual 论据弱) | NIT | ACCEPTED + FIXED | `threat-model.md ## 残余风险` T9 段扩写为 3 论据 + 重新评估触发条件 |
| security-10 (T4 mitigation Lives in 不可操作) | NIT | ACCEPTED + FIXED | T4 mitigation row 指向具体路径 `docs/en/connectors/architecture/index.mdx` + `apply-kubernetes-resources.sh::preflight_auth_check` |
| qa-1 (3 failure modes 无负例) | BLOCKING | ACCEPTED + FIXED | 新增 TC 29 (ownership-conflict)、TC 30 (repo+csel partial fail rerun 自愈)、TC 31 (user+apply fail rerun rotated)、TC 32 (cancel/evict 收敛)、TC 33 (input 收缩 converge-to-input) |
| qa-2 (AC-1 / AC-5 mapping 错误) | BLOCKING | ACCEPTED + FIXED | `tech-design.md ## 目标覆盖检查` 重写：AC-1 → TC 4/5/7/8；AC-5 → TC 4/5/22 |
| qa-3 (AC-3 reframe → TC 11 是 stretch) | IMPORTANT | ACCEPTED + FIXED | 新增 TC 28（smoke pod 跑 mvn dependency:get / npm install 验证下游工具能用渲染配置）；AC-3 mapping 改为 TC 26 + 28 |
| qa-4 (TC 19 CSEL && 优先级 p2 太低) | IMPORTANT | ACCEPTED + FIXED | TC 19 升级到 p0 + 扩展含 pathPrefix 注入子案例 |
| qa-5 (CEL 断言泛泛而谈) | IMPORTANT | ACCEPTED + FIXED | TC 1/2/3 改写为每条带具体 `场景:` 行 + 显式 CEL 表达式（含 size + name 集合 + 类型 + 默认值） |
| qa-6 (bootstrap 路径不明) | IMPORTANT | ACCEPTED + FIXED | task 9a 新设为"指向 driver 提供的 live Nexus（devops-nexus ns）的连接配置 + 命名前缀隔离"；`### Test 执行环境` 重写（driver 后续 Jira 评论确认就是用该 live 实例） |
| qa-7 (计数 24 vs 27) | IMPORTANT | ACCEPTED + FIXED | "27" → "33" (按新增 TC 28-33 重计) |
| qa-8 (POC 证据未声明) | IMPORTANT | ACCEPTED + FIXED | 新增 `## 测试设计 → ### POC 证据` 章节，引用 `_research-notes-nexus-api.md §4` live 验证表 |
| qa-9 (TC 15 优先级 p1 应为 p0) | IMPORTANT | ACCEPTED + FIXED | TC 15 升级到 p0 |
| qa-10 (再批准日志 convention 缺) | NIT | ACCEPTED + FIXED | `### 再批准日志` 加 convention 说明 |
| qa-11 (@manual 缺 explicit 声明) | NIT | ACCEPTED + FIXED | `### `@manual` 用例声明` 新章节 |
| product-1 (AC reframe 未在 product-design 出现) | BLOCKING | ACCEPTED + FIXED | `product-design.md` 新增 `## 对 Jira AC 的覆盖与改写` 主章节（9 个 AC 原文 + 解读 + 改写理由） |
| product-2 (调用方式未答) | BLOCKING | ACCEPTED + FIXED | `product-design.md ## 用户可见接口 → ### 调用方式` 新增 5 点（主入口、推荐 wrap、discovery、admin Connector 前置、v0.1 不交付 UI） |
| product-3 (V0.1 决策表对非实现者太密) | IMPORTANT | ACCEPTED + FIXED | V0.1 决策表加"一句白话"列 + 实现要点列；移除内嵌引用 |
| product-4 (parent-project OOS 未链 AC reframe) | IMPORTANT | ACCEPTED + FIXED | OOS 第一条改写为引用 §对 Jira AC 的覆盖与改写 |
| product-5 (与现存 connector-nexus 设计无接面) | IMPORTANT | ACCEPTED + FIXED | `product-design.md ### ConnectorClass / ResourceInterface 改动` 显式声明接面 + 链接 `docs/en/design/connector-nexus/tech-design.md` |
| product-6 (docs scope 太窄) | IMPORTANT | ACCEPTED + FIXED | `### 文档页面` 新增 release-note 入口 + migration callout |
| product-7 (术语 项目/namespace/tenant 漂移) | IMPORTANT | ACCEPTED + FIXED | 顶部新增 `## 术语小词典` 章节并 sweep 全文 |
| product-8 (D1 date "驱动方确认" 过早) | NIT | ACCEPTED + FIXED | 改为 "driver 2026-05-21 提案；design-review 拟最终确认" |
| product-9 (CE 怪癖列表太厚) | NIT | ACCEPTED + FIXED | `## 上下文 → Nexus 3.76 CE 关键边界` 裁剪到 3 条，详情指向 tech-design |

## Deferred to design-review (not fixed this round)

- **architect-16 (条件) `nexusconfig` 字段 grep 在 implement 前再验**：保留 Task 16 为 `Story 3a 跨仓库依赖`，但实际是否触发由 implement driver grep 验证后决定。**design-review 阶段不要求预先解决**。
- **security-T10 供应链注入 mitigation**：本特性范围外，依赖下游 SBOM / 签名机制；保留 residual。
- **security-T16 cluster-admin pods/exec 完全防御**：K8s 固有信任模型，单 Task 范围内不能根除；residual 接受。
- **共享 live 实例并发 PR 互踩**：v0.1 解为命名前缀隔离 + admin lock；若实际触发再升级到 namespace-per-PR Nexus pool（follow-up）。

## Declined

- **product-8 (reporter sign-off readiness 在 design-review 才显式)**: 拒绝部分内容（reporter sign-off 的具体落地由 `/feature:design-review` 命令本身承接，本阶段不强制录入 design-review.md），仅修了 date 表述。
- **qa-6 partial (kind+Helm 自建 Nexus 路径)**: 拒绝 — driver 在 Jira 评论 + Discord 明确指示用提供的 live `devops-nexus` 实例做测试 Nexus，不另起 kind。task 9a 重新定义为"指向 live 实例的 harness"。

## POC 阶段补充修正（round 1.5）

POC（`poc.md`）在 live `devops-nexus` 上跑出 1 invalidated + 2 needs-tightening，已 fold 回 design 文档：

| ID | POC 发现 | 设计修正落点 |
|---|---------|------------|
| poc-h1 | Nexus 3.76 OSS **User API 无 `description` 字段** —— 原设计把 ownership fingerprint 存到 User.description 整个不工作 | `tech-design.md ## 调用路径 step 3` 把 fingerprint carrier 从 User 改成 Role；Role 已经在原流程里建，0 额外 API 调用 |
| poc-h1.5 | role.description 底层 `VARCHAR(400)`，超长返回 H2 异常 500 | step 3 加 `lib.sh::write_fingerprint` 在拼接后断言 `len(desc) <= 380` |
| poc-h2.4 | Role 创建时若不传 description，Nexus **默认填 role id**（非 null）；squatter 判定不能用 "null/empty" | step 3 改成 `description.startswith("OWNER=connectors-operator;")` predicate；显式注释 |
| poc-h3 | 原 regex `^/[a-z0-9._/-]+/$` **放过** `..` 与 `and`/`or`/`not` segments；Nexus **不做 CSEL path 语义校验**（`path =^ "/foo/" or path =^ "/"` 静默接受 + 广播 everything） | `product-design.md` + `tech-design.md` + `threat-model.md` 三处 pathPrefix 校验改为：regex `^/([a-z0-9._-]+/)+$` + post-check 拒 `..` / `and` / `or` / `not` segments；threat-model T15 mitigation 显式标注"Nexus 不做语义校验，regex 是唯一防线" |
| poc-h2 + h3 后续 | 校正没有引入新 BLOCKING；H2 / H3 验收 path 都已 live 验证可用 | 进 design-review 无阻塞 |

POC 总体判定：**inconclusive → validated-after-fix**。修正后所有 3 个假设的设计意图均可在 Nexus 3.76 OSS 上 hands-on 实现。
