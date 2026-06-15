# sing-box

[sing-box](https://sing-box.sagernet.org/zh/)

## Installation

```bash
brew install sing-box
brew install jq fzf
```

## CLI dependencies

- `bash`: runs `sing-box.sh`.
- `sing-box`: validates and runs the generated config.
- `curl`: fetches the subscription and talks to the Clash API.
- `jq`: merges JSON configs, renders proxy lists, URL-encodes API values, and parses delay results.
- `fzf`: only required by `proxies switch`.
- `sudo`: required by `run`/`restart` when starting sing-box and by `stop` when terminating it.
- macOS built-ins: `networksetup` and `scutil` for system proxy commands and inspection; `ps`, `nc`, `lsof`, `netstat`, `ifconfig`, `awk`, `grep`, `sed`, `mktemp`, `shasum` or `sha256sum` for process, port, config, and diagnostics helpers.

## Usage

```bash
# Get subscription URL
echo 'SUBSCRIPTION_URL="https://example.com/subscription"' > ~/.config/sing-box/.env

# Refresh config.subscription.json and generate config.json from config.template.json
~/.config/sing-box/sing-box.sh update

# Run or stop sing-box process.
# Run refreshes config.subscription.json and regenerates config.json first.
# If refresh fails, it falls back to the existing config.subscription.json cache.
~/.config/sing-box/sing-box.sh run
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

# Insepct proxy status
~/.config/sing-box/sing-box.sh inspect
```

## License

MIT License © 2026 [OneKuma](https://github.com/yjl9903)
