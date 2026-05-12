# QA Results — {{title}}

<!-- Output of /feature:qa. Per-case pass/fail with evidence links. -->

## Summary

- **Bundle under test:** {{bundle_tag}}@{{digest}}
- **Total cases:** {{count}}
- **Pass:** {{p}}  **Fail:** {{f}}  **Blocked:** {{b}}
- **Outcome:** {{advance | loop-back-to-implement}}

## Per-case results

| # | Case | Method | Outcome | Evidence |
|---|------|--------|---------|----------|
| 1 | {{scenario}} | {{unit|integration|e2e|manual-ui}} | pass | {{link}} |
| 2 | {{scenario}} | {{method}} | fail | {{link}} |
| 3 | {{scenario}} | {{method}} | blocked | {{reason}} |

## Defects opened

<!-- One line per failure, linked to the Jira bug. -->

- {{jira_id}}: {{title}} — from case {{case_number}}.

## Acknowledged p1 failures (if advancing)

<!-- Explicit acknowledgment per p1 failure the driver decided to accept. -->

- Case {{case_number}}: {{reason_for_accepting}}.

## Reviewer

- **QA reviewer:** {{name}}
- **Signed at:** {{date}}

Verification that the enumerated cases match the test design 1:1 (no silently
dropped cases, no surprise additions without an updated test design entry): {{yes_or_deviations}}.
