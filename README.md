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

The built-in help includes a command overview, configuration reference, and
details for every nested subcommand:

```bash
~/.config/sing-box/sing-box.sh --help
~/.config/sing-box/sing-box.sh help config
~/.config/sing-box/sing-box.sh help subscription list
~/.config/sing-box/sing-box.sh help proxies switch
~/.config/sing-box/sing-box.sh env test --help
```

```bash
# Run or stop sing-box process.
# Run refreshes config.subscription.json and regenerates config.json first.
# If refresh fails, it falls back to the existing config.subscription.json cache.
~/.config/sing-box/sing-box.sh run
~/.config/sing-box/sing-box.sh start
~/.config/sing-box/sing-box.sh stop
~/.config/sing-box/sing-box.sh restart

# Emergency recovery: leave sing-box stopped and restore direct networking.
~/.config/sing-box/sing-box.sh reset

# Stronger recovery: also clear runtime cache and power-cycle Wi-Fi.
~/.config/sing-box/sing-box.sh reset --hard

# Refresh config.subscription.json and generate config.json from config.template.json
~/.config/sing-box/sing-box.sh subscription update

# List the cached subscription nodes without exposing credentials.
~/.config/sing-box/sing-box.sh subscription list

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

# Inspect system proxy, DNS, process, TUN, route, and recent log status.
~/.config/sing-box/sing-box.sh inspect

# Clear the subscription cache, sing-box runtime cache, and log.
# A running sing-box process is stopped and restarted automatically.
~/.config/sing-box/sing-box.sh clear
```

## DNS recovery

If DNS fails after sing-box has been running for a long time, capture the state
before changing it, then restore direct networking:

```bash
~/.config/sing-box/sing-box.sh inspect > /tmp/sing-box-inspect.txt 2>&1
~/.config/sing-box/sing-box.sh reset
```

If that is not enough, use the hard reset. It also clears `cache.db` and
power-cycles `en0`, so Wi-Fi disconnects briefly:

```bash
~/.config/sing-box/sing-box.sh reset --hard
```

Both reset forms leave sing-box stopped. After direct networking works again,
run `sing-box.sh start`. Proxy environment variables belong to the current
shell and cannot be removed by a child script; clear them separately if used:

```bash
eval "$(~/.config/sing-box/sing-box.sh env off)"
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
