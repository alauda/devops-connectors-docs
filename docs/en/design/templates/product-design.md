# Product Design — {{title}}

<!--
Written by /feature:design. The primary output is the Goal statement; every
other section exists to support or validate it.
-->

## Goal

<!--
One paragraph. What problem does this feature solve? Who for? What does the
desired end state look like? What is explicitly out of scope?

The goal is the contract the feature is held to at every later gate
(design-review, accept, ship). A vague goal here will drift downstream.
-->

{{goal_paragraph}}

## Context

<!-- For profile=light and profile=standard; inline what would otherwise be research.md -->

- {{per-repo finding 1}}
- {{per-repo finding 2}}
- {{risk 1}}

## User-facing surface

### CRD fields

- `{{field_path}}` — {{purpose}}

### CLI flags / API endpoints

- {{flag_or_endpoint}} — {{purpose}}

### UI forms / screens

- {{screen}} — {{new-or-changed-behavior}}

### Doc pages

- `docs/en/connectors/{{slug}}.mdx` — {{what_changes}}

## Out of scope

- {{explicitly_excluded_1}}
- {{explicitly_excluded_2}}
