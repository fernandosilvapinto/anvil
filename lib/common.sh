#!/usr/bin/env bash

# ~/apps/anvil/.env holds the real admin credentials on a deployed instance
# (the container reads them as KC_BOOTSTRAP_ADMIN_USERNAME/_PASSWORD). Source
# it automatically so these scripts authenticate with the real values instead
# of silently falling back to admin/admin and failing with
# "Invalid user credentials". No-op in local dev, where this path does not
# exist.
if [ -f "$HOME/apps/anvil/.env" ]; then
  set -a
  source "$HOME/apps/anvil/.env"
  set +a
fi

REALM=${ANVIL_REALM:-anvil}
CONTAINER=${ANVIL_CONTAINER:-anvil}
SERVER=${ANVIL_SERVER:-http://localhost:8080}
ADMIN_USER=${KC_ADMIN_USER:-${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}}
ADMIN_PASSWORD=${KC_ADMIN_PASSWORD:-${KC_BOOTSTRAP_ADMIN_PASSWORD:-admin}}

require_container() {
  local running
  running=$(docker ps --format '{{.Names}}')
  if ! grep -qx "$CONTAINER" <<< "$running"; then
    echo "Container '$CONTAINER' is not running. Start it with: docker compose up -d" >&2
    exit 1
  fi
}

kc() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"
}

# Same, but with stdin attached, for the calls that pass a JSON body with
# `-f -`. Kept separate so the ordinary calls are not left waiting on a
# terminal that never sends anything.
kc_in() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"
}

kc_login() {
  require_container

  local attempts=${ANVIL_LOGIN_ATTEMPTS:-30}
  local delay=${ANVIL_LOGIN_DELAY:-2}
  local attempt=1

  while [ "$attempt" -le "$attempts" ]; do
    if kc config credentials --server "$SERVER" --realm master \
         --user "$ADMIN_USER" --password "$ADMIN_PASSWORD" >/dev/null 2>&1; then
      return 0
    fi

    if [ "$attempt" -eq 1 ]; then
      echo "Waiting for '$CONTAINER' to accept connections on $SERVER ..." >&2
    fi

    sleep "$delay"
    attempt=$((attempt + 1))
  done

  echo >&2
  echo "Gave up after $attempts attempts. Last error:" >&2
  kc config credentials --server "$SERVER" --realm master \
    --user "$ADMIN_USER" --password "$ADMIN_PASSWORD" >&2 || true
  echo >&2
  echo "Check: docker ps  |  docker logs $CONTAINER --tail 30" >&2
  exit 1
}

client_uuid() {
  kc get clients -r "$REALM" -q clientId="$1" --fields id --format csv --noquotes | tr -d '\r\n'
}

scope_uuid() {
  kc get client-scopes -r "$REALM" --fields id,name --format csv --noquotes \
    | tr -d '\r' | grep ",$1\$" | cut -d, -f1
}

organization_uuid() {
  kc get organizations -r "$REALM" -q search="$1" -q exact=true \
      --fields id,alias --format csv --noquotes \
    | tr -d '\r' | awk -F, -v alias="$1" '$2==alias {print $1; exit}'
}

user_uuid() {
  kc get users -r "$REALM" -q username="$1" -q exact=true --fields id,username --format csv --noquotes \
    | tr -d '\r' | awk -F, -v u="$1" '$2==u {print $1; exit}'
}

require_args() {
  local expected=$1 actual=$2 usage=$3
  if [ "$actual" -lt "$expected" ]; then
    echo "Usage: $usage" >&2
    exit 1
  fi
}

# True if the scope is linked to the client in the given list ("default" or
# "optional"). The list is read into a variable before matching: piping kcadm
# straight into "grep -q" lets grep exit on the first match while the pipe is
# still being written, and under "set -o pipefail" that SIGPIPE turns a match
# into a failure.
scope_linked() {
  local client_uuid=$1 kind=$2 scope_uuid=$3 ids
  ids=$(kc get "clients/$client_uuid/$kind-client-scopes" -r "$REALM" \
          --fields id --format csv --noquotes | tr -d '\r')
  grep -qx "$scope_uuid" <<< "$ids"
}

# Links a client scope to a client as a *default* scope, and checks it.
# Keycloak links some scopes to every client as *optional* on its own — the
# built-in "organization" scope, once organizations are enabled. A scope can
# only be linked once per client, and asking for it as default while it is
# still optional is silently ignored, so the optional link is removed first
# and the result is verified instead of assumed. Returns non-zero on failure.
attach_default_scope() {
  local client_uuid=$1 scope_uuid=$2 attempt
  if scope_linked "$client_uuid" optional "$scope_uuid"; then
    kc delete "clients/$client_uuid/optional-client-scopes/$scope_uuid" -r "$REALM"
  fi
  kc update "clients/$client_uuid/default-client-scopes/$scope_uuid" -r "$REALM"
  for attempt in 1 2 3 4 5; do
    scope_linked "$client_uuid" default "$scope_uuid" && return 0
    sleep 1
  done
  return 1
}

split_list() {
  echo "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
