# Workflow Improvement Log

Append-only backlog of cross-feature workflow improvements. Every `Change` entry
from every retrospective lands here. Entries are picked up in regular
maintenance work and struck through (with a link to the implementing PR) when
done.

Entry shape:

```
- YYYY-MM-DD · <feature-jira-id> · (tag) — one-line description. [open | in-PR-#N | done #N]
```

Tags: `template` · `tooling` · `process` · `scope`.

---

## Open

- 2026-05-14 · DEVOPS-43146 · (tooling) — `/feature:integrate` should accept `--re-record-bundle` (or auto-detect that current stage is past `integrate`) and refresh `bundle.{tag,image,digest}` without forcibly advancing `stage.current=qa`. Eliminates the most-common state-repair trigger when a post-qa fix produces a new bundle. [open]
- 2026-05-14 · DEVOPS-43146 · (tooling) — `/feature:record-merge <pr-url>` (or a PR-merge hook at `/feature:status` display time) to flip `story_groups[].changes[].pr_state` to `merged` automatically. Eliminates the second-most-common state-repair trigger. [open]
- 2026-05-14 · DEVOPS-43146 · (template) — `docs/en/design/templates/security-reviewers.md` should ship populated for each team, OR `/feature:init` should warn loudly when a feature could become `risk=sensitive` and the file is still the unfilled stub. Silent-degrade-to-self-acting at `/feature:security-sign-off` defeats the reviewer-separation intent. [open]
- 2026-05-14 · DEVOPS-43146 · (tooling) — Document the PaC GitHub App webhook-drift workaround inline in `/feature:implement` + `/feature:integrate` skill output ("If pushes aren't firing PipelineRuns within ~3 min, redeliver via GitHub App → Settings → Advanced → Recent Deliveries → Redeliver"). Currently only in personal memory; next driver shouldn't have to rediscover. [open]
- 2026-05-14 · DEVOPS-43146 · (process) — Document **R3-relaxed** (cite-latest-green-on-parent + delta-analysis) as a first-class option in `/feature:regress` skill body, alongside R1/R2/R3-strict. Today the skill lists three execution paths but "cite parent SHA when no green exists at the actual SHA" requires skill-level reasoning to construct on the fly. [open]
- 2026-05-14 · DEVOPS-43146 · (tooling) — `make render-tasks` should fail noisily (mtime check on `scripts/*.sh` vs the rendered `task.yaml`) when the rendered Task is older than its source scripts. Eliminates the silent-no-op pattern that bit F1 fix twice. [open]
- 2026-05-15 · DEVOPS-43146 · (template) — Extend `docs/en/design/templates/retrospective.md` with a `## PR ledger` section so PR links land durably alongside lessons-learned in the archived umbrella. Today the canonical PR list is the auto-link in Jira; the retro is the post-ship snapshot and the PR list there ages better than "go check Jira and grep". This feature added the section ad-hoc; promote to template so the next sensitive feature inherits it by default. [open]
- 2026-05-15 · DEVOPS-43146 · (template) — User-facing RBAC docs for Tekton Tasks should default to a dedicated **narrow** ClusterRole + per-tenant RoleBinding pattern with exactly the verbs the Task uses (typically `{get, patch, create}` for `kubectl apply --server-side` Tasks). **Do not** reuse the shipped `*-editor-role` ClusterRoles — `editor` grants `delete/update/list/watch` on top of the apply-only set, an over-broad surface for an automation SA. Reuse-the-shipped-role is appealing on first draft but is consistently flagged in review. Codify in any future Tekton-Task user-doc template. [open]
- 2026-05-15 · DEVOPS-43146 · (template) — When a Tekton Task supports both an in-cluster ServiceAccount **and** a `kubernetes`-class Connector workspace, user-facing docs should lead with the **kubernetes-Connector workspace as the *recommended* identity path** (uniform across same- and cross-cluster, identity lives on a Connector — the platform-team mental model). The in-cluster TaskRun SA is the same-cluster *fallback*. Applies to all `*-connector-automatic-creation` Tasks (gitlab, harbor, future). [open]
- 2026-05-15 · DEVOPS-43146 · (tooling) — The Tekton form-based UI surfaces only ~3-5 fields by default regardless of `style.tekton.dev/displayParams` list length (heuristic, not declarative — confirmed against ACP v4.3). When authoring the annotation, trim `displayParams` to the 3-5 most-important params; remaining params keep descriptors for the Advanced section. Document in `devops-tekton-dynamic-form-optimizer` skill (currently silent on this) so future authors don't ship a 10-field `displayParams` expecting all 10 to render. [open]
- 2026-05-15 · DEVOPS-43146 · (process) — For cohesive permission sets the consumer always uses together (e.g. a Task that always writes both Secret and Connector), default to **one** ClusterRole containing both rules, not split per resource. Splitting doubles per-tenant RoleBinding boilerplate without enabling any independent-binding scenario. Three-iteration tightening on op #1098 (1 Role → 2 ClusterRoles → 1 ClusterRole) is the canonical example; cite when reviewing future RBAC docs. [open]

## Done

_(none yet.)_
