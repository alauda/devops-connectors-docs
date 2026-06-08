# Review Iteration 2 — Handoff (DEVOPS-43953)

**Status as of 2026-05-26 ~03:58 UTC**: review iteration 2 (Harbor-style
image build + BDD rewrite) is **in flight, not landed**. PR #325 has a
working image build + dist + upload-dist; the BDD execution layer is
still broken. Handing off to a local-kind iteration loop so the BDD
rewrite can be tightened against a real kind cluster rather than over
PaC round-trips.

## 1. Repo / PR / branch snapshot

| Repo | Branch | PR | HEAD |
|---|---|---|---|
| `connectors-extensions` (cross-fork from `kycheng/`) | `pilot/DEVOPS-43953-task` | [#325](https://github.com/AlaudaDevops/connectors-extensions/pull/325) | `08f6713` |
| `connectors-operator` | `feature/devops-43953-sonarqube-auto-create-project-connector` | [#1147](https://github.com/AlaudaDevops/connectors-operator/pull/1147) | `338a56b` |

### Commit log on PR #325 (oldest → newest)

```
e127391 docs(connectors-sonarqube): scaffold OpenSpec changes (DEVOPS-43953)
7331e9e feat(connectors-sonarqube/tektoncd): add sonarqube-connector-automatic-creation Task v0.1 + BDD harness
bc02457 fix(connectors-sonarqube/testing): drop dangling local-path replace
14132ed refactor(connectors-sonarqube/tektoncd): implement review-iteration-1 deltas
17de998 test(connectors-sonarqube/tektoncd): cover review-iteration-1 contract
ac56495 feat(connectors-sonarqube/tektoncd): add optional sonarqubeUrl param
da2a555 refactor(connectors-sonarqube/tektoncd): bake helper scripts into a dedicated image
495cbcc build(connectors-sonarqube/tektoncd): register image + Makefile + BDD wiring
4645f30 ci(connectors-sonarqube): add Harbor-style PaC build+test pipeline   <-- earlier
... iteration of pipeline tweaks (rebased/amended to current ccc927c -> 8886361 -> a4aa6f7 -> 12a45ba -> 81eb646 -> c970237 -> e8f9c38) ...
08f6713 feat(connectors-sonarqube): ship sonarqube-tenant-offboard.sh in samples/
```

## 2. What actually works on PR #325

- ✅ Containerfile builds cleanly on PaC (`registry.alauda.cn:60070/devops/sonarqube-connector-automatic-creation:{v0.1.0,latest}`)
- ✅ trivy scan in-image sanity test (every helper script + `bash/curl/jq/kubectl` present at /usr/local/bin; UID 65532)
- ✅ `make dist` + `kustomize build` produces a 359-line `install.yaml`
  (Task + the two `config/images/*.yaml` ConfigMaps)
- ✅ `upload-dist` posts that install.yaml to
  `devops/connectors-sonarqube-tektoncd/install-manifests/<branch>`
- ✅ The PaC pipeline's `deploy-dependency` script (after several
  rounds of fixes) does successfully:
  - install cert-manager + Tekton Pipelines into kind
  - install the connectors operator (`CONNECTORS_BRANCH=main make deploy-connectors`)
  - install the connectors-sonarqube proxy from nexus main
  - `kubectl config set-context --current --namespace=bdd-testing` + `kubectl apply -f /workspace/source/connectors-sonarqube/tektoncd/dist/install.yaml`
  - get the Task itself into `bdd-testing` namespace (status `successfully created resource`)
- ✅ BDD framework loads + parses tektoncd.feature (after escaping
  `||` and dropping `<token>`/`<u>` literals)

## 3. What is STILL broken

### 3.1 BDD CEL evaluation fast-fails (the active blocker)

PaC `e8f9c38` minimal bisect (single-row CEL `size(obj.spec.params) == 11`)
still produces a fail in ~1 second per scenario, with no assertion-output
in the log. Each scenario's log shape is:

```
DEBUG checking namespace ...                       {scenario_id: 366, name: testing-sonarqube-connector-auto-144037}
WARN  StepImportSingleYamlWithType is deprecated   {scenario_id: 366}
WARN  config generator not found  {scenario_id: 366, parser: name}     (x3)
WARN  config generator not found  {scenario_id: 366, parser: tenant}   (x5)
DEBUG Diagnostic: Object YAML     {kind: Task, namespace: ..., name: sonarqube-connector-automatic-creation, status: UNKNOWN}
INFO  successfully created resource   {scenario_id: 366, name: sonarqube-connector-automatic-creation, ...}
DEBUG resource checker wait condition...                   (x12, all at 03:29:12-13Z)
DEBUG check resource field value...                        (x12, same window)
DEBUG cleaning up namespace ...
```

Then move to the next scenario. The `check resource field value` polls
~12 times in 1 second window and bails — the framework's
`<retryUntilTimeout> interval=2s timeout=30s` should poll every 2s for
30s, so 12 polls in 1s suggests something different is happening (maybe
each row of the table is queried in parallel, OR the poller fires a
burst then short-circuits when one row returns "definitive false").

The `config generator not found` warnings likely come from
`task.yaml`'s descriptors carrying literal `<tenant>-bot` and
`<tenant>-template` strings (the descriptor text intended for the
Tekton dynamic-form UI) — the BDD framework's template substitution
sees `<tenant>` / `<name>` and looks up a config generator with that
name. Harbor's task.yaml has similar literals (`<namespace>/<name>`,
`<resource>:<verb>`) and works, so the warnings might be benign. **But
the fast-fail still happens with a single-CEL row of `size(obj.spec.params) == 11`**, so the cause is NOT just the multi-row CEL bugs we
already fixed.

### 3.2 Hypotheses to investigate

1. **Task object mutation during import**. The BDD framework's
   `已导入 X 资源: "../../task.yaml"` may rewrite descriptor strings
   containing `<X>` placeholders during import — possibly producing a
   Task whose count/shape differs from the file. Run locally: import the
   Task via the same step + `kubectl get task <name> -o yaml` and diff
   against `task.yaml`. If `size(obj.spec.params) != 11` after import,
   that's the bug.
2. **Multi-row CEL evaluation timing**. The framework may not be
   running rows sequentially with 2s intervals; it could be batching
   one cycle, returning early on the first false. Validate by writing a
   pass-by-construction CEL `1 == 1` — if THAT also fails, the issue is
   architectural (resource not visible to BDD client), not CEL-content.
3. **Namespace permission lag**. Right after `已导入`, the Task may not
   yet be visible to the framework's CEL evaluator (cache lag). The
   framework's `wait condition` should handle this but might not.

### 3.3 What's been rewritten and is incomplete

- `0.1/testing/features/tektoncd.feature` — currently 1 contract
  scenario (single-row CEL, bisecting); 3 other contract scenarios
  (workspaces / results / steps) and the 12 e2e scenarios are commented
  out. Original aspirational gherkin from Story 2 was wiped because the
  step phrases were free-form and not in the framework's built-in
  registry (`steps.BuiltinSteps`).
- `0.1/testing/features/script.feature` — **not yet rewritten**.
  Currently tagged `@manual` so PaC skips it. The full plan
  (positive + negative cases per script, Pod-based fixtures mirroring
  `connectors-harbor/.../testing/testdata/script/X/*.pod.yaml`) is
  scoped but not coded.

## 4. Recommended next steps for the local-kind handoff

### 4.1 Smoke-test the BDD framework against a known-good task locally

```bash
# in connectors-extensions/
cd connectors-sonarqube/tektoncd/testing
make build                # compile BDD binary (Go 1.26+ required)

# spin up a fresh kind cluster (matching PaC's `kind` task config)
kind create cluster --name sonar-bdd-iter --config <kind-config.yaml>
kubectl config use-context kind-sonar-bdd-iter

# install cert-manager + Tekton + connectors operator
# (mirror the deploy-dependency from
#  .tekton/connectors-sonarqube/sonarqube-connector-automatic-creation.yaml)
make -C ../../.. certmanager
TEKTON_VERSION=release-1.6
curl -O https://build-nexus.alauda.cn/repository/alauda/devops/tektoncd-releases/tektoncd-pipeline/${TEKTON_VERSION}/pipeline/release.yaml
sed -i 's_build-harbor.alauda.cn/_registry.alauda.cn:60070/_g' release.yaml
kubectl apply -f release.yaml
CONNECTORS_BRANCH=main make -C ../../.. deploy-connectors

# create test namespace, install Task + image ConfigMaps
kubectl create ns bdd-testing
kubectl config set-context --current --namespace=bdd-testing
make -C .. dist
kubectl apply -f ../dist/install.yaml

# run the BDD with verbose godog output (NO --godog.format=allure)
go test -timeout=1h -v -count 1 . \
  --godog.format=pretty \
  --godog.tags="@sonarqube-connector-automatic-creation"
```

`--godog.format=pretty` is the key change vs PaC — it prints per-scenario
PASS/FAIL/UNDEFINED + the FAILING ASSERTION TEXT. PaC uses `=allure`
which buries assertion errors in JSON artifacts.

### 4.2 Bisect CEL until one PASSES, then add complexity

Start with a TRIVIAL true assertion to confirm framework + Task plumbing:

```gherkin
那么 资源检查通过
  | kind | apiVersion    | namespace   | name                                   | cel    | interval | timeout |
  | Task | tekton.dev/v1 | <namespace> | sonarqube-connector-automatic-creation | 1 == 1 | 2s       | 30s     |
```

If this still FAILS, the framework can't find the Task at all (look at
the importer's resource-name resolution, namespace, or RBAC). If it
PASSES, incrementally re-add the size + per-param checks.

### 4.3 Once contract scenarios pass, rewrite script.feature

Mirror this Harbor file 1:1:
`connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/testing/features/script.feature`

For each helper script, create a `testdata/script/<script-name>/<scenario>.pod.yaml`
that:
- uses the new image `registry.alauda.cn:60070/devops/sonarqube-connector-automatic-creation:latest`
- injects env vars / fake workspace files via volumeMounts
- runs `bash -c '<exact command to exercise the script>'`
- exits 0 (positive) or non-zero (negative)

Coverage matrix is fully listed in the Discord transcript and
`bdd-scratch.md`. The high-level set:

- `lib.sh::derive_names` — happy + 4 negatives
- `lib.sh::compute_token_expiry` — happy + 4 negatives
- `lib.sh::is_token_due_for_renewal` — 6-row matrix
- `lib.sh::_props_get` — 4 cases
- `lib.sh::load_admin_credentials` Mode A token / userpass / mode B / SONARQUBE_URL override / missing-everything (5 cases)
- `ensure-template.sh` arg validation: admin-rejection (2 negative) + default-set (1 positive)
- `apply-kubernetes-resources.sh` state machine: minted / reused / unknown (3)
- `write-results.sh` happy + missing-env (2)

### 4.4 Add ONE @p0 happy-path TaskRun scenario in tektoncd.feature

After contract + script are green. Background imports
`testdata/apply-script-rbac.yaml` + `testdata/sonarqube-config-secret.yaml`
+ runs `sonarqube-tenant-offboard.sh` for the fixed tenant prefix
(pre-clean). Scenario creates a TaskRun, waits Succeeded, asserts
Connector + Secret + SonarQube user/template/token via the BDD HTTP
steps (per
[bdd/docs/references/steps.md](https://github.com/AlaudaDevops/bdd/blob/main/docs/references/steps.md)).
Final step runs the offboard script again (idempotency check + cleanup
for next run).

The 19 SonarQube API endpoints + their data shapes are listed in the
Discord transcript under the "SonarQube API call inventory" reply.

### 4.5 Wire SonarQube test instance credentials into PaC

The release-e2e-test-config ConfigMap exposes `<config.{{.toolchains.X.endpoint}}>`
templating to the BDD harness. Add `toolchains.sonarqube.endpoint` +
`toolchains.sonarqube.token`. kychen owns this side (URL + admin token
+ confirming SCIM is OFF).

## 5. Open questions kychen needs to answer

| # | Question | Why |
|---|---|---|
| Q1 | Fixed TENANT prefix? Candidates: `bdd-sonarqube` / `bdd-test-sonar` / `devops-43953-bdd` | Per kychen's instruction "用固定前缀，因为清理脚本会清理" — all BDD scenarios share this prefix so the offboard pre/post-clean catches everything |
| Q2 | Test SonarQube URL + admin token + confirm SCIM is OFF | For the @p0 happy-path TaskRun scenario (and any other API-asserting tests) |
| Q3 | Run @p0 e2e in PaC automation or @manual only? | kychen earlier said "@p0 just write, 手动执行" then later "如果 kind 装了 Tekton tektoncd.feature 也可以跑". Latest reading: contract scenarios in PaC, @p0 TaskRun execution @manual against test SonarQube |

## 6. Tools + access available to anyone picking this up

- `gh` CLI authenticated as kycheng (scopes: `repo,workflow,gist,read:org`)
- `edge.alauda.cn` Bearer token at `/tmp/.edge_token` (long-lived; expires 2029) — read access to build-cluster's tekton.dev resources + pod logs
- `jira` CLI configured via `JIRA_BASE_URL`/`JIRA_USER`/`JIRA_PASSWORD` in `/workspaces/.claude/credentials.env`
- `git` credential helper points at `gh` so any push to either repo works
- All three connectors-* repos cloned under `/workspaces/`
- Memory entries persist at `/workspaces/.claude/projects/-workspaces-connectors-operator/memory/`
  (notable: `sonarqube-integration-test-fragility.md`, `cross-fork-pr-fallback.md`,
  `edge-alauda-api-access.md`)

## 7. Reference paths

| What | Where |
|---|---|
| Containerfile | `connectors-extensions/connectors-sonarqube/tektoncd/tasks/sonarqube-connector-automatic-creation/0.1/images/sonarqube-connector-automatic-creation/Containerfile` |
| 9 helper scripts | same dir, `scripts/{lib.sh,rollback.sh,ensure-user.sh,ensure-template.sh,ensure-token.sh,ensure-tenant.sh,apply-kubernetes-resources.sh,apply-step.sh,write-results.sh}` |
| Rendered task | `.../sonarqube-connector-automatic-creation/0.1/task.yaml` (NO template, hand-edited) |
| BDD harness | `.../sonarqube-connector-automatic-creation/0.1/testing/features/{tektoncd.feature,script.feature}` |
| Offboard script | `.../sonarqube-connector-automatic-creation/0.1/samples/sonarqube-tenant-offboard.sh` |
| PaC pipeline | `connectors-extensions/.tekton/connectors-sonarqube/sonarqube-connector-automatic-creation.yaml` |
| Top-level Task Makefile | `connectors-extensions/connectors-sonarqube/tektoncd/Makefile` (build-image / set-image-config / dist targets) |
| Image config CMs | `.../sonarqube-connector-automatic-creation/config/images/{0.1.0.yaml,latest.yaml,kustomization.yaml}` |
| Feature umbrella (this doc lives here) | `connectors-operator/docs/en/design/devops-43953-sonarqube-auto-create-project-connector/` |
| poc.md §5 offboard outline | same dir, `poc.md` |
| product-design.md §4.1 SCIM caveat | same dir, `product-design.md` |
| review-iteration-1 design delta | same dir, `review-iteration-1.md` |
| BDD step reference | https://github.com/AlaudaDevops/bdd/blob/main/docs/references/steps.md |

## 8. Status of in-flight PaC runs (cleaned up)

All in-flight PaC PipelineRuns on PR #325 have been **cancelled** as of
2026-05-26 ~03:58 UTC (latest: `sonarqube-connector-automatic-creation-9fpjd`
on SHA `e8f9c38`). No active jobs eating build-cluster resources. Re-trigger
with `gh pr comment 325 --repo AlaudaDevops/connectors-extensions --body
"/sonarqube-connector-automatic-creation"` when the local-kind iteration
loop produces a candidate worth re-validating in CI.
