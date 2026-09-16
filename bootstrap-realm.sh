#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_args 1 $# "./bootstrap-realm.sh <realm> [workforce|customers]"

REALM=$1
PROFILE=${2:-workforce}

SMTP_HOST=${KEEPER_SMTP_HOST:-host.docker.internal}
SMTP_PORT=${KEEPER_SMTP_PORT:-1025}
SMTP_FROM=${KEEPER_SMTP_FROM:-keeper@keeper.local}

# The authorization code is single-use and is redeemed by the application within
# a second or two. Sixty seconds is the value OAuth 2.1 recommends; raise it
# through the environment only while exchanging codes by hand.
ACCESS_CODE_LIFESPAN=${KEEPER_ACCESS_CODE_LIFESPAN:-60}

case "$PROFILE" in
  workforce)
    DISPLAY_NAME="Keeper Workforce"
    REGISTRATION=false
    VERIFY_EMAIL=false
    REMEMBER_ME=false
    SSO_IDLE=1800
    SSO_MAX=36000
    ;;
  customers)
    DISPLAY_NAME="Keeper Customers"
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

echo
echo "Realm $REALM ready."
echo "Console:   http://keeper.localtest.me:8081/admin"
echo "Discovery: http://keeper.localtest.me:8081/realms/$REALM/.well-known/openid-configuration"
