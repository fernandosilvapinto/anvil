#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_args 3 $# "./create-organization.sh <alias> <name> <manager-email>"

ALIAS=$1
NAME=$2
EMAIL=$3

# The alias is the tenant slug. It has to match what the API uses for
# Row-Level Security 1:1, because the "organization" claim in the token is
# a list of aliases, not ids — see README.md, "Organizations".
kc_login

echo "==> Organization $ALIAS"
ORG_UUID=$(organization_uuid "$ALIAS")
if [ -z "$ORG_UUID" ]; then
  # Keycloak requires at least one domain per organization even though the
  # admin console does not mark it as such. It does not need to be a real,
  # routable email domain for this to work — the alias is reused here as a
  # placeholder, since nothing depends on domain-based IdP discovery.
  kc create organizations -r "$REALM" \
    -s "name=$NAME" \
    -s "alias=$ALIAS" \
    -s enabled=true \
    -s "domains=[{\"name\":\"$ALIAS\",\"verified\":true}]"
  ORG_UUID=$(organization_uuid "$ALIAS")
  echo "    created ($ORG_UUID)"
else
  echo "    already exists, kept ($ORG_UUID)"
fi

echo "==> Manager $EMAIL"
USER_UUID=$(user_uuid "$EMAIL")
TEMP_PASSWORD=""
if [ -z "$USER_UUID" ]; then
  # ANVIL_MANAGER_PASSWORD lets a caller pin the value (e.g. to immediately
  # pull a test token in the same shell) instead of only ever seeing it once
  # in this script's own output.
  TEMP_PASSWORD=${ANVIL_MANAGER_PASSWORD:-$(openssl rand -base64 18)}
  kc create users -r "$REALM" \
    -s "username=$EMAIL" \
    -s "email=$EMAIL" \
    -s emailVerified=true \
    -s enabled=true \
    -s 'requiredActions=["UPDATE_PASSWORD"]'
  USER_UUID=$(user_uuid "$EMAIL")
  # reset-password is write-only (no GET), so kcadm's default merge-by-reading
  # first fails with "Resource not found". -n skips that read.
  kc update "users/$USER_UUID/reset-password" -r "$REALM" \
    -s type=password \
    -s "value=$TEMP_PASSWORD" \
    -s temporary=true \
    -n
  echo "    created ($USER_UUID)"
else
  echo "    already exists, kept ($USER_UUID)"
fi

echo "==> Role pistachio-manager"
kc add-roles -r "$REALM" --uusername "$EMAIL" --rolename pistachio-manager

echo "==> Organization membership"
MEMBER_IDS=$(kc get "organizations/$ORG_UUID/members" -r "$REALM" --fields id --format csv --noquotes | tr -d '\r')
if grep -qx "$USER_UUID" <<< "$MEMBER_IDS"; then
  echo "    already a member, kept"
else
  kc create "organizations/$ORG_UUID/members" -r "$REALM" -b "\"$USER_UUID\""
  echo "    added"
fi

echo
echo "Organization $ALIAS ready."
if [ -n "$TEMP_PASSWORD" ]; then
  echo
  echo "Temporary password for $EMAIL: $TEMP_PASSWORD"
  echo "Forced to change on first login (UPDATE_PASSWORD). Share it out of band,"
  echo "never by plain email."
fi
