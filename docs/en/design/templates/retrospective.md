# Retrospective — {{title}}

<!--
Written by /feature:retro BEFORE /feature:ship while the feature umbrella
is still active. Required for standard and full profiles; opt-out for
light.
-->

## Worked

<!-- What went well and should be repeated. Be specific. -->

- {{entry_1}}
- {{entry_2}}

## Didn't work

<!--
What went poorly. Specific: which stage, what artifact, what symptom.

Post-release bugs filed AFTER this retrospective is written attach to
the parent epic's post-release-log.md (not here). The future feature
that fixes the bug writes its own `Didn't work` entry for the defect
class.
-->

- {{entry_1}}
- {{entry_2}}

## Change

<!--
What to do differently next time. Each entry tagged with one of:
  template | tooling | process | scope

Entries with `template` or `tooling` tags become candidates to improve
this TEP or the command implementations.
-->

- **(template)** {{entry_1}}
- **(tooling)** {{entry_2}}
- **(process)** {{entry_3}}
- **(scope)** {{entry_4}}

---

## Opt-out (for profile=light only)

<!-- If using /feature:retro --opt-out=<reason>, this is the whole file. -->

```
opt-out: {{reason}}
```

Recognized opt-out tokens: `trivial`, `dup-of=<feature-id>`, `sweep`.
