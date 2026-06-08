# Retrospective — DEVOPS-43953 SonarQube auto-create

<!--
Written by /feature:retro BEFORE /feature:ship while the feature umbrella
is still active. profile=full → required (no opt-out).

Driver feedback collected via AskUserQuestion at retro time; AI synthesised
from the 13 maturity.entries (10 counted + 3 excluded) and the driver's
4 retrospective answers.
-->

## Worked

- **PR #1211 absorbing Story 3+4 code while PR #1147 became a docs-only
  flow archive.** Reviewers saw the bundle-input code (install.yaml,
  mk target, hack scripts, values.yaml image registration, mdx docs) as
  a single coherent diff in #1211 with a meaningful title and a tight
  set of changed files. PR #1147, once rebased onto main, became a
  pure flow archive (25 commits, 4272+/0-, 0 code changes) — a much
  cleaner review surface than the original "umbrella PR + Story 4 code
  + docs + design history all glued together" shape. Driver flagged
  this explicitly as the most-worth-repeating move of the feature.

- **DEVOPS-43146 (GitLab) as a structural template.** Plan layout
  (4 story_groups, same design-change + 3 mechanical-followups shape),
  test harness (godog + Allure + CEL assertion table, same selector
  labels), Task structure (script set + workspaces + helper
  rendering), and even the design-review R1 finding (`tokenDuration`
  derived from GitLab's `compute_token_expiry` precedent) all
  shortened decision time. Plan stage primary_blocker was `template`
  precisely because the value-add was extracting facts from the
  GitLab umbrella rather than originating novel design.

- **POC routing through Branch-3 (per-tenant user + key-pattern
  template).** Three options were explored against the real SonarQube
  Web API; Branch-1 (PROJECT_ANALYSIS_TOKEN) was rejected on
  measures-403 empirical evidence; Branch-3 simplified to "Task does
  not auto-create projects" after observing that SonarQube
  auto-creates at scan time when the user holds global
  `provisioning`. Empirical validation against SonarQube 8.9.2 +
  25.1 makes the design version-portable for free.

- **design-review R1 `tokenDuration` change.** Renaming `tokenExpiry`
  (absolute date) to `tokenDuration` (days) + adding
  `compute_token_expiry()` at step time both (a) lets cron-driven Task
  re-runs auto-extend the expiry without driver action, and (b) keeps
  credential-lifetime info out of Pod spec / TaskRun YAML / process
  args — a security improvement adopted on top of an ergonomics
  improvement.

## Didn't work

- **`duration_min` in maturity.entries is misleading as a "human
  time" metric.** The 1416-minute POC entry and the 32-minute integrate
  entry are calendar elapsed time between `opened_at` and `closed_at`,
  not active driver/AI work time. POC actually ran across several
  Discord-driven async sessions over ~24 calendar hours; active
  reasoning + commits totaled a small fraction of that wall time. The
  field's literal interpretation makes the loop look much heavier than
  it was. Cross-feature maturity rollups that average `duration_min`
  will systematically over-state effort for async-driver features.
  Driver flagged this in the retro pass: "实际花费时间并没有跨度那
  么长吧". This is a metric-design issue, not a feature-execution issue
  — the work itself was paced fine; the records make it look paced
  badly.

- **State-yaml drift for 11 days.** state.yaml was last written
  2026-05-22 by /feature:plan / /feature:implement; PR #325 merged
  2026-05-28, PR #1211 merged 2026-06-02, but state.yaml was not
  updated when either landed. The /feature:integrate command at
  reconciliation time had to absorb 11 days of out-of-band PR
  activity (Stories 1+2+3+4 PR-state, bundle PipelineRun query,
  rebase of PR #1147 onto main) in a single session. The drift is
  recoverable here because the work is documented in PR descriptions
  and git history, but for cross-feature reporting it makes the
  "feature is in implement" status look stale (it is — but only
  because no-one updated the row).

- **QA evidence reclamation.** The named PipelineRuns
  (`connectors-sonarqube-integration-test-bk9vw`,
  `connectors-sonarqube-lint-and-test-m4kn4`) are reclaimed from the
  live Tekton namespace because PR #325 merged 5 days ago; the
  extensions repo doesn't enable Tekton Watcher's results-archiver
  for the devops namespace. Per-scenario BDD outcomes are not
  recoverable — only the PR-check rollup status (SUCCESS) remains.
  For a retrospective audit (or a quality-gate appeal) the per-case
  granularity would matter.

## Change

- **(process) Decide PR-split shape during /feature:plan, not during
  /feature:implement.** This feature's plan recorded PR #1147 as the
  Story-4 PR carrying both code + state, then during implement we
  re-decided to carve Story 3+4 code out into PR #1211 and leave
  #1147 as docs-only. The carve-out was correct (driver flagged it
  as the top "worked" entry), but it created two reconciliations:
  state.yaml story_groups[].changes[].pr had to be re-keyed at
  /feature:integrate time, and PR #1147's title/description had to
  be rewritten to "feat → docs". Doing this split at plan time
  would have saved the reconciliation. Suggested plan-time
  convention: when stories 3 (docs) and 4 (operator wiring) live in
  the same repo and share a doc-build pre-hook, **default to one
  combined code PR + one separate docs-only flow-archive PR**, and
  record it in story_groups at plan time.

- **(template) Allow feature umbrella PRs to ship docs-only — make
  it the default, not a fallback.** The end-state of #1147 (25
  commits, 4272+/0-, only `docs/en/design/...` +
  `openspec/changes/.../`, all code-bearing content in a sibling PR)
  is exactly the right separation: code reviewers don't have to
  page through 4272 lines of design history, design reviewers
  don't have to context-switch into mdx + install.yaml. Suggest
  the template carry a "Story split" section that names the docs-
  only umbrella PR explicitly and gives the operator the option
  of "0-code feature PR" (the umbrella is just OpenSpec + design
  archive; all code-bearing changes live in named sibling PRs).
  Tightly couples with the (process) change above: plan stage
  declares both PRs upfront.

- **(tooling) Enable Tekton Watcher results-archiver for the
  extensions devops namespace.** Closes the QA-evidence gap above;
  per-scenario BDD outcomes survive the PipelineRun retention
  window and can be queried at /feature:qa, /feature:accept, or a
  post-release audit by name. Low operational cost (configmap +
  archiver pod), high evidentiary value.

- **(template) qa-results.md should carry a per-evidence
  "retention" line.** Each evidence row should explicitly note
  whether the underlying PipelineRun is still live, archived, or
  reclaimed-with-rollup-only. Makes the reclamation gap visible
  at QA write-time, not at audit time. The current template has
  it as a free-text note in the present file; promoting it to a
  per-row column would make the issue countable across features.

---

## Opt-out

n/a — profile=full, no opt-out.
