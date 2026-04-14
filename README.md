# did-cli

Command-line interface for [did](https://github.com/puzzlepart/did).
<p align="center">
![didcli1](https://github.com/user-attachments/assets/9bf9c6a9-767d-4cc6-afa5-64c19c030d4a)
</p>  

## Setup

1. Clone this repo
2. Run `./add-to-path.sh` to add `did-cli` to your PATH
3. Get your `didapp` session cookie from the browser (DevTools > Application > Cookies)
4. Configure: `did-cli config --cookie "your-cookie-value"`

`did-cli` will create `.env` from `.env.sample` automatically on first run, so `did-cli help` and `did-cli config ...` work before the cookie is set.

### Configuration

```bash
did-cli config --url did.crayonconsulting.no  # set instance (default)
did-cli config --cookie "eyJ..."              # set session cookie
did-cli config                                # show current config
```

## Usage

### Check status

```bash
did-cli status --pretty
```

Shows time bank balance, vacation days, and user info.

### Query hours

```bash
did-cli report --customer "Crayon" --from 2026-01 --to 2026-03 --pretty
did-cli report --project "Alpha" --week 15 --pretty
did-cli report --from 2026-03 --pretty
```

### Submit hours

```bash
did-cli submit --period current        # submit current week
did-cli submit --week 15 --year 2026   # submit specific week
did-cli submit --period current --confirm  # skip prompt
```

## Output

Default output is JSON (for piping/scripting). Use `--pretty` for human-readable tables.

## Requirements

- zsh
- curl
- jq
- python3 (for ISO week date calculation)

## Smoke Tests

Run the non-network regression checks with:

```bash
./tests/review-smoke.sh
```
