#!/usr/bin/env bash
# POC spike for DEVOPS-43953 — SonarQube auto-create Project + Connector + Secret.
#
# THROWAWAY. Not production code, not the shipped Task. This single file
# mirrors the design's helper-script decomposition as functions so the
# end-to-end flow can be run and observed against a real SonarQube + cluster.
#
# Subcommands:
#   flow           create-or-reuse project + permission template + token + k8s resources
#   rollback-demo  run the flow with an injected failure; show rollback unwind
#   cleanup        revoke tokens / delete project + template / delete k8s resources
#
# Driven by env vars (see defaults below). Credentials never appear in argv:
# the SonarQube admin user lives in a curl --config file; the cluster creds in
# a kubeconfig. Tokens are masked in all log output.
set -Eeuo pipefail

SONAR_URL="${SONAR_URL:-https://devops-sonar.alaudatech.net}"
CURL_CFG="${CURL_CFG:-/tmp/poc-devops-43953/curl.cfg}"
# Pinned via POC_KUBECONFIG (not KUBECONFIG) so an ambient KUBECONFIG can't shadow it.
export KUBECONFIG="${POC_KUBECONFIG:-/tmp/poc-devops-43953/kubeconfig.yaml}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-direct-connect}"   # proxy-connect context is flaky

PROJECT_KEY="${PROJECT_KEY:-poc-devops-43953}"
PROJECT_NAME="${PROJECT_NAME:-POC DEVOPS-43953}"
SCOPE="${SCOPE:-parent}"                       # parent | namespace
PERMISSION_TEMPLATE="${PERMISSION_TEMPLATE:-poc-43953-${SCOPE}}"
QUALITY_GATE="${QUALITY_GATE:-Sonar way}"      # assigned for scope=parent
TARGET_NS="${TARGET_NS:-kychen}"
CONNECTOR_NAME="${CONNECTOR_NAME:-$(printf '%s' "$PROJECT_KEY" | tr ':_' '--')-sonarqube}"
SECRET_NAME="${SECRET_NAME:-${CONNECTOR_NAME}-secret}"
TOKEN_NAME="${TOKEN_NAME:-connector-${TARGET_NS}-${CONNECTOR_NAME}}"
STATE_FILE="${STATE_FILE:-/tmp/poc-devops-43953/state-$(printf '%s' "$PROJECT_KEY" | tr ':' '-').env}"
INJECT_FAILURE="${INJECT_FAILURE:-false}"

log()  { printf '[poc] %s\n' "$*" >&2; }
ok()   { printf '[poc]  \033[32mOK\033[0m  %s\n' "$*" >&2; }
fail() { printf '[poc] \033[31mERR\033[0m  %s\n' "$*" >&2; exit 1; }

# curl wrapper — admin creds come from CURL_CFG, never argv. Echoes "BODY<NL>HTTP".
sq() {
  local method="$1" path="$2"; shift 2
  curl -sS -m 30 -K "$CURL_CFG" -X "$method" -w '\n%{http_code}' "$SONAR_URL$path" "$@"
}
http_code() { printf '%s' "$1" | tail -n1; }
http_body() { printf '%s' "$1" | sed '$d'; }
mask()      { sed -E 's/(sq[apu]_)[A-Za-z0-9]+/\1***masked***/g'; }

# --- rollback state: only resources created THIS run are recorded -------------
state_init()   { : > "$STATE_FILE"; }
state_mark()   { printf '%s\n' "$1" >> "$STATE_FILE"; }
state_has()    { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }

rollback() {
  log "---- ROLLBACK: unwinding resources created this run ----"
  if state_has "token:${TOKEN_NAME}"; then
    sq POST "/api/user_tokens/revoke" --data-urlencode "name=${TOKEN_NAME}" >/dev/null && \
      log "rollback: revoked token ${TOKEN_NAME}"
  fi
  if state_has "project:${PROJECT_KEY}"; then
    sq POST "/api/projects/delete" --data-urlencode "project=${PROJECT_KEY}" >/dev/null && \
      log "rollback: deleted project ${PROJECT_KEY}"
  fi
  if state_has "template:${PERMISSION_TEMPLATE}"; then
    sq POST "/api/permissions/delete_template" --data-urlencode "templateName=${PERMISSION_TEMPLATE}" >/dev/null && \
      log "rollback: deleted permission template ${PERMISSION_TEMPLATE}"
  fi
  log "---- ROLLBACK complete (reused/pre-existing resources untouched) ----"
}

# ============================ flow steps ====================================

ensure_project() {
  log "ensure-project: key=${PROJECT_KEY}"
  local r; r="$(sq GET "/api/projects/search?projects=${PROJECT_KEY}")"
  [ "$(http_code "$r")" = 200 ] || fail "projects/search HTTP $(http_code "$r"): $(http_body "$r")"
  if http_body "$r" | grep -q "\"key\":\"${PROJECT_KEY}\""; then
    ok "project already exists — reusing (not recorded for rollback)"
    return
  fi
  r="$(sq POST "/api/projects/create" \
        --data-urlencode "project=${PROJECT_KEY}" \
        --data-urlencode "name=${PROJECT_NAME}")"
  [ "$(http_code "$r")" = 200 ] || fail "projects/create HTTP $(http_code "$r"): $(http_body "$r")"
  state_mark "project:${PROJECT_KEY}"
  ok "project created — recorded for rollback"
}

ensure_permissions() {
  log "ensure-permissions: scope=${SCOPE} template=${PERMISSION_TEMPLATE}"
  local r; r="$(sq GET "/api/permissions/search_templates?q=${PERMISSION_TEMPLATE}")"
  if ! http_body "$r" | grep -q "\"name\":\"${PERMISSION_TEMPLATE}\""; then
    r="$(sq POST "/api/permissions/create_template" \
          --data-urlencode "name=${PERMISSION_TEMPLATE}" \
          --data-urlencode "description=POC DEVOPS-43953 ${SCOPE} template")"
    [ "$(http_code "$r")" = 200 ] || fail "create_template HTTP $(http_code "$r"): $(http_body "$r")"
    state_mark "template:${PERMISSION_TEMPLATE}"
    ok "permission template created — recorded for rollback"
  else
    ok "permission template already exists — reusing"
  fi
  r="$(sq POST "/api/permissions/apply_template" \
        --data-urlencode "templateName=${PERMISSION_TEMPLATE}" \
        --data-urlencode "projectKey=${PROJECT_KEY}")"
  [ "$(http_code "$r")" = 204 ] || [ "$(http_code "$r")" = 200 ] \
    || fail "apply_template HTTP $(http_code "$r"): $(http_body "$r")"
  ok "permission template applied to project"

  if [ "$SCOPE" = parent ]; then
    r="$(sq POST "/api/qualitygates/select" \
          --data-urlencode "gateName=${QUALITY_GATE}" \
          --data-urlencode "projectKey=${PROJECT_KEY}")"
    if [ "$(http_code "$r")" = 204 ] || [ "$(http_code "$r")" = 200 ]; then
      ok "shared quality gate '${QUALITY_GATE}' assigned (scope=parent)"
    else
      log "quality gate select HTTP $(http_code "$r") — non-fatal for POC: $(http_body "$r" | head -c160)"
    fi
  fi

  if [ "$INJECT_FAILURE" = permissions ]; then
    fail "INJECT_FAILURE=permissions — simulated permission-step failure"
  fi
}

ensure_token() {
  log "ensure-token: name=${TOKEN_NAME} type=PROJECT_ANALYSIS_TOKEN"
  local r; r="$(sq GET "/api/user_tokens/search")"
  if http_body "$r" | grep -q "\"name\":\"${TOKEN_NAME}\""; then
    log "ensure-token: a token named ${TOKEN_NAME} exists — revoking before mint"
    sq POST "/api/user_tokens/revoke" --data-urlencode "name=${TOKEN_NAME}" >/dev/null
  fi
  r="$(sq POST "/api/user_tokens/generate" \
        --data-urlencode "name=${TOKEN_NAME}" \
        --data-urlencode "type=PROJECT_ANALYSIS_TOKEN" \
        --data-urlencode "projectKey=${PROJECT_KEY}")"
  [ "$(http_code "$r")" = 200 ] || fail "user_tokens/generate HTTP $(http_code "$r"): $(http_body "$r")"
  state_mark "token:${TOKEN_NAME}"
  TOKEN_VALUE="$(http_body "$r" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
  local ttype; ttype="$(http_body "$r" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("type"))')"
  ok "minted ${ttype} (value $(printf '%s' "$TOKEN_VALUE" | mask)) — recorded for rollback"

  # prove the minted token authenticates
  local v; v="$(curl -sS -m 20 -u "${TOKEN_VALUE}:" "$SONAR_URL/api/authentication/validate")"
  printf '%s' "$v" | grep -q '"valid":true' \
    && ok "minted token authenticates against SonarQube: ${v}" \
    || fail "minted token failed authentication: ${v}"
}

apply_k8s() {
  log "apply-kubernetes-resources: ns=${TARGET_NS} connector=${CONNECTOR_NAME}"
  kubectl --context "$KUBECTL_CONTEXT" apply --server-side --field-manager connector-auto -f - <<EOF >&2
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${TARGET_NS}
  labels: { connectors.cpaas.io/sonarqube: "true", poc.devops: "43953" }
type: connectors.cpaas.io/bearer-token
stringData:
  token: "${TOKEN_VALUE}"
---
apiVersion: connectors.alauda.io/v1alpha1
kind: Connector
metadata:
  name: ${CONNECTOR_NAME}
  namespace: ${TARGET_NS}
  labels: { connectors.cpaas.io/sonarqube: "true", poc.devops: "43953" }
spec:
  connectorClassName: sonarqube
  address: "${SONAR_URL}"
  auth:
    name: tokenAuth
    secretRef:
      name: ${SECRET_NAME}
      namespace: ${TARGET_NS}
EOF
  ok "server-side-applied Secret + Connector into ${TARGET_NS}"
}

write_results() {
  log "results: project-key=${PROJECT_KEY} project-scope=${SCOPE} token-name=${TOKEN_NAME} connector-ref=${TARGET_NS}/${CONNECTOR_NAME}"
}

# ============================ subcommands ====================================

cmd_flow() {
  state_init
  trap 'rc=$?; [ $rc -ne 0 ] && rollback; exit $rc' EXIT
  ensure_project
  ensure_permissions
  ensure_token
  apply_k8s
  write_results
  trap - EXIT
  ok "FLOW COMPLETE — ${PROJECT_KEY} (${SCOPE})"
}

cmd_rollback_demo() { INJECT_FAILURE=permissions cmd_flow; }

cmd_cleanup() {
  log "cleanup: ${PROJECT_KEY} / ${TOKEN_NAME} / ${PERMISSION_TEMPLATE} / ${TARGET_NS}"
  sq POST "/api/user_tokens/revoke"        --data-urlencode "name=${TOKEN_NAME}"            >/dev/null 2>&1 || true
  sq POST "/api/projects/delete"           --data-urlencode "project=${PROJECT_KEY}"        >/dev/null 2>&1 || true
  sq POST "/api/permissions/delete_template" --data-urlencode "templateName=${PERMISSION_TEMPLATE}" >/dev/null 2>&1 || true
  kubectl --context "$KUBECTL_CONTEXT" delete secret "${SECRET_NAME}" \
    connector.connectors.alauda.io/"${CONNECTOR_NAME}" \
    -n "${TARGET_NS}" --ignore-not-found >/dev/null 2>&1 || true
  ok "cleanup done"
}

case "${1:-flow}" in
  flow)          cmd_flow ;;
  rollback-demo) cmd_rollback_demo ;;
  cleanup)       cmd_cleanup ;;
  *) fail "unknown subcommand: ${1:-}" ;;
esac
