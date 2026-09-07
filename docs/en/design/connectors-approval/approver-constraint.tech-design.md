# AccessPolicy 审批人约束 — 技术方案（DEVOPS-44347）

- Jira: [DEVOPS-44347](https://jira.alauda.cn/browse/DEVOPS-44347) AccessPolicy 可以约束到具体的审批人
- 来源: [DEVOPS-43150](https://jira.alauda.cn/browse/DEVOPS-43150) 制品晋级流水线模板
- 状态: 设计中
- 实施仓库: `connectors`（核心实现）、`connectors-operator`（本设计文档）
- 关联设计: [approval.tech-design.md](./approval.tech-design.md)、[product-design.md](./product-design.md)

## 1. 背景与问题

Connectors 审批能力（`AccessPolicy` / `AccessRequest`）当前只消费流水线中 `ApprovalTask` 的
`status.state` 布尔化结果，**不校验审批由谁作出**。由此产生两个问题（记录于 DEVOPS-44347 评论）：

1. **审批规则分散**：谁能审批、需要几人审批，唯一载体是各条流水线里的 `ApprovalTask` spec。
   规则变更时必须批量修改所有流水线，无法中心化配置。
2. **制品晋级流水线模板无法交付**：模板中审批人无法硬编码，只能作为流水线参数存在；
   而"由谁审批"不应该由触发人决定 —— 参数化审批人与晋级的业务预期矛盾。

安全视角的根因：拥有流水线创建/修改权限的开发者可以修改 `ApprovalTask` 的审批人参数，
自己审批自己，存在越权风险（DEVOPS-43150 评论，2026-05-15）。

## 2. 现状机制摘要

审批链路（代码位置以 `connectors` 仓库 main 分支为准）：

```
Task Pod 经 CSI 挂载 connector 凭据
  → CSI 创建 AccessRequest                    (pkg/csidriver/nodeserver_rbac.go:221)
  → AccessRequestReconciler:
      syncAccessPolicy    匹配 AccessPolicy 并快照     (accessrequest_controller.go:923)
      syncAccessCheck     逐条评估 checks              (accessrequest_controller.go:1000)
        loadCheckRuleSpec       ref(ConfigMap)|spec 二选一   (:1130)
        renderCheckSelector     JSONPath 渲染 label selector
        fetchCheckResources     dynamic client 拉取 check 资源(duck type)
        checkStateEvaluator.Eval  状态判定                  (:1105)
          ├─ CheckStateRegoEvaluator   state.rego 非空: package "check"、
          │                            input = 资源对象本身、输出反序列化为 knative Condition
          └─ CheckStateDefaultEvaluator 默认: 读 status.conditions Ready/Succeeded
      AggregatePoliciesCheckState  聚合                (accessrequest_funcs.go:93)
      syncPermissionForMatchedPolicy  True→建 Role/RoleBinding; False→删; Unknown→等待 (:496)
  → CSI 轮询 AccessRequest 顶层 condition，SAR 通过后挂载放行
```

关键事实：

- check 框架是**类型无关**（duck-typed）的：目标资源由 `CheckSelector`（label selector +
  objectRef GVK）定位，judgment 由 rego 或默认 duck condition 完成。集成测试用 ConfigMap
  充当 check 目标以避免与 TektonCD 耦合。
- 内置 check 规则模板 `approvals-in-pipeline`（`config/accesspolicy/approvals-in-pipeline-configmap.yaml`）
  匹配 `openshift-pipelines.org/v1alpha1 ApprovalTask`，rego 仅读 `status.state` 映射
  approved/rejected/pending → True/False/Unknown。
- 上游 `ApprovalTask.status.approversResponse[]` 记录了每个审批人的
  `{name, type(User|Group), response, groupMembers[]{name, response}}` —— 这是**可信的**
  审批人记录：manual-approval-gate 的 webhook 认证请求人身份后由其 controller 写入
  status 子资源，普通用户无 `approvaltasks/status` update 权限。
- 与之相对，`ApprovalTask.spec.approvers` 是流水线侧声明，触发人可控，**不可作为信任来源**。
- Feature flag：整条审批链路受 `enable-connectors-approval` 控制（`featureflags/flags.go`）。

## 3. 目标与非目标

**目标**

- G1: AccessPolicy 能够表达"审批必须由指定的人/组作出、需满足最少人数"，中心化维护。
- G2: 非指定审批人的 approve 不产生授权（fail-closed），并给出可排障的明确原因。
- G3: 保持 check 框架类型无关：不新增 Check 分支、不在 API 层引入审批专有 schema。
- G4: 无审批人约束的存量 AccessPolicy 行为完全不变。
- G5: 制品晋级流水线模板可交付：审批人参数退化为 UX 路由输入，不再是信任来源。

**非目标**

- 不做 AccessPolicy 驱动创建 ApprovalTask/CustomRun（DEVOPS-44347 评论中的"解法2"，
  作为后续演进方向另行立项）。
- 不改 manual-approval-gate / tektoncd-operator（跨团队方案已排除）。
- 不做基于 tag/path 的细粒度规则（独立 backlog）。
- 不为 ConfigMap 模板引入 params schema 声明/校验层（见 §4 方案 B 的否决理由与
  §5.6 的替代 guardrails）。

## 4. 数据结构方案对比

三个候选共享同一前提（本轮设计讨论已确认）：判定统一发生在现有 rego evaluator 中，
新增数据结构只承担**数据提供**职责，不构成新的 Check 方式。

### 方案 A（选定）：`CheckRule.params` 弱类型参数（复用已有 `kmetav1alpha1.Params`）

```yaml
checks:
- name: approval-check
  ref:
    configMap:
      name: approvals-in-pipeline
  params:
  - name: approvers
    value: ["alice", "group:ops-leads"]   # Tekton 风格 array 值
  - name: numberOfApprovalsRequired
    value: "1"                             # Tekton 风格 string 值
```

params **直接复用 connectors 已在用的 `kmetav1alpha1.Params`**（Tekton 风格：值是
string/array/object，数字以字符串 `"1"` 承载），不新造类型。求值时把**整个 check 自身**
注入 rego input（`input.check`），rego 经 `input.check.params` 读参数；内置模板对
`approvers` **有值才做审批人判断，完全缺席则维持旧行为**。

- ✅ check 框架的弱类型概念完整保留，无特例分支。
- ✅ 对 ApprovalTask 的全部知识（GVK、label、status 形状、判定逻辑）都在可随版本替换的
  配置层；将来加新约束维度 = 改 ConfigMap rego + UI，API 零改动。
- ✅ per-policy 值与共享模板天然解耦：params 属于 policy，模板保持共享。
- ⚠️ 残余成本（睁眼接受）：无 UI 的 YAML/GitOps 用户面对松散 name/value，错误反馈延迟到
  reconcile 期；安全逻辑保障从结构性（编译器/webhook）变为纪律性（rego 自防御 + OPA 测试，
  见 §5.6，为红线非建议）。

### 方案 B（否决）：强类型字段作为数据提供方

在 `CheckRule` 增加 `approval: {approvers: [{name,type}], numberOfApprovalsRequired}` 强类型
字段，controller 将其序列化后注入 rego input，判定仍在 rego。

- 否决理由 1（决定性）：**API 字段近乎永久**，而这套字段的形状需与审批资源的能力对齐；
  审批目标是 duck type（可能是 ApprovalTask、测试用 ConfigMap、未来其他资源），
  在 API 层固化审批词汇打破 check 框架的类型无关设计。
- 否决理由 2：强类型的主要收益（webhook 深度校验、kubectl explain 自解释）在产品实际
  入口是 UI 的前提下大幅贬值 —— UI 直接渲染已知字段即可（见 §5.7），schema 只需在 UI
  写一遍，不必在 API 再写一遍。

### 方案 C（否决）：额外的用户自定义 rego 表达式

在 check 上增加第二个 rego 槽位，由 policy 作者编写"审批状态成功 && 审批人为 xxx"的
完整判定，与模板基础判定 AND 合成。

- 否决理由 1（决定性）：**把安全关键逻辑的作者换成最不专业的一方**。客户管理员写的 rego
  若误读 `spec.approvers`（可伪造）而非 `status.approversResponse`，或遗漏 default-deny，
  直接 fail-open；webhook 只能校验 rego 编译，校不出语义错误。
- 否决理由 2：审批人变更不可治理 —— 改审批人 = 改一段 rego 字符串，diff/审计不可读，
  而"谁能批生产"恰是最需要非技术角色 review 的配置。
- 备注：该能力的实质（自定义完整判定）通过现有内联 `spec.state.rego` 已经可用
  （input 即完整资源对象），作为高级逃生门保留，无需新增槽位。

### 结论

采用**方案 A**。决策准绳：架构一致性（弱类型框架无破口）+ 耦合位置正确（配置层可替换）
优先；体验短板由 UI 承接（§5.7），安全短板由模板自防御 + CI 测试承接（§5.6）。
当前处于 v1alpha1 + feature flag 窗口，若 GitOps 场景被验证为主流，将来在 params 之上
补类型化字段是纯增量演进。

## 5. 详细设计

### 5.1 API 变更（`pkg/apis/connectors/v1alpha1/accesspolicy_types.go`）

```go
import kmetav1alpha1 "github.com/AlaudaDevops/pkg/apis/meta/v1alpha1"

// CheckRule 现有 Name/Ref/Spec 不变，新增 Params —— 直接复用已有类型，不造新轮子：
type CheckRule struct {
	Name string         `json:"name"`
	Ref  *CheckRuleRef  `json:"ref,omitempty"`
	Spec *CheckRuleSpec `json:"spec,omitempty"`

	// Params are passed to the check rule's rego evaluation, accessible as
	// input.check.params. Params are data only: they do not change which
	// evaluator runs. Reuses kmetav1alpha1.Params (the Tekton-style param
	// type already used by ConnectorClass.Spec.Params) — values are
	// string/array/object (a number is carried as the string "1").
	// +optional
	Params kmetav1alpha1.Params `json:"params,omitempty"`
}
```

- `kmetav1alpha1.Params` = `[]Param{Name string, Value ParamValue{Type, StringVal,
  ArrayVal, ObjectVal}}`（`github.com/AlaudaDevops/pkg/apis/meta/v1alpha1`，connectors
  已依赖，`ConnectorClass.Spec.Params` 就是它）。**不新增 `apiextensionsv1.JSON` 自定义
  Param**（review 意见 note 19263/19286）。代价：数字以字符串 `"1"` 承载（rego 侧 `to_number`）。
- `ref` / `spec` 互斥关系不变；`params` 与两者均可组合（对 `ref` 是主用法；对内联
  `spec` 同样注入 —— params 是数据，语义统一为"喂给该规则的求值过程"）。

### 5.2 Rego input 契约

input 从"只有被 check 的资源对象"扩为 `{object, check}`（review 意见 note 19292）：

```
{
  "object": <要 check 的资源对象>,   // 当前已有，不变
  "check":  <当前 check 自身的数据>   // 新增，rego 经 check.params 读参数
}
```

| 字段 | 内容 |
|---|---|
| `input.object` | 被 check 的资源（ApprovalTask / ConfigMap-duck），**语义完全不变** |
| `input.check` | 当前 check 规则自身；`input.check.params` = `kmetav1alpha1.Params` 数组 |

- 注入点：`CheckStateRegoEvaluator.Eval`（`accessrequest_controller.go` 内）。签名传入当前
  check，组装 `{object, check}` 作为 input。default（duck-condition）evaluator 不受影响。
- **兼容性（已定：统一 `{object, check}`，破坏性变更）**：input 无条件包一层，任何直接读
  `input.data.*` / `input.status.*` 把 input 当资源本身的 check-state rego 都会失效，必须迁移到
  `input.object.*`。范围**不止内置模板与审批人 fixture**——所有 check-state rego（内置模板 +
  全部集成 testdata 的 inline check rego + 用户存量 inline rego）都要一起迁移。实现时集成回归
  暴露了这点：`approvals-by-configmap` / `multi-match` / `check-failed-jsonpath` / `csi-approval`
  等基线 fixture 最初漏改（读 `input.data.state`）→ 8 个基线场景回归失败，已随实现 MR 全量迁移到
  `input.object.data.state`。**release note 必须标注**该 input 契约变更；proxy-auth rego
  （`pkg/proxy/auth`）是另一条求值路径，不受影响。
- 实施注意：`evaluateLoadedCheckStateWithRego`（package "approval"）与 `accesspolicy_webhook.go`
  的校验 query（`data.approval.status`）是与活跃路径（package "check"、变量 `result`）不一致的
  遗留死代码——已在实现 MR 删除 / 修正。
- **webhook 校验 query 修正非破坏性**（review 问题 1）：运行时求值走
  `connectorrego.Expression.WithPackage("check").WithVariable("result")` → query
  `result = data.check.result`。webhook 里原先的 `status = data.approval.status`
  引用的 package/变量**没有任何运行时路径使用**（是纯遗留不一致），只在 admission 时做
  rego 编译门。改成 `result = data.check.result` 是让"校验契约"与"运行时契约"对齐：任何真正
  能在运行时求值的 rego（package "check" + `result`，也是文档/模板教的写法）继续通过校验；
  唯一会新失败 admission 的，是那些**本来运行时就取不到 `result`、已然不工作**的对象。故非破坏。

### 5.3 内置 ConfigMap `approvals-in-pipeline` 原地升级

**沿用现有名称**（存量 policy 以名称引用，改名即破坏兼容）。部署态实际名称带
kustomize 前缀（如 `connectors-approvals-in-pipeline`，ns 随部署形态）。注意与集群上
可能存在的 `connectors-approvals-by-configmap` 区分：后者是 BDD 集成测试创建的
ConfigMap-duck check 规则（objectRef kind=ConfigMap，读 `data.state`），非内置模板；
本方案的集成测试可为其新增 params 变体以便脱离 TektonCD 验证 params 链路（IT5）。`data.spec` 的 selector 不变，
`state.rego` 升级为（**清晰优先、只保必要健壮性**，review 意见 note 19296/19303；最终语法以实现
单测通过版本为准）：

```rego
package check

obj := input.object

# check.params 是 kmetav1alpha1.Params；每个 param 的 value 已是 native 值
# （string/array/object，由 kmetav1alpha1.ParamValue.MarshalJSON 序列化为裸值），
# rego 直接读 params[i].value —— 不复用库已有的序列化就是重复造轮子（review note 19xxx）。
check_params := object.get(object.get(input, "check", {}), "params", [])

# approvers：名为 approvers 的 param 的 value（即数组本身）；缺省空
default approvers := []
approvers := value {
	some i
	check_params[i].name == "approvers"
	value := check_params[i].value
}

# numberOfApprovalsRequired：同名 param 的 value（字符串）转数字；缺省 1；
# 下限为 1——值 < 1 退回缺省 1（自审发现的 fail-open：approvers 有值时 "0" 会让
# count(approved) >= 0 恒真、approvedBy 为空也放行；floor 后约束永不弱于"1 名真实指定审批人"）。
default required := 1
required := n {
	some i
	check_params[i].name == "numberOfApprovalsRequired"
	value := check_params[i].value
	value != ""
	n := to_number(value)
	n >= 1
}

has_constraint { count(approvers) > 0 }

state := object.get(object.get(obj, "status", {}), "state", "")
responses := object.get(object.get(obj, "status", {}), "approversResponse", [])

user_entries  := {a | a := approvers[_]; not startswith(a, "group:")}
group_entries := {substring(a, 6, -1) | a := approvers[_]; startswith(a, "group:")}

matched_users := {r.name |
	r := responses[_]
	object.get(r, "type", "User") == "User"
	r.response == "approved"
	user_entries[r.name]
}
matched_group_members := {m.name |
	r := responses[_]
	r.type == "Group"
	group_entries[r.name]
	m := r.groupMembers[_]
	m.response == "approved"
}
approved := matched_users | matched_group_members

# 决策级联（deny-by-default）
result = r {
	state == "rejected"
	r := {"status": "False", "reason": "Rejected"}
} else = r {
	state == "approved"
	not has_constraint                 # 无 approvers：维持旧行为（纯状态检查）
	r := {"status": "True", "reason": "Approved"}
} else = r {
	state == "approved"
	count(approved) >= required
	r := {"status": "True", "reason": "ApprovedByRequiredApprovers", "approvedBy": sort(approved)}
} else = r {
	state == "approved"
	r := {"status": "False", "reason": "ApproverMismatch", "approvedBy": sort(approved)}
} else = r {
	r := {"status": "Unknown", "reason": "Pending"}
}
```

**刻意不做的**（review 意见 note 19296/19303：只保必要健壮性，不为不必要的防御牺牲可读性）：
- **不做 unknown-param 拒绝**：拼错 param 名 → 该约束不生效、退回旧行为，而非 `False`。可读性/
  可维护性优先；真要防拼写错交给 UI + 文档，不在 rego 里堆 `known_params`。
- **不做 invalid-param 逐类报错级联**：值形状异常时按"取不到值/缺省"自然退化，不额外造
  `InvalidParam` 分支。

语义要点：

- **有 approvers 才判断，缺席即旧行为**（G4）。
- **`ApproverMismatch` 是 False 终态而非 Unknown**：ApprovalTask 的 approved 为终态，
  错误的人先批后指定审批人无法补批，挂 Unknown 只会让 Pod 空等到 task timeout；
  False 快速失败且 message 写明差异，直接回应"流水线显示审批通过但任务失败"的排障诉求。
- **False 同时是 AccessRequest 级终态**（集成测试实证，2026-07-16）：check False 触发
  RBAC 清理后 `PermissionSync.Reason=PermissionCleanUp`，`IsFinalState()` 生效，controller
  的事件 predicate 与 check 资源映射（`mapCheckResourceToAccessRequests`）均不再投递该
  AccessRequest——即使 check 资源随后满足约束也不会"复活"。这是既有产品语义且是安全
  性质（防止清理后被晚到事件重新授权）；恢复路径 = 重跑流水线产生新 AccessRequest。
  用户文档需写明。
- **Group 约定**：`"group:<name>"` 前缀。组成员的审批记录信任 manual-approval-gate 写入的
  `approversResponse[].groupMembers`，connectors 不对接 IDP 解析组成员（信任边界声明）。
- 计数 = `approved_identities` 去重后的**不同身份数**（组成员逐人计入）。

### 5.4 Controller 变更

- 链路透传当前 check：`CheckStateRegoEvaluator.Eval` 组装 `input = {object: <资源>,
  check: <当前 check（含 params）>}` 喂给 rego（不再预抽 params 成 map，直接
  `json.Marshal(check)` 注入；每个 param 的 `value` 就是 `kmetav1alpha1.ParamValue`
  序列化出的 native 值，rego 直接读 `input.check.params[i].value`，**不做**逐字段展开——
  复用库已有的序列化能力，review 问题 2）。
- **无 Rego 配置时的判定（`CheckStateDefaultEvaluator`，不改动，review 问题 3）**：
  check 规则若没配 `state.rego`，走默认求值器——它读被 check 资源的 knative duck 状态里
  `Ready` / `Succeeded` 类型的 condition：`True` → `AccessCheckReady=True/Passed`，
  `False` → `False/Rejected`，其余（含找不到该 condition）→ `Unknown/Pending`。**`params`
  在此路径完全被忽略**（审批人约束是纯 rego 能力，只有配了 rego 的 check 才消费 params）。
  内置 `approvals-in-pipeline` 模板本身配了 rego，故走 rego 路径；此默认路径是给"仅凭资源
  duck-condition 判定、无需自定义逻辑"的 check 用的。用户文档需写明这一无-rego 行为。
- rego 输出契约扩展一个可选字段 `approvedBy []string`：`CheckStateRegoEvaluator`
  的结果结构从 knative `Condition` 扩为 `{Condition, ApprovedBy}`（内部结构），
  controller 将其写入 `MatchedCheck`：

```go
// MatchedCheck 新增（accessrequest_types.go）
type MatchedCheck struct {
	// ... 现有字段不变 ...

	// ApprovedBy records the distinct identities whose response satisfied
	// the check at evaluation time (group members recorded individually).
	// Populated only when the check rule's rego reports it.
	// +optional
	ApprovedBy []string `json:"approvedBy,omitempty"`
}
```

- 聚合逻辑 `AggregatePoliciesCheckState` 不变（约束在单资源判定层生效，先于聚合）。
- 快照语义不变：`params` 随 `policySpec` 在 AccessRequest 首次匹配时快照，
  在途请求不受 policy 后续修改影响（审计稳定；"撤销某人审批权"对已创建请求不生效，
  这是明确接受的语义）。

### 5.5 Webhook 变更（`accesspolicy_webhook.go`）

改用 `kmetav1alpha1.Params` 后，**复用其自带的校验**（review 意见 note 19304）——
`kmetav1alpha1.ParamSpecs/Params` 已有 name 非空、类型合法等校验逻辑（`ConnectorClass`
webhook 已在用），直接调用，不自写 `validateCheckRuleParams`：

- name 非空 / 值类型合法 → 复用 `kmetav1alpha1` 侧校验；
- 同一 check 内 name 唯一 → 若已有类型未覆盖则补一条轻量校验，否则复用；
- 现有 `ref`/`spec` 互斥校验、内联 spec 的 rego 编译校验 → 不变。

### 5.6 安全分析与 Guardrails（红线，非建议）

信任链：

| 数据 | 可信度 | 原因 |
|---|---|---|
| `ApprovalTask.spec.approvers` | ❌ 不可信 | 流水线作者/触发人可控 |
| `ApprovalTask.status.state` / `approversResponse` | ✅ 可信 | webhook 认证身份 + 仅 controller 可写 status |
| `AccessPolicy.params` | ✅ 可信 | policy 作者（管理员）配置，RBAC 隔离于流水线用户 |

攻击面推演：

- 触发人自批：其身份不在 `approvers` param → `ApproverMismatch` → 无授权。✅
- 触发人伪造带匹配 label 的 ApprovalTask 并自批：同上，身份不匹配。✅
- 触发人把审批人参数改成自己：`ApprovalTask.spec` 随意，但授权判定只看
  policy params ∩ status 记录 → 无授权。✅（G5：流水线参数退化为 UX 路由）
- 错误的人先批导致 ApprovalTask 进入 approved 终态：fail-closed（False），
  需重跑流水线。已知体验代价，文档写明。

多资源聚合的语义（code review 提出，已评估）：一个 check 规则的 selector 可能匹配到
多个 ApprovalTask（同一 `tekton.dev/pipelineRun` label 下有多个审批 Task）。每个匹配资源
产出一个 MatchedCheck，`aggregateMatchedChecksState` 以 True>False>Unknown 优先级聚合
（既有逻辑，本方案未改）。这意味着若同一 PipelineRun 下一个 ApprovalTask 被拒、另一个
通过，聚合结果为通过。评估结论：**对审批人约束不构成新的 fail-open** —— 能贡献 True 的
Task 必须由 policy **指定的审批人**批准（否则是 ApproverMismatch=False），而这恰是合法
授权条件本身；触发人无法凭自批的第二个 Task 提升结果。该 True>False 优先级是作用于**所有**
check 类型的既有全局行为。**裁决（review 意见 note 19340）：保持当前全局语义不变**——
聚合仍是"有一个通过即通过"，只是把每个 check 资源的"通过（True）"定义为"状态 approved
**且**满足审批人约束"。即：只要有一个 ApprovalTask 既 approved 又满足约束，就算通过；这已由
单资源判定层天然实现（每个资源的 True 都要过约束），无需改聚合。OQ4 据此**关闭**。

Guardrails（进入完成标准）：

1. 内置模板 rego 附带单测并接入 CI（`make check`/`gotest`）——测试**直接跑交付的 rego**
   （从 `config/accesspolicy/...` 加载），用例矩阵见 §7。安全逻辑住进 rego，测试义务随之搬家。
   （已去掉原 unknown-param 拒绝那条——见 §5.3"刻意不做的"。）
2. ConfigMap 内注释块维护 param 清单（名义真源），改 rego 必须同步；UI/文档/rego 三处对齐
   依赖该清单。集成用 rego 副本由 `TestApprovalsInPipelineCopyIsInSync` 机器强制同步。

### 5.7 UI 契约（connectors-ui-plugin）

**已建独立 Jira：[DEVOPS-44541](https://jira.alauda.cn/browse/DEVOPS-44541)**（Cause 关联到
DEVOPS-44347，review 意见 note 19296/19339）——单内写清后端数据结构变动供前端依赖：

- `CheckRule.params`（`kmetav1alpha1.Params`）：`approvers`（array，`group:` 前缀=组）+
  `numberOfApprovalsRequired`（string 数字）。
- `AccessRequest ... matchedChecks[].approvedBy`（[]string）：实际满足审批的身份，供展示。
- UI 要求：内置模板 `connectors-approvals-in-pipeline` 渲染上述两定制字段（组写回 `group:`
  前缀、数字写回字符串），其它模板回退裸 params 编辑器；审批结果展示 `approvedBy`。

UI 落地不阻塞本 MR（后端先行，YAML 可用）。

### 5.8 兼容性

- **行为兼容**：存量 AccessPolicy（无 `approvers`）→ 内置模板 rego 走 legacy 分支（纯状态
  检查）→ 行为等价，回归用例覆盖。
- **input 形状变更**：input 从"资源本身"改为 `{object, check}`（§5.2）。内置模板与 testdata
  副本一起改，不受影响；**唯一受影响的是用户自建、直接把 input 当资源读（`input.status...`）
  的内联 rego**——量少、是逃生门，实现时决定"统一 `{object, check}` + release note 标注迁移"
  还是"无 check 注入时保持 input 为资源本身"。**实现 MR 定，本文不锁死。**
- CRD 变更纯增量（新增可选字段 + 复用已有类型），无需版本升级/迁移。
- 分发：内置 ConfigMap **正式分发只有 operator 一种途径**（OQ2 已定），随版本升级无冲突。
- Feature flag：不新增 flag，随 `enable-connectors-approval` 整体启停。

## 6. 实施拆分

| 仓库 | 内容 | 依赖 |
|---|---|---|
| connectors | API 字段（复用 `kmetav1alpha1.Params`）+ deepcopy/CRD 生成、evaluator `{object, check}` 注入、MatchedCheck.ApprovedBy、webhook 复用校验、内置 ConfigMap rego 升级、rego 单测、单测、集成测试 | 无 |
| connectors-operator | 本设计文档；用户文档（approval 概念文档补"审批人约束"章节）；operator 分发（正式唯一途径，随版本升级） | connectors MR 合并后同步 |
| connectors-ui-plugin | [DEVOPS-44541](https://jira.alauda.cn/browse/DEVOPS-44541) 定制表单（不阻塞） | connectors 发布 |

分支命名：`feat/DEVOPS-44347-approver-constraint`（各仓库同名）。

## 7. 测试计划

### 7.1 单元测试（Ginkgo/Gomega，connectors 仓库）

- webhook：复用 `kmetav1alpha1` 校验 + name 唯一性；合法通过、存量对象（无 params）不受影响。
- evaluator：input 组装为 `{object, check}`，rego 经 `input.check.params` 读到 Tekton 风格值
  （arrayVal / stringVal）；无 approvers 时走 legacy 分支。
- controller：rego 返回 `approvedBy` 时 `MatchedCheck.ApprovedBy` 写入；
  条件聚合与 RBAC 授权/回收行为随 True/False/Unknown 正确（复用现有测试模式）。

### 7.2 内置 rego 决策矩阵测试（接入 CI）

> 实施说明（2026-07-16）：最终以 **Go 驱动**测试实现（`TestBuiltInApprovalsInPipelineRego`），
> 而非独立 `opa test`。测试从磁盘加载**交付的** ConfigMap（`loadShippedApprovalsInPipelineRego`），
> 经**生产 evaluator 路径**（`CheckStateRegoEvaluator`）跑下方矩阵——比 `opa test` 更强：
> 验证的是真实运行时求值链，且随 `make check → gotest` 自然进 CI，无需引入 OPA 二进制。
> 另有 `TestApprovalsInPipelineCopyIsInSync` 机器强制集成用副本与交付 rego 逐字节一致。

> 简化后**去掉** unknown-param / invalid-param 类断言（rego 不再做这些防御，见 §5.3）；
> 保留必要覆盖：

| # | 场景 | 期望 |
|---|---|---|
| 1 | 无 approvers + approved | True/Approved（legacy） |
| 2 | 无 approvers + rejected / pending | False / Unknown（legacy） |
| 3 | approvers=[alice] + alice approved | True/ApprovedByRequiredApprovers, approvedBy=[alice] |
| 4 | approvers=[alice] + 仅 bob approved | False/ApproverMismatch |
| 5 | approvers=[alice] + pending | Unknown/Pending |
| 6 | approvers=[group:ops] + ops 组成员 approved | True, approvedBy=[成员] |
| 7 | required=2("2") + 组内 2 人 approved | True |
| 8 | required=2("2") + 仅 1 身份 approved | False/ApproverMismatch |
| 9 | required 缺省 → 按 1 处理 | 一人满足即 True |
| 10 | 同一人重复 approve（User + 组成员双记录） | 身份去重计 1 |
| 11 | 拼错 param 名（如 `aprovers`） | 约束不生效 → 退回 legacy（**不报错**，见 §5.3） |

### 7.3 集成测试（cluster.md 开发集群，`testing/` BDD）

复用现有 approval 集成测试基建（ConfigMap 充当 check 目标 + 真实 ApprovalTask 两条路径，
以现有 feature 布局为准）：

- IT1 回归：存量无 params policy 全流程行为不变（现有 approval feature 全绿）。
- IT2 指定审批人 approve → AccessRequest True → RBAC 创建 → CSI 语义放行。
- IT3 非指定审批人 approve → AccessRequest False，reason=ApproverMismatch，无 RBAC。
- IT4 `required=2` + `group:` 前缀：一身份不足、两身份满足。
- IT5 params + 内联 spec 组合（params 经 `input.check.params` 注入自定义 rego 可读）。

### 7.4 E2E（调整既有 case，review 意见 note 19309）

**把已有的一个审批 E2E case 改为"指定审批人"来审批**（指定审批人比不指定更常用，应作为主路径
覆盖）——而非仅作为 bundle/e2e 候选记录。具体：现有晋级/审批 E2E 里选一个 approve 场景，
给其 AccessPolicy 的 check 加 `approvers` param、并由指定审批人提交审批，验证端到端授权成功；
保留一个不指定审批人的既有 case 作为对照。落点在 `connectors-operator` / `devops-e2e`
（bundle/e2e 阶段）。

## 8. 验收标准（独立 agent 逐条核验）

以下每条都必须给出可观察证据（测试输出 / 集群资源状态 / 文件内容）：

- AC1: `AccessPolicy` CRD 接受 `checks[].params`（`kmetav1alpha1.Params`），值支持
  string/array（数字以字符串承载）；CRD yaml 已重新生成并包含该字段。
- AC2: 配置 `approvers=[<userA>]` 的 policy 下，<userA> approve 后对应
  AccessRequest 顶层 condition 为 True 且目标 Role/RoleBinding 存在。
- AC3: 同一 policy 下，非指定用户 approve 后 AccessRequest 的 matched check
  condition 为 False 且 reason=`ApproverMismatch`，Role/RoleBinding 不存在。
- AC4: `approvers` param 完全缺席时，行为与升级前逐字节一致（存量 approval
  集成测试全绿，未修改断言）。
- AC5: 拼错 param 名（未知 param）时**不报错**、约束不生效退回 legacy 行为（本轮 review
  明确不做 unknown-param 拒绝，见 §5.3）。
- AC6: `group:` 前缀审批人：组成员 approve 被计入，`numberOfApprovalsRequired="2"`
  时两名不同身份 approve 才 True。
- AC7: `MatchedCheck.approvedBy` 在约束满足时记录实际审批身份。
- AC8: webhook 复用 `kmetav1alpha1` 校验 + name 唯一性；合法 params 通过、存量无 params 对象不受影响。
- AC9: §7.2 决策矩阵在 CI 目标（`make check → gotest`）中对**交付的** rego 执行且通过
  （以 Go 驱动 evaluator 实现，见 §7.2 实施说明；等价满足"矩阵在 CI 跑交付 rego"意图）。
- AC10: 内置 ConfigMap 含 param 清单注释块；用户文档（approval 概念文档）新增
  审批人约束章节，含 group 前缀约定与 ApproverMismatch 排障说明。

## 9. 完成标准（DoD）

1. connectors 仓库 `make check`（fmt+vet+lint+单测）通过；OPA 测试接入并通过。
2. §7.3 集成测试在 cluster.md 环境全绿（本次范围 + 存量 approval 回归）。
3. `connectors-code-review`（project-tier）+ `code-review`（framework-tier）无 BLOCKING 遗留。
4. §8 验收标准由独立 agent 核验通过（refuter 模式）。
5. MR 已创建、description 含测试策略评估（触及 RBAC/webhook/CSI 边界 → e2e 候选
  已记录为 bundle/e2e 决策输入）；PaC 流水线绿。
6. 技能退出条件满足（connectors-implement §9：单测+lint+集成测试+Phase B QA design
  对照+自审全过+MR 必填评估写入）。

## 10. 架构评审记录（connectors-arch-review, 2026-07-16）

**架构事实**：主体 = Connectors 插件 / connectors 组件（AccessPolicy CRD、AccessRequest
controller、内置 ConfigMap）；动作 = 新增可选 API 字段 + 配置层 rego 升级；跨插件数据流 =
AccessRequest controller 经 dynamic client 读 Tekton 插件的 ApprovalTask status（**既有链路**，
本方案仅消费同一资源的更多字段）；驱动方 = Connectors 插件自身；触发场景 = reconcile。

**命中原则判定**：

| 原则 | 状态 | 关键判定 |
|---|---|---|
| no-bidirectional-dependency | 通过（附既有风险注记） | 本方案未新增跨插件链路、未反转方向；判定问题 5（不装 Tekton 插件时能力是否成立）：核心能力成立，approval check 走 duck type，ApprovalTask CRD 缺席时 selector 匹配不到资源 → pending，与现状一致 |

既有风险注记（非本方案引入）：Connectors↔Tekton 之间已存在两条方向相反的链路
（RI: Tekton→Connectors，见 DEVOPS-43943；approval check: Connectors→Tekton duck 读）。
本方案将 ApprovalTask schema 知识（approversResponse 形状、group: 语义）保持在**可替换的
配置层**而非 API/代码层，是对该格局的缓解而非加剧。

**待补充（原则集合盲点，candidate for connectors-learn）**：本方案触及"配置归属"
（params 值归 policy、判定逻辑归平台模板、schema 认知归 UI）与"安全信任链"
（spec 不可信 / status 可信）两个维度，当前原则集未覆盖。

## 11. 开放问题

- OQ1（已定论，2026-07-16 实施期调查）：
  - `evaluateLoadedCheckStateWithRego`（package "approval"）确认为死代码（仅测试引用）——
    follow-up 删除；
  - webhook rego 校验 query `data.approval.status` 在活跃路径上但仅起编译门作用
    （不校验 `package check`/`result` 契约）——follow-up 收紧为 `result = data.check.result`；
    注意 `testing/testdata/accessrequest-controller/accesspolicy-check-failed-jsonpath.yaml`
    fixture 依赖 package 不匹配产生 eval 失败，收紧时需一并评审；
  - `CheckStateExpression.Rego` 的过时 doc comment（说 package "approval"）在本 MR 修正
    （用户经 kubectl explain 可见）。
- OQ2（**已定论**，review 意见 note 19338）：内置 ConfigMap 的**正式分发只有 operator 一种
  途径**，故随版本升级无冲突、无需额外 sync 路径考量。
- OQ3（**已定论**，review 意见 note 19339）：UI follow-up 已建
  [DEVOPS-44541](https://jira.alauda.cn/browse/DEVOPS-44541)（见 §5.7）。
- OQ4（**已关闭**，review 意见 note 19340）：保持当前全局聚合语义不变（"有一个通过即通过"），
  只是把"通过"定义为"approved 且满足审批人约束"——已由单资源判定层天然实现，不改聚合。见 §5.6。
