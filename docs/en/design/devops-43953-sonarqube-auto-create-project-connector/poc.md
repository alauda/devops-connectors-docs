# POC — SonarQube 自动创建 Project + Connector + Secret

<!--
本文同时承载：
- Part A —— 用户操作完整工作流（runbook，driver 要求）
- Part B —— POC 实证记录（spike 分支结论 + 关键发现 + 演进过程）

契约 → product-design.md  ·  实现细节 → tech-design.md
三份文档章节顺序对齐，便于同步对照。

POC 循环不计入 maturity 指标。当桌面调研无法敲定设计时，通过 POC 迭代设计
正是工作流的预期运作方式。
-->

---

## Part A — 用户操作完整工作流（runbook）

平台工程师按以下顺序在**新装 / 未配置**的 SonarQube 实例上启用本 Task。
本手册经 SonarQube **25.1 与 8.9.2** 上的 POC 端到端验证 —— 两个版本步骤
完全一致，仅默认组配置不同（→ 步骤 1.b）。

### 步骤 1 — SonarQube 实例侧一次性前置项（运维 / SonarQube admin）

**为什么需要：** Branch-3 的隔离模型靠 4 条实例级配置共同保障。Task **不**
试图自行修复（避免把 admin 凭据抬到「能修改实例设置」的高权层级），而是
做成**部署前置条件**、由 Task preflight 校验落实情况
（→ product-design.md §4）。

#### 1.a 实例默认项目可见性 = Private

```bash
curl -u admin:<PWD> -X POST "$SONAR/api/projects/update_default_visibility" \
  --data-urlencode 'projectVisibility=private'
```

扫描时自动创建的项目继承实例默认 —— 必须 Private，跨租户隔离才成立。

#### 1.b 默认组（`sonar-users` + `Anyone`）剥除全部全局权限

> POC 实测两版本默认状态：
> - **25.1**：`sonar-users` 默认持 `provisioning` + `scan`。
> - **8.9**：`Anyone` 默认持 `provisioning` + `scan`（`sonar-users` 默认无）。
>
> **保险起见两组都核验并剥除。**

```bash
for GRP in sonar-users Anyone; do
  for PERM in admin provisioning scan gateadmin profileadmin; do
    curl -u admin:<PWD> -X POST "$SONAR/api/permissions/remove_group" \
      --data-urlencode "groupName=$GRP" --data-urlencode "permission=$PERM"
  done
done
```

剥除后只有 `sonar-administrators` 持全局权限。

#### 1.c Default Permission Template 剥除默认组项目级 grants

> 8.9 默认 Default Template 给 `sonar-users` 授 `user`+`codeviewer`+
> `issueadmin`+`securityhotspotadmin` —— 不命中租户 pattern 的项目套上
> Default Template 后，租户 user（在 `sonar-users` 里）就能 Browse 别的
> 租户项目（POC 实测：未清前 HTTP 200 + 元数据泄漏；清后 HTTP 403）。

```bash
for GRP in sonar-users Anyone; do
  for PERM in user codeviewer issueadmin securityhotspotadmin scan admin; do
    curl -u admin:<PWD> -X POST "$SONAR/api/permissions/remove_group_from_template" \
      --data-urlencode 'templateName=Default template' \
      --data-urlencode "groupName=$GRP" --data-urlencode "permission=$PERM"
  done
done
```

剥除后 Default Template 仅保留 `sonar-administrators`。

#### 1.d 实例默认 quality gate + quality profiles = 共享基线

SonarQube **无** key-pattern 分发 gate/profile 机制 —— 所有新项目继承实例
默认。把实例默认配成租户共享基线（UI 或 `api/qualitygates/set_as_default`
+ `api/qualityprofiles/set_default`）。**这是 AC-3 的交付方式。**

#### 1.e admin bootstrap Connector

在集中管理 namespace（如 `connectors-management`）创建一个 `sonarqube`
`Connector` + `Secret`。**Token 必须持有全局 `admin`（Administer System）**
—— Task 用 `lib.sh::preflight()` 调
`GET api/permissions/users?permission=admin` 校验 admin login 在结果集，
缺则拒跑（→ product-design.md §9.2 A9）。

### 步骤 2 — 集群侧一次性 RBAC（每目标 namespace 一次）

Task 默认在集群内跑，租户 Connector 将落到的 namespace 需以下 RBAC：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: sonarqube-task-runner, namespace: <tenant-ns> }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: sonarqube-task-runner, namespace: <tenant-ns> }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "patch", "update", "delete"]
  - apiGroups: ["connectors.alauda.io"]
    resources: ["connectors"]
    verbs: ["get", "create", "patch", "update", "delete"]
  - apiGroups: [""]
    resources: ["namespaces"]
    resourceNames: ["<tenant-ns>"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: sonarqube-task-runner, namespace: <tenant-ns> }
subjects: [{ kind: ServiceAccount, name: sonarqube-task-runner }]
roleRef:
  { apiGroup: rbac.authorization.k8s.io, kind: Role, name: sonarqube-task-runner }
```

跨集群运行场景下绑 `kube-config` workspace 即可，集群侧不需要 RBAC。

### 步骤 3 — 每租户提交 TaskRun（一次创建）

```yaml
apiVersion: tekton.dev/v1
kind: TaskRun
metadata: { name: sonarqube-acme-onboard, namespace: connectors-management }
spec:
  serviceAccountName: sonarqube-task-runner    # 见步骤 2
  taskRef: { name: sonarqube-connector-automatic-creation }
  params:
    - { name: toolImage,       value: "registry.alauda.cn:60070/devops/tektoncd/hub/kubectl:v1.33" }
    - { name: connector,       value: "acme-prod/acme-sonarqube" }     # 输出租户 Connector <ns>/<name>
    - { name: tenant,          value: "acme" }
    - { name: projectPattern,  value: "^acme(:.*)?$" }
  workspaces:
    - name: sonarqube-config                    # admin 经此投递
      secret: { secretName: admin-sonarqube }   # 见步骤 1.e
```

**期待结果：**

| 侧 | 资源 |
|---|------|
| SonarQube | local user `acme-bot`（直接持 `provisioning`、无其它全局权限）；template `acme-template`（`projectKeyPattern=^acme(:.*)?$`，5 项项目级权限直发 `acme-bot`）；该 user 的 USER_TOKEN |
| 集群 | `acme-prod` namespace 下 Connector `acme-sonarqube` + Secret `acme-sonarqube-secret` |
| Results | `tenant=acme`、`username=acme-bot`、`permission-template=acme-template`、`token-name=acme-bot-token`、`connector-ref=acme-prod/acme-sonarqube` |

### 步骤 4 — 验证（租户开发者侧 CI 自动）

CI 对新 repo 跑：

```bash
sonar-scanner \
  -Dsonar.host.url=$SONAR \
  -Dsonar.projectKey=acme:my-repo \
  -Dsonar.login=$USER_TOKEN
```

期待日志：

```
INFO  ANALYSIS SUCCESSFUL
INFO  EXECUTION SUCCESS
```

**期待 SonarQube 侧：** `acme:my-repo` 自动创建为 `visibility=private`，
创建时自动套 `acme-template`，user `acme-bot` 获项目级权限。租户 token
读自己项目的 measures → 200；读非 acme pattern 的别人项目 →
**HTTP 403 Insufficient privileges**（隔离）。

### 步骤 5 — 租户下线（手动清理脚本，不发布独立 Task）

**设计决策：** 参照 harbor / gitlab 创建 Task 的「无下线模式参数 / 创建与
销毁解耦」惯例，本设计**不**发布独立的下线 Task；改在文档中提供对称的
清理 bash 脚本，平台工程师按需直接运行。脚本逻辑与「假设的下线 Task」
步骤一致（先 SonarQube 侧再集群侧），且天然幂等（每步先 search、缺则跳过）。

```bash
#!/usr/bin/env bash
# sonarqube-tenant-offboard.sh —— 对称撤销 sonarqube-connector-automatic-creation
# Task 产出的租户资源；幂等、安全可重跑。
set -euo pipefail

# ---- 调参（与创建 TaskRun 一致即可派生） ---------------------------------
TENANT="${TENANT:?tenant required, e.g. acme}"
CONNECTOR_REF="${CONNECTOR_REF:?'<ns>/<name>', e.g. acme-prod/acme-sonarqube}"
USERNAME="${USERNAME:-${TENANT}-bot}"
TEMPLATE="${TEMPLATE:-${TENANT}-template}"
SONAR="${SONAR:?SonarQube base URL}"
ADMIN_AUTH="${ADMIN_AUTH:?admin basic auth, e.g. token: or user:pwd}"
DEACTIVATE_USER="${DEACTIVATE_USER:-true}"   # false 时保留 user 仅清模板

NS="${CONNECTOR_REF%/*}"
NAME="${CONNECTOR_REF#*/}"
api() { curl -sS -u "$ADMIN_AUTH" "$@"; }

echo "== 1) Revoke all tokens of user $USERNAME =="
TOKENS=$(api "$SONAR/api/user_tokens/search?login=$USERNAME" | jq -r '.userTokens[]?.name // empty')
for T in $TOKENS; do
  api -X POST "$SONAR/api/user_tokens/revoke" \
    --data-urlencode "login=$USERNAME" --data-urlencode "name=$T" >/dev/null
  echo "  revoked $T"
done

echo "== 2) Delete permission template $TEMPLATE =="
api -X POST "$SONAR/api/permissions/delete_template" \
  --data-urlencode "name=$TEMPLATE" >/dev/null || echo "  (already absent)"

echo "== 3) Remove global 'provisioning' from $USERNAME =="
api -X POST "$SONAR/api/permissions/remove_user" \
  --data-urlencode "login=$USERNAME" --data-urlencode "permission=provisioning" >/dev/null \
  || echo "  (already absent)"

if [ "$DEACTIVATE_USER" = "true" ]; then
  echo "== 4) Deactivate user $USERNAME =="
  api -X POST "$SONAR/api/users/deactivate" \
    --data-urlencode "login=$USERNAME" >/dev/null || echo "  (already deactivated)"
else
  echo "== 4) Keep user $USERNAME active (DEACTIVATE_USER=false) =="
fi

echo "== 5) Delete cluster-side Connector + Secret in $NS =="
kubectl -n "$NS" delete connector "$NAME" --ignore-not-found
kubectl -n "$NS" delete secret "$NAME-secret" --ignore-not-found

echo "== Offboarding complete for tenant $TENANT =="
```

执行示例：

```bash
TENANT=acme \
CONNECTOR_REF=acme-prod/acme-sonarqube \
SONAR=https://sonarqube.example.com \
ADMIN_AUTH=squ_xxxxxxxxxxxxxxxxxxxx: \
  bash sonarqube-tenant-offboard.sh
```

**顺序约定**：先 SonarQube 侧（步 1–4）再集群侧（步 5），避免「集群侧
Connector 已删但 SonarQube 侧 user/token 还活着，外部仍能用旧 token
访问」的窗口。脚本幂等，与「上一次下线未跑完」的中间状态共存。

### 故障排查速查

| 症状 | 可能原因 / 处置 |
|------|---------------|
| `ANALYSIS SUCCESSFUL` 但项目未创建 | user 缺全局 `provisioning`（`ensure-user` 是否实际授予？） |
| HTTP 403 on `users/create` / `create_template` | admin Connector 凭据缺 Administer System（preflight 会先报出） |
| 租户 token 能读别人项目 | 步骤 1.b 或 1.c 未完整执行（默认组在 Default Template 或全局权限里） |
| `ImagePullBackOff` on Task | `toolImage` 默认值在集群上不可达；覆盖为可达 mirror（POC 用 `registry.alauda.cn:60070/devops/tektoncd/hub/kubectl:v1.33`） |

---

## Part B — POC 实证记录

### B.1 摘要

- **假设：** 一条 Tekton Task，用纯 `curl` 驱动 SonarQube Web API，
  能完成「租户 user + permission template + USER_TOKEN」+ 集群侧 SSA
  「`sonarqube` Connector + Secret」，端到端、无需自建 CLI 镜像，从而证明
  DEVOPS-43953 设计可行。
- **范围：** 内部 SonarQube `https://devops-sonar.alaudatech.net` (25.1.0
  Community) + `kychen-1/sonarqube-89` (8.9.2 Community) + driver 的 kube
  集群（`direct-connect` context）。脚本与真实 Tekton Task 两种形态都跑过。
- **分支：** `connectors-extensions` 仓 `poc/devops-43953-auto-create-e2e`，
  commit `b396ce0`（**仅本地**；本环境对该仓只有只读权限，未 push）。
  Spike 文件镜像到 [`poc-artifacts/`](./poc-artifacts/)。
- **结果：** ✅ **validated** —— 端到端假设成立；POC 还暴露并修正了 7 处
  具体的设计点（→ B.2）。

### B.2 关键发现（全部已并入设计）

#### F1 — 租户 Connector schema：`spec.auth` 而非 `spec.authRef`

集群上的 `connectors.alauda.io/v1alpha1` `Connector` 用
`spec.auth: { name: <authType>, secretRef: { name, namespace } }`。设计早期
一份陈旧样例写成 `spec.authRef.name`，SSA 会以 `field not declared in schema`
拒绝。→ product-design.md §5.4、tech-design.md 任务 7 均已修正为
`spec.auth.{name: tokenAuth, secretRef: {name, namespace}}`。

#### F2 — 工具镜像合并为单个 alpine kubectl 镜像

catalog `sonarqube-shell` 镜像 **没有 `curl`**（第一次 TaskRun 以
`curl: command not found` 失败）；catalog **`kubectl` 镜像基于 alpine，
自带 `bash`+`curl`+`jq`+`kubectl`**，跑通整个 Task。→ 设计中的双镜像
拆分合并为**一个** `toolImage`，无 Containerfile（A4 收敛）。

#### F3 — B2 三分支决策 → 选 Branch-3

真实的 catalog `sonarqube-scanner` Task 把 B2 拆出三个选项（均针对真实
实例测过）：

| 分支 | 模型 | 关键限制 | 验证 |
|------|------|---------|------|
| **Branch 1** | 项目级 `PROJECT_ANALYSIS_TOKEN`（设计原假设） | 可分析、可轮询 `api/ce/task`，但 `api/measures/component` → **HTTP 403 Insufficient privileges**；token *类型*仅可分析，授予 Browse 的模板**无法**解除该限制 | 测过 → 拒绝 |
| **Branch 2** | 每项目专用 user + USER_TOKEN | 完整 API 能力，但用户生命周期随项目数线性增长 | 未做端到端 |
| **Branch 3**（当前设计） | 每租户 user + key-pattern permission template + USER_TOKEN | 完整 API 能力 + 可控生命周期（user 数 = 租户数）；约束：租户 user 必须**只**持 `provisioning`、scope 由 5 条边界共同保证（→ product-design.md §6） | 端到端 PASS（25.1 + 8.9） |

> Branch-3 验证脚本：[`poc-artifacts/branch3-verify.sh`](./poc-artifacts/branch3-verify.sh)。

**B2 决议：Branch-3。** 也是唯一同时具备完整 API 能力与可控生命周期的选项。

#### F4 — scoping 不能靠「踢出 sonar-users」实现 → 实例级前置条件

POC 追测发现：SonarQube 把每个 user 强制加入默认组 `sonar-users` 且
**无法移除**（`api/user_groups/remove_user` 对默认组返回 `400 Default
group cannot be used`）。因此：

- **租户 user 的 scoping 必须**靠 **实例级前置条件**：默认组（`sonar-users`
  + `Anyone`）剥光全局权限 + Default Permission Template 剥光默认组项目级
  grants —— 任一条破裂即跨租户泄漏。
- **8.9 实测：** 未清前租户 token 调
  `api/measures/component?component=other-tenant:probe-2` → **HTTP 200** +
  component 元数据可读。剥除全局 `Anyone` 权限后**仍**泄漏（Default Template
  里 `sonar-users` 仍有 grants）；继续剥除 Default Template grants 后 →
  **HTTP 403 Insufficient privileges**，隔离恢复。

**清洁复测（A6 解决）：** 在默认组已剥光全局权限的前提下：

| Test | 设置 | 结果 |
|------|------|------|
| 1（最小权限假设） | 模板只授项目级 `scan`、user 仅在租户 group + `sonar-users` | 扫描时 `You're not authorized to analyze this project or the project doesn't exist on SonarQube and you're not authorized to create it`；项目**未**创建 |
| 2（直接授全局 `provisioning`） | Test 1 + 额外给 user 授全局 `provisioning` | **扫描成功**，项目自动创建（`acme-bot-43953` 触发） |

→ 扫描期自动创建项目**要求 user 直接持有全局 `provisioning`**；模板的项目
级 `scan` 单独不足。设计采纳：`ensure-user.sh` 创建 user 后直接 grant
`provisioning` + 校验无其它全局权限。

→ product-design.md 部署前置条件 P1–P4 全部由此而来。

#### F5 — 「去 group」可行 → permission template 直挂 user（A7 解决）

`add_user_to_template` 与 `add_group_to_template` 对称。Test 3：把 Test 2
的 user 移出租户 group、用 `add_user_to_template` 把模板权限直发 user →
扫描照样成功，项目自动创建。**结论：** 本设计是「每租户 1 user」的 1:1
模型，租户 group 是冗余的间接层。

**对设计的影响：**

| 项 | 改动 |
|---|------|
| 每租户 SonarQube 资源 | 5 件（1 user + 1 template + 1 USER_TOKEN + 1 Connector + 1 Secret），比含 group 的版本少 1 件 |
| 任务拆解 | 去 `ensure-group.sh`；参数去 `groupName` |
| `ensure-template.sh` | 改用 `add_user_to_template` |
| `rollback.sh` | 去 `delete group` 步骤 |

#### F6 — SonarQube 8.9.2 端到端通过 + Default Template 隔离漏洞

Driver 要求验证 Branch-3 在老 LTS 上的可行性。在 `kychen-1/sonarqube-89`
部署干净的 8.9.2-community（embedded H2、`node.store.allow_mmap=false` 绕开
`vm.max_map_count` sysctl、PSP restricted-compliant SC）。

**✅ Branch-3 全步骤在 8.9 上通过：**

- `users/create` + `permissions/add_user permission=provisioning` 直发 user
  → 204。
- `permissions/create_template` + 5 项 `add_user_to_template`（user /
  codeviewer / issueadmin / securityhotspotadmin / scan，直接挂 user）→ 204。
- `user_tokens/generate`：8.9 上**静默接受** `type=USER_TOKEN` 与
  `expirationDate` 参数（返回 200 + token） —— Task 透传，无需写版本分支。
- sonar-scanner 跑命中 pattern 的 key → `ANALYSIS SUCCESSFUL`，项目
  **自动创建** `visibility=private`、template 自动套用。
- 租户 token 读自己项目 measures → 200，6 项 metric 全返回。

**⚠️ 新发现：默认组与 Default Template 的隔离漏洞（跨版本通用）。** 8.9
默认状态下 `Anyone` 持 `provisioning` + `scan`（25.1 上是 `sonar-users` 持
这两项）；且 Default Template 给 `sonar-users` 授 `user`/`codeviewer`/
`issueadmin`/`securityhotspotadmin`。后果与设计影响详见 F4。两条
25.1 与 8.9 通用，已并入 product-design.md §4 P2、P3 与 threat-model.md
T5、T12。

> POC 实测脚本：
> [`poc-artifacts/branch3-89-validate.sh`](./poc-artifacts/branch3-89-validate.sh)、
> [`poc-artifacts/branch3-89-scan.sh`](./poc-artifacts/branch3-89-scan.sh)、
> [`poc-artifacts/sonarqube-89.yaml`](./poc-artifacts/sonarqube-89.yaml)。

#### F7 — 真 Tekton Task + TaskRun 端到端：正向 + 反向 scan 隔离实证

Driver 要求把 POC 从「裸 Pod 跑脚本」升级为「真 Tekton Task + TaskRun」，
并让 scan TaskRun 使用本设计**自动创建出来的** `sonarqube` Connector
（而非静态 token）。部署在 `kychen-1`：

**a) onboarding Task / TaskRun** ([`poc-artifacts/sonarqube-task-branch3.yaml`](./poc-artifacts/sonarqube-task-branch3.yaml))：

- 3 步 inline-script Task（throwaway POC 形态，不是 render-tool）：
  `ensure-tenant`（preflight + ensure-user + ensure-template + ensure-token）
  → `apply-kubernetes-resources`（SSA Secret + Connector）→ `write-results`。
- workspace `sonarqube-config` 用 Secret-直挂（admin Secret
  `sonarqube-89-admin` 含 `address`/`username`/`password` —— 统一文件名
  约定的 Basic auth 路径）。
- RBAC：在 ns 预创建 `sonarqube-task-runner` SA + Role。
- 实跑 TaskRun `sonarqube-acme-tr-onboard` → **Succeeded**，35s；5 results
  全返回；Connector `acme-tr-sonarqube` reconcile 全绿（7/7 conditions=True）。

**b) ✅ 正向 scan TaskRun**（catalog `sonarqube-scanner@0.6`，同 YAML 内）：

- **关键**：`sonar-credentials` workspace 经
  `csi.driver=connectors-csi`、`volumeAttributes: { connectors:
  kychen-1/acme-tr-sonarqube, configuration.names: sonar-scanner }` 挂载
  **a) 步骤产出的 Connector** —— CSI 驱动按 ConnectorClass `sonar-scanner`
  配置渲染 `sonar-project.properties` + 由 connectors-proxy 注入真实 token，
  scanner 完全不见静态凭据。
- `sonarProjectKey=acme-tr:demo-scan`（命中 `^acme-tr(:.*)?$`）。
- TaskRun `sonarqube-acme-tr-scan` → **Succeeded** 102s；`code-scan-metrics`
  返回 28 项（`alert_status=OK`、`ncloc=4`、`bugs=0` 等）；项目自动创建
  `visibility=private`、模板自动套用。

**c) ❌ 反向 scan TaskRun（隔离实证）** —— 同一个 acme-tr Connector，
`sonarProjectKey=demo-89:cross-tenant-probe`（**不**命中 `^acme-tr(:.*)?$`）：

- sonar-scan 抛 `EXECUTION FAILURE` + `You're not authorized to run
  analysis. Please contact the project administrator.` → exit 1。
- TaskRun `sonarqube-acme-tr-scan-negative` → **Failed** 86s。
- SonarQube 侧验证：`demo-89:cross-tenant-probe` **未**自动创建
  （`api/projects/search?projects=...` total=0）。

**结论**：自动创建出来的 Connector token scope 由 `projectPattern` 锚定
—— 不命中本租户 pattern 的 key 即拒绝。Branch-3 的「user 仅持全局
`provisioning` + 模板对本租户 pattern 授权」对扫描期的越权 attempt 是**真实
有效**的边界。

**d) CSI volume attribute keys 修正** —— 设计稿原写法
`driver: connectors.csi.alauda.io` / `connector: ...` /
`configuration: ...` 均与驱动实际 schema 不符；驱动报
`connectors or connector.name is required`。已修正为
`driver: connectors-csi` / `connectors: <ns>/<name>` /
`configuration.names: <name>` —— 见 sibling repo
`connectors/pkg/csidriver/types.go` 的 `ConnectorsKey="connectors"` /
`ConfigurationNamesKey="configuration.names"`。product-design.md §5.3 已同步。

> POC 实测脚本：
> [`poc-artifacts/sonarqube-task-branch3.yaml`](./poc-artifacts/sonarqube-task-branch3.yaml)、
> [`poc-artifacts/sonarqube-scan-via-connector.yaml`](./poc-artifacts/sonarqube-scan-via-connector.yaml)。

### B.3 演进过程（已并入设计的迭代速记）

POC 期间还经过若干次设计修正、它们已全部并入设计、此处仅作存档：

- **A1 已解决** —— SonarQube 25.1 Community 端到端可行；Project Analysis
  token、permission template、`qualitygates/select`、`qualityprofiles/add_project`
  均可用；不依赖 Enterprise。
- **A3 已敲定** —— 凭据投递经 Secret-backed workspace + `curl --config`
  —— 比设计假设的「CSI 挂载 `sonar-scanner` 配置」更简单，且把凭据挡在
  Pod spec 之外。25.1 上账号密码 Basic auth 可用（设计假设的是 token）。
- **幂等 / 回滚模型已确认（AC-6、AC-7）** —— token 值由
  `user_tokens/generate` 只返回一次且不可再读；集群 Secret 是唯一持久副本。
  设计的「当且仅当 token 在 SonarQube 上存在 **且** 租户 Secret 已持有时
  复用，否则 revoke+mint」是正确规则；回滚只回退本次新建资源已演示。
- **RBAC 要求** —— Secret + Connector 的 SSA 要求 Task SA 对目标 namespace
  的 `secrets` 与 `connectors` 持有 **`patch`**（不只是 `create`）。已并入
  Story-3 how-to / Story-4 operator 接线文档。
- **Branch-1 时代的废弃发现**（已被 Branch-3 取代，仅为历史记录）：
  - *project key 必须事先确定* —— `PROJECT_ANALYSIS_TOKEN` 只能为已存在
    项目签发（`user_tokens/generate` 拒绝未知 `projectKey`）。该约束在
    Branch-1 下让「auto-create 与扫描期自动建项目共存」成为矛盾；
    Branch-3 模型靠 USER_TOKEN（不依赖项目存在）天然规避。
  - *扫描期 measures 403* —— `PROJECT_ANALYSIS_TOKEN` 能提交分析、能轮询
    CE task，但 `api/measures/component` 返回 403。该限制是 token *类型*
    层面的、permission template 无法解除 —— 直接导致 B2 决议从 Branch-1
    切到 Branch-3。
- **`visibility=private` 必须在创建时定** —— 4 个 POC 项目用默认
  `api/projects/create`（无 `visibility` 参数）创建，结果都是 `public` ——
  与实例默认一致。Outsider user token 可读 measures、`api/components/
  search_projects` 返回 6600 个全实例项目。`api/projects/update_visibility`
  连 admin 都 403 —— 稳妥路径是创建时定 `visibility=private`。
  Branch-3「Task 不建项目」后该条**演化**为部署前置条件 **P1「实例默认
  可见性 = Private」**（→ product-design.md §4）。
- **`sonarqube-config` workspace 双挂载形态（设计追加）** —— SonarQube
  没有标准 CLI 配置文件（不像 git `.gitconfig` / maven `settings.xml`），
  既有的 `sonar-scanner` connector configuration 是 scanner CLI 的属性
  文件，与本 Task 调 Web API 的需求无可复用之处。设计追加
  `sonarqube-config` 同时支持 Connector-CSI 与 Secret 直挂、由 `lib.sh`
  自动识别（→ product-design.md §5.3）。新增 A8 假设跟踪 `sonar-api`
  configuration 注册。

### B.4 经验杂记

- driver 的 kubeconfig `proxy-connect` context 不稳定 —— discovery 陈旧
  （`no matches for kind "Connector"`）、`auth can-i` 答案不一致。
  `direct-connect` context 可靠。仅环境问题；无设计影响，但 QA 值得知道。
- `apply_template` 返回 HTTP `204`；`user_tokens/generate` 在其 JSON body
  中只返回一次 token 值。
- 目标集群上 `sonarqube` `ConnectorClass` 已安装，所以该 Task 创建的
  Connector 能自行完整 reconcile。
- SonarQube 项目 key 可含 `:`（如 `acme:web-frontend`），与租户
  key-pattern 方案天然契合。
- 整个流程约 9 次 SonarQube Web API 调用 + 1 次 `kubectl apply` —— 足够
  轻量，无需自建镜像、无需 SonarQube CLI、无需 init 步骤。

### B.5 POC 在系统上遗留的资源

POC 把测试产物原地保留供 driver 检查（未自动删除）：SonarQube 项目
`poc-devops-43953`、`poc-devops-43953:team-a`、`poc-devops-43953:via-taskrun`、
`acme-tr:demo-scan`、`acme-89:autocreate-89-1`；template `poc-43953-parent`、
`poc-43953-namespace`、`acme-template`、`acme-tr-template`；以及 namespace
`kychen` / `kychen-1` 中的 `Connector` / `Secret` 对（label
`poc.devops=43953`）。`poc-run.sh cleanup`、Part A 步骤 5 的 offboard
脚本、与一条 label-selector `kubectl delete` 可清除它们。
