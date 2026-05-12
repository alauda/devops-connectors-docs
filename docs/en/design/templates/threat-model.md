# Threat Model — {{title}}

<!--
Required for risk=sensitive. Reviewed at /feature:design-review by a
security-labeled reviewer.
-->

## Assets

<!-- What valuable things does this feature handle or protect? -->

- {{asset_1}} — {{why_sensitive}}
- {{asset_2}} — {{why_sensitive}}

## Actors

### Legitimate

- {{actor_1}} — {{what_they_do}}
- {{actor_2}} — {{what_they_do}}

### Adversarial

- {{attacker_1}} — {{goal}}
- {{attacker_2}} — {{goal}}

## Threats

| # | Threat | Affected asset | Likelihood | Impact |
|---|--------|----------------|------------|--------|
| 1 | {{threat_description}} | {{asset}} | low/med/high | low/med/high |
| 2 | {{threat_description}} | {{asset}} | low/med/high | low/med/high |

## Mitigations

| # | Threat | Planned mitigation | Lives in | Owner |
|---|--------|--------------------|----------|-------|
| 1 | {{threat_ref}} | {{mitigation}} | {{design_section}} | {{who}} |
| 2 | {{threat_ref}} | {{mitigation}} | {{design_section}} | {{who}} |

## Residual risk

<!--
Threats not fully mitigated and why accepting them is reasonable. The
security reviewer signs off on these.
-->

- {{residual_1}} — accepted because {{rationale}}.

## Reviewer

- **Name:** {{reviewer_name}}
- **Role:** {{role}}
- **Security label:** {{label}}
- **Sign-off date:** {{date}}
