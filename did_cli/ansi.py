"""ANSI colour helpers for pretty output.

Colours are emitted only when the relevant stream is a TTY. Callers
that explicitly want colour (or explicitly don't) can pass force=True
or force=False.
"""
import os
import sys


def _enabled(stream):
    if os.environ.get('NO_COLOR'):
        return False
    return stream.isatty()


def _wrap(code, text, stream, force):
    if force is None:
        on = _enabled(stream)
    else:
        on = force
    if not on:
        return text
    return f'\x1b[{code}m{text}\x1b[0m'


def red(text, stream=None, force=None):
    return _wrap('31', text, stream or sys.stderr, force)


def green(text, stream=None, force=None):
    return _wrap('32', text, stream or sys.stderr, force)


def yellow(text, stream=None, force=None):
    return _wrap('33', text, stream or sys.stderr, force)


def cyan(text, stream=None, force=None):
    return _wrap('36', text, stream or sys.stderr, force)


def bold(text, stream=None, force=None):
    return _wrap('1', text, stream or sys.stdout, force)


def error(msg):
    print(red(f'ERROR: {msg}'), file=sys.stderr)


def info(msg):
    print(cyan(msg), file=sys.stderr)


def debug(msg):
    if os.environ.get('DID_DEBUG') == '1':
        print(green(f'DEBUG: {msg}'), file=sys.stderr)
