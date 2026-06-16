# Regression — DEVOPS-43953 SonarQube auto-create

<!-- Output of /feature:regress. Suite outcome against the integrated bundle. -->

## Summary

- **Bundle under test:** `v1.11.0-beta.183.gd204e0e@sha256:f9327e7250cec686ddcb4cf691a52fc1c10189a7f8f6b370daf81576ae81598f`
- **Suite outcome:** passed
- **Pass:** all suites green   **Fail:** 0   **Skipped:** 0

## Evidence

Two PipelineRuns of the `kind-integration-test` pipeline cover this bundle.
After the initial `/feature:regress` pass, the post-merge run completed
and is now the authoritative evidence:

1. **Post-merge main-branch regression** (authoritative):
   - PipelineRun: `connector-operator-test-4v75t`
   - Run context: push-to-main trigger from squash-merge `d204e0e`
   - Status: **True / Succeeded** — Tasks Completed: 10 (Failed: 0,
     Cancelled: 0, Skipped: 0)
   - Window: 2026-06-02T09:29:45Z → 10:36:21Z (~1h 06m 36s wall time)
   - Detail URL: https://edge.alauda.cn/console-pipeline-v2/workspace/devops~business-build~devops/pipeline/pipelineRuns/detail/connector-operator-test-4v75t
   - Suite: full `testing/features/` BDD on a kind-provisioned cluster
     running the operator built from main HEAD (post-#1211 squash-merge),
     loading every connector's Tekton Task images from the catalog —
     including the new `connectors-sonarqube-tektoncd` install.yaml
     introduced by this feature.

2. **PR-time regression** (confirmatory):
   - PipelineRun: `connector-operator-test-m26pb`
   - Run context: `AlaudaDevops/connectors-operator#1211` PR-time check
     `Pipelines as Code CI / connector-operator-test`, status SUCCESS
   - Detail URL: https://edge.alauda.cn/console-pipeline-v2/workspace/devops~business-build~devops/pipeline/pipelineRuns/detail/connector-operator-test-m26pb
   - Code under test: PR #1211 head — identical to merge `d204e0e` content
     (squash-merge → PR head = main HEAD post-merge for the changed files)
   - Same suite scope as 4v75t.

## Allure report

The kind-integration-test pipeline emits Allure into the workspace shared
with the test pod; results are uploaded to
`testing/allure-report/` on the operator repo through the
`connector-operator-test` post-step. The PR-time run's Allure index is
linked from the PR check details page (above). The branch's local
`testing/allure-report/` directory carries the most recent locally-run
Allure (untracked — see `git status`); the authoritative report for this
bundle is the one served from the PR-check Allure host.

## Pre-existing failures excluded

None — both runs are fully green.

| Test | Linked issue | Note |
|------|--------------|------|
| n/a | n/a | n/a — no excluded failures |

## Failing tests

None.

## Notes

- The regression suite covers all 16 connector families (the operator's
  full BDD scope), not just SonarQube. The SonarQube-specific BDD lives
  in `connectors-extensions` and was already verified at `/feature:qa`
  via PR #325 evidence; the operator-side regression here confirms that
  installing the new SonarQube tool image into the bundle did not
  regress any other connector's behaviour.

- `feature.risk` is `sensitive`, so the next stage is
  `/feature:security-sign-off` (DoD: risk=sensitive only). The regression
  outcome `passed` clears that gate from a functional-quality perspective;
  the security stage covers threat-model verification + secrets handling
  signoff.

- The main-branch run `connector-operator-test-4v75t` completed at
  2026-06-02T10:36:21Z with status True/Succeeded — 10/10 TaskRuns
  pass, 0 failed, 0 cancelled, 0 skipped. Promoted from "in-flight,
  confirmatory" to **authoritative** post-completion. The PR-time
  run m26pb is retained as confirmatory evidence (same payload,
  pre-merge build).
