# Design Overview — {{epic_title}}

<!--
Written by /feature:design (epic-scope). Captures the architectural
shape across all stories — decisions that every story's own feature-
level design inherits. When a feature is /feature:story-start-ed from
this epic, its `product-design.md` / `tech-design.md` ## Context
sections link back here.
-->

## Goal (epic-scope)

<!--
One paragraph. What does this epic deliver as a user-visible capability?
What is explicitly out of scope for the epic (not just for a single
story)?

This is the contract the epic is held to at /feature:epic-close.
-->

{{epic_goal}}

## Architectural shape

### Components touched

- **connectors** — {{what_changes_here_at_architectural_level}}
- **connectors-extensions/<plugin>** — {{...}}
- **connectors-operator** — {{...}}
- **connectors-plugin** — {{...}}

### Cross-story invariants

<!--
Design constraints that every story in this epic must respect:
- data shapes
- API contracts
- security boundaries
- error surfaces
-->

- {{invariant_1}}
- {{invariant_2}}

### Shared credentials / state / resources

<!--
If stories share a resource that must be introduced in an early story,
flag the resource + the introducing story here.
-->

- {{resource}} — introduced by story {{id}}; used by stories {{ids}}.

## Out of scope

<!-- Things that are explicitly NOT part of this epic but might be follow-ups -->

- {{explicitly_excluded_1}} — tracked as follow-up in {{jira-id-or-TBD}}
- {{explicitly_excluded_2}}

## Open architectural decisions

<!--
Decisions that the team has not yet made but must be made before the
affected stories can start. Each comes with the approving reviewer.
-->

- {{decision_1}} — needs decision by {{date}}; approver: {{name}}.
- {{decision_2}}

## Reviewer (epic-level)

- **Lead reviewer:** {{name}}
- **Security reviewer:** {{name}} (risk=sensitive only)
- **Frontend lead:** {{name}} (if any story has slice=ui)
- **Sign-off date:** {{date}}
