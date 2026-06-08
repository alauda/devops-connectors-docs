#!/bin/sh
# Branch-3 end-to-end validation on SonarQube 8.9.2 (CE) — kychen-1/sonarqube-89.
# Reflects the refined design: drop group, user direct global provisioning,
# add_user_to_template for project-level perms.
set -e
S=http://sonarqube-89.kychen-1.svc:9000
AUTH='admin:Sonarqube12345*'
TENANT=acme-89
USER=acme-89-bot
TEMPLATE=acme-89-template
TOKEN_NAME=acme-89-bot-token

curl_a() { curl -sk -m20 -u "$AUTH" "$@"; }
hr() { printf '\n--- %s ---\n' "$*"; }

get_users_for_perm() {
  curl_a "$S/api/permissions/users?permission=$1" | jq -r '[.users[]?.login] | join(",")' 2>&1
}
get_groups_for_perm() {
  curl_a "$S/api/permissions/groups?permission=$1" | jq -r '[.groups[]?.name] | join(",")' 2>&1
}

hr "step 1: inspect default 'sonar-users' global perms on 8.9 (compare to 25.1)"
for P in admin provisioning scan gateadmin profileadmin; do
  printf "  [global %s] users=[%s] groups=[%s]\n" "$P" "$(get_users_for_perm $P)" "$(get_groups_for_perm $P)"
done

hr "step 2: strip 'sonar-users' of all global perms (deployment prereq)"
for P in admin provisioning scan gateadmin profileadmin; do
  before=$(get_groups_for_perm $P)
  if echo "$before" | grep -q 'sonar-users'; then
    code=$(curl_a -X POST "$S/api/permissions/remove_group" --data-urlencode "groupName=sonar-users" --data-urlencode "permission=$P" -w "%{http_code}" -o /tmp/r)
    printf "  remove_group sonar-users %s -> %s\n" "$P" "$code"
  fi
done

hr "step 3: set instance default project visibility = Private (deployment prereq)"
code=$(curl_a -X POST "$S/api/projects/update_default_visibility" --data-urlencode 'projectVisibility=private' -w "%{http_code}" -o /tmp/r)
printf "  update_default_visibility=private -> %s\n" "$code"

hr "step 4: Branch-3 setup — create user '$USER'"
curl_a -X POST "$S/api/users/create" \
  --data-urlencode "login=$USER" --data-urlencode "name=$USER" \
  --data-urlencode 'local=true' --data-urlencode 'password=Branch3-Probe-89!' \
  -w "  users/create -> %{http_code}\n" -o /dev/null

hr "step 5: grant user direct global 'provisioning' (Create Projects)"
curl_a -X POST "$S/api/permissions/add_user" \
  --data-urlencode "login=$USER" --data-urlencode 'permission=provisioning' \
  -w "  add_user provisioning -> %{http_code}\n" -o /dev/null

hr "step 6: verify user has only provisioning + sonar-users (no other globals)"
for P in admin provisioning scan gateadmin profileadmin; do
  hits=$(get_users_for_perm $P)
  echo "$hits" | grep -q "^$USER$\|,$USER$\|^$USER,\|,$USER," && echo "  user has global: $P"
done
echo "  user's groups:"
curl_a "$S/api/users/groups?login=$USER" | jq -r '.groups[]? | select(.selected==true) | "    - " + .name'

hr "step 7: create permission template + grants direct to user (no group)"
curl_a -X POST "$S/api/permissions/create_template" \
  --data-urlencode "name=$TEMPLATE" --data-urlencode "projectKeyPattern=^${TENANT}(:.*)?\$" \
  -w "  create_template -> %{http_code}\n" -o /dev/null
for P in user codeviewer issueadmin securityhotspotadmin scan; do
  curl_a -X POST "$S/api/permissions/add_user_to_template" \
    --data-urlencode "templateName=$TEMPLATE" --data-urlencode "login=$USER" \
    --data-urlencode "permission=$P" \
    -w "  add_user_to_template $P -> %{http_code}\n" -o /dev/null
done

hr "step 8: token mint — try BOTH the 25.x-style 'type=USER_TOKEN' and 8.9-native"
echo "  --- with type=USER_TOKEN (post-9.5 param) ---"
RESP=$(curl_a -X POST "$S/api/user_tokens/generate" \
  --data-urlencode "login=$USER" --data-urlencode "name=$TOKEN_NAME-typed" \
  --data-urlencode 'type=USER_TOKEN')
echo "    $RESP" | head -c 300; echo

echo "  --- without type (8.9-native) ---"
RESP=$(curl_a -X POST "$S/api/user_tokens/generate" \
  --data-urlencode "login=$USER" --data-urlencode "name=$TOKEN_NAME")
TENANT_TOKEN=$(echo "$RESP" | jq -r '.token // empty' 2>/dev/null)
[ -n "$TENANT_TOKEN" ] && echo "    token minted (len=${#TENANT_TOKEN})" || { echo "    FAIL: $RESP"; exit 1; }

hr "step 9: try expirationDate (post-9.6 param) on 8.9"
curl_a -X POST "$S/api/user_tokens/generate" \
  --data-urlencode "login=$USER" --data-urlencode "name=${TOKEN_NAME}-exp" \
  --data-urlencode 'expirationDate=2027-01-01' \
  -w "  with expirationDate -> %{http_code}\n" -o /tmp/r
echo "    body: $(head -c 200 /tmp/r)"

# Save the token for the scan step
echo "$TENANT_TOKEN" > /shared/tenant-token
echo "$USER" > /shared/tenant-user
echo "$TEMPLATE" > /shared/template-name

echo
echo "=== Branch-3 setup done on 8.9. shared/{tenant-token,tenant-user,template-name} written. ==="
