# Security model for did-cli

## TL;DR

`did-cli` is a personal productivity tool. It stores a `didapp`
session cookie on disk and sends it to a GraphQL endpoint. Don't
deploy it for users who aren't you.

## What this is

`did-cli` is a CLI that wraps the GraphQL API used by the `did`
timesheet app. It reads a session cookie the user pasted out of
their own browser and replays it against
`https://<did-host>/graphql` to query, filter, and submit timesheet
periods on behalf of that user.

## Threat model

**In scope:** The tool assumes a single user, signed into the did
web app in their browser, running the CLI under their own account.

- The cookie is stored at `~/.config/did-cli/config`, mode `0600`.
  Any process running as that user can read it.
- Atomic writes (temp file + fsync + rename) protect the on-disk
  cookie from partial writes on crash.
- The cached display name at `DID_USER_DISPLAY_NAME` is PII but
  low-impact; the user pasted it in themselves.

**Out of scope:**

- Multi-tenant deployment. There is none.
- Service accounts, daemons, or CI secret stores.
- Sharing cookies across hosts or users. The cookie is a user
  credential; sharing it is credential sharing.
- A compromised laptop. If someone else can read your home
  directory, they already have everything - `did-cli` adds no new
  attack surface.

## What `did-cli` does not do

- Register an application in any tenant.
- Issue requests for anyone other than the user whose cookie is
  configured.
- Send telemetry, crash reports, or update checks. The only network
  call is `POST https://<DID_URL>/graphql`.
- Persist anything the GraphQL server returns beyond the cached
  display name.

## What breaks it

- Session expiry. The server returns 401; the CLI prints
  `Session expired (401)` and points at `did-cli config --cookie`.
- Cookie rotation or name change on the did side. Update
  `did-cli config --cookie <new>` and continue.
- GraphQL schema drift. `.graphql` files in `did_cli/queries/`
  become stale; update them in lockstep with the server.

## Don't deploy this for other people

If you're thinking "I could wrap this in a service for my team" -
don't. Cookies are user credentials. Sharing them across users is
credential sharing. Packaging the CLI so a teammate can install it
on their own laptop, using their own cookie, is fine. Running it as
a daemon on behalf of N people is not.
