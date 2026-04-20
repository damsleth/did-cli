import pytest

from did_cli import formatting


SAMPLE = [
    {'customer': {'name': 'Crayon'}, 'project': {'name': 'Alpha'}, 'duration': 2.5,
     'startDateTime': '2026-04-06T09:00:00.000Z'},
    {'customer': {'name': 'Crayon'}, 'project': {'name': 'Alpha'}, 'duration': 1.5,
     'startDateTime': '2026-04-06T14:00:00.000Z'},
    {'customer': {'name': 'Acme'}, 'project': {'name': 'Beta'}, 'duration': 3.0,
     'startDateTime': '2026-04-07T10:00:00.000Z'},
]


def test_format_hours_has_total():
    out = formatting.format_hours(SAMPLE, cmax=10, pmax=10)
    assert 'Total: 7.0 hours' in out
    assert 'Customer' in out
    assert 'Crayon' in out


def test_format_hours_rounds_to_two_decimals():
    entries = [{'customer': {'name': 'A'}, 'project': {'name': 'B'}, 'duration': 1.111}]
    out = formatting.format_hours(entries, cmax=5, pmax=5)
    # 1.111 * 100 = 111.1, round = 111, /100 = 1.11
    assert 'Total: 1.11 hours' in out


def test_format_hours_by_day_groups_and_totals():
    out = formatting.format_hours_by_day(SAMPLE, week_num=15, cmax=10, pmax=10,
                                         use_color=False)
    assert 'Week 15' in out
    assert 'Monday 6' in out  # 2026-04-06 is a Monday
    assert 'Tuesday 7' in out
    assert 'Total: 7.0h' in out


def test_format_hours_custom_spec():
    spec = '[["customer.name","Kunde",10],["duration","Timer",0]]'
    out = formatting.format_hours(SAMPLE, pretty_format=spec)
    assert 'Kunde' in out
    assert 'Timer' in out


def test_format_hours_by_day_no_color_by_default():
    out = formatting.format_hours_by_day(SAMPLE, week_num=15, use_color=False)
    assert '\x1b[' not in out


def test_format_hours_by_day_with_color():
    out = formatting.format_hours_by_day(SAMPLE, week_num=15, use_color=True)
    assert '\x1b[1m' in out  # bold header


def test_format_hours_by_day_includes_undated_in_total():
    # Grand total must match flat total even when an entry is missing
    # startDateTime. The prior filtered-list total would silently drop it.
    entries = SAMPLE + [{'customer': {'name': 'Zed'}, 'project': {'name': 'X'},
                        'duration': 2.0}]
    out = formatting.format_hours_by_day(entries, week_num=15, cmax=10, pmax=10,
                                         use_color=False)
    assert 'Unknown date' in out
    assert 'Total: 9.0h' in out


@pytest.mark.parametrize('bad', [
    'not-json',
    '{"not":"a list"}',
    '[]',
    '[["only-two","items"]]',
    '[[1,2,3]]',
    '[["field","header","not-int"]]',
])
def test_validate_pretty_format_rejects(bad):
    assert formatting.validate_pretty_format(bad) is not None


def test_validate_pretty_format_accepts_good_spec():
    assert formatting.validate_pretty_format(
        '[["customer.name","Kunde",15],["duration","Timer",5]]'
    ) is None


def test_validate_pretty_format_accepts_empty():
    assert formatting.validate_pretty_format('') is None
    assert formatting.validate_pretty_format(None) is None
