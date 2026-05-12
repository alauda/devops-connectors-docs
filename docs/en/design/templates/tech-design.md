# Tech Design — {{title}}

<!--
Written by /feature:design. Mirrors the Goal from product-design.md; adds
architecture, task breakdown, and test design.
-->

## Goal

<!-- Copy from product-design.md. Keep in sync. -->

{{goal_paragraph}}

## Architecture

### Components touched

- **connectors** — {{what_changes_here}}
- **connectors-extensions/<plugin>** — {{what_changes_here}}
- **connectors-operator** — {{what_changes_here}}
- **connectors-plugin** — {{what_changes_here}}

### Call paths

- {{caller}} → {{callee}} → {{result}}
- {{caller}} → {{callee}} (new) → {{result}}

### Failure modes

- {{scenario_1}} — {{handling}}
- {{scenario_2}} — {{handling}}

## Task Breakdown

<!--
Required. Numbered table. Validates goal coverage, direction, and
completeness before any code is written.

Invariant: every task maps to a story (or `default`) and a repo.
UI tasks must appear if any story has slice=ui.
-->

| # | Task | Story | Slice | Repo | Why |
|---|------|-------|-------|------|-----|
| 1 | {{task_name}} | 1 | backend | connectors | {{rationale}} |
| 2 | {{task_name}} | 1 | backend | connectors-extensions | {{rationale}} |
| 3 | {{task_name}} | 4 | backend | connectors-operator | {{rationale}} |
| 4 | {{task_name}} | 6 | ui | connectors-plugin | {{rationale}} |
| 5 | {{task_name}} | 7 | docs | connectors-operator | {{rationale}} |

### Goal coverage check

- AC-1 covered by tasks {{list}}
- AC-2 covered by tasks {{list}}
- Story 6 (UI) has tasks {{list}}
- No orphan ACs. No orphan tasks.

## Test Design

<!--
Required. The QA stage executes these cases against the integrated bundle.
-->

### Test methods per story

- Story 1 (backend): Go unit tests; Ginkgo integration test in `pkg/...`.
- Story 4 (operator): webhook unit tests; controller integration test with
  envtest.
- Story 6 (UI): component tests in `connectors-plugin`; manual walkthrough
  against the drawio prototype before PR review.
- Story 8 (e2e): new case(s) under `connectors-operator/test/integration`.

### Specific test cases

<!-- Each case has: scenario, input, expected outcome, test method -->

1. (p0) {{scenario}} — input {{input}} → expected {{expected}} — method: {{method}}.
2. (p0) {{scenario}} — input {{input}} → expected {{expected}} — method: {{method}}.
3. (p1) {{scenario}} — input {{input}} → expected {{expected}} — method: {{method}}.

### E2E case decision

<!-- Explicit yes/no. Defaulting to "no e2e" without a reason is rejected at design-review. -->

**Yes — new e2e cases required** in `connectors-operator/test/integration`:

- `{{test_file_1}}` — {{one-line_scenario}}
- `{{test_file_2}}` — {{one-line_scenario}}

Reason for needing new e2e cases: {{rationale}}.

<!-- OR: "No new e2e cases — covered by existing <suite>." with a reason. -->

### Re-approval log

<!-- If the test design is edited during implement, the design reviewer re-signs here. -->

- re-approved: {{reviewer_name}}, {{date}} — reason: {{what_changed_and_why}}
