# 技术设计 — Nexus 自动创建 Project + Connector + Secret

<!--
由 /feature:design 写出。Goal 与 product-design.md 同步；本文件补充架构、任务拆分、测试设计。
-->

## 目标

（与 `product-design.md ## 目标` 同步，复述于此）

提供一个 Tekton Task `nexus-connector-automatic-creation/0.1`，面向 **Nexus Repository Manager 3.76 社区版（OSS / CE）**。给定一个 Nexus 管理员 Connector 作为入参，该 Task 为目标项目按其声明的制品格式（maven / npm / pypi / raw 等）创建一组项目专属仓库（hosted；按需共享中央代理；可选 group），通过 Nexus 原生权限模型（user + role + privilege + content selector）创建一个**仅作用于该项目**的 Nexus 本地用户，并把对应的 Connector 与 Secret 通过 `kubectl apply --server-side` 回写到项目所在的 namespace。**不**依赖任何 Nexus PRO 能力，**不**引入 parent-project / tenant 层级；部分失败的恢复模型为 **idempotent rerun + 显式依赖图清理**（沿用 Harbor / GitLab 前作），而非事务回滚。

## 架构

### 涉及组件

- **`connectors-extensions/connectors-nexus`** — **新建 `tektoncd/` 子树**（该仓库当前无 tektoncd 目录）：
  - `tektoncd/kustomization.yaml`
  - `tektoncd/tasks/nexus-connector-automatic-creation/0.1/nexus-connector-automatic-creation.template.yaml` —— Task 模板源文件，使用 `{{ INCLUDE: scripts/<name>.sh }}` 占位符引用 helper 脚本。
  - `tektoncd/tasks/nexus-connector-automatic-creation/0.1/nexus-connector-automatic-creation.yaml` —— 渲染产物（提交入库；CI 校验 `make render-tasks` 输出一致）。
  - `tektoncd/tasks/nexus-connector-automatic-creation/0.1/scripts/{lib,ensure-nexus-resources,ensure-nexus-user,apply-kubernetes-resources,write-results}.sh` —— 源 helper 脚本（plain `.sh`，可 review / lint / shellcheck）。
  - `tektoncd/tasks/nexus-connector-automatic-creation/0.1/samples/` —— TaskRun 示例（含每种格式的最小用例 + 多 format 复合用例）。
  - `tektoncd/tasks/nexus-connector-automatic-creation/0.1/testing/features/{script,tektoncd}.feature` + `testdata/` —— BDD。
  - `hack/render-task.sh`（≤50 LOC；GitLab 同款，按占位符内联 `.sh` 进 step 的 `script: |`）。
  - **不引入 `images/nexus-cli/` 容器化目录** —— 复用 catalog 已发布的 `kubectl` + `curl` 工具镜像（curl 直接打 Nexus REST，绕开"维护一个 nexus-cli Containerfile"的成本）。
- **`catalog`（alaudadevops/catalog）** —— **不动**。Task 用 `curlImage` + `kubectlImage` 参数指向 catalog 已发布的 `catalog.tekton.dev/tool-image-{curl,kubectl}` ConfigMap（在 `kube-public` namespace）。
- **`connectors-extensions/connectors-nexus`（现有，未改）** —— `config/connectorclass/connectorclass.yaml` 已暴露 `nexusconfig` / `npmrc` / `pipconf` 等多 protocol configuration；新 Task **消费**这些定义，**预期不修改 ConnectorClass**（Story 3a 在实现前 grep 校验，若发现需新增字段则跨仓库挂依赖）。
- **`connectors`** —— **不动**。proxy 与 CSI driver 原样复用。
- **`connectors-operator`（本仓库）** —— pipeline wiring only：
  - `hack/sync_install_manifests.sh` —— 新增一行：`sync_install_manifests "connectors-nexus-tektoncd" "connectors-nexus-tektoncd"`。
  - `values.yaml` —— 在 `global.images` 下新增 `nexus-connector-automatic-creation` 占位条目（与 Harbor / GitLab 平行）。
  - `hack/sync_nexus_connector_automatic_creation_task_doc.sh` —— 新文档同步 helper，镜像 Harbor / GitLab 同名脚本。
  - `cmd/kodata/connectors-nexus-tektoncd/1.0.0/install.yaml` —— 上述三项就绪后由 Nexus 自动同步产出（CLAUDE.md "NEVER edit `cmd/kodata/`" 规则照旧）。
- **`connectors-plugin`** —— **不动**。本特性无 UI 故事。

### 调用路径

**构建期**：
- `make render-tasks`（新增）→ `hack/render-task.sh` 读取 `nexus-connector-automatic-creation.template.yaml`，把每个 `{{ INCLUDE: scripts/<name>.sh }}` 占位符替换为对应 `.sh` 内容，写出 shippable `nexus-connector-automatic-creation.yaml`。每个 step 的 `script: |` 完全自包含 —— 没有 init step，没有跨 step 状态依赖（除了显式 emptyDir tmpfs 中转 token）。
- CI 校验 `make render-tasks` diff 为空（否则 PR 拒绝）。

**运行期（单次 TaskRun）**：

```
TaskRun (SA = connectors-management/automation-sa)
  │
  ├─ step 1 [curlImage] verify-admin
  │     ├─ load admin creds from /workspace/nexus-config/{username,password} (CSI mount)
  │     ├─ GET /service/rest/v1/status (Nexus 健康)
  │     ├─ GET /service/rest/v1/security/users/$adminUser (确认 admin 存在 + 有权限)
  │     ├─ 探测匿名用户启用状态 → 写 anonymous-policy-warning 入 emptyDir
  │     └─ 失败立即退出（任何远端创建之前）
  │
  ├─ step 2 [curlImage] ensure-nexus-resources
  │     注：`projectID` 与所有 `pathPrefix` 来自 Task 入参（`product-design.md ## 用户可见接口 ### Tekton Task 参数`），
  │     不在 step 内推断。
  │     **POC 修正（H3）**：原拟 regex `^/[a-z0-9._/-]+/$` **不安全** —— `..`、CSEL 关键字 `and`/`or`/`not` 作为 path
  │     段可逃逸；而 Nexus CSEL parser **不做 path 语义校验**（live 实测 `path =^ "/foo/" or path =^ "/"` POST 204
  │     广播到所有路径），regex 是唯一防线。改用：
  │       (a) regex `^/([a-z0-9._-]+/)+$`（character class 内**不含** `/`；段必须非空），
  │       (b) post-check：path 不含字面 `..` 任何 segment 不等于 `and` / `or` / `not`（小写关键字）。
  │     helper `lib.sh::validate_path_prefix` 同时实施 (a) + (b)；同时校验 `pathPrefix` 中无 `"`、`\`、空白、其它 CSEL 算子。
  │     For each nexusRepositories[i] = {name, format, type, scope, pathPrefix, retainAccess, proxyRemoteUrl}:
  │       ├─ format ∈ {maven2,npm,pypi,raw}, scope = "shared-csel":
  │       │     ├─ ensure hosted repo `proj-<projectID>-<name>` (GET-first → POST or PUT)
  │       │     ├─ ensure content-selector `proj-<projectID>-csel-<name>` with expression
  │       │     │      `format == "<format>" and path =^ "<pathPrefix>"`
  │       │     │   (注意：CSEL 算子为 `and`/`or`，禁用 `&&`；pathPrefix 已过白名单)
  │       │     ├─ ensure privilege (csel) `proj-<projectID>-csel-priv-<name>` actions=retainAccess
  │       │     └─ ensure privilege (view) `proj-<projectID>-view-priv-<name>` actions=[browse,read]
  │       └─ format ∈ {docker,gitlfs} OR scope = "dedicated":
  │             ├─ ensure hosted repo `proj-<projectID>-<name>` (独立)
  │             └─ ensure privilege (view) `proj-<projectID>-view-priv-<name>` actions=[browse,read,edit,add,delete]
  │     For each groupRepositories[g] = {name, format, members[], withCsel}:
  │       ├─ ensure group repo `proj-<projectID>-group-<name>` 内含 members[]
  │       ├─ withCsel == true（tight）：
  │       │     ├─ 为该 group 物化 N 条 priv，N = members[] 中归属本 projectID 的 shared-csel repo 数；
  │       │     │     每条 priv 类型 `repository-content-selector`，repository=group,
  │       │     │     contentSelector=与原 repo 同名 csel（即 `proj-<projectID>-csel-<member.name>`），actions=[browse,read]
  │       │     └─ 非本 projectID 的 members（如共享 `maven-central` 上游）不在此 group-CSEL 内 → 透过 group URL 对那些 members 默认无 read
  │       └─ withCsel == false（blanket）：
  │             └─ ensure privilege (view) `proj-<projectID>-group-view-priv-<name>` actions=[browse,read]（blanket 入口；接受 leakage 风险换简单）
  │     emit per-repo / per-group result lines on stdout (LOG-pattern 化便于 BDD 断言)
  │
  ├─ step 3 [curlImage] ensure-nexus-user
  │     注：`userId` = Task 入参 `nexusUser`（默认 `connector-<connector-ns>-<connector-name>`，与 Harbor `robotAccount`/GitLab `accessTokenName` 命名风格一致）。
  │     **POC 修正（H1 invalidated）**：Nexus 3.76 OSS User API **无 `description` 字段**，silently dropped。
  │            身份指纹改存到 **Role 的 description** 上（Role 是本流程已经要创建的对象，0 额外 API 调用）。
  │     注：身份指纹存放策略 —— 在 **role `proj-<projectID>-role`** 的 `description` 字段以
  │            `OWNER=connectors-operator;FP=<identity-suffix>;CONN=<conn-ns>/<conn-name>` 形式存放。
  │            **长度约束（POC H1.5）**：Nexus role.description 底层是 `VARCHAR(400)`，> 400 字符返回 H2
  │            异常 500。`lib.sh::write_fingerprint` 在拼接后断言 `len(desc) <= 380`（留 20 char safety margin）。
  │     注：身份比对预解读（POC H2.2 + H2.4）—— Nexus 创建时不传 description 会**默认填 role id**（不是 null）。
  │            判定 owned-by-us 的 predicate 必须是 `description.startswith("OWNER=connectors-operator;")` 或
  │            完全等于 `connectors-operator`，**不能**用 "null / empty" 判别。
  │     ├─ identity-suffix = sha256(
  │     │      format-set ∥ scope-set ∥ retainAccess-set ∥
  │     │      pathPrefix-set ∥ group-policy-set(name,format,members,withCsel) ∥
  │     │      nexusUser-override
  │     │   )[:12]  # 12 hex chars = 48 bits
  │     ├─ existing **role** `proj-<projectID>-role` (GET → 解析 description)?
  │     │     ├─ no role 或 role.description 不以 `OWNER=connectors-operator;` 开头 但 role 存在 →
  │     │     │       抛 actionable error "role owned by external party; rename projectID or remove"（反 squatter）
  │     │     ├─ role.description 解析出 FP 与 input identity-suffix 不等 (identity-changed) →
  │     │     │     DELETE existing user + role + privs + csels in 反向依赖顺序,
  │     │     │     re-create as new identity (status=recreated reason=identity-changed)，写新 role.description
  │     │     ├─ no role at all → POST /v1/security/roles (含 description)，再 POST /v1/security/users (空 description，
  │     │     │     User API silently 丢弃也无所谓，userId 唯一身份在 role 这边)，status=created
  │     │     └─ match → 重置 user password (PUT .../change-password)，refresh role.privileges
  │     │              (status=rotated reason=identity-match)
  │     ├─ write tmpfs `/tmp/state/nexus-token`（emptyDir.medium: Memory）；`{ set +x; ...; } 2>/dev/null`
  │     │     bracket 包裹任何 password 写文件 / 拼接 / curl basic-auth header 的命令
  │     └─ 错误分类：500 + body 含 `DuplicateUserException` →
  │                   GET role.description 校验 owner；如 owner=connectors-operator 走 identity-changed recreate；否则抛 squatter
  │                500 + body 含 `... is in use` → 走依赖图反向清理重试
  │                500 + body 含 `Value too long for column "DESCRIPTION"` → 上抛 client bug；本 helper 应已预检 380 char cap
  │                500 其它 → 上抛 fail Task
  │
  ├─ step 4 [kubectlImage] apply-kubernetes-resources
  │     ├─ 读 tmpfs token + workspace nexus-config 中的 connector-class / ns 信息
  │     ├─ Connector + Secret 落 `connectors-management` namespace（不写项目 namespace；与 Harbor / GitLab 前作一致；
  │     │     下游应用通过 connectors-proxy + CSI 间接消费 — 项目 namespace 内**不**留 raw 凭据 Secret）
  │     ├─ 在 `{ set +x; ...; } 2>/dev/null` bracket 内：渲染 Secret manifest（kubernetes.io/basic-auth）+ Connector manifest，
  │     │     通过 **进程替换** + stdin 喂给 kubectl（**禁止 `<<<` here-string**，否则 verbose-mode 下 xtrace 会把 base64 password 印到 stderr）：
  │     │       kubectl apply --server-side --field-manager=connectors-operator -f - < <(printf '%s\n' "$rendered")
  │     │   （server-side-apply 在 stable field-manager 上保证 rerun 幂等 + 暴露 field 冲突）
  │     └─ 校验：再次 GET Connector，断言 status.phase 进入 Ready 时限内
  │
  └─ step 5 [curlImage] write-results
        ├─ 从 tmpfs 文件读取所有上游 step 写入的状态：
        │     /tmp/state/nexus-repositories.txt  # step 2 写
        │     /tmp/state/nexus-user.txt         # step 3 写（仅 user 名，不含 password）
        │     /tmp/state/anonymous-warning.txt  # step 1 写（统一通过 tmpfs，不走 stdout）
        │     /tmp/state/connector-ref.txt      # step 4 写
        ├─ 在 `{ set +x; ...; } 2>/dev/null` bracket 内写 Tekton results；
        │     **禁止** 在 verbose=true 时把 results 内容 echo 到 stdout（results 已经被 Tekton 抓取）
        └─ exit 0
```

### 失败模式

| 场景 | 处理 |
|------|------|
| admin Connector 不可达 / 凭据错误 | step 1 退出，0 远端写入；TaskRun Failed，log 输出可操作 hint |
| Nexus 返回 **500** + `DuplicateUserException` | step 3 解析 body → 走 identity-changed recreate 路径，**不**重试相同 POST |
| Nexus 返回 **500** + `Content selector ... is in use` | step 2/3 走依赖图反向清理（user → role → priv → csel）后重试当前 op |
| 创建 repo 后 csel 失败 | 当前 TaskRun fail；下次 rerun step 2 检测到 stale repo（命名前缀匹配但 csel 缺失）→ 走 update-or-recreate 路径 |
| 创建 user 后 K8s apply 失败 | 当前 TaskRun fail；下次 rerun step 3 检测到 user 已存在 + 身份匹配 → status=rotated；step 4 重新 SSA |
| 不同 owner 已占用同名 repo / user / role | 沿用 GitLab retrospective 教训：**显式 ownership 校验**（描述字段或自定义元数据中存放 owner fingerprint），不静默 adopt → 抛 actionable error |
| CSEL 表达式语法错（误写 `&&` 而非 `and`） | step 2 在 first-call 失败时把 Nexus error body 完整透传到 log；CI BDD 用一条 negative case 守护 |
| 匿名用户启用 | step 1 检测，写 warning result；TaskRun 继续；threat-model 在 sign-off 阶段评估 |
| TaskRun 中途被 cancel / pod evict | 已 emit 但未 result-written 的远端对象在下次 rerun 通过命名前缀 list-and-reconcile 被采用 |
| Nexus 端 admin 凭据被外部轮换 | step 1 立即失败；运维 runbook（Story 5 文档）记录如何更新 CSI 挂载 |
| 网络 partial 写入（POST 200 但 connection drop） | 下次 rerun GET 检测到已存在 → 走 update / rotate 路径，无副作用 |
| **stale role/priv 引用残留**（外部直接 DELETE 了 role 但 user 上仍引用同名 role） | step 3 在比对身份前先 list 项目命名前缀下所有对象 → 与 description.OWNER+FP 匹配集校验；不匹配则触发依赖图反向清理后重建 |
| **`nexusRepositories[]` 在 rerun 间收缩**（一条 entry 被删除）| 默认 **converge-to-input**：step 2 在创建路径前先 list 项目下命名前缀对象，与本次输入集 diff，删除孤儿 csel / priv（**保留** repo 自身以避免误删制品）。该策略写进 how-to 文档，避免 user surprise |
| Tekton TaskRun results 历史泄露元数据（user 名 / connector-ref / 警告文本） | results 内**不**含 password；user 名是公开 fingerprint；threat-model T6 兜底 |

## 任务拆分

> 每条 task 映射到一个 story + repo + slice，invariant 见 `_shared.md`。
>
> **Implementation 阶段退出门（driver 2026-05-21 决策）**：本 feature 进入 `/feature:implement` 后，**每个 story 的退出**必须同时满足四点 —— (1) 代码合入；(2) 对应 BDD（`script.feature` / `tektoncd.feature`）在 CI 上跑绿；(3) 至少一轮独立 agent review（`code-review-subagent` + 项目层 `connectors-code-review` agent，sensitive risk 必须叠加 security 角色 review）+ 处置表记录；(4) 在 driver 提供的 live `devops-nexus` 实例上完成 manual smoke（用 connectors-ai 的 `/connectors-implement-manual-testing` skill），证据记入对应 PR 描述。**不**允许把 review / manual verification 推迟到 `/feature:qa` 或更晚 —— 与本设计阶段 POC-in-design 同理（在拥有变更的阶段抓真实环境破坏，而不是 2-3 个 stage 之后）。同改进意见已记入 `docs/en/design/improvement-log.md`。

> 按 4-pillar 退出门重新组织：每个 story 的最后两条 task（标 **exit-gate**）是 "多轮 agent review" 与 "真实环境 manual smoke"，这两条**不**作为可选 follow-up，**就是**该 story 的退出条件，必须先于下一个 story 启动。

| # | Task | Story | Slice | Repo | 理由 |
|---|------|-------|-------|------|-----|
| **Story 1** —— Task + scripts + BDD（实现 + 自动化测试同包）|||||
| 1.1 | 新建 `tektoncd/` 子树，配置 `kustomization.yaml`、`hack/render-task.sh`、Task 模板骨架 | 1 | backend | connectors-extensions | Nexus 扩展首个 Tekton 资产；scaffold 一次复用到后续 Task |
| 1.2 | 实现 `scripts/lib.sh`（curl 包装、错误体解析、命名约定常量、ownership fingerprint helpers、`validate_path_prefix` / `validate_project_id` / `validate_nexus_user` / `build_csel_expression` / `write_fingerprint` 380-char 校验）| 1 | backend | connectors-extensions | 所有后续 step 都依赖此库；隔离 Nexus 怪癖（500≠故障）；POC H3 注入防御 |
| 1.3 | 实现 `scripts/verify-admin.sh`（step 1，含匿名探测 + `requireAnonymousDisabled` opt-in）| 1 | backend | connectors-extensions | 失败前置；零远端副作用 |
| 1.4 | 实现 `scripts/ensure-nexus-resources.sh`（step 2，按 format dispatch + group repo + CSEL 路径白名单）| 1 | backend | connectors-extensions | 业务核心；含 CSEL 表达式构造、`and` 算子守护、POC H3 regex tightening |
| 1.5 | 实现 `scripts/ensure-nexus-user.sh`（step 3，三路 identity 生命周期 + Role.description 指纹 carrier + 依赖图反向清理）| 1 | backend | connectors-extensions | 唯一权变更点；引用前作 GitLab `ensure-gat.sh`；POC H1 carrier 修正 |
| 1.6 | 实现 `scripts/apply-kubernetes-resources.sh`（step 4，SSA + `kubectl auth can-i` preflight + process-substitution 防 set-x 泄密）| 1 | backend | connectors-extensions | Connector + Secret 回写；security mitigation 4 + 6 落点 |
| 1.7 | 实现 `scripts/write-results.sh`（step 5，从 tmpfs 汇总 results + 退出前 shred token）| 1 | backend | connectors-extensions | 完成 Task contract；security mitigation 16 落点 |
| 1.8 | 渲染产物 `nexus-connector-automatic-creation.yaml` 提交 + CI render-diff 守护（`connectors-extensions / lint-and-test`）| 1 | backend | connectors-extensions | build-time 契约；GitLab 前作同 |
| 1.9 | `script.feature` —— 每个 helper 脚本的 Pod-level 单元行为（针对 live `devops-nexus`）；含 TC 8-21、29-33（所有 helper-side 反例 + 自愈 + ownership-conflict + 收缩 input）| 1 | test | connectors-extensions | BDD 与代码同 PR 提交（沿用 GitLab 前作 consolidate 模式） |
| 1.10 | `tektoncd.feature` —— 完整 TaskRun 端到端 + Task contract + multi-format smoke + group repo opt-in + 下游工具 smoke pod（TC 1-7, 22-28）| 1 | test | connectors-extensions | 同 PR 提交 |
| 1.11 | testdata + 多 format / 多 project 复合场景 + ownership-conflict / partial-fail / 收缩 input fixture | 1 | test | connectors-extensions | 与 1.9 / 1.10 同 PR |
| **1.exit-A** | **Multi-round agent review**：`code-review-subagent`（framework tier）+ `connectors-code-review`（project tier）+ security 角色 review pass（risk=sensitive 强制）；处置表追加到 `_review-disposition-round2-implement.md` | 1 | review | connectors-extensions | 4-pillar 退出门 P3 |
| **1.exit-B** | **Manual smoke on live `devops-nexus`**：via connectors-ai `/connectors-implement-manual-testing` skill，按 Jira AC + V0.1 决策表 D1/D2/D3 三场景 hands-on 跑一遍；截图 / 日志记入 PR 描述 | 1 | manual | connectors-extensions | 4-pillar 退出门 P4 |
| **Story 2** —— BDD harness（自动化测试基础设施）|||||
| 2.1 | `connectors-nexus/testing/` 落地连接配置（指向 driver 提供的 live `nexus-1-nxrm-ha`）+ 命名前缀隔离 `bdd-<short-sha>-` + setup / teardown 脚本 | 2 | test | connectors-extensions | driver 在 Jira 评论中明确指定使用该 live 实例；不另起 kind+Helm |
| 2.2 | godog runner 在 connectors-extensions `Makefile` 中加 `make test` 入口；`testing/AGENTS.md` 更新跑法 | 2 | test | connectors-extensions | 与 1.9 / 1.10 必需联动 |
| **2.exit-A** | Review pass（`code-review-subagent`）+ 处置 | 2 | review | connectors-extensions | 4-pillar 退出门 P3 |
| **2.exit-B** | Manual smoke：CI 内 + 本地各跑一遍 `script.feature` + `tektoncd.feature`，确认 33 个 TC 全绿 | 2 | manual | connectors-extensions | 4-pillar 退出门 P4 |
| **Story 3** —— 文档（docs slice）|||||
| 3.1 | 概念文档 `docs/en/connectors/concepts/nexus-cli-config.mdx` + 中文同步 | 3 | docs | connectors-extensions（源）| 与 Harbor `harbor-cli-config` / GitLab `glab_cli_config` 同形 |
| 3.2 | how-to 文档 `docs/en/connectors/how-to/automatic-create-nexus-projects.mdx` + 中文同步 + migration callout（手工已存在的 `proj-foo-maven` 怎么 takeover）| 3 | docs | connectors-extensions（源）| 含 TaskRun 示例 + cron 模板 + 运维 runbook + 手工兜底 |
| 3.3 | release-note 入口 `release-notes.md` 追加新 Task 摘要 + D3 anonymous warn-not-modify 行为 + `requireAnonymousDisabled` opt-in | 3 | docs | connectors-extensions（源）| product reviewer round-1 要求 |
| **3.exit-A** | Doc review：product 角色 reviewer 跑一遍 mdx lint + 内容审；处置表追加 | 3 | review | connectors-extensions | 4-pillar P3 |
| **3.exit-B** | How-to dry-run：按 how-to 文档**字面**指引在 live `devops-nexus` 上从零跑一遍（新建一个 `bdd-doc-dryrun-<sha>-` 项目），确认每个步骤可执行、命令可粘贴；任何卡点回 3.2 修文档 | 3 | manual | connectors-extensions | 4-pillar P4；连锁验证文档质量与实际行为一致 |
| **Story 3a**（**条件**，若 grep 发现 `nexusconfig` 缺字段）|||||
| 3a.1 | 跨仓库依赖：在 connectors-extensions/connectors-nexus 中补 `nexusconfig` ConnectorClass 字段 | 3a | backend | connectors-extensions | retrospective 教训：grep-verify 而非假设 |
| **3a.exit-A** | Review + Manual smoke | 3a | review+manual | connectors-extensions | 4-pillar 收尾 |
| **Story 4** —— operator wiring（cross-repo）|||||
| 4.1 | `connectors-operator/hack/sync_install_manifests.sh` 加 entry + `values.yaml` 加 `nexus-connector-automatic-creation` stub | 4 | backend | connectors-operator | 触发 `cmd/kodata/connectors-nexus-tektoncd/` 自动同步 |
| 4.2 | operator-side `hack/sync_nexus_connector_automatic_creation_task_doc.sh` | 4 | docs | connectors-operator | 镜像 Harbor / GitLab 同名 helper |
| **4.exit-A** | Review：`code-review-subagent` + `connectors-code-review`（强制，因为 operator-side 更改）| 4 | review | connectors-operator | 4-pillar P3 |
| **4.exit-B** | Manual smoke：触发 PR 上 `/test sync-install-manifests` PaC trigger，确认产出的 `cmd/kodata/connectors-nexus-tektoncd/1.0.0/install.yaml` 含本次 Task；本地 `make dist` + apply 一遍确认 Task 在集群可见可 trigger | 4 | manual | connectors-operator | 4-pillar P4 |

### 目标覆盖检查

将 Jira AC 映射到本设计的 task；注意 AC-3 / AC-4 / AC-7 / AC-8 原文以"parent project / multi-level hierarchy / rollback"措辞，本设计已在 `product-design.md` 范围外章节解释了 reframe 思路 —— 这里映射的是 **reframed** 版本。

> 注：AC-3 / AC-4 / AC-7 / AC-8 reframe 的详细原文对照见 `product-design.md ## 对 Jira AC 的覆盖与改写`。此处仅做 task / TC 映射。

- **AC-1**（Nexus repository can be created automatically via Task for a given Project / namespace）→ tasks 1.4, 1.8；测试用例 **4** (单 maven smoke), 5, 7, 8。
- **AC-2**（Project-scoped credentials are created with repository-specific permissions）→ tasks 1.4, 1.5；测试用例 8, 9, 13, 14。
- **AC-3 (reframed)**（项目用户能通过 settings.xml / .npmrc 等下游工具配置 merge 访问共享 upstream proxy）→ tasks 1.4, 1.6, 3.1；测试用例 **26**（group withCsel=true）+ **28**（smoke pod 跑 `mvn dependency:get` / `npm install` 验证下游工具能用渲染出的 settings.xml / .npmrc）。
- **AC-4 (reframed)**（项目用户的读写权严格约束在项目自有路径前缀，不能跨项目）→ tasks 1.4, 1.5；测试用例 9, 10, 11, 12, 14。
- **AC-5**（Connector + Secret reconciled into the right namespace as part of provisioning）→ tasks 1.6；测试用例 5, **22**（SSA 幂等），4（端到端 results 含 connector-ref 检查）。
- **AC-6**（Error handling for API failures and permission conflicts）→ tasks 1.2, 1.3, 1.4, 1.5；测试用例 16, 17, 18, **19** (CSEL `&&` lint，提级至 p0)，**29**（ownership-conflict）。
- **AC-7 (reframed)**（部分失败的恢复 = idempotent rerun + 依赖图反向清理；非事务回滚）→ tasks 1.2, 1.4, 1.5；测试用例 7, 13, 16, 17, 20, 21, **30**（partial repo+csel-fail rerun 自愈）, **31**（user+apply-fail rerun 走 rotated 路径）, **32, 33**。
- **AC-8 (reframed)**（集成测试覆盖多项目 × 多 format scoping 组合）→ tasks 1.9, 1.10, 1.11, 2.1；测试用例 5, 7, 9, 10, 14, 25, 26, 27 全套。
- **AC-9**（Documentation includes Nexus API usage and examples）→ tasks 3.1, 3.2, 3.3；docs review (3.exit-A) + release-note + migration callout（product-design.md §文档页面）。
- **build-time render contract** → task 1.8；CI job `connectors-extensions / lint-and-test` 在 `connectors-nexus/tektoncd/...` 子树下执行 `make render-tasks && git diff --exit-code`，diff 非空即 fail。
- **pipeline-wiring (operator-side)** → tasks 4.1, 4.2。
- **4-pillar 退出门**（driver 2026-05-21 决策）→ tasks `*.exit-A`（review）+ `*.exit-B`（manual smoke）每个 story 各一对，不可省略。

无孤儿 AC，无孤儿 task。

## 测试设计

### 各 Story 测试方法

- **Story 1（backend — Task + scripts）**。Pod-level 助手脚本场景写在 `script.feature`（godog 跑），针对真 Nexus 3.76 CE 实例验证 shell 行为：幂等性、参数校验、错误分类、依赖图反向清理。
- **Story 2（test — BDD）**。端到端 TaskRun 写在 `tektoncd.feature`，针对一个 kind 集群 + 已部署 Nexus 3.76 CE 实例（用 `connectors-nexus/testing/init/` bootstrap 脚本预置；初始化包含 admin user + nexusconfig ConnectorClass）。
- **Story 3（docs）**。CI 跑 `mdx` lint；jtcheng 在 design-review 时人工 review；how-to 中的 TaskRun 示例在 acceptance 阶段端到端跑一遍。
- **Story 4（operator pipeline wiring）**。CI 跑 `make manifests` 期望产出非空的 `cmd/kodata/connectors-nexus-tektoncd/1.0.0/install.yaml`；`make dist` 产出含本组件；doc-sync helper 跑通。

### 测试格式

`script.feature` 与 `tektoncd.feature` 都遵循 **connectors-extensions BDD harness**（godog runner，`cd connectors-extensions/testing && make test` 跑），Gherkin 形态沿用 Harbor / GitLab：

- 顶部 `# language: zh-CN`；场景标题中文（`场景:`），表头英文。
- Allure 标签：`@allure.label.epic:NexusConnectorAutomaticCreationTask` + `@priority-high|medium|low` + `@automated|@manual`。
- Selector 标签：`@nexus-connector-automatic-creation`、`@nexus-connector-automatic-creation-tektoncd` / `@nexus-connector-automatic-creation-script`，加 per-scenario 标签（`@params`、`@workspaces`、`@results`、`@scoping`、`@error-handling`、`@identity-lifecycle`、`@dependency-cleanup`）。
- CEL 断言：`资源检查通过` 管道表对资源（`obj.spec.*` / `obj.status.*`）跑 CEL，含 `interval` + `timeout` 列。
- Pod / TaskRun outcome 断言：Pod 场景断言 `$.status.phase == Succeeded|Failed` + 命名容器日志正则；TaskRun 断言 step 退出码 + results + post-run 资源状态（CEL）。
- testdata 用相对路径（`../testdata/<scope>/<file>.yaml`），便于 review。

### 具体测试用例

> 编号以 p0 / p1 / p2 标注优先级；method 即 `script.feature` / `tektoncd.feature` / `manual`。

#### Task contract（`tektoncd.feature`）

> 与 GitLab 一致：每个 `场景:` 行明确写 CEL target 而不仅承诺"会断言"。

1. **(p0)** `场景: Task 应声明 11 个 params` — CEL：`obj.spec.params.size() == 11` + 每条 param `name in ['connector','secret','verbose','imagePullPolicy','curlImage','kubectlImage','projectID','nexusUser','nexusRepositories','groupRepositories','requireAnonymousDisabled']` + 类型 + 默认值表（与 product-design.md §Tekton Task 参数 表一致）。method: `tektoncd.feature`。
2. **(p0)** `场景: Task 应声明 2 个 workspaces` — CEL：`obj.spec.workspaces.exists(w, w.name == 'nexus-config' && w.optional == false)` + 同形断言 `kube-config` `optional == true`。method: `tektoncd.feature`。
3. **(p0)** `场景: Task 应声明 3 个 results` — CEL：`obj.spec.results.size() == 3` + 每个 result `name in ['nexus-repositories','nexus-user','connector-ref']` + per-result `description` 非空。method: `tektoncd.feature`。注：原设计列入第 4 个 result `anonymous-policy-warning`，v0.1 未落地（DEVOPS-44183），匿名检测改为 step 1 verify 日志一行 WARN（log-only）；test 24 已相应改写为日志断言。

#### 端到端 smoke（`tektoncd.feature`）

4. **(p0)** Task 应完成 Nexus 与 Kubernetes 资源初始化 — 单 maven2 hosted repo + scoped user + Connector + Secret；状态 Succeeded；results 完整。method: `tektoncd.feature`。
5. **(p0)** Task 应完成多 format 复合初始化 — `[maven2, npm, pypi, raw]` × 1 project；Task 内按 format dispatch，5 + 5×3 = 20 个 Nexus 对象按命名约定列出。method: `tektoncd.feature`。
6. **(p0)** Task 应在 docker format 时回退到 dedicated repo 策略 — `format=docker` 时不挂 CSEL，仅 view-priv 上 RW；验证 docker push / pull 用户可成功。method: `tektoncd.feature`。
7. **(p0)** Task 应在不变输入下幂等重跑 — 重跑 5 次后所有对象 `resourceVersion`（在 K8s 侧）不变，Nexus side `lastModified` 不变（除 password rotate）。method: `tektoncd.feature`。

#### 范围（scoping）正例 / 反例（`script.feature`）

8. **(p0)** ensure-nexus-resources 应创建 hosted repo 与 csel（maven2）— 断言 csel `expression` 与 priv `actions` 精确匹配。method: `script.feature`。
9. **(p0)** scoped user 应在 IN-scope path 路径 PUT 成功 — 用预置的 proj-pilot-user 凭据从 Pod 内 PUT `/repository/.../com/acme/proj-pilot/widget-1.0.0.jar`，期望 201。method: `script.feature`。
10. **(p0)** scoped user 应在 OUT-of-scope path PUT 失败（403）— PUT `/com/other/Y.jar`，期望 403。**关键反例**。method: `script.feature`。
11. **(p1)** scoped user 应在 OUT-of-scope path GET 时收到 404（不是 403）— 信息隐藏行为，用于守护 retrospective 教训。method: `script.feature`。
12. **(p0)** scoped user 不能创建 / 删除 repo — POST / DELETE `/v1/repositories/...`，期望 403。method: `script.feature`。

#### 身份生命周期（`script.feature`）

13. **(p0)** ensure-nexus-user 应在已存在用户上 rotate-password — 预置 user，rerun，日志含 `RESULT: ensure-nexus-user user=proj-pilot-user status=rotated`，tmpfs token 文件已更新。method: `script.feature`。
14. **(p0)** ensure-nexus-user 应在身份变更（format 集变化）时 recreate — 改 `nexusRepositories` 数组的 format 集合后 rerun，日志含 `status=recreated reason=identity-changed`，user 名称不变但 role / privileges 全部重建。method: `script.feature`。
15. **(p0)** ensure-nexus-user 应在 Nexus 端用户被外部删除时 fall through 到 recreate — 手动 DELETE user，rerun，日志含 `status=recreated reason=user-vanished`。method: `script.feature`。**(优先级 p1→p0：CE 上可直接 live-verify，且与 GitLab retrospective "fall-through 路径是 stub 测试漏检重灾区" 教训一致。)**

#### 错误分类（`script.feature`）

16. **(p0)** ensure-nexus-user 应识别 `DuplicateUserException` 为 identity-changed 路径 —— 注入一个同名但 description fingerprint 不同的 user，rerun → recreate 路径，**不**报 fatal。method: `script.feature`。
17. **(p0)** ensure-nexus-resources 应识别 `Content selector ... is in use` 为 in-use → 走依赖图反向清理重试。method: `script.feature`。
18. **(p1)** 任何 step 应在 admin Connector 凭据错误时给出可操作错误 — log 含具体 endpoint + status code + Nexus body excerpt。method: `script.feature`。
19. **(p0)** ensure-nexus-resources 应拒绝 CSEL 表达式中的 `&&` / `||`（静态 lint）—— `lib.sh::build_csel_expression` 在构造前断言无 `&&` / `||` / `"` / `\` / 任意 whitespace；fixture 注入 `&&` 或 `or 1==1` 风格 pathPrefix 时 Pod Failed + log 含 `invalid CSEL operator / pathPrefix`；同时单独一个 p1 sub-case：若 lint 被绕过传到 Nexus，Nexus 报错 body 完整透传日志。method: `script.feature`。**(优先级 p2→p0：CSEL 误用会静默 deny / allow，而本特性的安全模型完全建立在 CSEL 正确性上 — 参 threat-model T7 reframed。)**

#### 依赖图反向清理（`script.feature`）

20. **(p0)** Task delete 路径应按 `user → role → priv → csel → repo` 反向清理 —— 单元化 `cleanup` 函数（Story 1 的 `lib.sh` 实现），Pod 跑 `cleanup proj-pilot`，断言所有 6 类对象都不存在 + 日志含按序删除。method: `script.feature`。
21. **(p1)** Task 应检测并修复 stale role-on-user 引用 — 预置 user 引用一个已删除的 role，rerun，期望 role / priv / csel 重建，user 上的 role 引用更新。method: `script.feature`。

#### K8s apply（`script.feature`）

22. **(p0)** apply-kubernetes-resources 应幂等 SSA Secret + Connector — rerun 5 次，`resourceVersion` 不 bump（password 未变时）。method: `script.feature`。
23. **(p1)** apply-kubernetes-resources 应在 `field-manager` 冲突时给出可操作错误 — 预置一个非 connectors-operator field-manager 持有 Connector 的某字段，rerun 期望 SSA 冲突 + 可读错误。method: `script.feature`。

#### 匿名用户策略（`tektoncd.feature`）

24. **(p1)** Task 应检测匿名用户启用并在 step 1 verify 日志中记一行 WARN — 测试 Nexus 默认 anonymous=enabled，step 1 (`verify`) Pod 日志含 `WARN Nexus anonymous access is ENABLED at ...`；TaskRun 状态 `Succeeded`（log-only 路径，不暴露 result，不 fail）。method: `tektoncd.feature`。注：原设计同时断言 TaskRun result `anonymous-policy-warning` 非空 + 加 sub-case 守护 `requireAnonymousDisabled=true` opt-in fail 分支，v0.1 未落地（DEVOPS-44183，设计 → 落地之间晚期下线，理由参 `manual-testing.md` AC-6 line 135 接受 log-only 实现）；如未来重新引入 result + opt-in fail 作为 v0.2+ 特性，再补 sub-cases。

#### Group repository（D2 参数化）

25. **(p1)** Task 应在 `groupRepositories=[]` 时不创建任何 group repo — list `/v1/repositories`，断言无 `proj-<projectID>-group-*` 条目。method: `tektoncd.feature`。
26. **(p0)** Task 应在 `groupRepositories[0].withCsel=true` 时把 CSEL 挂到 group 层 — 验证 group 上有 `repository-content-selector` priv，scoped user 透过 group URL GET 受限路径外文件期望 404，受限路径内 GET 期望 200。method: `tektoncd.feature`。
27. **(p1)** Task 应在 `groupRepositories[0].withCsel=false` 时仅给 group view priv — scoped user 透过 group URL GET 任意 member 上的 artifact 全部期望 200（blanket 入口，已接受的 leakage）；写 group URL 期望 405 / 403（Nexus group 只读）。method: `tektoncd.feature`。

#### AC-3 reframe 验证：downstream 工具配置 merge（`tektoncd.feature` + smoke pod）

28. **(p0)** scoped user 可通过 ConnectorClass 渲染的 settings.xml / .npmrc 拉取项目 hosted + 共享上游 — 起 smoke pod 挂 `nexusmavenartifact` ResourceInterface，跑 `mvn dependency:get -DgroupId=com.acme.proj-pilot -DartifactId=widget -Dversion=1.0.0`（命中项目 hosted），随后跑 `mvn dependency:get -DgroupId=junit -DartifactId=junit -Dversion=4.12`（命中共享 maven-central proxy）；两次均期望 200 + 文件落盘。method: `tektoncd.feature`。

#### Ownership 冲突 + Partial 失败自愈（`script.feature`）

29. **(p0)** Task 应拒绝静默 adopt 不同 owner 持有的同名 user / repo / role — fixture 预置一个 description.OWNER ≠ `connectors-operator` 的同名 user；Task rerun 期望 Pod Failed + log 含可操作 takeover 指引（mirror gitlab `verify_admin_ownership`）。method: `script.feature`。
30. **(p1)** Task 应在"repo 已建但 csel 缺失"的中间状态下自愈 — fixture 直接 DELETE 一条 csel 后 rerun，期望 step 2 检测到命名前缀匹配且 csel 缺失 → 重新创建 csel + priv，无副作用；resourceVersion 在 K8s 侧不 bump。method: `script.feature`。
31. **(p1)** Task 应在"user 已建但 K8s apply 失败"后下次 rerun 走 rotated 路径 — fixture 在 step 4 之前杀掉 kubectl SA token；下次 rerun 期望 step 3 status=rotated + step 4 SSA 成功，Nexus 端 user 不重建。method: `script.feature`。
32. **(p1)** Task 应在中途 cancel / pod evict 后通过命名前缀 list-and-reconcile 收敛 — fixture 在 step 2 中途 cancel TaskRun；rerun 期望从命名前缀重新发现已建对象，按 OWNER+FP 校验后继续未完成的部分。method: `script.feature`。
33. **(p1)** Task 应在 `nexusRepositories[]` 收缩时（一条 entry 被删）走 converge-to-input 路径 — fixture 一次 rerun 后从输入数组去掉一条；下次 rerun 期望对应 csel + priv 被删除（保留 repo 不动），日志含 `orphan-csel cleaned, hosted repo retained`。method: `script.feature`。

### E2E case 决策

**否 —— 不新增 e2e 用例到 `connectors-operator/test/integration`**。理由：

- operator 端只做 install-manifest plumbing（task 14, 15），没有新 controller / reconciler 逻辑可测。
- Task 内部 business 逻辑全部由 `script.feature` + `tektoncd.feature` 覆盖（**33 个用例**，含 scoping 反例 + ownership 反例 + partial-fail 自愈四例）。
- 沿用 Harbor + GitLab 前作的同款决策；GitLab retrospective 未提到该决策是 friction 来源。

operator 集成测试套保留给真正涉及 operator reconciler 的 PR。

### `@manual` 用例声明

**预计 0 个 `@manual` 用例**。Nexus 3.76 CE 上所有失败路径（identity rotate / external delete / field-manager 冲突 / 匿名启用 / ownership conflict / partial-fail / 收缩 input）都可在 live 实例上 admin API 直接重现；不存在 GitLab TC4 / TC11 / TC12 那类"CE 不能复现 PRO 行为"的限制。如 implement 阶段发现需要 `@manual`，必须在再批准日志中说明理由。

### Test 执行环境

- **Target Nexus**：driver 在 Jira DEVOPS-43952 评论中提供的 live 实例 —— 集群 `jtcheng-bdrjq-bwrsq--idp.alaudatech.net` 上 `devops-nexus` namespace 中的 `nexus-1-nxrm-ha`（Nexus 3.76.0-03 OSS）。**不**另起 kind+Helm 自建 Nexus（driver 明确指示用 Jira 提供的 Nexus 作为测试目标）。
- **Story 2 harness（task 9a）**：在 `connectors-extensions/connectors-nexus/testing/` 下落地连接配置 + 命名前缀隔离 `bdd-<short-sha>-` + 跑前 setup + 跑后反向清理脚本。BDD pod 通过 port-forward 或 in-cluster service DNS 直达。
- **跑 BDD 的位置**：CI 在 connectors-extensions PipelineRun 中拉起测试 pod（与现有 lint-and-test 流水线同一形态）；本地开发可手动 `cd testing && make test`。
- **共享 live 实例的并发约束**：命名前缀隔离 + admin 全局锁是 v0.1 解；若并发 PR 出现互踩，作为 follow-up 改用 namespace-per-PR 的 Nexus 实例池。

### POC 证据

本特性的 critical-path 风险（CSEL 是否在 CE 可用、能否约束跨项目读写）已在 design 阶段于 live Nexus 3.76.0-03 OSS 实例上 **hands-on 验证完毕**：

| 实测项 | 结果 | 证据 |
|------|------|-----|
| 建 hosted + csel + priv + role + user | 成功（HTTP 201/204） | `_research-notes-nexus-api.md §4` |
| scoped user IN-scope PUT | 201 ✅ | 同上表 |
| scoped user OUT-of-scope PUT | 403 ✅（critical positive evidence）| 同上表 |
| scoped user OUT-of-scope GET | 404（info-hiding，as designed）| 同上表 |
| scoped user 删 repo / 建 repo | 403 ✅ | 同上表 |
| anonymous PUT | 401 ✅ | 同上表 |
| 全部测试对象反向清理 | 实例回到 fingerprint baseline | 同上表 |

BDD 阶段沿用同一 live 实例验证 helper 脚本 + 端到端 TaskRun；本特性**不**需要额外独立的 POC 分支跑（feature-flow improvement-log 已记录"POC 与 design 同阶段执行"的会议决议）。

### 再批准日志

> 约定：若 implement 期间用例增删、优先级调整、失败模式覆盖变化，design reviewer 在此追加一条 entry：日期 + 修改人 + 涉及 TC 编号 + 一句理由 + re-sign 提示。Mirror feature-workflow `maturity.entries[]` 风格。

_（暂无）_
