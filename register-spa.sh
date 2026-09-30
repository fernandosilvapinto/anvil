#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_args 3 $# "./register-spa.sh <client-id> <origin> <scope,scope,...>"

CLIENT_ID=$1
ORIGIN=${2%/}
SCOPES=$3

kc_login

# baseUrl tells the provider where this application lives. Without it, its
# pages have nowhere to send a visitor who changed their mind: the "back to the
# application" link the theme renders on every information and error screen
# simply does not appear. A one-way door is a design defect, not a security
# measure.

# frontchannelLogout=false on purpose. Front-channel logout works by having the
# provider load one iframe per application during sign-out, so it depends on
# third-party cookies — which browsers are removing. Left on without a
# frontchannel.logout.url it also does nothing at all, which is worse than
# being off: it advertises a guarantee the system does not keep. Propagating a
# sign-out to other applications is back-channel logout's job, and that needs a
# server-side endpoint per application.
#
# fullScopeAllowed=false on purpose. With it left on — Keycloak's default — the
# token carries every role the person holds anywhere in the realm, so signing
# in to one application yields a credential that opens every other API that
# person can reach. Closed, the client only receives the permissions of the
# APIs whose client scope it was given below.

echo "==> Application $CLIENT_ID at $ORIGIN"
if [ -z "$(client_uuid "$CLIENT_ID")" ]; then
  kc create clients -r "$REALM" \
    -s clientId="$CLIENT_ID" \
    -s name="$CLIENT_ID" \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s frontchannelLogout=false \
    -s fullScopeAllowed=false \
    -s rootUrl="" \
    -s baseUrl="$ORIGIN" \
    -s "redirectUris=[\"$ORIGIN/*\"]" \
    -s "webOrigins=[\"$ORIGIN\"]" \
    -s "attributes={\"pkce.code.challenge.method\":\"S256\",\"post.logout.redirect.uris\":\"$ORIGIN/*\"}"
else
  echo "    already exists, updating origins"
  CLIENT_UUID=$(client_uuid "$CLIENT_ID")
  kc update "clients/$CLIENT_UUID" -r "$REALM" \
    -s frontchannelLogout=false \
    -s fullScopeAllowed=false \
    -s rootUrl="" \
    -s baseUrl="$ORIGIN" \
    -s "redirectUris=[\"$ORIGIN/*\"]" \
    -s "webOrigins=[\"$ORIGIN\"]" \
    -s "attributes={\"pkce.code.challenge.method\":\"S256\",\"post.logout.redirect.uris\":\"$ORIGIN/*\"}"
fi

CLIENT_UUID=$(client_uuid "$CLIENT_ID")

# Every scope listed is linked as a default scope: the audience of each API the
# application calls and, for a back office in the workforce realm,
# "organization" — so the token says which business the user belongs to. Each
# link is verified; the script stops if one did not take.
echo "==> Default scopes"
while read -r scope; do
  SCOPE_UUID=$(scope_uuid "$scope")
  if [ -z "$SCOPE_UUID" ]; then
    echo "    client scope '$scope' does not exist in realm '$REALM'." >&2
    echo "    An API: ./register-api.sh $scope   organization: ./bootstrap-realm.sh $REALM workforce" >&2
    exit 1
  fi
  if ! attach_default_scope "$CLIENT_UUID" "$SCOPE_UUID"; then
    echo "    '$scope' could not be made a default scope of $CLIENT_ID" >&2
    exit 1
  fi
  echo "    $scope"
done < <(split_list "$SCOPES")

echo "Application $CLIENT_ID ready."
