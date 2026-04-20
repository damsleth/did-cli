"""`did-cli submit` - confirm a timesheet period."""
import json
import sys

from . import ansi, dates, gql


def _build_matched_events(events):
    """Build the matchedEvents array expected by submitPeriod."""
    out = []
    for e in events:
        if not e.get('project'):
            continue
        out.append({
            'id': e.get('id'),
            'projectId': (e.get('project') or {}).get('tag'),
            'manualMatch': False,
            'duration': e.get('duration'),
            'originalDuration': e.get('originalDuration'),
            'adjustedMinutes': e.get('adjustedMinutes'),
        })
    return out


def do_submit(config, week, year, confirm):
    try:
        dates.validate_week(week)
        dates.validate_year(year)
        start_d, end_d = dates.iso_week_bounds(week, year)
    except ValueError as e:
        ansi.error(str(e))
        return 1

    ansi.debug(f'Fetching timesheet for week {week}/{year} ({start_d} to {end_d})')

    tz = dates.current_tz_offset_minutes()
    ts_vars = {
        'query': {'startDate': start_d, 'endDate': end_d},
        'options': {'locale': 'nb', 'dateFormat': 'DD.MM.YYYY', 'tzOffset': tz},
    }
    ts_data = gql.call('timesheet.graphql', ts_vars, config)
    if ts_data is None:
        return 1

    period = None
    for p in ts_data.get('periods') or []:
        if p.get('week') == week:
            period = p
            break

    if not period:
        ansi.error(f'No period found for week {week}/{year}')
        return 1

    if period.get('isConfirmed'):
        ansi.info(f'Week {week}/{year} is already submitted.')
        return 0

    events = period.get('events') or []
    total_hours = round(sum((e.get('duration') or 0) for e in events) * 100) / 100

    ansi.info(f'Week {week}/{year}: {len(events)} events, {total_hours}h total')
    ansi.info(f"Period: {period.get('startDate')} to {period.get('endDate')}")

    if not confirm:
        prompt = ansi.yellow('Submit this period? (y/N): ')
        sys.stderr.write(prompt)
        sys.stderr.flush()
        answer = sys.stdin.readline().strip()
        if answer not in ('y', 'Y'):
            ansi.info('Aborted.')
            return 0

    submit_vars = {
        'period': {
            'id': period.get('id'),
            'startDate': period.get('startDate'),
            'endDate': period.get('endDate'),
            'matchedEvents': _build_matched_events(events),
            'forecastedHours': period.get('forecastedHours') or 0,
        },
        'options': {'locale': 'nb', 'dateFormat': 'DD.MM.YYYY', 'tzOffset': tz},
    }

    result = gql.call('submit-period.graphql', submit_vars, config)
    if result is None:
        return 1

    success = (result.get('result') or {}).get('success')
    if success:
        ansi.info(f'Week {week}/{year} submitted successfully!')
        print(json.dumps(result, indent=2))
        return 0

    err_msg = 'Unknown error'
    err = (result.get('result') or {}).get('error')
    if isinstance(err, dict):
        err_msg = err.get('message', err_msg)
    ansi.error(f'Submission failed: {err_msg}')
    return 1
