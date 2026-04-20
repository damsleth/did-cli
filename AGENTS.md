# AGENTS.md

Instructions for AI coding agents working in this repo.

## What this is

`did-cli` is a small stdlib-only Python CLI (package at `did_cli/`,
~1000 lines split across a handful of modules) that talks to a
`did`-compatible GraphQL backend to read, filter, and submit
timesheet periods. One user, one laptop, macOS-first. Ported from a
zsh script in April 2026; the shape of the package mirrors
`owa-piggy` deliberately.

## Ground rules

- **Stdlib only** at runtime. No `requests`, no extra deps.
  `pytest` is dev-only under `[project.optional-dependencies] test`.
- **Never commit a real `didapp` cookie value**, even in tests or
  fixtures. Use obvious fakes (`"eyJfake"`).
- Match existing style: docstrings explain *why*. Keep that tone.
- No semicolons in JS/TS samples; 2-space indentation in shell and
  docs.

## Layout

```
did_cli/
  __init__.py        # re-exports `main` so `did-cli = "did_cli:main"` resolves
  __main__.py        # `python -m did_cli`
  cli.py             # arg parsing + dispatch
  config.py          # CONFIG_PATH, load_config, save_config, parse_kv_stream
  ansi.py            # tiny ANSI colour helpers for pretty output
  dates.py           # ISO week math, validate_* helpers, friendly_date_range_nb
  gql.py             # the one HTTP call, query loader, GqlError
  formatting.py      # pretty tables (flat + grouped-by-day)
  status.py          # do_status
  report.py          # do_report (+ display-name cache)
  submit.py          # do_submit
  queries/           # *.graphql files shipped as package data
scripts/
  add-to-path.sh     # pipx install shim
tests/               # pytest suite: pure functions + CLI smoke
pyproject.toml
README.md
SECURITY.md
```

## Working on this repo

- **Read before editing.** Don't change code you haven't read.
- **Preserve behavior.** Recent decisions encoded in commits: cookie
  lives at `~/.config/did-cli/config` (mode 0600), env overrides
  file, atomic writes, display-name cached in config, queries
  shipped as package data via `importlib.resources`.
- **Don't add abstractions.** Flat functions are the norm.
- **Test pure functions and CLI dispatch.** Network calls are
  monkeypatched in `test_cli_smoke.py`.

## Verification before claiming done

- `python -m compileall -q did_cli` passes.
- `python -m did_cli help` runs on a machine with no config.
- `pytest -q` is green.
- If you touched pretty output, `did-cli report --pretty` against a
  real session still looks right. If you can't run against a real
  session, say so explicitly.
- If you touched `scripts/*.sh`: `shellcheck` clean.

## Commits and PRs

- Short imperative commit messages. One line is usually enough.
- One logical change per commit.
- Do not push or open PRs without the user asking. Do not force-push
  `main`.

## What NOT to do

- Don't add a dependency on `requests`, `click`, `typer`, or any
  framework. The CLI is ~500 lines of stdlib.
- Don't add telemetry, crash reporting, or update checks.
- Don't widen the on-disk config to accept arbitrary keys. The
  `ALLOWED_KEYS` tuple in `config.py` is the allow-list.
