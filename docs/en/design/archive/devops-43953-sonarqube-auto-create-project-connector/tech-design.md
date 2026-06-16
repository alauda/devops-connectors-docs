# 技术设计 — SonarQube 自动创建 Project + Connector + Secret

<!--
实现文档（HOW）。
- 契约（参数、results、workspaces、API 调用、AC、隔离模型、前置条件）→ product-design.md
- 实证 / 用户操作手册 → poc.md
三份文档章节顺序对齐，便于同步对照。
-->

## 1. 目标

实现 [product-design.md §1](./product-design.md#1-目标) 描述的 Tekton Task —— Branch-3 / 每租户模型 —— 涵盖模板与脚本设计、幂等与回滚、任务拆解、测试。

## 2. 架构

### 2.1 涉及组件

| Repo / 路径 | 角色 | 改动幅度 |
|------------|------|---------|
| `connectors-extensions/connectors-sonarqube/tektoncd/tasks/sonarqube-connector-automatic-creation/0.1/` | **新增子树**：Task 模板（`*.template.yaml`，含 `{{ INCLUDE: scripts/<name>.sh }}` 占位符）+ 渲染后 Task YAML、`scripts/{lib,ensure-user,ensure-template,ensure-token,apply-kubernetes-resources,rollback,write-results}.sh`、`samples/`、`testing/` | 新增 |
| `connectors-extensions/connectors-sonarqube/tektoncd/kustomization.yaml`、`hack/render-task.sh`、`make render-tasks` | 渲染发布通道 | 新增 |
| catalog | 复用 alpine `kubectl` 镜像（自带 bash+curl+jq+kubectl） | **不改** |
| `connectors-extensions/connectors-sonarqube`（既有 ConnectorClass） | 原样消费；A8 需注册 `sonar-api` configuration | 增量、无破坏 |
| `connectors` (core) | — | **不改** |
| `connectors-plugin` | — | **不改（无 UI 面）** |
| `connectors-operator`（本仓） | 流水线接线：`sync_install_manifests.sh` + `values.yaml` + doc-sync + `cmd/kodata` 自动同步 | 仅接线 |

> **不**新建 Containerfile / 工具镜像。

### 2.2 构建期渲染

`make render-tasks` → `hack/render-task.sh`（≤50 LOC）把脚本内联进模板，
写出可发布 Task YAML；CI 重渲染并在漂移时失败。

### 2.3 运行期 — 3 步骤调用路径

**步骤 0 — `ensure-tenant`**（`toolImage`，包含 preflight + 4 个 ensure-*）：

1. **`lib.sh` 启动** —— 自动识别 `sonarqube-config` 挂载形态（Connector-CSI
   或 Secret 直挂；按 product-design.md §5.3 统一文件名约定）；读 `address`
   + 优先 `token`（无则 `username`+`password`）；写 `curl --config` 到 tmpfs。
2. **preflight（在任何租户改动前）** —— `GET api/permissions/users?permission=admin`：
   - admin login 不在结果集 → **拒绝运行**，打印「admin Connector 凭据
     缺 Administer System」（A9）。
   - preflight API 不可用（HTTP ≥500） → 回退「不验证、由后续 API 自报
     HTTP 403」。
3. **`ensure-user`** —— `users/search`；缺则 `users/create`（`local=true`，
   记 `user:created`）。`permissions/add_user permission=provisioning
   login=<user>` 把全局 `provisioning` **直接**授给该 user（先查后授，幂等；
   新授时记 `user-provisioning:granted`）。校验该 user 的直接全局权限
   **仅有** `provisioning`、除 `sonar-users` 外不属其它组，偏离则失败。
4. **`ensure-template`** —— `permissions/search_templates`；缺则
   `permissions/create_template`（`projectKeyPattern=<projectPattern>`，
   记 `template:created`）；对 `templatePermissions` 各调
   `permissions/add_user_to_template login=<user>`（grants 直发 user，
   **不经 group**）。
5. **`ensure-token`** —— `user_tokens/search` 查 `tokenName`；结合租户
   Secret 是否存在决定**复用**还是 **revoke+mint**。需要 mint 时：先调
   `compute_token_expiry()` 算 `today UTC + tokenDuration 天` →
   `user_tokens/generate type=USER_TOKEN login=<租户 user>
   name=<tokenName> expirationDate=<computed>`，把新值写到 tmpfs token
   文件，记 `token:<name>`。**`expirationDate` 始终在运行时算，避免把
   绝对日期写进 Pod spec / TaskRun 日志**（rework 反馈 R1，对齐 GitLab
   `tokenDuration` + `compute_token_expiry` 模式）。
6. **失败 trap** —— 步骤内任何非零退出，`trap` 触发 `rollback.sh`。

**步骤 1 — `apply-kubernetes-resources`**（`toolImage`）：以 field manager
`connector-auto` 把租户 `Secret`（`connectors.cpaas.io/bearer-token`）与
`sonarqube` `Connector`（`spec.auth.{name: tokenAuth, secretRef}`）SSA 到
`connector` 参数解析出的 namespace。

**步骤 2 — `write-results`**（`toolImage`）：输出 5 个 result（`tenant`、
`username`、`permission-template`、`token-name`、`connector-ref`）。

### 2.4 幂等与回滚模型

| 资源 | 幂等规则 | 回滚规则（仅本次新建） |
|-----|---------|---------------------|
| User | `users/search` 决定 create-or-reuse；`add_user permission=provisioning` 幂等 | `users/deactivate`（不真删，可重激活） |
| 全局 `provisioning` grant | 先 `permissions/users` 查；缺则授；新授时入状态文件 | `permissions/remove_user permission=provisioning` |
| Permission template | `search_templates` 决定 create-or-reuse；`add_user_to_template` 幂等 | `permissions/delete_template` |
| USER_TOKEN | 当且仅当 `user_tokens/search` 命中 **且** 租户 Secret 已持有非空 `token` 时复用；否则 revoke+mint（mint 时 `expirationDate` 由 `compute_token_expiry()` 算 `today + tokenDuration`）。**影响身份的输入**（`tokenName`、`tokenDuration`）强制重新签发 | `user_tokens/revoke`；不依赖项目预存在，无「鸡生蛋」 |
| 集群 Secret + Connector | SSA（field manager `connector-auto`）—— 多次 apply 等价 | 步骤 1 失败时**不**回滚 SonarQube 侧；重跑可自愈 |

**回滚总顺序（与创建相反）：** revoke token → delete template → remove
provisioning grant → deactivate user。被**复用**的既有资源**绝不被回滚
删除**。

### 2.5 失败模式

| 失败 | 表现 / 处置 |
|-----|-----------|
| Admin token 缺所需全局权限 | preflight 命中时拒跑；否则 SonarQube 返回 403、Task 原样暴露并 trap 回滚 |
| User/template 同名但语义冲突（如同名 user 非 local） | search 命中即复用；语义冲突原样暴露并退出 |
| SCIM/SSO 自动供给冲突（A2） | 实例可能拒绝 group/user 写入；原样暴露 + how-to 记录手动 fallback |
| 租户 user 无法移出 `sonar-users` | `api/user_groups/remove_user` 对默认组返回 `400 Default group cannot be used` —— scoping 不能靠「踢出 sonar-users」实现，必须靠部署前置条件 P2/P3 |
| Token 名称冲突 | `ensure-token` 先 search 并 revoke 同名再 generate |
| 步骤 1 集群 apply 失败 | SonarQube 侧设施已建但 Connector/Secret 未落；重跑自愈（user/template 复用、token 见 Secret 缺失则重签、步骤 1 重试） |
| operator 侧接线缺失 | `make manifests` 在 `sync_install_manifests.sh` 条目 + `values.yaml` 占位齐备前不拉 manifest；属 Story 4，gate `/feature:integrate` |

## 3. 任务拆解（16 项）

| # | 任务 | Story | Slice | Repo | 关联 AC |
|---|------|-------|-------|------|--------|
| 1 | Task 模板 `sonarqube-connector-automatic-creation.template.yaml`（参数表 + 5 results + 必绑 workspace + 可选 `kube-config`、非 root podTemplate、内存 `emptyDir` secrets 卷、cpu/mem requests+limits、3 步骨架含 `{{ INCLUDE }}`）；提交渲染后 Task YAML | 1 | backend | extensions | AC-1、AC-5 |
| 2 | `hack/render-task.sh` + `make render-tasks` + CI 漂移检查；接入 `make lint` | 1 | infra | extensions | — |
| 3 | `scripts/lib.sh` —— 避泄露日志、双挂载形态识别（统一文件名约定）、`curl --config` 封装、JSON 辅助、tmpfs 回滚状态追踪、**preflight()** | 1 | backend | extensions | AC-6（preflight） |
| 4 | `scripts/ensure-user.sh` —— create-or-reuse local user + 直接 grant 全局 `provisioning`（幂等）+ 校验该 user 直接全局权限仅有 `provisioning`、除 `sonar-users` 外不属其它组 | 1 | backend | extensions | AC-1、AC-2 |
| 5 | `scripts/ensure-template.sh` —— create-or-reuse template（`projectKeyPattern=<projectPattern>`）+ 经 `add_user_to_template` 把 `templatePermissions` **直接授给租户 user**（不经 group） | 1 | backend | extensions | AC-1、AC-4 |
| 6 | `scripts/ensure-token.sh` —— USER_TOKEN 生命周期：健康 + Secret 存在则复用；缺失/过期/影响身份变更则 revoke+mint。提供 `compute_token_expiry()`（`date -u -d "@$((now + tokenDuration * 86400))" +%Y-%m-%d`，busybox `-r` 兼容），mint 时把结果作为 `expirationDate` 传给 `user_tokens/generate`；值写 tmpfs | 1 | backend | extensions | AC-2 |
| 7 | `scripts/apply-kubernetes-resources.sh` —— 解析 `connector=<ns>/<name>`，SSA 租户 Secret（`connectors.cpaas.io/bearer-token`，名 `<name>-secret`）+ `sonarqube` Connector（`spec.auth.{name: tokenAuth, secretRef}`） | 1 | backend | extensions | AC-5 |
| 8 | `scripts/rollback.sh` + `scripts/write-results.sh` —— rollback 按相反顺序回退本次新建资源；write-results 输出 5 个 result | 1 | backend | extensions | AC-6、AC-7 |
| 9 | `connectors-sonarqube/tektoncd/kustomization.yaml`（对齐 Harbor/GitLab 形态） | 1 | infra | extensions | — |
| 10 | `testing/features/script.feature` —— Pod 级 helper 场景：ensure-* 的 create+reuse、`provisioning` grant 幂等、rollback 回退、apply 幂等、错误路径 | 2 | test | extensions | AC-8（helper） |
| 11 | `testing/features/tektoncd.feature` —— Task 契约 + e2e：单租户全新供给、幂等重跑、token 重新签发、部分失败回滚、多租户隔离、扫描期自动创建、错误路径 | 2 | test | extensions | AC-8（Task 契约 + e2e） |
| 12 | BDD fixtures `testing/features/testdata/*` | 2 | test | extensions | AC-8 |
| 13 | 概念页 —— 每租户模型、key-pattern 自动套用、与扫描时项目自动创建的关系 | 3 | docs | operator | AC-9 |
| 14 | how-to 页 —— TaskRun 操作步骤、**部署前置条件** checklist、运维手册 | 3 | docs | operator | AC-9 |
| 15 | 参考页 —— Task 调用的 SonarQube Web API + admin token 最小全局权限集 + workspace 文件名约定 | 3 | docs | operator | AC-9 |
| 16 | `sync_install_manifests.sh` 增条目 + `values.yaml` 占位 + `make manifests` + `hack/sync_sonarqube_connector_automatic_creation_task_doc.sh` + Makefile target + `cmd/kodata/...` | 4 | infra | operator | — |

> 任务 3 与 4 已拆分（原 POC 后版本把 lib + ensure-user 合并为一项）。
> 任务 16 把原任务 15 + 16 合并 —— 同 Story、同 slice、同 repo。

### 3.1 AC × 任务覆盖矩阵

| AC | 覆盖任务 | 备注 |
|----|---------|-----|
| AC-1（自动创建） | 4 + 5 | user 持全局 `provisioning` + key-pattern 模板；项目本身由扫描期自动创建 |
| AC-2（项目级 token + 项目专属权限） | 4 + 6 | 每租户 USER_TOKEN + user 仅持 `provisioning` + 模板直发 user |
| AC-3（共享基线 gate/profile） | — | **部署前置条件 P4 交付**（实例默认 gate/profile），非 Task 任务 |
| AC-4（namespace 项目受限） | 5 | key-pattern 模板 + 前置条件 P1（Private） |
| AC-5（Connector + Secret 落对 namespace） | 1 + 7 | — |
| AC-6（错误处理） | 3–8 | 测试用例 6–9 |
| AC-7（回滚） | 8 | 测试用例 4 |
| AC-8（集成测试覆盖多场景） | 10 + 11 + 12 | 测试用例 1–11 |
| AC-9（文档） | 13 + 14 + 15 | — |
| 构建/打包/接线（无 AC） | 2 + 9 + 16 | — |

**无孤立 AC；无孤立任务。**

## 4. 测试设计

### 4.1 各 Story 的测试方法

| Story | 测试方法 |
|-------|---------|
| Story 1（backend） | `script.feature`（godog）针对真实 SonarQube + kube API 检验每个 `scripts/*.sh` |
| Story 2（test） | `tektoncd.feature` 针对 kind 集群 + 真实 SonarQube 的端到端 TaskRun |
| Story 3（docs） | CI `mdx` lint；reporter 人工评审；how-to 步骤端到端走一遍 |
| Story 4（operator 接线） | CI 中 `make manifests` 产出非空 kodata；`make dist` 成功 |

### 4.2 测试格式

`script.feature` 与 `tektoncd.feature` 遵循 connectors-extensions BDD harness
（godog、`# language: zh-CN`、Allure 打标、CEL 资源断言表）。场景标题中文、
表头英文、选择器标签 `@sonarqube-connector-automatic-creation[-script|-tektoncd]`。

### 4.3 测试用例

| # | 优先级 | 名称 | 关键断言 | 方法 |
|---|-------|------|---------|------|
| 1 | p0 | 单租户全新供给 | user/template/token 创建；user 直接持全局 `provisioning` + 无其它全局权限 + 除 `sonar-users` 外不属其它组；template `projectKeyPattern` 正确；template 5 项项目级权限直发 user（**不经 group**）；Connector + Secret 创建 | `tektoncd.feature` e2e |
| 2 | p0 | 幂等重跑 | user/template 复用（含 `provisioning` grant）；token 不重签；无副作用 | `tektoncd.feature` |
| 3 | p0 | token 过期 / 缺失重签 | token 过期或租户 Secret 删除 → 重跑 revoke（若有）+ mint + 重写 Secret | `tektoncd.feature` + `script.feature` |
| 4 | p0 | 回滚 | 注入 `ensure-token` 失败 → 回退本次新建的 template / `provisioning` grant / user（复用的不动）；TaskRun `Failed` | `tektoncd.feature` + `script.feature` |
| 5 | p0 | 多租户隔离 | 供给 A、B；用 A 的 token 读 B pattern 下私有项目 → 拒绝（403/不可见） | `tektoncd.feature` |
| 6 | p0 | E2E — 扫描期自动建项目并被覆盖 | 命中 pattern 的 `sonar.projectKey` 跑真实 `sonar-scanner` → SonarQube 自动建 private 项目、自动套模板；租户 token 完成扫描 + 读 `api/measures` | `tektoncd.feature`（含 catalog `sonarqube-scanner` 串联） |
| 7 | p0 | Admin token 缺权限 | preflight 拒跑；或后续 API 返回 403 原样暴露、无残留 | `tektoncd.feature` |
| 8 | p0 | 非法参数 | 缺 `tenant` / `projectPattern` → 参数校验失败、无 SonarQube 调用 | `tektoncd.feature` |
| 9 | p1 | SCIM/SSO 自动供给冲突（A2） | 模拟实例拒绝 group/user 写入 → 原样暴露 | `script.feature` |
| 10 | p1 | helper：ensure-user/template create+reuse + `provisioning` 幂等 + `lib.sh` 双挂载识别 | 见列名 | `script.feature` |
| 11 | p1 | helper：ensure-token mint + reuse + revoke+mint + apply 幂等 SSA | 见列名 | `script.feature` |

### 4.4 E2E 决策

**是 —— 需要新 e2e 用例**，在 `connectors-extensions`：
- `testing/features/tektoncd.feature` —— 完整 TaskRun + 多租户隔离 + 扫描
  期自动建项目串联（用例 1–9）。
- `testing/features/script.feature` —— Pod 级 helper（用例 10–11）。

**理由：** Task 针对真实 SonarQube Web API 建 user/template、签 USER_TOKEN；
隔离、回滚、扫描期自动创建无真实 API 契约无法测试。

**`connectors-operator/test/integration` 不新增 e2e。**

## 5. 复审记录

### 5.1 当前快照

| 项 | 当前态 |
|---|-------|
| 账号模型 | Branch-3：每租户 1 user + key-pattern 模板（无 group） |
| 项目创建 | 由 SonarQube 在扫描期自动创建；Task 不亲自建 |
| scoping | 5 边界（→ product-design.md §6） + 5 条实例级前置条件（P1–P5） |
| Task 步骤 | 3 步（`ensure-tenant` 含 preflight + 4 ensure-* / `apply-kubernetes-resources` / `write-results`） |
| Task 参数 | 9 项（其中 7 项默认派生），admin Connector 不进参数；`tokenDuration` 取代 `tokenExpiry`（天数 + 运行时算 `expirationDate`） |
| Task results | 5 项 |
| 工具镜像 | 单一 catalog alpine `kubectl` 镜像 |
| 任务拆解 | 16 项 |
| 测试用例 | 11 项（p0×8 + p1×3） |
| 待 design-review 项 | A2 / A4 / A5 / A8 / A9 |

### 5.2 时间线

<!-- 若测试设计在 implement 期间被修改，design reviewer 在此重新签字。 -->

- **2026-05-21** — 初版设计。
- **2026-05-22** — 经 POC 整体改写为 Branch-3 / 每租户模型；实例默认值改为
  部署前置条件。
- **2026-05-22（清洁复测后追改）** — `ensure-user` 时直接 grant 全局
  `provisioning`（清洁复测确认是触发扫描期自动创建的必要条件）；「去 group」
  追测后移除租户 group，`ensure-template` 改用 `add_user_to_template` 直发
  user；任务拆解 17 → 16；`sonarqube-config` 加 Secret 直挂形态；Task results
  加 `username`。
- **2026-05-22（5 项精化 + 8.9 验证）** — 加 `lib.sh::preflight()`（A9）；
  明确「无续期 API → revoke+mint + SSA 重写 Secret」；前置条件从「`sonar-users`
  无全局权限」泛化为「默认组（`sonar-users` + `Anyone`）皆无 + Default
  Template 无默认组 grants」（8.9 POC 暴露的隔离漏洞，→ poc.md B.2 #4）；
  集群侧 RBAC 显式列出。SonarQube 8.9.2 端到端实测 PASS。
- **2026-05-22（offboarding 改文档化清理脚本）** — driver 决议不发布独立
  下线 Task；改在 how-to + poc.md 步骤 5 提供对称清理脚本；
  threat-model.md T13（下线 Task 部分失败）随之删除。任务拆解维持 16 项。
- **2026-05-22（文档整体优化）** — 三份文档结构对齐，每个事实只在一份
  文档承载；任务拆解单元格精简；AC 覆盖、测试用例、复审快照改为表格。
- **2026-05-22（design-review R1 — rework）** — driver 反馈
  `tokenExpiry` 写绝对 `YYYY-MM-DD` 会进 TaskRun 日志、不能自动轮换。
  对齐 GitLab `gitlab-connector-automatic-creation` Task 既有惯例
  （`tokenDuration` + `compute_token_expiry`）：把参数改为 `tokenDuration`
  天数，`ensure-token.sh` 每次 mint 时算 `today UTC + N 天` 作为
  `expirationDate` 传给 SonarQube。cron Task 重跑自动顺延，无绝对日期
  落到日志。Harbor 同类 Task `robotAccountDuration` 直接传给 Harbor API
  （Harbor 原生接受 duration）；本 Task 与 GitLab 一样需脚本换算成
  绝对日期，因为 SonarQube `user_tokens/generate` 只接受
  `expirationDate=YYYY-MM-DD`（POC 实测）。design-review.md 记录 outcome
  = rework。任务拆解 + 测试用例不变。
