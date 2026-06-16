# Review Iteration 1 — design delta (DEVOPS-43953)

**Driver**: kychen
**Opened**: 2026-05-25 (Discord async review of PR #325)
**Scope**: 9 review comments from kychen against PR
`AlaudaDevops/connectors-extensions#325` (Story 1+2 consolidated).

All deltas land in `connectors-extensions` (the same PR). No changes to
`connectors-operator` are in scope for this iteration.

## 1. `TOKEN_MODE` rename + reuse-path comment (review #1)

`/workspace/state/token-mode` is renamed to `/workspace/state/token-action`.
Value space unchanged: `minted | reused`.

`scripts/apply-kubernetes-resources.sh` gains an ASCII state-machine
comment at the top documenting the path matrix:

```text
ensure-token writes token-action  -> apply step behaviour
   minted                         -> SSA Secret + Connector
   reused                         -> SSA Connector only (skip Secret rewrite)
```

The reuse optimisation stays. Rationale: rewriting an unchanged
`stringData.token` triggers a Secret revision bump and re-fires every
watcher that selects on the tenant Secret; the cron use-case re-runs
the Task daily, so the noise compounds.

## 2. Template defaults — drop admin-shaped permissions (review #2)

Default of `templatePermissions` becomes `["user","codeviewer","scan"]`.
Removed: `issueadmin`, `securityhotspotadmin`. The operator-of-record
can still opt in by overriding the param at TaskRun time. The
existing `admin` rejection in `scripts/ensure-template.sh` stays.

Affected files:
- `scripts/ensure-template.sh` (default const + sample-output strings)
- `task.template.yaml` (param default + description)
- `samples/onboard-csi.yaml` + `samples/onboard-secret.yaml`
  (if they pass the param explicitly)
- `testing/features/*.feature` cases that assert default permissions

## 3. Token-expiry renewal (review #3)

`scripts/ensure-token.sh` gains an expiry check on the reuse path. New
helper in `lib.sh::is_token_due_for_renewal`:

```bash
# Echoes "renew" when expirationDate is missing, malformed, already
# past, or less than 1 day in the future.
is_token_due_for_renewal() {
  local exp="$1"
  [ -z "$exp" ] && { echo renew; return; }
  local today_plus_one
  today_plus_one="$(date -u -d '+1 day' +%Y-%m-%d 2>/dev/null \
    || date -u -v+1d +%Y-%m-%d)"
  if [ "$exp" \< "$today_plus_one" ]; then echo renew; fi
}
```

`ensure-token.sh` calls `user_tokens/search?login=${USER}` (existing),
extracts the named token's `expirationDate`, and calls
`is_token_due_for_renewal`. If `renew` is echoed, the script revokes
the existing token and mints a new one (existing mint path).

Threshold rationale: GitLab's `is_expired_now` is strict ("already
expired"). Harbor uses `-1` for non-expiring and has no renewal
logic. The < 1 day threshold prevents a same-day-rerun from missing
the rotation window when the previous run minted with default
`tokenDuration=30` minus an off-by-one. Tighter than GitLab,
weaker than "always renew", honours the cron rerun pattern.

## 4. Group-membership invariant — keep as-is (review #4)

No change. `scripts/ensure-user.sh` continues to reject group
memberships outside `sonar-users`. Reaffirmed: the invariant catches
operator-error grants made between runs (someone manually adds the
bot to a project-group with template grants) which would silently
widen the tenant scope. The check is cheap (1 API call) and the
error message is self-documenting.

## 5. Dual-mode credential loading (review #5) — **B2 chosen**

`lib.sh::load_admin_credentials` learns a second projection shape.

**Mode A (existing — file-pair projection)**:
- `${SONAR_CONFIG_DIR}/address` — base URL
- `${SONAR_CONFIG_DIR}/token` OR `${SONAR_CONFIG_DIR}/username` +
  `${SONAR_CONFIG_DIR}/password` — credentials
- `api()` calls SonarQube directly with `--user` / token user
- Workspace target for Secret-direct mounts and the legacy CSI
  projection that emits raw address+credential files.

**Mode B (new — `sonar-scanner` configuration projection)**:
- `${SONAR_CONFIG_DIR}/sonar-project.properties` — the rendered
  template from the `sonarqube` ConnectorClass's
  `configurations[0].name: sonar-scanner` data block. Contents:
  ```properties
  sonar.host.url=<connector.spec.address>
  sonar.scanner.proxyHost=<connector.status.proxyAddress host>
  sonar.scanner.proxyPort=<port>
  sonar.scanner.proxyUser=<ns/name>
  sonar.scanner.proxyPassword=<token>
  ```
- `api()` proxies through `${proxyHost}:${proxyPort}`. The proxy
  injects the `Authorization: Basic …` header per the ConnectorClass
  rego generator. The Task pod sees no credential material.

Mode selection precedence in `load_admin_credentials`:
1. If `${SONAR_CONFIG_DIR}/sonar-project.properties` exists → Mode B
2. Else if `${SONAR_CONFIG_DIR}/address` exists → Mode A
3. Else hard fail with a message that names both shapes.

Mode B's contract:
- `proxyUser` and `proxyPassword` fields are read by the proxy, NOT
  by the Task. The Task strips them before logging; they MUST NOT
  leak via `set -x` or `kubectl get pod -o yaml`.
- `address` is canonicalised by stripping the trailing slash to match
  Mode A behaviour.
- Liveness / preflight semantics are unchanged: the Task still
  validates Administer System on the admin login, but the admin's
  identity is now whoever the proxy authenticates as.

Why B2 (and not B1 `kubectl get connector`):
- No new RBAC. B1 needs `get connectors.alauda.io/connectors`
  (the SA already creates them, but the existing
  testdata/apply-script-rbac.yaml has not been updated for read).
- ConnectorClass already templates `sonar-project.properties` with
  address + proxy in one file. Re-deriving the same fields in the
  Task is duplication.
- Pod is required to reach the proxy in proxy mode either way; CSI
  mount is the only standard way to learn the proxy address.

## 6. `templatePermissions` typed as array (review #6)

Param `templatePermissions` changes from `type: string` (comma-
separated) to `type: array` with default `["user","codeviewer","scan"]`.
The Tekton webhook rejects array expansion in `env` values, so the
permissions arrive as positional args via `args: -
$(params.templatePermissions[*])` (same idiom as GitLab's
`scopes` and `subgroups`).

`ensure-template.sh` switches from splitting `$TEMPLATE_PERMS` on
comma to iterating `"$@"` positional args. The `admin` rejection
check moves to a per-element loop.

## 7. Dynamic-form annotations (review #7)

`metadata.annotations` gains:
- `style.tekton.dev/displayParams` — comma-separated param order
  for the form
- `style.tekton.dev/descriptors` — multiline YAML with one
  `x-descriptors:` block per param

Convention mirrored from
`connectors-harbor/tektoncd/tasks/harbor-connector-automatic-creation/0.1/harbor-connector-automatic-creation.yaml`:

| Param | Widget | Notes |
|---|---|---|
| `connector` | text + validation:required | `<ns>/<name>` regex hint in tooltip |
| `tenant` | text + validation:required | |
| `projectPattern` | text + validation:required | example regex in tooltip |
| `permissionTemplate` | text | derived default `<tenant>-template` in description |
| `templatePermissions` | text-array (multi-add) | per-element select isn't supported in current UI; render as free-form array |
| `userName` | text | derived default `<tenant>-bot` |
| `tokenDuration` | text + numeric validation | days |
| `toolImage` | image-picker (Harbor-style) | `labelSelector=catalog.tekton.dev/tool-image-kubectl` |
| `imagePullPolicy` | select Always/IfNotPresent/Never | default Always |
| `verbose` | select true/false | default false |

## 8. Inline preamble → wrapper scripts (review #8)

Each step's `script:` field collapses to a single
`{{ INCLUDE: scripts/<step>.sh }}` line. Two new wrapper scripts:

- `scripts/ensure-tenant.sh`
  - `set -euo pipefail` + sources `lib.sh` + `rollback.sh`
  - Installs the EXIT trap that dispatches `rollback_step` on
    non-zero exit
  - Calls in order: `ensure-user.sh`, `ensure-template.sh`,
    `ensure-token.sh`
- `scripts/apply-step.sh`
  - `set -euo pipefail` + sources `lib.sh`
  - Exports `KUBECONFIG=${WORKSPACE_KUBECONFIG_PATH}/kubeconfig`
    when the optional kubeconfig workspace is bound
  - Calls `apply-kubernetes-resources.sh`

`write-results.sh` self-defaults `SONAR_CONFIG_DIR=/dev/null` at its
top so the inline workaround in the template disappears.

`hack/render-task.sh` already handles arbitrary `{{ INCLUDE }}`
directives; no render-tool changes needed.

## 9. `openspec/changes/` files — keep (review #9)

No change. The directory pattern matches the already-merged
`openspec/changes/gitlab-connector-automatic-creation-task*` from
DEVOPS-43146; removing only the SonarQube set would break consistency
without an alternative location, since
`connectors-extensions` does not host `docs/en/design/`.

## Implementation order

1. `scripts/lib.sh` — Mode B detection, parser, proxy-aware `api()`,
   `is_token_due_for_renewal`, rename `token-mode` → `token-action`
2. `scripts/ensure-user.sh` — no logic change (#4 is a no-op)
3. `scripts/ensure-template.sh` — positional args, default permission
   set (#2 + #6)
4. `scripts/ensure-token.sh` — wire `is_token_due_for_renewal` into
   the reuse path (#3)
5. `scripts/apply-kubernetes-resources.sh` — rename + state-machine
   comment (#1)
6. New `scripts/ensure-tenant.sh` + `scripts/apply-step.sh` (#8)
7. `scripts/write-results.sh` — self-default `SONAR_CONFIG_DIR` (#8)
8. `task.template.yaml` — param shape change (#6), dynamic-form
   annotations (#7), inline preamble removal (#8), Mode B-aware
   workspace description
9. `make render` → regenerate `task.yaml`
10. `testing/features/*.feature` + `testdata/bootstrap-fixtures.sh` —
    cover Mode B parse, expiry renewal, array param
11. Local `make test` (kind cluster) if reachable, else rely on PR CI
12. Commit (3 commits, one per logical layer) + push to
    `kycheng/connectors-extensions feature/...`; PR #325 updates
    automatically

## Out of scope for this iteration

- Cross-repo: any `connectors-operator` doc-sync side (Story 3
  belongs to a follow-up iteration of /feature:implement, not this
  review delta).
- `connectorclass.yaml` itself — the `sonar-scanner` configuration
  already exists; this iteration only consumes it.
- Threat-model.md updates — Mode B narrows the credential surface
  (Task pod no longer sees the token); a positive but minor delta to
  fold during /feature:design when this iteration archives.

## Risks

- `sonar-project.properties` parsing is line-based grep; values with
  `=` (e.g., `?param=` in URLs) need to use `cut -d= -f2-`, not
  `awk '{print $2}'`. Covered with a BDD scenario.
- `--proxy` of `curl` does not understand `https://` proxy URLs the
  same way scanners do; we pass `host:port` only. If the proxy
  service requires TLS, set `proxy = "https://host:port"` in the
  `--config` block. Covered by integration BDD.
- Image-picker descriptors require the cluster catalog to publish a
  `tool-image-kubectl` ConfigMap. Already present on the build
  cluster (verified during POC); the form falls back to free text
  on clusters without it.
