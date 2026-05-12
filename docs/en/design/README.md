# Design Docs — Feature Workflow Umbrellas + Ad-hoc Design Folders

This directory holds three kinds of artifact, co-located:

1. **Feature umbrella folders** (`<jira-id>-<slug>/`) — created by the
   `/feature:*` command family. Each umbrella represents one shippable
   slice and runs the feature pipeline. Archives at `/feature:ship`.
2. **Epic umbrella folders** (`epics/<jira-id>-<slug>/`) — long-lived
   containers for multi-release Jira epics. Hold research, story list,
   design overview, dependency graph, and a post-release log. Archive
   at `/feature:epic-close`.
3. **Ad-hoc design folders** (kebab-case, e.g. `connector-gitlab/`,
   `connectors-approval/`) — pre-existing, not managed by `/feature:*`.
   Untouched and continue to work as before.

The naming conventions don't collide: feature umbrellas are always
Jira-prefixed; epic umbrellas live under `epics/`; ad-hoc folders are
kebab-case without a Jira prefix.

See the TEP for the full feature-workflow design:
[`docs/en/teps/feature-workflow.md`](../teps/feature-workflow.md).

## Layout

```
docs/en/design/
├── README.md                             # this file
├── improvement-log.md                    # cross-feature workflow improvements backlog
├── state.schema.json                     # JSON Schema (kind: feature|epic) for every state.yaml
├── templates/                            # artifact templates read at runtime by commands
├── archive/                              # shipped features (moved here at /feature:ship)
│   └── cancelled/                        # features closed without ship
├── epics/                                # long-lived epic umbrellas
│   ├── <jira-id>-<slug>/                 # in-flight epic umbrella
│   │   ├── epic.md
│   │   ├── state.yaml                    # kind: epic
│   │   ├── research.md                   # cross-story research
│   │   ├── design-overview.md            # architectural shape across stories
│   │   ├── stories.md                    # numbered story list
│   │   ├── dependencies.md               # story-level dependency graph
│   │   ├── threat-model.md               # risk=sensitive only
│   │   ├── design-review.md              # epic-level review outcomes
│   │   ├── post-release-log.md           # bugs linked + tech debt + new stories
│   │   └── shipped-features/             # back-links to archived feature umbrellas
│   │       └── <feature-jira-id>.link
│   └── archive/                          # closed epics
├── <kebab-name>/                         # existing ad-hoc design folders (pre-workflow)
└── <jira-id>-<slug>/                     # in-flight feature umbrella
    ├── feature.md                        # parent_epic back-link (if any)
    ├── state.yaml                        # kind: feature
    ├── handoff.md
    ├── dependencies.md                   # only for standalone profile=full features
    ├── research.md                       # profile=full standalone only
    ├── product-design.md
    ├── tech-design.md
    ├── threat-model.md                   # risk=sensitive only
    ├── ui-prototype.drawio               # when this slice includes UI
    ├── design-review.md                  # feature-level (implementation-depth)
    ├── poc.md                            # optional stage
    ├── qa-packet.md
    ├── qa-results.md
    ├── acceptance.md
    ├── release-notes.md
    ├── docs-changes.md
    ├── regression.md
    ├── security-sign-off.md              # risk=sensitive only
    ├── retrospective.md                  # written BEFORE ship
    └── maturity-report.md                # written AT ship
```

Retired artifacts (do not create these — replaced in the two-tier model):

- `post-ship-observations.md` — superseded by epic `post-release-log.md`.
- `postmortem.md` — superseded by epic `post-release-log.md` + feature `retrospective.md`.
- `hotfixes/<child-jira>.link` inside feature umbrella — superseded by epic `shipped-features/`.

## Lifecycle in one line

Epic lifecycle (for multi-release work):

```
epic-init → (research) → (design-overview → design-review)
         → ((story-start <id>) ∥ (bug-link) ∥ (story --add))
         → epic-close (all p0 stories shipped)
```

Feature lifecycle (per shippable slice):

```
init (standalone) OR story-start <id> (from epic)
   → (research) → design → design-review → (poc) → plan → implement
   → integrate → qa → [accept ∥ docs] → regress → (security-sign-off)
   → retrospective → ship (archive immediately)
```

Stages in parentheses are conditional. Ship archives the feature umbrella
immediately; there is no post-ship window. Post-release feedback attaches
to the parent epic (if any) via `/feature:bug-link`.

## Quickstart

Start a standalone feature (no epic needed):

```
/feature:init DEVOPS-12345 --profile=standard --effort=days
```

Start a multi-release epic:

```
/feature:epic-init DEVOPS-41818 --profile=full
/feature:research            # populates stories.md
/feature:story-start 1       # branch the first shippable slice
```

At any time, check where you are:

```
/feature:status              # active feature
/feature:epic-status         # active epic (multi-release board)
```

Run the next stage in the lifecycle:

```
/feature:next
```

Transfer ownership without cancelling work:

```
/feature:handoff <new-driver>
```

Pause while keeping draft PRs alive:

```
/feature:pause --reason="waiting-on-upstream-rfc"
/feature:resume
```

After release, attach a production bug to the epic:

```
/feature:bug-link DEVOPS-41999 --epic=DEVOPS-41818 \
    --related-story=1 --disposition=new-story-added --new-story-id=10
```

Close the epic when all p0 stories have shipped:

```
/feature:epic-close DEVOPS-41818
```

## State invariant

`state.yaml` is written only by commands. Manual edits are detected by
checksum and commands will refuse to proceed. The sanctioned recovery
path is:

```
/feature:state-repair --audit-reason="..."
```

See the TEP's [State Repair](../teps/feature-workflow.md#state-repair) section.

## Profiles

Profile is declared at init and scales **artifact size, not stage count**:

- **`light`** — one-line fix. Research collapses into design. Retro is opt-out.
- **`standard`** — 1-2 repos, risk ≥ standard. Research collapses into design.
- **`full`** — 3+ repos or new connector type. Research is a separate stage
  with mandatory story decomposition.

For epic umbrellas, the same three profiles apply at the epic scope and
are inherited as defaults by each story-started feature umbrella.

## Risk levels

- **`low`** — docs/refactor/test-only. No security artifacts.
- **`standard`** — security section in design-review; CI scans enforced.
- **`sensitive`** — standalone `threat-model.md`; security-labeled reviewer
  at design-review; `/feature:security-sign-off` gate before ship.

Epic-level risk is computed once at `/feature:epic-init` and inherited by
every story-started feature.

## Maturity, not automation rate

Every stage close records a `primary_blocker`:

- **`none`** — auto-complete.
- **`template`** — driver invented structure the template should have provided.
- **`skill`** — driver dropped out of `/feature:*` to a raw skill.
- **`kb`** — AI asked for context that should have been retrievable.
- **`judgment`** — stage inherently required human judgment (not a miss).
- **`flake`** — CI/transient; retry succeeded.

`/feature:metrics` rolls up blocker categories across features so the team
invests where intervention counts are highest — templates? skills? KB?

Post-release bug rate (from epic `post-release-log.md` entries) is tracked
separately as a product-quality signal.

## Cross-feature improvements

`improvement-log.md` in this directory accumulates `Change` entries from
every retrospective. It is the team's backlog of workflow improvements.
