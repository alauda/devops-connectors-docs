# Design Review — {{title}}

<!--
Written by /feature:design-review. Outcome is approved | pivot | rework.
-->

## Attendees

- {{reviewer_1}} — {{role}}
- {{reviewer_2}} — {{role}}
- {{reviewer_3}} — {{role}} (security-labeled, if risk=sensitive)
- {{reviewer_4}} — {{role}} (frontend lead, if any story has slice=ui)

## Checklist

- [ ] Goal is unambiguous
- [ ] Task breakdown covers the goal (no missing slices)
- [ ] Direction is right (no unnecessary rebuilds)
- [ ] Test design is concrete enough for QA to execute as-is
- [ ] For UI slices: drawio prototype is implementable without questions
- [ ] For risk=sensitive: threat-model residual risks acceptable
- [ ] Dependency graph has no cycles

## Security considerations

<!-- Required for risk >= standard. Expand for risk=sensitive. -->

- {{concern_1}}
- {{concern_2}}

## Decisions

1. {{decision_1}} — {{rationale}}
2. {{decision_2}} — {{rationale}}

## Outcome

<!-- One of: approved | pivot | rework -->

**{{outcome}}**

### Pivot / rework notes (if applicable)

{{what_needs_to_change_and_why}}

## Signatures

- {{reviewer_1}}: approved, {{date}}
- {{reviewer_2}}: approved, {{date}}
- Security reviewer: {{reviewer_3}}, {{date}} (risk=sensitive)
- Frontend lead: {{reviewer_4}}, {{date}} (story has slice=ui)
