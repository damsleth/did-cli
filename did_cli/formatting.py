"""Pretty-printing for report output.

Two modes: flat table (default) and day-grouped (used for --week
queries). An optional DID_PRETTY_FORMAT JSON column spec lets the
user override headers/widths/fields per column.
"""
import json
from datetime import datetime

from .ansi import bold
from .dates import MONTH_EN, WEEKDAY_EN


def _pad(s, n):
    s = str(s)
    return s + (' ' * max(0, n - len(s)))


def _trunc(s, n):
    s = '' if s is None else str(s)
    if n > 0:
        return _pad(s[:n], n)
    return _pad(s, 30)


def _get_field(row, path):
    parts = path.split('.')
    cur = row
    for p in parts:
        if cur is None:
            return ''
        cur = cur.get(p) if isinstance(cur, dict) else None
    return '' if cur is None else cur


def validate_pretty_format(pretty_format):
    """Return None if valid, otherwise a human-readable error string.

    Valid shape: JSON array of [field:str, header:str, width:int]
    tuples. Called by the CLI before persisting and by _load_spec
    before rendering; a bad persisted value should produce a clean
    error message, not a traceback.
    """
    if not pretty_format:
        return None
    try:
        spec = json.loads(pretty_format)
    except json.JSONDecodeError:
        return 'Invalid JSON for --pretty-format'
    if not isinstance(spec, list) or not spec:
        return '--pretty-format must be a non-empty JSON array'
    for col in spec:
        if (not isinstance(col, list) or len(col) != 3
                or not isinstance(col[0], str)
                or not isinstance(col[1], str)
                or not isinstance(col[2], int)):
            return '--pretty-format entries must be [field, header, width]'
    return None


def _load_spec(pretty_format):
    """Parse DID_PRETTY_FORMAT JSON or return None. Silently rejects
    structurally invalid values; the CLI has already validated user
    input, so we only reach this with a bad persisted/env value."""
    if not pretty_format or validate_pretty_format(pretty_format) is not None:
        return None
    return json.loads(pretty_format)


def _sum_duration(entries):
    total = 0.0
    for e in entries:
        d = e.get('duration')
        if isinstance(d, (int, float)):
            total += d
    return round(total * 100) / 100


def format_hours(entries, cmax=0, pmax=0, pretty_format=None):
    """Flat table: Customer | Project | Hours + grand total."""
    spec = _load_spec(pretty_format)
    lines = []

    if spec:
        header = ''.join(_trunc(col[1], col[2]) for col in spec)
        sep = ''.join(_trunc('---', col[2]) for col in spec)
        lines.append(header)
        lines.append(sep)
        for row in entries:
            lines.append(''.join(_trunc(_get_field(row, col[0]), col[2]) for col in spec))
    else:
        lines.append(f'{_trunc("Customer", cmax)}{_trunc("Project", pmax)}Hours')
        lines.append(f'{_trunc("---", cmax)}{_trunc("---", pmax)}---')
        for row in entries:
            c = _get_field(row, 'customer.name')
            p = _get_field(row, 'project.name')
            d = row.get('duration', 0)
            lines.append(f'{_trunc(c, cmax)}{_trunc(p, pmax)}{d}')

    lines.append('')
    lines.append(f'Total: {_sum_duration(entries)} hours')
    return '\n'.join(lines)


def _week_header(days, week_num):
    """'Week 15 (7-13 April)' or spanning variant."""
    if not days or not week_num:
        return ''
    first = days[0][0]['startDateTime'][:10]
    last = days[-1][0]['startDateTime'][:10]
    fd = int(first[8:10])
    ld = int(last[8:10])
    fm = MONTH_EN[int(first[5:7])]
    lm = MONTH_EN[int(last[5:7])]
    if fm == lm:
        return f'Week {week_num} ({fd}-{ld} {fm})'
    return f'Week {week_num} ({fd} {fm} - {ld} {lm})'


def format_hours_by_day(entries, week_num=0, cmax=0, pmax=0, pretty_format=None,
                        use_color=False):
    """Day-grouped layout for weekly reports.

    Entries without a startDateTime are rendered under an
    'Unknown date' bucket at the end so the grand total here matches
    the flat/JSON totals for the same dataset. Silently dropping
    those rows would hide data problems.
    """
    spec = _load_spec(pretty_format)
    with_start = sorted((e for e in entries if e.get('startDateTime')),
                        key=lambda e: e['startDateTime'])
    undated = [e for e in entries if not e.get('startDateTime')]

    days = []
    current_day_key = None
    for e in with_start:
        key = e['startDateTime'][:10]
        if key != current_day_key:
            days.append([])
            current_day_key = key
        days[-1].append(e)

    lines = []
    if week_num:
        header = _week_header(days, week_num) if days else f'Week {week_num}'
        lines.append(bold(header, force=use_color))
        lines.append('')

    def _render_row(row):
        if spec:
            return '  ' + ''.join(_trunc(_get_field(row, c[0]), c[2]) for c in spec)
        c = _get_field(row, 'customer.name')
        p = _get_field(row, 'project.name')
        d = row.get('duration') or 0
        return f'  {_trunc(c, cmax)}{_trunc(p, pmax)}{d}h'

    for day in days:
        day_total = round(sum((e.get('duration') or 0) for e in day) * 100) / 100
        date_str = day[0]['startDateTime'][:10]
        dt = datetime.strptime(date_str, '%Y-%m-%d')
        weekday = WEEKDAY_EN[dt.isoweekday()]
        lines.append(bold(f'{weekday} {dt.day} ({day_total}h)', force=use_color))
        for row in day:
            lines.append(_render_row(row))
        lines.append('')

    if undated:
        undated_total = round(sum((e.get('duration') or 0) for e in undated) * 100) / 100
        lines.append(bold(f'Unknown date ({undated_total}h)', force=use_color))
        for row in undated:
            lines.append(_render_row(row))
        lines.append('')

    grand = round(sum((e.get('duration') or 0) for e in entries) * 100) / 100
    lines.append(bold(f'Total: {grand}h', force=use_color))
    return '\n'.join(lines)
