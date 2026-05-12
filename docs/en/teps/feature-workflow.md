---
status: proposed
authors:
  - daniel
created: 2026-04-14
---

# Feature Workflow — End-to-End AI-Driven Delivery

## TL;DR

**Problem.** The OpenSpec workflow stops at "code merged." Everything after that
— operator bundle version, QA handoff, acceptance, regression, ship — is
manual and has no traceability back to the Jira epic. A cross-repo feature
(connectors + extensions + operator + plugin) has no single place that says
what it is, where it is, or whether it's done. And because our release
cadence is monthly non-LTS + quarterly LTS, a Jira epic typically spans
*several* releases — which means any single umbrella that tries to track
it end-to-end either closes too early (before customers can test) or
stays open for months.

**Proposal.** Add a feature-level workflow one layer above per-repo OpenSpec
changes. One driver, one command family (`/feature:*`), **two umbrellas**:

- a long-lived **epic umbrella** for a Jira epic that survives across
  releases, holding research, story list, design overview, dependency
  graph, and a post-release log;
- a bounded **feature umbrella** per shippable slice that runs the feature
  pipeline and archives at ship.

The coordinator dispatches per-repo sub-agents when a feature spans multiple
repos; the driver sees a single linear pipeline per slice. A one-story
epic degenerates to just a feature umbrella (`/feature:init` is the
entrypoint, no epic container needed).

**Feature stages, one command each:**

```
init → (research →)? design → design-review → (poc →)? plan → implement
     → integrate → qa → [accept ∥ docs] → regress → [security-sign-off]
     → retrospective → ship (archive)
```

The `research` stage runs separately only for `profile=full`; for `light`
and `standard` it collapses into `design` as a `## Context` section. `poc`
is optional and triggered when design-review loops twice. **Retrospective
runs before ship**, not after — ship archives the feature umbrella
immediately.

**Epic umbrella commands (long-lived, multi-release):**

```
/feature:epic-init <jira>        — create the epic umbrella
/feature:story-start <story-id>  — branch a feature umbrella from the epic
/feature:bug-link <bug-jira>     — record a post-release bug on the epic
/feature:epic-status <jira>      — multi-release board
/feature:epic-close <jira>       — archive when all p0 stories have shipped
```

Post-release bugs, tech debt, and new stories attach to the **epic**
umbrella (which stays open across releases), not to archived feature
umbrellas.

**Key mechanics:**

- **Single driver surface.** `/feature:status` always shows current stage,
  next command, blockers, and a handoff snapshot any new driver can use to
  pick the feature up cold. `/feature:next` runs the next stage.
- **Three size profiles.** `--profile=light|standard|full` declared at init
  scales **artifact size**, not stage count. Even a one-line single-repo
  fix runs through QA, integrate, accept, and regress — what shrinks is
  the form of the artifacts (a one-line release-note instead of a full
  packet), never the validation gates. Research collapses into design for
  `light` and `standard`; retrospective is opt-out for `light`.
- **Design = goal + breakdown.** The design stage's primary output is the
  problem-and-goal statement; the task breakdown that accompanies it exists
  so the driver and reviewer can confirm the goal is fully covered, the
  direction is right, and nothing is missing — including UI work.
- **Story decomposition stays in research for `profile=full`.** The
  research stage still enumerates sub-stories (backend, UI, infra) with
  explicit priorities so each can be designed and shipped on its own
  slice. For smaller profiles, story decomposition happens inline in
  `/feature:design` when it applies at all.
- **Story is the unit of review and progress; repos are implementation
  fan-out.** `/feature:plan` produces a story group per story with one
  parent record and per-repo OpenSpec changes linked to it. Per-repo review
  is per story, not per `(repo × story)`.
- **Mechanical follow-ups are classed separately.** A downstream PR whose
  content is fully determined by an upstream design-change (e.g. the
  `connectors-operator` sync-install-manifests PR that follows a
  `connectors` annotation change) is tagged `mechanical-followup`: only
  `tasks.md` + PR, no independent OpenSpec pre-apply cycle, inherits review
  from the parent.
- **Story list mutates mid-flight.** `/feature:story --add | --split |
  --merge | --defer` edits the story list with history recording; substantial
  mutations re-run design-review for the affected story only. This is
  expected, not a failure mode.
- **Cross-repo without cognitive load.** `/feature:implement` fans out
  `/opsx:apply` to every affected repo in parallel, ordered by an explicit
  story-level dependency graph. Drill-down (`/feature:tracks`,
  `/feature:dispatch <repo>`) only surfaces when needed.
- **Cross-feature collisions are detected at init.** `/feature:init` scans
  in-flight feature umbrellas and flags any other feature touching the same
  connector type, plugin, or shared file area before work starts.
- **Design-review is a real gate** with `approved` / `pivot` / `rework`
  outcomes; two consecutive `pivot` outcomes trigger an optional
  `/feature:poc` stage before plan.
- **Accept and docs run in parallel** after QA; both must be green before
  regression.
- **Security review is risk-gated.** `--risk=low|standard|sensitive` set at
  init via a trigger-question checklist. Sensitive features require a
  `threat-model.md` at design time and a `/feature:security-sign-off` gate
  before ship.
- **Every stage has explicit entry/exit criteria.** Each stage names what
  must be true before it can start, what must be true to close it, and how
  that closure is verified — so drivers and reviewers share one definition
  of done per stage, not just per feature.
- **Driver handoff and pause are distinct.** `/feature:pause` freezes the
  feature while keeping the current driver; sub-agents are not cancelled,
  draft PRs stay open with a banner comment. `/feature:handoff <new-driver>`
  transfers ownership without cancelling in-flight work (use `--reset`
  explicitly if the new driver wants a clean slate).
- **Archive at ship; feedback flows to the epic.** `/feature:ship` archives
  the feature umbrella immediately. Post-release bugs are recorded on the
  *epic* via `/feature:bug-link`; fixes become new stories via
  `/feature:story-start`. Tech debt discovered mid-implementation adds a
  deferred story to the epic. The epic umbrella stays open until all its
  p0 stories have shipped.
- **State has a recovery path.** `/feature:state-repair --audit-reason=...`
  is the only sanctioned way to mutate `state.yaml` outside a stage
  command; it logs the intervention and excludes the feature from maturity
  metrics.
- **Retrospective runs before ship.** `/feature:retro` captures what went
  wrong, what worked, and what the next feature should do differently
  while the umbrella is still active; entries feed `/feature:metrics` so
  improvements are tracked, not just remembered. Light features may opt
  out with a single-word reason.
- **Workflow maturity is measured, not automation rate.** Every command
  records the *primary blocker* per stage (`template` / `skill` / `kb` /
  `judgment` / `flake` / `none`). `/feature:metrics` rolls up blocker
  counts across features, so the team sees *what to invest in next*
  (templates? skills? KB?) rather than chasing a single opaque percentage.
  Judgment-only interventions are the honest floor, not a miss.
- **Jira integration is minimal** (init-fetch, plan-comment, ship-transition,
  plus comments on pause/resume/handoff/bug-link/epic events) so it can be
  swapped later.

**Delivery.** Seven incremental implementation phases, each a separate
OpenSpec change. Phase 1 ships `/feature:init` (standalone feature),
`/feature:status`, `/feature:next`, `/feature:handoff`, `/feature:pause`,
`/feature:resume`, `/feature:state-repair`, the size-profile + cross-
feature collision checks, and the umbrella scaffolding. A separate
phase introduces the epic umbrella (`/feature:epic-init`,
`/feature:story-start`, `/feature:bug-link`, `/feature:epic-status`,
`/feature:epic-close`). Later phases add design flow with story
decomposition and mutation, implementation fan-out with dependency
graph, post-merge flow, the sensitive-feature overlay, retrospective +
ship with immediate archive, and the blocker-stratified maturity
tracker.

**What this is not.** Not a Jira replacement. Not a new CI system. Not a
forced migration of in-flight work. Existing OpenSpec changes keep working;
new features opt in at `/feature:init`.

---

- [Summary](#summary)
- [Motivation](#motivation)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
  - [Use Cases](#use-cases)
  - [Requirements](#requirements)
- [Proposal](#proposal)
  - [Core Concepts](#core-concepts)
  - [Repo Roles](#repo-roles)
  - [Umbrella Folder Layout](#umbrella-folder-layout)
  - [Notes and Warnings](#notes-and-warnings)
- [Design Details](#design-details)
  - [Stage Model](#stage-model)
  - [Feature Size Profiles](#feature-size-profiles)
  - [Command Surface and Artifacts](#command-surface-and-artifacts)
  - [Per-Stage Entry and Exit Criteria](#per-stage-entry-and-exit-criteria)
  - [State Files: Epic and Feature](#state-files-epic-and-feature)
  - [Design Stage: Goal First, Breakdown for Validation](#design-stage-goal-first-breakdown-for-validation)
  - [Story Decomposition in Research](#story-decomposition-in-research)
  - [Story as Unit, Repos as Fan-Out](#story-as-unit-repos-as-fan-out)
  - [Story Mutation Mid-Flight](#story-mutation-mid-flight)
  - [Cross-Repo Dependency Graph](#cross-repo-dependency-graph)
  - [Design-Review Gate Semantics](#design-review-gate-semantics)
  - [Optional POC Stage](#optional-poc-stage)
  - [Accept and Docs Parallel Fork](#accept-and-docs-parallel-fork)
  - [Cross-Repo Drill-Down](#cross-repo-drill-down)
  - [Cross-Feature Conflict Detection](#cross-feature-conflict-detection)
  - [Driver Handoff and Pause](#driver-handoff-and-pause)
  - [Post-Release Feedback](#post-release-feedback)
  - [State Repair](#state-repair)
  - [Retrospective](#retrospective)
  - [WIP and Capacity Signals](#wip-and-capacity-signals)
  - [Coordinator Dispatch Model](#coordinator-dispatch-model)
  - [Risk Gating and Security Review Overlay](#risk-gating-and-security-review-overlay)
  - [Workflow Maturity Tracking](#workflow-maturity-tracking)
  - [Jira Integration Points](#jira-integration-points)
  - [Bundle Version Linking](#bundle-version-linking)
- [Walkthrough](#walkthrough)
- [Design Evaluation](#design-evaluation)
- [Alternatives](#alternatives)
- [Implementation Plan](#implementation-plan)
- [Appendices](#appendices)
- [References](#references)

## Summary

This TEP defines a feature-level workflow that sits one layer above the
existing per-repo OpenSpec changes and drives a feature from a Jira epic
or story all the way to a shippable connectors-operator bundle version —
and through the post-release feedback that typically arrives one or more
releases later. The workflow is expressed as a small family of
`/feature:*` slash commands backed by two umbrella shapes in this
repository:

- A long-lived **epic umbrella** for Jira epics that naturally span
  multiple releases — holds research, story list, design overview,
  dependency graph, and a post-release log.
- A bounded **feature umbrella** per shippable slice — runs the feature
  pipeline, archives at ship, back-links to the epic.

A single driver walks each feature umbrella through the lifecycle; when a
feature affects more than one repo, the coordinator dispatches parallel
sub-agents to do per-repo work while still presenting one command surface
to the driver. The epic umbrella is the long-term container where
feedback that outlives a release lands.

The TEP is a living document. Teams are expected to amend it as stages
are collapsed, command names change, or new gates are added. The intent
is to capture the minimum structure needed for a single person to drive
any feature end-to-end as an *almost-autonomous* process today — with a
clear path to a fully *autonomous* process once workflow maturity
(measured by stratified blocker tracking, not a single automation
percentage) passes a threshold.

## Motivation

The OpenSpec workflow that lives in the `connectors` repo today stops at merge
to `main`. It has excellent coverage from research through apply and supports
optional post-apply phases (`/workflow:test`, `/workflow:accept`,
`/workflow:document`), but nothing in it ties a merged change to an operator
bundle version, a QA handoff, an acceptance record, or a regression result.
The Definition of Done the team actually works to — Jira epic closed only after
regression passes on a real bundle — therefore relies entirely on manual
tracking, inconsistent artifacts, and individual skill with the toolchain.

A cross-repo feature today spreads across four repos (`connectors`,
`connectors-extensions`, `connectors-operator`, `connectors-plugin`), each
with its own OpenSpec changes or ad-hoc designs, and converges silently at
the Tekton `sync-install-manifests` pipeline. There is no single place to
answer "which Jira, which bundle version, what is the QA status, what
regression ran, is it shippable." Drivers have to reconstruct this from git
logs, Tekton runs, and chat history every time they want to know where a
feature stands.

On top of that, **our release cadence is monthly non-LTS + quarterly LTS**.
A Jira epic that produces a user-visible capability typically spans several
such releases: story 1 ships in 2026.05, stories 2–4 in 2026.06, the UI
follow-up in 2026.07 (LTS), a production bug surfaces weeks later and
spawns story 10 for the next release. A single umbrella cannot both close
cleanly at ship *and* stay open to accumulate this feedback. The workflow
therefore separates the two concerns: a **feature umbrella** closes at
ship, and a **epic umbrella** stays open across releases to absorb
post-release bugs, tech debt, and new stories.

The goal of this proposal is to make the full lifecycle a walkable pipeline
with one command per stage, persistent state per feature, a coordinator
that handles multi-repo fan-out, and an epic-level container that holds
the multi-release story together so no driver has to reconstruct the
picture from chat history.

### Goals

- Provide a single command surface (`/feature:*`) that a driver can learn in
  one sitting and use to move any feature from Jira to shipped operator bundle
  to post-release cleanup.
- Give every shippable slice a bounded **feature umbrella** that is the single
  source of truth for its state, artifacts, and outcome during its lifecycle
  — and archive it cleanly at ship.
- Give every multi-release Jira epic a long-lived **epic umbrella** that
  survives across release cycles and collects the research, story list,
  design overview, dependency graph, and post-release log.
- Handle cross-repo features without requiring the driver to coordinate
  manually; the coordinator dispatches per-repo work and aggregates results.
- Make artifact size proportional to feature size via
  `--profile=light|standard|full`. Light reduces what each artifact has
  to contain (one-line release-note, single-line task breakdown), but
  every feature still goes through the full validation pipeline (QA,
  integrate, accept, regress) regardless of profile — testing is not a
  ceremony cost we trade away.
- Force large epics to decompose into shippable stories during research,
  so output stays bounded and reviewable rather than collapsing into one
  opaque mega-PR. Story decomposition lives on the epic umbrella; each
  story can then be started as a feature umbrella when ready.
- Make every stage's definition of done explicit (entry criteria, exit
  criteria, validation method) so drivers and reviewers cannot disagree
  about whether a stage actually closed.
- Support clean driver handoff at any stage so no feature is bottlenecked on
  one person's availability.
- Detect cross-feature collisions (two features touching the same connector,
  plugin module, or shared file area) at init, before merge conflicts and
  bundle interleaving become expensive.
- Capture lessons learned in a structured retrospective so workflow
  improvements compound rather than getting lost. The retrospective runs
  before ship, while the umbrella is still active.
- Preserve and wrap the existing `/opsx:*` and `/workflow:*` commands rather
  than replace them.
- Make security review proportional to risk via a `--risk` flag with a
  trigger-question checklist.
- Support post-release feedback: bugs, tech debt, and new stories discovered
  after a release have a first-class path onto the epic umbrella via
  `/feature:bug-link` and `/feature:story-start`, so they are not lost
  in Jira comments or tied to an already-archived feature.
- Measure workflow *maturity* — not a single "automation rate" — by
  stratifying every stage-level intervention into blocker categories
  (`template` / `skill` / `kb` / `judgment` / `flake`) so the team can see
  *what to invest in next* rather than chase an opaque percentage. The bar
  is "almost-autonomous" today (non-judgment blockers ≤ 2 per feature) and
  "autonomous" tomorrow (≤ 0.5 per feature, and remaining judgment steps
  prompt-able).

### Non-Goals

- This TEP does not replace Jira as the source of truth for business state; it
  records Jira identifiers and syncs transitions at specific gates, nothing
  more.
- It does not replace the Tekton pipelines that build images and sync install
  manifests; it observes them and records their outputs.
- It does not define a new CI system, a new testing framework, or a new QA
  tooling stack; it assembles handoff artifacts from what already exists.
- It does not force a minimum-complexity feature to go through every stage;
  stages are skippable when the artifacts they produce are not applicable (for
  example, a pure doc change skips `/feature:regress`).

### Use Cases

- **Driver with a tiny single-repo fix** — a one-line bug fix in the
  `connectors` repo. Driver runs `/feature:init --profile=light`. Every
  stage still runs (including QA, integrate, accept, regress); what
  shrinks is the artifact form: research is folded into design as a single
  `## Context` paragraph, the design itself is a single goal sentence +
  one-line breakdown, the QA packet is a single test case, the release-note
  is one line, and retrospective is opt-out with a one-word reason. The
  feature is still verified end-to-end on a real bundle.
- **Driver adding a single ConnectorClass definition** — a new
  `ConnectorClass` for an existing connector type (no new CRD, no UI),
  living entirely in `connectors`. Driver runs
  `/feature:init --profile=standard --connector=<existing-type>`. Plan,
  implement, integrate, QA, accept, regress all run against one repo;
  the QA test design covers the new class's accept/reject paths.
- **Driver building a Tekton task or job that consumes connectors** — an
  independent piece of automation (e.g. a CI Tekton task that resolves
  credentials through a `Connector`) that is not part of the operator
  bundle but uses the connectors stack. Driver runs `/feature:init` with
  the consuming repo as the affected repo; the workflow still runs QA
  against the resulting bundle behaviour because the task's correctness
  depends on the connectors API contract not changing under it. The
  integration step is lighter (no new bundle artifact) but not skipped.
- **Driver with a single-repo feature that still fans out a mechanical
  follow-up** — an annotation change to the `connectors` controller that
  requires a `connectors-operator` sync-install-manifests PR after merge.
  Driver runs `/feature:init --profile=standard`. Plan produces one
  design-change in `connectors` and one `mechanical-followup` change in
  `connectors-operator`. The follow-up has only `tasks.md` + a PR, no
  independent design or BDD; it inherits review from the parent
  design-change. The driver sees one story on the board, not two.
- **Driver with a four-repo connector feature** — a new connector type
  (e.g. Bitbucket) that touches `connectors-extensions` (per-type code and
  controller), `connectors-operator` (CRD wiring and bundle manifests),
  `connectors` (proxy/API integration), and `connectors-plugin` (UI form
  and connector card). Driver runs `/feature:init --profile=full`, which
  forces story decomposition during research and surfaces a UI slice as its
  own story. `/feature:plan` records a story-level dependency graph;
  `/feature:implement` dispatches in dependency order, holding downstream
  stories as draft until their blockers merge. `/feature:tracks` renders
  the graph when needed.
- **Driver whose story list needs to change mid-implementation** — during
  implement the driver realises story 3 (UI) is actually two independent
  slices (GitHub variant and GitLab variant) that different people can
  work on in parallel. They run `/feature:story --split 3`; the workflow
  records the mutation, re-runs a fast design-review on the two resulting
  stories, and continues. No need to cancel and restart the feature.
- **Driver with a sensitive feature** — something touching auth, secrets,
  TLS, or RBAC. The init checklist promotes `--risk` to `sensitive`; a
  `threat-model.md` is authored during design, reviewed at
  `/feature:design-review` by a security-labeled reviewer, and a
  `/feature:security-sign-off` stage is inserted before `/feature:ship`.
- **Driver inheriting a feature mid-stream** — someone else started the
  feature last week and went on leave. The new driver runs `/feature:status`
  and sees the current stage, blockers, exact next command, and the handoff
  snapshot left by `/feature:handoff` (open questions, decisions deferred,
  context the prior driver carried in their head). They can pick up without
  reading any history; in-flight draft PRs are still there waiting for
  them (handoff does not cancel sub-agents).
- **Driver pausing a feature** — the driver needs to step off the feature
  for two weeks but will come back to it themselves. They run
  `/feature:pause --reason="waiting-on-upstream-rfc"`. Sub-agents stay
  alive; draft PRs get a banner comment; Jira gets a comment; `state.yaml`
  records the pause. When they return, `/feature:resume` picks up exactly
  where they left off.
- **Driver with a multi-release epic (new connector type)** — a new
  connector type (e.g. Bitbucket) whose rollout will span releases
  2026.05 (backend + CRD), 2026.06 (UI), and 2026.07 (docs + e2e).
  Driver runs `/feature:epic-init DEVOPS-<id>` once; research + story
  decomposition + design overview live on the epic umbrella.
  `/feature:story-start 1` spawns a feature umbrella for the first
  story's shippable slice, which runs the full feature pipeline and
  archives at ship. The epic umbrella stays open across releases; the
  driver (or a different driver) runs `/feature:story-start 2` for the
  next slice whenever capacity allows.
- **Driver hitting a bug after a release** — a customer files a bug on
  the feature six weeks after release 2026.05. The epic is still open.
  Driver runs `/feature:bug-link <bug-jira-id> --epic=<epic-id>` to
  record the bug in the epic's `post-release-log.md`. Depending on
  severity and scope the team either (a) adds a new p0 story via
  `/feature:story --add` and runs `/feature:story-start` to fix it in
  the next release, (b) updates an in-flight story that already covers
  the affected area, or (c) documents the bug as accepted for a later
  release. The archived feature umbrella that originally shipped the
  affected code is not touched.
- **Driver hitting a cross-feature conflict** — at `/feature:init`, the
  collision check flags that another in-flight feature is also modifying
  `connectors-extensions/connectors-git`. The driver and the other feature's
  driver align on sequencing (or merge the work) before either reaches
  `/feature:implement`.
- **Driver whose `state.yaml` got corrupted** — a rare bug in an earlier
  command left `state.yaml` inconsistent. Instead of editing the file
  manually (which commands detect and refuse), the driver runs
  `/feature:state-repair --audit-reason="sync-manifest-pr-reference-wrong"`.
  The intervention is logged; the feature is excluded from maturity
  metrics for that run; the workflow continues.

### Requirements

- The workflow must be driven by slash commands only. No step should require
  the driver to know which skill or sub-agent to call directly.
- Feature state must be readable by a human and writable only by commands, so
  that state cannot drift from reality through ad-hoc editing.
- All artifacts must live in git so the full history of a feature is
  reproducible from the repository alone.
- Per-stage automation metrics must be captured automatically with no driver
  action; the driver pays zero cost for measurement.
- The TEP itself (this document) and all templates it references must be
  amendable without code changes to the command implementations; templates are
  read at runtime from this repo.

## Proposal

### Core Concepts

- **Epic umbrella** — a long-lived folder in this repo under
  `docs/en/design/epics/<jira-id>-<slug>/` that represents one Jira epic
  across all the releases it touches. Holds the epic-scope research, design
  overview, story list, dependency graph, and post-release log. Created by
  `/feature:epic-init`, persists while the epic has open p0 stories, and is
  archived by `/feature:epic-close` when all p0 stories have shipped. An
  epic umbrella is only created when the feature's scope will span multiple
  shippable slices or when the team expects multi-release work; a one-story
  Jira can skip directly to a feature umbrella.
- **Feature umbrella** — a bounded folder in this repo under
  `docs/en/design/<jira-id>-<slug>/` that represents one shippable slice.
  Holds design, QA, acceptance, regression, maturity report, and
  retrospective. Created by `/feature:init` (standalone) or
  `/feature:story-start` (when branched from an epic umbrella). Runs the
  feature pipeline and **archives immediately at `/feature:ship`**. A
  back-link is recorded on the parent epic (if any) so the umbrella stays
  discoverable.
- **Per-repo OpenSpec change** — the existing unit of work inside any single
  repo. One feature has one or more OpenSpec changes, each created and driven
  through `/opsx:*` commands as today, but linked back to the feature
  umbrella.
- **Story** — the unit of review and progress inside an epic. Each story
  has an id, a title, a slice (`backend` / `ui` / `infra` / `docs`), a
  priority, and a dependency list. For multi-release epics, stories live
  on the epic umbrella in `stories.md`; they become feature umbrellas via
  `/feature:story-start`. For single-story features (no epic), the story
  list lives on the feature umbrella. A story can span multiple repos via a
  **story group** (one parent record + per-repo OpenSpec changes linked to
  it). Per-repo review happens per story, not per `(repo × story)`.
- **Change classification** — every per-repo OpenSpec change inside a story
  group is either a `design-change` (full pre-apply cycle + independent
  review) or a `mechanical-followup` (only `tasks.md` + PR; inherits review
  from its parent design-change). Mechanical follow-ups capture downstream
  PRs whose content is fully determined by the parent (e.g. a
  sync-install-manifests PR that lands after a connectors annotation change).
- **Coordinator** — the implicit agent behind every `/feature:*` command.
  Reads the umbrella state, decides what to do (including whether to dispatch
  parallel sub-agents for multi-repo work), writes the resulting artifacts
  back into the umbrella folder, and updates state.
- **Stage** — a named step in the feature lifecycle. Each stage has one primary
  command, produces a specific artifact, and records a blocker-classified
  maturity entry when it closes.
- **Gate** — a stage whose outcome can block forward progress or loop back to
  a prior stage. `design-review` and, for sensitive features,
  `security-sign-off` are gates.
- **Risk level** — a feature-wide property set at init (`low | standard |
  sensitive`) that determines whether security-specific artifacts and gates
  are required. Inherited from the parent epic when a feature is
  story-started.
- **Paused feature** — a feature temporarily frozen by the current driver
  (not transferred). Sub-agents remain dispatched but inactive; draft PRs
  stay in place with a banner comment; `/feature:resume` restores the active
  state. Distinct from handoff, which transfers ownership.
- **Post-release feedback** — bugs, tech debt, or new stories discovered
  after a release ships. Recorded on the *epic* umbrella via
  `/feature:bug-link` (bugs) or `/feature:story --add` (new stories /
  deferred tech debt). The archived feature umbrellas that shipped the
  affected code are not re-opened; instead the fix becomes a new story
  that runs through its own feature pipeline.
- **Blocker classification** — every stage close records its
  `primary_blocker` (`template` / `skill` / `kb` / `judgment` / `flake` /
  `none`). This replaces a single "automation rate" as the workflow's
  maturity signal; the team invests where the blocker counts are highest.

### Repo Roles

| Repo | Role in this workflow |
|------|----------------------|
| `connectors-operator` | **Entrypoint.** Hosts feature umbrellas (`docs/en/design/<jira-id>-<slug>/`), this TEP, the `/feature:*` command implementations (`.claude/commands/feature/`), the state schema (`docs/en/design/state.schema.json`), and the artifact templates (`docs/en/design/templates/`). Design documents live here. The feature is declared "shippable" against an operator bundle version produced by this repo's Tekton pipelines. |
| `connectors` | Hosts the OpenSpec workflow (`/opsx:*`, `/workflow:*`) that `/feature:plan` and `/feature:implement` delegate into. Per-repo code lands in `openspec/changes/...` as today. |
| `connectors-extensions` | Per-connector implementation repo, organized as `connectors-extensions/connectors-<type>/`. Receives OpenSpec changes when a feature touches a specific connector type. No direct workflow commands added here; coordinator sub-agents operate on it when dispatched. |
| `connectors-plugin` | Frontend (Angular/Nx) repo that ships the connector UI: connector cards, configuration forms, and integration screens. Receives OpenSpec changes when a feature has a UI slice (most new connector types and most user-facing CRD fields). Coordinator sub-agents dispatch into the appropriate `apps/` or `libs/` workspace. |

Commands are implemented once in `connectors-operator` (colocated with the
umbrellas and state they mutate) but operate across repos by dispatching
sub-agents with the appropriate working directory. UI work is treated as a
peer slice, not a follow-up: the story decomposition step in research
enumerates UI alongside backend slices with explicit priority, so a connector
type ships with its UI in the same feature unless the team explicitly defers it.

### Umbrella Folder Layouts

#### Epic umbrella (long-lived)

```
connectors-operator/docs/en/design/epics/<jira-id>-<slug>/
├── epic.md                      # Jira link, affected repos, profile hint, open p0 stories
├── state.yaml                   # machine-readable epic state; written only by commands
├── research.md                  # cross-story research (profile=full only)
├── design-overview.md           # architectural shape across stories
├── stories.md                   # numbered story list with priority, slice, repos, depends-on
├── dependencies.md              # story-level dependency graph (edge list)
├── threat-model.md              # only for risk=sensitive
├── ui-prototype.drawio          # required when any story has slice=ui
├── design-review.md             # epic-level design-review outcomes
├── poc.md                       # /feature:poc output (optional; may be per-story)
├── post-release-log.md          # append-only: bugs linked via /feature:bug-link, tech debt, new stories
└── shipped-features/            # back-links to feature umbrellas that have shipped
    └── <feature-jira-id>.link
```

An epic umbrella in flight lives under `docs/en/design/epics/`. On
`/feature:epic-close` (invoked when all p0 stories have shipped), the
folder is moved into `docs/en/design/epics/archive/<jira-id>-<slug>/`.
All shipped-features back-links stay resolvable.

#### Feature umbrella (bounded)

```
connectors-operator/docs/en/design/<jira-id>-<slug>/
├── feature.md                   # Jira link (feature or story), parent_epic link, affected repos, profile, DoD
├── state.yaml                   # machine-readable feature state; written only by commands
├── handoff.md                   # written/updated by /feature:handoff; the "pick this up cold" doc
├── dependencies.md              # story-level dependency graph (only when the feature itself decomposes further)
├── research.md                  # profile=full standalone features only; inherited-from-epic features skip this
├── product-design.md            # when applicable
├── tech-design.md               # when applicable; includes Task Breakdown + Test Design sections
├── threat-model.md              # only for risk=sensitive (or inherited from epic)
├── ui-prototype.drawio          # required when this slice includes UI
├── design-review.md             # feature-level design-review (implementation-depth)
├── qa-packet.md                 # input to /feature:qa: bundle + test design + env
├── qa-results.md                # output of /feature:qa: per-case pass/fail + evidence
├── acceptance.md                # output of /feature:accept
├── release-notes.md             # output of /feature:docs
├── docs-changes.md              # index of user-facing doc edits
├── regression.md                # output of /feature:regress
├── security-sign-off.md         # only for risk=sensitive
├── retrospective.md             # written at /feature:retro BEFORE ship (opt-out for profile=light)
└── maturity-report.md           # written at /feature:ship: blocker classification + narrative
```

A feature in flight lives under `docs/en/design/`. **On `/feature:ship`,
the feature umbrella is archived immediately** — moved into
`docs/en/design/archive/<jira-id>-<slug>/`. There is no post-ship
window; long-term feedback flows to the parent epic umbrella via
`/feature:bug-link` + `/feature:story-start`.

Retired artifacts (from earlier TEP revisions — do not create these):

- `post-ship-observations.md` — superseded by epic `post-release-log.md`.
- `postmortem.md` — superseded by epic `post-release-log.md` entries +
  the feature's `retrospective.md`.
- `hotfixes/` subfolder — superseded by epic `shipped-features/` +
  `/feature:bug-link` + `/feature:story-start`.

### Notes and Warnings

- **Stages are skippable when inapplicable**, not when inconvenient. Invoking
  a stage command with `--skip=<reason>` records a history entry with
  `outcome: skipped` and the reason; skipped stages are always excluded from
  maturity metrics. `/feature:ship` refuses to close if a required stage
  for the feature's risk level is in `pending` state or was skipped with an
  unrecognized reason. A bootstrap list of recognized reasons ships in
  [Appendix H](#appendix-h---recognized-skip-reasons); teams can amend their
  own `feature.md` template to extend it.
- **`state.yaml` is not a user-edit file.** Manual edits are detected on the
  next command by checksum; the command refuses to proceed. The sanctioned
  recovery path is `/feature:state-repair --audit-reason="..."`, which
  records the intervention in `state.yaml.integrity.repairs[]` and excludes
  the feature from maturity metrics for that run. This is the only way
  integrity of maturity metrics can be guaranteed.
- **The coordinator never hides failed sub-agents.** If a dispatched per-repo
  task fails, the parent `/feature:*` command surfaces the failure and writes
  the repo's error into `state.yaml` under `failures:`; it does not retry
  silently.
- **Pause does not cancel sub-agents.** `/feature:pause` freezes the feature
  while leaving draft PRs intact and the current driver assigned.
  `/feature:handoff` transfers ownership without cancelling sub-agents by
  default; use `/feature:handoff --reset` when the new driver wants a
  clean slate.

## Design Details

### Stage Model

The workflow has two levels: the **epic lifecycle** (long-lived, optional)
and the **feature lifecycle** (bounded, always runs per shippable slice).
For a one-story feature with no parent epic, only the feature lifecycle runs.

#### Epic lifecycle (for multi-release work)

```text
epic-init
   │
(research)         (profile=full on the epic)
   │
design-overview    (architectural shape; feeds per-story design)
   │
(design-review)    (epic-level gate; approves the story list + overview)
   │
┌──┤  (stays open across releases) ──┐
│  ▼                                 │
│  (story-start <id>)  ── per story ─┼─► feature lifecycle (below)
│                                    │
│  (bug-link)  ─ post-release bug ───┤
│  (story --add)  ─ tech debt / new  ┤
│                    story added     │
└──▶ epic-close (when all p0 stories have shipped; archives epic umbrella)
```

Epic stages in parentheses are conditional — for small epics where research
is trivial, the driver may go straight from `epic-init` to `design-overview`
or even skip the overview and jump to a single story.

#### Feature lifecycle (per shippable slice)

```text
init  (standalone feature)  OR  story-start <id>  (branched from an epic)
  │
(research)            (profile=full standalone features only; epic-inherited features skip this)
  │
design                (goal first; task breakdown for validation)
  │
design-review ◀──── (on pivot/rework, loops back to design)
  │
(poc)                 (optional; triggered after two pivots in design-review)
  │
plan                  (story groups; per-repo changes classed design-change | mechanical-followup)
  │
implement             (parallel per repo, ordered by story dependency graph)
  │
integrate
  │
qa
  │
  ├─── accept ─────┐
  │                │
  └─── docs ───────┤
                   │
              regress
                   │
          [security-sign-off]   (only if risk=sensitive)
                   │
            retrospective       (opt-out for profile=light; lessons feed /feature:metrics)
                   │
                 ship             (archive immediately; back-link written on parent epic if any)
```

Stages in parentheses are conditional:

- `research` runs as a feature-level stage only for `profile=full` standalone
  features. When a feature is `story-start`-ed from an epic, research is
  inherited from the epic umbrella and the feature skips straight to `design`
  (which still writes `## Context` with any feature-specific notes).
- `poc` is optional and offered automatically after two consecutive `pivot`
  outcomes at `design-review`, or whenever the driver requests it.
- `security-sign-off` is inserted only for `risk=sensitive`.
- `retrospective` is required for `standard` and `full`; opt-out for `light`
  with a single-word reason. **Runs before ship**, not after.
- `ship` is always the final stage. It archives the feature umbrella
  immediately; there is no post-ship window.

Every stage has exactly one primary command; the commands are listed in the
next section. The exact subset that runs on a given feature depends on its
size profile (see [Feature Size Profiles](#feature-size-profiles)) and
whether it is standalone or epic-inherited.

### Feature Size Profiles

A one-line bug fix and a new four-repo connector type should not pay the
same ceremony cost. `/feature:init` accepts `--profile=light|standard|full`
(default `standard`). **The profile scales artifact size, not stage count.**
Every feature, regardless of profile, runs through every stage; what
changes is what each stage's artifact has to contain.

This rule exists because skipping QA, integrate, accept, or regress for
"small" features has historically been the source of the regressions that
look smallest in the diff and bite hardest in production. Validation cost
is not the cost we trade away.

| Stage | `light` | `standard` | `full` |
|-------|---------|------------|--------|
| `init` | required | required | required |
| `research` | collapsed into `design` as `## Context` paragraph | collapsed into `design` as `## Context` section | required (multi-page; story decomposition mandatory; UI slice named or explicitly waived) |
| `design` | required (one-sentence goal + one-line breakdown + named test cases; research context inlined) | required (goal + product-design + tech-design + test design + UI prototype if UI slice; research context inlined) | required (goal + product-design + tech-design + per-story tech notes + test design + UI prototype if UI slice) |
| `design-review` | required (async, one approver) | required (gate, two approvers) | required (gate, two approvers + domain owner per affected repo) |
| `poc` | opt-in; auto-offered after two pivots | opt-in; auto-offered after two pivots | opt-in; auto-offered after two pivots |
| `plan` | required (single story group; at most one design-change + mechanical-followups) | required (one story group per story; design-change + mechanical-followups classed per repo) | required (one story group per story; design-change + mechanical-followups classed per repo; per-repo review checkpoint per design-change) |
| `implement` | required | required | required |
| `integrate` | required (records bundle even if no new manifests; consumer features may pass with "no bundle delta" outcome) | required | required |
| `qa` | required (executes the named test cases against the bundle; minimum one acceptance scenario) | required (executes the test design from the design stage) | required (executes the test design from the design stage; e2e cases in connectors-operator/test/integration) |
| `accept` | required | required | required |
| `docs` | required (one-line release-note) | required (release-note + docs-changes index) | required (release-note + docs-changes + per-story doc deltas) |
| `regress` | required (focused regression around the changed area; minimum: tests for adjacent behaviour) | required (full regression suite) | required (full regression suite) |
| `security-sign-off` | required only if `risk=sensitive` | required only if `risk=sensitive` | required only if `risk=sensitive` |
| `retrospective` | **opt-out** with a single-word reason (e.g. `trivial`); if kept, three-line entry | required | required |
| `ship` | required · archives immediately · writes back-link on parent epic (if any) | required · archives immediately | required · archives immediately |

Profile selection rules:

- **Profiles are always driver-declared at `/feature:init`** via
  `--profile=light|standard|full`. There is no auto-detection heuristic
  (past heuristics tended to misfire both ways). If the driver does not
  provide `--profile`, the command refuses with the three options listed
  and a one-sentence description of each.
- **`full` is required automatically when affected repos ≥ 3 OR when the
  brief mentions a new connector type.** The command will refuse
  `--profile=light|standard` with a short explanation and prompt for
  `--profile=full`.

Profiles are sticky after `init` but can be promoted (`light → standard →
full`) at any stage via `/feature:promote --profile=...`. Promotion records
a history entry; previously-collapsed artifacts must be expanded to the
new profile's required form before `/feature:ship`.

Demotion (`full → standard`) is allowed via
`/feature:promote --profile=standard --demote-reason="..."` but requires
an explicit reason that is logged and surfaced at every subsequent gate.
The previous heavy approach (cancel and re-init) destroyed accumulated
state for no gain.

### Command Surface and Artifacts

Primary `/feature:*` commands, in stage order:

| # | Stage | Command | Primary Artifact | Summary of Coordinator Behavior |
|---|-------|---------|-------------------|----------------------------------|
| 0 | — | `/feature:status` | — | Read `state.yaml`; print stage, next command, open blockers, per-repo PR status, blocker-category summary so far, WIP summary for the current driver. Always available. |
| 0 | — | `/feature:next` | — | Run the single command the current stage dictates. Equivalent to `/feature:<stage>` with no arguments. |
| 1 | init | `/feature:init <jira-id\|brief> --profile=light\|standard\|full [--risk=...] [--repos=...] [--effort=...]` | `feature.md`, `state.yaml` | Fetch Jira epic/story details; run the risk-trigger checklist; scaffold the umbrella folder; record affected repos and the `--effort` tag if provided. `--profile` is required; no auto-detection. Emits a WIP warning if the driver already has ≥3 in-flight features. |
| 2 | research | `/feature:research` | `research.md` | **profile=full only.** Dispatch per-repo Explore sub-agents with scoped questions; consolidate into a single research doc; enforce `## Stories` section. For `light` and `standard`, this stage is skipped and its content inlines into `/feature:design` as `## Context`. |
| 3 | design | `/feature:design` | `product-design.md`, `tech-design.md`, optional `threat-model.md`, `dependencies.md` | Scaffold design files using the operator's existing multi-level convention; for `light`/`standard`, include a `## Context` section that replaces the research document; for `risk=sensitive`, also scaffold `threat-model.md`; write the story-level dependency graph to `dependencies.md`. Human-driven content; coordinator drafts and asks focused questions. |
| 4 | design-review | `/feature:design-review` | `design-review.md` | Drive a review session: outcome is `approved`, `pivot`, or `rework`. On `pivot` or `rework`, stage state returns to `design`. On the second consecutive `pivot`, the command offers `/feature:poc` before the next design attempt. For risk=sensitive, reviewer group must include a security-labeled approver. |
| 4.5 | poc | `/feature:poc` | `poc.md` + throwaway branch | **Optional.** Spike the risky bits in a branch; record outcome and lessons in `poc.md`; feed results into the next `/feature:design` pass. Offered automatically after two consecutive pivots; driver can decline. |
| 5 | plan | `/feature:plan` | Per-story OpenSpec change groups (design-change + mechanical-followup per repo) with pre-apply artifacts and per-story review sign-off | Create one story group per story; inside each story group, create per-repo OpenSpec changes classed as either `design-change` (full pre-apply: `proposal → specs → design → tasks → bdd-design`) or `mechanical-followup` (only `tasks.md` + PR, inherits review from its parent); populate each `proposal.md` with a `feature:` back-link to the umbrella; **walk each design-change through the OpenSpec pre-apply phases** using `/opsx:ff` or `/opsx:continue`; **convene a per-story review** on the group's `design.md` and `bdd-design.md` — one reviewer signs for the whole story group unless a cross-repo concern escalates it to per-repo. |
| 6 | implement | `/feature:implement [--repo=<name>]` | Per-repo PR URLs in `state.yaml` | Dispatch `/opsx:apply` sub-agents in dependency order (from `dependencies.md`); stories with no unmet dependencies dispatch first, downstream stories stay as `draft` PRs until their blockers merge, then auto-rebase and re-dispatch. Mechanical-followups dispatch when their parent design-change merges. Without `--repo`, all ready repos in parallel; with `--repo`, only that repo. |
| 7 | integrate | `/feature:integrate` | Bundle version recorded in `state.yaml` | Watch `.tekton/sync-install-manifests.yaml` PRs in this repo; record the synced manifest versions and the bundle image tag that first includes them. |
| 8 | qa | `/feature:qa` | `qa-results.md`, updated `qa-packet.md` | Execute the test design from `tech-design.md` against the integrated bundle: run each named test case (unit, integration, e2e per the test design), record per-case pass/fail with evidence link, log defects, decide advance vs. loop back to `implement`. The `qa-packet.md` exists as input (assembled from the test design + bundle + environment instructions); QA outputs `qa-results.md`. |
| 9a | accept | `/feature:accept` | `acceptance.md` | Aggregate per-repo `/workflow:accept` outputs; map each proposal AC to a BDD result; report pass/fail per AC. |
| 9b | docs | `/feature:docs` | `release-notes.md`, `docs-changes.md` | Draft release-note entry in the operator's existing release-note convention; enumerate user-facing doc edits under `docs/en/connectors/`; open a follow-up PR if needed. Runs in parallel with 9a. |
| 10 | regress | `/feature:regress` | `regression.md` | Execute the regression suite against the recorded bundle version; record pass/fail and Allure report link. Requires 9a and 9b both green. |
| 10.5 | security-sign-off | `/feature:security-sign-off` | `security-sign-off.md` | Only if risk=sensitive. Review bundle image digests, operator permissions, exposed endpoints; capture reviewer decision. |
| 11 | retrospective | `/feature:retro [--opt-out=<reason>]` | `retrospective.md` | Capture what worked, what didn't, what to change. Tag entries with `template`, `tooling`, `process`, or `scope`. Append into the cross-feature improvement log. Required for `standard` and `full`; opt-out for `light` with a single-word reason (`trivial`, `dup-of=<feature>`, `sweep`). **Runs before ship.** |
| 12 | ship | `/feature:ship` | `maturity-report.md`; Jira → Done; feature umbrella archived | Refuse if required artifacts are missing or red. Transition Jira. Write `maturity-report.md` (blocker-stratified; see [Workflow Maturity Tracking](#workflow-maturity-tracking)). **Archive the feature umbrella immediately.** Write a back-link file on the parent epic (if any) under `shipped-features/`. |

Drill-down commands (see [Cross-Repo Drill-Down](#cross-repo-drill-down)):

| Command | Scope | Purpose |
|---------|-------|---------|
| `/feature:tracks` | Any stage that operates per-story (currently `implement`, `qa`) | Show a story-grouped board rendered from `dependencies.md` |
| `/feature:dispatch <repo>` | Same | Run the next thing for one specific repo without waiting for others |

Lifecycle commands:

| Command | Purpose |
|---------|---------|
| `/feature:handoff <new-driver> [--note=...] [--reset]` | Transfer feature ownership; snapshot current context (open questions, deferred decisions) into `handoff.md`; leave in-flight sub-agents intact unless `--reset` is passed. New driver's first command is `/feature:status`. |
| `/feature:pause [--reason=...]` | Freeze the feature, keep the current driver. Sub-agents not cancelled; draft PRs get a banner comment; Jira gets a comment. Use when the driver needs to step off temporarily. |
| `/feature:resume` | Un-freeze a paused feature; resume from the stage it was paused at. |
| `/feature:promote --profile=... [--demote-reason=...]` | Promote or demote between profiles. Promotion re-opens previously collapsed artifacts as `pending`. Demotion requires an explicit reason logged in `state.yaml.feature.profile_history[]`. |
| `/feature:cancel [--reason=...]` | Close an in-flight feature without ship. Records the reason and moves the umbrella to `archive/cancelled/`. |
| `/feature:conflicts` | Re-run the cross-feature collision check at any time. |
| `/feature:story --add\|--split <id>\|--merge <a> <b>\|--defer <id>` | Mutate the story list mid-flight (on whichever umbrella owns the list — epic for multi-release features, feature umbrella for standalone profile=full work). Records a history entry; substantial mutations re-run design-review for the affected story only. |
| `/feature:state-repair --audit-reason="..."` | Sanctioned `state.yaml` recovery path. Logs the intervention in `state.yaml.integrity.repairs[]`; excludes the feature from maturity metrics for that run. |

Epic-level commands (see [Post-Release Feedback](#post-release-feedback)):

| Command | Purpose |
|---------|---------|
| `/feature:epic-init <jira-id\|brief> [--profile=...] [--risk=...] [--repos=...]` | Create a new epic umbrella under `docs/en/design/epics/<jira-id>-<slug>/`. Fetch the Jira epic; run the epic-scope risk checklist; scaffold `epic.md`, `state.yaml`, `research.md`, `design-overview.md`, `stories.md`, `dependencies.md`. Used when a feature will span multiple releases or stories. |
| `/feature:story-start <story-id> [--driver=...]` | Branch a new feature umbrella from the current (or named) epic for a specific story. Inherits `risk`, `repos`, research, and design overview from the epic; feature's own `design` stage focuses on implementation-level detail. Feature runs the normal pipeline and archives at ship. |
| `/feature:bug-link <bug-jira-id> [--epic=<id>] [--related-story=<id>]` | Record a post-release bug on the epic's `post-release-log.md`. Captures severity, affected release, linked Jira ticket, and the team's disposition (fix in next release / add story / defer / accept). Does NOT re-open the archived feature umbrella. |
| `/feature:epic-status [<jira-id>]` | Multi-release board for an epic: per-story state, which release each shipped story landed in, open post-release items, remaining p0 stories. Read-only. |
| `/feature:epic-close <jira-id>` | Archive the epic umbrella when all p0 stories have shipped. Move to `docs/en/design/epics/archive/`. Refuses if any p0 story is not yet shipped or cancelled. |

Metrics commands (see [Workflow Maturity Tracking](#workflow-maturity-tracking)):

| Command | Purpose |
|---------|---------|
| `/feature:maturity` | Show this feature's per-stage blocker record and category totals. |
| `/feature:metrics` | Roll up blocker categories across all features in `archive/`. Reports per-category trend, top intervention sources, WIP distribution across drivers, and post-release bug rate derived from epic post-release logs. |

### Per-Stage Entry and Exit Criteria

Every stage names what must be true to enter, what must be true to close,
and how the closure is verified. Entry criteria are checked by the command
itself (refusing to start otherwise). Exit criteria are checked at close
(refusing to advance otherwise). Validation method tells the driver and
reviewer what evidence to look at — there is no implicit "looks good."

| Stage | Entry criteria | Exit criteria | Validation method |
|-------|---------------|---------------|-------------------|
| `init` | Driver provided either a Jira id or a free-text brief; `--profile` provided; cross-feature collision check ran. | `feature.md` and `state.yaml` exist; risk computed; profile chosen; affected repos listed; `--effort` tag recorded if provided; collisions either none or explicitly acknowledged; WIP warning emitted if driver is on ≥3 in-flight features. | Schema validation of `state.yaml`; `/feature:status` returns a coherent summary. |
| `research` | `init` closed; `profile=full`; affected repos exist on disk; Explore sub-agents reachable. | `research.md` records: per-repo findings, risks, unknowns, references; a numbered list of stories with priority and slice (`backend`, `ui`, `infra`, `docs`); UI slice named or explicitly waived. | Reviewer checks every affected repo is mentioned at least once; story list covers the brief without overlap. Skipped entirely for `profile=light\|standard`. |
| `design` | `init` closed (for `light`/`standard`) or `research` closed (for `full`); for `profile=full`, at least one story exists. | For `light`/`standard`: `product-design.md` / `tech-design.md` include a `## Context` section replacing a standalone research document. For all profiles: the goal is stated first, followed by a numbered task breakdown that maps each task to a story and a target repo; `tech-design.md` includes `## Test Design` with named test methods, specific test cases, and an explicit e2e-case decision; `dependencies.md` enumerates story-level edges; for any story with `slice=ui`, `ui-prototype.drawio` exists; for `risk=sensitive`, `threat-model.md` exists. | Reviewer confirms (a) goal is unambiguous, (b) breakdown covers the goal, (c) no missing slices (especially UI when applicable), (d) direction is right, (e) test design is concrete enough that QA can execute it as-is, (f) for UI, the drawio prototype is implementable without further questions. |
| `design-review` | `design` closed; reviewers nominated. | `design-review.md` records `approved`, `pivot`, or `rework`; for `risk=sensitive`, a security-labeled reviewer signed; for `profile=full`, every affected repo has a domain-owner approval. On the second consecutive `pivot`, `/feature:poc` is offered. | Gate check inside the command refuses to advance unless required signatures present. |
| `poc` | `design-review` returned `pivot` twice, or driver invoked `/feature:poc` explicitly. | `poc.md` records the hypothesis under test, the throwaway branch URL, the outcome (`validated` / `invalidated` / `inconclusive`), and the design changes that fall out of it. | Branch URL resolves; outcome recorded; next `/feature:design` pass includes the POC findings in `## Context`. Poc loop-backs do not count against maturity metrics. |
| `plan` | `design-review` outcome is `approved`; affected repos have working OpenSpec setups (`/opsx:*` available). | One **story group** exists per story. Inside each group, every per-repo entry is classed as `design-change` or `mechanical-followup`. Every `design-change` has all pre-apply artifacts populated (`proposal.md`, `specs/`, `design.md`, `tasks.md`, `bdd-design.md`) and a `Per-story reviewer:` sign-off line. Every `mechanical-followup` has `tasks.md` only and a `parent:` reference to a design-change in the same story group. Back-links to the umbrella resolve in both directions. `dependencies.md` is reconfirmed against the planned changes. | `openspec status --change <id>` in each repo shows every artifact `complete` for design-changes (skipped for mechanical-followups); the per-story reviewer signature is recorded in `state.yaml.story_groups[].review`. `/feature:implement` refuses to dispatch on groups without a recorded review. |
| `implement` | `plan` closed; sub-agents have working `/opsx:apply` in every affected repo. | All per-repo PRs are merged in dependency order; every BDD acceptance file referenced in `proposal.md` exists and is green; mechanical-followup PRs have merged behind their parent design-change; no unresolved review comments. | `/feature:tracks` shows every story at `merged` and BDD `green`; CI green on every merged PR. |
| `integrate` | `implement` closed; all PRs merged. | `state.yaml.bundle.bundle_tag` is non-null; the bundle includes manifest versions for every merged PR. | Tekton sync-install-manifests pipeline reports success; bundle image digest reachable. |
| `qa` | `integrate` closed; bundle reachable; test design from `tech-design.md` is approved (re-approval recorded if amended during implement). | `qa-packet.md` (input) exists; `qa-results.md` (output) records every test case from the test design with `pass`/`fail`/`blocked` and an evidence link (Allure / log / screenshot); all `p0` cases pass; defects opened for each failure; outcome is either `advance` (all p0 green, p1 within tolerance) or `loop-back-to-implement` (with the failing cases listed). | Reviewer (QA-labeled approver) signs `qa-results.md`; the cases enumerated match the test design 1:1 (no silently dropped cases, no surprise additions without an updated test design entry). |
| `accept` | `qa` closed. | `acceptance.md` maps every AC from `proposal.md` to a BDD result; overall status is `passed` or `failed`. | Each AC explicitly listed; no AC missing a verdict. |
| `docs` | `qa` closed. | `release-notes.md` drafted in this repo's release-note convention; `docs-changes.md` enumerates every doc edit (with target file paths); follow-up doc PR opened or filed under `docs/en/connectors/`. | Release-note draft renders; doc PR link resolves (or `docs-changes.md` records "no user-facing doc change needed" with reason). |
| `regress` | `accept` and `docs` both closed and `passed`/`complete`. | `regression.md` records suite outcome, Allure link, and explicit list of any pre-existing failures excluded. | Allure report reachable; pass count matches expected suite size. |
| `security-sign-off` | `regress` closed; `risk=sensitive`; bundle digest reviewable. | `security-sign-off.md` records `approved` or `rejected` with reviewer, bundle digest, RBAC delta, exposed endpoints. | `approved` required to advance; reviewer must hold a security label. |
| `retrospective` | `regress` closed (and `security-sign-off` closed if `risk=sensitive`). Runs *before* ship. | For `standard` and `full`: `retrospective.md` exists with at least one entry per category (`worked`, `didnt-work`, `change`); each entry tagged with `template`, `tooling`, `process`, or `scope`; entries appended to `docs/en/design/improvement-log.md`. For `light`: either a three-line entry exists, or `retrospective.md` contains `opt-out: <reason>` where reason is one of the recognized opt-out tokens. | Each required category non-empty (or opt-out recorded); `/feature:metrics` rollup increments. |
| `ship` | `retrospective` closed; Jira reachable. | Jira ticket transitioned to `Done`; `maturity-report.md` written; feature umbrella moved to `docs/en/design/archive/<jira-id>-<slug>/`; if a parent epic exists, a back-link file `<feature-jira-id>.link` is created under the epic's `shipped-features/`. | Jira API confirms transition; `maturity-report.md` renders; archive folder exists; bundle tag still resolves; epic back-link resolves in both directions (if applicable). |

Epic-level stages (only for multi-release work managed by `/feature:epic-init`):

| Stage | Entry criteria | Exit criteria | Validation method |
|-------|---------------|---------------|-------------------|
| `epic-init` | Driver provided a Jira epic id (or a brief for a not-yet-filed epic). | Epic umbrella scaffolded at `docs/en/design/epics/<jira-id>-<slug>/` with `epic.md`, `state.yaml`, `research.md` (empty until research runs), `design-overview.md` (empty until design runs), `stories.md` (empty until research decomposition), `dependencies.md`, `post-release-log.md` (empty). | Schema validation of epic `state.yaml`; `/feature:epic-status` returns a coherent summary. |
| `epic-research` (optional) | `epic-init` closed; `profile=full`. | `research.md` on the epic umbrella has per-repo findings, risks, unknowns, references; `stories.md` has a numbered story list; UI slice named or explicitly waived. | Reviewer checks every affected repo is mentioned; story list covers the brief without overlap. |
| `epic-design-review` (optional) | Epic research closed. | `design-review.md` on the epic umbrella records `approved`, `pivot`, or `rework` of the overall approach + story list. | Gate check; for risk=sensitive, a security-labeled reviewer signed. |
| `epic-close` | All stories marked p0 in `stories.md` have corresponding feature umbrellas in archive; no open post-release items flagged p0. | Epic umbrella moved to `docs/en/design/epics/archive/<jira-id>-<slug>/`; Jira epic transitioned to `Done`. | Every p0 story has a `shipped-features/<feature-jira-id>.link` entry; Jira API confirms transition. |

These criteria are advisory text in this TEP and enforced as code in the
respective `/feature:*` command implementations. Where a check is hard to
mechanize (e.g. "direction is right"), the command demands a reviewer
signature in the artifact rather than guessing.

### State Files: Epic and Feature

Every umbrella — epic or feature — carries a `state.yaml` as its
machine-readable heart. Commands read it at the start of every invocation,
mutate it in a single final write, and hash its contents so manual edits
can be detected. The two schemas share integrity fields but differ in
content (epics carry story lists and post-release logs; features carry
stage progression and bundle info).

A top-level `kind: epic | feature` discriminator lets commands pick the
right schema. Full schemas live in [Appendix E](#appendix-e--state-yaml-schemas).

#### Feature `state.yaml` (per shippable slice)

```yaml
kind: feature
schema_version: 3
feature:
  jira_id: DEVOPS-43245
  slug: custom-ca-certs
  title: "Centralised custom CA cert support for proxy and connectors"
  parent_epic: DEVOPS-41818     # null if the feature is standalone (no epic)
  profile: full                 # light | standard | full
  risk: sensitive               # low | standard | sensitive (inherited from epic if parent_epic set)
  repos: [connectors, connectors-operator]
  effort: weeks                 # advisory
  created_at: 2026-04-14T09:10:00Z
  driver: daniel
  previous_drivers: []
  paused: false
  profile_history: []
  shipped_at: null              # filled at /feature:ship; also when feature archives
stage:
  current: implement
  history:
    - stage: init
      primary_blocker: none
      closed_at: 2026-04-14T09:11:00Z
    - stage: design
      primary_blocker: template
      closed_at: 2026-04-14T09:40:00Z
story:                          # the one story this feature represents (inherited from the epic's stories[] if applicable)
  id: 1
  title: "Shared OAuth-app credential model"
  slice: backend
  priority: p0
  depends_on: []
story_groups:                   # per-repo OpenSpec changes linked to the single story this feature owns
  - story_id: 1
    review:
      reviewer: proxy-maintainer
      signed_at: 2026-04-14T11:00:00Z
    changes:
      - repo: connectors
        class: design-change
        path: openspec/changes/2026-04-14-oauth-credential-model
        pr: https://github.com/org/connectors/pull/412
        pr_state: merged
      - repo: connectors-operator
        class: mechanical-followup
        parent_change: openspec/changes/2026-04-14-oauth-credential-model
        path: openspec/changes/2026-04-14-oauth-credential-model-sync
        pr: null
        pr_state: draft
bundle:
  synced_manifests: []
  bundle_image: null
  bundle_tag: null
qa: { packet_path: null, owner: null, assigned_at: null }
acceptance: { status: pending }
regression: { status: pending }
maturity:
  entries: []                   # see Appendix G
  category_totals: { none: 0, template: 0, skill: 0, kb: 0, judgment: 0, flake: 0 }
security:
  threat_model_path: null
  signoff_path: null
  override: null
collisions: []
integrity:
  last_hash: "sha256:..."
  last_written_by: /feature:design
  last_written_at: 2026-04-14T09:40:00Z
  repairs: []
```

A standalone feature (no parent epic) can embed its own multi-story
decomposition by adding `stories[]` / `dependencies` directly on the
feature state. Most features branched from an epic have a single story
and use the `story:` object above.

#### Epic `state.yaml` (long-lived, multi-release)

```yaml
kind: epic
schema_version: 3
epic:
  jira_id: DEVOPS-41818
  slug: oauth2-app-auth
  title: "oAuth2 App support for Authentication"
  profile: full
  risk: sensitive
  repos: [connectors, connectors-extensions, connectors-operator, connectors-plugin]
  created_at: 2026-03-15T10:00:00Z
  driver: daniel
  previous_drivers: []
epic_stage:
  current: in-flight            # init | in-flight | closing | archived
  history:
    - stage: epic-init
      closed_at: 2026-03-15T10:30:00Z
    - stage: epic-research
      closed_at: 2026-04-05T14:00:00Z
    - stage: epic-design-review
      outcome: approved
      closed_at: 2026-04-06T11:00:00Z
stories:
  - id: 1
    title: "Shared OAuth-app credential model"
    slice: backend
    priority: p0
    repos: [connectors, connectors-extensions]
    depends_on: []
    state: shipped              # not-started | in-flight | shipped | cancelled | deferred
    shipped_in_release: "2026.05"
    feature_jira_id: DEVOPS-43245
  - id: 2
    title: "GitHub App token issuance"
    slice: backend
    priority: p0
    repos: [connectors, connectors-extensions]
    depends_on: [1]
    state: in-flight
    feature_jira_id: DEVOPS-43246
  # ...
dependencies:                   # story-level edges
  - from: 1
    to: 2
  - from: 1
    to: 4
  # ...
shipped_features:
  - feature_jira_id: DEVOPS-43245
    story_id: 1
    archived_path: docs/en/design/archive/DEVOPS-43245-oauth-credential-model/
    shipped_at: 2026-04-20T16:00:00Z
    shipped_in_release: "2026.05"
post_release_log:
  - entry_at: 2026-05-18T09:00:00Z
    jira_id: DEVOPS-41999
    severity: high
    related_story: 5
    disposition: new-story-added
    new_story_id: 10
    notes: "callback allowlist regex fails on self-hosted GHE hostnames"
security:
  threat_model_path: threat-model.md
  signoff_path: null            # per-feature signoffs live on feature umbrellas
collisions: []
integrity:
  last_hash: "sha256:..."
  last_written_by: /feature:bug-link
  last_written_at: 2026-05-19T10:00:00Z
  repairs: []
```

### Design Stage: Goal First, Breakdown for Validation

The primary output of `/feature:design` is a clear statement of the
**goal**: what problem the feature solves, who it solves it for, what the
desired end state looks like, and what is explicitly out of scope. The goal
is the contract the feature is held to at every later gate (design-review,
accept, ship). Without a sharp goal, every downstream artifact drifts.

For `profile=light` and `profile=standard`, the design document includes a
`## Context` section at the top that replaces what would otherwise be a
standalone `research.md`. This collapse eliminates the ceremony of a two-stage
design process for smaller features without losing the information. For
`profile=full`, research remains a separate stage because the mandatory story
decomposition is load-bearing for the design-review gate.

The **task breakdown** that accompanies the goal is a secondary output but
required. Its purpose is not to drive implementation (`/feature:plan` does
that), but to give the driver and the design reviewer a tool to verify three
things before any code is written:

1. **Coverage** — does the breakdown cover everything the goal implies? If
   the goal is "users can configure a Bitbucket connector through the UI"
   and the breakdown lists only backend tasks, the UI slice is missing.
2. **Direction** — does each task move toward the goal, not adjacent to it?
   A reviewer skimming the breakdown should be able to see "yes, this is
   the right shape" or "no, you're rebuilding X when you should be
   reusing Y."
3. **Completeness boundary** — is anything in the breakdown not actually
   needed for the goal? Scope creep is easier to catch in a numbered list
   than in prose design text.

The breakdown lives at the bottom of `tech-design.md` under a `## Task
Breakdown` heading. Each entry has:

- A one-line task name.
- The **story** it belongs to (when the feature was decomposed in research;
  otherwise `default`).
- The **slice** label: `backend`, `ui`, `infra`, `docs`, `test`, `ops`.
- The target **repo**.
- A one-sentence rationale tying the task back to the goal.

The breakdown is *not* `tasks.md`. `tasks.md` lives inside each per-repo
OpenSpec change and tracks executable steps. The design-stage breakdown is
the design-time map that proves the goal is fully covered by the OpenSpec
changes the plan stage will create.

For `profile=light`, the breakdown collapses to a single line
("touch X to fix Y; no UI; no doc"). For `profile=full`, the breakdown is
grouped by story.

#### Test Design

The design stage also produces the **test design**. Test design is not a
QA stage activity; QA *executes* the test design produced here. Doing it
in design ensures we know how we will know the feature works *before* we
write the code, and gives the design reviewer a chance to push back if
the test plan is weak.

Test design lives at the bottom of `tech-design.md` under a `## Test
Design` heading and includes:

- **Test methods** — for each task or story, which level of test is
  appropriate: unit, integration (Ginkgo suites in the repo),
  end-to-end (the integration tests under
  `connectors-operator/test/integration`), manual UI verification.
- **Specific test cases** — a numbered list of cases. Each case names a
  scenario, the input, the expected outcome, and the test method. These
  become the BDD scenarios that `/feature:plan` writes into the per-repo
  OpenSpec changes' `tasks.md`.
- **E2E case decision** — an explicit yes/no on whether this feature
  needs new e2e cases in `connectors-operator/test/integration`. If yes,
  list them; if no, record the reason (e.g. "covered by existing
  ConnectorsGit e2e suite"). Defaulting to "no e2e" without an explicit
  reason is rejected at design-review.
- **Living document** — if implementation forces a test-design change
  (a case becomes infeasible to test at the planned level, a trade-off
  reduces what can be asserted), the implementer updates this section in
  the same PR that introduces the change. The QA stage refuses to run
  if the test design has been edited but not re-approved by the design
  reviewer (a one-line `re-approved: <name>, <date>` entry suffices for
  small updates; non-trivial changes loop back to a fast design-review).

#### UI Prototypes

Any feature with a story tagged `slice=ui` must include a UI prototype in
**drawio format** (`ui-prototype.drawio`) committed alongside
`product-design.md`. The prototype shows: the screens involved, the form
shape (fields, validation, primary CTA), the navigation, and any state
transitions. Drawio is the chosen format because it lives in git and
diffs reviewably in PRs (we don't depend on a SaaS prototyping tool).

Prototype quality bar: a frontend developer who has never touched the
feature should be able to produce the first UI PR from the prototype
without asking questions about layout or fields. If they have to ask,
the prototype isn't done.

For `profile=light` features that touch UI, the prototype can be a
single screen drawio (no navigation). For `profile=full` features, the
prototype covers every screen the user lands on.

The frontend lead is the prototype reviewer at `/feature:design-review`
and signs the prototype explicitly. Without a signed prototype, the gate
cannot close `approved` for a feature with a UI slice.

### Story Decomposition in Research

When `/feature:research` runs under `profile=full`, decomposition is
mandatory: the research output must enumerate sub-stories rather than
treating the feature as a single shippable unit. This forces the team to
confront scope before design and to surface UI work as a peer slice rather
than an after-thought.

Decomposition rules:

- A story is the smallest slice that can be designed, implemented,
  reviewed, and shipped on its own. It does not have to ship alone, but it
  must *be able to*. If a candidate story cannot be cut without breaking
  another, it is not a story; it is a task inside another story.
- Every story has: id (numeric within the feature), title, slice
  (`backend`, `ui`, `infra`, `docs`), affected repos, priority (`p0`,
  `p1`, `p2`), explicit dependencies on other stories.
- UI work is always a candidate story when the feature touches a CRD field,
  a connector configuration, or any user-facing surface. The
  `/feature:research` command refuses to close without either a UI story or
  an explicit "no UI needed because…" entry.
- Priority semantics: `p0` stories must ship in this feature; `p1` stories
  should ship in this feature but can defer with reviewer agreement; `p2`
  stories are flagged for follow-up features and produce a Jira link in
  `research.md` instead of an OpenSpec change.

The decomposition output lives under a `## Stories` heading in
`research.md`:

```markdown
## Stories

1. **Backend: Bitbucket connector type** (p0, slice=backend,
   repos=[connectors-extensions, connectors, connectors-operator])
   Implement the Bitbucket connector class and its proxy registration.
   Depends on: none.

2. **UI: Bitbucket connector card and configuration form** (p0, slice=ui,
   repos=[connectors-plugin])
   Add the Bitbucket card to the connector picker and a configuration form
   matching the new CRD fields. Depends on: 1 (CRD shape).

3. **Docs: Bitbucket connector user guide** (p1, slice=docs,
   repos=[connectors-operator])
   New page under docs/en/connectors/. Depends on: 1 + 2.
```

`/feature:plan` uses this list to create one **story group** per story,
with per-repo OpenSpec changes linked inside it. Per-story review happens
at the story-group level, not at the per-repo-per-story level.
`/feature:tracks` groups its board by story so the driver can see UI and
backend slices as separate columns.

For `profile=standard`, decomposition is inline in `/feature:design`'s
task breakdown when it applies; no separate Stories section is enforced.
For `profile=light`, decomposition does not run — the feature is assumed
to be a single slice.

### Story as Unit, Repos as Fan-Out

Two observations drove the story-group model. First, the four-repo split
means even a single logical slice frequently fans out to multiple PRs: a
connectors controller annotation change almost always needs a
`connectors-operator` sync-install-manifests PR to land. Second, treating
that fan-out as "two stories" or "two independent OpenSpec changes
requiring independent design" multiplies review load without adding
decision-making.

**Story group = one story + N per-repo OpenSpec changes linked to it.**

`/feature:plan` produces a story group per story. Inside the group, every
per-repo change is classed:

- **`design-change`** — full OpenSpec pre-apply cycle
  (`proposal → specs → design → tasks → bdd-design`). An independent
  design decision lives here; it needs review. By convention, each story
  has at most one or two design-changes (backend + UI, say); more is a
  signal that the story should split.
- **`mechanical-followup`** — only `tasks.md` + PR. Content is fully
  determined by the parent design-change; no independent design or BDD
  work is warranted. Inherits review from the parent. Typical examples:
  sync-install-manifests in `connectors-operator` after a connectors API
  change; docs pages whose content is fully specified in the parent's
  `product-design.md`; integration-test scaffolding whose scenarios are
  derived verbatim from the parent's test design.

Per-story review signs the whole group: one reviewer per story (typically
the domain owner of the story's slice), not one per `(repo × story)`. If
a reviewer flags a cross-repo concern the decision propagates to a
per-repo review inside the affected repo, but the default is one
signature per story group.

Change classification is set at plan and can change at implement: if
during implementation a mechanical-followup turns out to need real
design work, the driver runs `/feature:plan --reclass=design-change
<change-id>`, which re-opens the pre-apply phases for that change.

#### Cross-Repo Splits and PR Consolidations

Two recording conventions cover the cases where the openspec change folder
and the actual PR drift apart at implement time:

- **`implementation_repo`** — set on a change entry when the implementation
  PR lands in a different repo than the openspec-change folder. The change
  was scaffolded under the parent design-change's repo (typical for
  mechanical-followups whose docs/wiring would naturally sit next to their
  parent's `proposal.md`), but the actual content ships from the consuming
  repo. `repo` continues to point at the change folder; `implementation_repo`
  points at the PR's repo. `/feature:integrate`, `/feature:tracks`, and the
  ship-time manifest sync read `implementation_repo` when present and fall
  back to `repo` otherwise.

- **`consolidated_from`** — set on a change entry when a stacked PR was
  rebased into its parent because PaC CEL, branch-protection, or review-surface
  rules made the split untenable. The current `pr` field points at the
  surviving (parent) PR; `consolidated_from` records the URL of the
  collapsed PR for traceability. The collapsed PR is expected to be
  `closed` or `merged` with no independent content.

Both fields are optional and additive: a routine same-repo, single-PR
change uses neither. They are recorded explicitly so the integrity hash
captures the divergence and reviewers see, at a glance, that the planning
shape no longer matches the merge shape.

### Story Mutation Mid-Flight

Stories written at research or design rarely survive implementation
unchanged. A backend story may turn out to be two stories once the code
starts; a UI story may split by platform; two stories may collapse into
one when the code shape clarifies. The workflow makes these mutations
first-class instead of pretending the initial decomposition was final.

`/feature:story` subcommands:

- **`--add <title> --slice=<s> --repos=<r> [--priority=<p>] [--depends-on=<ids>]`**
  Append a new story to the list. Runs a fast design-review on the new
  story before plan can pick it up.
- **`--split <id>`** — split an existing story. The driver is prompted
  for the new titles, slices, and dependency edges; the original story
  is marked `split-into: [<new-ids>]` in `state.yaml.stories` and its
  story group dissolves into new groups.
- **`--merge <a> <b>`** — merge two stories into one. Requires that both
  stories have the same slice and at least one shared repo; merges their
  dependency edges.
- **`--defer <id> [--jira=<new-epic>]`** — move a story out of this
  feature and into a follow-up (either an existing Jira or a new one).
  The deferred story is archived inside the current feature's umbrella
  with a back-link.

Each mutation:

- Records a history entry in `state.yaml.stories[].history`.
- For substantial mutations (new slice, new repo, or a split producing
  stories with different reviewers), re-runs a fast `/feature:design-review`
  on the affected story or stories only. Not a full feature-level review.
- Is classified as a `design-iteration` maturity entry (excluded from
  the maturity metric — mutation during build is expected).

Mutations at stages past `implement` are allowed but discouraged: the
system records a warning because the cost of re-planning merged PRs
escalates. `/feature:story --split` at `qa` stage requires an explicit
`--confirm-late-mutation=...` reason.

### Cross-Repo Dependency Graph

`dependencies.md` in the umbrella captures story-level dependencies as a
simple edge list:

```text
# dependencies.md
1 -> 2    # credential model blocks GitHub token issuance
1 -> 4    # credential model blocks CRD extensions
4 -> 6    # CRD shape blocks UI form
```

The graph is authored during `/feature:design` (initial edges from the
task breakdown's implied dependencies), validated at
`/feature:design-review`, and refined at `/feature:plan` (once per-repo
change paths exist).

`/feature:implement` reads the graph and:

- Dispatches stories with no unmet dependencies first.
- Holds downstream stories as `draft` PRs with a tracking comment naming
  the blocker story ids.
- On each blocker merge, auto-rebases and re-dispatches downstream
  stories without human intervention.

`/feature:tracks` renders the graph as a story board with dependency
arrows. Mechanical-followups appear as sub-nodes beneath their parent
design-change rather than as independent columns, matching how the
driver actually thinks about them.

Cycle detection happens at `/feature:design-review`: if the graph
contains a cycle the gate cannot close `approved`. Cyclic dependencies
almost always indicate that two stories should merge or one should
split.

### Design-Review Gate Semantics

`/feature:design-review` is a gate, not a pass-through. Its output has three
shapes:

- **approved** — design artifacts accepted; stage advances to `plan`.
- **pivot** — a significant direction change is required. The command writes
  `design-review.md` with the proposed pivot, updates `state.yaml.stage.current`
  back to `design`, and records a `loop_count` so metrics can measure how
  often designs loop. The driver runs `/feature:design` again.
- **rework** — minor changes requested. Same loop-back as `pivot`, but
  `design-review.md` records it as a smaller correction. Used when the team
  agrees the direction is right but details need adjustment.

For features with `risk=sensitive`, the gate additionally requires that one
of the reviewers in `design-review.md` is labeled as a security reviewer (a
configurable codeowners-style group; see [Appendix A](#appendix-a---risk-trigger-checklist)).
Without that signature, the gate cannot be closed as `approved`.

Loop-backs from this gate do not count against the feature's maturity
metrics; design iterations are the workflow operating as intended. They are
recorded for visibility but scored as expected.

On the **second consecutive `pivot`** outcome on the same feature, the
command offers `/feature:poc` before the next design attempt. Two pivots
in a row is a signal the team does not yet have enough information to
settle the design — a spike is cheaper than a third design pass.

### Optional POC Stage

`/feature:poc` is an opt-in stage between `design-review` and `plan`.
Offered automatically after two consecutive pivots at `design-review`;
the driver can also invoke it explicitly at any point between
`design-review` and `plan`.

The POC is a **throwaway branch** targeting the narrowest possible
hypothesis that blocked the design. For example: "can the operator
webhook actually validate the `secretRef` shape at admission without
reading the secret," or "can the proxy cache installation tokens with
the TTL the design assumes." The branch is not intended to merge.

`poc.md` records:

- **Hypothesis** — one sentence, testable.
- **Branch** — URL of the throwaway branch in the affected repo.
- **Result** — `validated` / `invalidated` / `inconclusive`.
- **Design impact** — which sections of `tech-design.md` (or
  `product-design.md`) change as a result. These changes are made in
  the next `/feature:design` pass, not inside the POC.
- **Learnings** — any observation worth keeping that did not feed a
  specific design change (performance surprise, API quirk, platform
  constraint).

After `/feature:poc` closes, the driver re-runs `/feature:design` (not
`/feature:research` — the scope has not changed, only the depth of
understanding has). The POC `## Context` is folded into the updated
design document.

Poc loop-backs are not scored against maturity metrics — a POC is the
workflow operating as intended when the design cannot settle from desk
research alone.

### Accept and Docs Parallel Fork

After `/feature:qa` closes, two independent commands can progress in either
order:

- `/feature:accept` runs acceptance against the bundle; writes `acceptance.md`.
- `/feature:docs` drafts user-facing documentation changes and the release-note
  entry in this repo; writes `release-notes.md` and `docs-changes.md`.

`state.yaml.stage.current` during this phase reads `accept|docs`. `/feature:status`
shows both sub-stages; `/feature:regress` refuses to start until both are
`passed`/`complete`. Either command can be run first; they do not share state.

The rationale for parallelism: docs authoring and acceptance testing have no
data dependency on each other, and the team historically does them in parallel
already. Forcing a serial order would slow real work without adding safety.

### Cross-Repo Drill-Down

`/feature:implement` is the one stage where parallel per-repo work happens by
default. The coordinator dispatches one sub-agent per affected repo, each
running `/opsx:apply` against that repo's OpenSpec change. Sub-agents run in
parallel and report back with PR URLs and apply outcomes.

For drivers who want finer control:

- `/feature:tracks` prints a board: repo, OpenSpec change path, PR URL, PR
  state, BDD state, last sub-agent outcome.
- `/feature:dispatch <repo>` runs only one repo's next implementation step,
  leaving the others untouched. Useful when one repo is blocked on an external
  review and the driver wants to make progress elsewhere.

These commands are undocumented in the primary surface. `/feature:status`
surfaces them in its output only when `feature.repos` has more than one entry.
Single-repo features never learn they exist.

### Cross-Feature Conflict Detection

Two features touching the same connector type, the same plugin module, or
the same shared file area collide silently in the current workflow: the
problem only surfaces at merge time, when one feature's PR forces a rebase
of the other, or at bundle time, when the auto-sync pipeline interleaves
manifests from both. By then the cost to disentangle is high.

Detection runs at three points:

1. **`/feature:init`** — automatically. After the umbrella is scaffolded but
   before `init` closes, the command walks `docs/en/design/` (excluding
   `archive/`) and reads each `state.yaml`. It compares the new feature's
   `feature.repos`, declared connector types (parsed from the brief or
   passed as `--connector=<type>`), and any explicit `--touches=<path-glob>`
   hints against in-flight features. Matches are written into
   `state.yaml.collisions` and printed.

2. **`/feature:plan`** — repeats the check with sharper signal: the
   per-repo OpenSpec change paths now exist, so file-level overlap can be
   detected by walking the planned task lists. Any new collisions are
   appended.

3. **`/feature:conflicts`** — the driver can re-run the check at any time,
   for example after a colliding feature ships and the umbrella moves to
   `archive/`.

Collision policy:

- A collision flagged at `init` does not block — it informs. The driver
  must explicitly acknowledge each collision (via
  `/feature:init --acknowledge=<feature-id>`) before `init` will close.
  The acknowledgement is recorded with timestamp and driver name.
- A collision flagged at `plan` blocks `/feature:implement` until the
  driver records a sequencing decision in `state.yaml.collisions[].plan`:
  one of `wait-for=<feature-id>`, `merge-with=<feature-id>`, or
  `independent` (with rationale).
- For `merge-with`, the two features share a single set of OpenSpec
  changes; the workflow tracks both umbrellas pointing at the same
  changes, and `/feature:ship` on either feature ships both.

Detection signals (in order of strength):

- Same repo + same OpenSpec change path → guaranteed conflict.
- Same repo + same connector type folder
  (e.g. both touch `connectors-extensions/connectors-git/`) → high.
- Same repo + overlapping `--touches` glob → medium.
- Same repo only → low (informational).

The detector errs on the side of false positives at `init` (cheap to
acknowledge) and false negatives at `plan` (expensive to acknowledge
incorrectly).

### Driver Handoff and Pause

A feature can outlive the present moment for two different reasons: the
current driver needs to step off temporarily (vacation, higher-priority
interrupt, waiting on an external decision) or ownership needs to change
hands (leave, reassignment, reviewer taking over). The workflow treats
these as two separate operations.

#### Pause — freeze work, keep the driver

`/feature:pause [--reason=...]` freezes the feature in place:

1. Sets `state.yaml.feature.paused = true` with a timestamp and the
   reason.
2. Does **not** cancel sub-agents. Draft PRs stay open. Each draft PR
   gets a banner comment: "feature `<slug>` paused at `<date>` by
   `<driver>` — resume via `/feature:resume`."
3. Adds a comment to the Jira ticket noting the pause and linking the
   umbrella.
4. Refuses to run any stage command other than `/feature:resume`,
   `/feature:status`, `/feature:handoff`, or `/feature:cancel` while
   paused.

`/feature:resume` reverses the pause:

1. Sets `paused = false`.
2. Updates each affected PR's banner comment to note the resume.
3. Prints the next command in the lifecycle, the same way
   `/feature:next` would.

Pause is the right command for "I'm stepping off for a week." Nothing in
flight needs to be rebuilt when the driver returns; draft PRs, BDD
scenarios in progress, and review threads on sub-agent-generated content
remain exactly where they were.

#### Handoff — transfer ownership

`/feature:handoff <new-driver> [--note=...] [--reset]` transfers the
driver role without freezing the work:

1. Updates `state.yaml.feature.driver` and appends the previous driver
   to `state.yaml.feature.previous_drivers[]` with a timestamp.
2. Writes (or updates) `handoff.md` in the umbrella with: current stage,
   blockers, open questions for the new driver, decisions deferred and
   why, in-flight sub-agent state (PR URLs awaiting review, BDD
   scenarios in progress), and the optional free-text note.
3. **Does not cancel sub-agents by default.** The new driver inherits
   in-flight draft PRs as-is and can decide per PR whether to continue
   or restart them. Passing `--reset` cancels all in-flight dispatches
   and records them as `interrupted` (excluded from maturity metrics);
   use this only when the new driver explicitly wants a clean slate.
4. Adds a comment to the Jira ticket noting the reassignment and
   linking the umbrella.
5. Prints the new driver's first command: `/feature:status`.

`/feature:status` is designed so that running it cold, after a handoff,
produces the same actionable summary as it does for the original driver:
current stage, exact next command, open blockers, the handoff note, and
the story-grouped PR board when applicable. The new driver does not
need to read any of the design or research documents to decide what to
do next; they read those when the next stage actually requires them.

#### Pause + handoff compose

A paused feature can be handed off (new driver inherits the paused
state and resumes later). An active feature can be handed off without
pausing (new driver takes over mid-flight, with in-flight sub-agents
intact). This matches the real-world workflow: handoff is about who is
responsible, pause is about whether work is currently happening.

The TEP intentionally does not support concurrent drivers. If two
people are working on the same feature, one is the driver and the
other is a contributor whose work flows through the driver's
`/feature:*` commands. Multi-driver coordination is a Jira problem,
not a workflow problem.

### Post-Release Feedback

A feature umbrella archives at ship. The *epic* umbrella — when one
exists — is the long-lived container for everything that happens after
a release publishes: customer bugs, tech debt surfaced in later work,
new stories pulled in from the field.

An earlier revision of this TEP tried to solve post-release feedback by
keeping the feature umbrella open for a 14-day "landed window" and
spawning child "hotfix" features from it. That approach assumed
customers would touch a feature the week it shipped. In our release
reality — monthly non-LTS cadence, quarterly LTS — production feedback
typically lands weeks or months after release, long after any
reasonably-sized landed window has closed. The workflow now solves the
same problem at a higher level of granularity: the epic umbrella stays
open, and post-release events attach to it.

#### The three post-release paths

**Path A — a customer bug is filed after a release.**

The driver (or whoever triages) runs:

```
/feature:bug-link <bug-jira-id> --epic=<epic-jira-id> [--related-story=<id>]
```

The command:

- Appends an entry to the epic umbrella's `post-release-log.md` with
  severity, affected release, related story (if known), and a
  placeholder disposition.
- Adds a Jira comment on the bug linking the epic umbrella path.
- Refuses if the named epic umbrella is already archived — the epic
  must be re-opened (via `/feature:epic-close --reopen --reason=...`)
  before `bug-link` accepts new entries, or the bug is genuinely not
  related to this epic.

The driver then chooses a disposition:

- **fix-next-release** — add a new story to the epic via
  `/feature:story --add --priority=p0`, then
  `/feature:story-start <id>` when it's time to implement. The fix
  runs through the normal feature pipeline and ships in the next
  release train.
- **fold-into-inflight-story** — an in-flight feature umbrella already
  covers the affected area; add the bug's fix to that feature's scope
  via `/feature:story --expand <id>` (recorded on the epic
  `post-release-log.md`).
- **defer** — document the workaround; schedule for a later release.
  The bug stays linked to the epic but doesn't become a story yet.
- **accept** — the team decides not to fix; record the acceptance
  rationale.

All four dispositions update the `post-release-log.md` entry.

**Path B — tech debt surfaces during implementation.**

While working on story N, the team discovers a gap (missing cache, a
refactor that would help future stories, etc.). The driver runs:

```
/feature:story --add "<title>" --slice=backend --priority=p1 --defer
```

The command appends the new story to the epic's `stories.md` with
`state: deferred`. The deferred story is picked up in a later release
via `/feature:story-start <id>` when capacity allows. If the tech debt
must be paid before other p0 stories can ship, the driver sets
`--priority=p0` (no `--defer`) and the dependency graph is updated.

**Path C — a new story emerges after discussion with stakeholders.**

Between releases, new requirements surface (a customer asks for an
adjacent capability, a product manager adds scope). The driver runs
`/feature:story --add` on the epic and the story enters the normal
flow.

#### What the feature umbrella does NOT do post-ship

The feature umbrella archives at `/feature:ship` and is **not**
re-opened for post-release work. This is deliberate:

- Re-opening an archived umbrella means re-signing its state hash and
  re-running commands against stale artifacts; every such re-open is
  a subtle source of state drift.
- The fix for a post-release bug is almost always a new story, which
  deserves its own feature umbrella (its own design, its own QA, its
  own retrospective).
- A one-line hotfix is still a feature umbrella with `profile=light`
  that runs the full pipeline.

#### Features without a parent epic

A standalone feature (no `/feature:epic-init` was run) has no epic
umbrella to absorb post-release feedback. Two options:

1. **Create an epic retroactively.** If post-release bugs keep
   arriving, run `/feature:epic-init <jira-id>` with the epic's Jira
   id, and back-fill stories (the shipped feature becomes a
   `shipped_features[]` entry with state `shipped`). Bugs then attach
   via `/feature:bug-link`.
2. **Handle bugs as independent features.** Each bug becomes its own
   standalone `/feature:init` feature. This is fine for sparse
   feedback but gets noisy if the same feature generates several
   bugs over time.

The workflow recommends creating the epic at `init` time whenever the
team suspects the work will generate post-release feedback (which is
almost every user-facing feature).

#### Post-release bug rate

`/feature:metrics` reports a **post-release bug rate** across the last
90 days, computed from `post-release-log.md` entries on active and
archived epic umbrellas. This is a product-quality signal distinct
from workflow maturity — a rising bug rate says the shipped code is
less reliable, not that the AI is less helpful.

### State Repair

`state.yaml` integrity is enforced by a checksum written after every
command. Manual edits to `state.yaml` are detected at the next command
invocation, which refuses to proceed. This is correct for maturity
metrics integrity — drivers should not be able to silently edit
"driver-rework" into "auto-complete."

But `state.yaml` can become genuinely wrong for reasons that are not
malicious: a bug in an earlier command wrote an inconsistent entry; a
crash mid-write left a partial value; a merge conflict was resolved
badly. The TEP sanctions exactly one recovery path:

`/feature:state-repair --audit-reason="..."`

The command:

1. Reads the current `state.yaml`, computes a new checksum, writes it
   with no semantic changes (i.e. it does not ask what to fix — the
   driver is expected to edit the file, then invoke this command to
   re-sign it).
2. Appends an entry to `state.yaml.integrity.repairs[]` with the audit
   reason, timestamp, and the driver's identity.
3. Marks the feature as `maturity_excluded: true` for the current
   maturity entry, so the repaired stage is not scored.
4. Adds a comment to the Jira ticket noting the repair and the audit
   reason (so reviewers can see it).

The `--audit-reason` is required. Vague reasons (`fix`, `typo`, `bug`)
are rejected; a useful audit reason names what was wrong and how the
driver believes it got there. Reasons appear verbatim in
`/feature:metrics` so patterns of repair surface over time — a rising
repair rate is itself a workflow-health signal.

`/feature:state-repair` is not a routine command. If a driver finds
themselves invoking it more than once per feature, that is a bug in an
earlier command and should be reported; the repair is the short-term
fix, the command fix is the long-term one.

### Retrospective

`/feature:retro` runs **before** `/feature:ship` while the feature
umbrella is still active. It is required for `standard` and `full`
profiles and **opt-out** for `light` with a single-word reason.

For `standard` and `full`, the command produces `retrospective.md` with
three required sections:

```markdown
# Retrospective — <feature title>

## Worked
- (entries) — what went well and should be repeated.

## Didn't work
- (entries) — what went poorly. Be specific: which stage, what artifact,
  what symptom.

## Change
- (entries) — what to do differently next time. Each entry tagged with one of
  `template`, `tooling`, `process`, `scope`. Entries with `template` or
  `tooling` tags become candidate improvements to this TEP or the command
  implementations.
```

Post-release bugs that arrive **after** this feature's retrospective
is written (the common case) are recorded on the parent epic's
`post-release-log.md` via `/feature:bug-link`. They do not retroactively
modify this feature's retrospective; instead, whichever future feature
fixes the bug writes its own `Didn't work` entry for the class of
defect (e.g. "OAuth callback regex did not cover self-hosted
hostnames"). Linking bugs back to the originating feature is done
through the epic's `shipped_features[]` + `post_release_log[]` entries,
not by re-opening this feature's retro.

After writing, the command appends each `Change` entry as a row in
`docs/en/design/improvement-log.md`. The improvement log is the team's
backlog of workflow improvements; entries are picked up in regular
maintenance work and removed from the log when implemented (with a link to
the implementing PR).

`/feature:metrics` reads the improvement log and reports:

- Open improvement count (and how long each has been open).
- Improvements implemented in the last N features.
- Most common `Change` tags across the last 30 days, so the team can see
  whether interventions cluster around templates, tooling, or process.

The retrospective is intentionally separated from the maturity report.
The maturity report is mechanical (blocker counts per category). The
retrospective is judgment (what we should change). They are different
artifacts because they serve different audiences: the maturity report
goes to anyone tracking workflow maturity progress; the retrospective
goes to anyone maintaining the workflow itself.

For `profile=light`, the retrospective is **opt-out** via
`/feature:retro --opt-out=<reason>`. Recognised reasons are:

- `trivial` — a one-line fix with nothing surprising to record.
- `dup-of=<feature-id>` — this feature's learnings are already captured
  in another recent feature's retro.
- `sweep` — part of a routine maintenance sweep (dependency bump, lint
  pass, etc.) with no feature-specific learning.

Opt-out records a row in `improvement-log.md` only if the feature's
maturity report exposed a blocker category that has not yet been
addressed by any open improvement-log entry. This keeps the signal high:
we opt out of noise, not of signal.

If a light feature wants to record a retro anyway, `/feature:retro` with
no arguments still works and produces the three-line short form:

```markdown
# Retrospective — <feature title>

- Worked: <one line>
- Didn't work: <one line, can be "n/a">
- Change: <one line, can be "none">
```

Even one-line retros feed the improvement log if their `Change` line is
non-empty.

### WIP and Capacity Signals

Cross-feature collision detection catches *spatial* collisions — two
features touching the same area. It does not catch *temporal* or
*capacity* collisions — one driver running too many features at once,
or a team starting features faster than it finishes them. Those are
productivity problems, not correctness problems, and the workflow
offers layered signals (not a hard block) so teams can choose the
friction they want.

**Driver-level soft signal.** `/feature:status` prints a header line
showing how many features the current driver is on and how many are
paused:

```
Driver daniel — in-flight: 3 (1 paused) — effort total: ~6 weeks
```

`/feature:init` emits a warning when the driver is already on ≥3
in-flight features (default threshold; configurable per team). The
warning does not block; it is informational.

**Effort tag at init.** `/feature:init --effort=days|weeks|months`
attaches a free-text effort tag to the umbrella. The tag is not
measured or gated — it is a signal for `/feature:status` and
`/feature:metrics` so that "driver is on 3 features totalling
~4 weeks of effort" is more actionable than "driver is on 3 features."

**Team-level cap, off by default.** A team can set a team-wide WIP
cap in the config file. When set, `/feature:init` refuses to scaffold
a new feature when the team's current in-flight count exceeds the cap
unless `--force` is passed with a reason. `--force` invocations are
logged to the improvement log so patterns of override are visible.

**`/feature:metrics` aggregates WIP distribution** across drivers for
the last 90 days. Visible inequity (one driver on 5+ features while
others are on 0) is almost always fixable with a conversation rather
than a policy; the data just has to be visible.

### Coordinator Dispatch Model

Every `/feature:*` command follows the same pattern:

1. Read `state.yaml`, verify integrity hash, verify stage is valid for the
   command.
2. Decide whether the stage is per-repo or umbrella-level.
   - If umbrella-level (most stages), execute in the operator repo context.
   - If per-repo (`implement` and optionally `research`), construct one
     sub-agent invocation per entry in `feature.repos`.
3. Dispatch sub-agents in parallel when multiple repos are affected. Each
   sub-agent receives: feature slug, umbrella path, target repo path, the
   specific skill to invoke (usually `/opsx:apply`), and a scoped prompt.
4. Collect results; aggregate into the umbrella artifact for this stage.
5. Update `state.yaml`: append a history entry, record automation metrics,
   rewrite integrity hash, commit.

Sub-agent prompts are generated from a small number of templates stored in
`.claude/commands/feature/prompts/`, so their behavior is reproducible and
auditable.

### Risk Gating and Security Review Overlay

Security review is not a fixed stage; it is an overlay activated by the
feature's `--risk` value. The overlay affects three places in the lifecycle.

**At `/feature:init`:**

The command runs a trigger-question checklist ([Appendix A](#appendix-a---risk-trigger-checklist)).
Any "yes" raises the risk level:

- Any material change → at least `standard`.
- Any trigger in the sensitive list → `sensitive`.

The driver can override the computed risk with `--risk=...`, but the override
and its justification are recorded in `state.yaml.security.override` and
surfaced at every subsequent gate.

**At `/feature:design` and `/feature:design-review`:**

- `risk=low`: no security artifacts required.
- `risk=standard`: a **Security considerations** section is added to
  `design-review.md` using the template in [Appendix B](#appendix-b-threat-modelmd-template).
- `risk=sensitive`: a standalone `threat-model.md` is scaffolded during
  `/feature:design` and must be approved by a security-labeled reviewer at
  `/feature:design-review` before the gate can close as `approved`.

**Before `/feature:ship` (only for `risk=sensitive`):**

A new stage, `/feature:security-sign-off`, is inserted. The command produces
`security-sign-off.md` using [Appendix C](#appendix-c-security-sign-offmd-template):
reviewer, bundle version, image digests reviewed, operator permissions
requested, new exposed endpoints, findings, decision (`approved` /
`rejected`). `/feature:ship` refuses to proceed without an `approved` result.

### Workflow Maturity Tracking

An earlier version of this TEP tracked a single "automation rate"
(percentage of stages completing without driver edits) against a 90%
target. We replaced that approach because a single number can't
distinguish three fundamentally different situations: (a) the AI is
weak at this kind of work, (b) the template / skill / KB gives the AI
no way to succeed, (c) the work is genuinely human judgment that the
AI was never going to produce on its own. Aggregating those into one
percentage hides the signal the team actually needs to act on, and
creates a target that warps behavior.

**What we measure instead: primary blocker per stage close.**

Each command, when it closes a stage, records a `primary_blocker`
classification on that stage's maturity entry. The classifications:

| Classification | Meaning |
|----------------|---------|
| `none` | The AI produced an acceptable artifact with no driver intervention. |
| `template` | The driver invented structure the template should have provided. |
| `skill` | The driver dropped out of `/feature:*` to a raw skill or manual step the workflow should have covered. |
| `kb` | The AI asked the driver for context that should have been retrievable from a knowledge base. |
| `judgment` | The stage inherently required human judgment (AC sign-off, residual-risk call, domain decision) that the AI was not expected to produce. Not a miss. |
| `flake` | CI / transient failure; retry succeeded. Not scored. |

Per-entry fields (summary; full schema in
[Appendix G](#appendix-g--maturity-tracking-schema)):

- `stage`, `command`, `primary_blocker`, `ai_turns`,
  `driver_edits.files_touched`, `driver_edits.lines_changed`,
  `custom_prompts`, `duration_min`, `closed_at`, `closed_by`,
  `notes` (optional one-liner that the driver can attach if the
  blocker category doesn't fully capture what happened).

Blocker determination is largely mechanical:

- `ai_turns == 1` and `lines_changed == 0` → `none`.
- `ai_turns >= 2` with explicit re-prompt asking for context → `kb`.
- Driver invoked a raw skill or manual command inside the stage → `skill`.
- Driver edits visible in git diff of the AI artifact beyond cosmetic
  changes → either `template` (if the edit fills in structure) or
  `judgment` (if the edit is a decision the AI couldn't have made). The
  distinction defaults to `template` and can be overridden by the
  driver with `--primary-blocker=judgment` when closing the stage.
- Stage was skipped with a recognized reason → not scored (excluded).
- Stage command exited with error and had to be retried (CI, transient) →
  `flake`.

Events explicitly excluded from maturity scoring (recorded but not scored):

- Design-review `pivot` / `rework` loops — expected iteration.
- `/feature:poc` loops — expected iteration.
- Story mutation via `/feature:story` — expected iteration.
- Stage closures on a feature that had a `/feature:state-repair`
  invocation — excluded for the feature's remaining stages to keep the
  data clean.
- QA finding a real bug and looping back to `implement` — this is a
  feature-quality signal (tracked separately as part of the post-ship
  hotfix rate), not a workflow-maturity signal.

#### Per-feature maturity report

`/feature:ship` writes `maturity-report.md` with:

```markdown
# Maturity Report — <feature title>

## Stage summary
Total stages run: 12
  none:      7
  template:  2
  skill:     0
  kb:        1
  judgment:  2 (expected)
  flake:     0

## Top intervention sources
1. (template) Story-list authoring in research — driver wrote 8 out of
   10 stories; AI drafted the other 2. Suggests research-template
   story-seed heuristics are weak for OAuth-flavoured features.
2. (kb) Design stage asked for existing proxy auth patterns — driver
   had to paste in three code snippets. Suggests missing KB entry for
   proxy auth.
3. (template) Threat-model template lacked an OAuth-flavoured example.

## Judgment-only stages (on-target)
- design-review: required security-labelled reviewer sign-off.
- accept: AC verdicts require reporter approval.
- security-sign-off: sensitive-feature gate.

## Excluded stages
- design (first pass): looped back via pivot (not scored).
- implement: state-repair invoked during dispatch (excluded).
```

The narrative is the highest-value output. The category totals tell the
team *where* to invest next (templates? skills? KB?); the narrative
tells the team *what specifically* to invest in.

#### Cross-feature metrics

`/feature:metrics` walks `docs/en/design/archive/` (shipped features),
`docs/en/design/` (in-flight features), and
`docs/en/design/epics/` (both active and archived epic umbrellas),
reads every `state.yaml`, and writes
`docs/en/design/maturity-metrics.md`:

- **Category trend** — per-category blocker count per feature over the
  last N features. A declining `template` trend means templates are
  improving; a rising `kb` trend means the knowledge base is not
  keeping up.
- **Top intervention sources** — the most frequently cited concrete
  intervention narratives, clustered by keyword.
- **Post-release bug rate** — bugs recorded via `/feature:bug-link` on
  epic umbrellas in the last 90 days, rolled up per epic and per
  severity. This is the product-quality signal, deliberately separate
  from workflow maturity: a rising bug rate says the shipped code is
  less reliable, not that the AI is less helpful.
- **WIP distribution** — in-flight feature counts per driver over the
  last 90 days.
- **State-repair rate** — how often `/feature:state-repair` has been
  invoked. Rising rate is a command-bug signal.

#### Maturity thresholds (replacing the 90% target)

- **Almost-autonomous bar** — mean count of
  `template + skill + kb` blockers per feature, rolling 30 days across
  all profile mixes, ≤ 2. Reaching this bar says "the tooling is no
  longer the bottleneck; the remaining interventions are judgment."
- **Autonomous bar** — same metric ≤ 0.5, AND every remaining
  judgment-only stage is **prompt-able** (the driver is answering a
  specific AI question with a short answer, not inventing artifacts).
  Reaching this bar is the signal to let the workflow run without a
  human driver for non-judgment stages.

Judgment-only interventions are the honest floor of human involvement
and are counted but not penalised. "100% auto-complete" is not the
goal; "we know exactly which interventions are inherent and which are
accidental" is.

Thresholds are advisory; crossing them is not an automatic trigger. The
team reviews the signal in a quarterly workflow-health check and
decides whether to flip the autonomous flag for a subset of stages.

### Jira Integration Points

The workflow touches Jira at the following points:

- **`/feature:init`** — fetches the story to populate `feature.md`
  (title, ACs, owner). Read-only. If the Jira API is unavailable, the driver
  can provide the details as a brief and the command continues.
- **`/feature:epic-init`** — fetches the Jira epic to populate `epic.md`.
  Adds a single comment announcing that the epic umbrella has been created.
- **`/feature:story-start`** — adds a comment to the story's Jira ticket
  linking the feature umbrella and the parent epic.
- **`/feature:plan`** — adds a comment to the feature's Jira ticket linking
  each per-story OpenSpec change group.
- **`/feature:pause`** and **`/feature:resume`** — add a comment noting the
  event and the current stage.
- **`/feature:handoff`** — adds a comment noting the reassignment and linking
  the umbrella.
- **`/feature:bug-link`** — adds a comment to the bug's Jira ticket linking
  the parent epic umbrella and the decided disposition.
- **`/feature:state-repair`** — adds a comment with the audit reason so
  reviewers can see repair events in the Jira history.
- **`/feature:ship`** — transitions the feature's Jira ticket to Done and
  attaches the `maturity-report.md` path.
- **`/feature:epic-close`** — transitions the Jira epic to Done after
  confirming all p0 stories have shipped.

All Jira writes are comments or state transitions — no Jira field editing,
no story mutation in Jira. This keeps the integration small enough to
replace with another issue tracker later without reshaping the workflow.

### Bundle Version Linking

`/feature:integrate` is the weakest-coupling stage: it observes the existing
Tekton `sync-install-manifests.yaml` pipeline rather than driving it. Its job
is to find the first bundle image tag produced by this repo that contains the
merged PRs from each affected repo, and record that tag in
`state.yaml.bundle.bundle_tag` along with the synced manifest versions and
operator bundle image digest.

Detection strategy:

1. Read merged PR commit SHAs from `state.yaml.opsspec_changes[].pr`.
2. For each, find the auto-sync PR in `connectors-operator` that picked up
   the resulting manifest changes.
3. Find the first bundle image build whose input includes all of those sync
   PRs.
4. Record the bundle tag and manifests in `state.yaml.bundle`.

If any step fails (for example, the sync PR hasn't landed yet), the command
records what it did find and prints the gap. The driver reruns the command
when the gap is closed; no retry loop is needed.

## Walkthrough

For a concrete, end-to-end example of the workflow against a real
in-flight epic (oAuth2 App support for Authentication — DEVOPS-41818),
see the companion document
[`docs/en/teps/assets/DEVOPS-41818-walkthrough.md`](assets/DEVOPS-41818-walkthrough.md).
The walkthrough shows what each stage produces when the source Jira has
a one-sentence goal and missing ACs, and how the workflow drives both
gaps to closure without the driver inventing process on the fly.

## Design Evaluation

### Reusability

The workflow is built on top of existing artifacts and commands: `/opsx:*` for
per-repo changes, `/workflow:*` for post-apply phases, the operator repo's
`design/` and `teps/` conventions for design artifacts, and the existing
Tekton pipelines for bundle builds. No existing mechanism is duplicated; the
new layer binds them together at the feature level.

### Simplicity

The driver's visible surface is small: ten stage commands, two drill-down
commands, three metrics/status commands. Each stage command has an obvious
purpose and exactly one primary artifact. `/feature:next` collapses the need
to remember stage names for drivers who prefer a single forward-only command.

For small single-repo features, the total command count the driver needs is
between three and six: `init`, `design` (possibly), `implement`, `accept`,
`ship`. Stages that have no work because the artifact is inapplicable are
closed with a one-word skip.

### Flexibility

Stages can be added or removed by amending this TEP and the command
implementations. Templates (risk checklist, threat model, QA packet, release
note) are runtime files that teams can edit without touching commands.

The coordinator's dispatch model accepts any repo as a target as long as the
per-repo skill (`/opsx:apply`) is present; adding a fourth repo in the future
requires no changes to this workflow.

Risk-level policy is localized to the overlay section. Teams can change which
triggers map to which level without reshaping the stage model.

### Conformance

The TEP does not introduce new Kubernetes resources or API changes. It adds
two things to this repo: new content under `docs/en/design/` (umbrellas,
templates, state schema, co-located with existing feature design folders)
and a new command directory `.claude/commands/feature/`.

### User Experience

The driver's experience is a linear pipeline. Every command prints, on
success, the next command to run. `/feature:status` is idempotent and cheap,
making "where am I" a sub-second answer.

The coordinator never asks "which skill should I use"; all such decisions are
made by reading the feature's stage and repos. The driver is expected to
provide business input (designs, AC review, acceptance decisions), not
plumbing decisions.

### Performance

Commands complete in the time of their underlying work. `/feature:research`
and `/feature:implement` are the longest because they dispatch real
sub-agents; others finish in seconds. `/feature:integrate` may have to poll
Tekton state and is expected to take longer on first-run; subsequent runs
after the pipeline lands are immediate.

### Risks and Mitigations

- **Risk:** the umbrella folder drifts from Jira state because the Jira
  integration is thin.
  **Mitigation:** `/feature:status` shows the last Jira sync timestamp and
  refuses to claim a feature is done if Jira has moved independently.
- **Risk:** drivers edit `state.yaml` manually to unblock themselves.
  **Mitigation:** integrity hash detects edits; commands refuse to proceed
  and tell the driver which stage command to re-run. `state.yaml` has no
  user-facing fields that need manual editing.
- **Risk:** a stage gets skipped silently because its work happens outside the
  tooling (for example, docs written elsewhere).
  **Mitigation:** `/feature:ship` refuses to close if any required stage for
  the feature's risk level is in `pending` or unrecognized `skipped` state.
- **Risk:** maturity metrics become a goal that warps behavior (drivers
  accept bad AI output to make their feature look better).
  **Mitigation:** the metric is a *blocker classification*, not a
  percentage. Accepting a bad output still classifies as `template` /
  `skill` / `kb` blocker in the driver's maturity entry; there is no
  percentage to game by looking away. The maturity narrative captures
  intervention *intent*, and `/feature:metrics` surfaces recurring
  intervention sources so the team treats low maturity in a category as
  a signal to invest in that category, not to punish drivers.

### Drawbacks

- The lifecycle has many stages with multiple artifacts — more structure
  than a small fix needs. The `light` profile mitigates this (research
  collapses into design; retrospective is opt-out; most artifacts shrink
  to one line) but the umbrella folder, `state.yaml`, and the mandatory
  validation gates (QA, integrate, accept, regress) remain for every
  feature. We accept this cost in exchange for end-to-end verification
  on every change, even trivial ones.
- The workflow does not support concurrent drivers on the same feature.
  Handoff and pause are supported and explicit (see
  [Driver Handoff and Pause](#driver-handoff-and-pause)) but at any
  moment a feature has exactly one driver. Most features are driven by
  one person, and Jira already handles the multi-person case via
  separate stories.
- Cross-feature collision detection relies on declared signals
  (`feature.repos`, `--connector`, `--touches`). Drivers who under-declare
  produce false negatives. We mitigate by re-running the check at `/plan`
  with sharper signal, but a determined misuse can still slip through.
- The coordinator's parallel sub-agent dispatch depends on each repo
  having a working `/opsx:*` implementation. The `connectors-plugin`
  repo in particular needs a UI-aware variant; until that lands, UI
  stories fall back to driver-led steps and raise the `skill`-blocker
  count for the affected feature.
- **Two umbrella types raise the learning curve.** Drivers now need to
  decide at `/feature:init` vs `/feature:epic-init` time whether their
  work warrants an epic umbrella or is a one-shot feature. We mitigate
  this by defaulting `/feature:init` (no epic) and letting the driver
  promote to an epic retroactively when post-release feedback starts
  piling up. Most single-story fixes never need the epic container;
  most multi-release user-facing features do.
- **Epic umbrellas can linger indefinitely.** A Jira epic that keeps
  spawning stories (or whose p0 story list keeps growing) will hold an
  umbrella open for months. We accept this: the alternative — closing
  the epic aggressively and losing the connection between its stories
  — is worse. `/feature:epic-status` surfaces epic age and story-count
  trend, so the team can see when an epic has lost focus and should be
  split.
- **Post-release bugs that the team chooses to *not* fix still live on
  the epic's log.** This is deliberate (so the decision is auditable)
  but it does mean the log accumulates forever for long-lived epics.
  `/feature:epic-close` requires open p0 items to be resolved but
  accepts non-p0 items as "deferred forever"; the log remains for
  historical reference.

## Alternatives

- **Pure linear pipeline (Option A only, no drill-down).** Simpler surface,
  but multi-repo features would serialize per-repo work and lose significant
  time. Rejected in favor of the A-with-drill-down hybrid.
- **Checklist / state-graph (Option C).** Every action is "unlocked" when its
  dependencies are met; no fixed stage order. More flexible, but harder to
  teach and harder to standardize automation metrics against. Rejected
  because the primary goal is a low learning curve.
- **Jira-centric reporting with no new workflow.** A dashboard that reads
  git, Tekton, and Jira and synthesizes status without any new commands.
  Rejected because it addresses traceability but not the "one driver, one
  surface, almost-autonomous execution" goal.
- **Per-feature branch across all repos.** Using a shared feature branch name
  across the three repos, coordinated by a script. Works for cross-repo sync
  but not for cross-feature ordering or QA handoff.

## Implementation Plan

Seven incremental phases. Each phase is itself an OpenSpec change in
`connectors-operator` (where the commands, templates, state schema, and
docs all live). Phases can ship in order; each produces working end-to-end
value for a subset of stages.

- **Phase 1 — Umbrella scaffolding, state contract, lifecycle commands.**
  - This TEP merged.
  - `docs/en/design/` directory seeded with a `README.md`, `archive/`,
    and an empty `improvement-log.md`.
  - `state.yaml` JSON Schemas for FeatureState AND EpicState committed
    (via `kind:` discriminator) in `docs/en/design/state.schema.json`.
  - `/feature:init` (standalone feature: required `--profile`, `--risk`
    checklist, `--effort` tag, cross-feature collision check),
    `/feature:status`, `/feature:next`.
  - Ownership / pause commands: `/feature:handoff` (default non-destructive
    + `--reset` opt-in), `/feature:pause`, `/feature:resume`,
    `/feature:promote` (with demotion allowed), `/feature:cancel`,
    `/feature:conflicts`.
  - Integrity: `/feature:state-repair` with audit-reason logging.
  - Per-stage entry/exit criteria enforced by command stubs returning
    "stage not yet implemented" for stages that land in later phases.
- **Phase 2 — Epic umbrella and multi-release support.**
  - `/feature:epic-init` (scaffolds `docs/en/design/epics/<jira>-<slug>/`).
  - `/feature:story-start` (branches a feature umbrella from an epic with
    parent_epic back-link).
  - `/feature:epic-status` (multi-release board).
  - `/feature:bug-link` (post-release log append).
  - `/feature:epic-close` (archive when all p0 stories shipped).
  - Epic-state schema, `stories.md` / `post-release-log.md` templates,
    epic-level `/feature:state-repair` integration.
- **Phase 3 — Design flow with story decomposition.**
  - `/feature:research` (dispatches Explore sub-agents; enforces Stories
    section for `profile=full`; collapsed into design for smaller profiles;
    runs at the epic level when the feature is epic-inherited).
  - `/feature:design` (scaffolds product/tech designs with the goal-first
    template, Task Breakdown, Test Design, and `dependencies.md` sections;
    `threat-model.md` for sensitive; `## Context` inlining of research for
    `light`/`standard`).
  - `/feature:design-review` (gate with approved/pivot/rework; auto-offers
    `/feature:poc` after the second consecutive pivot).
  - `/feature:poc` (optional throwaway-branch spike).
  - `/feature:story` (add / split / merge / defer; mid-flight mutation on
    whichever umbrella owns the story list).
- **Phase 4 — Implementation fan-out with story groups and dependency graph.**
  - `/feature:plan` (creates story groups with per-repo changes classed as
    `design-change` or `mechanical-followup`; planning-time collision
    recheck).
  - `/feature:implement` (parallel `/opsx:apply` dispatch ordered by
    `dependencies.md`; draft-PR hold for blocked stories; auto-rebase when
    blockers merge).
  - `/feature:tracks` (story-grouped board rendered from the dependency
    graph) and `/feature:dispatch` drill-down.
- **Phase 5 — Post-merge flow.**
  - `/feature:integrate` (Tekton bundle observation).
  - `/feature:qa` (executes the test design against the bundle).
  - `/feature:accept` and `/feature:docs` (parallel fork).
  - `/feature:regress`.
- **Phase 6 — Sensitive overlay, retrospective, ship (with immediate archive).**
  - `/feature:security-sign-off`.
  - `/feature:retro` (required for standard/full; opt-out for light;
    recognised opt-out tokens). **Runs before ship.**
  - `/feature:ship` with Jira integration, immediate archive move, and
    back-link write on the parent epic (if any).
  - `improvement-log.md` append + tag taxonomy.
- **Phase 7 — Workflow maturity tracking.**
  - Per-command blocker classification (retrofitted into all prior
    commands).
  - `/feature:maturity` (per-feature view) and `/feature:metrics` rollup
    (per-category trend, top intervention sources, WIP distribution,
    state-repair rate, post-release bug rate from epic logs).
  - `maturity-metrics.md` rollup generator.

### Test Plan

- **Unit tests** for each command's state-machine logic in the `connectors`
  repo, focused on: state transitions, integrity hash, risk overlay, skip
  handling.
- **Integration tests** that run `/feature:init` through `/feature:ship`
  against a synthetic single-repo feature and a synthetic cross-repo feature
  with mocked sub-agents.
- **Template tests** that verify every artifact template in this repo is
  parseable and fills in placeholders correctly for each risk level.
- **Dogfooding**: the first three real features after Phase 4 ships must be
  driven through the workflow end-to-end; their `maturity-report.md`
  narratives become input to Phase 6 template improvements.

### Infrastructure Needed

None beyond what exists today. The workflow writes to git only; no new
services, databases, or queues.

### Upgrade and Migration Strategy

Existing in-flight work remains on the current `/opsx:*` surface until
features wrap. New features after Phase 1 ships can opt into `/feature:init`.
No migration of past OpenSpec changes is required; archived changes are not
retroactively imported into feature umbrellas.

### Implementation Pull Requests

(To be filled as phases merge.)

## Appendices

### Appendix A — `--risk` Trigger Checklist

Run at `/feature:init`. Each question answered "yes" raises the computed risk
level as indicated. The driver may override the result; overrides are
recorded in `state.yaml`.

Standard-raising triggers (any "yes" → at least `standard`):

1. Does this change code that runs in production?
2. Does it introduce a new user-facing surface (CRD field, CLI flag, API
   endpoint)?
3. Does it alter any default behavior of an existing component?

Sensitive-raising triggers (any "yes" → `sensitive`):

4. Does it touch credential, token, or secret handling?
5. Does it change TLS, CA cert, or encryption behavior?
6. Does it modify RBAC, access policies, approval flows, or admission
   webhooks?
7. Does it open or change network egress to a third-party system?
8. Does it change cluster-scoped resources or the operator's own RBAC?
9. Does it expose a new API endpoint, webhook, or gRPC service?

Low-only (all "no" above AND):

10. Is this a docs-only, test-only, or internal-refactor change?

### Appendix B — `threat-model.md` Template

```markdown
# Threat Model — <feature title>

## Assets
- What valuable things does this feature handle or protect?

## Actors
- Legitimate: who is expected to interact with the feature?
- Adversarial: who might try to misuse it?

## Threats
For each threat, record: threat, affected asset, likelihood, impact.

## Mitigations
For each threat, record: planned mitigation, where it lives in the design,
who implements it.

## Residual risk
Threats not fully mitigated, and why accepting them is reasonable.

## Reviewer
- Name, role, security label, sign-off date.
```

### Appendix C — `security-sign-off.md` Template

```markdown
# Security Sign-off — <feature title>

## Bundle under review
- Bundle tag: <tag>
- Bundle image digest: <sha256>
- Included manifest versions: <list>

## Surface review
- Operator RBAC delta vs. previous bundle: <diff summary>
- New exposed endpoints: <list or none>
- Third-party network egress introduced: <list or none>

## Findings
- Blocker findings: <list or none>
- Non-blocker findings: <list or none>

## Decision
- approved | rejected
- Reviewer: <name>, <date>
- Rationale: <one paragraph>
```

### Appendix D — `qa-packet.md` Template

```markdown
# QA Packet — <feature title>

## Bundle
- Tag: <tag>
- Operator image: <image@digest>
- Included component images: <list>

## Jira
- Epic/story: <id>, <title>, link

## Acceptance criteria
Mapped from `proposal.md`. For each AC:
- AC text
- Expected BDD feature file(s) and scenario names
- Expected outcome

## Environment
- Cluster requirements (kind, ACP, sizes)
- Kubeconfig retrieval instructions
- Any required feature flags

## Test instructions
- Which regression tag expressions to run
- How to interpret failure output
- Who to contact on blockers
```

### Appendix E — `state.yaml` Schemas

The full JSON Schema is committed at `docs/en/design/state.schema.json`
with a `kind: epic | feature` discriminator at the top level. Phase 1 of
the Implementation Plan commits the feature variant; Phase 2 adds the
epic variant.

#### Common fields (both kinds)

- `kind` (required): `epic | feature`
- `schema_version` (int, required; currently `3`)
- `integrity` (object, required): `last_hash`, `last_written_by`,
  `last_written_at`, `repairs[]` (appended by `/feature:state-repair`)
- `collisions[]` (array): other in-flight umbrellas flagged as overlapping

#### `kind: feature`

- `feature` (object, required): `jira_id`, `slug`, `title`, `parent_epic`
  (nullable Jira id), `profile`, `risk`, `repos`, `effort`, `created_at`,
  `driver`, `previous_drivers[]`, `paused`, `profile_history[]`,
  `shipped_at` (nullable)
- `stage` (object, required): `current`, `history[]`
- `story` (object, nullable): `id`, `title`, `slice`, `priority`,
  `depends_on[]` — the one story this feature represents when branched
  from an epic
- `stories[]` (optional): present only for standalone `profile=full`
  features that decompose within their own umbrella
- `story_groups[]` (array): `story_id`, `review` (reviewer/signed_at),
  `changes[]` (each with `repo`, `class` in `design-change | mechanical-followup`,
  `path`, `pr`, `pr_state`, and optional `parent_change` for followups)
- `bundle` (object): `synced_manifests`, `bundle_image`, `bundle_tag`
- `qa` (object): `packet_path`, `owner`, `assigned_at`
- `acceptance` (object): `status`, `report_path`
- `regression` (object): `status`, `report_path`
- `maturity` (object): `entries[]` (see [Appendix G](#appendix-g--maturity-tracking-schema)),
  `category_totals` (per-category blocker counts, filled at ship)
- `security` (object): `threat_model_path`, `signoff_path`, `override`

#### `kind: epic`

- `epic` (object, required): `jira_id`, `slug`, `title`, `profile`,
  `risk`, `repos`, `created_at`, `driver`, `previous_drivers[]`
- `epic_stage` (object, required): `current` (`init | in-flight | closing | archived`),
  `history[]`
- `stories[]` (array): `id`, `title`, `slice`, `priority`, `repos`,
  `depends_on[]`, `state` (`not-started | in-flight | shipped | cancelled | deferred`),
  `shipped_in_release` (nullable), `feature_jira_id` (nullable)
- `dependencies[]` (array): story-level edge list (`from`, `to`)
- `shipped_features[]` (array): back-links to archived feature umbrellas
  — `feature_jira_id`, `story_id`, `archived_path`, `shipped_at`,
  `shipped_in_release`
- `post_release_log[]` (array): bug-link entries — `entry_at`, `jira_id`,
  `severity`, `related_story`, `disposition`
  (`fix-next-release | fold-into-inflight-story | defer | accept | new-story-added`),
  `new_story_id` (if disposition is `new-story-added`), `notes`
- `security` (object): `threat_model_path`, `override`

### Appendix F — Per-Stage Artifact Templates

Feature umbrella templates (written to `docs/en/design/<slug>/`):

- `feature.md` — Jira block, profile, risk level, affected repos,
  `parent_epic` back-link, `--effort` tag, DoD checklist, links to every
  sibling artifact.
- `handoff.md` — driver context snapshot (open questions, deferred
  decisions, in-flight sub-agent state).
- `dependencies.md` — story-level dependency edge list (only when the
  feature itself decomposes further; otherwise the edge list lives on
  the epic).
- `research.md` — per-repo findings (profile=full standalone features
  only; epic-inherited features skip this).
- `product-design.md` / `tech-design.md` — goal, task breakdown, test
  design; `## Context` inlining for light/standard.
- `threat-model.md` — risk=sensitive only.
- `design-review.md` — attendees, decisions, outcome.
- `poc.md` — hypothesis, branch URL, outcome, design impact, learnings.
- `qa-packet.md` / `qa-results.md` — QA input and execution outcomes.
- `acceptance.md` — AC-by-AC pass/fail table.
- `release-notes.md` — user-visible summary, upgrade notes.
- `docs-changes.md` — index of user-facing doc edits.
- `regression.md` — suite run summary, Allure link, known failures.
- `security-sign-off.md` — risk=sensitive only.
- `retrospective.md` — worked / didn't work / change (runs before ship).
- `maturity-report.md` — per-stage blocker table, category totals, top
  intervention-source narrative.

Epic umbrella templates (written to `docs/en/design/epics/<slug>/`):

- `epic.md` — Jira epic block, profile hint, risk, repos, story-list
  summary, open p0 count.
- `research.md` — cross-story research (profile=full).
- `design-overview.md` — architectural shape across stories.
- `stories.md` — numbered story list with priority, slice, repos,
  `depends_on[]`, state, and (when shipped) release tag.
- `dependencies.md` — story-level edge list.
- `design-review.md` — epic-level review outcomes.
- `post-release-log.md` — append-only: `/feature:bug-link` entries,
  deferred tech debt, new stories added post-release.

Full bodies of each template are committed alongside this TEP at
`docs/en/design/templates/`.

Retired templates (do not author these; replaced by their successors):

- `post-ship-observations.md` → superseded by epic `post-release-log.md`.
- `postmortem.md` → superseded by epic `post-release-log.md` entries +
  the feature's `retrospective.md`.

### Appendix G — Maturity Tracking Schema

Each entry in `state.yaml.maturity.entries`:

```yaml
- stage: design                  # stage name from the stage model
  command: /feature:design       # exact command invoked
  primary_blocker: template      # none | template | skill | kb | judgment | flake
  ai_turns: 2                    # total AI turns inside the active stage
  driver_edits:
    files_touched: 2
    lines_changed: 14            # total +/- lines against AI baseline
  custom_prompts: 1              # count of driver re-prompts/custom instructions
  duration_min: 12
  opened_at: 2026-04-14T10:11:00Z
  closed_at: 2026-04-14T10:23:00Z
  closed_by: ai                  # ai | human (who committed the close)
  notes: ""                      # optional, driver-provided one-liner
  excluded: false                # true for design-review/poc loops, state-repair, etc.
  exclusion_reason: ""           # when excluded=true, names why
```

Blocker determination rules (reproduced from Design Details):

- `none`: `ai_turns == 1` and `driver_edits.lines_changed == 0`.
- `kb`: `ai_turns >= 2` and at least one driver turn was a context injection.
- `skill`: the driver invoked a raw skill or manual command inside the stage.
- `template`: default classification for non-trivial `driver_edits` where
  the edit added missing structure.
- `judgment`: driver-provided override (`--primary-blocker=judgment`) when
  the edit is a decision the AI was not expected to produce.
- `flake`: command errored transiently and retry succeeded.

Exclusions (`excluded: true`) for stage entries that should not be scored:

- Design-review `pivot`/`rework` loops.
- `/feature:poc` loops.
- `/feature:story` mutations (design-iteration).
- Any stage closure on a feature where `/feature:state-repair` was
  invoked for the current stage.

Per-feature category totals are computed at `/feature:ship` and written
into `state.yaml.maturity.category_totals` and `maturity-report.md`:

```
category_total[c] = count(entries where primary_blocker == c and not excluded)
```

There is no single aggregate percentage; `/feature:metrics` reports per-category
trends and named intervention sources instead.

### Appendix H — Recognized Skip Reasons

Stage commands accept `--skip=<reason>` only when the artifact genuinely
does not apply. Recognized reasons ship with this TEP; teams may extend
the list in their own `feature.md` template.

Starter list:

| Reason | Stages it applies to | Meaning |
|--------|---------------------|---------|
| `docs-only` | `qa`, `regress`, `integrate` | Feature only touches documentation; no behavioural bundle change. |
| `test-only` | `integrate`, `docs` | Feature only adds tests; no user-facing behaviour change. |
| `refactor-no-behavior-change` | `docs`, `accept` | Pure refactor with no AC / release-note entry warranted. |
| `no-ui-needed` | story-level, during research | The feature genuinely has no UI surface; documented explicitly rather than inferred. |
| `no-bundle-delta` | `integrate` | Feature is a consumer-side change (e.g. a Tekton task that uses connectors) without a new bundle artifact. |
| `no-e2e-needed` | e2e-case decision in design | Scenarios are covered by existing e2e; explicit rather than default. |
| `dup-of=<feature-id>` | `retrospective` (opt-out) | Learnings already captured in another feature's retro. |
| `trivial` | `retrospective` (opt-out) | One-line fix; no surprising learnings. |
| `sweep` | `retrospective` (opt-out) | Routine maintenance sweep (dependency bump, lint pass). |

Teams extending this list should add entries to their `feature.md`
template under a `## Recognized skip reasons` heading; the list is read
at stage close by the respective command. Reasons not in the list are
rejected with a message listing the current set.

## References

- [`docs/en/teps/assets/DEVOPS-41818-walkthrough.md`](assets/DEVOPS-41818-walkthrough.md) —
  companion walkthrough that shows this workflow end-to-end against a real,
  in-flight epic (oAuth2 App support for Authentication).
- `docs/en/teps/template.md` — the KEP-style template this TEP follows.
- `docs/en/teps/connectors-approval.md` and
  `docs/en/design/connectors-approval/` — the existing cross-repo design
  pattern this TEP generalizes into a workflow.
- [`../connectors/openspec/workflow/README.md`](../../../../connectors/openspec/workflow/README.md) —
  the current per-repo OpenSpec workflow, including the
  `/opsx:*` (`/opsx:new`, `/opsx:ff`, `/opsx:continue`, `/opsx:apply`) and
  `/workflow:*` (`/workflow:accept`, `/workflow:document`) commands this TEP wraps.
- [`../connectors/openspec/workflow/DESIGN.md`](../../../../connectors/openspec/workflow/DESIGN.md) —
  architecture rationale for the OpenSpec workflow this TEP sits above.
- `.tekton/sync-install-manifests.yaml` — the auto-sync pipeline observed by
  `/feature:integrate`.
- [`../connectors/.claude/commands/workflow/`](../../../../connectors/.claude/commands/workflow) —
  the post-apply workflow commands this TEP's `/feature:accept`,
  `/feature:docs`, and `/feature:regress` wrap.
