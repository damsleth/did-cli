"""Date helpers: ISO week math, Norwegian-friendly range formatting.

All functions are pure. Tests live in tests/test_dates.py.
"""
import time
from datetime import datetime, timedelta

WEEKDAY_EN = {
    1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday',
    5: 'Friday', 6: 'Saturday', 7: 'Sunday',
}
MONTH_EN = {
    1: 'January', 2: 'February', 3: 'March', 4: 'April', 5: 'May', 6: 'June',
    7: 'July', 8: 'August', 9: 'September', 10: 'October', 11: 'November',
    12: 'December',
}
MONTH_NB = {
    1: 'januar', 2: 'februar', 3: 'mars', 4: 'april', 5: 'mai', 6: 'juni',
    7: 'juli', 8: 'august', 9: 'september', 10: 'oktober', 11: 'november',
    12: 'desember',
}


def current_tz_offset_minutes():
    """Minutes east of UTC. Mirrors the zsh helper; the did API wants this
    as tzOffset in its timesheet query."""
    return -time.timezone // 60 if time.daylight == 0 else -time.altzone // 60


def current_year():
    return int(time.strftime('%Y'))


def current_week():
    return int(time.strftime('%V'))


def current_month():
    return int(time.strftime('%m'))


def first_of_month():
    return time.strftime('%Y-%m-01')


def today():
    return time.strftime('%Y-%m-%d')


def iso_week_bounds(week, year):
    """Return (monday, sunday) as YYYY-MM-DD strings for the ISO week.
    Raises ValueError if the combination is invalid."""
    start = datetime.strptime(f'{year}-W{int(week):02d}-1', '%G-W%V-%u')
    end = start + timedelta(days=6)
    return start.strftime('%Y-%m-%d'), end.strftime('%Y-%m-%d')


def resolve_week_keyword(val):
    """Resolve 'last'/'next' to (week, year). For numeric input returns
    (int(val), None) so the caller knows year wasn't implied."""
    if val == 'last':
        d = datetime.now() - timedelta(weeks=1)
    elif val == 'next':
        d = datetime.now() + timedelta(weeks=1)
    else:
        return int(val), None
    return int(d.strftime('%V')), int(d.strftime('%G'))


def validate_week(week):
    try:
        w = int(week)
    except (TypeError, ValueError):
        raise ValueError(f"Invalid week '{week}'. Use an ISO week number from 1 to 53.")
    if w < 1 or w > 53:
        raise ValueError(f"Invalid week '{week}'. Use an ISO week number from 1 to 53.")
    return w


def validate_year(year):
    s = str(year)
    if not (s.isdigit() and len(s) == 4):
        raise ValueError(f"Invalid year '{year}'. Use a four-digit year.")
    return int(s)


def validate_date_arg(d):
    """Validate a --from / --to value. Accepts YYYY-MM or YYYY-MM-DD.
    Raises ValueError with a user-facing message. Returns the input
    unchanged on success so call sites can chain it."""
    if not isinstance(d, str):
        raise ValueError(f"Invalid date '{d}'. Use YYYY-MM or YYYY-MM-DD.")
    try:
        if len(d) == 7 and d[4] == '-':
            datetime.strptime(d, '%Y-%m')
            return d
        if len(d) == 10 and d[4] == '-' and d[7] == '-':
            datetime.strptime(d, '%Y-%m-%d')
            return d
    except ValueError:
        pass
    raise ValueError(f"Invalid date '{d}'. Use YYYY-MM or YYYY-MM-DD.")


def normalize_start_date(d):
    """YYYY-MM -> YYYY-MM-01T00:00:00.000Z.
    YYYY-MM-DD -> YYYY-MM-DDT00:00:00.000Z.
    Anything else passes through unchanged (caller validated it)."""
    if len(d) == 7 and d[4] == '-':
        return f'{d}-01T00:00:00.000Z'
    if len(d) == 10 and d[4] == '-' and d[7] == '-':
        return f'{d}T00:00:00.000Z'
    return d


def normalize_end_date(d):
    """YYYY-MM -> last day of month T23:59:59.999Z.
    YYYY-MM-DD -> YYYY-MM-DDT23:59:59.999Z."""
    if len(d) == 7 and d[4] == '-':
        year, month = int(d[:4]), int(d[5:7])
        if month == 12:
            nxt = datetime(year + 1, 1, 1)
        else:
            nxt = datetime(year, month + 1, 1)
        last = nxt - timedelta(days=1)
        return last.strftime('%Y-%m-%d') + 'T23:59:59.999Z'
    if len(d) == 10 and d[4] == '-' and d[7] == '-':
        return f'{d}T23:59:59.999Z'
    return d


def friendly_date_range_nb(start, end):
    """'7-13. april' if same month, '28. mars - 3. april' otherwise.
    Input: ISO date strings (first 10 chars used)."""
    s = datetime.strptime(start[:10], '%Y-%m-%d')
    e = datetime.strptime(end[:10], '%Y-%m-%d')
    sm = MONTH_NB[s.month]
    em = MONTH_NB[e.month]
    if s.month == e.month:
        return f'{s.day}-{e.day}. {sm}'
    return f'{s.day}. {sm} - {e.day}. {em}'
