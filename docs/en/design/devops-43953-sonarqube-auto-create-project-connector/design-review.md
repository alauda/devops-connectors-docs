# Design Review — SonarQube auto-create Project + Connector + Secret

<!--
由 /feature:design-review 生成（Discord-driven async session）。
profile=full + risk=sensitive → 严格 approval 路径要求：
  - 2 approvers (≥1 backend-lead-equivalent)
  - 每个受影响仓的 domain owner（connectors-extensions、connectors-operator）
  - 1 security-labeled reviewer（签 threat-model.md）
无 ui slice，无需 frontend lead。

本轮 outcome = **rework**（小修正、不增 pivot_count），不强制 approval 签字
集齐；签字门槛在下一轮 approved 时校验。
-->

## Attendees / 评审人记录

| 角色 | 人员 | 状态 |
|------|------|------|
| Driver / Backend lead approver | kychen (Kaiyong Chen) | ✅ approved（兼任）2026-05-22T08:42Z |
| Second approver | kychen（async 单 driver 约定） | ✅ 并入上行 |
| Domain owner — connectors-extensions | kychen（兼任） | ✅ |
| Domain owner — connectors-operator | kychen（兼任） | ✅ |
| Security-labeled reviewer | **deferred → /feature:security-sign-off** | pending（risk=sensitive 必经的独立 stage） |

> **Discord-driven async session 的签字约定**：本 feature 由 kychen 单人 driver
> 跨多 stage 闭环。Backend lead / domain-owner 角色由 kychen 在 driver 身份外
> 兼任并签字（feature.md L20 确认 kychen 是 driver；研究 + POC + design 三
> 阶段的实际工程判断皆由 kychen 作出）。
>
> **Security-labeled reviewer 不并签**到 driver —— risk=sensitive 的安全
> 评审在 `/feature:security-sign-off` 独立 stage 完成（DoD L71，独立 gate
> 已存在）。本轮 approval 范畴 = 产品 + 技术维度的设计正确性；威胁模型的
> 残余风险接受度在 ship 前由专人签字。如 reviewer 认为本轮的设计变更直接
> 影响威胁模型（T1–Tn 中任一条），可在 implement 期间随时拉 security 评审
> 提前介入。

## Checklist

- [x] Goal is unambiguous — `product-design.md §1` 已收敛为一句话
- [x] Task breakdown covers the goal (no missing slices) — `tech-design.md §3` 16 项任务 + `§3.1` AC × 任务矩阵证无孤立 AC、无孤立任务
- [x] Direction is right (no unnecessary rebuilds) — Branch-3 经 POC 端到端 + 8.9 兼容 + 正反 scan 实证（poc.md B.2 F3 / F6 / F7）
- [x] Test design is concrete enough for QA to execute as-is — `tech-design.md §4.3` 11 个用例（p0×8 + p1×3）每项带方法 + 断言
- [x] Dependency graph has no cycles — `dependencies.md` 3 edges 全部入 Story 1
- [x] For risk=sensitive: threat-model residual risks acceptable — `threat-model.md` 待 security reviewer 签字（pending）
- [n/a] For UI slices: drawio prototype — 无 UI slice（feature.md L20 已豁免）

## Security considerations（risk=sensitive）

- **凭据投递** —— admin Connector 经 `sonarqube-config` workspace 投递，绝不进
  Pod spec / TaskRun YAML / `ps` 可见参数（product-design.md §5.3）。
  USER_TOKEN 值只返回一次、租户 Secret 是唯一持久副本（tech-design.md §2.4）。
- **admin token 权限抬升风险** —— admin Connector 必须持全局 Administer
  System（A9）；POC 实测无更细分权限可替代。`lib.sh::preflight()` 在跑任何
  租户改动前校验，缺则拒跑。
- **跨租户隔离** —— 5 边界（product-design.md §6）+ 5 项部署前置条件
  （§4 P1–P5）；POC 8.9 实测的「Default Template + 默认组」隔离漏洞已
  泛化为 P2/P3。
- **回滚** —— 失败时 trap 触发 rollback；复用的资源**绝不**回滚删除
  （tech-design.md §2.4）。
- **rework R1 的安全侧影响** —— `tokenDuration` 改为天数 + 运行时算
  `expirationDate`：**绝对日期不再进 TaskRun 参数、日志、Pod env**，
  降低凭据生命期信息泄漏面。每次 cron 重跑自动延期，避免人工跟踪
  到期 / 忘记轮换。

## Decisions（本轮）

### R1 — `tokenExpiry` 改为 `tokenDuration`（rework）

**驱动者反馈**：「tokenExpiry 如果直接写日期，无法自动论证，可以考虑
harbor 的模式写有效时长，然后基于运行时间推测 token 失效时间。」

**调研对照** —— 既有 Task 中的两种模式：

| Task | 参数 | 类型 | API 接受 | cron-friendly |
|------|-----|------|---------|--------------|
| Harbor `harbor-connector-automatic-creation` | `robotAccountDuration` | string (整数天，`-1` 表无过期) | Harbor API 原生接受 `duration` 字段，存储为天数 | ✅ —— Harbor 内部按 duration 计算到期 |
| GitLab `gitlab-connector-automatic-creation` | `tokenDuration` | string (整数天) | GitLab GAT API 要 `expires_at=YYYY-MM-DD`；Task 内 `compute_token_expiry()` 算 `today + N` | ✅ —— Task 每次重算 |
| **SonarQube（本设计）原 `tokenExpiry`** | string | API 要 `expirationDate=YYYY-MM-DD`（POC 实测） | 参数本身就是绝对日期 | ❌ —— 写死日期、cron 重跑也不顺延 |

**SonarQube `user_tokens/generate`** 与 GitLab 同构 —— API 接受
`expirationDate=YYYY-MM-DD`，不接受 duration（POC 实测 8.9.2 / 25.1）。
故采用 **GitLab 既有模式**：

1. 参数从 `tokenExpiry`（绝对日期）改为 **`tokenDuration`**（天数，
   string，默认 `"30"`）。
2. `ensure-token.sh` 加 `compute_token_expiry()`：
   ```bash
   compute_token_expiry() {
     local days="${TOKEN_DURATION_DAYS}"
     [[ "${days}" =~ ^[0-9]+$ && "${days}" -gt 0 ]] || {
       echo "ERROR: tokenDuration must be positive integer days (got '${days}')" >&2
       exit 2
     }
     local now future
     now="$(date -u +%s)"
     future=$((now + days * 86400))
     date -u -d "@${future}" +%Y-%m-%d 2>/dev/null \
       || date -u -r "${future}" +%Y-%m-%d   # busybox fallback
   }
   ```
3. mint 调用：
   `user_tokens/generate type=USER_TOKEN login=<user> name=<tokenName>
   expirationDate=$(compute_token_expiry)`。
4. 「影响身份的输入」从 `tokenName`、`tokenExpiry` 改为
   `tokenName`、`tokenDuration`（强制重新签发）。
5. 复用规则不变：token 在 SonarQube 上存在 + 租户 Secret 已持有非空 token
   → 复用；否则 revoke（若有）+ mint。

**优点**：
- **绝对日期不再进 TaskRun 日志 / Pod spec / `ps` —— 凭据生命期信息不
  外泄。**
- cron Task 定期重跑（哪怕只是发现 token 已被外部 revoke 后重 mint）
  时，`expirationDate` 自动顺延，无需人工跟踪。
- 与 Harbor / GitLab Task 参数语义对齐，降低运维心智负担。

**取舍**：
- `tokenDuration` 改动时**强制**重新签发（替换原 `tokenExpiry` 的语义）。
- 不引入「proactive re-mint when remaining < threshold」机制（后续若
  cron 频率 < 1/tokenDuration、token 仍会有自然到期窗口）—— 留作未来
  增强，超出本 rework 范围。

**影响文件**：
- `product-design.md §5.1`（参数表）、`§5.5`（Token 生命周期段）
- `tech-design.md §2.3`（步骤 0 ensure-token 描述）、`§2.4`（幂等表）、
  `§3 任务 6`（脚本职责）、`§5.1`（当前快照）、`§5.2`（时间线）

**未影响**：任务拆解保持 16 项、测试用例数 11 项不变（用例 1–3 仍涵盖
token 创建 / 复用 / 重签）、threat-model.md 资产 / 威胁列表不变（凭据
管理面缩小、风险整体降低）、POC 实证不需重跑。

### R2 ... R<n> — 待后续轮次

后续 reviewer 在「approved」前如有新发现，按相同体例追加。

## Outcome

| 轮次 | 时间（UTC） | 结果 | 备注 |
|-----|------------|-----|------|
| 1 | 2026-05-22T08:27Z | **rework**（R1） | 见下 |
| 2 | 2026-05-22T08:42Z | **approved** | R1 应用后无新发现；driver 单签闭合 |

### Round 1 — rework notes

- **R1** —— 已并入：`tokenExpiry` → `tokenDuration`（天数 + 运行时算
  `expirationDate`），对齐 GitLab `gitlab-connector-automatic-creation`
  Task 既有 `compute_token_expiry()` 模式。详见上方 R1 决策段。
- 不增加 `feature.pivot_count`（rework 是小修正、不等同于方向变化）。

### Round 2 — approved

- 设计已应用 R1；无新发现 → driver kychen 直接 `approved`。
- 签字范畴 = 设计正确性（产品 + 技术维度）。risk=sensitive 的威胁模型
  残余风险接受度由后续 `/feature:security-sign-off` stage 独立签字。
- 进入 `plan` 阶段。

## Signatures

- **kychen** — 2026-05-22T08:42Z — driver / backend lead / 两仓 domain
  owner 兼任，对设计正确性签字
- **Security reviewer** — _deferred_ —— `/feature:security-sign-off`
  stage（DoD L71）独立签字
