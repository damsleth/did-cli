"""Argument parsing and dispatch for the `did-cli` command."""
import sys

from . import ansi, dates
from .config import CONFIG_PATH, load_config, save_config


HELP_TEXT = """did-cli - command-line interface for did

usage: did-cli <command> [options]

commands:
  status              show current period, time bank, and vacation
  report              query hours with filters
  submit              submit a timesheet period
  config              view or update configuration
  help                show this help

report options:
  --customer <name>   filter by customer name
  --project <name>    filter by project name
  --employee <name>   filter by employee (default: current user)
  --employee all      show all employees
  --period <value>    current, last, or next (week)
  --from <date>       start date (YYYY-MM-DD or YYYY-MM)
  --to <date>         end date (YYYY-MM-DD or YYYY-MM)
  --week <n>          ISO week number, or: last, next
  --year <number>     year (default: current)
  --pretty            human-readable output
  --json              JSON output (default from DID_DEFAULT_OUTPUT)

submit options:
  --period <value>    current, last, or next
  --week <n>          ISO week number, or: last, next
  --year <number>     year (default: current)
  --confirm           skip interactive prompt

config options:
  --url <hostname>    set did instance URL
  --cookie <value>    set didapp session cookie
  --output <format>   set default output: json or pretty
  --customer-maxlength <n>  max display width for customer column
  --project-maxlength <n>   max display width for project column
  --pretty-format <json>    column spec: array of [field, header, width] tuples
                            e.g. '[["customer.name","Customer",15],...]'

config file:
  ~/.config/did-cli/config    KEY=value, auto-created on first write

examples:
  did-cli status --pretty
  did-cli report --customer Crayon --from 2026-01 --to 2026-03 --pretty
  did-cli report --week 15 --pretty
  did-cli submit --period current
  did-cli config --cookie "eyJ..."
  did-cli config --output pretty
"""


def _print_help():
    print(HELP_TEXT)


def _require_value(flag, argv, idx):
    if idx + 1 >= len(argv) or argv[idx + 1].startswith('--'):
        ansi.error(f'Missing value for {flag}')
        sys.exit(1)
    return argv[idx + 1]


def _resolve_output(explicit, config):
    if explicit in ('pretty', 'json'):
        return explicit
    return 'pretty' if config.get('DID_DEFAULT_OUTPUT') == 'pretty' else 'json'


def _resolve_period_keyword(value):
    if value == 'current':
        return dates.current_week(), dates.current_year()
    if value in ('last', 'next'):
        return dates.resolve_week_keyword(value)
    ansi.error(f'Unknown period: {value}. Use current, last, or next.')
    sys.exit(1)


def _cmd_status(argv, config):
    output = ''
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--pretty':
            output = 'pretty'
            i += 1
        elif a == '--json':
            output = 'json'
            i += 1
        else:
            ansi.error(f'Unknown flag: {a}')
            return 1
    from . import status
    return status.do_status(config, _resolve_output(output, config))


def _cmd_report(argv, config):
    customer = project = employee = from_date = to_date = None
    week = year = None
    output = ''
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--customer':
            customer = _require_value(a, argv, i)
            i += 2
        elif a == '--project':
            project = _require_value(a, argv, i)
            i += 2
        elif a == '--employee':
            employee = _require_value(a, argv, i)
            i += 2
        elif a == '--from':
            raw = _require_value(a, argv, i)
            try:
                from_date = dates.validate_date_arg(raw)
            except ValueError as e:
                ansi.error(str(e))
                return 1
            i += 2
        elif a == '--to':
            raw = _require_value(a, argv, i)
            try:
                to_date = dates.validate_date_arg(raw)
            except ValueError as e:
                ansi.error(str(e))
                return 1
            i += 2
        elif a == '--week':
            raw = _require_value(a, argv, i)
            if raw in ('last', 'next'):
                week, year = dates.resolve_week_keyword(raw)
            else:
                try:
                    week = dates.validate_week(raw)
                except ValueError as e:
                    ansi.error(str(e))
                    return 1
            i += 2
        elif a == '--year':
            raw = _require_value(a, argv, i)
            try:
                year = dates.validate_year(raw)
            except ValueError as e:
                ansi.error(str(e))
                return 1
            i += 2
        elif a == '--period':
            raw = _require_value(a, argv, i)
            week, year = _resolve_period_keyword(raw)
            i += 2
        elif a == '--pretty':
            output = 'pretty'
            i += 1
        elif a == '--json':
            output = 'json'
            i += 1
        else:
            ansi.error(f'Unknown flag: {a}')
            return 1

    from . import report
    return report.do_report(
        config,
        _resolve_output(output, config),
        customer=customer, project=project, employee=employee,
        from_date=from_date, to_date=to_date, week=week, year=year,
    )


def _cmd_submit(argv, config):
    week = year = None
    confirm = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--period':
            raw = _require_value(a, argv, i)
            week, year = _resolve_period_keyword(raw)
            i += 2
        elif a == '--week':
            raw = _require_value(a, argv, i)
            if raw in ('last', 'next'):
                week, year = dates.resolve_week_keyword(raw)
            else:
                try:
                    week = dates.validate_week(raw)
                except ValueError as e:
                    ansi.error(str(e))
                    return 1
            i += 2
        elif a == '--year':
            raw = _require_value(a, argv, i)
            try:
                year = dates.validate_year(raw)
            except ValueError as e:
                ansi.error(str(e))
                return 1
            i += 2
        elif a == '--confirm':
            confirm = True
            i += 1
        else:
            ansi.error(f'Unknown flag: {a}')
            return 1

    if week is None:
        week = dates.current_week()
    if year is None:
        year = dates.current_year()

    from . import submit
    return submit.do_submit(config, week, year, confirm)


def _cmd_config(argv, config):
    """View or update config. No args -> print current. With flags -> persist."""
    updates = {}
    i = 0
    flag_to_key = {
        '--url': 'DID_URL',
        '--cookie': 'DID_COOKIE',
        '--output': 'DID_DEFAULT_OUTPUT',
        '--customer-maxlength': 'DID_CUSTOMER_MAXLENGTH',
        '--project-maxlength': 'DID_PROJECT_MAXLENGTH',
        '--pretty-format': 'DID_PRETTY_FORMAT',
    }
    while i < len(argv):
        a = argv[i]
        if a in flag_to_key:
            value = _require_value(a, argv, i)
            if a == '--output' and value not in ('json', 'pretty'):
                ansi.error(f"Invalid output format: {value}. Use 'json' or 'pretty'.")
                return 1
            if a in ('--customer-maxlength', '--project-maxlength'):
                try:
                    n = int(value)
                    if n < 0:
                        raise ValueError
                except ValueError:
                    ansi.error(f'{a} must be a non-negative integer')
                    return 1
            if a == '--pretty-format':
                from .formatting import validate_pretty_format
                err = validate_pretty_format(value)
                if err:
                    ansi.error(err)
                    return 1
            updates[flag_to_key[a]] = value
            i += 2
        else:
            ansi.error(f'Unknown flag: {a}')
            return 1

    if updates:
        # Merge into on-disk config. Do NOT inherit env overrides - we want
        # to write only what the user explicitly set this call.
        from .config import parse_kv_stream
        on_disk = {}
        if CONFIG_PATH.exists():
            on_disk = parse_kv_stream(CONFIG_PATH.read_text())
        on_disk.update(updates)
        save_config(on_disk)
        for key, value in updates.items():
            if key == 'DID_COOKIE':
                ansi.info(f'{key} updated')
            else:
                ansi.info(f'{key} set to {value}')
        return 0

    ansi.info('Current config:')
    ansi.info(f"  DID_URL={config.get('DID_URL', '')}")
    ansi.info(f"  DID_DEFAULT_OUTPUT={config.get('DID_DEFAULT_OUTPUT', 'json')}")
    cookie = config.get('DID_COOKIE') or ''
    if cookie:
        ansi.info(f'  DID_COOKIE={cookie[:20]}...')
    else:
        ansi.info('  DID_COOKIE=<not set>')
    for opt_key in ('DID_CUSTOMER_MAXLENGTH', 'DID_PROJECT_MAXLENGTH',
                    'DID_PRETTY_FORMAT'):
        val = config.get(opt_key)
        if val:
            ansi.info(f'  {opt_key}={val}')
    ansi.info(f'  (config file: {CONFIG_PATH})')
    return 0


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ('help', '--help', '-h'):
        _print_help()
        return 0

    command = argv[0]
    rest = argv[1:]
    config = load_config()

    if command == 'status':
        return _cmd_status(rest, config)
    if command == 'report':
        return _cmd_report(rest, config)
    if command == 'submit':
        return _cmd_submit(rest, config)
    if command == 'config':
        return _cmd_config(rest, config)

    ansi.error(f"Unknown command: {command}. Run 'did-cli help' for usage.")
    return 1
