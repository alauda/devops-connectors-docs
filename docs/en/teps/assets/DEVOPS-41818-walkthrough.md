---
status: walkthrough (illustrative; not yet executed)
authors:
  - daniel
created: 2026-04-16
updated: 2026-04-22
jira: DEVOPS-41818
related-tep: ../feature-workflow.md
---

# Walkthrough — DEVOPS-41818: oAuth2 App support for Authentication

This document shows how the [feature workflow TEP](../feature-workflow.md)
would play out end-to-end on a real, in-flight epic that naturally spans
multiple releases. It is not a project plan; it is a worked example so the
reader can see what each `/feature:*` stage produces against an epic that
*exists today* in our backlog.

The epic was chosen because it exercises every corner of the two-tier
umbrella model the TEP introduces:

- It touches all four repos (`connectors`, `connectors-extensions`,
  `connectors-operator`, `connectors-plugin`).
- It is `risk=sensitive` (auth flow, credential storage, new exposed
  endpoint).
- Its acceptance criteria are not yet written, so the workflow has to
  *produce* the decomposition rather than execute against a fully
  specified epic.
- It blocks a quarterly milestone (`DEVOPS-39706 — 2026Q2 Connectors
  security enhancement`), so multiple releases are implicated.
- It will ship across several release cycles: the initial credential
  model in release 2026.05, per-provider token issuance and CRD
  extensions in 2026.06, the UI and docs in 2026.07 (LTS), with
  post-release bugs and deferred tech debt absorbed by the epic
  umbrella as they arise.

---

## Epic snapshot (as fetched from Jira on 2026-04-16)

```
Key:        DEVOPS-41818
Type:       Epic
Status:     待处理 (To Do)
Priority:   L1 - High
Component:  connectors-operator
Reporter:   Daniel Morinigo
Assignee:   Jingtao Cheng
Blocks:     DEVOPS-39706 (2026Q2 Connectors security enhancement milestone)

Title:      oAuth2 App support for Authentication

Description:
  Goal: Adds support to oAuth2 apps in connectors tech stack to support
  connectors

  Scenarios:
    - Github apps have its own auth flow, and permission mechanisms that
      personal tokens don't, generally is recommended to use such Github
      Apps mechanism to increase rate limits and provide better control
    - Gitlab apps (same as github)

  Acceptance criteria (needs completion)
```

Two things to notice up front:

1. The goal is one sentence. The driver does not yet know what "support"
   means concretely (do we issue tokens? store app credentials? rotate
   them? handle the install/uninstall flow per-tenant?).
2. The acceptance criteria are explicitly missing. This is precisely the
   case where the workflow's epic-level `research` and `design-overview`
   stages have to produce the structure rather than just record it.
3. The scope is plural (github apps, gitlab apps, callback surface, UI),
   so the work is a multi-release epic, not a one-shot feature.

The walkthrough below shows how the workflow drives the gaps to closure
across three release cycles without the driver having to invent process
on the fly.

---

## Part 1 — The first release

### Stage — `/feature:epic-init`

```
$ /feature:epic-init DEVOPS-41818

ERROR: --profile is required. Pick one of:
  light     — one-story epic; prefer /feature:init directly.
  standard  — 2-3 stories across 1-2 repos, risk ≥ standard.
  full      — 3+ stories OR 3+ repos OR new connector type.

$ /feature:epic-init DEVOPS-41818 --profile=full

Fetched Jira: DEVOPS-41818 — "oAuth2 App support for Authentication"
  Component:  connectors-operator
  Reporter:   Daniel Morinigo
  Assignee:   Jingtao Cheng
  Blocks:     DEVOPS-39706
  ACs:        none defined (Jira description says "needs completion")

Risk-trigger checklist (epic-scope):
  - production code?                           yes  → at least standard
  - new user-facing surface (CRD/CLI/API)?     yes  → at least standard
  - default behaviour change?                   no
  - credential / token / secret handling?      yes  → SENSITIVE
  - TLS / CA cert / encryption change?         yes  → SENSITIVE
  - RBAC / admission / approval flows?         yes (callback handler) → SENSITIVE
  - new third-party network egress?            yes (github/gitlab oauth) → SENSITIVE
  - new exposed endpoint?                      yes (oauth callback)     → SENSITIVE
  - cluster-scoped or operator RBAC change?    likely  → SENSITIVE

Computed risk: sensitive
Profile:       full (driver-declared)

Cross-feature collision scan (epic-scope, against other active epics):
  - DEVOPS-42720 (Connector end-to-end encryption) — touches credential
    storage in connectors. Severity: high (overlap on the credential path).
  - DEVOPS-43567 (Connector Operator Out-of-the-box deployment) — touches
    install manifests in connectors-operator. Severity: low.
  Run /feature:epic-init ... --acknowledge=DEVOPS-42720 --acknowledge=DEVOPS-43567
  to proceed.

$ /feature:epic-init DEVOPS-41818 --profile=full \
    --acknowledge=DEVOPS-42720 --acknowledge=DEVOPS-43567

Created docs/en/design/epics/DEVOPS-41818-oauth2-app-auth/
  - epic.md, state.yaml, research.md (empty), design-overview.md (empty),
    stories.md (empty), dependencies.md (empty), post-release-log.md (empty)
Affected repos: connectors, connectors-extensions, connectors-operator, connectors-plugin
Risk: sensitive — threat-model.md will be required at design.
Driver: daniel
WARNING: Acceptance criteria missing in source Jira. Epic research must
         produce a Stories section AND an ACs section that the reporter
         signs off on before any story-start can dispatch.
Next: /feature:research (epic-scope)
```

**What just happened that matters:**

- Risk level was *computed*, not guessed. Six out of nine sensitive
  triggers fire for an OAuth implementation.
- The collision check caught `DEVOPS-42720` (Connector end-to-end
  encryption), which also lives in the credential path. Without this
  signal, the two epics could re-architect credential storage in
  incompatible ways and only discover it at PR review of the *second*
  epic's first story.
- The missing-AC condition is recorded in the epic's `state.yaml` so it
  cannot be forgotten. No story can start until the reporter signs off.

### Stage — `/feature:research` (epic-scope)

Dispatches one Explore sub-agent per affected repo with a scoped
question. For this epic:

- `connectors`: "How is auth handled today between the proxy and Git
  providers? What changes if we add a per-tenant OAuth app instead of a
  static token?"
- `connectors-extensions`: "What does `connectors-git` do today for
  GitHub auth? What does `connectors-gitlab` do for GitLab? Where would
  GitHub App / GitLab App credentials slot in?"
- `connectors-operator`: "What CRD fields exist on `ConnectorsGit` /
  `ConnectorsGitLab` today? How would we extend them to declare an
  OAuth app credential reference vs. a static token?"
- `connectors-plugin`: "What does the connector configuration form look
  like today? What would change for OAuth-app-flavored configuration?"

The AI consolidates `research.md` on the epic umbrella. Because
profile=full and source ACs are missing, the command refuses to close
without two sections: `## Acceptance Criteria (proposed)` and a story
list.

The driver edits the AI draft into:

```markdown
## Acceptance Criteria (proposed — pending reporter sign-off)

AC-1. A platform admin can register a GitHub App with the operator (app
      id, private key, webhook secret, install URL) via the
      ConnectorsGit CR. The credentials are stored in a Secret, not in
      the CR.
AC-2. A platform admin can register a GitLab Application analogously via
      the ConnectorsGitLab CR.
AC-3. A user creating a `Connector` resource backed by a GitHub-App-typed
      `ConnectorClass` is issued an installation token by the proxy on
      demand (not stored at rest), with the rate limits of the App and
      not the user.
AC-4. The same flow works for GitLab Applications.
AC-5. The OAuth callback endpoint exposed by the operator is restricted
      (TLS, signed-state cookie, single-redirect allowlist) and reviewed
      under threat-model.md.
AC-6. Existing static-token configurations continue to work unchanged
      (no migration forced; OAuth-app is an additional auth mode).
AC-7. The connectors-plugin UI exposes the OAuth-app configuration form
      as a peer to the personal-token form, with a clear "which to
      choose" hint.
AC-8. Documentation under docs/en/connectors/git/ and docs/en/connectors/gitlab/
      explains both setup paths and when to prefer each.
```

The story decomposition lands in `stories.md`:

```markdown
## Stories

1. **Backend: shared OAuth-app credential model** (p0, slice=backend,
   repos=[connectors, connectors-extensions]) · state=not-started
   Define how an OAuth-app credential reference is shaped (Secret
   schema, reference field on the connector CR, retrieval API in the
   proxy). Depends on: none. ACs: 1, 2, 6.

2. **Backend: GitHub App token issuance in the proxy** (p0, slice=backend,
   repos=[connectors, connectors-extensions/connectors-git]) · state=not-started
   Cache JWT, mint installation token per repo as needed, never persist.
   Depends on: 1. ACs: 3.

3. **Backend: GitLab Application token issuance in the proxy** (p0,
   slice=backend, repos=[connectors, connectors-extensions/connectors-gitlab]) · state=not-started
   Same shape as story 2 but for GitLab. Depends on: 1. ACs: 4.

4. **Operator: ConnectorsGit / ConnectorsGitLab CRD extensions** (p0,
   slice=backend, repos=[connectors-operator]) · state=not-started
   Add `auth.oauthApp.secretRef` to both CRDs; webhook validation.
   Depends on: 1. ACs: 1, 2, 6.

5. **Operator: OAuth callback endpoint** (p0, slice=backend,
   repos=[connectors-operator]) · state=not-started
   Redirect URI, signed-state cookie, redirect allowlist, TLS policy.
   Most security-sensitive surface. Depends on: 1. ACs: 5.

6. **UI: OAuth-app configuration form (GitHub + GitLab)** (p0, slice=ui,
   repos=[connectors-plugin]) · state=not-started
   OAuth-app form variant with "which to choose" inline. Depends on: 4.
   ACs: 7.

7. **Docs: setup guides for OAuth-app mode** (p1, slice=docs,
   repos=[connectors-operator]) · state=not-started
   New sections under docs/en/connectors/git/ and docs/en/connectors/gitlab/.
   Depends on: 1, 2, 3, 4, 5, 6. ACs: 8.

8. **Test: end-to-end acceptance** (p0, slice=test,
   repos=[connectors-operator]) · state=not-started
   Integration test for the full fake-App → installation-token flow.
   Depends on: 1, 2, 3, 4, 5. ACs: 3, 4.

9. **Follow-up (out of scope for this epic): per-tenant install UI**
   (p2, slice=ui, repos=[connectors-plugin]) · state=deferred
   "Click here to install the GitHub App" flow. Captured here so it
   isn't forgotten; will become a follow-up epic.
```

The driver shares `research.md` with the reporter for AC sign-off and
then closes the epic-research stage. The epic-scope design-overview and
design-review follow the same shape as a feature-level one but at the
architectural level — deciding, for example, that the OAuth callback
endpoint (story 5) lives in `connectors-operator` rather than in the
proxy, and recording the threat model for the callback surface.

### Stage — `/feature:story-start 1`

With epic-level research and design-overview approved, the driver
branches the first shippable slice:

```
$ /feature:story-start 1

Story 1 — "Shared OAuth-app credential model" (p0, backend)
  Repos: connectors, connectors-extensions
  Depends on: none (can start immediately)

Created docs/en/design/DEVOPS-43245-oauth-credential-model/
  - feature.md (parent_epic: DEVOPS-41818)
  - state.yaml, handoff.md (empty)
  - research.md INHERITED from epic (symlinked into feature's ## Context)
  - design-overview.md INHERITED from epic
Driver: daniel
Profile: standard (inherited from epic; can promote to full if this
         feature itself decomposes further — it doesn't here)
Next: /feature:design
```

The feature umbrella runs the normal feature pipeline. Its `design`
stage focuses on implementation-level decisions (Secret schema, the
exact retrieval API shape, cache lifetime) rather than re-litigating
the architectural ones already approved at the epic level. The feature
ships in release 2026.05:

- 2026-04-10 to 2026-04-18: design, plan, implement, integrate, qa,
  accept, docs, regress, retro.
- 2026-04-19: `/feature:ship`.
- 2026-04-20: feature umbrella archived at
  `docs/en/design/archive/DEVOPS-43245-oauth-credential-model/`.
- 2026-04-20: back-link written at
  `docs/en/design/epics/DEVOPS-41818-oauth2-app-auth/shipped-features/DEVOPS-43245.link`.
- 2026-04-20: epic `stories.md` updated — story 1 state: shipped,
  shipped_in_release: 2026.05.
- 2026-05-02: release 2026.05 publishes. Customers can try it.

---

## Part 2 — Post-release feedback and the second release

### Event — Customer bug DEVOPS-41999 (2026-05-18)

Two weeks after release 2026.05, a customer on self-hosted GitHub
Enterprise files DEVOPS-41999: the OAuth callback allowlist regex
rejects their hostname pattern. Root cause points at a validation path
that was shipped with story 1.

### Stage — `/feature:bug-link`

```
$ /feature:bug-link DEVOPS-41999 --epic=DEVOPS-41818 --related-story=1

Fetched Jira: DEVOPS-41999 — "OAuth callback regex rejects self-hosted GHE hostnames"
  Severity: high
  Affected release: 2026.05
  Reported by: <customer contact>

Appended to docs/en/design/epics/DEVOPS-41818-oauth2-app-auth/post-release-log.md:

  - entry_at: 2026-05-19T09:00:00Z
    jira_id: DEVOPS-41999
    severity: high
    related_story: 1
    disposition: <pending driver decision>
    notes: "self-hosted GHE hostname pattern fails current regex"

Added Jira comment on DEVOPS-41999 linking the epic umbrella.

Next: pick a disposition via /feature:bug-link --disposition=<kind>
      (fix-next-release | fold-into-inflight-story | defer | accept |
       new-story-added)
```

The driver decides: fix in the next release. They add a new story to
the epic:

```
$ /feature:story --add "Allowlist regex fix for self-hosted GHE" \
    --slice=backend --priority=p0 --repos=connectors-operator

Story 10 added to epic DEVOPS-41818.
Epic stories.md now lists 10 stories (8 in scope + story 9 deferred + new story 10).
Fast design-review required for story 10 (narrow scope; 30 minutes).

$ /feature:bug-link DEVOPS-41999 --epic=DEVOPS-41818 \
    --disposition=new-story-added --new-story-id=10

post-release-log.md updated — disposition recorded.
```

### Parallel — `/feature:story-start 2` (the planned second story)

At the same time (2026-05-05, before the bug even surfaced), the driver
(or a different driver) had started story 2:

```
$ /feature:story-start 2

Story 2 — "Backend: GitHub App token issuance" (p0, backend)
  Repos: connectors, connectors-extensions
  Depends on: 1 (shipped in release 2026.05) — CAN START
  Risk: sensitive (inherited)

Created docs/en/design/DEVOPS-43246-github-app-tokens/
  ...
```

Story 2 runs the feature pipeline in parallel with the hotfix story 10
over the course of ~3 weeks. They are independent feature umbrellas
with independent PRs; both back-link to DEVOPS-41818.

### Tech debt — `/feature:story --add --defer`

During story 2's implementation, the team discovers that the
installation-token caching assumed by story 2's design would benefit
from a proxy-wide cache that wasn't scoped originally. Adding it to
story 2 would balloon scope and risk the release 2026.06 train.

```
$ /feature:story --add "Credential cache in proxy" \
    --slice=backend --priority=p1 --defer \
    --repos=connectors \
    --depends-on=2

Story 11 added to epic DEVOPS-41818 with state=deferred.
Not blocking release 2026.06; can be picked up later.
post-release-log.md updated (classification: tech-debt-deferred).
```

### Shipping release 2026.06

By 2026-05-28, stories 2 and 10 have shipped (both feature umbrellas
archived; back-links written on the epic). Release 2026.06 publishes on
2026-06-02 containing both.

At this point the epic has:

- 3 stories shipped (1, 2, 10) — back-links under `shipped-features/`.
- 4 stories in-flight or not-started (3, 4, 5, 6).
- 2 stories deferred (9 follow-up, 11 tech debt).
- 1 story not yet started (7 docs, 8 e2e — both wait on more stories
  shipping).
- 1 post-release-log entry resolved (DEVOPS-41999 → story 10 shipped).

`/feature:epic-status DEVOPS-41818` renders this as a board.

---

## Part 3 — Remaining releases and epic close

### Releases 2026.07 (LTS) and 2026.08

The driver works through the remaining stories at whatever pace
capacity allows. Representative timeline:

- 2026-06 to 2026-07: `/feature:story-start 3` (GitLab token
  issuance), `/feature:story-start 4` (CRD extensions),
  `/feature:story-start 5` (OAuth callback endpoint — the highest
  security-sensitive story; gets careful threat-model re-review at
  feature-design-review even though the epic's threat model covered
  the surface). All three ship in release 2026.07 (LTS).
- 2026-07-15: `/feature:story-start 6` (UI form). Ships in 2026.08.
- 2026-07-22: `/feature:story-start 8` (e2e tests). Ships in 2026.08.
- 2026-07-29: `/feature:story-start 11` (the deferred cache — now a
  p1 that the team has bandwidth for). Ships in 2026.08.
- 2026-08-05: `/feature:story-start 7` (docs). Ships in 2026.08.

Occasional post-release bugs across these months follow the same
`/feature:bug-link` path; some become new p0 stories, some are deferred,
some are accepted.

### Epic close

By 2026-08-10, every p0 story has shipped. Story 9 remains as a
`deferred` stub pointing at a follow-up epic (which the team files
separately when/if they decide to build the richer install-flow UI).

```
$ /feature:epic-close DEVOPS-41818

Checking p0 story states...
  Story 1  shipped (2026.05)   ✓
  Story 2  shipped (2026.06)   ✓
  Story 3  shipped (2026.07)   ✓
  Story 4  shipped (2026.07)   ✓
  Story 5  shipped (2026.07)   ✓
  Story 6  shipped (2026.08)   ✓
  Story 8  shipped (2026.08)   ✓
  Story 10 shipped (2026.06)   ✓  (post-release bug fix)
All p0 stories shipped.

Non-p0 stories:
  Story 7  shipped (2026.08)       (p1)
  Story 9  deferred → follow-up epic DEVOPS-44120  (p2)
  Story 11 shipped (2026.08)       (p1, was tech debt)

post-release-log.md summary:
  - 1 bug linked, 1 resolved (DEVOPS-41999 via story 10)
  - 1 tech-debt deferred, 1 resolved (story 11)

Transitioning Jira epic DEVOPS-41818 to Done.
Moving epic umbrella to docs/en/design/epics/archive/DEVOPS-41818-oauth2-app-auth/.

Done. Epic closed.
```

---

## What this walkthrough demonstrated

- A real epic with a one-sentence goal and missing ACs went from "we
  have no idea what this means" to a structured 9-story decomposition
  (+2 follow-ups + 1 deferred tech debt) across 4 releases without the
  driver having to invent process.
- Post-release bugs (DEVOPS-41999) found a clean home on the epic
  umbrella via `/feature:bug-link`. The archived feature umbrella that
  shipped the affected code was not re-opened; the fix became a new
  story with its own feature pipeline.
- Tech debt discovered during story 2's implementation was added to the
  epic as a deferred p1 story (story 11), rolled forward to a release
  where capacity allowed, and shipped cleanly.
- Cross-feature collisions (`DEVOPS-42720`) were caught at epic-init
  and re-confirmed at plan for each story.
- Risk classification (`sensitive`) was computed once at epic-init and
  inherited by every story; the OAuth callback story still got a
  feature-level threat-model re-review because it's the most
  security-sensitive surface.
- The four-repo fan-out, ordered by the epic's dependency graph,
  compressed what would have been a serial multi-release effort into
  controlled parallel shipping while keeping each feature umbrella
  small and reviewable.
- The epic umbrella closed cleanly only when every p0 story had
  shipped. Its `post-release-log.md` remains as the auditable record
  of everything that happened after the first release.

For the underlying mechanics of each stage, see the
[feature workflow TEP](../feature-workflow.md) and its
[Per-Stage Entry and Exit Criteria](../feature-workflow.md#per-stage-entry-and-exit-criteria)
section. For the post-release flow specifically, see
[Post-Release Feedback](../feature-workflow.md#post-release-feedback).
