# 产品设计 — SonarQube 自动创建 Project + Connector + Secret

<!--
契约文档（WHAT + WHY）。
- 实现细节 → tech-design.md
- 实证 / 用户操作手册 → poc.md
三份文档章节顺序对齐，便于同步对照。
-->

## 1. 目标

为平台工程师提供一条 Tekton TaskRun：基于一个 admin SonarQube Connector，
为一个 ACP 租户（Project）一次性配置 SonarQube 代码扫描接入能力。Task 在
SonarQube 侧创建租户的 **local user**、**permission template** 与
**USER_TOKEN**，并把租户侧 `sonarqube` **Connector + 鉴权 Secret** 落到目标
namespace。**Task 不创建具体 SonarQube 项目** —— 项目在 CI 首次扫描时由
SonarQube 自动创建（凭 user 的全局 `provisioning`），凭 key 命中
`projectKeyPattern` 自动套模板。Task 重跑幂等，失败时回滚本次新建的资源。

## 2. 范围

**之内：** Tekton Task 模板与脚本、`sonarqube` ConnectorClass 的
configuration 注册（A8）、operator 流水线接线（`sync_install_manifests.sh`
+ `values.yaml` + `cmd/kodata` 同步）、概念/how-to/参考文档三页、BDD
集成测试。

**之外：** SonarQube 服务端安装/升级、Enterprise Portfolios、Task 亲自
创建项目、Task 修改实例级设置、运行 scanner、独立的租户下线 Task（下线由
文档承载的清理脚本完成 — 见 poc.md 步骤 5）、破坏性 ConnectorClass 变更、
编辑 operator 的 `cmd/kodata/`、UI 面（无 connectors-plugin 改动）。

## 3. 设计决策（driver 已确认）

| # | 决策 | 关键理由 / 证据 |
|---|------|---------------|
| D1 | **账号模型 = Branch-3：每租户 1 user + key-pattern 模板，无 group** | POC 端到端 + 清洁复测 + 「去 group」追测均成立（→ poc.md B.2 #3、#5）。否决「项目级 `PROJECT_ANALYSIS_TOKEN`」（不能读 `api/measures`）与「每项目专用 user」（账号膨胀）。 |
| D2 | **Task 只建租户设施，不建具体项目** | 项目在扫描期由 SonarQube 自动创建，要求租户 user 直接持全局 `provisioning`；规避项目级 token 的「鸡生蛋」（→ poc.md B.3）。 |
| D3 | **scoping 靠 4 件实例级前置条件 + 租户 user 仅持 `provisioning`** | SonarQube 默认组 `sonar-users` 不可移除（`api/user_groups/remove_user` 对默认组返回 `400 Default group cannot be used`），故隔离必须落到实例级（→ §4、§6）。 |
| D4 | **`connector` 参数 = 输出（对齐 Harbor/GitLab）** | 参数语义统一：`connector=<ns>/<name>` 指要创建/更新的租户 Connector；admin Connector 经 `sonarqube-config` workspace 投递（→ §5.3）。 |
| D5 | **单工具镜像 `sonarqubeAutomationImage`（review-iteration-2 起改为自建）** | POC 初版复用 catalog alpine kubectl 镜像 + render-task.sh 内联展开 helper 脚本即可；review-iteration-2 起 ~600+ LOC helper 脚本使 task.yaml diff 不可读，遂改为自建 `sonarqube-connector-automatic-creation` 镜像（alpine 3.23.x + bash/curl/jq/kubectl + 烘焙脚本到 `/usr/local/bin`），同时参数从 `toolImage` 改名为 `sonarqubeAutomationImage` 以避免与「catalog 工具镜像」语义混淆。 |

## 4. 部署前置条件（运维一次性准备）

这 5 条是 **Branch-3 隔离模型成立的必要条件**。Task **不**自行修复（以免把
admin 凭据抬到「能修改实例设置」的高权层级），由运维 / SonarQube 管理员
预先配置；Task 启动时由 `lib.sh::preflight()` 校验关键项。可执行命令见
[poc.md 步骤 1](./poc.md#步骤-1--sonarqube-实例侧一次性前置项运维--sonarqube-admin)。

| # | 前置条件 | 校验 / 落实 |
|---|---------|-----------|
| **P1** | **实例默认项目可见性 = Private** | 扫描期自动创建的项目继承实例默认；事后改 visibility 在目标实例上不可靠（POC 实测 `api/projects/update_visibility` 连 admin 都 403）。`api/projects/update_default_visibility` 设 `projectVisibility=private`。 |
| **P2** | **默认组（`sonar-users` + `Anyone`）无任何全局权限** | 每个 user 强制属 `sonar-users` 且无法移除；`Anyone` 涵盖匿名访问。POC 实测两版本默认状态见下表；上线前必须逐项剥除。 |
| **P3** | **Default Permission Template 无默认组项目级 grants** | Default Template 套到「不命中租户 pattern」的项目上。8.9 POC 实测：未清前 `sonar-users` 默认在 Default Template 中持 `user`/`codeviewer`/`issueadmin`/`securityhotspotadmin` → 租户 user 能 Browse 其它租户项目；剥除后 HTTP 403（→ poc.md B.2 #4、#6）。 |
| **P4** | **实例默认 quality gate + 默认 profiles = 共享基线** | SonarQube **无** key-pattern 分发 gate/profile 机制；所有新项目继承实例默认。**这是 AC-3 的交付方式**。 |
| **P5** | **admin bootstrap Connector 持全局 `admin`（Administer System）** | Task 调 `users/create`/`permissions/add_user (global)`/`permissions/create_template`/`add_user_to_template`/`user_tokens/generate login=<其它 user>` —— 8.9/9.x/25.x 均要求 Administer System。`lib.sh::preflight()` 调 `GET api/permissions/users?permission=admin` 校验 admin login 在结果集；缺则拒跑（→ A9）。 |

**P2 / P3 的版本差异（POC 实测的两版本默认值）：**

| 实例 | `sonar-users` 默认全局权限 | `Anyone` 默认全局权限 | Default Template 默认组 grants |
|------|--------------------------|---------------------|--------------------------------|
| 25.1 | `provisioning` + `scan` | 无 | 已被实例清过，未观察到泄漏 |
| 8.9  | 无 | `provisioning` + `scan` | `sonar-users` 持 `user`/`codeviewer`/`issueadmin`/`securityhotspotadmin` |

> **建议：上线前对两组的全局权限 + Default Template grants 都逐项核验并
> 剥除；只保留 `sonar-administrators`。** 一键脚本见 poc.md 步骤 1.b / 1.c。

**P6 — 集群侧 RBAC（每个目标 namespace 一次）：** Task 默认在集群内跑
（`kube-config` workspace 未绑），其 Pod ServiceAccount 在 `connector` 参数
解析出的 namespace 需以下最小 RBAC：

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: sonarqube-connector-automatic-creation
  namespace: <connector 参数的 ns>
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "patch", "update", "delete"]
  - apiGroups: ["connectors.alauda.io"]
    resources: ["connectors"]
    verbs: ["get", "create", "patch", "update", "delete"]
  - apiGroups: [""]                # 校验 namespace 存在（防 typo）
    resources: ["namespaces"]
    resourceNames: ["<connector 参数的 ns>"]
    verbs: ["get"]
```

`RoleBinding` 绑该 namespace 下 Task 用的 SA（建议 `sonarqube-task-runner`，
不沿用 `default`）。**how-to 必须把这份 RBAC YAML 列为部署清单的一部分。**
跨集群场景绑 `kube-config` workspace，kubeconfig 内嵌身份代替集群侧 RBAC。

### 4.1 SonarQube 身份联合模式 vs Task 兼容性（A2 落实）

Task 走 **Branch-3 模型** —— 为每个租户创建一个 local user（`api/users/create
local=true + password`）。SonarQube 的身份联合 / 自动 provisioning 设置直接
决定 `users/create` 是否被实例拒绝；运维必须在上线前选准模式。

| SonarQube 模式 | 行为 | Task 是否可用 | 应对 |
|---|---|---|---|
| **无联合 / 仅本地账号** | `users/create local=true` 完全放行 | ✅ 直接可用 | 不需要额外动作 |
| **纯 SSO（SAML / OIDC，仅做登录联动）** | local user 与 SSO user **并存**；admin / 服务账号 local user 不受影响；`users/create local=true` 仍放行 | ✅ 直接可用 | 不需要额外动作；SSO 用户登录走 IDP，服务用户登录靠 token |
| **SCIM provisioning（Enterprise+）** | SonarQube 把 user lifecycle 托管给 IDP；`api/users/create` 返回 **HTTP 400** body 大致是 `User management is delegated to your SCIM provider`；`local=true` 也被拒 | ❌ ensure-user.sh 在 `users/create` 直接退出 2 | 见下方"SCIM 场景手动 fallback" |

**SCIM 场景手动 fallback**（按推荐顺序）：

1. **关 SCIM 的 user provisioning，保留 SSO 登录**。SCIM 是「IDP 推用户」，
   关掉之后 SonarQube 回到 admin 主动管理用户的模式，Task 可重新工作；同时
   SAML/OIDC 登录联动可以照常保留。这是最干净的方案，适用于运维能控制 IDP
   provisioning 范围的场景。
2. **让 IDP 把服务用户也 provision 到 SonarQube**。一些 IDP（Okta、Azure
   Entra ID）支持把 service account 类账号通过 SCIM 推过来。把每个租户对应的
   `<tenant>-bot` 在 IDP 端建好、推到 SonarQube。Task 第一次 ensure-user
   阶段会调 `users/search`，命中已存在的 user → 走 reuse 路径不再 create。
3. **预先手动创建 user**。SonarQube admin 在 UI / SCIM 关闭窗口期手动建好
   每个租户的 `<tenant>-bot` local user（password 任意，Task 不读），然后
   Task 跑 reuse 路径 + 自行 grant `provisioning` + mint token。

无论选哪条，**SCIM 模式下 Task 的 preflight 不会主动检测** —— `users/search`
是允许调用的（SCIM 只拒写、不拒读），仅在 `users/create` 时才暴露 400。
how-to 文档需在「故障排查」段列 `HTTP 400 + "SCIM"` 作为已知症状并指向本节。

> 历史背景：bdd-scratch.md 用例 9（SCIM/SSO conflict）是这一段的回归验证
> 场景；在 stub SonarQube fixture 落地前用 `@manual @needs-sonarqube` 跳过。

## 5. Tekton Task 契约

### 5.1 参数

共 **11 个 param**（review-iteration-1.5 新增 `sonarqubeUrl`；review-iteration-1 §2
把 `templatePermissions` 默认从 5 项收紧到 3 项；review-iteration-2 把 `toolImage`
改名为 `sonarqubeAutomationImage`）：

| 参数 | 类型 | 必填 | 默认 / 派生 | 含义 |
|-----|------|-----|------------|------|
| `sonarqubeAutomationImage` | string | 是 | — | 烘焙了 helper 脚本的自建工具镜像（`sonarqube-connector-automatic-creation`；alpine 3.23.x + bash/curl/jq/kubectl + `/usr/local/bin/{ensure-*,apply-*,rollback,lib,write-results}.sh`）；UI 隐藏默认值，PaC build-image 推 `v0.1.0-<sha>`。review-iteration-2 起从 `toolImage` 改名（见 D5）。 |
| `imagePullPolicy` | string | 否 | `Always` | — |
| `connector` | string | 是 | — | **输出**租户 `sonarqube` Connector `<ns>/<name>`（对齐 Harbor/GitLab） |
| `tenant` | string | 是 | — | 租户标识；派生 user / template 默认名 |
| `sonarqubeUrl` | string | 否 | `""` | **覆盖** workspace 推出的 SonarQube 地址（Mode A 的 `address` 文件或 Mode B 的 `sonar.host.url`）。用法：单个 admin Connector 搭配 credentials-only Secret 投递多套实例，按 TaskRun 切换地址。空时走 workspace 原始地址。（review-iteration-1.5 新增） |
| `projectPattern` | string | 是 | — | 该租户项目 key 的正则，写入 template `projectKeyPattern` |
| `permissionTemplate` | string | 否 | 派生自 `tenant` | 要创建/复用的 template 名称 |
| `templatePermissions` | array | 否 | `[user, codeviewer, scan]` | template **直发给租户 user** 的项目级权限集（Browse + See Source Code + Execute Analysis）。**绝不含 `admin`** —— 给租户 user 项目级 Administer 会让其能改项目权限/可见性、删项目，破坏隔离；`ensure-template.sh` 调 SonarQube 前硬拦截。review-iteration-1 §2 起从 5 项 `[user, codeviewer, issueadmin, securityhotspotadmin, scan]` 收紧到 3 项 —— 自动创建项目的最小可扫描权限集即可，issue / hotspot 管理由 admin / CI 出具修复结果，租户 user 不需要。 |
| `userName` | string | 否 | 派生自 `tenant` | SonarQube user 登录名 |
| `tokenDuration` | string | 否 | `"30"` | USER_TOKEN 有效期天数（正整数）。**每次运行**由 `compute_token_expiry()` 算出 `expirationDate = today UTC + N 天`、再传给 `user_tokens/generate`。对齐 GitLab `gitlab-connector-automatic-creation` Task 既有惯例 —— **cron-friendly**：定期 cron Task，每次 mint 都从「今日 + N」起算，避免日志里写死的过期日期失效。 |
| `verbose` | string | 否 | `false` | 非敏感步骤开 shell trace；凭据 / token 路径永远关闭 xtrace，不受此参数影响 |

**派生：** 租户 Secret 名 = `<connector-name>-secret`；USER_TOKEN 名派生自
`connector`。**admin SonarQube Connector 不是参数** — 经 `sonarqube-config`
workspace 投递。

### 5.2 Results

| Result | 含义 |
|--------|------|
| `tenant` | 处理的租户标识 |
| `username` | 创建/复用的租户 SonarQube user 登录名 |
| `permission-template` | 创建/复用的 permission template 名称 |
| `token-name` | USER_TOKEN 名称（**绝不返回值**） |
| `connector-ref` | 租户 Connector 的 `<ns>/<name>` |

### 5.3 Workspaces

- **`sonarqube-config`（必绑）** —— 投递 admin SonarQube base URL + 凭据
  到 Pod 内文件，**绝不进 Pod spec / TaskRun YAML / `ps` 可见参数**。
  SonarQube 没有标准 CLI 配置文件，故 Task 自定 **统一文件名约定** + 支持
  两种挂载形态，由 `lib.sh` 自动识别：

  | 形态 | 何时用 | 挂载语法 |
  |------|-------|---------|
  | **Connector-CSI（首选）** | 同集群运行；`sonarqube` ConnectorClass 已注册 `sonar-api` 配置（A8） | `csi.driver: connectors-csi` + `volumeAttributes: { connectors: <ns>/<admin-conn>, configuration.names: sonar-api }` |
  | **Secret 直挂（fallback）** | 跨集群、CSI 不可用、上线 bootstrap | `secret.secretName: <admin-secret>` |

  **文件名约定**：挂载目录下必有 `address`（base URL）+ `token` **或**
  `username`+`password`（Basic auth）。同时存在时 `lib.sh` 优先选 `token`。

  > CSI volume attribute key 必须用 **`connectors`**（复数）+
  > **`configuration.names`** —— 单数形式 `connector` / `configuration`
  > 是常见拼错，驱动会返回 `connectors or connector.name is required`
  > （POC 实测；参 sibling repo `connectors/pkg/csidriver/types.go` 的
  > `ConnectorsKey="connectors"` / `ConfigurationNamesKey="configuration.names"`）。

- **`kube-config`（可选）** —— 跨集群运行时的 kubeconfig。

### 5.4 集群侧产出

| 资源 | 形态 |
|------|------|
| `Secret` | type `connectors.cpaas.io/bearer-token`、`stringData.token` = USER_TOKEN 值；name = `<connector-name>-secret` |
| `Connector` | `connectors.alauda.io/v1alpha1`、`spec.connectorClassName: sonarqube`、`spec.address` = SonarQube URL、`spec.auth.{name: tokenAuth, secretRef: {name, namespace}}` 指向上述 Secret |

> **注意：** `Connector` 用 **`spec.auth.{name, secretRef}`**（不是
> `spec.authRef`）。设计早期一份陈旧样例曾写成 `authRef`，SSA 会以
> `field not declared in schema` 拒绝（POC 实测 → poc.md B.2 #1）。

### 5.5 调用的 SonarQube Web API

纯 REST。

| 类别 | API |
|------|-----|
| User 生命周期 | `users/search` `\|create` `\|deactivate`、`user_groups/groups`（校验该 user 除 `sonar-users` 外不属其它组） |
| 全局权限（直发给 user） | `permissions/add_user` `\|remove_user` `\|users`（授全局 `provisioning`、审计/清理其它全局权限） |
| Permission template | `permissions/search_templates` `\|create_template` `\|add_user_to_template`（**grants 直发 user，不经 group**） `\|delete_template` |
| Token | `user_tokens/search` `\|generate`（`type=USER_TOKEN`、`login=<租户 user>`） `\|revoke` |
| 健康检查 / preflight | `authentication/validate`、`system/status`、`permissions/users?permission=admin` |

**Token 生命周期 — SonarQube 无续期 API**：`api/webservices/list` 确认
`api/user_tokens` 只有 `search`/`generate`/`revoke`，**无** `update`/`renew`/
`extend`。`generate` 同名冲突。→ 到期或刷新触发时 `ensure-token.sh` 执行
「`revoke <tokenName>` + `generate <tokenName> expirationDate=<computed>`
→ SSA 重写租户 Secret」。

**`expirationDate` 在运行时计算（cron-friendly）**：参数为
`tokenDuration` 天数；脚本调
`date -u -d "@$((now + N * 86400))" +%Y-%m-%d` 算出 `YYYY-MM-DD`
（busybox `date` 兼容：`date -u -r "${future}" +%Y-%m-%d`）。
每次 cron 运行重新签发 token 时，`expirationDate` 自动顺延 N 天 ——
避免把绝对日期写进 Pod spec / TaskRun 日志、避免人工跟踪到期。**与
GitLab Task 的 `tokenDuration` 一致**（见
`connectors-extensions/connectors-gitlab/tektoncd/tasks/
gitlab-connector-automatic-creation/0.1/task.yaml` `compute_token_expiry`）。
Harbor 同类 Task 的 `robotAccountDuration` 也是天数 —— 区别仅在 Harbor
API 原生接受 duration，本 Task 与 GitLab 一样需在脚本里换算成绝对日期。

**版本兼容（8.9 / 9.x / 25.x）**：8.9 上 `type=USER_TOKEN` 与
`expirationDate` 被静默接受（POC 实测 `sonarqube-89` v8.9.2，→ poc.md B.2 #6），
9.5/25.x 按文档生效；Task 透传无需写版本分支。

## 6. 隔离模型

租户 user 的 scoping 由 **5 条不可少的边界** 共同保证：

1. **该 user 的直接全局权限仅有 `provisioning`** —— 尤其无全局 `scan`
   （否则可扫任意项目）。`ensure-user.sh` 创建 user 后直接 grant
   `provisioning`，并校验无其它全局权限。
2. **模板的 `projectKeyPattern` 只对本租户项目 key 授权**（含项目级
   `scan`）—— grants 直发该 user。
3. **该 user 强制属默认组 `sonar-users` 且无法移除** —— 因此实例侧的
   `sonar-users` **必须**无全局权限（前置条件 P2）。
4. **`Anyone` 组（匿名）无全局权限** —— 8.9 默认在 `Anyone` 上，必须
   核查并剥除（前置条件 P2）。
5. **Default Permission Template 不能给默认组项目级 grants** —— 否则租户
   user（属 `sonar-users`）能 Browse 其它租户的项目（前置条件 P3）。

任意一条破裂都会导致跨租户泄漏。POC 已在 25.1 与 8.9 上分别实测每一条
（→ poc.md B.2 #4、#6；正/反向 scan 实证 → poc.md B.2 #6）。

## 7. 验收准则（AC 重新表述）

需 reporter / design-review 追认。原 AC 见 [feature.md](./feature.md#acceptance-criteria-from-jira)。

| AC | 原文 | Branch-3 交付方式 |
|----|------|------------------|
| AC-1 | 项目可经 API 自动创建 | Task 把租户配置成「命中 `projectPattern` 的项目在扫描自动创建时套权 + 继承 Private + 共享基线 gate/profile」。Task **使能**自动创建，不亲自执行。 |
| AC-2 | 项目级 token + 项目专属权限 | 每租户 1 个 USER_TOKEN：user 仅持 `provisioning` + key-pattern 模板直授 user + 干净的默认组 + 干净的 Default Template。 |
| AC-3 | parent 项目共享 quality gate/profile | 共享基线 = 实例默认 gate/profile（前置条件 P4）。**无法**做到每租户不同 gate。 |
| AC-4 | namespace 项目受限于自己的项目 | Private 可见性（P1）+ key-pattern 模板 + 仅持 `provisioning` 的租户 user + 干净的默认组。 |
| AC-5 | Connector + Secret 落对 namespace | Task `apply-kubernetes-resources` 步骤 SSA 落地（field manager `connector-auto`）。 |
| AC-6 | 错误处理 | preflight 校验 + 步骤内非零退出 `trap` 触发 rollback；SonarQube 错误原样暴露。 |
| AC-7 | 回滚 | tmpfs 状态文件记本次新建资源，失败时按相反顺序回退；复用的资源不动。 |
| AC-8 | 集成测试覆盖多场景 | BDD 套件 11 个用例（→ tech-design.md §5.3）。 |
| AC-9 | 文档含 API 用法 + 示例 | 概念页 + how-to 页（含部署前置条件 checklist）+ API 参考页。 |

## 8. 使用示例

### 示例 1 — 为租户 acme 配置 SonarQube 接入

```yaml
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: sonarqube-tenant-acme
  namespace: connectors-management
spec:
  taskRef:
    name: sonarqube-connector-automatic-creation
  params:
    # sonarqubeAutomationImage / imagePullPolicy 取默认（review-iteration-2 起
    # 默认为自建 v0.1.0 tag）；sonarqubeUrl 留空走 workspace 地址。
    - { name: connector,      value: acme-prod/acme-sonarqube }   # 输出 <ns>/<name>
    - { name: tenant,         value: acme }
    - { name: projectPattern, value: "^acme(:.*)?$" }
    - { name: tokenDuration,  value: "30" }
  workspaces:
    - name: sonarqube-config                                       # admin Connector 经此投递（CSI 路径）
      csi:
        driver: connectors-csi
        readOnly: true
        volumeAttributes:
          connectors: connectors-management/admin-sonarqube
          configuration.names: sonar-api                           # 见 A8
```

或用 Secret 直挂（fallback）：

```yaml
  workspaces:
    - name: sonarqube-config
      secret:
        secretName: admin-sonarqube                                # 键：address、token（或 username+password）
```

**预期 SonarQube 状态：** local user `acme-bot`（直接持全局 `provisioning`、
无其它全局权限）+ template `acme-template`（`projectKeyPattern=^acme(:.*)?$`，
5 项项目级权限直发 `acme-bot`）+ 该 user 的 USER_TOKEN。

**预期集群状态：** `acme-prod` 中 `acme-sonarqube-secret` + Connector
`acme-sonarqube`；result `connector-ref = acme-prod/acme-sonarqube`。

### 示例 2 — 之后，CI 扫描某 repo

租户 acme 的 CI 对新 repo 跑 `sonar-scanner`，传
`sonar.projectKey=acme:web-frontend` → SonarQube 自动建项目
`acme:web-frontend`（凭 `acme-bot` 的全局 `provisioning`、继承 Private +
默认 gate/profile）、创建时自动套 `acme-template` → user `acme-bot` 获
项目级权限 → 租户 token 可扫描 + 读结果。**无需额外管理员动作。**

### 示例 3 — 幂等重跑 / 失败回滚

原样重跑：user/template 复用、token 健康（API search 命中 + 租户 Secret
持有非空 token）则不重签。`ensure-token` 失败时 `trap` 运行
`rollback.sh`：revoke 本次签发的 token → 删本次新建的 template → 移除本次
新加的全局 `provisioning` grant → deactivate 本次新建的 user（复用的资源
不动）。

> 租户下线由 how-to 文档承载的清理脚本完成 — 见
> [poc.md 步骤 5](./poc.md#步骤-5--租户下线手动清理脚本不发布独立-task)。

## 9. 假设与待核实项

### 9.1 已解决

| ID | 结论 | 证据 |
|----|------|-----|
| **A1** | SonarQube 25.1 + 8.9 Community 均支持 Branch-3 | poc.md B.2 #6（8.9 端到端）+ B.1 evidence |
| **A6** | 扫描期自动创建要求租户 user **直接**持有全局 `provisioning`；模板仅授项目级 `scan` 不足 | poc.md B.3「清洁复测」 |
| **A7** | 「去 group」可行：`add_user_to_template` 与 `add_group_to_template` 对称 | poc.md B.2 #5 |

### 9.2 待 design-review 核实

| ID | 项 | 待答 |
|----|----|-----|
| **A2** | 实例供给模式 | SCIM/SSO 自动供给实例上 user / group 写入可能被拒；how-to 需记录手动 fallback。 |
| **A4** | catalog 工具镜像 | 确切引用 + tag（POC 用 `registry.alauda.cn:60070/devops/tektoncd/hub/kubectl:v1.33`）。 |
| **A5** | 5 条前置条件的落实责任与流程 | 谁在上线前对每个实例核验 P1–P5？how-to 应给出可校验 checklist。 |
| **A8** | `sonar-api` configuration 注册 | 需在 `sonarqube` ConnectorClass 中按统一文件名约定注册新 configuration。过渡期可用 Secret 直挂 fallback。 |
| **A9** | admin Connector = Administer System | 是否接受此权衡？无更细分的 user/permission 管理者可替代（POC 实测）。替代：取消 preflight、由 HTTP 403 自暴露。 |
