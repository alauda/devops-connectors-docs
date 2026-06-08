# 威胁模型 — Nexus 自动创建 Project + Connector + Secret

<!--
risk=sensitive 必需。在 /feature:design-review 阶段由 security 标签 reviewer 复核。
-->

## 资产

- **Nexus 管理员凭据**（admin Connector + 关联 Secret，通过 CSI 挂载进 TaskRun）—— 持有该凭据可对**整个 Nexus 实例**做 user / role / repo CRUD；泄露等同 Nexus 实例完全失陷。
- **项目级 Nexus 凭据**（Task 为每个项目生成的 `nexusUser` 的 password）—— 持有该凭据可在该项目的路径前缀内读写 hosted repo 内容；通过 K8s Secret 派发到 `connectors-management` namespace 后由 connectors-proxy + CSI 间接消费。
- **K8s 端 Connector + Secret 对象**（`kubernetes.io/basic-auth` 类型 Secret + Connector CR）—— 落 `connectors-management` namespace；该 namespace 的 RBAC + Tekton TaskRun SA 决定 blast radius。
- **TaskRun ServiceAccount + 其 token**（`connectors-management/automation-sa`）—— 每个 Task Pod 上都有；被滥用即等同 Connector + Secret CRUD 权限；通过 `pods/exec` 抓取风险与 CSI 凭据并列。
- **`/tmp/state/nexus-token` tmpfs 文件**（step 3 写、step 4 读，`emptyDir.medium: Memory`）—— 含项目级 password 明文；与 CSI mount 是 password 在 TaskRun 内的两个 plaintext 落点。
- **Tekton results 留存**（`taskruns/get` 权限可读）—— `nexus-repositories`、`nexus-user`、`connector-ref` 在 TaskRun 历史中长期可读；含 user 名、repo 命名前缀等元数据（**不**含 password）。注：原设计列入第 4 个 result `anonymous-policy-warning`，v0.1 未落地（DEVOPS-44183），匿名检测改为 step 1 verify 日志一行 WARN（log-only）；TaskRun results 留存面因此减小一项。
- **`nexusconfig` ConnectorClass 模板**（既有 schema，本特性消费方）—— 含 `settings.xml` / `.npmrc` / `pip.conf` 渲染逻辑，最终在下游应用 Pod 内输出 project password；模板被改可成为 password 泄露通道。
- **Nexus repository 内容**（项目自有 hosted repo 中存放的制品）—— 篡改可触发下游 CI/CD 拉到被污染版本；删除可阻断流水线。
- **Nexus content-selector / role / privilege 配置**—— 跨项目共享的权限原语；被错误编辑可绕过 path-prefix 限制。
- **TaskRun 日志**（stdout / stderr）—— 含可能被泄露的元数据（user 名、repo 命名前缀、Nexus endpoint）；password / token 不应出现在日志中（mitigation 6 校验）。
- **`anonymous` Nexus 用户**（cluster-level 状态）—— 默认开启 read，决定未授权方是否能拉项目制品；本 Task 默认**不修改它**，仅在 step 1 verify 步骤记一行 WARN 日志（log-only）。v0.1 未提供 `requireAnonymousDisabled` opt-in 严格模式（DEVOPS-44183，设计 → 落地之间晚期下线）；严格站需在 Nexus 安装阶段处理 cluster-level 配置。

## 参与方

### 合法

- **平台工程师 / DevOps 用户** —— 触发 TaskRun（手工或 cron），消费产出的 Connector + Secret 在项目流水线中。
- **项目 CI 流水线 Pod** —— 用项目级凭据连 Nexus，拉 / 推制品。
- **Tekton TaskRun ServiceAccount** —— 通常为 `connectors-management/automation-sa`；持有 cluster-side Secret + Connector CRUD on `connectors-management` 与目标项目 namespace，以及读 admin Connector + 其 CSI mount 的权限。
- **Nexus 管理员**（人）—— 在 Nexus UI 上轮换 admin 凭据时同步更新 admin Connector 关联 Secret；负责 cluster-level 匿名策略。

### 对手

- **内部权限蔓延者**（已拿到一个项目 Nexus 凭据的内部 actor）—— 目标：越过 path-prefix 写入其它项目的制品 / 接管其它项目 user。
- **时移密码 replayer**（持有某次过去泄露的项目-user password 的人）—— 目标：在下次 rerun 之前用旧密码持续读 / 写 hosted repo。Nexus local-user password 无原生过期，rotate 完全依赖 rerun 节奏。
- **Nexus 管理员（人）作为内鬼**—— 目标：手工删除 / 修改项目对象（user / role / repo），让 Task 的 identity 判断走错支；或直接读 user description fingerprint 反推命名约定；或读 hash store 试图离线破解 password。
- **Tekton `pods/exec` / debug-pod 操纵者**（持有目标 ns 上 `pods/exec` 或 `pods/portforward` 权限的 cluster operator）—— 目标：在 Task Pod 跑期间 exec 进容器抓取 tmpfs `/tmp/state/nexus-token` 或 CSI mount 内容；并发抓取 Tekton results。
- **供应链注入者**—— 目标：篡改某项目 hosted repo 中的制品（POM / npm tarball / Docker layer）让下游 CI 拉到被污染版本。
- **CSI 凭据读取者**—— 目标：读取 TaskRun 中挂载的 admin Connector secret（通过容器逃逸 / 误配 RBAC / hostPath / debug pod）。
- **K8s namespace 串扰者**—— 目标：在 `connectors-management` 或下游消费方 namespace 拿到自己不该有的 Secret 内容（通过 RoleBinding 错误授权 / Pod ServiceAccount 错挂）。
- **TaskRun 日志读取者**—— 目标：从 logs / Tekton results / pod events 中收集到凭据明文或弱化的 fingerprint。
- **Nexus 端帐户 squatter**—— 目标：抢先注册同名 user / role / repo，让 Task 在 rerun 时静默 adopt（参 GitLab retrospective ownership 校验教训）。
- **匿名 Nexus 用户**（若启用）—— 目标：未授权拉取项目制品。
- **恶意 caller**（控制 Task 输入的人，例如能修改 PipelineRun 参数的项目用户）—— 目标：构造特殊 `pathPrefix` / `projectID` / `nexusUser` 注入 CSEL 表达式或命名前缀逃逸至 admin-only 对象。

## 威胁

| # | 威胁 | 受影响资产 | 可能性 | 影响 |
|---|------|----------|-------|------|
| T1 | 项目用户越过 path-prefix 写入或读取其它项目数据（CSEL bypass / role grant 配错 / repository-admin 错挂） | 项目级凭据 + Nexus repository 内容 | low | high |
| T2 | 删 role / priv 留下 stale ref，导致已删 user 残留访问能力（Nexus 端 cleanup 不级联）| 项目 Nexus 配置 + 项目级凭据 | medium | medium |
| T3 | admin Connector 凭据泄露（CSI mount 被误访问 / 日志中泄露） | Nexus 管理员凭据 | low | critical |
| T4 | 项目 Secret 在项目 namespace 被非授权读取（RBAC 配置错误 / 错挂 SA） | 项目级凭据 | medium | medium |
| T5 | Nexus 端同名 user / repo 被外部 actor 抢占 → Task rerun 时静默 adopt | 项目级凭据 + 项目 repo | low | high |
| T6 | TaskRun 日志 / Tekton results 中泄露明文凭据或可逆 fingerprint | 项目级凭据 + admin 凭据 | medium | high |
| T7 | CSEL 表达式构造错误（`&&` 而非 `and`）导致 selector 实际为 deny-all 或 allow-all | 项目 Nexus 配置 | low | high |
| T8 | 部分失败导致 Nexus 端创建了 user 但 K8s 端 Secret 缺失 / 不一致 | 项目级凭据 + 项目 namespace | medium | medium |
| T9 | 匿名 Nexus 用户未关闭且对项目 hosted repo 有 read 权限 → 未授权拉取 | 项目 repo 内容 | high | low / medium |
| T10 | 供应链篡改：合法项目用户被诱导 / 凭据被盗后向自己 path-prefix 推入恶意制品 | 项目 repo 内容 + 下游 CI | low | high |
| T11 | Nexus admin 在管理员视图删除项目对象（user / role / repo）造成 Task rerun 误判 identity-changed → 不必要 recreate / Connector 抖动 | 项目级凭据稳定性 | low | low |
| T12 | Nexus 实例本身降级到 PRO（启用 LDAP / SAML / user-tokens）使 Task 的 basic-auth + local-user 路径与新 realm 冲突 | 整体功能 | low | medium |
| T13 | Task 误把 `wildcard` / `repository-admin` priv 加入项目 role，给项目用户授予实例级 CRUD | 项目级凭据 + Nexus 实例 | low | critical |
| T14 | 删 priv / role 后留下 stale name，外部以同名再建一个**更宽**权限 priv → 既有用户隐式继承（Nexus role priv 校验只在 create 时做）| 项目级凭据 | low | high |
| T15 | 恶意 caller 通过 `pathPrefix` / `projectID` 注入 CSEL 表达式（如 `"; or path =^ "/`）或越界命名前缀 | 项目 Nexus 配置 + 跨项目隔离 | low | high |
| T16 | `pods/exec` 权限滥用：cluster operator 在 Task Pod 跑期间 exec 进 step 3 / step 4 抓取 tmpfs token | 项目级凭据 + admin 凭据 | low | high |
| T17 | `nexusconfig` ConnectorClass 模板被替换为含 password 外发逻辑（如 webhook 发送）的版本 | 项目级凭据 | very low | critical |

## 缓解

| # | 威胁 | 计划缓解 | 落在哪 | 责任人 |
|---|------|---------|------|-------|
| 1 | T1 | scoping 阴性测试用例（test 9, 10, 11, 12 — `script.feature`）实测 CSEL 边界 + 阻止 `repository-admin` priv 出现在 role 中 + helper lint | `tech-design.md ## 测试设计`、`scripts/lib.sh` | impl driver |
| 2 | T2 | Task step 3 / step 5 在每次 rerun 时按命名前缀 `proj-<projectID>-*` 列出现有对象 → 反向清理 stale；test 20, 21 守护 | `tech-design.md ## 失败模式`、`scripts/lib.sh::reconcile_dependencies` | impl driver |
| 3 | T3 | admin 凭据**仅**通过 CSI 挂载（`/workspace/nexus-config`），**绝不**作为 Pod env / Task param 出现；Task SA RBAC 限制为 `get` 该 Secret + CSI mount；日志 redact 校验（test 18） | `tech-design.md ## 调用路径`、平台 RBAC 模板（部署方责任） | impl driver + 部署方 |
| 4 | T4 | Connector + Secret 落 `connectors-management` namespace（**不**落项目 namespace）—— tech-design.md ## 调用路径 step 4 已明确；下游应用 Pod 通过 connectors-proxy + CSI 间接消费 password，项目 namespace 内**不**留 raw password Secret；该架构详见 `docs/en/connectors/architecture/index.mdx`。`apply-kubernetes-resources.sh` 在 SSA 前 `kubectl auth can-i create secrets -n connectors-management` 自检；自检失败 fail-fast 不静默继续 | `tech-design.md ## 调用路径 step 4`、`scripts/apply-kubernetes-resources.sh::preflight_auth_check`、`docs/en/connectors/architecture/index.mdx` | impl driver + 部署方 |
| 5 | T5 | 在 user / role / repo 的 description 字段写 ownership fingerprint（`owner=connectors-operator|connector-ns=<ns>|connector-name=<name>`）；Task rerun 必须先 `verify_admin_ownership`，不匹配则报 actionable error 而非 adopt | `scripts/lib.sh::verify_admin_ownership`、test 21 守护 | impl driver |
| 6 | T6 | password 从不写日志：(a) 所有涉及 `$PASSWORD` / `$rendered` / curl `-u` 拼接 / `change-password` body 的命令均在 `{ set +x; ...; } 2>/dev/null` bracket 内（具体落点：`scripts/lib.sh::log`、`scripts/lib.sh::nexus_curl`、`scripts/ensure-nexus-user.sh::write_password_tmpfs`、`scripts/apply-kubernetes-resources.sh::render_and_apply`、`scripts/write-results.sh::emit_results`）；(b) **禁止 `<<<` here-string**（参 tech-design.md ## 调用路径 step 4 说明），改用 process substitution `< <(printf '%s\n' "$rendered")`；(c) test 18 在 `verbose=true` 模式下也运行，grep step 日志期望 0 个 password-pattern match；(d) CI guard：rendered task YAML 中不得出现 `set -x` 全局开关 | `scripts/{lib,ensure-nexus-user,apply-kubernetes-resources,write-results}.sh`、test 18 verbose 子分支 | impl driver |
| 7 | T7 + T15 | (a) CSEL 表达式由 helper 函数构造（不允许 caller 拼接），`scripts/lib.sh::build_csel_expression` 内 assert `'&&' not in expr && '||' not in expr`；(b) `lib.sh::validate_path_prefix` 双层防御（**POC H3 修正**）：(b1) regex `^/([a-z0-9._-]+/)+$`（character class 不含 `/`，段必须非空），(b2) post-check 拒绝任何段等于 `and`/`or`/`not` 或路径含字面 `..`；(c) `lib.sh::validate_project_id` + `validate_nexus_user` 白名单 `^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`；(d) test 19 涵盖 `&&`、CSEL 关键字 segment、`..` 路径段三类反向用例。**关键提醒**：POC 实测 Nexus 3.76 OSS CSEL parser **不做 path 语义校验** —— `path =^ "/foo/" or path =^ "/"` POST 204 静默接受并广播到 everything；regex + post-check 是**唯一**防线 | `scripts/lib.sh::{build_csel_expression,validate_path_prefix,validate_project_id,validate_nexus_user}`、test 19 | impl driver |
| 8 | T8 | step 4 K8s apply 失败时 step 3 已写的 user 不 rollback；rerun 走 status=rotated 路径覆盖 password 并重新 SSA；test 7（5 次幂等 rerun）+ test 22（SSA 幂等）共同守护 | `tech-design.md ## 调用路径`、`scripts/apply-kubernetes-resources.sh` | impl driver |
| 9 | T9 | 默认 (c)：`verify.sh`（step 1）检测匿名状态并记一行 `WARN Nexus anonymous access is ENABLED at ...` 日志；how-to 文档显式指引部署方关闭匿名（cluster-level Nexus 配置，本 Task 默认不动）；test 24 守护 log-only 路径。**已考虑但 v0.1 未落地**（DEVOPS-44183，设计 → 落地之间晚期下线）：`anonymous-policy-warning` Tekton result + opt-in `requireAnonymousDisabled` 参数。下线理由参 `manual-testing.md` AC-6 line 135（log-only 实现已被接受），严格站需在 Nexus 安装阶段处理 cluster-level 配置；未来如有真实需求，作为 v0.2+ 独立特性 | `verify.sh`、how-to docs、product-design.md §D3 | impl driver + 部署方 |
| 10 | T10 | 不在本特性范围内做防御（凭据盗用 / 社工不可由 Task 防御）；缓解依赖：(a) 项目用户的 CI 流水线签名 / SBOM 校验、(b) Nexus 端开启 `strictContentTypeValidation`（hosted repo body 中已设 true）—— 后者由 helper `ensure-nexus-resources` 强制默认 true，禁止 caller 关闭 | `scripts/ensure-nexus-resources.sh`（hosted repo 模板）、residual risk 一节 | impl driver |
| 11 | T11 | Task 在 identity 比对时区分 "ownership fingerprint mismatch" vs "expected-identity-state changed" —— 后者才走 recreate；前者抛 error；test 14 vs test 21 区分 | `scripts/ensure-nexus-user.sh::compare_identity` | impl driver |
| 12 | T12 | how-to 文档（task 13）声明本 Task 仅支持 OSS 3.76；PRO + 非 NexusAuthenticatingRealm 仅在 best-effort 范围；CI 不针对 PRO 跑 | how-to docs、release-notes | impl driver |
| 13 | T13 | `scripts/lib.sh::build_role` 维护内部白名单 `ALLOWED_PRIV_TYPES = {repository-content-selector, repository-view}`；构造 role 时拒绝任何外部传入的 priv 引用 `wildcard:*:*` / `nx-admin` / `repository-admin:*`；test 12 守护"项目用户无 admin 操作"反例已覆盖 | `scripts/lib.sh::build_role`、test 12 | impl driver |
| 14 | T14 | step 3 在反向清理 priv 之前先 `list users referencing priv` —— 如有非本 Task owner 引用，refuse 删除并 abort；rerun 阶段对发现的 stale priv 不静默重建，要求人工 takeover | `scripts/lib.sh::safe_delete_priv` + `scripts/ensure-nexus-user.sh` `unsafe stale ref` 分支、test 21 守护 | impl driver |
| 15 | T15 | 参 row 7 合并条目 | 同 row 7 | impl driver |
| 16 | T16 | (a) Task 步骤标注 `securityContext.runAsUser: 65532` + readOnlyRootFilesystem；(b) tmpfs `/tmp/state/nexus-token` 在 step 5 退出前 `shred -u`；(c) how-to 文档要求部署方限定 `pods/exec` 权限在 `connectors-management` ns 不要授予非平台管理员；(d) `automation-sa` 仅 bind 必要的 RoleBinding；T3 已 cover CSI mount 等其它面 | `scripts/lib.sh::cleanup_state`、how-to runbook、RBAC 模板 | impl driver + 部署方 |
| 17 | T17 | `nexusconfig` ConnectorClass 的 owner 是 connectors-extensions 仓库；本 Task 在 install-manifest 同步 + cmd/kodata 流程中受 CI 审查（CLAUDE.md "NEVER edit cmd/kodata/" 规则）。模板 / Helm chart 任何修改走 PR review；本特性**不**修改模板（详 product-design.md §ConnectorClass / ResourceInterface 改动） | `cmd/kodata/connectors-nexus-tektoncd/` 自动同步流水线、PR review 流程 | 平台架构 + impl driver |

## 残余风险

- **T3 admin 凭据机密性的最终边界由部署方 RBAC + CSI driver 决定**，本 Task 已最小化暴露面（never in env / never in result / never in log），不进一步加固。被接受是因为 admin 凭据是 platform-level secret，其保密由 namespace 隔离 + cluster RBAC 体系保证，与 Harbor / GitLab 前作一致。
- **T9 匿名用户策略由部署方决策**。default 模式下接受两点：(i) 实际部署里依赖匿名 read-only mirror 的小众场景占比未量化，但被严格站打断会阻塞迁移；(ii) v0.1 仅 step 1 verify 日志一行 WARN（log-only），无 Tekton result 也无 opt-in fail 参数（`anonymous-policy-warning` + `requireAnonymousDisabled` 在设计 → 落地之间晚期下线，DEVOPS-44183），部署方需自己 scrape step 1 日志或在 Nexus 安装阶段处理 cluster-level 匿名配置。**重新评估触发条件**：若有客户报告未授权 pull 事故，重新评估 v0.2 是否补回 `anonymous-policy-warning` result + opt-in fail，并把 default 翻转为 fail-on-anonymous，opt-out 保留兼容。
- **T10 供应链注入** 在本 Task 范围外 mitigate。residual 是任何制品库共有的问题，不属于本特性的 unique surface。
- **T11 admin 误删项目对象 → identity-changed recreate 抖动**。impact low；接受重建成本（password rotate + Secret SSA + Connector status 抖动 ≤ 5s），不引入"等 admin 确认"的人工 gate。
- **T12 Nexus 实例升级到 PRO** 后 SAML / LDAP 强制启用会破坏 Task 假设。residual 接受，因为这是部署方主动变更；release-notes 会显式说明 OSS 3.76 边界。
- **T16 cluster operator 通过 `pods/exec` 抓 tmpfs token / CSI mount**。本 Task 已收缩 tmpfs 留存窗口（step 5 退出前 shred）+ 推荐 RBAC 模板限定 `pods/exec`，但 cluster-admin 角色仍可绕过任何 Pod 级别防御 —— 这是 K8s 的固有信任模型，不在单 Task 范围内 mitigate。
- **CSEL out-of-scope GET 返回 404 而非 403** 是 Nexus 信息隐藏设计；非威胁，是 documented behavior，how-to 文档会说明。

## Reviewer

- **姓名**：_（design-review 时填）_
- **角色**：security-labeled reviewer
- **安全标签**：_（由 reviewer 自填）_
- **签字日期**：_（design-review 通过时填）_
