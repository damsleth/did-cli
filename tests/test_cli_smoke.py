"""CLI smoke tests.

Exercises argument parsing and dispatch without hitting the network.
gql.call is monkeypatched on a per-test basis when needed. No real
cookies, no config writes outside tmp_path, no HTTP.
"""
import sys

import pytest

from did_cli import cli as cli_mod


def _run(monkeypatch, argv):
    monkeypatch.setattr(sys, 'argv', ['did-cli'] + list(argv))
    return cli_mod.main()


def test_help_exits_zero(monkeypatch, capsys):
    rc = _run(monkeypatch, ['help'])
    assert rc == 0
    out = capsys.readouterr().out
    assert 'did-cli' in out
    for flag in ('status', 'report', 'submit', 'config'):
        assert flag in out


def test_short_help_alias(monkeypatch, capsys):
    rc = _run(monkeypatch, ['-h'])
    assert rc == 0
    assert 'did-cli' in capsys.readouterr().out


def test_no_args_shows_help(monkeypatch, capsys):
    rc = _run(monkeypatch, [])
    assert rc == 0
    assert 'did-cli' in capsys.readouterr().out


def test_unknown_command_fails_fast(monkeypatch, capsys):
    rc = _run(monkeypatch, ['nonsense'])
    assert rc != 0
    assert 'Unknown command' in capsys.readouterr().err


def test_missing_flag_value_fails_fast(monkeypatch, capsys, tmp_config, clean_env):
    with pytest.raises(SystemExit) as exc:
        _run(monkeypatch, ['report', '--week'])
    assert exc.value.code == 1
    assert 'Missing value for --week' in capsys.readouterr().err


def test_invalid_week_rejected_without_side_effects(monkeypatch, capsys, tmp_config,
                                                    clean_env):
    rc = _run(monkeypatch, ['submit', '--week', '999', '--year', '2026'])
    assert rc != 0
    assert 'Invalid week' in capsys.readouterr().err


def test_config_without_args_prints_current(monkeypatch, capsys, tmp_config,
                                            clean_env):
    rc = _run(monkeypatch, ['config'])
    assert rc == 0
    err = capsys.readouterr().err
    assert 'DID_URL=' in err
    assert 'DID_DEFAULT_OUTPUT=' in err


def test_config_cookie_persists_to_file(monkeypatch, capsys, tmp_config, clean_env):
    rc = _run(monkeypatch, ['config', '--cookie', 'eyJfake'])
    assert rc == 0
    assert tmp_config.exists()
    text = tmp_config.read_text()
    assert 'DID_COOKIE="eyJfake"' in text


def test_config_output_validates(monkeypatch, capsys, tmp_config, clean_env):
    rc = _run(monkeypatch, ['config', '--output', 'fancy'])
    assert rc != 0
    assert 'Invalid output format' in capsys.readouterr().err


def test_config_pretty_format_rejects_bad_json(monkeypatch, capsys, tmp_config,
                                               clean_env):
    rc = _run(monkeypatch, ['config', '--pretty-format', 'not-json'])
    assert rc != 0
    assert 'Invalid JSON' in capsys.readouterr().err


def test_status_surfaces_missing_cookie(monkeypatch, capsys, tmp_config, clean_env):
    rc = _run(monkeypatch, ['status'])
    assert rc != 0
    assert 'DID_COOKIE' in capsys.readouterr().err


def test_report_json_output(monkeypatch, capsys, tmp_config, clean_env):
    from did_cli import config, gql, report
    config.save_config({'DID_COOKIE': 'c', 'DID_USER_DISPLAY_NAME': 'Kim'})

    calls = []

    def fake_call(query_file, variables, cfg):
        calls.append(query_file)
        if query_file == 'filter-options.graphql':
            return {'filterOptions': {'customerNames': ['Crayon'],
                                      'projectNames': [], 'parentProjectNames': [],
                                      'partnerNames': [], 'employeeNames': []}}
        if query_file == 'report.graphql':
            return {'timeEntries': [
                {'customer': {'name': 'Crayon'}, 'project': {'name': 'Alpha'},
                 'duration': 4.0,
                 'startDateTime': '2026-04-06T09:00:00.000Z'},
            ]}
        return {}

    monkeypatch.setattr(gql, 'call', fake_call)
    monkeypatch.setattr(report.gql, 'call', fake_call)

    rc = _run(monkeypatch, ['report', '--customer', 'Crayon', '--json'])
    assert rc == 0
    out = capsys.readouterr().out
    assert 'timeEntries' in out
    assert 'Crayon' in out
    assert 'report.graphql' in calls


def test_report_pretty_output(monkeypatch, capsys, tmp_config, clean_env):
    from did_cli import config, gql, report
    config.save_config({'DID_COOKIE': 'c', 'DID_USER_DISPLAY_NAME': 'Kim'})

    def fake_call(query_file, variables, cfg):
        if query_file == 'filter-options.graphql':
            return {'filterOptions': {'customerNames': ['Crayon'],
                                      'projectNames': [], 'parentProjectNames': [],
                                      'partnerNames': [], 'employeeNames': []}}
        if query_file == 'report.graphql':
            return {'timeEntries': [
                {'customer': {'name': 'Crayon'}, 'project': {'name': 'Alpha'},
                 'duration': 4.0,
                 'startDateTime': '2026-04-06T09:00:00.000Z'},
            ]}
        return {}

    monkeypatch.setattr(gql, 'call', fake_call)
    monkeypatch.setattr(report.gql, 'call', fake_call)

    rc = _run(monkeypatch, ['report', '--customer', 'Crayon', '--pretty'])
    assert rc == 0
    out = capsys.readouterr().out
    assert 'Customer' in out
    assert 'Crayon' in out
    assert 'Total:' in out


def test_report_invalid_from_date_rejected(monkeypatch, capsys, tmp_config, clean_env):
    rc = _run(monkeypatch, ['report', '--from', 'banana'])
    assert rc != 0
    assert 'Invalid date' in capsys.readouterr().err


def test_report_invalid_to_date_rejected(monkeypatch, capsys, tmp_config, clean_env):
    rc = _run(monkeypatch, ['report', '--to', '2026-13'])
    assert rc != 0
    assert 'Invalid date' in capsys.readouterr().err


def test_config_rejects_non_int_maxlength(monkeypatch, capsys, tmp_config, clean_env):
    rc = _run(monkeypatch, ['config', '--customer-maxlength', 'abc'])
    assert rc != 0
    assert 'non-negative integer' in capsys.readouterr().err


def test_config_rejects_malformed_pretty_format(monkeypatch, capsys, tmp_config,
                                                clean_env):
    # Structurally valid JSON but wrong shape.
    rc = _run(monkeypatch, ['config', '--pretty-format', '[["only","two"]]'])
    assert rc != 0
    assert '--pretty-format' in capsys.readouterr().err


def test_report_pretty_fails_clean_on_bad_persisted_maxlength(monkeypatch, capsys,
                                                              tmp_config, clean_env):
    from did_cli import config, gql, report
    # Simulate a previously persisted bad value.
    config.save_config({'DID_COOKIE': 'c', 'DID_USER_DISPLAY_NAME': 'Kim',
                        'DID_CUSTOMER_MAXLENGTH': 'abc'})

    def fake_call(query_file, variables, cfg):
        if query_file == 'filter-options.graphql':
            return {'filterOptions': {'customerNames': ['Crayon'],
                                      'projectNames': [], 'parentProjectNames': [],
                                      'partnerNames': [], 'employeeNames': []}}
        return {'timeEntries': []}

    monkeypatch.setattr(gql, 'call', fake_call)
    monkeypatch.setattr(report.gql, 'call', fake_call)

    rc = _run(monkeypatch, ['report', '--customer', 'Crayon', '--pretty'])
    assert rc != 0
    assert 'DID_CUSTOMER_MAXLENGTH' in capsys.readouterr().err


def test_report_unknown_customer_suggests(monkeypatch, capsys, tmp_config,
                                          clean_env):
    from did_cli import config, gql, report
    config.save_config({'DID_COOKIE': 'c', 'DID_USER_DISPLAY_NAME': 'Kim'})

    def fake_call(query_file, variables, cfg):
        if query_file == 'filter-options.graphql':
            return {'filterOptions': {'customerNames': ['Crayon', 'Acme'],
                                      'projectNames': [], 'parentProjectNames': [],
                                      'partnerNames': [], 'employeeNames': []}}
        pytest.fail('should not reach report query')

    monkeypatch.setattr(gql, 'call', fake_call)
    monkeypatch.setattr(report.gql, 'call', fake_call)

    rc = _run(monkeypatch, ['report', '--customer', 'cray'])
    assert rc != 0
    err = capsys.readouterr().err
    assert 'not found' in err
    assert 'Crayon' in err
