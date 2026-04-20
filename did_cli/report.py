"""`did-cli report` - query time entries with filters."""
import json
import sys

from . import ansi, dates, formatting, gql
from .config import persist_key


def _get_display_name(config):
    """Fetch + cache the current user's displayName."""
    cached = (config.get('DID_USER_DISPLAY_NAME') or '').strip()
    if cached:
        return cached
    ansi.debug('Fetching display name (first time)...')
    data = gql.call('status.graphql', {}, config)
    if data is None:
        return None
    name = (data.get('user') or {}).get('displayName')
    if name:
        config['DID_USER_DISPLAY_NAME'] = name
        try:
            # Write only the display name. Using save_config(config) here
            # would persist env-only values like DID_COOKIE back to disk.
            persist_key('DID_USER_DISPLAY_NAME', name)
        except Exception as e:
            ansi.debug(f'could not cache displayName: {e}')
        return name
    return None


def _validate_customer_project(customer, project, config):
    """Return (customer, project) with API-canonical casing, or None on
    unresolvable name. Prints suggestions to stderr."""
    if not customer and not project:
        return customer, project

    ansi.debug('Validating filter names...')
    data = gql.call('filter-options.graphql', {}, config)
    if data is None:
        return None

    opts = data.get('filterOptions') or {}
    cust_names = opts.get('customerNames') or []
    proj_names = opts.get('projectNames') or []

    def _resolve(value, available, label, limit=None):
        if not value:
            return value
        low = value.lower()
        exact = [n for n in available if n.lower() == low]
        if exact:
            return exact[0]
        ansi.error(f"{label} '{value}' not found.")
        partial = [n for n in available if low in n.lower()]
        if partial:
            ansi.info(f"Did you mean: {', '.join(partial)}")
        else:
            ansi.info(f'Available {label.lower()}s:')
            shown = available[:limit] if limit else available
            for n in shown:
                ansi.info(f'  {n}')
        return None

    resolved_c = _resolve(customer, cust_names, 'Customer')
    if customer and resolved_c is None:
        return None
    resolved_p = _resolve(project, proj_names, 'Project', limit=20)
    if project and resolved_p is None:
        return None
    return resolved_c, resolved_p


def _build_query(customer, project, employee, from_date, to_date, week, year):
    q = {}
    if employee:
        q['employeeNames'] = [employee]
    if customer:
        q['customerNames'] = [customer]
    if project:
        q['projectNames'] = [project]
    if from_date:
        q['startDateTime'] = dates.normalize_start_date(from_date)
    if to_date:
        q['endDateTime'] = dates.normalize_end_date(to_date)
    if week is not None:
        q['week'] = week
        q['year'] = year if year is not None else dates.current_year()
    elif year is not None:
        q['year'] = year

    # Default date range: first of current month -> today
    if not from_date and not to_date and week is None:
        q['startDateTime'] = f'{dates.first_of_month()}T00:00:00.000Z'
        q['endDateTime'] = f'{dates.today()}T23:59:59.999Z'
    return {'query': q} if q else {}


def _period_submitted_label(config, week, year):
    """For week-based pretty output: fetch the period and return a
    coloured status label, or None on failure."""
    try:
        start_d, end_d = dates.iso_week_bounds(week, year)
    except ValueError:
        return None
    ts_vars = {
        'query': {'startDate': start_d, 'endDate': end_d},
        'options': {
            'locale': 'nb',
            'dateFormat': 'DD.MM.YYYY',
            'tzOffset': dates.current_tz_offset_minutes(),
        },
    }
    ts = gql.call('timesheet.graphql', ts_vars, config)
    if ts is None:
        return None
    for p in ts.get('periods') or []:
        if p.get('week') == week:
            return ansi.green('submitted') if p.get('isConfirmed') else ansi.yellow('not submitted')
    return None


def do_report(config, output, customer, project, employee, from_date, to_date,
              week, year):
    # Resolve current user as default employee; 'all' means all employees.
    if employee is None:
        employee = _get_display_name(config)
        if employee is None:
            return 1
    elif employee == 'all':
        employee = None

    resolved = _validate_customer_project(customer, project, config)
    if resolved is None:
        return 1
    customer, project = resolved

    variables = _build_query(customer, project, employee, from_date, to_date,
                             week, year)

    ansi.info(f"Querying hours from {config.get('DID_URL', '')}...")
    data = gql.call('report.graphql', variables, config)
    if data is None:
        return 1

    entries = data.get('timeEntries') or []

    if output == 'pretty':
        def _int_or_err(key):
            raw = config.get(key) or 0
            try:
                n = int(raw)
                if n < 0:
                    raise ValueError
                return n
            except (TypeError, ValueError):
                ansi.error(f'{key}={raw!r} is not a non-negative integer.')
                return None

        cmax = _int_or_err('DID_CUSTOMER_MAXLENGTH')
        pmax = _int_or_err('DID_PROJECT_MAXLENGTH')
        if cmax is None or pmax is None:
            return 1
        pretty_fmt = config.get('DID_PRETTY_FORMAT') or ''
        spec_err = formatting.validate_pretty_format(pretty_fmt)
        if spec_err:
            ansi.error(f'DID_PRETTY_FORMAT is invalid: {spec_err}')
            return 1
        if week is not None:
            label = _period_submitted_label(
                config, week, year if year is not None else dates.current_year()
            )
            if label:
                print(label, file=sys.stderr)
            print(formatting.format_hours_by_day(
                entries, week_num=week, cmax=cmax, pmax=pmax,
                pretty_format=pretty_fmt, use_color=sys.stdout.isatty(),
            ))
        else:
            print(formatting.format_hours(
                entries, cmax=cmax, pmax=pmax, pretty_format=pretty_fmt,
            ))
        return 0

    print(json.dumps(data, indent=2))
    return 0
