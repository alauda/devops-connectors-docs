# Maturity Report — Nexus 自动创建 Project + Connector + Secret

<!-- Output of /feature:ship. Stratified blocker signal. -->

## Feature metadata

- **Profile:** standard
- **Risk:** sensitive
- **Repos:** connectors-extensions, connectors-operator
- **Effort (advisory):** null
- **Driver:** jtcheng (+ handoffs: none)
- **Bundle shipped:** `v1.11.0-beta.173.g15aaded@sha256:34827db4667b5f2fc87c89aa6cb2441c6e247e048566c90dd0e1cf5aea16f37d`

## Stage summary

```
Total stages run: 12
  none:      8     (auto-complete: init, design-review, integrate, accept, docs, regress, retrospective, ship)
  template:  0
  skill:     0
  kb:        1     (design)
  judgment:  2     (plan, security-sign-off — on-target, not a miss)
  flake:     1     (implement)
```

## Top intervention sources

1. **(flake)** stage `implement` — 1268 min wall-clock, 28 AI turns, 4 PaC
   iterations driven by infrastructure flake (kind CoreDNS / aardvark-dns
   SERVFAIL, build-harbor GC mirror window, kind containerd CA trust for
   connectors-proxy MITM cert). Each iteration diagnosed via jump-server-
   fetched Allure + step logs; none were product-side defects. The fixes
   shipped — curl retry on transport errors, build-harbor → registry mirror
   rewrite, CoreDNS upstream-forward patch with grep-verify guard, CSI
   `ca.crt` plumbing for mode-B — are reusable but currently per-Task.
   **Suggested investment:** lift the four into shared connectors-extensions
   PaC fragments (CoreDNS patch, mirror-rewrite, CSI cert plumbing, curl
   transport-retry) so the next Task author inherits them. Tracked in
   improvement-log under DEVOPS-43952 `(tooling)` entries 2026-05-28.

2. **(kb)** stage `design` — 12 AI turns, 70 min, three POC hypotheses run
   against live Nexus 3.76 OSS; H1 invalidated (User REST object has no
   `description` field — fingerprint carrier had to move to `Role.description`
   with 400-char cap); H3 validated only after regex tightening (Nexus does
   not validate CSEL path semantics — regex is sole defense). Both gaps were
   product-side knowledge holes about Nexus 3.76 OSS that no template or
   skill would have closed.
   **Suggested investment:** a `knowledge/topics/nexus-oss-3.76-rest-quirks.md`
   entry in connectors-ai capturing the four quirks discovered (no
   `User.description`, CSEL semantic non-validation, anonymous-on-default
   without enforcement, no parent-project concept) so future Nexus work
   doesn't repeat the POC.

3. **(judgment)** stage `plan` — driver re-shaped the original 4-story plan
   (Story 2 / 3 / 3a / 4 in dependencies.md) into a 2-story bundle that
   matched how the implementation actually shipped (one extensions PR + one
   operator PR). This is irreducible plan-shaping work — no template lifts
   it. Listed in the judgment-only section below.

## Judgment-only stages (on-target)

- `plan`: re-shaping the dependencies-graph into shippable story groups is
  driver-domain work. The template can scaffold the artefact, not pick the
  bundle boundaries.
- `security-sign-off`: risk=sensitive reviewer judgment by design. Two
  residual risks (T9 anonymous-default-on, T16 pods/exec) were accepted
  with documented re-evaluation triggers; that's exactly the human-judgment
  call the stage exists to capture.

## Excluded stages

None this run. No POC loops outside the in-design POC (which is recorded
in `poc.md` and folded into the design stage's primary_blocker=kb signal,
not a separate excluded entry). No state-repair, no story mutations.

## Reading this report

- `flake=1` on `implement` is the dominant signal. The four reusable
  fragments listed above are the concrete output that moves it to `none`
  on the next Nexus-family or Tekton-Task-shipping feature.
- `kb=1` on `design` is the second signal. The POC-in-design pattern
  (improvement-log line 33 from DEVOPS-43146; repeated here as a working
  pattern) caught the gap at the right stage; the missing piece is making
  the lesson durable in the connectors-ai KB so the next feature doesn't
  re-POC the same Nexus REST surface.
- `judgment=2` is the honest floor — `plan` and `security-sign-off` are
  human-decision stages. Reducing them requires redesigning the stages,
  not better tooling.
- `none=8` covers stages where the workflow ran on rails: init,
  design-review (async-then-sync gate worked as designed), integrate,
  accept (9/9 ACs via BDD evidence), docs (after the release-notes block
  miss was caught — itself a Change entry), regress (58/58 on a clean
  baseline), retrospective, ship.

This feature's category totals feed `docs/en/design/maturity-metrics.md`
via `/feature:metrics`.
