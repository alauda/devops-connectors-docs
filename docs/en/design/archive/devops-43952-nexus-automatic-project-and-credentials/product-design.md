# 产品设计 — Nexus 自动创建 Project + Connector + Secret

<!--
由 /feature:design 写出。Goal 是首要产物，其它章节都为它提供支撑或验证。
-->

## 术语小词典

> 本文反复出现的几个易混词：
>
> - **项目**：一律指 **ACP DevOps Project**（其下挂一个 K8s namespace；Nexus 端用 `projectID` 标识，等同 ACP project name 的 kebab-case 化）。
> - **namespace**：仅指 K8s namespace。
> - **tenant**：不使用（GitLab 专属术语）。
> - **Connector** / **Secret**：K8s 端 CR 与 Secret，由本 Task 在 `connectors-management` namespace 创建。
> - **proj-`<projectID>`**：Nexus 侧 user / role / privilege / content-selector / repo 的统一命名前缀。

## 目标

提供一个 Tekton Task `nexus-connector-automatic-creation/0.1`，面向 **Nexus Repository Manager 3.76 社区版（OSS / CE）**。给定一个 Nexus 管理员 Connector 作为入参，以及目标项目的 `projectID` 与按制品格式声明的仓库列表，该 Task 通过 Nexus 原生权限模型（user + role + privilege + content selector）在 Nexus 端创建项目专属仓库、把仅作用于该项目的本地用户与权限按命名约定 `proj-<projectID>-*` 一次性建好，然后用 `kubectl apply --server-side` 把对应的 Connector 与 Secret 回写到 `connectors-management` namespace。**不**依赖任何 Nexus PRO 能力（不使用 NXRM PRO user-token、staging 插件、blob-store 配额、HA cluster、licence-gated realm）；**不**引入 parent-project / tenant 层级（Nexus 不存在该概念，Harbor 同样为 flat 模型，仅 GitLab 因 group 概念而引入双 pattern）；部分失败的恢复模型为 **idempotent rerun + 显式依赖图清理**（沿用 Harbor / GitLab 前作），而非事务回滚。

## 对 Jira AC 的覆盖与改写

> Jira 原文 9 条 AC 中 4 条因 Nexus 无 parent-project / 无事务 / 无 multi-level hierarchy 等原生原语，需要 reframe；reframe 后给出"等价用户价值"的实现路径，**不**降低用户体验。下表是 reframe 与原文的对照，对 design-review 与明天的讨论会有直接价值。

| AC | Jira 原文 | 本设计的解读 | 改写理由（reframe 时） |
|----|----------|-------------|--------------------|
| AC-1 | Nexus repository can be created automatically via Task for a given Project / namespace | **直接交付**：Task 入参 `nexusRepositories[]` 描述目标 repo 集，按 format dispatch 创建 | — |
| AC-2 | Project-scoped credentials are created with repository-specific permissions | **直接交付**：Task 为项目建一个本地 user + role + per-repo privilege，凭据回写到 Connector + Secret | — |
| AC-3 | Parent project has access to shared resources (base artifacts / proxies) | **改写**：Nexus 无 parent-project 原语。用"项目工具配置 merge 访问共享 upstream proxy"实现等价 — Connector 的 `nexusconfig` / `npmrc` / `pipconf` 模板把项目 hosted repo 与共享 upstream proxy（如 maven-central-proxy）一起渲染进 `settings.xml` / `.npmrc` / `pip.conf`，下游工具自然 merge | Nexus 与 Harbor 同样为 flat 模型；GitLab 因 group 概念才引入 parent；强行造层级会破坏 D1 决策的对称性 |
| AC-4 | Namespace projects have restricted access to their own repositories | **改写**：去掉 namespace-vs-parent 层级措辞，等价语义为"项目用户的读写权严格约束在自有路径前缀或自有 hosted repo"，由 Nexus content-selector 在 `path =^ "<pathPrefix>"` 上保证（live 验证：out-of-scope PUT 403 ✅；out-of-scope GET 404 ✅；删 repo 403 ✅；建 repo 403 ✅） | 原文"namespace project"一词在 Nexus 语境下无 native 对应；reframe 后 acceptance 仍可机测 |
| AC-5 | Connector + Secret reconciled into the right namespace as part of provisioning | **直接交付**（**但澄清 "right namespace" 的解读**）：本设计中 Connector + Secret 落 `connectors-management` namespace（与 Harbor / GitLab 前作一致；连下游应用所在的项目 namespace 通过 connectors-proxy + CSI 间接消费） | — |
| AC-6 | Error handling for API failures and permission conflicts | **直接交付**：Nexus 返回 4xx 与 `Duplicate*Exception` / `... is in use` 等 5xx 都按错误体内容分类，actionable error 透传到日志；测试由 TC 16-19 覆盖 | — |
| AC-7 | Rollback mechanism for failed repository / credential creation | **改写**：Nexus REST 无 transaction；本设计走"idempotent rerun + 依赖图反向清理"（与 Harbor swallow-409 / GitLab idempotent-create 思路一致但因 Nexus 创建非幂等而带 GET-first 检查）— 等价语义为"部分失败后再次运行 Task 即可自愈" | Nexus REST 没有 transaction 端点；研究阶段验证 |
| AC-8 | Integration tests cover multi-level hierarchy scenarios | **改写**：去掉 "multi-level hierarchy"（Nexus 不存在）；等价覆盖为"多项目 × 多 format × scoping 组合"，BDD 集成测试覆盖（TC 5-11, 26, 27） | — |
| AC-9 | Documentation includes Nexus API usage and examples | **直接交付**：概念页 + how-to 页 + 中英文双版本 + release-note 入口 | — |

V0.1 driver（jtcheng）拟在 design-review 阶段对上述 reframe **逐条 sign-off**，由 reviewer 复核。原始 ticket 文案保留在 Jira 不动；reframe 的"等价语义"统一在 acceptance.md 中按上表语义 verify。

## 上下文

> 调研阶段（DEVOPS-43950）已合并入本设计阶段。下列结论来自对 live 测试 Nexus 3.76.0-03 OSS（namespace `devops-nexus`）的 hands-on 验证，以及对 Harbor (DEVOPS-43145) / GitLab (DEVOPS-43146) 前作的设计 & retrospective 通读。完整原始记录见 `_research-notes-nexus-api.md` 与 `_research-notes-prior-art.md`。

### Nexus 3.76 CE 关键边界（设计读者关心的 3 条）

- **身份机制只有 basic auth**：`/v1/system/license` 402；`/v1/security/user-tokens`、`/v1/security/jwt` 全部 404；唯一可用的非交互式凭证就是 `userId + password`。
- **权限原语完备**：CE 自带 `repository-content-selector` privilege —— live 验证可将一个普通用户的读写严格约束到一个共享 hosted repo 的某个路径前缀上；不需要"一项目一独立 repo"。
- **API 按格式分流**：没有统一 `POST /v1/repositories`，每个 format 一组 `/v1/repositories/<format>/<hosted|proxy|group>` 端点。控制器按 `format` 字段 dispatch。

> Nexus 的几个会咬实现者的小怪癖（CSEL 算子 `and`/`or` 而非 `&&`、POST 返回码混乱、HTTP 500 不一定是故障、创建非幂等、删除依赖不一致）已落到 `tech-design.md ## 失败模式` 与 `## 测试设计` 章节，本节不重复。

### 前作（Harbor / GitLab）沿用与分歧

> 完整 18 项 reuse-vs-reject 决策表见 `_research-notes-prior-art.md` 第 9 节。

**直接沿用**：Task 命名约定与版本目录、`task.template.yaml + render-task.sh` 内联脚本模式、通用参数与 tool-image descriptors、workspace 对（必选 `nexus-config` + 可选 `kube-config`）、凭证三路生命周期、Task 自包含 reconciler（`kubectl apply --server-side --field-manager=connectors-operator` 直接回写）、幂等重跑+命名前缀 list-and-clean、BDD pod-level + zh-CN Gherkin、OpenSpec 4-story 拆分、risk=sensitive + threat-model + security sign-off。

**与前作的分歧**：

- **不引入双 pattern**：Nexus 与 Harbor 都是 flat 模型，仅 GitLab 因 group 概念而需要双 pattern。
- **不复用 `permissions` 位置数组**：Harbor 的 `<resource>:<verbs>` 不适配 Nexus 的 user + role + privilege + content-selector 多原语模型；改用结构化的 `nexusRepositories` 数组。
- **不暴露 `imagePullSecrets`**：Nexus 是通用制品库；image-pull 物化是 Harbor 特有产物。
- **创建不能 swallow 409**：Nexus 创建非幂等（重复 user 500 / 重复 repo 400 / 重复 role 400），必须 GET-first 检查。

### 按格式的扫描策略

- `maven2` / `npm` / `pypi` / `raw`：**Option (i) 共享 hosted repo + 路径前缀 CSEL**。每项目 5 个 Nexus 对象（1 csel + 2 privilege + 1 role + 1 user）。
- `docker` / `gitlfs`：**Option (ii) 一项目一独立 hosted repo + 全 RW repository-view，无 path-prefix**。

### V0.1 决策（driver 2026-05-21 提案；design-review 拟最终确认）

> 一句白话先讲清楚每个决策，再列实现要点；非实现者也能在 30 秒内看懂。

| # | 一句白话 | 实现要点 |
|---|---------|---------|
| D1 | 一个 Nexus Connector 同时管多种制品格式（maven + npm 在同一 Connector） | `nexusRepositories[]` 每条目自带 `format`，控制器按 format dispatch；不按 format 拆 ConnectorClass（与现存 `docs/en/design/connector-nexus/tech-design.md` 多 protocol configurations 对齐） |
| D2 | 默认不前置 per-project group repo；调用方需要虚拟入口时通过 Task 参数显式 opt-in | 新增 `groupRepositories[]` 数组（默认 `[]`），每条目 `{name, members[], withCsel:bool}`；`withCsel=true` 走"在 group 上再挂一层 CSEL"（紧路径，避免 group 透读 members 全集）vs `withCsel=false` 走 blanket browse/read（宽路径） |
| D3 | Nexus 全局开启匿名读不是本 Task 的责任；只在 step 1 verify 日志里给部署方一个 warning | 默认 (c)：`verify.sh` 检测 `anonymous` 启用即记一行 `WARN Nexus anonymous access is ENABLED at ...`，不修改 Nexus 设置，不暴露为 Tekton result，也不提供 opt-in fail 参数（log-only 行为已被 `manual-testing.md` AC-6 接受）。注：测试 Nexus 实例（`devops-nexus` ns）driver 已授权自由修改，不约束生产 Nexus 设计行为。**v0.1 下线**（设计 → 落地之间晚期决策，详 `manual-testing.md` AC-6 line 135 + DEVOPS-44183）：`anonymous-policy-warning` Tekton result 与 `requireAnonymousDisabled` opt-in 参数。如严格站需要 fail-fast，由部署方在 Nexus 安装阶段处理 cluster-level 匿名配置 |

## 用户可见接口

### 调用方式

- **主入口**：平台工程师在 `connectors-management` namespace 或目标项目 namespace 编写一个 `TaskRun`，把 admin Nexus Connector 引用 + `projectID` + `nexusRepositories[]` 传入。
- **推荐 wrap**：建议在 Pipeline 中包一层（与上下游 connector 自动创建 Task 串联），或用 CronJob 周期化用于定期 password rotate。
- **discovery**：本 Task 在 Story 4 完成 install-manifest 同步后，会出现在 ACP DevOps "新建 PipelineRun → 选择 Task" 列表中。
- **admin Connector 前置条件**：`connectors-management` namespace 中必须已经存在一个 admin Nexus Connector + 其凭据 Secret，且该 Connector 通过 `nexusconfig` ConnectorClass 渲染出 admin 凭据可挂载到 CSI workspace。
- **v0.1 不交付 UI 表单**：没有在 ACP DevOps 表单层新增独立的 "Auto-create Nexus" 屏幕；如未来需要，作为 follow-up。

### Tekton Task 参数

`connectors-extensions/connectors-nexus/tektoncd/tasks/nexus-connector-automatic-creation/0.1/`（**新建 `tektoncd/` 子树** —— 该仓库当前无该目录，Story 1 顺带 scaffolding）。

**通用 params**（与前作命名一致）：

| 参数 | 类型 | 必填 | 默认 | 用途 |
|------|------|----|-----|------|
| `connector` | string `<ns>/<name>` | 必填 | — | 管理员 Nexus Connector |
| `secret` | string | 可选 | `<connector-name>-secret` | admin 凭据 Secret 名 |
| `verbose` | string `"true"`/`"false"` | 可选 | `"false"` | 日志详细程度 |
| `imagePullPolicy` | string | 可选 | `Always` | tool-image pull 策略 |
| `curlImage` | string | 可选 | `catalog.tekton.dev/tool-image-curl` 当前值 | step 1/2/3/5 使用 |
| `kubectlImage` | string | 可选 | `catalog.tekton.dev/tool-image-kubectl` 当前值 | step 4 使用 |

**业务 params**：

| 参数 | 类型 | 必填 | 默认 | 用途 |
|------|------|----|-----|------|
| `projectID` | string | **必填** | — | 项目唯一标识，Nexus 端命名前缀 `proj-<projectID>-*` 的来源；约束 `^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`（同 K8s name），与 ACP project name 的 kebab-case 化对齐 |
| `nexusUser` | string | 可选 | `connector-<connector-ns>-<connector-name>` | 项目级 user 名（与 Harbor `robotAccount` / GitLab `accessTokenName` 命名对齐） |
| `nexusRepositories` | array of struct | 必填 | — | 见下方 schema |
| `groupRepositories` | array of struct | 可选 | `[]` | 见下方 schema（D2 opt-in） |
<!-- v0.1 下线（DEVOPS-44183）：原计划 `requireAnonymousDisabled` opt-in 参数（D3 严格站 fail-fast）未落地；shipped task.yaml 仅 8 个 params。如未来重新引入，作为 v0.2+ 独立特性。 -->

**`nexusRepositories[]` 条目 schema**：

| 字段 | 类型 | 必填 | 允许值 / 默认 | 用途 |
|------|------|----|-------------|------|
| `name` | string | 必填 | 形如 `maven`、`npm-internal` | repo 简称，物化后命名 `proj-<projectID>-<name>` |
| `format` | string | 必填 | `maven2` \| `npm` \| `pypi` \| `raw` \| `docker` \| `gitlfs` | 决定 API 端点 |
| `type` | string | 可选 | `hosted` \| `proxy` \| `group`，默认 `hosted` | Nexus 三种 repo 类型；v0.1 主推 `hosted` |
| `scope` | string | 必填 | `shared-csel`（仅适配 maven2/npm/pypi/raw）\| `dedicated`（强制用于 docker/gitlfs） | 决定 Option (i) vs (ii) 落地 |
| `pathPrefix` | string | 条件必填 | `scope=shared-csel` 时必填；形如 `/com/acme/myproj/`；约束 `^/([a-z0-9._-]+/)+$` **加** segment 拒绝 `..` / `and` / `or` / `not`（**POC H3 修正**：原 `^/[a-z0-9._/-]+/$` 不安全） | 仅 `shared-csel` 用，CSEL 表达式中 `path =^ "<pathPrefix>"` 的值；Nexus CSEL 不做语义校验，regex 是唯一防线 |
| `retainAccess` | array of string | 可选 | 子集 `[read, browse, edit, add, delete]`；默认 `[read, browse, edit, add, delete]` | 该项目用户在此 repo 拥有的 action |
| `proxyRemoteUrl` | string | 条件必填 | `type=proxy` 时必填 | 上游 URL |

**`groupRepositories[]` 条目 schema**（D2 opt-in）：

| 字段 | 类型 | 必填 | 默认 | 用途 |
|------|------|----|-----|------|
| `name` | string | 必填 | — | group 简称，物化后命名 `proj-<projectID>-group-<name>` |
| `format` | string | 必填 | — | 一个 group 只能包同 format 的 members |
| `members` | array of string | 必填 | — | 引用 `nexusRepositories[].name`（同 projectID 内的命名）或现有 Nexus repo 名（如 `maven-central`） |
| `withCsel` | bool | 可选 | `false` | tight (CSEL on group) vs blanket (only repository-view browse/read) |

**Results**：

| 字段 | 用途 |
|------|------|
| `nexus-repositories` | 数组，实际物化后的 repo 全名（含 `proj-<projectID>-` 前缀） |
| `nexus-user` | 实际物化后的 user 名（identity rotate / recreate 后值可能变化） |
| `connector-ref` | `<ns>/<name>` 形式的 Connector 引用 |
<!-- v0.1 下线（DEVOPS-44183）：原计划 `anonymous-policy-warning` Tekton result 未落地；shipped task.yaml 仅 3 个 results（`nexus-repositories` / `nexus-user` / `connector-ref`）。匿名检测改为 step 1 verify 日志一行 WARN（log-only，per D3 上方说明 + `manual-testing.md` AC-6 line 135 接受）。 -->

**Workspaces**：

- `nexus-config`（**必填**）—— 管理员凭据 CSI 挂载点；包含 `username` / `password` / `connector-class` / `connector-namespace` 等 admin 上下文。
- `kube-config`（可选）—— 写 K8s 时使用；不提供则使用 in-cluster 配置。

### ConnectorClass / ResourceInterface 改动

- **预期为 0 改动**。本 Task 是 `nexusconfig` ConnectorClass + per-protocol ResourceInterface（`nexusmavenartifact`、`nexusnpmartifact`、`nexuspypiartifact`，详 [`docs/en/design/connector-nexus/tech-design.md`](../connector-nexus/tech-design.md)）的**消费方**，不修改既有 schema。
- **接面声明**：本 Task 通过 `nexusRepositories[].format` 输出与各 ResourceInterface 协议对齐的 repository；下游消费方按 protocol 选择对应 RI 挂载（Maven 选 `nexusmavenartifact`、npm 选 `nexusnpmartifact`、etc）。Task 写入的 Connector 仅含 admin 凭据替换为 per-project 凭据后的字段，ConnectorClass schema 复用。
- **如 grep 发现需新增字段**（如 gitlab 因 `gitlabconfig` 缺 `connector_address` 字段而需跨仓库提交修复）：列为 Story 3a 跨仓库依赖任务，design-review 时按发现实际情况决定是否阻塞。

### 文档页面

- **概念页**：`docs/en/connectors/concepts/nexus-cli-config.mdx` —— admin 凭据如何通过 CSI 挂载、Task 如何用 basic auth 调 Nexus REST、CE 与 PRO 边界。
- **How-to 页**：`docs/en/connectors/how-to/automatic-create-nexus-projects.mdx` —— 完整 TaskRun 示例、cron 调度模板、运维 runbook、Nexus 端手工兜底、迁移指南（"我已经手工建过 `proj-foo-maven` 怎么办"——指向 ownership-fingerprint 错误与手工 takeover 步骤）。
- **中文同步**：`docs/zh/...` 同步（沿用既有翻译流程）。
- **Release note 入口**：在 `release-notes.md` 记录新 Task + 默认行为（含 D3 anonymous warn-not-modify）。
- **Migration 提示**：how-to 页显式给出"该 Task 对已存在但非本 Task 创建的 Nexus 对象拒绝静默 adopt"的行为说明，及切换路径。

### CLI 标志 / 新 API 端点

无新增 CLI / 集群 API 端点。所有交互通过 Tekton Task 入口。

### UI 表单 / 屏幕

无 UI 故事。Task 出现在现有 ACP DevOps 流水线 Task 选择器（Story 4 install-manifest 同步后自动可见）。

## 范围外

- **parent-project / tenant 多层级**：AC-3 原文要求 parent-project 共享访问 — Nexus 无 parent-project 原语，Harbor 同样为 flat 模型；本设计通过 "downstream 工具配置 merge 访问共享 upstream proxy" 实现等价用户价值（详 §对 Jira AC 的覆盖与改写），不引入 tenant 层级。后续若有真实诉求，作为独立 epic 重启。
- **Nexus PRO 能力**：user-token、JWT、SAML、staging、blob-store quota、HA cluster、Crowd / licence-gated realm —— 全部 explicit 拒绝，不为 PRO 实例提供加速路径。
- **与 SonarQube 兄弟 Story (DEVOPS-43953) 共享 Tekton 脚手架**：保持 Nexus Task 自包含；脚手架共享延后到两个 Task 都 ship 之后再评估。
- **事务回滚 / 强一致清理**：Nexus REST 无 transaction；本特性使用幂等重跑 + 命名约定 list-and-clean，partial-failure 由下次 reconcile 自愈，不在单次 TaskRun 内做强回滚承诺（详 AC-7 reframe）。
- **匿名用户开关**：本 Task 默认不修改 cluster-level `anonymous` 配置（D3 (c)），仅在 step 1 verify 步骤记一行 WARN 日志（log-only，v0.1 未提供 result 也未提供 opt-in fail 参数，DEVOPS-44183）。部署方如需 lock down 应在 Nexus 安装阶段处理。
- **Docker 镜像拉取 Secret 物化**（`kubernetes.io/dockerconfigjson`）：Harbor 专属产物，Nexus 不复制（GitLab 同样 drop）。后续如需 follow-up Task。
- **Operator-side reconciler / CRD**：Task 自己用 server-side-apply 回写 Connector + Secret；不引入 operator controller 新 reconcile loop（沿用前作）。
- **跨集群 Nexus 部署**：本 Task 假定 Nexus 在 Tekton 可直达的网络位置（含 VPC 对等 / proxy）；多集群跨网 Nexus 路由不在范围。
- **静默 adopt 非本 Task 创建的同名对象**：ownership fingerprint 不匹配时本 Task 抛 actionable error，要求人工 takeover 或重命名；不在 v0.1 内做自动 takeover。
