"""Shared fixtures for the did-cli test suite.

No network. No real cookies. No writes outside tmp_path.
"""
import pytest


@pytest.fixture
def tmp_config(tmp_path, monkeypatch):
    """Redirect did_cli.config.CONFIG_PATH under tmp_path. Patch every module
    that re-imported the name."""
    fake = tmp_path / 'did-cli' / 'config'
    from did_cli import config as config_mod
    monkeypatch.setattr(config_mod, 'CONFIG_PATH', fake)
    from did_cli import cli as cli_mod
    monkeypatch.setattr(cli_mod, 'CONFIG_PATH', fake, raising=False)
    return fake


@pytest.fixture
def clean_env(monkeypatch):
    """Strip DID_* env vars so tests start from a known state."""
    for key in ('DID_URL', 'DID_COOKIE', 'DID_DEFAULT_OUTPUT',
                'DID_CUSTOMER_MAXLENGTH', 'DID_PROJECT_MAXLENGTH',
                'DID_PRETTY_FORMAT', 'DID_USER_DISPLAY_NAME', 'DID_DEBUG'):
        monkeypatch.delenv(key, raising=False)
