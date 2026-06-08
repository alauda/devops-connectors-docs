# Regression — Nexus 自动创建 Project + Connector + Secret

<!-- Output of /feature:regress. Suite outcome against the integrated bundle. -->

## Summary

- **Bundle under test:** `v1.11.0-beta.173.g15aaded@sha256:34827db4667b5f2fc87c89aa6cb2441c6e247e048566c90dd0e1cf5aea16f37d`
- **Suite outcome:** passed
- **Pass:** 58  **Fail:** 0  **Skipped:** 0

## Allure report

- [Allure — connector-operator-test-5db2d](http://192.168.186.151:32493/data/backend-test/20260528125223-connector-operator-test-5db2d/allure-report)

## Pre-existing failures excluded

None. The most recent green baseline on `main` (regression run
`connector-operator-test-r69v4`, 58/58 pass on the parent commit at
2026-05-28T12:11Z, ~40m before the bundle build for this feature) had
zero failing tests, so there is no pre-existing flake list to carry
into this run.

## Failing tests (if any)

None.

## Notes

- The regression suite is the operator's standard `connector-operator-test`
  PaC pipeline (`run-test-on-kind` task running the ginkgo `test/integration`
  specs against a kind cluster provisioned with the bundle under test).
- 58 cases covered every other connector type (git / gitlab / github / harbor /
  jfrog / k8s / maven / npm / oci / pypi / sonarqube) plus the connectors-core
  control-plane scenarios. The two-tier nexus-specific feature surface
  (nexus-connector-automatic-creation Tekton Task) was verified separately
  via the extensions-side BDD suite (29/29 green on PR #332 polish commit
  c5808a7, recorded in `acceptance.md`); the operator-side regression here
  confirms the bundle assembly + sync + nexus ConnectorClass scenarios are
  unbroken by the bundle delta this feature contributed.
- Run duration ~38m on `run-test-on-kind`; total pipeline ~63m including
  build + report upload. Within historical envelope for the parallel-run
  density (5 concurrent `connector-operator-test-*` pipelines on `devops`
  namespace at the moment of trigger).
