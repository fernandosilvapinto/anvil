#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_args 1 $# "./register-organization-scope.sh <client-id>"

CLIENT_ID=$1

kc_login

echo "==> Organization claim for $CLIENT_ID"

SCOPE_UUID=$(scope_uuid organization)
if [ -z "$SCOPE_UUID" ]; then
  echo "    Client scope 'organization' does not exist in realm '$REALM'." >&2
  echo "    Run ./bootstrap-realm.sh $REALM workforce first." >&2
  exit 1
fi

CLIENT_UUID=$(client_uuid "$CLIENT_ID")
if [ -z "$CLIENT_UUID" ]; then
  echo "    $CLIENT_ID does not exist. Register it first (./register-spa.sh or similar)." >&2
  exit 1
fi

# Same operation register-spa.sh performs when "organization" is in its scope
# list; this script exists for a client that is already registered.
if ! attach_default_scope "$CLIENT_UUID" "$SCOPE_UUID"; then
  echo "    organization could not be made a default scope of $CLIENT_ID" >&2
  exit 1
fi

echo "    organization claim is now issued by default to $CLIENT_ID"
