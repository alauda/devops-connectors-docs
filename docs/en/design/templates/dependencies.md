# Dependencies — {{title}}

<!--
Story-level dependency graph. Written by /feature:design and refined by
/feature:plan. Used by /feature:implement to order sub-agent dispatch.

Format: `<from-story-id> -> <to-story-id>   # rationale`

Cycles are rejected at /feature:design-review.
-->

```text
1 -> 2    # credential model blocks GitHub token issuance
1 -> 3    # credential model blocks GitLab token issuance
1 -> 4    # credential model blocks CRD extensions
4 -> 6    # CRD shape blocks UI form
1 -> 8, 2 -> 8, 3 -> 8, 4 -> 8, 5 -> 8  # e2e depends on all backend + callback
```

## Notes

- Stories with no incoming edges are "root" stories; they dispatch first.
- Mechanical-followups inherit their parent design-change's dependencies
  — no edges needed for followups.
- Cross-feature waits (`wait-for=<feature-id>:<story-id>`) live in
  state.yaml.collisions[].plan_decision, not here.
