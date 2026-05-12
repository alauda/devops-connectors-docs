# Epic: {{title}}

<!--
This file is the human-readable index of the epic umbrella. state.yaml is
the machine-readable source of truth. Both are written by /feature:*
commands; manual edits to state.yaml are detected by integrity hash.
-->

- **Jira epic:** {{jira_id}} — [link]({{jira_url}})
- **Reporter:** {{reporter}}
- **Assignee:** {{assignee}}
- **Blocks:** {{blocks}}

## Classification

- **Profile:** {{profile}}  (light | standard | full)
- **Risk:** {{risk}}  (low | standard | sensitive)
- **Repos affected (union across all stories):** {{repos_list}}
- **Driver:** {{driver}}

## Summary

{{one-paragraph summary of what this epic delivers — drawn from Jira or brief}}

## Story board (snapshot)

<!-- Rendered live by /feature:epic-status. This section is an illustrative snapshot. -->

- p0 stories shipped: {{shipped}}/{{p0_total}}
- p0 stories in-flight: {{inflight}}
- p0 stories not-started: {{not_started}}
- p1/p2 stories: {{other_count}}

See [`stories.md`](./stories.md) for the full list and
[`dependencies.md`](./dependencies.md) for the dependency graph.

## Release timeline (actual)

<!-- Populated as stories ship and their feature umbrellas archive -->

- 2026.XX — {{stories shipped in this release}}
- 2026.YY — {{stories shipped in this release}}

## Cross-epic collisions

{{list of colliding in-flight epics with severity and acknowledgment status}}

## Shipped features (back-links)

See [`shipped-features/`](./shipped-features/) for the list of archived
feature umbrellas that shipped slices of this epic.

## Post-release log

See [`post-release-log.md`](./post-release-log.md) for bugs linked via
`/feature:bug-link`, tech debt discovered mid-implementation, and new
stories added after the first release.

## Artifacts

- [state.yaml](./state.yaml) — machine-readable epic state
- [research.md](./research.md) — cross-story research (profile=full)
- [design-overview.md](./design-overview.md) — architectural shape across stories
- [stories.md](./stories.md) — numbered story list
- [dependencies.md](./dependencies.md) — story-level dependency graph
- [threat-model.md](./threat-model.md) — risk=sensitive only
- [design-review.md](./design-review.md) — epic-level review outcomes
- [post-release-log.md](./post-release-log.md) — append-only post-release events
- [shipped-features/](./shipped-features/) — back-links to archived feature umbrellas
