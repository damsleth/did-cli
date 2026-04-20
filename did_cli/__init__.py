"""did-cli - command-line interface for the did timesheet app.

The package entry point is `main`, wired up as the `did-cli` console
script via pyproject.toml. See `cli.py` for the dispatch layer and the
per-concern modules (config, gql, dates, formatting, status, report,
submit) for the logic.
"""
from .cli import main

__all__ = ["main"]
