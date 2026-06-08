#!/bin/sh
# Strip 'Anyone' default global perms on 8.9, then run a scan with the tenant
# USER_TOKEN matching the projectPattern. Verify auto-create + measures access.
set -e
S=http://sonarqube-89.kychen-1.svc:9000
AUTH='admin:Sonarqube12345*'
USER=acme-89-bot
TENANT_TOKEN_NAME=acme-89-bot-token

curl_a() { curl -sk -m20 -u "$AUTH" "$@"; }
hr() { printf '\n--- %s ---\n' "$*"; }

hr "step 10: strip 'Anyone' group of global provisioning + scan (8.9-specific prereq)"
for P in provisioning scan; do
  code=$(curl_a -X POST "$S/api/permissions/remove_group" --data-urlencode 'groupName=Anyone' --data-urlencode "permission=$P" -w "%{http_code}" -o /tmp/r)
  echo "  remove_group Anyone $P -> $code"
done

hr "step 11: verify global perms now clean (only sonar-administrators)"
for P in admin provisioning scan; do
  grps=$(curl_a "$S/api/permissions/groups?permission=$P" | jq -r '[.groups[]?.name] | join(",")')
  usrs=$(curl_a "$S/api/permissions/users?permission=$P" | jq -r '[.users[]?.login] | join(",")')
  echo "  global $P: groups=[$grps] users=[$usrs]"
done

hr "step 12: re-mint a fresh tenant token (the prior was set in setup)"
# revoke whatever might be around with this name
curl_a -X POST "$S/api/user_tokens/revoke" --data-urlencode "login=$USER" --data-urlencode "name=$TENANT_TOKEN_NAME" -w "  revoke -> %{http_code}\n" -o /dev/null || true
RESP=$(curl_a -X POST "$S/api/user_tokens/generate" \
  --data-urlencode "login=$USER" --data-urlencode "name=$TENANT_TOKEN_NAME")
TENANT_TOKEN=$(echo "$RESP" | jq -r '.token // empty')
[ -n "$TENANT_TOKEN" ] || { echo "  FAIL mint: $RESP"; exit 1; }
echo "  fresh token minted (len=${#TENANT_TOKEN})"
echo "$TENANT_TOKEN" > /shared/tenant-token-fresh

hr "step 13: prove the token can NOT scan a non-matching project (isolation probe)"
# expect 403 since 'Anyone' no longer has global scan, and only acme-89:* is templated
code=$(curl -sk -u "$TENANT_TOKEN:" "$S/api/components/search?qualifiers=TRK&q=non-matching-probe" -m10 -w "%{http_code}" -o /tmp/r)
echo "  search non-matching -> HTTP $code, body[:200]=$(head -c 200 /tmp/r)"

echo
echo "=== prereq pass complete. shared/tenant-token-fresh written. ==="
