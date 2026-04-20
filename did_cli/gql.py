"""GraphQL client. One HTTP call plus error-mapping.

Queries live in `did_cli/queries/*.graphql` and are loaded through
importlib.resources so they ship inside the installed package.
"""
import json
import sys
import urllib.error
import urllib.request

from . import ansi

try:
    from importlib.resources import files as _files

    def _read_query(name):
        return (_files('did_cli.queries') / name).read_text()
except ImportError:  # Python 3.8 fallback
    from importlib.resources import read_text as _read_text

    def _read_query(name):
        return _read_text('did_cli.queries', name)


class GqlError(Exception):
    """GraphQL or HTTP error. Carries an exit code hint for the caller."""

    def __init__(self, message, exit_code=1):
        super().__init__(message)
        self.exit_code = exit_code


def load_query(name):
    """Read a .graphql file shipped in the package."""
    return _read_query(name)


def gql_request(query_file, variables, url, cookie):
    """POST a GraphQL query and return the `data` field.

    `url` is the bare hostname (no scheme). `cookie` is the didapp
    session cookie value. Raises GqlError on HTTP/GraphQL error.
    """
    if not cookie:
        raise GqlError(
            'DID_COOKIE not set. Configure it with: did-cli config --cookie <value>'
        )

    query = load_query(query_file)
    body = json.dumps({'query': query, 'variables': variables or None}).encode('utf-8')
    ansi.debug(f'POST https://{url}/graphql ({query_file})')

    req = urllib.request.Request(
        f'https://{url}/graphql',
        data=body,
        headers={
            'Content-Type': 'application/json',
            'Cookie': f'didapp={cookie}',
        },
        method='POST',
    )

    try:
        with urllib.request.urlopen(req) as resp:
            payload = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode('utf-8', errors='replace')
        if e.code == 401:
            raise GqlError(
                'Session expired (401). Update your cookie: did-cli config --cookie <value>'
            )
        ansi.debug(err_body[:500])
        raise GqlError(f'HTTP {e.code} from did API')
    except urllib.error.URLError as e:
        raise GqlError(f'network error: {e.reason}')

    errors = payload.get('errors')
    if errors:
        msg = 'Unknown GraphQL error'
        if isinstance(errors, list) and errors:
            msg = errors[0].get('message', msg)
        raise GqlError(f'GraphQL error: {msg}')

    return payload.get('data')


def call(query_file, variables, config):
    """Convenience wrapper. Prints error to stderr and returns None on
    failure instead of raising. Used by command modules."""
    try:
        return gql_request(
            query_file, variables,
            config.get('DID_URL', ''),
            config.get('DID_COOKIE', ''),
        )
    except GqlError as e:
        print(f'\x1b[31mERROR: {e}\x1b[0m' if sys.stderr.isatty()
              else f'ERROR: {e}', file=sys.stderr)
        return None
