# Acceptance — Nexus 自动创建 Project + Connector + Secret

<!-- Output of /feature:accept. AC-by-AC pass/fail mapped to BDD results. -->

## Summary

- **Total ACs:** 9
- **Pass:** 9  **Fail:** 0  **Unverified:** 0
- **Overall status:** passed

ACs come from `product-design.md ## 对 Jira AC 的覆盖与改写` (9-row table with
explicit reframe rationale for AC-3 / AC-4 / AC-7 / AC-8). BDD evidence is the
nexus-connector-automatic-creation Task suite in
`connectors-extensions/connectors-nexus/tektoncd/tasks/nexus-connector-automatic-creation/0.1/testing/features/`,
last run green at 29/29 twice consecutively on PR #332 commit `c5808a7` (PaC
runs `nexus-connector-automatic-creation-2qlpr` + `-ckqrm`, 2026-05-28).

Bundle under test:
`build-harbor.alauda.cn/devops/connectors-operator-bundle:v1.11.0-beta.173.g15aaded@sha256:34827db4...`
(recorded at `/feature:integrate`; carries the polished Task install.yaml
synced via PR #1198).

## Per-AC results

### AC-1 — Nexus repository can be created automatically via Task for a given Project / namespace

- **BDD scenario(s):** TC1 (Task params contract), TC2 (workspaces contract), TC3 (results + steps shape), TC4 (multi-format provisioning end-to-end)
- **BDD outcome:** pass
- **Evidence:** [allure ngcw5](http://192.168.186.151:32493/data/backend-test/20260528012551-nexus-connector-automatic-creation-ngcw5/) · [allure 2qlpr](http://192.168.186.151:32493/data/backend-test/20260528030748-nexus-connector-automatic-creation-2qlpr/)
- **Status:** pass

### AC-2 — Project-scoped credentials are created with repository-specific permissions

- **BDD scenario(s):** TC4 (end-to-end including user + role + per-repo privilege + Secret writeback), TC7 (scoped user can act within listed repo's allowed actions), TC15 (rerun PUT-refresh + password rotate), TC21 (scoped user gains entry.actions on newly added repo)
- **BDD outcome:** pass
- **Evidence:** [allure ngcw5](http://192.168.186.151:32493/data/backend-test/20260528012551-nexus-connector-automatic-creation-ngcw5/) — TC4/TC7/TC15/TC21 all green
- **Status:** pass

### AC-3 — Parent project has access to shared resources (base artifacts / proxies)

> Reframed: Nexus has no parent-project primitive. Equivalent semantics —
> consumer tooling configs (settings.xml / .npmrc / pip.conf) merge access
> to project hosted repos and shared upstream proxy repos via the
> Connector's nexusconfig rendering. The acceptance signal is that a
> reference-mode entry (existing shared upstream proxy) gets its
> privileges linked to the scoped user alongside provisioned entries.

- **BDD scenario(s):** TC6 (provision + reference mixed array with inline actions — the reference entry is the shared upstream proxy whose privileges must be granted to the scoped user)
- **BDD outcome:** pass
- **Evidence:** [allure ngcw5](http://192.168.186.151:32493/data/backend-test/20260528012551-nexus-connector-automatic-creation-ngcw5/) — TC6 green; tooling-config rendering itself is covered by the existing nexus ConnectorClass test suite (`script.feature` configuration-* scenarios), out of scope for this Task's BDD
- **Status:** pass

### AC-4 — Namespace projects have restricted access to their own repositories

> Reframed: namespace-vs-parent hierarchy not native to Nexus. Equivalent
> semantics — scoped user's read/write is strictly bounded by Nexus
> content-selector path prefix (or whole repo, for non-CSEL formats).
> Verified positively (user can act inside scope) AND negatively (user
> CANNOT act outside scope).

- **BDD scenario(s):** TC8 (scoped user has NO permission on repos not listed in nexusRepositories — covers PUT 403 / GET 404 / repo-delete 403 / repo-create 403 from product-design's live-validation set), TC22 (second run that removes a repo → scoped user loses access to that repo)
- **BDD outcome:** pass
- **Evidence:** [allure 2qlpr](http://192.168.186.151:32493/data/backend-test/20260528030748-nexus-connector-automatic-creation-2qlpr/) — TC8/TC22 green
- **Status:** pass

### AC-5 — Connector + Secret reconciled into the right namespace as part of provisioning

> Clarified per product-design: "right namespace" = the connector's
> namespace (extracted from the `connector` param's `<ns>/<name>` form),
> matching the harbor / gitlab precedent. Both modes of workspace
> binding (BasicAuthSecret vs ConnectorRef) must produce the same
> Connector + Secret outcome.

- **BDD scenario(s):** TC4 (multi-format end-to-end produces Connector + Secret in the connector namespace), TC9 (BasicAuthSecret mode workspace happy path), TC10 (ConnectorRef CSI mode end-to-end including proxy MITM CA trust via `--cacert $STATE_PROXY_CACERT`), TC9c (BOTH-mode marker collision picks ConnectorRef + log_warn, sub-aspect of mode detection), TC18 (kubectl auth preflight failure fast-fails step 3 instead of partial-write into the wrong namespace)
- **BDD outcome:** pass
- **Evidence:** [allure ngcw5](http://192.168.186.151:32493/data/backend-test/20260528012551-nexus-connector-automatic-creation-ngcw5/) — all five scenarios green
- **Status:** pass

### AC-6 — Error handling for API failures and permission conflicts

- **BDD scenario(s):** TC11 (immutable-field diff at second run → fail-fast with actionable hint), TC12 (Nexus 404 on unknown format/type → actionable hint), TC12b (reference entry that doesn't exist on Nexus → fail with hint), TC13 (missing required key in provision entry → early fail), TC13b (invalid YAML in nexusRepositories → yq-error hint), TC14 (squatter Role owned by someone else → fail), TC14b (PUT-refresh + rotate on owned User), TC14c (squatter User without our Role → fail), TC9b (missing-file fast-fail in BasicAuthSecret mode), TC3b (no password leak in Task results), TC3c (no password leak in verbose-mode step log)
- **BDD outcome:** pass
- **Evidence:** [allure ngcw5](http://192.168.186.151:32493/data/backend-test/20260528012551-nexus-connector-automatic-creation-ngcw5/) — 10/10 scenarios green
- **Status:** pass

### AC-7 — Rollback mechanism for failed repository / credential creation

> Reframed: Nexus REST has no transaction endpoint. Equivalent semantics
> — idempotent rerun + GET-first detection lets a partial-failure state
> self-heal on the next TaskRun. Verified via two TCs: clean rerun (TC5)
> and partial-state-already-on-Nexus rerun (TC16).

- **BDD scenario(s):** TC5 (Task input unchanged → rerun converges to stable state without creating new privileges), TC16 (some repos already exist when rerun starts → walks "exists + refresh" path to self-heal), TC23 (second run with updated mutable fields → updates land on Nexus side)
- **BDD outcome:** pass
- **Evidence:** [allure ngcw5](http://192.168.186.151:32493/data/backend-test/20260528012551-nexus-connector-automatic-creation-ngcw5/) — TC5/TC16/TC23 green
- **Status:** pass

### AC-8 — Integration tests cover multi-level hierarchy scenarios

> Reframed: "multi-level hierarchy" not native to Nexus. Equivalent
> coverage = multi-project × multi-format × scoping combinations. The
> full BDD suite (29 scenarios across `tektoncd.feature` + `script.feature`)
> exercises maven2/npm/raw/pypi format dispatch under both mode A
> (basic-auth) and mode B (ConnectorRef CSI), with concurrent runs and
> rerun-self-heal explicitly verified.

- **BDD scenario(s):** TC4 (multi-format dispatch), TC6 (provision + reference mixed), TC16b (concurrent TaskRuns with the same input both succeed), plus the entire 29-scenario suite as the implicit cross-product
- **BDD outcome:** pass
- **Evidence:** [allure ngcw5](http://192.168.186.151:32493/data/backend-test/20260528012551-nexus-connector-automatic-creation-ngcw5/) — 29/29 green; concurrency case TC16b explicitly verified
- **Status:** pass

### AC-9 — Documentation includes Nexus API usage and examples

> Operator-side artifact (out of the extensions BDD scope). Delivered via
> PR #1198 (connectors-operator) which lands the user-facing how-to page
> + reference page under `docs/en/connectors-nexus/how_to/` plus the
> hack scripts that auto-sync the rendered Task install.yaml + this
> doc surface from extensions. Doc PR was driver-reviewed and merged
> 2026-05-28T11:42:27Z.

- **BDD scenario(s):** N/A — documentation artifact, not a runtime contract
- **BDD outcome:** N/A
- **Evidence:** [connectors-operator PR #1198](https://github.com/AlaudaDevops/connectors-operator/pull/1198) (merged 2026-05-28); see `docs/en/connectors-nexus/how_to/using_nexus_connector_automatic_creation_task.mdx` + `docs/en/connectors-nexus/how_to/nexus_connector_automatic_creation_task.mdx`
- **Status:** pass

## Failing ACs (if any)

None.

## Reviewer

- **Accept reviewer:** jtcheng (driver, one-hat per feature-flow profile=standard policy)
- **Signed at:** 2026-05-28T12:08:00Z
