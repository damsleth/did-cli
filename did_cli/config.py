"""Config file I/O.

Stores the did session cookie and a handful of display preferences as
KEY=value lines under ~/.config/did-cli/config. Writes are atomic
(temp file + fsync + rename) so a crashed write cannot leave the only
live session cookie truncated.

Environment variables override the on-disk config for the same keys,
matching the owa-piggy convention. DID_USER_DISPLAY_NAME is cached
automatically on first successful status query.
"""
import os
import tempfile
from pathlib import Path

CONFIG_PATH = Path.home() / '.config' / 'did-cli' / 'config'

ALLOWED_KEYS = (
    'DID_URL',
    'DID_COOKIE',
    'DID_DEFAULT_OUTPUT',
    'DID_CUSTOMER_MAXLENGTH',
    'DID_PROJECT_MAXLENGTH',
    'DID_PRETTY_FORMAT',
    'DID_USER_DISPLAY_NAME',
    'DID_DEBUG',
)

DEFAULTS = {
    'DID_URL': 'did.crayonconsulting.no',
    'DID_DEFAULT_OUTPUT': 'json',
}


def parse_kv_stream(text):
    """Parse KEY=value lines. Only recognises known DID_* keys."""
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, _, v = line.partition('=')
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k in ALLOWED_KEYS:
            out[k] = v
    return out


def load_config():
    """Return merged config dict. File < env. Missing values get defaults."""
    config = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        config.update(parse_kv_stream(CONFIG_PATH.read_text()))
    for key in ALLOWED_KEYS:
        if key in os.environ:
            config[key] = os.environ[key]
    return config


def save_config(config):
    """Atomically rewrite the config file, preserving comments and key order
    where possible. Unknown keys are dropped on write."""
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    filtered = {k: v for k, v in config.items() if k in ALLOWED_KEYS and v != ''}

    lines = []
    existing_keys = set()
    if CONFIG_PATH.exists():
        for line in CONFIG_PATH.read_text().splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith('#') and '=' in stripped:
                k = stripped.split('=', 1)[0].strip()
                if k in filtered:
                    lines.append(f'{k}="{filtered[k]}"')
                    existing_keys.add(k)
                    continue
                if k in ALLOWED_KEYS:
                    # Key was removed from config; drop the line.
                    continue
            lines.append(line)

    for k, v in filtered.items():
        if k not in existing_keys:
            lines.append(f'{k}="{v}"')

    payload = '\n'.join(lines).rstrip() + '\n'

    fd, tmp_path = tempfile.mkstemp(
        prefix='.config.', suffix='.tmp', dir=str(CONFIG_PATH.parent)
    )
    tmp = Path(tmp_path)
    try:
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, CONFIG_PATH)
    except Exception:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def persist_key(key, value):
    """Write a single KEY=value to the on-disk config.

    Reads the raw file, sets one key, writes it back. Deliberately
    does NOT merge environment variables, so ephemeral env-only
    credentials (e.g. a one-shot DID_COOKIE) are never persisted to
    disk as a side effect of another command.
    """
    if key not in ALLOWED_KEYS:
        raise ValueError(f'unknown config key: {key}')
    on_disk = {}
    if CONFIG_PATH.exists():
        on_disk = parse_kv_stream(CONFIG_PATH.read_text())
    on_disk[key] = value
    save_config(on_disk)
