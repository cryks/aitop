# AGENTS.md

## Repo Overview

- This repository is a Bash-first workspace for usage summary CLIs.
- Main entrypoints live at the repository root: `aitop-codex`, `aitop-claude`, `aitop-opencode`, `aitop-gemini`, and `aitop`.
- Shared terminal rendering helpers live in `lib/render.bash`.
- Contract tests live in `tests/`, with provider-specific scripts such as `tests/aitop-codex-contract.sh`.

## Working Conventions

- Follow the existing Bash style: `#!/usr/bin/env bash`, `set -euo pipefail`, small helper functions, and explicit error messages.
- Keep changes surgical and match the current structure used by the provider scripts: `_resolve_script`, `usage`, validation helpers, fetch helpers, and display helpers.
- Treat CLI output as part of the contract. If a user-facing message or rendered label changes, update the matching contract test in `tests/`.
- Prefer extending the existing provider scripts and `lib/render.bash` over adding new layers or dependencies.

## Verification

- For a provider change, run its matching contract test script in `tests/`.
- For shared rendering or multi-provider changes, run all provider contract tests.

## Safety

- Never commit real tokens, cookies, account IDs, or other live credentials.
- Treat paths under the user's home directory and locally sourced auth material as environment-specific.
