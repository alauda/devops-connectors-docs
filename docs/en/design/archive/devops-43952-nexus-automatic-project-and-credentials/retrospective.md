# Retrospective — Nexus 自动创建 Project + Connector + Secret

<!-- Output of /feature:retro. risk=sensitive, profile=standard. -->

## Worked

- **POC inside `design` stage invalidated H1 before any code shipped.** Live
  Nexus 3.76 OSS testing during `/feature:design` discovered the
  `User` REST object has no `description` field — the fingerprint carrier
  had to live on `Role.description` instead. This is exactly the
  "design-validate" pattern logged at improvement-log line 33; running it
  in-stage saved an implement-side rewrite.
- **Bundling Story 1 (code + BDD + PaC pipeline) into one umbrella story
  matched how the work actually shipped** through PR #326 + #332. The
  original five-story plan would have forced three cross-story handoffs
  that produced no useful checkpoint signal.
- **Two-tier parallel review (`connectors-code-review` project-tier +
  `devops-connectors-review` team-tier) caught defects no single tier
  would have.** Round-1 against `dadbd4b`: B1 xtrace leak (team-tier),
  B2 Makefile registry drift (project-tier), I1 CoreDNS silent-noop
  sed (team-tier), I2 30m timeout (project-tier). Re-run against
  `c5808a7` confirmed zero regressions and zero new BLOCKING. The
  parallel-dispatch pattern is worth standardising for every
  `risk=sensitive` implement closure.
- **Driver-mandated local integration-test run before PaC** surfaced the
  `bdd@v1.14.1 StepCheckPodLogs` literal-substring semantics (it's
  `strings.Contains`, not regex). PaC turnaround would have masked this
  as a "passing but wrong" green for at least one more iteration.
- **`maturity.entries[]` `primary_blocker` field tracked the real signal
  without curation** — design `kb` (Nexus 3.76 quirks needed live POC),
  plan + security `judgment` (irreducible reviewer call), implement
  `flake` (CoreDNS SERVFAIL on kind), the rest `none`. That's a faithful
  workflow-quality snapshot, not a vanity scorecard.

## Didn't work

- **`/feature:integrate` prerequisite vs reality drift.** All Story-1
  PRs merged but `stage.current` was still `implement` (the implement
  stage was never explicitly closed because no AskUserQuestion fired
  while the driver was in Discord). Had to close implement + integrate
  atomically with two maturity entries to advance. Skill spec reads "
  implement closed" as a hard prereq, but the load-bearing condition
  is actually "all referenced PRs merged" — those should be aliased.
- **`/feature:docs` first pass missed the v1.11.0 release-notes block.**
  Sibling precedent (Harbor v1.10.0 `**Harbor Connector Enhancements**`)
  exists in `docs/en/overview/release_notes.mdx`, but the skill did not
  scan it. Driver had to ask "看看还缺什么". Result: follow-up PR #1207
  (6-line single-file diff) — work the first pass should have surfaced.
- **PaC `Succeeded=True` silently masked a no-op BDD run** via Tekton
  `onError: continue` + missing-`results.<name>` guard. The
  `check-test-status` literal-fix to `tasks.<name>.status` shipped in
  PR #332, but the pattern is reusable across every godog-driven PaC
  pipeline in connectors-extensions. Without driver's "PaC green is not
  proof" reflex (now in personal memory `feedback_pac_validation_requires_report.md`)
  this would have shipped a paper-green pipeline.
- **BDD framework literal-substring semantics not documented.** Wasted
  one round writing escaped-regex `Selecting ConnectorRef mode \(B\)` for
  TC9c assertions before discovering `bdd@v1.14.1 StepCheckPodLogs` does
  `strings.Contains`. The harness README in `connectors-extensions/connectors-*/bdd/`
  doesn't mention it; future Task authors will hit the same wall.

## Change

- **(template)** `/feature:docs` should scan `docs/en/overview/release_notes.mdx`
  for the most-recent **sibling-precedent block** (same connector family,
  same change class — e.g. Harbor v1.10.0 Connector Enhancements for
  this Nexus v1.11.0 entry) and prompt the driver if no equivalent
  block is found under the WIP version. The miss this run cost one
  follow-up PR (#1207); a scan-and-suggest hook would have folded it
  into the first pass.
- **(process)** `/feature:integrate` should accept "all referenced PRs
  merged" as implicit implement-stage closure (auto-fire the
  `implement → outcome:advance` history entry instead of refusing). An
  alternative is a `/feature:status` background pass that polls
  `story_groups[].changes[].pr_state` and closes `implement` when all
  reach `merged`. Today the gap forces atomic-fixup state.yaml edits
  every time the driver isn't sitting in the terminal during PR merge.
- **(process)** Two-tier parallel review (project-tier `connectors-code-review`
  + team-tier `devops-connectors-review`) should be the **default gate
  at `/feature:implement` exit when `risk == sensitive`**. Today both
  tiers must be invoked manually after the fact. Codify the dispatch +
  YAML-merge contract (project's `tier: project` + framework's untagged
  block) in the skill body so future sensitive features inherit it.
- **(tooling)** Promote "Tekton `finally` task that gates on prior task
  outcome **must** use `$(tasks.<name>.status)`, not `$(results.<name>)`"
  to a reusable PaC pipeline-fragment guard in connectors-extensions.
  The `check-test-status` literal-fix in PR #332 captures the pattern;
  lift it out of the per-Task pipeline and into a shared YAML snippet
  or a CI lint rule so the next pipeline author can't reintroduce the
  paper-green-on-skip class.
- **(scope)** Document `bdd@v1.14.1 StepCheckPodLogs` literal-substring
  semantics in `connectors-extensions/connectors-*/bdd/README.md` (or
  one shared BDD harness root README). The framework already commits
  to `strings.Contains`; making it discoverable to Task authors at the
  point of writing the `.feature` file would eliminate the
  regex-vs-literal trap this feature hit on TC9c.
- **(tooling)** Add a lint rule (or `shellcheck` config + explicit
  pre-commit hook) against `set -x` *inside* loops in
  `connectors-extensions/connectors-*/tektoncd/tasks/*/0.*/images/scripts/*.sh`.
  Re-enabling xtrace mid-retry-loop is the canonical credential-leak
  pattern (B1 finding this run): the next curl iteration emits `-u
  user:pass` to stderr via argv. Catch the pattern statically; don't
  rely on team-tier review to spot it every time.
