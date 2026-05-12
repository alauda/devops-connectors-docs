# Maturity Report — {{title}}

<!--
Written at /feature:ship. Stratified blocker signal — the replacement for
a single "automation rate" percentage.
-->

## Feature metadata

- **Profile:** {{profile}}
- **Risk:** {{risk}}
- **Repos:** {{repos}}
- **Effort (advisory):** {{effort}}
- **Driver:** {{driver}} (+ handoffs: {{previous_drivers}})
- **Bundle shipped:** {{bundle_tag}}@{{digest}}

## Stage summary

```
Total stages run: {{n}}
  none:      {{a}}     (auto-complete)
  template:  {{b}}
  skill:     {{c}}
  kb:        {{d}}
  judgment:  {{e}}     (on-target — not a miss)
  flake:     {{f}}
```

## Top intervention sources

<!-- Derived from entries with largest driver_edits.lines_changed or highest ai_turns. -->

1. **({{category}})** stage `{{stage}}` — {{one_line_narrative}}.
   Suggested investment: {{template / skill / kb entry}}.

2. **({{category}})** stage `{{stage}}` — {{narrative}}.

3. **({{category}})** stage `{{stage}}` — {{narrative}}.

## Judgment-only stages (on-target)

<!-- Stages that were always going to be human judgment — not counted as misses. -->

- `{{stage}}`: {{reason_human_is_required}}.

## Excluded stages

<!-- Design-review loops, POC loops, story mutations, state-repair. -->

- `{{stage}}`: {{exclusion_reason}}.

## Reading this report

The category totals tell the team *where* to invest next (templates? skills?
KB?). The narratives tell the team *what specifically* to build. Judgment-only
interventions are the honest floor of human involvement on this class of work;
reducing them requires redesigning the stage, not better tooling.

This feature's category totals feed `docs/en/design/maturity-metrics.md`
via `/feature:metrics`.
