# sing-box

My Local [sing-box](https://sing-box.sagernet.org/zh/) Management Script.

## Installation

```bash
brew install sing-box
brew install jq fzf
```

## Environment Setup

This script is intended to live at `~/.config/sing-box`.

```bash
mkdir -p ~/.config
git clone https://github.com/yjl9903/sing-box ~/.config/sing-box
cd ~/.config/sing-box
```

Create `.env` and put your subscription URL in it. Repeat `SUBSCRIPTION_URL` for multiple subscriptions:

```bash
echo 'SUBSCRIPTION_URL="https://example.com/subscription"' > ~/.config/sing-box/.env
echo 'SUBSCRIPTION_URL="https://example.com/another-subscription"' >> ~/.config/sing-box/.env
```

Then start sing-box. `start` refreshes the subscription cache, generates `config.json`, starts the process, and enables the system proxy:

```bash
~/.config/sing-box/sing-box.sh start
```

## Usage

```bash
# Refresh config.subscription.json and generate config.json from config.template.json
~/.config/sing-box/sing-box.sh update

# Run or stop sing-box process.
# Run refreshes config.subscription.json and regenerates config.json first.
# If refresh fails, it falls back to the existing config.subscription.json cache.
~/.config/sing-box/sing-box.sh run
~/.config/sing-box/sing-box.sh start
~/.config/sing-box/sing-box.sh stop
~/.config/sing-box/sing-box.sh restart

# List, switch, or test default proxy nodes.
~/.config/sing-box/sing-box.sh proxies list
~/.config/sing-box/sing-box.sh proxies switch
~/.config/sing-box/sing-box.sh proxies test

# System level proxy switch
~/.config/sing-box/sing-box.sh proxy on
~/.config/sing-box/sing-box.sh proxy off

# Set environment variables
eval "$(~/.config/sing-box/sing-box.sh env on)"
eval "$(~/.config/sing-box/sing-box.sh env off)"

# View and test current proxy environment variables
~/.config/sing-box/sing-box.sh env check
~/.config/sing-box/sing-box.sh env test https://www.google.com/generate_204

# Insepct system proxy status
~/.config/sing-box/sing-box.sh inspect
```

## CLI dependencies

- `bash`: runs `sing-box.sh`.
- `sing-box`: validates and runs the generated config.
- `curl`: fetches the subscription and talks to the Clash API.
- `jq`: merges JSON configs, renders proxy lists, URL-encodes API values, and parses delay results.
- `fzf`: only required by `proxies switch`.
- `sudo`: required by `run`/`start`/`restart` when starting sing-box and by `stop` when terminating it.
- macOS built-ins: `networksetup` and `scutil` for system proxy commands and inspection; `ps`, `nc`, `lsof`, `netstat`, `ifconfig`, `awk`, `grep`, `sed`, `mktemp`, `shasum` or `sha256sum` for process, port, config, and diagnostics helpers.

## License

MIT License © 2026 [OneKuma](https://github.com/yjl9903)
