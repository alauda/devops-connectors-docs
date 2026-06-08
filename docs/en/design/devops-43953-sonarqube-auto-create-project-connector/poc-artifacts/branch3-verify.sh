#!/usr/bin/env bash
# POC Branch-3 verification: per-tenant user + group + key-pattern permission
# template. Proves a USER_TOKEN can read api/measures for projects whose key
# matches the template's pattern, and is denied on non-matching projects.
set -Eeuo pipefail

S=https://devops-sonar.alaudatech.net
CFG=/tmp/poc-devops-43953/curl.cfg

GROUP=poc-43953-tenant-branch3
USER=acme-bot-43953
TEMPLATE=poc-43953-branch3-template
PATTERN='^poc-devops-43953(:.*)?$'
TOKEN_NAME=acme-bot-branch3-test
USER_PW="POCb3-$(head -c 12 /dev/urandom | base64 | tr -d '+/=' | head -c 16)-Aa1!"

sq()   { m=$1; p=$2; shift 2; curl -sS -m 30 -K "$CFG" -X "$m" -w '\n%{http_code}' "$S$p" "$@"; }
code() { printf '%s' "$1" | tail -n1; }
body() { printf '%s' "$1" | sed '$d'; }
mask() { sed -E 's/(sq[apu]_)[A-Za-z0-9]+/\1***masked***/g'; }

echo "=== 1) create group ==="
r=$(sq POST /api/user_groups/create --data-urlencode "name=$GROUP" --data-urlencode "description=POC Branch 3 tenant group")
echo "  HTTP $(code "$r"): $(body "$r" | head -c 160)"

echo "=== 2) create local user ==="
r=$(sq POST /api/users/create --data-urlencode "login=$USER" --data-urlencode "name=ACME Bot (POC Branch 3)" --data-urlencode "password=$USER_PW" --data-urlencode "local=true")
echo "  HTTP $(code "$r"): $(body "$r" | head -c 160)"

echo "=== 3) add user to group ==="
r=$(sq POST /api/user_groups/add_user --data-urlencode "name=$GROUP" --data-urlencode "login=$USER")
echo "  HTTP $(code "$r")"

echo "=== 4) create permission template with projectKeyPattern ==="
r=$(sq POST /api/permissions/create_template --data-urlencode "name=$TEMPLATE" --data-urlencode "projectKeyPattern=$PATTERN" --data-urlencode "description=POC Branch 3")
echo "  HTTP $(code "$r"): $(body "$r" | head -c 160)"

echo "=== 5) grant group: user (Browse) + codeviewer (See Source) + scan (Execute Analysis) ==="
for perm in user codeviewer scan; do
  r=$(sq POST /api/permissions/add_group_to_template --data-urlencode "templateName=$TEMPLATE" --data-urlencode "groupName=$GROUP" --data-urlencode "permission=$perm")
  echo "  perm=$perm HTTP $(code "$r")"
done

echo "=== 6) apply template to existing POC projects ==="
for key in poc-devops-43953 'poc-devops-43953:team-a' 'poc-devops-43953:kychen-1' 'poc-devops-43953:via-taskrun'; do
  r=$(sq POST /api/permissions/apply_template --data-urlencode "templateName=$TEMPLATE" --data-urlencode "projectKey=$key")
  echo "  apply→$key HTTP $(code "$r")"
done

echo "=== 7) mint USER_TOKEN for $USER (admin via login=) ==="
r=$(sq POST /api/user_tokens/generate --data-urlencode "login=$USER" --data-urlencode "name=$TOKEN_NAME" --data-urlencode "type=USER_TOKEN")
[ "$(code "$r")" = 200 ] || { echo "FAIL: $(body "$r")"; exit 1; }
USER_TOKEN=$(body "$r" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
echo "  minted user token: $(printf '%s' "$USER_TOKEN" | mask)"
printf '%s' "$USER_TOKEN" > /tmp/poc-devops-43953/branch3-user-token.txt
chmod 600 /tmp/poc-devops-43953/branch3-user-token.txt

echo "=== 8) TEST — user token: api/measures on MATCHING projects (expect 200) ==="
for key in 'poc-devops-43953' 'poc-devops-43953:kychen-1' 'poc-devops-43953:team-a'; do
  c=$(curl -sS -m 20 -u "${USER_TOKEN}:" "$S/api/measures/component?component=$key&metricKeys=ncloc,bugs,alert_status" -w '\n%{http_code}')
  echo "  $key → HTTP $(code "$c")  $(body "$c" | head -c 200)"
done

echo "=== 9) pick a NON-matching SonarQube project on the instance ==="
NONMATCH=$(curl -sS -m 20 -K "$CFG" "$S/api/projects/search?ps=50" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for c in d.get("components", []):
    k = c["key"]
    if not k.startswith("poc-devops-43953"):
        print(k); break')
echo "  non-matching candidate: ${NONMATCH:-<none found>}"

if [ -n "$NONMATCH" ]; then
  echo "=== 10) TEST — user token: api/measures on NON-MATCHING project (expect 403/404) ==="
  c=$(curl -sS -m 20 -u "${USER_TOKEN}:" "$S/api/measures/component?component=$NONMATCH&metricKeys=ncloc" -w '\n%{http_code}')
  echo "  $NONMATCH → HTTP $(code "$c")  $(body "$c" | head -c 200)"
fi

echo "=== 11) TEST — user token: api/projects/search (should list only what user can browse) ==="
c=$(curl -sS -m 20 -u "${USER_TOKEN}:" "$S/api/projects/search?ps=50" -w '\n%{http_code}')
echo "  HTTP $(code "$c")"
printf '%s' "$(body "$c")" | python3 -c 'import sys,json;d=json.load(sys.stdin);[print(" ",x["key"]) for x in d.get("components",[])]' 2>&1 || true

echo "=== done; user token at /tmp/poc-devops-43953/branch3-user-token.txt (600) ==="
