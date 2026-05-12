# Research — {{title}}

<!--
Written by /feature:research. Profile=full only. For profile=light|standard,
research is inlined as a `## Context` section in product-design.md.
-->

## Overview

{{one-paragraph summary of what this feature touches and why}}

## Per-repo findings

### connectors

- {{finding_1}}
- {{finding_2}}

### connectors-extensions

- {{finding_1}}

### connectors-operator

- {{finding_1}}

### connectors-plugin

- {{finding_1}}

## Risks

- {{risk_1}}
- {{risk_2}}

## Unknowns

- {{unknown_1}} — blocks design decision about {{decision}}.

## References

- [{{ref_1_title}}]({{ref_1_url}})
- [{{ref_2_title}}]({{ref_2_url}})

## Acceptance Criteria (proposed — pending reporter sign-off)

<!-- Only populated when the source Jira had no ACs -->

AC-1. {{criterion_1}}
AC-2. {{criterion_2}}
AC-3. {{criterion_3}}

## Stories

<!-- Required for profile=full; refuse to close the stage without this section -->

1. **{{story_title}}** (p0, slice=backend, repos=[connectors, connectors-extensions])
   {{one-paragraph description}}
   Depends on: none.
   ACs: 1, 2.

2. **{{story_title}}** (p0, slice=ui, repos=[connectors-plugin])
   {{description}}
   Depends on: 1 (CRD shape).
   ACs: 3.

3. **{{story_title}}** (p1, slice=docs, repos=[connectors-operator])
   {{description}}
   Depends on: 1, 2.
   ACs: 4.

<!--
Rules:
- A story is the smallest slice that can be designed, implemented, reviewed,
  and shipped on its own (even if it doesn't have to ship alone).
- UI work is always a candidate story when the feature touches a CRD field,
  a connector configuration, or any user-facing surface. Refuse to close
  without either a UI story or an explicit "no UI needed because..." entry.
- Priority semantics:
  - p0 — must ship in this feature.
  - p1 — should ship; can defer with reviewer agreement.
  - p2 — follow-up feature (produces a Jira link here instead of an
    OpenSpec change).
-->
