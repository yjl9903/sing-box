# Repository Guidelines

## Project Structure & Module Organization

This repository is a compact macOS management wrapper for sing-box. `sing-box.sh` contains the CLI, subscription merging, process control, proxy switching, and recovery logic. `config.template.json` is the persistent base configuration; subscription outbounds are merged into it to generate `config.json`. `README.md` documents installation and user-facing workflows. Runtime and private files such as `.env`, `config.json`, `config.subscription.json`, `cache.db`, PID files, hashes, and logs are intentionally ignored and must not be committed.

There is currently no separate test directory or asset tree. Keep reusable shell helpers in `sing-box.sh` and persistent routing or DNS changes in `config.template.json`.

## Build, Test, and Development Commands

There is no build step. Install development dependencies with:

```bash
brew install sing-box jq fzf
```

Use these checks before submitting changes:

```bash
bash -n sing-box.sh                    # Check Bash syntax
./sing-box.sh --help                   # Smoke-test CLI dispatch and help
sing-box check -c config.template.json # Validate the base configuration
./sing-box.sh inspect                  # Review local runtime state
```

Commands such as `start`, `stop`, `reset --hard`, and `proxy on` alter processes or macOS networking and may invoke `sudo`; run them deliberately on a development machine.

## Coding Style & Naming Conventions

Use Bash with `set -Eeuo pipefail`, two-space indentation, quoted expansions, and `snake_case` for functions and variables. Prefer `local` variables inside functions and fail with clear, actionable messages. Preserve the existing two-space JSON indentation and descriptive sing-box tags such as `mixed-in` and `geosite-cn`. Keep CLI help synchronized whenever commands, aliases, flags, or dependencies change.

## Testing Guidelines

No automated test framework or coverage threshold is configured. At minimum, run the syntax, help, and configuration checks above. For behavioral changes, exercise the affected subcommand and verify cleanup paths. Never use real subscription credentials in fixtures, logs, examples, or commits.

## Commit & Pull Request Guidelines

Recent history follows short Conventional Commit-style subjects, including `feat:`, `fix:`, `docs:`, and `chore:`. Use an imperative, lowercase summary focused on one change. Pull requests should explain user-visible behavior, list commands run, note macOS/networking impact, and call out template or dependency changes. Link relevant issues; include terminal output when it helps reviewers reproduce a failure.
