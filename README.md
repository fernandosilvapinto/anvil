# Anvil

Self-hosted identity provider built on Keycloak — OpenID Connect, SSO and
role-based authorization across multiple applications.

## Overview

Anvil authenticates people once and issues tokens that every application
accepts, so applications no longer store credentials, sign their own tokens, or
implement login flows. One sign-in serves them all.

It is deliberately application-agnostic. Applications register as OIDC clients
and APIs register as resource servers; the identity provider holds no
application logic and no domain data. Adding an application is a client
registration, not a change to this repository.

| Concept | Role |
|---|---|
| Realm | Security boundary — users, signing keys, clients, sessions |
| Client (public) | Browser or mobile application, Authorization Code with PKCE |
| Client (confidential) | Server-side application, may use Client Credentials |
| Resource server | API that validates tokens; owns its permissions as client roles |
| Client scope | Bundle of protocol mappers, including the audience mapper per API |

## Services

| Service | Port | Role | Profile |
|---|---|---|---|
| `anvil` | 8081 | Identity provider and authorization server | default |
| `anvil` (management) | 9000 | `/health` and `/metrics` | default |
| `anvil-db` | 5433 | Dedicated PostgreSQL instance | default |
| `anvil-ldap` | 1389 | LDAP directory for user federation | `federation` |
| `anvil-ldapadmin` | 8083 | LDAP web interface | `federation` |
| `anvil-openfga` | 8084 / 3001 | Relationship-based authorization engine | `authz` |

The management port is separate from the HTTP port by design and is not meant
to be exposed alongside it.

## Requirements

- Docker with Compose v2
- An SMTP endpoint reachable at `host.docker.internal:1025` for account
  verification and password reset messages. Any SMTP sink works; the identity
  provider treats mail delivery as an external dependency and does not ship one.

## Getting started

Copy `.env.example` to `.env`, then:

```
docker compose up -d
```

Administration console: http://anvil.localtest.me:8081/admin

`localtest.me` and its subdomains resolve to 127.0.0.1 over public DNS. If the
local network blocks that resolution, add `127.0.0.1 anvil.localtest.me` to the
system hosts file.

Optional profiles:

```
docker compose --profile federation up -d
docker compose --profile authz up -d
```

## Realms

A realm is the security boundary, and it is where single sign-on stops: two
applications share a session only if they share a realm. The split therefore
follows the population, not the application.

| Realm | Population | Registration | Sign-in policy |
|---|---|---|---|
| `workforce` | The operator's own people | Closed — accounts are provisioned | Short sessions, no "remember me" |
| `customers` | People who buy from the operator | Open, with email verification | Long sessions, "remember me" |

Internal applications register in `workforce` and single sign-on between
themselves. A customer-facing application registers in `customers` and can never
receive a workforce session, whatever it asks for. An API that serves both
validates two issuers and accepts a token from either.

```
./bootstrap-realm.sh workforce workforce
./bootstrap-realm.sh customers customers
```

### Organizations (multi-tenant back office)

`workforce` is shared by every client business — Pistachio is one identity
provider serving many tenants, not one deployment per tenant. Keycloak
Organizations is what tells a manager's token which business they belong to:
each client business is one organization, and **its alias is always identical
to the tenant slug the API already uses for Row-Level Security** (`demo`,
`oficina-silva`, ...). That equality is the whole integration; the API reads
the claim and matches it straight against the slug it already knows, no
translation table involved.

A back office asks for the claim by listing `organization` among its default
scopes when it registers — Pistachio's `register.sh` runs
`register-spa.sh pistachio-admin <origin> pistachio-api,organization` — so a
client recreated from scratch gets it too. From then on every access token that
client is issued carries:

```json
"organization": ["<slug>"]
```

a JSON array of aliases, one per organization the user belongs to, and always
an array, even with a single entry (the mapper is `multivalued`). The
`organization` scope also appears in the token's `scope` claim. This is the
shape with the built-in mapper's defaults; turning on "Add organization id" or
"Add organization attributes" on the mapper changes it to an object keyed by
alias, so leave those off unless the API is changed to match. Keep
every manager in exactly one organization — Keycloak has open bugs around the
claim when a user belongs to more than one (see e.g. keycloak/keycloak#33556
and #43635), and this system has no use for a manager spanning tenants.

`create-organization.sh` is the one script from this section meant to be run
repeatedly, once per new client business.

## Scripts

Nine scripts, split by responsibility. The first builds a realm; the rest are
parameterized operations that any application can call. None of them contains
application-specific data — the arguments do, and they are never hard-coded
here.

```
./bootstrap-realm.sh              <realm> [workforce|customers]
./register-api.sh                 <api-id> <permission,permission,...>
./register-spa.sh                 <client-id> <origin> <scope,scope,...>
./register-role.sh                <role> <api-id>:<permission>,... [default]
./register-service-client.sh      <client-id> <realm-management-role,...> [secret]
./register-organization-scope.sh  <client-id>
./create-organization.sh          <alias> <name> <manager-email>
./set-realm-theme.sh              <realm> <login-theme> [account] [email]
./export-realm.sh                 <realm> [output-dir]
```

Every script but the first acts on the realm named in `ANVIL_REALM`, so an
application registers itself in one realm or the other by exporting it.

`bootstrap-realm.sh` creates or updates a realm and applies a profile: sign-in
policy, token and session lifetimes, brute force protection, the mail provider,
and event auditing. It is safe to run again — it is how a policy change is
applied.

`register-api.sh` creates a resource server, declares its permissions as client
roles, and creates the client scope whose audience mapper puts the API into the
`aud` claim.

`register-spa.sh` registers a browser application as a public client with PKCE
enforced, sets its redirect URIs and web origin, and links the client scopes it
needs as default scopes: the audience of each API it calls and, for a back
office, `organization`. Each link is verified, and the script stops if one did
not take.

`register-role.sh` creates a business role as a composite of permissions drawn
from one or more resource servers.

`register-service-client.sh` creates a confidential client with a service
account, for an application that needs to act on the realm without a user —
creating an account on a visitor's behalf, for instance. Grant it the narrowest
set of realm management roles the task needs, and keep its secret out of source
control.

`register-organization-scope.sh` makes the built-in `organization` client
scope a *default* scope of the given client, so every access token it is
issued carries the `organization` claim without the application having to ask
for it — the same thing `register-spa.sh` does when `organization` is in its
scope list, for a client that is already registered. Keycloak links that scope
to every client as *optional* when organizations are enabled, and a scope
cannot be both; the optional link is removed first. Sessions that started before the change keep their old
scopes on refresh, so users have to log out and back in to get the claim. Requires organizations to already be enabled on the realm — see
"Organizations" below.

`create-organization.sh` onboards one tenant: creates the organization (alias
== tenant slug), creates or reuses the manager's account, grants
`pistachio-manager`, and adds them as a member. Run it once per client
business. The temporary password it prints is shown once, must change on
first login, and should travel out of band, never in source control or in
this terminal's scrollback.

`set-realm-theme.sh` points a realm at a login, account or email theme, so a
customer-facing realm can carry the application's branding while the provider
remains the only thing that ever sees a password.

`export-realm.sh` writes the realm's configuration to `realms/<realm>.json`.

The registration scripts are idempotent. `register-spa.sh` refuses to register an
application against a client scope that does not exist, so no client is left
without an audience or without its `organization` claim.

Applications keep their own registration definition in their own repository and
call these scripts. This repository never learns their names.

Verify a realm is serving metadata:

```
curl -s http://anvil.localtest.me:8081/realms/workforce/.well-known/openid-configuration
```

## Documentation

[`docs/onboarding.md`](docs/onboarding.md) covers how an application starts using
this provider and who is responsible for each step — the integration request, who
owns the permission catalog, who approves access, secret rotation, access
certification and decommissioning. It also states the service contract in both
directions: what the provider commits to, and what it requires of every
integrating application.

## Configuration as code

Realm configuration lives in the database, not in this repository. Export it
after any change, so that a change to who can do what arrives as a reviewable
diff rather than as an undocumented click in a console:

```
./export-realm.sh workforce
./export-realm.sh customers
```

The export runs against the live provider and covers clients, roles, groups,
scopes, mappers and realm policy. It deliberately omits users and masks client
secrets: what belongs in version control is the configuration, not the
population and not the credentials.

## Authorization model

Permissions are declared as client roles on each resource server, in
`resource:action` form. Business roles are composite realm roles that aggregate
those permissions. APIs authorize against permissions, never against business
roles, so a new role can be introduced without touching application code.

Resource ownership — whether a subject may act on a specific record — is domain
logic and stays in the application. The identity provider answers who the
subject is and what class of operation they may perform, nothing more.

## Environment

| Variable | Purpose |
|---|---|
| `KC_ADMIN_USER` | Bootstrap administrator, created on first start only |
| `KC_ADMIN_PASSWORD` | Bootstrap administrator password |
| `KC_DB_PASSWORD` | Password for the dedicated PostgreSQL instance |
| `LDAP_ADMIN_PASSWORD` | LDAP administrator password, `federation` profile only |

## Used by

| Application | Registers |
|---|---|
| [pistachio-api](https://github.com/fernandosilvapinto/pistachio-api) | A resource server in both realms, two browser clients and a service account |
| CARGA | A resource server and one browser client in `workforce` |

Each keeps its own registration definition in its own repository and calls the
scripts above. The link is documentation: nothing in this repository refers to
them.

## Status

This configuration targets local development. It runs Keycloak in `start-dev`
mode over plain HTTP, with a relaxed hostname policy and no clustering. A
production deployment requires `start --optimized`, TLS termination, a fixed
hostname, external key management, and pinned image digests.
