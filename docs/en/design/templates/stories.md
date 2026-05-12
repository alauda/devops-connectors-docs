# Stories — {{epic_title}}

<!--
Written by /feature:research (epic-scope) and mutated by /feature:story
(--add, --split, --merge, --defer). The epic's state.yaml holds the
machine-readable equivalent; this file is the human view.

Each story's state transitions automatically as feature umbrellas branch
(via /feature:story-start) and ship (via /feature:ship).
-->

## Story list

<!--
Story format:

N. **{{title}}** ({{priority}}, slice={{slice}}, repos=[...])
   {{one-paragraph description}}
   Depends on: {{list of story ids or "none"}}.
   ACs: {{AC numbers}}
   State: {{not-started | in-flight | shipped | cancelled | deferred}}
   Shipped in release: {{release or "—"}}
   Feature umbrella: {{jira_id or "—"}}
-->

1. **{{story_title}}** (p0, slice=backend, repos=[...])
   {{description}}
   Depends on: none.
   ACs: 1, 2.
   State: not-started

2. **{{story_title}}** (p0, slice=ui, repos=[connectors-plugin])
   {{description}}
   Depends on: 1 (CRD shape).
   ACs: 3.
   State: not-started

<!-- etc. -->

## Priority semantics

- **p0** — must ship in this epic. Epic cannot close until every p0 is
  either shipped, cancelled (with rationale), or explicitly deferred
  to a follow-up epic at `/feature:epic-close --defer=...`.
- **p1** — should ship in this epic but can defer with reviewer
  agreement.
- **p2** — flagged for follow-up epic; produces a Jira link here
  instead of a feature umbrella.

## Slice semantics

- **backend** — server-side code in connectors / connectors-extensions /
  connectors-operator.
- **ui** — frontend code in connectors-plugin.
- **infra** — Tekton, CI, bundle infra.
- **docs** — user-facing documentation.
- **test** — e2e / integration-test scaffolding that doesn't fit inside
  a backend or ui story.
- **ops** — operational procedures, monitoring, runbooks.

## Adding / splitting / merging stories

Use `/feature:story` commands:

```
/feature:story --add "<title>" --priority=p0 --slice=backend --repos=connectors --depends-on=1
/feature:story --split 6
/feature:story --merge 10 11
/feature:story --defer 9 --jira=DEVOPS-44120
```

Each mutation records a history entry in `state.yaml.stories[].history`.
Substantial mutations (new slice, new repo, split producing different
reviewers) re-run a fast `/feature:design-review` on the affected story.
