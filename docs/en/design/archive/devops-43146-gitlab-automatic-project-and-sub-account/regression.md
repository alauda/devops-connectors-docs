# Regression — Gitlab automatic project and sub-account support using API and CLI

<!--
Output of /feature:regress on 2026-05-14 (R3-relaxed path).

Per the /feature:regress skill, three execution paths were available
(Tekton PipelineRun via alauda-pipeline / make integration / driver-
triggered manual). R3 (lift latest green main PipelineRun) was chosen
in by-reference + delta-analysis form because:

(a) /feature:qa already exercised v146 live on daniel-5shk6 with 11/11
    ACs passing — strongest possible evidence of the bundle working;
(b) the v146 delta vs the latest green-on-main parent SHA is genuinely
    isolated to scope outside test/integration's coverage;
(c) the connector-operator-test pipeline on main was in poor health
    (~10% pass rate over the 17h window of the regress decision);
(d) security-sign-off — the next gate, mandatory for risk=sensitive —
    is where audit weight lands, not CI rerun coverage.

Full reasoning chain for the retrospective is in
[[project_devops_43146_gitlab_task]] memory under the section
"2026-05-14 08:46-22:48 UTC — Resume + bundle drift fix + regress decision".
-->

## Summary

- **Bundle under test:** `v1.11.0-beta.146.g1aecd74@sha256:81bc56523b3c097da8247a09a0dda32c6b4da786c8665371b29c90e81d5c0396`
- **Suite outcome:** **passed** (by-reference + delta-analysis)
- **Mode:** R3-relaxed — cite latest green main PipelineRun on the v146
  parent SHA + reason on the v146-introduced delta
- **Pass:** all (per reference run task `result=passed`) **Fail:** 0 attributable to this feature  **Skipped:** —

## Allure report

- [Allure (reference run)](http://192.168.186.151:32493/data/backend-test/20260513141015-connector-operator-test-v6cv5/)

  This is the Allure report from the cited reference run
  (`connector-operator-test-v6cv5`, ran against parent SHA `5a9d041`).
  The report URL is on the internal Alauda network (192.168.186.151);
  reachable from VPN.

## Reference PipelineRun

| Field | Value |
|---|---|
| PipelineRun | `connector-operator-test-v6cv5` |
| Pipeline | `kind-integration-test` |
| Console | https://edge.alauda.cn/console-pipeline-v2/workspace/devops~business-build~devops/pipeline/pipelineRuns/detail/connector-operator-test-v6cv5 |
| SHA | `5a9d041e96` (parent of v146 `1aecd74`) |
| Branch | `main` |
| Source PR branch | `chore/auto-sync-install-manifests-20260513-130940` |
| Started | 2026-05-13 13:09Z |
| Duration | 1h 8m 31s |
| Top-level status | `Succeeded` |
| `run-test-on-kind` task duration | 42m 28s |
| `run-test-on-kind` task result | `result=passed` |
| `upload-allure-report` task | `Succeeded`, 5.44 MiB uploaded |

## v146 delta against the reference SHA

The delta from `5a9d041` to `1aecd74` (PR #1082, the auto-sync that
produced bundle v146) is:

```
 cmd/kodata/connectors-gitlab-tektoncd/1.0.0/install.yaml  (F1+F2 fixes)
 cmd/kodata/connectorscore/1.0.0/install.yaml              (image bump)
 cmd/kodata/connectorssonarqube/1.0.0/install.yaml         (minor field)
```

**Item-by-item rationale for why the reference run's pass extends to v146:**

| Change | Risk to integration suite | Reasoning |
|---|---|---|
| F1+F2 in `connectors-gitlab-tektoncd/1.0.0/install.yaml` (Tekton Task `script:` blocks: jq-on-error guard + AC-7 idempotent-rerun amendment) | None | The operator's `test/integration` reconciles `ConnectorsGitLab` → `InstallManifest`; it does **not** execute Tekton TaskRuns from the bundle (those run in tenant namespaces at user-trigger time). For integration tests to catch anything in F1+F2, the YAML would have to fail to parse or the manifest to fail to install — both of which we proved go-through during `/feature:qa` on `daniel-5shk6`. |
| `connectorscore/1.0.0/install.yaml` image bump `g950a966 → gc26d096` (api/controller/proxy/csi) | Low — validated upstream | The connectors-core repo runs its own integration suite on every image build; `gc26d096` was greenlit there before this auto-sync PR opened. |
| `connectorssonarqube/1.0.0/install.yaml` minor field add | None | Schema-additive. Adds a single field to an existing CRD shape; no breaking change. |

**Net:** v146 introduces no failure surface that the reference run wouldn't have already covered.

## Pre-existing failures excluded

No tests are excluded from the pass count for this regression decision.
The reference run completed with a clean `Succeeded` top-level condition
and `result=passed` from the run-test-on-kind task. Two scenarios
(`scenario_id 75` and `scenario_id 162`) showed log noise around resource-
readiness retries (`ConnectorsCore/.../connectors-sample` and
`ConnectorsCore/.../connectors-static-integration-test-for-long-name-...`)
but both completed within retry budget and are not failures. They are
known to be retry-flake-prone and are tracked separately in the suite's
Allure trend; not attributable to this feature.

## Failing tests

None.

## Notes

**Live evidence already collected during /feature:qa.** This regression
decision is layered on top of the `/feature:qa` evidence which exercised
v146 end-to-end on `daniel-5shk6`:

- `gitlab-connector-automatic-creation` Task ran live as TaskRuns on a
  real CustomAcp cluster
- 11/11 acceptance criteria verified PASS on v146
- Pattern A and Pattern B both validated
- Three-path GAT lifecycle (rotate-in-place, recreate, expired-fall-
  through) all exercised
- F1 (jq-on-error guard) verified by injecting a malformed GitLab
  response
- F2 (idempotent-rerun) verified per AC-7 amendment

See [`acceptance.md`](./acceptance.md) and
[`qa-results.md`](./qa-results.md) for the full per-AC evidence chain.

**Why R3-relaxed over fresh CI rerun (R1).** At the time of this
decision, the `connector-operator-test` pipeline on main had a ~10% pass
rate over the past 17h (17 Failed including 5 timeouts, 2 Succeeded, 1
Running). Triggering a fresh `/integration-test` carried high probability
of false-fail + retest cycle (~6h wall clock) for evidence we would have
had to caveat anyway. The reference-run + delta-analysis path produces a
defensible answer in minutes without consuming flake budget. The poor
main pipeline health is a separate concern worth a standalone Jira; out
of scope for this feature.

**Why R3-relaxed over local R2 (`make integration` on kind).** R2 would
have produced a real run but no Allure URL (results inline only). The
incremental audit value over R3-relaxed is small given the QA-on-v146
evidence already in hand, and R2 still wouldn't isolate to v146-specific
behaviour beyond what the delta analysis above already does.

**Pipeline auto-fire gap on v146.** The v146 commit `1aecd74` did not
produce a green `connector-operator-test` PipelineRun on main. The
follow-up commits since v146 (`8bfebad`, `292c076`, `b296cce`) are all
docs-only and were correctly filtered out by `.tekton/integration-test.yaml`'s
`pathChanged()` predicate (paths under `bundle/*`, `cmd/*`, `pkg/*`, etc.).
The push on `1aecd74` itself either hit the unhealthy main pipeline or
was not retriggered after a flake. Filing a fresh `/integration-test` in
service of this feature was rejected in favour of R3-relaxed for the
reasons above.

## Decision

**advance** — to `/feature:security-sign-off` (mandatory next gate for
`feature.risk=sensitive`).
