# PoC-3 报告：审批门控（覆盖矩阵问题域 5）

> 立项依据：覆盖矩阵 #5 — "生产推送走审批，开发放行"。Connectors 用
> `AccessPolicy` + `AccessRequest` + Tekton `ApprovalTask` 在同一
> PipelineRun 内联动；Vault Enterprise 用 Control Groups；Vault OSS
> 无原生审批门控。本 PoC 验证 OSS 路径上构造"最贴近等价模型"的可行性。

## 1. Vault Enterprise Control Groups 能力 spec（未真跑）

- **Edition**：仅 Vault Enterprise / HCP Vault Dedicated 提供；OSS 没有。
- **机制**：policy HCL 里 `path` 块带 `control_group = { factor "..." { identity { group_names approvals } } }`，触发后返回 wrapping_token，approvers 调 `/sys/control-group/authorize` 接受，requester 调 `/sys/control-group/request` 查询，approved 后 `vault unwrap` 取真值。
- **UX 关键事实**：**无内建 approver UI**。文档全程 CLI / API，集成方需自建通知与点击界面；approver 必须有自己的 Vault token。
- 完整 spec、policy 样例与 Connectors 各机制对照见 `control-group-spec.md`。

## 2. OSS 近似 PoC（已在 `devops-valult-invest` ns 跑通）

最小近似方案：

1. **审批信号载体**：`ConfigMap/vault-approval-decisions`，每个 request-id 一个 entry。
2. **审批 UI**：复用 `tekton-pipelines` ns 现有的 `manual-approval-gate` + `ApprovalTask` CR。
3. **Bridge 任务**：watch CustomRun.status，落盘到 ConfigMap。
4. **Gate + Fetch 任务**：先轮询 ConfigMap → approved 才执行 Kubernetes Auth login 取 Vault token → 读 `secret/git/test`。

| 场景 | PipelineRun | 结果 | 凭据是否拿到 |
|---|---|---|---|
| dev profile（不挂审批） | `vault-dev-2fb6g` | Succeeded (105s) | ✅ 拿到 |
| prod profile + approve | `vault-prod-approve-f26cb` | Succeeded (7m33s) | ✅ approve 后拿到 |
| prod profile + reject | `vault-prod-reject-t7plv` | Failed (27s) | ❌ 未拿到（fetch 未运行） |

## 3. 关键 UX 差异（vs Connectors 原生）

| 维度 | Connectors 原生 | OSS 近似 | Vault Enterprise CG |
|---|---|---|---|
| 审批人在哪点击 | PipelineRun UI（同屏） | PipelineRun UI（同屏） | Vault Web UI / CLI 自建 |
| 审批对象 | `AccessRequest` CR 一等公民 | ConfigMap revision + CustomRun 手工 join | Vault audit log |
| 网关粒度 | per-Connector + 三级 scope，挂 ACP IAM | per-PipelineRun + request-id 字符串约定 | per-path glob |
| 触发位置 | "用代理时"，秒级 RBAC 撤回 | "取凭据时"，取后无约束 | "取凭据时"，wrapping_token TTL |
| Approver 身份 | 复用 ACP IAM 群组 | username 内联 pipeline YAML | user/group 内联 HCL policy |

## 4. 与覆盖矩阵第 5 项的回扣

矩阵原结论 "**双方覆盖（Vault 必须 Enterprise，且模型不同）**"，PoC-3 精化为：

1. **Vault OSS 不可达**——只能靠外部组件构造近似。
2. **OSS 近似工程量大且体验差**——最简版本要达到生产可用还需 CRD + controller + IAM resolver + 通知 + per-team RBAC，等于在 Vault 上重写 Connectors `AccessPolicy`/`AccessRequest` 那一层。
3. **Vault Enterprise 也只解一半**——审批绑在"取凭据"非"用凭据"，无 UI，approver 要 Vault 身份；UI/通知/IAM 集成层每客户都要花工程，外加 per-cluster license。

**深层差异**：Connectors 审批绑在"使用 proxy"，凭据真值从不离开 connectors-system；Vault 路线只能审"取下来这一刻"，**凭据进 client 后审批失效**——与 secretless 哲学相悖（呼应总 REPORT §7.1）。

## 5. 最终评级

> **OSS 等价路径技术上可行但生产化体验差；要做到 Connectors 体验仍需 Vault Enterprise，且即便上了 Enterprise，UI/通知/IAM 集成层仍要新建一层"基本上就是再写一遍 AccessPolicy + AccessRequest"，没有 ROI。**

## 文件索引

- `control-group-spec.md` — Enterprise CG 能力 spec + 假设 HCL 样例
- `oss-approximation.yaml` — PoC K8s 资源清单
- `run-log.md` — 三组验证步骤与关键日志
- `feasibility.md` — 工程量、UX 差距、客户场景评估
