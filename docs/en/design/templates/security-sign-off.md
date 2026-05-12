# Security Sign-off — {{title}}

<!--
Required for risk=sensitive. Produced by /feature:security-sign-off.
-->

## Bundle under review

- **Tag:** {{bundle_tag}}
- **Image digest:** {{digest}}
- **Included manifest versions:** {{list}}

## Surface review

### Operator RBAC delta (vs previous bundle)

<!-- Diff of cluster roles / role bindings introduced or changed. -->

```diff
{{rbac_diff}}
```

### New exposed endpoints

- {{endpoint}} — {{purpose}}, {{tls_policy}}, {{auth_model}}

### Third-party network egress introduced

- {{destination}} — {{purpose}}, {{tls_policy}}, {{data_sent}}

## Findings

### Blocker findings

- {{finding_1}} — affected: {{component}} — must resolve before ship.

### Non-blocker findings

- {{finding_2}} — {{mitigation_or_acceptance}}.

## Decision

<!-- approved | rejected -->

**{{decision}}**

## Reviewer

- **Name:** {{name}}
- **Security label:** {{label}}
- **Date:** {{date}}
- **Rationale:** {{one_paragraph}}
