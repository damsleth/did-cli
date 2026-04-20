"""`did-cli status` - show current period, time bank, and vacation."""
import json
import sys

from . import ansi, dates, gql


def _get(d, *path, default=None):
    for key in path:
        if not isinstance(d, dict):
            return default
        d = d.get(key)
    return default if d is None else d


def _fetch_current_period(config):
    """Return the Timesheet period dict for the current ISO week."""
    week = dates.current_week()
    year = dates.current_year()
    try:
        start_d, end_d = dates.iso_week_bounds(week, year)
    except ValueError as e:
        ansi.error(str(e))
        return None, week
    variables = {
        'query': {'startDate': start_d, 'endDate': end_d},
        'options': {
            'locale': 'nb',
            'dateFormat': 'DD.MM.YYYY',
            'tzOffset': dates.current_tz_offset_minutes(),
        },
    }
    ts = gql.call('timesheet.graphql', variables, config)
    if ts is None:
        return None, week
    for p in ts.get('periods') or []:
        if p.get('week') == week:
            return p, week
    return None, week


def do_status(config, output):
    ansi.info(f"Fetching status from {config.get('DID_URL', '')}...")
    data = gql.call('status.graphql', {}, config)
    if data is None:
        return 1

    period, week = _fetch_current_period(config)

    if output == 'pretty':
        display_name = _get(data, 'user', 'displayName', default='Unknown')
        balance = _get(data, 'user', 'timebank', 'balance', default='N/A')
        vac_total = _get(data, 'vacation', 'total', default='N/A')
        vac_used = _get(data, 'vacation', 'used', default='N/A')
        vac_remaining = _get(data, 'vacation', 'remaining', default='N/A')

        status_line = 'n/a'
        events = 0
        total_hours = 0
        friendly = '?'
        if period:
            is_confirmed = bool(period.get('isConfirmed'))
            events = len(period.get('events') or [])
            total_hours = round(
                sum((e.get('duration') or 0) for e in (period.get('events') or [])) * 100
            ) / 100
            status_line = (ansi.green('submitted') if is_confirmed
                           else ansi.yellow('not submitted'))
            try:
                friendly = dates.friendly_date_range_nb(
                    period.get('startDate') or '',
                    period.get('endDate') or '',
                )
            except Exception:
                friendly = f"{period.get('startDate')} - {period.get('endDate')}"

        print(f'Status for {ansi.cyan(display_name)}', file=sys.stderr)
        print('', file=sys.stderr)
        print(f'Current period (week {week}, {friendly}): {status_line}',
              file=sys.stderr)
        print(f'  {events} events, {total_hours}h', file=sys.stderr)
        print('', file=sys.stderr)
        print(f'Time bank balance: {ansi.cyan(f"{balance}h")}', file=sys.stderr)
        print(
            f'Vacation: {ansi.cyan(vac_used)}/{ansi.cyan(vac_total)} days used, '
            f'{ansi.cyan(vac_remaining)} remaining',
            file=sys.stderr,
        )
        return 0

    merged = dict(data) if isinstance(data, dict) else {}
    merged['currentPeriod'] = period
    print(json.dumps(merged, indent=2))
    return 0
