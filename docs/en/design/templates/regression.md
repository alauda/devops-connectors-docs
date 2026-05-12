# Regression — {{title}}

<!-- Output of /feature:regress. Suite outcome against the integrated bundle. -->

## Summary

- **Bundle under test:** {{bundle_tag}}@{{digest}}
- **Suite outcome:** {{passed | failed}}
- **Pass:** {{p}}  **Fail:** {{f}}  **Skipped:** {{s}}

## Allure report

- [Allure]({{allure_link}})

## Pre-existing failures excluded

<!--
List every test that was excluded from the pass count because it was already
failing before this feature. Opaque "known issues" defeats the purpose.
-->

| Test | Linked issue | Note |
|------|--------------|------|
| {{test_name}} | {{jira_id}} | {{note}} |
| {{test_name}} | {{jira_id}} | {{note}} |

## Failing tests (if any)

<!-- For each failure: test name, failure mode, linked bug. -->

- {{test_name}} — {{failure_mode}} — bug: {{jira_id}}

## Notes

{{any_other_observations}}
