# QA Packet — {{title}}

<!--
Input to /feature:qa. Assembled from the test design in tech-design.md,
the bundle tag recorded at integrate, and environment instructions.
-->

## Bundle

- **Tag:** {{bundle_tag}}
- **Image:** {{bundle_image}}@{{digest}}
- **Included component images:** {{list}}

## Jira

- **Epic/story:** {{jira_id}} — {{title}} — [link]({{jira_url}})

## Acceptance criteria

<!-- Mapped from the feature's ACs. For each AC: expected BDD feature file(s) + scenario names + expected outcome. -->

### AC-1

- Text: {{ac_text}}
- BDD feature: `{{feature_file}}`
- Scenario(s): {{scenario_list}}
- Expected outcome: {{expected}}

### AC-2

- Text: {{ac_text}}
- ...

## Environment

- **Cluster requirements:** {{kind_or_acp}}, {{version_or_size}}
- **Kubeconfig retrieval:** {{instructions}}
- **Required feature flags:** {{flags}}
- **Prerequisite test App / Secret / Config:** {{details}}

## Test instructions

- **Regression tag expressions to run:** {{tags}}
- **How to interpret failure output:** {{notes}}
- **Who to contact on blockers:** {{contact}}

## Rollback

<!-- If the feature causes a regression for existing users, how to roll back. -->

- Steps: {{rollback_steps}}
