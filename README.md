# did-cli

Command-line interface for [did](https://github.com/puzzlepart/did).

<p align="center">
  <img alt="didcli" width=450 src="https://github.com/user-attachments/assets/caaeb04a-887b-4d6e-afeb-7ac890842794"/>
</p>

Pure stdlib Python 3.8+. No runtime dependencies.

## Install

### Homebrew (macOS / Linux)

```sh
brew install damsleth/tap/did-cli
```

### From source

```sh
./scripts/add-to-path.sh        # pipx install -e .
# or: pipx install -e .
```

Then configure your session cookie once:

```sh
# DevTools > Application > Cookies > didapp
did-cli config --cookie "eyJ..."
```

Config lives at `~/.config/did-cli/config` (mode 0600).

## Usage

### Check status

```sh
did-cli status --pretty
```

Shows the current period's submission state, time bank balance, and
vacation days.

### Query hours

```sh
did-cli report --customer "Crayon" --from 2026-01 --to 2026-03 --pretty
did-cli report --project "Alpha" --week 15 --pretty
did-cli report --from 2026-03 --pretty
did-cli report --period last --pretty
```

Default output is JSON (for piping). Use `--pretty` for
human-readable tables.

### Submit hours

```sh
did-cli submit --period current
did-cli submit --week 15 --year 2026
did-cli submit --period current --confirm    # skip prompt
```

### Configure

```sh
did-cli config --url did.crayonconsulting.no
did-cli config --cookie "eyJ..."
did-cli config --output pretty
did-cli config --project-maxlength 25
did-cli config                              # show current config
```

## Environment overrides

Env vars override config-file values for the same key:

- `DID_URL`, `DID_COOKIE`, `DID_DEFAULT_OUTPUT`
- `DID_CUSTOMER_MAXLENGTH`, `DID_PROJECT_MAXLENGTH`, `DID_PRETTY_FORMAT`
- `DID_DEBUG=1` enables debug logging on stderr

## AI skill

There's a `/did` skill for Claude Code / Codex / Copilot that wraps
this CLI for interactive timesheet review. It compares did data
against your calendar, surfaces issues, and fixes them via
`cal-cli`. Install from [SKILLS](https://github.com/damsleth/SKILLS):

```sh
./install-skill.sh --install did
```

## Requirements

- Python 3.8+
- A valid `didapp` session cookie

## Tests

```sh
pip install -e '.[test]'
pytest -q
```

See `SECURITY.md` for the threat model and `AGENTS.md` for the
working style expected by AI agents contributing here.
