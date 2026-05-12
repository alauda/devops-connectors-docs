# Post-Release Log — {{epic_title}}

<!--
Append-only log of events after the epic has produced its first release.
Entries are written by /feature:bug-link, /feature:story (--add --defer)
for tech debt, and /feature:epic-close (the closing summary).

This log lives on the epic umbrella because archived feature umbrellas
are not re-opened. Bugs, tech debt, and new stories discovered after a
release attach here.
-->

## Bug links

<!-- Entries appended by /feature:bug-link -->

- entry_at: {{timestamp}}
  jira_id: {{bug-jira-id}}
  severity: {{low | medium | high | critical}}
  related_story: {{story-id or null}}
  disposition: {{pending | fix-next-release | fold-into-inflight-story | defer | accept | new-story-added}}
  new_story_id: {{story-id or null}}
  notes: "{{short description}}"

## Tech debt and deferred work

<!-- Entries appended by /feature:story --add --defer -->

- added_at: {{timestamp}}
  story_id: {{new-id}}
  title: "{{title}}"
  priority: {{p1 | p2}}
  discovered_during: {{related-story-id or "standalone"}}
  notes: "{{short description}}"

## Closing summary

<!-- Appended by /feature:epic-close -->

- closed_at: {{timestamp}}
  total_shipped_features: {{N}}
  deferred_stories: {{M}}
  cancelled_stories: {{K}}
  total_bug_links: {{X}}
  total_tech_debt_added: {{Y}}
