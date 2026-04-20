import os

from did_cli import config


def test_parse_kv_stream_filters_unknown_keys():
    text = """
    DID_URL=did.example
    DID_COOKIE="abc"
    UNKNOWN=ignored
    # comment
    """
    parsed = config.parse_kv_stream(text)
    assert parsed == {'DID_URL': 'did.example', 'DID_COOKIE': 'abc'}


def test_save_and_load_roundtrips(tmp_config, clean_env):
    config.save_config({'DID_URL': 'did.example', 'DID_COOKIE': 'sekret'})
    loaded = config.load_config()
    assert loaded['DID_URL'] == 'did.example'
    assert loaded['DID_COOKIE'] == 'sekret'


def test_save_preserves_comments(tmp_config, clean_env):
    tmp_config.parent.mkdir(parents=True, exist_ok=True)
    tmp_config.write_text('# head\nDID_URL="x"\n# tail\n')
    config.save_config({'DID_URL': 'new', 'DID_COOKIE': 'c'})
    text = tmp_config.read_text()
    assert '# head' in text
    assert '# tail' in text
    assert 'DID_URL="new"' in text
    assert 'DID_COOKIE="c"' in text


def test_env_overrides_file(tmp_config, clean_env, monkeypatch):
    config.save_config({'DID_URL': 'from-file'})
    monkeypatch.setenv('DID_URL', 'from-env')
    assert config.load_config()['DID_URL'] == 'from-env'


def test_file_perms_0600(tmp_config, clean_env):
    config.save_config({'DID_URL': 'x', 'DID_COOKIE': 'secret'})
    mode = oct(os.stat(tmp_config).st_mode & 0o777)
    assert mode == '0o600'


def test_load_config_defaults_when_missing(tmp_config, clean_env):
    # Config file does not exist
    loaded = config.load_config()
    assert loaded['DID_URL'] == 'did.crayonconsulting.no'
    assert loaded['DID_DEFAULT_OUTPUT'] == 'json'


def test_persist_key_does_not_leak_env(tmp_config, clean_env, monkeypatch):
    # Regression: env-only values must never be persisted as a side
    # effect of writing one unrelated key (e.g. display-name caching).
    config.save_config({'DID_URL': 'from-file'})
    monkeypatch.setenv('DID_COOKIE', 'ephemeral')
    monkeypatch.setenv('DID_DEFAULT_OUTPUT', 'pretty')

    config.persist_key('DID_USER_DISPLAY_NAME', 'Kim')

    text = tmp_config.read_text()
    assert 'DID_USER_DISPLAY_NAME="Kim"' in text
    assert 'DID_URL="from-file"' in text
    assert 'DID_COOKIE' not in text
    assert 'DID_DEFAULT_OUTPUT' not in text
