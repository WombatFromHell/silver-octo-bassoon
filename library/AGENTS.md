# AGENTS.md for Qwen, Cursor, Kimi, and other agentic tools

## Common tool usage

As part of our CI guidelines we should always double check our code meets basic code quality standards by using the following tools:

### Essential command list

- Sort imports, format, and type check with: `ruff check --select I --fix; ruff format; pyright`
- Run the test suite and generate coverage reports with: `pytest -v`
- Ensure there is no dead code with: `vulture --min-confidence 80 *.py`
