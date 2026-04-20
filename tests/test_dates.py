import pytest

from did_cli import dates


def test_iso_week_bounds_happy():
    start, end = dates.iso_week_bounds(15, 2026)
    assert start == '2026-04-06'
    assert end == '2026-04-12'


def test_iso_week_bounds_year_boundary():
    # ISO week 1 of 2026 starts Mon 29 Dec 2025
    start, end = dates.iso_week_bounds(1, 2026)
    assert start == '2025-12-29'
    assert end == '2026-01-04'


def test_iso_week_bounds_invalid():
    with pytest.raises(ValueError):
        dates.iso_week_bounds(54, 2026)


def test_validate_week_accepts_range():
    assert dates.validate_week('1') == 1
    assert dates.validate_week('53') == 53


@pytest.mark.parametrize('bad', ['0', '54', 'abc', '', None])
def test_validate_week_rejects(bad):
    with pytest.raises(ValueError):
        dates.validate_week(bad)


def test_validate_year_accepts_four_digits():
    assert dates.validate_year('2026') == 2026


@pytest.mark.parametrize('bad', ['26', '20260', 'abcd', ''])
def test_validate_year_rejects(bad):
    with pytest.raises(ValueError):
        dates.validate_year(bad)


def test_normalize_start_date_yyyymm():
    assert dates.normalize_start_date('2026-04') == '2026-04-01T00:00:00.000Z'


def test_normalize_start_date_yyyymmdd():
    assert dates.normalize_start_date('2026-04-15') == '2026-04-15T00:00:00.000Z'


def test_normalize_end_date_yyyymm_last_day():
    # April has 30 days
    assert dates.normalize_end_date('2026-04') == '2026-04-30T23:59:59.999Z'


def test_normalize_end_date_december_rolls_year():
    assert dates.normalize_end_date('2026-12') == '2026-12-31T23:59:59.999Z'


def test_normalize_end_date_yyyymmdd():
    assert dates.normalize_end_date('2026-04-15') == '2026-04-15T23:59:59.999Z'


def test_friendly_range_same_month():
    assert dates.friendly_date_range_nb('2026-04-07', '2026-04-13') == '7-13. april'


def test_friendly_range_spans_months():
    assert dates.friendly_date_range_nb('2026-03-28', '2026-04-03') == '28. mars - 3. april'


@pytest.mark.parametrize('good', ['2026-04', '2026-04-15', '2026-12-31'])
def test_validate_date_arg_accepts(good):
    assert dates.validate_date_arg(good) == good


@pytest.mark.parametrize('bad', ['2026-13', '2026-99-99', 'banana', '', '2026/04',
                                 '2026-4', '2026-04-1'])
def test_validate_date_arg_rejects(bad):
    with pytest.raises(ValueError):
        dates.validate_date_arg(bad)
