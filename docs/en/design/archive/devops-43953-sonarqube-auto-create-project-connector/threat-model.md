# 威胁模型 — SonarQube 自动创建 Project + Connector + Secret

<!--
risk=sensitive 时必需。经 POC 后整体改写为 Branch-3 / 每租户 模型。
在 /feature:design-review 由带 security 标签的 reviewer 评审。
-->

## 资产

- **Admin SonarQube bootstrap 凭据** —— admin Connector 中的高权限 token。
  需要的全局权限：Create Projects、Administer Permissions、Provision（签发
  token）。**不需要** Administer System（实例默认值改为部署前置条件，Task 不
  动实例设置）。仍是价值最高的资产、`risk=sensitive` 的主因。存于 admin
  Connector 的 CSI 挂载内，绝不进 Pod spec / TaskRun YAML。
- **租户 USER_TOKEN** —— 由 Task 签发给租户的 local user。它是一个**用户
  token**，承载该 user 的完整身份；其 scope 由「该 user 的直接全局权限**仅
  有** `provisioning`（即仅能 Create Projects，不能扫其它项目）+ 项目级权限
  只来自模板对本租户 `projectKeyPattern` 的授权 + 除 `sonar-users` 外不属
  其它组」来保证 —— 因此实际只能访问该租户 `projectPattern` 下的项目。
  写入租户 Secret。泄露暴露**该租户全部项目**（比项目级 token 宽，但仍限于
  单租户）。
- **租户 `sonarqube` Connector Secret**（`connectors.cpaas.io/bearer-token`）。
- **Tmpfs 凭据文件** —— `curl --config`（admin token）与 token 交接文件，
  内存 `emptyDir`。
- **租户 user 的身份边界** —— 该 user 的「直接全局权限仅有 `provisioning`、
  除 `sonar-users` 外不属其它组」是 scoping 的全部依据；一旦被加额外全局
  权限（尤其全局 `scan`）或加入别的组，scoping 即破。
- **Permission template / projectKeyPattern 完整性** —— pattern 写错或与别的
  租户重叠，会把跨租户读权限授错。

## 角色

### 合法角色

- **平台工程师** —— 提交 TaskRun；选择 `tenant`、`projectPattern`、
  `connector`（输出租户 Connector `<ns>/<name>`）。持有引用 admin Connector
  的 RBAC。
- **SonarQube / 平台运维** —— 带外准备**部署前置条件**：实例默认可见性
  = Private、实例默认 quality gate/profile = 基线、admin bootstrap 凭据。
- **Operator** —— reconcile Task 创建出的租户 Connector。
- **租户 CI / 扫描负载** —— 经 connectors proxy 用租户 Connector + token 跑
  扫描；绝不接触 admin 凭据。

### 对抗角色

- **同集群相邻租户（横向移动）** —— 想读另一租户的 Secret / token。
- **被攻陷的租户负载** —— 持有本租户 USER_TOKEN，想拿 admin 凭据（提权）、
  或想读别的租户项目。
- **Admin 凭据窃取者** —— 外泄 admin token，可创建/删除任意 group/user/
  template、签发 token。
- **Sidecar / `pods/exec` 操作者** —— 扒取 tmpfs 凭据文件。
- **catalog 供应链攻击者** —— 攻陷 catalog alpine 工具镜像。
- **被误导的平台工程师** —— 提交 `projectPattern` 写错 / 与别的租户重叠的
  TaskRun。

## 威胁

| # | 威胁 | 受影响资产 | 可能性 | 影响 |
|---|------|-----------|--------|------|
| 1 | Admin bootstrap 凭据泄露 —— 可建删任意 group/user/template、签任意 token | 实例上所有 SonarQube 资产 | 低 | 高 |
| 2 | Admin 凭据被某步骤 stdout 记录/回显（尤其 `verbose=true`） | Admin 凭据 | 低 | 高 |
| 3 | 租户 USER_TOKEN 写到错误 namespace 的 Secret（`connector` 参数 `<ns>` 拼错） | 租户 token | 低 | 中 |
| 4 | 被攻陷的租户负载外泄 USER_TOKEN，重新签发周期后重放 | 租户 token | 中 | 中 |
| 5 | 实例默认组（`sonar-users` 或 `Anyone`）持有全局权限（尤其 Execute Analysis / Create Projects）—— 租户 user 强制属于 `sonar-users` 且**无法移除**，于是继承该全局权限，token scoping 破坏（全局 Execute Analysis 可扫描任意项目）。**8.9 默认是 `Anyone` 持权，25.1 默认是 `sonar-users` 持权**。| 跨租户机密性 | 中 | 高 |
| 12 | Default Permission Template 给默认组（`sonar-users` / `Anyone`）授项目级 grants —— 所有不命中租户 pattern 的项目都会套上 Default Template；租户 user 凭其默认组成员身份就能 Browse 其它租户的 private 项目。**8.9 POC 实测：未清理前租户 token 可读其它租户的 component 数据；剥除 `sonar-users` 从 Default Template 后 → HTTP 403。** | 跨租户机密性 | 中 | 高 |
| 6 | 两个租户的 `projectPattern` 重叠 —— 租户 A 的 template 把 A 的 group 授权到 B 的项目 | 跨租户机密性 | 低 | 中-高 |
| 7 | 部署前置条件「实例默认可见性=Private」未配置 —— 扫描自动建的项目是 public，任何认证用户可读 | 跨租户机密性 | 中 | 高 |
| 8 | catalog alpine 工具镜像被替换为恶意镜像（共享供应链） | 所有资产 | 极低 | 高 |
| 9 | Sidecar / `pods/exec` 扒取 tmpfs 凭据文件 | Admin 凭据 + 租户 token | 低 | 高 |
| 10 | 步骤 0 成功、步骤 1 失败 —— SonarQube 侧租户设施已建但无集群消费者 | 租户 token | 中 | 低 |
| 11 | 被误导的工程师提交 `projectPattern` 写错的 TaskRun | 租户边界完整性 | 低 | 中 |

## 缓解措施

| # | 威胁 | 计划的缓解 | 落点 | 责任方 |
|---|------|-----------|------|--------|
| 1 | T1 | (a) admin 身份只携带**最小全局权限集**（Create Projects + Administer Permissions + Provision），不给 Administer System。(b) 只经 `sonarqube-config` CSI 挂载投递。(c) 短轮换、外部 secret 存储、CI 日志擦 `squ_` 模式 | 参考 + how-to 文档；workspace 契约 | 文档作者 + 集群管理员 |
| 2 | T2 | helper 脚本默认 `set +x`、绝不 echo token、绝不 cat tmpfs；`verbose=true` 只在非机密步骤 trace；PR 评审清单 grep token 回显 | connectors-extensions `scripts/{lib,ensure-token}.sh` | 实现者 + reviewer |
| 3 | T3 | `connector` 显式必填、形如 `<ns>/<name>`；`apply-kubernetes-resources.sh` 解析后校验该 namespace 存在再 apply | connectors-extensions `scripts/apply-kubernetes-resources.sh` | 实现者 |
| 4 | T4 | 重新签发通过 `user_tokens/revoke` 吊销旧 token 名称使重放失效；how-to 说明重新签发周期与陈旧 token 告警 | `scripts/ensure-token.sh`；how-to 文档 | 实现者 + 文档作者 |
| 5 | T5 | (a) **部署前置条件**：实例 `sonar-users` 默认组必须剥除所有全局权限（尤其 Execute Analysis、Create Projects）—— how-to 做成醒目、可校验的前置步骤。(b) `ensure-user.sh` 创建 user 时**只**授予直接全局 `provisioning`（用以扫描时自动建项目），并校验该 user 的直接全局权限**仅有** `provisioning`、除 `sonar-users` 外不属其它组，偏离则失败。(c) 注：user 无法被移出 `sonar-users`（SonarQube 默认组），故此项只能靠实例级前置条件，Task 无法在租户级修复。建议对 `sonar-users` 的全局权限做审计告警 | how-to 文档（部署前置条件）；`scripts/ensure-user.sh`；运维 | 运维 / SonarQube 管理员 + 实现者 |
| 6 | T6 | `projectPattern` 必须租户间不重叠 —— how-to 强制要求一套命名约定 + 评审；BDD 多租户隔离用例（用例 5）断言互不可见 | how-to 文档；BDD 用例 5 | 文档作者 + 实现者 |
| 7 | T7 | 「实例默认可见性 = Private」列为**部署前置条件**，how-to 显式清单 + 校验步骤；建议运维上线前用一个探针项目确认。（Task 不改实例设置 —— 见设计决策。） | how-to 文档（部署前置条件）；运维 | 运维 / SonarQube 管理员 |
| 8 | T8 | 在 `toolImage` 参数默认值固定具体 catalog 镜像 tag；依赖 catalog CI（trivy + digest）做上游监控 | Task YAML 参数默认值；catalog CI | 实现者 + catalog 维护者 |
| 9 | T9 | Pod 模板 `emptyDir.medium=Memory`、非 root、无 `shareProcessNamespace`、无 debug sidecar；`rollback.sh`/`write-results.sh` 结尾 `rm -f` tmpfs 凭据文件 | Task podTemplate；how-to 文档 | 实现者 + 集群管理员 |
| 10 | T10 | 重跑自愈：group/user/template 复用、token 见 Secret 缺失则重新签发、步骤 1 重试；how-to 说明重试姿态 | connectors-extensions 脚本；how-to 文档 | 文档作者 |
| 11 | T11 | (a) `connector` 参数是天然 RBAC 边界。(b) how-to 推荐 per-tenant ServiceAccount + namespace 级 `taskruns/create` RBAC。(c) `projectPattern` / `tenant` 的评审是控制点 | how-to 文档；集群 RBAC | 文档作者 + 集群管理员 |

## 残余风险

- **租户 USER_TOKEN 比项目级 token 宽。** 它是用户 token，承载该 user 完整
  身份；scoping 完全依赖「该 user 直接全局权限**仅有** `provisioning`、模板
  的 `projectKeyPattern` 只对本租户授权、除 `sonar-users` 外不属其它组」。
  接受，因为 (a) `ensure-user` 每次运行校验该约束，(b) how-to 要求不得手工
  给租户 user 加全局权限或加入别的组，(c) 替代方案（项目级 token）无法读
  `api/measures`、不满足扫描流水线需求（POC 实证）。建议对租户 user 的全局
  权限做审计告警。
- **依赖部署前置条件「实例默认可见性 = Private」。** 若未正确配置，扫描自动
  建的项目是 public、跨租户隔离失效（T7）。这是本设计最关键的环境依赖；
  how-to 必须把它做成醒目的、可校验的前置步骤。design-review 需确认由谁、
  在何流程保证它。
- **步骤 1 失败后的孤儿租户设施**（T10）。SonarQube 侧 group/user/template/
  token 已存在但无集群 Connector。接受 —— 重跑自愈；未重跑的 token 仍按
  `tokenExpiry` 过期。
- **共享 catalog 镜像供应链**（T8）。接受 —— catalog CI 跑 trivy + digest 固定。

## Reviewer

- **姓名：** _待定 —— 在 `/feature:design-review` 指派_
- **角色：** Security reviewer（design-review 门）
- **Security 标签：** _待定_
- **签字日期：** _待定_

**说明。** 本威胁模型只覆盖**设计期**评审。`/feature:security-sign-off` 处的
**发布前**门需针对实际发布的 bundle（RBAC 增量、端点面、镜像 digest）重新
签字，并显式记录 bundle digest。
