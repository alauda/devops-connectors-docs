# Retrospective — Gitlab automatic project and sub-account support using API and CLI

<!--
Written by /feature:retro on 2026-05-14, before /feature:ship.
profile=standard, risk=sensitive. First sensitive-overlay feature
through the /feature:* workflow at scale.

Synthesized from the lived session arc 2026-05-06 → 2026-05-14, the
maturity entries already on disk, the umbrella's design + qa + accept
+ docs + regress + security-sign-off artifacts, and the project
memory entries [[project_devops_43146_gitlab_task]] (full session
narrative) plus the cross-feature reference + feedback memories
that fired during this feature.
-->

## Worked

- **Live QA on a real CustomAcp before declaring CI-green** caught the
  F1 jq-on-error bug (`ensure-gat.sh` calling `jq` on a GitLab error
  body) and drove the F2 / AC-7 amendment (idempotent-rerun documented
  instead of pretending we had transactional rollback). Classic
  [[feedback_live_qa_catches_what_bdd_misses]] payoff: the BDD suite
  was fully green on stub fixtures the same day the live run failed.
  Pattern to repeat for every sensitive-risk feature.

- **/feature:plan's 4-story decomposition** (Task + scripts / BDD /
  docs / operator wiring) mapped 1-to-1 to the 4 PRs that actually
  shipped — no re-planning mid-implementation, no story reshuffles.
  The decomposition surfaced `mechanical-followup` as a useful class
  for the operator-wiring story (PR #1000 was almost entirely wiring
  + auto-sync, no design choices).

- **Mermaid migration in `glab_cli_config.mdx`** via the
  `devops-connectors-write-user-docs` skill landed cleanly in a
  single +35/-53 PR (#1087) with no review iteration. Skill
  discovery (Daniel asking "do we have a doom/docs skill?") prevented
  re-inventing the doc-guideline rules from scratch.

- **R3-relaxed regression decision** saved ~6h by reasoning about the
  v146-vs-parent-SHA delta instead of triggering against the unhealthy
  main pipeline. The choice was made explicit in `regression.md` (the
  three-option tradeoff is in the file body, not just in commit
  history) so the reasoning is auditable. Better than "we just
  trusted QA."

- **threat-model.md was thorough enough at design-time** (10 threats,
  10 mitigations table, residual-risk acceptance) that pre-ship
  /feature:security-sign-off became a ~20-minute mechanical mapping
  exercise (RBAC delta = zero across cmd/kodata vs v1.10.0; one
  third-party egress reusing existing allowlist) instead of a fresh
  threat-discovery pass under deadline pressure.

- **Discord-as-driver-channel worked at multi-hour async cadence.**
  Daniel could issue commands while afk and the chunked replies
  (≤800 chars per [[feedback_discord_long_message_chunking]]) kept
  the conversation legible. Schedule-Wakeup + cron mechanisms covered
  the gaps where round-trips needed to wait (e.g. CI runs); `/loop`
  + `Sonnet for round trips` ([[feedback_sonnet_for_pipeline_round_trips]])
  handled the polling without burning Opus context.

## Didn't work

- **`/feature:integrate` has no stage-aware re-run mode.** Its skill
  unconditionally advances `stage.current` to `qa` (step 6), so when
  the bundle version churned post-qa (v141 → v146 after F1+F2 fixes
  triggered a fresh bundle pipeline run), the only options were:
  (a) re-run /feature:integrate and backtrack past qa+accept+docs, or
  (b) /feature:state-repair to patch `bundle.{tag,image,digest}` in
  place. We did (b) (Repair#3 at 2026-05-14T09:45Z). The unhandled
  scenario is "bundle version updated after stage > integrate" — not
  exotic; happens any time post-qa fixes generate a new bundle.

- **/feature:state-repair was used 3 times on this single feature.**
  Per the skill itself: "If a driver finds themselves invoking it
  more than once per feature, that is a bug in an earlier command."
  - Repair#1 (2026-05-11T12:15Z) — missing Story 3 + Story 4 PR URLs
    because no `/feature:*` command had written state since 2026-05-07
    yet PRs were open + CI-green; also formalized
    `implementation_repo` + `consolidated_from` schema fields and
    added `ready` to the `pr_state` enum.
  - Repair#2 (2026-05-12T13:30Z) — `pr_state: ready → merged` after
    manual admin-squash merges; no `/feature:*` command auto-records
    merge events.
  - Repair#3 (2026-05-14T09:45Z) — bundle drift v141 → v146 (above).
  At least 2 of these 3 are skill gaps (no auto-merge-event recorder;
  no stage-aware integrate re-run), not driver mistakes.

- **PaC GitHub App webhook drift fired twice on this feature**
  ([[reference_pac_webhook_drift]]). Each time ~10-15min lost
  diagnosing why new commits weren't firing pipelines before the
  GitHub-App-Advanced-tab redelivery workaround was applied. The
  workaround is in personal memory but not surfaced in any /feature:*
  skill output.

- **`connector-operator-test` pipeline on main was in genuinely poor
  shape** at the time of /feature:regress — 17 Failed (5 timeouts) /
  2 Succeeded / 1 Running over the past 17h. ~10% pass rate. This is
  not a defect introduced by this feature, but it forced R3-relaxed
  (vs a clean fresh CI run) and is a serious workflow tax that the
  next sensitive-risk feature through this workflow will hit again.
  **Action:** separate Jira to investigate; not in scope for this
  feature's remediation.

- **`docs/en/design/templates/security-reviewers.md` is the
  unfilled-stub template** (only the `{{id}}` placeholder row). Made
  it impossible at /feature:security-sign-off to nominate a separate
  security-team reviewer; the documented self-acting fallback in
  `threat-model.md` was used. The team-policy intent of
  /feature:security-sign-off (independent-reviewer separation) is
  undermined by leaving this file unconfigured. We are the first
  sensitive feature through the workflow — this absence wasn't
  surfaced earlier because no prior feature reached this gate.

- **`make render-tasks` indirection** ([[feedback_render_tasks_indirection]])
  bit twice during F1 fix. Editing `scripts/ensure-gat.sh` was a
  no-op until `make render-tasks` regenerated the inline-script
  `task.yaml`. The first time it was 2 minutes of confusion ("why
  is the step still failing the same way?"); the second time,
  ~5 minutes because the muscle memory of "edit the script, push"
  hadn't internalized the renderer step yet.

- **Bundle pipeline produced v141 first, then v146 after F1+F2.**
  /feature:integrate had run on v141; the F1+F2 fixes triggered a
  fresh build that produced v146 a day later. State.yaml carried
  the wrong bundle reference for ~2 days until Repair#3. Symptom of
  the same gap as the first "didn't work" entry — the skill chain
  doesn't model "bundle version churn during qa→regress."

## Change

- **(tooling)** `/feature:integrate` should accept a `--re-record-bundle`
  flag (or auto-detect that the current stage is past `integrate`) and
  update `bundle.{tag,image,digest}` without forcibly advancing
  `stage.current` to `qa`. Drop the implicit "this command always
  starts from `integrate`" assumption. Eliminates the most common
  state-repair trigger on this feature.

- **(tooling)** A `/feature:record-merge <pr-url>` (or PR-merge webhook
  hook at /feature:status display time) should mark
  `story_groups[].changes[].pr_state` as `merged` automatically when a
  referenced PR is merged. Eliminates the second state-repair trigger
  category.

- **(template)** `docs/en/design/templates/security-reviewers.md`
  should ship populated for each team adopting the workflow (or
  /feature:init should warn loudly when a feature could become
  risk=sensitive and the file is still the unfilled stub). The
  silent-degrade-to-self-acting path is too easy to fall into; the
  reviewer-separation intent is lost.

- **(tooling)** Document the PaC GitHub App webhook-drift workaround
  inline in `/feature:implement` + `/feature:integrate` skill output:
  "If pushes aren't firing PipelineRuns within ~3 min, redeliver via
  GitHub App → Settings → Advanced → Recent Deliveries → Redeliver."
  Currently only in personal memory; the next driver shouldn't have
  to rediscover it.

- **(process)** Document **R3-relaxed** (cite-latest-green-on-parent +
  delta-analysis) as a first-class option in `/feature:regress`'s
  skill body, alongside R1/R2/R3-strict. Currently the skill lists
  three execution paths (PipelineRun lift / make integration /
  driver-triggered Allure URL); the "cite parent SHA when no green
  exists at the actual SHA" path required skill-level reasoning to
  construct on the fly. Make it explicit so the next driver doesn't
  default to "wait 6h for the unhealthy pipeline" or worse, declare
  CI-green dishonestly.

- **(tooling)** `make render-tasks` should fail noisily (Makefile
  target with mtime check on `scripts/*.sh` vs the rendered
  `task.yaml`) when the rendered Task is older than its source
  scripts. Eliminates the silent-no-op symptom that bit F1 twice.

- **(template)** Extend `docs/en/design/templates/retrospective.md`
  with a `## PR ledger` section (see this feature's example below) so
  PR links land durably alongside the lessons-learned, alongside the
  archived umbrella. Today the canonical PR list is the Jira ticket
  (auto-linked via `DEVOPS-<id>` in PR titles), but the retro is the
  post-ship-archived snapshot — PR links there age better than "go
  check Jira and grep" two years from now.

## PR ledger

<!--
Not part of the current template (added per Change entry above).
Listed in the lifecycle order they were opened. State + brief role.
Auto-link in Jira covers the same ground but is less durable than
this in-archive surface.
-->

**`AlaudaDevops/connectors-operator` — 12 PRs**

| PR | State | Role |
|----|-------|------|
| [#888](https://github.com/AlaudaDevops/connectors-operator/pull/888) | closed | docs(teps): add feature-workflow TEP — superseded by #1000's 27-commit rebase squash |
| [#997](https://github.com/AlaudaDevops/connectors-operator/pull/997) | closed | docs(design): scaffold DEVOPS-43146 umbrella — superseded by #1000's squash |
| [#1000](https://github.com/AlaudaDevops/connectors-operator/pull/1000) | merged | **Story 4** — `feature(operator): wire connectors-gitlab-tektoncd into install-manifest pipeline` (also carries the squashed TEP + design umbrella) |
| [#1002](https://github.com/AlaudaDevops/connectors-operator/pull/1002) | merged | **Story 3** — `docs(connectors-gitlab): user-facing docs for gitlab-connector-automatic-creation Task` (concept + how-to + reference + ops runbook) |
| [#1058](https://github.com/AlaudaDevops/connectors-operator/pull/1058) | merged | `chore(feature-workflow): mark Stories 1-4 as merged after admin-squash` (state-repair Repair#2 — manual `pr_state: ready → merged` flip after admin-squash merges) |
| [#1066](https://github.com/AlaudaDevops/connectors-operator/pull/1066) | merged | `docs(feature-design): record /feature:qa outcome + F1/F2 fixes` |
| [#1085](https://github.com/AlaudaDevops/connectors-operator/pull/1085) | merged | `docs(feature-design): record v146 post-fix QA verification` |
| [#1086](https://github.com/AlaudaDevops/connectors-operator/pull/1086) | merged | `docs(feature-design): /feature:accept + /feature:docs outcomes` (umbrella accept+docs artifacts) |
| [#1087](https://github.com/AlaudaDevops/connectors-operator/pull/1087) | merged | `docs(connectors-gitlab): convert ASCII art to mermaid in glab_cli_config` (single-file user-doc cleanup PR) |
| [#1094](https://github.com/AlaudaDevops/connectors-operator/pull/1094) | merged | `docs(feature-design): /feature:regress + /feature:security-sign-off + /feature:retro outcomes` (also added this PR ledger section as a Change-tagged template proposal) |
| [#1096](https://github.com/AlaudaDevops/connectors-operator/pull/1096) | open | `chore(feature-workflow): /feature:ship DEVOPS-43146 — archive umbrella + maturity-report` — **this PR** (16 file moves to `archive/`, `maturity-report.md`, `state.yaml.feature.shipped_at`, post-ship retro PR-ledger refresh) |
| [#1098](https://github.com/AlaudaDevops/connectors-operator/pull/1098) | open | `docs(connectors-gitlab): mirror Harbor's sync-script approach for Task install instructions` — post-ship doc-bug fix (PR #1002 wrongly told users the operator installs the Task; corrected via existing `make sync-gitlab-connector-automatic-creation-task-doc` + missing `BEGIN/END GENERATED TASK YAML` markers) |

**`AlaudaDevops/connectors-extensions` — 5 PRs**

| PR | State | Role |
|----|-------|------|
| [#269](https://github.com/AlaudaDevops/connectors-extensions/pull/269) | merged | **Story 1** — `feat(connectors-gitlab/tektoncd): add gitlab-connector-automatic-creation Task` (Task definition + scripts + render tooling) |
| [#270](https://github.com/AlaudaDevops/connectors-extensions/pull/270) | merged | **Story 2** — `test(connectors-gitlab/tektoncd): BDD coverage for gitlab-connector-automatic-creation Task` (script.feature + tektoncd.feature + Pattern A/B fixtures) |
| [#271](https://github.com/AlaudaDevops/connectors-extensions/pull/271) | closed | docs concept + how-to + ops runbook — superseded; docs landed in operator repo via #1002 |
| [#288](https://github.com/AlaudaDevops/connectors-extensions/pull/288) | merged | `fix(connectors-gitlab/tektoncd): surface verbatim GitLab API error from ensure-gat list_gats` — **F1 post-qa fix** that drove the v146 bundle |
| [#292](https://github.com/AlaudaDevops/connectors-extensions/pull/292) | open | `feat(connectors-gitlab/tektoncd): add style.tekton.dev/descriptors annotation` — post-ship Tekton form-based UI improvement (12 descriptors at task.template.yaml source-of-truth + Title-Case access levels + scopes default `["api","read_repository"]` + displayParams trimmed to `connector,tenantGroup,accessLevel,scopes`); restores the descriptors that were originally — and incorrectly — placed in operator's `cmd/kodata/` (auto-synced; reverted via #1096's predecessor branch) |

**Tally:** 17 total · 12 merged (5 substantive + 7 workflow-state) · 3 closed/superseded (#888, #997, #271) · 3 open post-ship (#1096 ship, #1098 doc-bug fix, ext #292 descriptors).

**The 5 substantive PRs that constitute the actual scope of DEVOPS-43146:**
ext #269 (Task), ext #270 (BDD), ext #288 (F1 fix), op #1000 (operator wiring), op #1002 (docs).

**The 7 workflow-state writeouts (umbrella + drift fixes + ship + retro):**
op #1058, #1066, #1085, #1086, #1087, #1094, #1096.

**The 2 post-ship UX/doc fixes** (in-scope follow-ups discovered while applying to daniel-5shk6 for live UI verification):
op #1098 (install-section doc bug from #1002), ext #292 (Tekton form descriptors — `style.tekton.dev/descriptors` was missing from #269 entirely; rounds 1+2 land Title-Case enums + `read_repository` scope default + UX-trimmed `displayParams`).

## Post-ship lessons (2026-05-15)

Captured *after* the umbrella was archived, while iterating on the
descriptors annotation (ext #292) and the install-section doc bug
fix (op #1098) on a real cluster (daniel-5shk6, business). These
lessons did not exist in the pre-ship artifacts because the work that
surfaced them only happened post-ship.

### Tekton form-renderer ~4-field heuristic

Authored `style.tekton.dev/displayParams` listing 8 fields per the
naive "show users everything important" instinct. The actual UI
surfaces ~4 by default regardless of list length — confirmed against
v4.3 on daniel-5shk6. Round 2 trimmed `displayParams` to the 4 the
tenant operator must touch (`connector,tenantGroup,accessLevel,scopes`)
and let the rest sit in the Advanced section, descriptors-labelled.

The Tekton renderer is heuristic, not declarative. Treat
`displayParams` as "preferred 3–5 fields", not "render this list
verbatim". Documented in
[reference_tekton_descriptors_pattern memory](../../../../../.claude/projects/-workspaces-dev-code-github-com-alaudadevops-connectors-operator/memory/reference_tekton_descriptors_pattern.md)
and added as a Change entry to
[improvement-log.md](../../improvement-log.md).

### User-facing RBAC docs default to least-privilege, not reuse-of-shipped-editor

First draft of the ServiceAccount Permissions section reused the
shipped `connectors-connector-editor-role` ClusterRole for the
connectors half of the surface, citing "operator already ships this,
no redeclaration". Reviewer (Daniel) flagged that `editor` grants
delete/update/list/watch on top of the apply-only verbs the Task
actually uses — an over-broad surface for the platform-team SA.

Lesson: when documenting RBAC for a Task, default to a **dedicated
narrow ClusterRole** with exactly the verbs the Task uses. Reuse a
shipped role only when the verb sets match exactly. The shipped
editor role exists for human users / operator components that
genuinely edit Connectors; a Task that only `kubectl apply`s does not
qualify. Final shape on op #1098: one consolidated
`connectors-tenant-task-writer` ClusterRole with `{get, patch,
create}` on both `secrets` and `connectors`.

### kubernetes-Connector workspace is the *recommended* identity path

First draft framed the in-cluster TaskRun ServiceAccount as the
primary identity model and the kubernetes-Connector workspace as the
"cross-cluster only" alternative. Reviewer flagged that the
encouraged path is the kubernetes-Connector workspace even on the
same cluster — keeps provisioning identity on a Connector (uniform
mental model for platform teams), not on a TaskRun's SA.

Lesson: when a Task supports both an in-cluster SA and a
kubernetes-Connector workspace, lead the user-facing docs with the
Connector path. Mention the in-cluster SA only as the same-cluster
fallback. Applies to harbor-connector-automatic-creation too.

### Three-iteration RBAC table tightening

The ServiceAccount Permissions section took 3 iterations:
1. Single Role + RoleBinding scoped to one namespace
2. Two narrow ClusterRoles (secret-writer + connector-writer) +
   per-tenant RoleBindings
3. **One** consolidated `connectors-tenant-task-writer` ClusterRole
   + per-tenant RoleBinding

Final shape is least-privilege AND simplest. The split into two
roles (iteration 2) was over-engineered — the two rules always need
to be granted together (the Task always writes both Secret and
Connector), so splitting saves nothing and doubles the RoleBinding
boilerplate per tenant.

Lesson: for cohesive permission sets that the consumer always uses
together, prefer **one** ClusterRole over two. Split only when there's
a genuine independent-binding scenario.
