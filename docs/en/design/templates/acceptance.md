# Acceptance — {{title}}

<!-- Output of /feature:accept. AC-by-AC pass/fail mapped to BDD results. -->

## Summary

- **Total ACs:** {{count}}
- **Pass:** {{p}}  **Fail:** {{f}}  **Unverified:** {{u}}
- **Overall status:** {{passed | failed}}

## Per-AC results

### AC-1 — {{ac_summary}}

- **BDD scenario(s):** {{scenario_list}}
- **BDD outcome:** {{pass | fail}}
- **Evidence:** [{{link_label}}]({{link}})
- **Status:** {{pass | fail | unverified}}

### AC-2 — {{ac_summary}}

- ...

## Failing ACs (if any)

<!-- For each failing AC, which story's implementation is responsible. -->

- AC-{{n}}: fails on {{scenario}} → story {{id}} needs re-work.

## Reviewer

- **Accept reviewer:** {{name}}
- **Signed at:** {{date}}
