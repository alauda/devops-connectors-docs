# Design Review — Nexus 自动创建 Project + Connector + Secret (DEVOPS-43952)

<!--
Written by /feature:design-review on 2026-05-27. Outcome: approved.
risk=sensitive → required: 2 approvers + 1 security-labeled reviewer.
-->

## Attendees

- daniel — approver (backend lead-equivalent)
- kychen — approver
- jtcheng — driver + security-labeled reviewer (signs threat-model.md)

## Checklist

- [x] Goal is unambiguous — `product-design.md ## 用户可见接口` enumerates Task
  surface; `## 对 Jira AC 的覆盖与改写` ties every AC to a concrete behavior.
- [x] Task breakdown covers the goal (no missing slices) — `tech-design.md
  ## 调用路径` step 1-5 fully covers project create → user/role → secret →
  apply; failure modes enumerated.
- [x] Direction is right (no unnecessary rebuilds) — V0.1 reuses existing
  Nexus connector + ConnectorClass; **does NOT** require changes to
  `nexus-connectorclass` to provide `nexusconfig` (current impl only needs
  a Nexus secret as workspace input, confirmed by driver round-table).
- [x] Test design is concrete enough for QA to execute as-is — 33 TC with
  explicit CEL assertions, `场景:` narration per TC, POC evidence section
  (`product-design.md ## 测试设计 → POC 证据`) references live verification
  in `_research-notes-nexus-api.md §4`.
- [ ] For UI slices: drawio prototype is implementable without questions —
  **N/A** (v0.1 does not deliver UI; `product-design.md ### 调用方式`
  point 5).
- [x] For risk=sensitive: threat-model residual risks acceptable — 4 residual
  items dispositioned below; all accepted as v0.1 residual.
- [x] Dependency graph has no cycles — `dependencies.md` shows linear
  extensions → operator install-manifests sync; no operator → extensions
  loop.

## Security considerations

- **Credential handling**: Nexus user creds generated and written to
  `connectors-management` namespace; mitigations T4 + T6 (process
  substitution, no `<<<` here-string, `{ set +x; ...; } 2>/dev/null` bracket
  on secret-touching steps). Validated in `tech-design.md ## 调用路径 step 4`.
- **CSEL / pathPrefix injection**: regex whitelist on `pathPrefix`, validate
  helper referenced in `tech-design.md ## 调用路径 step 2`; T7 + T15 mitigated.
- **Wildcard / stale-priv collision**: T13 + T14 mitigated via
  `identity-suffix` hash over 6 inputs (format / scope / retainAccess /
  pathPrefix / group-policy / nexusUser-override).
- **Anonymous read leak**: T9 mitigated via opt-in `requireAnonymousDisabled`
  Task input + 24 sub-case test coverage; residual accepted with 3-argument
  rationale in `threat-model.md ## 残余风险 T9`.

## Decisions

1. **Approve v0.1 scope** — Task-only delivery (no UI); driver-confirmed AC
   reframe in `product-design.md ## 对 Jira AC 的覆盖与改写` is the binding
   contract for QA.
2. **Accept 4 residual items as v0.1 residual** (see disposition table
   below) — none block approval; all have either a v0.1 mitigation or an
   architectural-limit rationale.
3. **No `nexusconfig` field change on `nexus-connectorclass`** — driver
   verified during implementation that only a Nexus secret workspace input
   is needed; closes deferred item architect-16 without further grep work.
4. **Implementation already in flight** — extensions PR #326 (v0.1 Task)
   **merged**; PR #332 (polish UX) **open with CI in progress**. Recorded
   here as audit context; `/feature:plan` will register them as existing
   units rather than re-planning.

### Deferred items disposition (from `_review-disposition-round1.md`)

| # | Item | Disposition | Rationale |
|---|------|-------------|-----------|
| 1 | architect-16: `nexusconfig` field grep verification | **CLOSED — not needed** | Driver verified current impl only needs a Nexus secret as workspace; no `nexusconfig` schema change on `nexus-connectorclass`. |
| 2 | security-T10: supply-chain injection mitigation | **Accept residual** | Out of scope for this feature; depends on downstream SBOM / image-signing program. |
| 3 | security-T16: cluster-admin `pods/exec` full defense | **Accept residual** | K8s inherent trust model; cannot be eliminated within a single Task scope. |
| 4 | Shared live Nexus concurrent-PR collision | **Accept residual, non-blocking** | Management-side concurrency, controllable. v0.1 mitigations: name-prefix isolation + admin lock. Escalation path documented (namespace-per-PR Nexus pool) if real incident occurs. |

## Outcome

**approved**

### Pivot / rework notes (if applicable)

N/A.

## Signatures

- daniel: approved, 2026-05-27
- kychen: approved, 2026-05-27
- Security reviewer: jtcheng (driver + security-labeled, also signs
  `threat-model.md`), 2026-05-27 — accepts T9 / T13 / T14 / T15 mitigations
  and T10 / T16 / shared-Nexus residuals.
- Frontend lead: N/A (no UI slice in v0.1)
