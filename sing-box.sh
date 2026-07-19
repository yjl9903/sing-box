#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config_file="$script_dir/config.json"
config_template_file="$script_dir/config.template.json"
env_file="$script_dir/.env"
subscription_cache_file="$script_dir/config.subscription.json"
runtime_cache_file="$script_dir/cache.db"
pid_file="$script_dir/.sing-box.pid"
log_file="$script_dir/.sing-box.log"
lock_dir="$script_dir/.sing-box.lock"
config_hash_file="$script_dir/.sing-box.config.sha256"

network_service="Wi-Fi"
network_device="en0"
host=127.0.0.1
port=7892
clash_port=9090
proxy_test_timeout=3000
proxy_test_url="http://www.gstatic.com/generate_204"

bypass_domains=(
  localhost
  127.0.0.1
  ::1
  '10.*'
  '172.16.*'
  '172.17.*'
  '172.18.*'
  '172.19.*'
  '172.20.*'
  '172.21.*'
  '172.22.*'
  '172.23.*'
  '172.24.*'
  '172.25.*'
  '172.26.*'
  '172.27.*'
  '172.28.*'
  '172.29.*'
  '172.30.*'
  '172.31.*'
  '192.168.*'
  '169.254.*'
  '*.local'
)

no_proxy_value="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,.local"

usage() {
  local program
  program=$0
  cat <<EOF
Local sing-box manager for macOS

Usage:
  $program <command> [arguments]
  $program help [command [subcommand]]

Commands:
  run, start       Update the config, start sing-box, and enable system proxy
  stop             Stop sing-box and disable system proxy
  restart          Stop, refresh, start, and enable system proxy
  reset, recover   Restore direct networking; optionally reset Wi-Fi and cache
  subscription, sub
                   Refresh subscriptions or list cached proxy nodes
  clear            Clear subscription/runtime caches and the log
  proxies          List, switch, or delay-test nodes through the Clash API
  proxy            Enable or disable the macOS system proxy
  env              Print, inspect, or test shell proxy environment variables
  inspect          Show config, process, port, proxy, DNS, and TUN diagnostics
  help             Show global or command-specific help

Configuration:
  Files are resolved relative to: $script_dir

  .env
      Add one SUBSCRIPTION_URL per line; repeat the key for multiple feeds.
  config.template.json
      Persistent base config. Subscription outbounds are merged into this file.
  $0
      Edit the settings near the top for network service, ports, test URL,
      timeout, and bypass rules.

Generated files:
  config.subscription.json
      Downloaded and combined subscription cache
  config.json
      Generated runnable config; subscription update overwrites it
  cache.db
      sing-box runtime cache
  .sing-box.log
      Background process log

Examples:
  $program start
  $program subscription list
  $program proxies switch
  eval "\$($program env on)"
  $program help config
  $program proxies test --help

Run '$program help <command>' or '$program <command> --help' for details.
EOF
}

show_help() {
  local program topic subtopic key
  program=$0
  topic=${1:-}
  subtopic=${2:-}
  key=$topic
  [[ -n "$subtopic" ]] && key="$topic $subtopic"

  case "$key" in
    "")
      usage
      ;;
    config|configuration)
      cat <<EOF
Usage:
  $program help config

Subscription configuration:
  Create $env_file with one or more lines in this form:

    SUBSCRIPTION_URL="https://example.com/subscription"
    SUBSCRIPTION_URL="https://example.com/another-subscription"

  Quotes are optional. Each response must be sing-box JSON containing an
  outbounds array. Duplicate outbound tags are retained only once.

Base sing-box configuration:
  Edit $config_template_file for persistent DNS, inbound, routing, rule-set,
  logging, and experimental settings. During 'subscription update', proxy nodes
  are appended and selector outbounds receive their tags.

Script settings:
  Edit the variables near the top of $0 to change:
    network_service       macOS network service (default: $network_service)
    network_device        network device for hard reset (default: $network_device)
    host / port           local mixed proxy (default: $host:$port)
    clash_port            Clash API port (default: $clash_port)
    proxy_test_url        connectivity/delay test URL
    proxy_test_timeout    timeout in milliseconds
    bypass_domains        macOS system proxy bypass list
    no_proxy_value        shell NO_PROXY/no_proxy value

Generated state:
  Do not put persistent edits in $config_file or $subscription_cache_file;
  '$program subscription update' regenerates them. Runtime PID, hash, lock,
  cache, and log files are also kept next to the script.
EOF
      ;;
    run|start)
      cat <<EOF
Usage:
  $program run
  $program start

Refresh all subscriptions, generate and validate config.json, start sing-box in
the background, then enable the macOS system proxy. 'run' and 'start' are aliases.

If a subscription download fails and a cache exists, the cached subscription is
used. If sing-box is already running with an unchanged config, it is reused; a
changed config causes a restart.

Requires: sing-box, curl, jq, sudo, and macOS networksetup.
EOF
      ;;
    stop)
      cat <<EOF
Usage:
  $program stop

Disable HTTP, HTTPS, and SOCKS system proxies, restore automatic DNS on
'$network_service', then stop managed or detected 'sing-box run' processes. A
process that does not exit after SIGTERM is sent SIGKILL.

Requires: sudo and macOS networksetup.
EOF
      ;;
    restart)
      cat <<EOF
Usage:
  $program restart

Stop sing-box, refresh subscriptions, regenerate config.json, start sing-box,
and enable the macOS system proxy. See '$program help run' for refresh fallback
and startup behavior.
EOF
      ;;
    reset|recover)
      cat <<EOF
Usage:
  $program reset
  $program reset --hard

Restore a usable direct network without rebooting macOS. Both forms disable the
macOS HTTP/HTTPS/SOCKS proxies, restore automatic DNS, stop sing-box, and flush
the macOS DNS caches.

With --hard, also delete the sing-box runtime cache and power-cycle the Wi-Fi
interface. The hard reset temporarily disconnects Wi-Fi; run '$program start'
after Wi-Fi reconnects to enable sing-box again.

'recover' is an alias for 'reset'. Requires: sudo and macOS networksetup.
EOF
      ;;
    subscription|sub)
      cat <<EOF
Usage:
  $program subscription <subcommand>

Manage subscription data stored in $subscription_cache_file.

Subcommands:
  update            Download subscriptions and regenerate config.json
  list              Show a human-readable summary of cached proxy nodes

Run '$program help subscription <subcommand>' for details.
EOF
      ;;
    "subscription update"|"sub update")
      cat <<EOF
Usage:
  $program subscription update

Download every SUBSCRIPTION_URL from .env, combine unique proxy outbounds,
merge them into config.template.json, validate the result, and replace
config.json. This command does not start or restart sing-box.

If a download or response is invalid, an existing subscription cache is kept.
Requires: sing-box, curl, and jq.
EOF
      ;;
    "subscription list"|"sub list")
      cat <<EOF
Usage:
  $program subscription list

Read the current config.subscription.json cache and print its update time, proxy
node count, protocol totals, and a formatted node list containing protocol,
endpoint, transport features, and node name. Credentials and protocol secrets
are never displayed.

This command reads the local cache without fetching or changing subscriptions.
Requires: jq.
EOF
      ;;
    clear)
      cat <<EOF
Usage:
  $program clear

Delete the combined subscription cache, sing-box runtime cache, and background
log. If sing-box is running, stop it first and restart it afterward using the
existing config.json. The system proxy state is not changed.

This does not delete .env, config.template.json, or config.json.
EOF
      ;;
    proxies)
      cat <<EOF
Usage:
  $program proxies <subcommand>

Manage the 'default' selector through the Clash API at $host:$clash_port.
sing-box must be running and its Clash API must be enabled.

Subcommands:
  list              Show all selectable nodes and mark the current node
  switch            Select a node interactively with fzf
  test              Measure every node against the configured test URL

Run '$program help proxies <subcommand>' for details.
EOF
      ;;
    "proxies list")
      cat <<EOF
Usage:
  $program proxies list

Query the Clash API and print all nodes in the 'default' selector. The active
node is listed first and marked with [x].

Requires: a running sing-box Clash API, curl, and jq.
EOF
      ;;
    "proxies switch")
      cat <<EOF
Usage:
  $program proxies switch

Open an interactive fzf picker for the 'default' selector, with the active node
first, then switch the selector through the Clash API. Cancelling fzf makes no
change and exits successfully.

Requires: a running sing-box Clash API, curl, jq, and fzf.
EOF
      ;;
    "proxies test")
      cat <<EOF
Usage:
  $program proxies test

Test every node in the 'default' selector through the Clash API. Results show
delay in milliseconds or ERR. The active node is listed first and marked [x].

Test URL: $proxy_test_url
Timeout:  ${proxy_test_timeout}ms per node
Requires: a running sing-box Clash API, curl, and jq.
EOF
      ;;
    proxy)
      cat <<EOF
Usage:
  $program proxy <on|off>

Control proxy settings for the macOS network service '$network_service'. This
does not start or stop sing-box.

Subcommands:
  on                Enable HTTP/HTTPS/SOCKS at $host:$port
  off               Disable those proxies and restore automatic DNS
EOF
      ;;
    "proxy on")
      cat <<EOF
Usage:
  $program proxy on

Enable HTTP, HTTPS, and SOCKS system proxies at $host:$port for
'$network_service' and apply the configured bypass list. TUN owns DNS while
sing-box is running. This command does not verify that sing-box is running.
EOF
      ;;
    "proxy off")
      cat <<EOF
Usage:
  $program proxy off

Disable HTTP, HTTPS, and SOCKS system proxies for '$network_service' and restore
automatic DNS. This command does not stop sing-box.
EOF
      ;;
    env)
      cat <<EOF
Usage:
  eval "\$($program env)"
  eval "\$($program env on)"
  eval "\$($program env off)"
  $program env check
  $program env status
  $program env test [url]

Manage proxy variables for the current shell. 'env' defaults to 'env on'. The
on/off commands print shell code, so use eval to apply it to the parent shell.

Subcommands:
  on                Print export statements for proxy and no-proxy variables
  off               Print one unset statement for those variables
  check, status     Show values and test every configured proxy variable
  test [url]        Same as check, with an optional one-off test URL

Run '$program help env <subcommand>' for details.
EOF
      ;;
    "env on")
      cat <<EOF
Usage:
  eval "\$($program env on)"
  eval "\$($program env)"

Print exports for lowercase and uppercase HTTP, HTTPS, ALL_PROXY, and NO_PROXY
variables. Use eval because a child script cannot modify its parent shell.

HTTP/HTTPS: http://$host:$port
ALL_PROXY:  socks5h://$host:$port
EOF
      ;;
    "env off")
      cat <<EOF
Usage:
  eval "\$($program env off)"

Print an unset statement for all lowercase and uppercase proxy environment
variables. Use eval to apply it to the current shell.
EOF
      ;;
    "env check"|"env status")
      cat <<EOF
Usage:
  $program env check
  $program env status

Compare proxy environment variables with the script settings, then test every
set HTTP/HTTPS/ALL_PROXY value using curl. 'check' and 'status' are aliases.
Returns nonzero if none are set or any test fails.

Test URL: $proxy_test_url
Timeout:  ${proxy_test_timeout}ms per variable
EOF
      ;;
    "env test")
      cat <<EOF
Usage:
  $program env test [url]

Show and test the current proxy environment variables. With a URL, override the
configured test URL for this invocation only. Returns nonzero if none are set or
any test fails.

Default URL: $proxy_test_url
Timeout:     ${proxy_test_timeout}ms per variable
EOF
      ;;
    inspect)
      cat <<EOF
Usage:
  $program inspect

Run read-only diagnostics for the generated config, PID and matching processes,
mixed and Clash API ports, macOS system proxy and DNS settings, recent logs, and
TUN interfaces and routes. Individual diagnostic failures are displayed without
stopping the rest.

Common tools used: sing-box, ps, lsof, nc, netstat, scutil, networksetup, and
ifconfig.
EOF
      ;;
    help)
      cat <<EOF
Usage:
  $program help
  $program help <command>
  $program help <command> <subcommand>
  $program <command> --help
  $program <command> <subcommand> --help

Show the global help or detailed help for a command or nested subcommand.
'$program help config' describes all configuration files and settings.
EOF
      ;;
    *)
      echo "error: no help topic for '$key'" >&2
      return 2
      ;;
  esac
}

is_help_arg() {
  case "${1:-}" in
    help|-h|--help)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

fail() {
  echo "error: $*" >&2
  exit 1
}

shell_quote() {
  local value escaped
  value=$1
  escaped=${value//\'/\'\\\'\'}
  printf "'%s'" "$escaped"
}

acquire_lock() {
  if ! mkdir "$lock_dir" 2>/dev/null; then
    fail "another sing-box.sh operation appears to be running: $lock_dir"
  fi
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
}

pid_alive() {
  local pid=$1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  ps -p "$pid" >/dev/null 2>&1
}

pid_command() {
  local pid=$1
  ps -p "$pid" -o command= 2>/dev/null || true
}

pid_is_sing_box() {
  local pid=$1 command
  command=$(pid_command "$pid")
  is_sing_box_command "$command"
}

pid_from_file() {
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid=$(tr -cd '0-9' <"$pid_file")
  [[ -n "$pid" ]] || return 1
  printf '%s\n' "$pid"
}

find_running_pids() {
  local output status pid command
  set +e
  output=$(ps ax -o pid= -o command= 2>/dev/null)
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || return 0

  while read -r pid command; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    is_sing_box_command "$command" || continue
    printf '%s\n' "$pid"
  done <<<"$output"
}

is_sing_box_command() {
  local command=$1
  case "$command" in
    "sing-box run"*|*/"sing-box run"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

unique_pids() {
  awk '!seen[$0]++'
}

managed_pids() {
  local pid
  {
    if pid=$(pid_from_file 2>/dev/null) && pid_alive "$pid" && pid_is_sing_box "$pid"; then
      printf '%s\n' "$pid"
    fi
    find_running_pids
  } | unique_pids
}

check_config() {
  [[ -f "$config_file" ]] || fail "missing config file: $config_file"
  sing-box check -c "$config_file"
}

check_config_template() {
  [[ -f "$config_template_file" ]] || fail "missing config template: $config_template_file"
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

check_fzf() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "error: missing required command: fzf" >&2
    echo "install with: brew install fzf" >&2
    exit 1
  fi
}

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

subscription_urls() {
  [[ -f "$env_file" ]] || fail "missing env file: $env_file"

  local found=0 line value
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*SUBSCRIPTION_URL= ]] || continue
    found=1
    value=${line#*=}
    value=$(trim "$value")
    case "$value" in
      \"*\")
        value=${value#\"}
        value=${value%\"}
        ;;
      \'*\')
        value=${value#\'}
        value=${value%\'}
        ;;
    esac
    [[ -n "$value" ]] || fail "SUBSCRIPTION_URL is empty in $env_file"
    printf '%s\n' "$value"
  done <"$env_file"

  [[ "$found" -eq 1 ]] || fail "missing SUBSCRIPTION_URL in $env_file"
}

subscription_host() {
  local value
  value=${1#*://}
  value=${value#*@}
  value=${value%%[/?#]*}
  case "$value" in
    \[*\]*)
      value=${value#\[}
      value=${value%%\]*}
      ;;
    *)
      value=${value%%:*}
      ;;
  esac
  printf '%s\n' "$value"
}

config_hash() {
  local output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 "$config_file")
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum "$config_file")
  else
    fail "missing checksum command: shasum or sha256sum"
  fi
  printf '%s\n' "${output%% *}"
}

stored_config_hash() {
  [[ -f "$config_hash_file" ]] || return 1
  local hash
  hash=$(tr -d '[:space:]' <"$config_hash_file")
  [[ -n "$hash" ]] || return 1
  printf '%s\n' "$hash"
}

record_config_hash() {
  config_hash >"$config_hash_file"
}

ensure_config_hash_recorded() {
  stored_config_hash >/dev/null 2>&1 || record_config_hash
}

config_hash_changed() {
  local current stored
  stored=$(stored_config_hash) || return 1
  current=$(config_hash)
  [[ "$current" != "$stored" ]]
}

port_open() {
  local check_port=$1 status
  set +e
  nc -z -w 1 "$host" "$check_port" >/dev/null 2>&1
  status=$?
  set -e
  return "$status"
}

wait_for_sing_box_pid() {
  local deadline pids
  deadline=$((SECONDS + 5))
  while true; do
    pids=$(find_running_pids | unique_pids | tr '\n' ' ')
    if [[ -n "${pids// }" ]]; then
      printf '%s\n' "${pids%% *}"
      return 0
    fi

    (( SECONDS >= deadline )) && return 1
    sleep 0.2
  done
}

cmd_run_impl() {
  cmd_subscription_update_impl
  cmd_run_impl_without_update
}

cmd_run() {
  acquire_lock
  cmd_run_impl
}

wait_for_exit() {
  local pid=$1 deadline now
  deadline=$((SECONDS + 5))
  while pid_alive "$pid"; do
    now=$SECONDS
    (( now >= deadline )) && return 1
    sleep 0.2
  done
  return 0
}

cmd_stop_impl() {
  local pids pid stopped=0
  pids=$(managed_pids | tr '\n' ' ')

  if [[ -z "${pids// }" ]]; then
    rm -f "$pid_file" "$config_hash_file"
    echo "sing-box is not running"
    return 0
  fi

  for pid in $pids; do
    if ! pid_alive "$pid"; then
      continue
    fi

    echo "stopping sing-box: pid $pid"
    if ! sudo kill -TERM "$pid" 2>/dev/null && pid_alive "$pid"; then
      fail "failed to send SIGTERM to pid $pid"
    fi
    if ! wait_for_exit "$pid"; then
      echo "pid $pid did not exit after SIGTERM; sending SIGKILL"
      if ! sudo kill -KILL "$pid" 2>/dev/null && pid_alive "$pid"; then
        fail "failed to send SIGKILL to pid $pid"
      fi
      wait_for_exit "$pid" || true
    fi
    stopped=1
  done

  rm -f "$pid_file" "$config_hash_file"

  if [[ "$stopped" -eq 1 ]]; then
    echo "sing-box stopped"
  else
    echo "sing-box is not running"
  fi
}

cmd_stop() {
  local proxy_cleanup_failed=0

  acquire_lock
  cmd_proxy_off || proxy_cleanup_failed=1
  cmd_stop_impl
  [[ "$proxy_cleanup_failed" -eq 0 ]] || return 1
}

cmd_restart() {
  acquire_lock
  cmd_proxy_off || echo "warning: some system proxy settings could not be cleared before restart" >&2
  cmd_stop_impl
  cmd_subscription_update_impl
  cmd_run_impl_without_update
  cmd_proxy_on
}

count_subscription_nodes() {
  jq '[.outbounds[]? | select(.tag and (.type | IN("direct", "block", "dns", "selector", "urltest") | not))] | length' "$1"
}

fetch_subscription_cache() {
  check_command curl

  local urls url tmp_dir tmp_subscription tmp_combined node_count index=0
  urls=$(subscription_urls)
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sing-box.subscription.XXXXXX")
  tmp_combined="$tmp_dir/combined.json"

  while IFS= read -r url; do
    index=$((index + 1))
    tmp_subscription="$tmp_dir/subscription-$index.json"

    echo "fetching subscription config: $(subscription_host "$url")"
    if ! curl -fsSL "$url" -H "User-Agent: sing-box" -o "$tmp_subscription"; then
      rm -rf "$tmp_dir"
      if [[ -f "$subscription_cache_file" ]]; then
        echo "warning: failed to fetch subscription config; using cached subscription"
        return 0
      fi
      fail "failed to fetch subscription config and no cache exists"
    fi

    if ! jq -e '.outbounds | type == "array"' "$tmp_subscription" >/dev/null; then
      rm -rf "$tmp_dir"
      if [[ -f "$subscription_cache_file" ]]; then
        echo "warning: subscription response is invalid; using cached subscription"
        return 0
      fi
      fail "subscription response is not a sing-box config with outbounds and no cache exists"
    fi
  done <<<"$urls"

  if ! jq -s '
    reduce [.[].outbounds[]? | select(.tag)][] as $outbound
      ({outbounds: [], tags: {}};
        if .tags[$outbound.tag] then .
        else .outbounds += [$outbound] | .tags[$outbound.tag] = true
        end)
    | {outbounds}
  ' "$tmp_dir"/subscription-*.json >"$tmp_combined"; then
    rm -rf "$tmp_dir"
    fail "failed to merge subscription configs"
  fi

  node_count=$(count_subscription_nodes "$tmp_combined")
  if [[ "$node_count" -le 0 ]]; then
    rm -rf "$tmp_dir"
    if [[ -f "$subscription_cache_file" ]]; then
      echo "warning: subscription config contains no proxy outbounds; using cached subscription"
      return 0
    fi
    fail "subscription config contains no proxy outbounds and no cache exists"
  fi
  mv "$tmp_combined" "$subscription_cache_file"
  rm -rf "$tmp_dir"
}

generate_config_from_cache() {
  check_config_template
  [[ -f "$subscription_cache_file" ]] || fail "missing subscription cache: $subscription_cache_file"

  local tmp_merged node_count
  tmp_merged=$(mktemp "${TMPDIR:-/tmp}/sing-box.config.XXXXXX")

  node_count=$(count_subscription_nodes "$subscription_cache_file")
  [[ "$node_count" -gt 0 ]] || fail "subscription cache contains no proxy outbounds"

  if ! jq --slurpfile subscription "$subscription_cache_file" '
    def is_node:
      .tag and (.type | IN("direct", "block", "dns", "selector", "urltest") | not);

    ($subscription[0].outbounds
      | map(select(is_node))
      | map(if .type == "anytls" and .tls.alpn == ["h3"] then del(.tls.alpn) else . end)
    ) as $nodes
    | ($nodes | map(.tag)) as $node_tags
    | .outbounds =
        (
          [.outbounds[] | select(is_node | not)
            | if .type == "selector" then .outbounds = $node_tags else . end]
          + $nodes
        )
    | ([.outbounds[]?.server?
        | select(type == "string" and test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
        | . + "/32"] | unique) as $route_exclude_address
    | .inbounds |= map(
        if .type == "tun"
        then .route_exclude_address = $route_exclude_address
        else .
        end
      )
  ' "$config_template_file" >"$tmp_merged"; then
    rm -f "$tmp_merged"
    fail "failed to merge subscription outbounds into config template"
  fi

  if ! sing-box check -c "$tmp_merged"; then
    rm -f "$tmp_merged"
    fail "generated config failed sing-box check"
  fi
  mv "$tmp_merged" "$config_file"

  echo "generated config.json with $node_count subscription outbounds"
}

cmd_subscription_update_impl() {
  check_command jq
  check_command sing-box
  fetch_subscription_cache
  generate_config_from_cache
}

cmd_run_impl_without_update() {
  check_config

  local pid pids quoted_dir quoted_config quoted_log

  if pid=$(pid_from_file 2>/dev/null) && pid_alive "$pid" && pid_is_sing_box "$pid"; then
    if config_hash_changed; then
      echo "config.json changed since sing-box started; restarting"
      cmd_proxy_off || echo "warning: some system proxy settings could not be cleared before restart" >&2
      cmd_stop_impl
    else
      ensure_config_hash_recorded
      echo "sing-box is already running: pid $pid"
      return 0
    fi
  fi

  rm -f "$pid_file"

  pids=$(find_running_pids | unique_pids | tr '\n' ' ')
  if [[ -n "${pids// }" ]]; then
    pid=${pids%% *}
    printf '%s\n' "$pid" >"$pid_file"
    record_config_hash
    echo "adopted existing sing-box process: pid $pid"
    return 0
  fi

  if port_open "$port"; then
    fail "$host:$port is already listening, but no sing-box pid could be identified"
  fi

  quoted_dir=$(shell_quote "$script_dir")
  quoted_config=$(shell_quote "$config_file")
  quoted_log=$(shell_quote "$log_file")

  sudo -b sh -c "cd $quoted_dir && exec sing-box run -c $quoted_config >> $quoted_log 2>&1 < /dev/null"

  if ! pid=$(wait_for_sing_box_pid); then
    if port_open "$port"; then
      fail "sing-box appears to be listening on $host:$port, but its pid could not be identified"
    fi
    fail "sing-box did not start; see $log_file"
  fi

  printf '%s\n' "$pid" >"$pid_file"
  record_config_hash
  echo "sing-box started: pid $pid"
  echo "log: $log_file"
}

cmd_subscription_update() {
  acquire_lock
  cmd_subscription_update_impl
}

cmd_subscription_list() {
  check_command jq
  [[ -f "$subscription_cache_file" ]] || fail "missing subscription cache: $subscription_cache_file; run '$0 subscription update' first"
  jq -e '.outbounds | type == "array"' "$subscription_cache_file" >/dev/null || fail "subscription cache is not a sing-box config with outbounds"

  local total node_count helper_count protocols modified
  total=$(jq '.outbounds | length' "$subscription_cache_file")
  node_count=$(count_subscription_nodes "$subscription_cache_file")
  helper_count=$((total - node_count))
  protocols=$(jq -r '
    def is_node:
      .tag and (.type | IN("direct", "block", "dns", "selector", "urltest") | not);
    [.outbounds[]? | select(is_node) | (.type // "unknown")]
    | group_by(.)
    | map("\(.[0]): \(length)")
    | if length == 0 then "none" else join(", ") end
  ' "$subscription_cache_file")

  if modified=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %z' "$subscription_cache_file" 2>/dev/null); then
    :
  elif modified=$(stat -c '%y' "$subscription_cache_file" 2>/dev/null); then
    :
  else
    modified=unknown
  fi

  echo "Subscription cache"
  echo "File: $subscription_cache_file"
  echo "Updated: $modified"
  echo "Proxy nodes: $node_count"
  echo "Protocols: $protocols"
  echo "Helper outbounds: $helper_count (not listed)"

  if [[ "$node_count" -eq 0 ]]; then
    return 0
  fi

  echo
  echo "Nodes"

  while IFS=$'\t' read -r index type endpoint features tag; do
    printf '  %s. %s\n' "$index" "$tag"
    printf '     Type: %s | Endpoint: %s | Features: %s\n' "$type" "$endpoint" "$features"
  done < <(
    jq -r '
      def is_node:
        .tag and (.type | IN("direct", "block", "dns", "selector", "urltest") | not);
      def clean:
        tostring | gsub("[\\t\\r\\n]"; " ");
      def endpoint:
        if (.server? | type) == "string" then
          (if (.server | contains(":")) then "[" + .server + "]" else .server end)
          + (if .server_port? != null then ":" + (.server_port | tostring) else "" end)
        else
          "-"
        end;
      def features:
        [
          (if (.tls? != null and (.tls.enabled? // true)) then "tls" else empty end),
          (.transport.type? // empty),
          (if .multiplex.enabled? == true then "mux" else empty end)
        ]
        | if length == 0 then "-" else join(",") end;
      [.outbounds[]? | select(is_node)]
      | to_entries[]
      | [
          (.key + 1),
          (.value.type // "unknown" | clean),
          (.value | endpoint | clean),
          (.value | features | clean),
          (.value.tag // "(unnamed)" | clean)
        ]
      | @tsv
    ' "$subscription_cache_file"
  )
}

cmd_clear() {
  acquire_lock

  local pids was_running=0
  pids=$(managed_pids | tr '\n' ' ')
  if [[ -n "${pids// }" ]]; then
    was_running=1
    cmd_proxy_off || echo "warning: some system proxy settings could not be cleared before cache restart" >&2
    cmd_stop_impl
  fi

  rm -f "$subscription_cache_file"
  if ! rm -f "$runtime_cache_file" "$log_file" 2>/dev/null; then
    sudo rm -f "$runtime_cache_file" "$log_file"
  fi

  echo "cache cleared: $subscription_cache_file"
  echo "cache cleared: $runtime_cache_file"
  echo "log cleared: $log_file"

  if [[ "$was_running" -eq 1 ]]; then
    cmd_run_impl_without_update
    cmd_proxy_on
  fi
}

clash_api_base_url() {
  printf 'http://%s:%s\n' "$host" "$clash_port"
}

default_proxy_url() {
  printf '%s/proxies/default\n' "$(clash_api_base_url)"
}

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

fetch_default_proxy() {
  local url response
  url=$(default_proxy_url)
  if ! response=$(curl -fsS "$url"); then
    fail "clash api is unavailable at $(clash_api_base_url)"
  fi
  printf '%s\n' "$response"
}

cmd_proxies_list() {
  check_command curl
  check_command jq

  local response now total
  response=$(fetch_default_proxy)
  printf '%s\n' "$response" | jq -e '.all | type == "array" and length > 0' >/dev/null || fail "default proxy has no selectable outbounds"
  now=$(printf '%s\n' "$response" | jq -r '.now // empty')
  total=$(printf '%s\n' "$response" | jq '.all | length')

  echo "Default proxy"
  echo "Current: ${now:-unknown}"
  echo "Total: $total"
  echo
  printf '%s\n' "$response" |
    jq -r --arg now "$now" '
      [.all[]?]
      | (map(select(. == $now)) + map(select(. != $now)))[]
      | if . == $now then "[x] " + . else "[ ] " + . end
    '
}

cmd_proxies_switch() {
  check_command curl
  check_command jq
  check_fzf

  local response now selected payload url select_status
  response=$(fetch_default_proxy)
  printf '%s\n' "$response" | jq -e '.all | type == "array" and length > 0' >/dev/null || fail "default proxy has no selectable outbounds"
  now=$(printf '%s\n' "$response" | jq -r '.now // empty')

  set +e
  selected=$(
    printf '%s\n' "$response" |
      jq -r --arg now "$now" '[.all[]?] | (map(select(. == $now)) + map(select(. != $now)))[]' |
      fzf --height=80% --reverse --prompt='default > ' --header="current: ${now:-unknown}"
  )
  select_status=$?
  set -e

  [[ "$select_status" -eq 0 ]] || return 0
  [[ -n "$selected" ]] || return 0

  payload=$(jq -n --arg name "$selected" '{name: $name}')
  url=$(default_proxy_url)
  if ! curl -fsS -X PUT "$url" -H 'Content-Type: application/json' --data "$payload" >/dev/null; then
    fail "failed to switch default proxy"
  fi

  echo "default switched to: $selected"
}

proxy_delay_url() {
  local name_encoded test_url_encoded
  name_encoded=$(urlencode "$1")
  test_url_encoded=$(urlencode "$proxy_test_url")
  printf '%s/proxies/%s/delay?timeout=%s&url=%s\n' "$(clash_api_base_url)" "$name_encoded" "$proxy_test_timeout" "$test_url_encoded"
}

test_proxy_delay() {
  local name=$1 url response delay
  url=$(proxy_delay_url "$name")
  if ! response=$(curl -fsS "$url" 2>/dev/null); then
    printf 'ERR\n'
    return 0
  fi

  delay=$(printf '%s\n' "$response" | jq -r '.delay // empty')
  if [[ -n "$delay" ]]; then
    printf '%sms\n' "$delay"
  else
    printf 'ERR\n'
  fi
}

cmd_proxies_test() {
  check_command curl
  check_command jq

  local response now total name marker delay
  response=$(fetch_default_proxy)
  printf '%s\n' "$response" | jq -e '.all | type == "array" and length > 0' >/dev/null || fail "default proxy has no selectable outbounds"
  now=$(printf '%s\n' "$response" | jq -r '.now // empty')
  total=$(printf '%s\n' "$response" | jq '.all | length')

  echo "Default proxy delay test"
  echo "Current: ${now:-unknown}"
  echo "Total: $total"
  echo "URL: $proxy_test_url"
  echo "Timeout: ${proxy_test_timeout}ms"
  echo

  while IFS= read -r name; do
    if [[ "$name" == "$now" ]]; then
      marker="[x]"
    else
      marker="[ ]"
    fi
    delay=$(test_proxy_delay "$name")
    printf '%s %6s  %s\n' "$marker" "$delay" "$name"
  done < <(
    printf '%s\n' "$response" |
      jq -r --arg now "$now" '[.all[]?] | (map(select(. == $now)) + map(select(. != $now)))[]'
  )
}

cmd_proxy_on() {
  networksetup -setwebproxy                "$network_service" "$host" "$port"
  networksetup -setsecurewebproxy          "$network_service" "$host" "$port"
  networksetup -setsocksfirewallproxy      "$network_service" "$host" "$port"
  networksetup -setproxybypassdomains      "$network_service" "${bypass_domains[@]}"
  networksetup -setwebproxystate           "$network_service" on
  networksetup -setsecurewebproxystate     "$network_service" on
  networksetup -setsocksfirewallproxystate "$network_service" on
  echo "system proxy enabled on $network_service: $host:$port (DNS is managed by TUN)"
}

cmd_proxy_off() {
  local failed=0

  networksetup -setwebproxystate           "$network_service" off || failed=1
  networksetup -setsecurewebproxystate     "$network_service" off || failed=1
  networksetup -setsocksfirewallproxystate "$network_service" off || failed=1
  networksetup -setdnsservers              "$network_service" empty || failed=1

  if [[ "$failed" -ne 0 ]]; then
    echo "error: failed to clear one or more proxy/DNS settings on $network_service" >&2
    return 1
  fi
  echo "system proxy disabled on $network_service"
}

flush_dns_cache() {
  dscacheutil -flushcache
  sudo killall -HUP mDNSResponder
  echo "macOS DNS caches flushed"
}

cmd_reset() {
  local mode=${1:-} proxy_cleanup_failed=0

  acquire_lock
  cmd_proxy_off || proxy_cleanup_failed=1
  cmd_stop_impl
  flush_dns_cache

  if [[ "$mode" == "--hard" ]]; then
    if ! rm -f "$runtime_cache_file" 2>/dev/null; then
      sudo rm -f "$runtime_cache_file"
    fi
    echo "runtime cache cleared: $runtime_cache_file"
    echo "power-cycling Wi-Fi on $network_device"
    networksetup -setairportpower "$network_device" off
    sleep 2
    networksetup -setairportpower "$network_device" on
    echo "hard network reset complete; wait for Wi-Fi, then run '$0 start'"
  else
    echo "network reset complete; direct networking should now be available"
  fi

  [[ "$proxy_cleanup_failed" -eq 0 ]] || return 1
}

cmd_env() {
  local http_url socks_url
  http_url="http://$host:$port"
  socks_url="socks5h://$host:$port"

  printf 'export http_proxy=%q\n' "$http_url"
  printf 'export https_proxy=%q\n' "$http_url"
  printf 'export all_proxy=%q\n' "$socks_url"
  printf 'export HTTP_PROXY=%q\n' "$http_url"
  printf 'export HTTPS_PROXY=%q\n' "$http_url"
  printf 'export ALL_PROXY=%q\n' "$socks_url"
  printf 'export no_proxy=%q\n' "$no_proxy_value"
  printf 'export NO_PROXY=%q\n' "$no_proxy_value"
}

cmd_env_clear() {
  echo "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY"
}

env_proxy_value() {
  printenv "$1" 2>/dev/null || true
}

expected_env_proxy_value() {
  case "$1" in
    http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY)
      printf 'http://%s:%s\n' "$host" "$port"
      ;;
    all_proxy|ALL_PROXY)
      printf 'socks5h://%s:%s\n' "$host" "$port"
      ;;
    no_proxy|NO_PROXY)
      printf '%s\n' "$no_proxy_value"
      ;;
    *)
      return 1
      ;;
  esac
}

cmd_env_check_show_values() {
  local name value expected

  echo "Environment proxy variables"
  for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
    value=$(env_proxy_value "$name")
    expected=$(expected_env_proxy_value "$name")
    if [[ -z "$value" ]]; then
      printf '  [unset] %-12s expected %s\n' "$name" "$expected"
    elif [[ "$value" == "$expected" ]]; then
      printf '  [ok]    %-12s %s\n' "$name" "$value"
    else
      printf '  [diff]  %-12s %s (expected %s)\n' "$name" "$value" "$expected"
    fi
  done
}

cmd_env_check_test_one() {
  local name=$1 proxy=$2 timeout_seconds output status stats http_code time_total error
  timeout_seconds=$(( (proxy_test_timeout + 999) / 1000 ))

  set +e
  output=$(curl -sS -o /dev/null -w $'\n%{http_code} %{time_total}' \
    --proxy "$proxy" \
    --connect-timeout "$timeout_seconds" \
    --max-time "$timeout_seconds" \
    "$proxy_test_url" 2>&1)
  status=$?
  set -e

  stats=${output##*$'\n'}
  read -r http_code time_total <<<"$stats"

  if [[ "$status" -eq 0 && "$http_code" =~ ^[0-9][0-9][0-9]$ && "10#$http_code" -ge 200 && "10#$http_code" -lt 400 ]]; then
    printf '  [ok]   %-12s %s (%s, %ss)\n' "$name" "$proxy" "$http_code" "$time_total"
    return 0
  fi

  output=${output%$'\n'$stats}
  error=$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -n 1)
  if [[ -n "$error" ]]; then
    printf '  [fail] %-12s %s (%s)\n' "$name" "$proxy" "$error"
  else
    printf '  [fail] %-12s %s (curl exit %s, http %s)\n' "$name" "$proxy" "$status" "${http_code:-unknown}"
  fi
  return 1
}

cmd_env_check() {
  check_command curl

  local name value tested=0 failed=0

  cmd_env_check_show_values

  echo
  echo "Proxy test"
  echo "  URL: $proxy_test_url"
  echo "  Timeout: ${proxy_test_timeout}ms"

  for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    value=$(env_proxy_value "$name")
    [[ -n "$value" ]] || continue
    tested=1
    cmd_env_check_test_one "$name" "$value" || failed=1
  done

  if [[ "$tested" -eq 0 ]]; then
    echo "  [fail] no proxy environment variables are set"
    return 1
  fi

  [[ "$failed" -eq 0 ]] || return 1
}

section() {
  printf '\n== %s ==\n' "$1"
}

show_command() {
  local output status
  echo "\$ $*"
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" | sed 's/^/  /'
  fi
  if [[ "$status" -ne 0 ]]; then
    echo "  (exit $status)"
  fi
}

show_shell() {
  local command=$1 output status
  echo "\$ $command"
  set +e
  output=$(bash -c "$command" 2>&1)
  status=$?
  set -e
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" | sed 's/^/  /'
  fi
  if [[ "$status" -ne 0 ]]; then
    echo "  (exit $status)"
  fi
}

cmd_inspect() {
  local pid pids

  section "Config"
  echo "config: $config_file"
  echo "pid file: $pid_file"
  echo "log file: $log_file"
  show_command sing-box check -c "$config_file"
  show_command sing-box version

  section "Process"
  if pid=$(pid_from_file 2>/dev/null); then
    echo "pid file value: $pid"
    if pid_alive "$pid"; then
      echo "pid file process: alive"
      echo "command: $(pid_command "$pid")"
    else
      echo "pid file process: not running"
    fi
  else
    echo "pid file: missing"
  fi

  pids=$(find_running_pids | unique_pids | tr '\n' ' ')
  if [[ -n "${pids// }" ]]; then
    echo "matching sing-box run pids: $pids"
  else
    echo "matching sing-box run pids: none"
  fi

  section "Ports"
  show_shell "lsof -nP -iTCP:$port -sTCP:LISTEN"
  show_shell "lsof -nP -iTCP:$clash_port -sTCP:LISTEN"
  show_shell "netstat -an -p tcp | awk '/\\.($port|$clash_port)[[:space:]].*LISTEN/{print}'"
  show_command nc -vz "$host" "$port"

  section "System Proxy"
  show_command scutil --proxy
  show_command networksetup -getwebproxy "$network_service"
  show_command networksetup -getsecurewebproxy "$network_service"
  show_command networksetup -getsocksfirewallproxy "$network_service"

  section "DNS"
  show_command networksetup -getdnsservers "$network_service"
  show_shell "scutil --dns | sed -n '1,160p'"

  section "Recent Log"
  show_command ls -lh "$log_file"
  show_command tail -n 80 "$log_file"

  section "TUN"
  show_shell "ifconfig | awk '/^[a-z0-9]+:/{iface=\$1} /172\\.19\\.0\\.1/{print iface \" \" \$0}'"
  show_shell "netstat -rn -f inet | awk '/172\\.19\\.0\\.1|utun/{print}'"
}

main() {
  local command=${1:-help}
  shift || true

  case "$command" in
    help)
      [[ "$#" -le 2 ]] || fail "help takes at most a command and subcommand"
      show_help "${1:-}" "${2:-}"
      return
      ;;
    -h|--help)
      [[ "$#" -eq 0 ]] || fail "$command takes no arguments"
      usage
      return
      ;;
  esac

  if [[ "$#" -eq 1 ]] && is_help_arg "$1"; then
    show_help "$command"
    return
  fi

  case "$command" in
    run|start)
      [[ "$#" -eq 0 ]] || fail "$command takes no arguments"
      cmd_run
      cmd_proxy_on
      ;;
    stop)
      [[ "$#" -eq 0 ]] || fail "stop takes no arguments"
      cmd_stop
      ;;
    restart)
      [[ "$#" -eq 0 ]] || fail "restart takes no arguments"
      cmd_restart
      ;;
    reset|recover)
      [[ "$#" -le 1 ]] || fail "$command takes at most --hard"
      [[ "$#" -eq 0 || "$1" == "--hard" ]] || fail "usage: $0 $command [--hard]"
      cmd_reset "${1:-}"
      ;;
    subscription|sub)
      if [[ "$#" -eq 2 ]] && is_help_arg "$2"; then
        show_help subscription "$1"
        return
      fi
      case "${1:-}" in
        update)
          [[ "$#" -eq 1 ]] || fail "subscription update takes no extra arguments"
          cmd_subscription_update
          ;;
        list)
          [[ "$#" -eq 1 ]] || fail "subscription list takes no extra arguments"
          cmd_subscription_list
          ;;
        help|-h|--help)
          [[ "$#" -le 2 ]] || fail "subscription help takes at most one subcommand"
          show_help subscription "${2:-}"
          ;;
        *)
          echo "error: expected a subscription subcommand" >&2
          show_help subscription >&2
          exit 2
          ;;
      esac
      ;;
    clear)
      [[ "$#" -eq 0 ]] || fail "clear takes no arguments"
      cmd_clear
      ;;
    proxies)
      if [[ "$#" -eq 2 ]] && is_help_arg "$2"; then
        show_help proxies "$1"
        return
      fi
      case "${1:-}" in
        list)
          [[ "$#" -eq 1 ]] || fail "proxies list takes no extra arguments"
          cmd_proxies_list
          ;;
        switch)
          [[ "$#" -eq 1 ]] || fail "proxies switch takes no extra arguments"
          cmd_proxies_switch
          ;;
        test)
          [[ "$#" -eq 1 ]] || fail "proxies test takes no extra arguments"
          cmd_proxies_test
          ;;
        help|-h|--help)
          [[ "$#" -le 2 ]] || fail "proxies help takes at most one subcommand"
          show_help proxies "${2:-}"
          ;;
        *)
          echo "error: expected a proxies subcommand" >&2
          show_help proxies >&2
          exit 2
          ;;
      esac
      ;;
    proxy)
      if [[ "$#" -eq 2 ]] && is_help_arg "$2"; then
        show_help proxy "$1"
        return
      fi
      case "${1:-}" in
        on)
          [[ "$#" -eq 1 ]] || fail "proxy on takes no extra arguments"
          cmd_proxy_on
          ;;
        off)
          [[ "$#" -eq 1 ]] || fail "proxy off takes no extra arguments"
          cmd_proxy_off
          ;;
        help|-h|--help)
          [[ "$#" -le 2 ]] || fail "proxy help takes at most one subcommand"
          show_help proxy "${2:-}"
          ;;
        *)
          echo "error: expected a proxy subcommand" >&2
          show_help proxy >&2
          exit 2
          ;;
      esac
      ;;
    env)
      if [[ "$#" -eq 2 ]] && is_help_arg "$2"; then
        show_help env "$1"
        return
      fi
      case "${1:-on}" in
        on)
          [[ "$#" -le 1 ]] || fail "env on takes no extra arguments"
          cmd_env
          ;;
        off)
          [[ "$#" -eq 1 ]] || fail "env off takes no extra arguments"
          cmd_env_clear
          ;;
        check|status)
          [[ "$#" -eq 1 ]] || fail "env ${1:-check} takes no extra arguments"
          cmd_env_check
          ;;
        test)
          [[ "$#" -le 2 ]] || fail "env test takes at most one URL argument"
          if [[ "$#" -eq 2 ]]; then
            [[ -n "$2" ]] || fail "env test URL cannot be empty"
            proxy_test_url=$2
          fi
          cmd_env_check
          ;;
        help|-h|--help)
          [[ "$#" -le 2 ]] || fail "env help takes at most one subcommand"
          show_help env "${2:-}"
          ;;
        *)
          echo "error: expected an env subcommand" >&2
          show_help env >&2
          exit 2
          ;;
      esac
      ;;
    inspect)
      [[ "$#" -eq 0 ]] || fail "inspect takes no arguments"
      cmd_inspect
      ;;
    *)
      echo "error: unknown command '$command'" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
