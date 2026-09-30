#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_args 1 $# "./bootstrap-realm.sh <realm> [workforce|customers]"

REALM=$1
PROFILE=${2:-workforce}

SMTP_HOST=${ANVIL_SMTP_HOST:-host.docker.internal}
SMTP_PORT=${ANVIL_SMTP_PORT:-1025}
SMTP_FROM=${ANVIL_SMTP_FROM:-anvil@anvil.local}

# The authorization code is single-use and is redeemed by the application within
# a second or two. Sixty seconds is the value OAuth 2.1 recommends; raise it
# through the environment only while exchanging codes by hand.
ACCESS_CODE_LIFESPAN=${ANVIL_ACCESS_CODE_LIFESPAN:-60}

case "$PROFILE" in
  workforce)
    DISPLAY_NAME="Anvil Workforce"
    REGISTRATION=false
    VERIFY_EMAIL=false
    REMEMBER_ME=false
    SSO_IDLE=1800
    SSO_MAX=36000
    ;;
  customers)
    DISPLAY_NAME="Anvil Customers"
    REGISTRATION=false
    VERIFY_EMAIL=true
    REMEMBER_ME=true
    SSO_IDLE=86400
    SSO_MAX=604800
    ;;
  *)
    echo "Unknown profile '$PROFILE'. Use 'workforce' or 'customers'." >&2
    exit 1
    ;;
esac

kc_login

SETTINGS=(
  -s enabled=true
  -s "displayName=$DISPLAY_NAME"
  -s sslRequired=NONE
  -s loginWithEmailAllowed=true
  -s duplicateEmailsAllowed=false
  -s resetPasswordAllowed=true
  -s "registrationAllowed=$REGISTRATION"
  -s "verifyEmail=$VERIFY_EMAIL"
  -s "rememberMe=$REMEMBER_ME"
  -s bruteForceProtected=true
  -s accessTokenLifespan=300
  -s "accessCodeLifespan=$ACCESS_CODE_LIFESPAN"
  -s "ssoSessionIdleTimeout=$SSO_IDLE"
  -s "ssoSessionMaxLifespan=$SSO_MAX"
)

echo "==> Realm $REALM ($PROFILE profile)"
if kc get "realms/$REALM" >/dev/null 2>&1; then
  echo "    already exists, applying settings"
  kc update "realms/$REALM" "${SETTINGS[@]}"
else
  kc create realms -s "realm=$REALM" "${SETTINGS[@]}"
fi

echo "==> Mail provider"
kc update "realms/$REALM" \
  -s "smtpServer={\"host\":\"$SMTP_HOST\",\"port\":\"$SMTP_PORT\",\"from\":\"$SMTP_FROM\",\"fromDisplayName\":\"$DISPLAY_NAME\",\"ssl\":\"false\",\"starttls\":\"false\",\"auth\":\"false\"}"

echo "==> Auditing"
kc update "realms/$REALM/events/config" \
  -s eventsEnabled=true \
  -s adminEventsEnabled=true \
  -s adminEventsDetailsEnabled=true \
  -s 'enabledEventTypes=["LOGIN","LOGIN_ERROR","LOGOUT","REGISTER","REGISTER_ERROR","CODE_TO_TOKEN","CODE_TO_TOKEN_ERROR","REFRESH_TOKEN","REFRESH_TOKEN_ERROR","CLIENT_LOGIN","CLIENT_LOGIN_ERROR","UPDATE_PASSWORD","RESET_PASSWORD","SEND_RESET_PASSWORD","VERIFY_EMAIL"]'

if [ "$PROFILE" = "workforce" ]; then
  echo "==> Organizations (multi-tenant)"
  kc update "realms/$REALM" -s organizationsEnabled=true

  # Enabling the feature makes Keycloak create the built-in "organization"
  # client scope and link it to every client as optional. This block is only
  # a fallback in case that scope is missing. Safe to run again: skipped once
  # the scope exists. Making it a default scope of a given client is done by
  # register-organization-scope.sh.
  if [ -z "$(scope_uuid organization)" ]; then
    kc create client-scopes -r "$REALM" \
      -s name=organization \
      -s protocol=openid-connect \
      -s 'attributes={"include.in.token.scope":"true","display.on.consent.screen":"false"}'

    ORG_SCOPE_UUID=$(scope_uuid organization)

    kc create "client-scopes/$ORG_SCOPE_UUID/protocol-mappers/models" -r "$REALM" \
      -s name=organization \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-organization-membership-mapper \
      -s 'config={"claim.name":"organization","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true","introspection.token.claim":"true","multivalued":"true","addOrganizationAttributes":"false","addOrganizationId":"false","addOrganizationDomain":"false","jsonType.label":"String"}'

    echo "    client scope 'organization' created"
  else
    echo "    client scope 'organization' already exists, kept"
  fi
fi

echo
echo "Realm $REALM ready."
echo "Console:   http://anvil.localtest.me:8081/admin"
echo "Discovery: http://anvil.localtest.me:8081/realms/$REALM/.well-known/openid-configuration"
