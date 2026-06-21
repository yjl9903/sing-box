#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config_file="$script_dir/config.json"
config_template_file="$script_dir/config.template.json"
env_file="$script_dir/.env"
subscription_cache_file="$script_dir/config.subscription.json"
pid_file="$script_dir/.sing-box.pid"
log_file="$script_dir/.sing-box.log"
lock_dir="$script_dir/.sing-box.lock"
config_hash_file="$script_dir/.sing-box.config.sha256"

network_service="Wi-Fi"
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
  cat <<EOF
Usage:
  $0 run|start
  $0 stop
  $0 restart
  $0 update
  $0 proxies list
  $0 proxies switch
  $0 proxies test
  $0 proxy on
  $0 proxy off
  $0 env [on|off|check|test [url]|status]
  $0 inspect
EOF
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

subscription_url() {
  [[ -f "$env_file" ]] || fail "missing env file: $env_file"

  local line value
  line=$(grep -E '^[[:space:]]*SUBSCRIPTION_URL=' "$env_file" | tail -n 1 || true)
  [[ -n "$line" ]] || fail "missing SUBSCRIPTION_URL in $env_file"

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
  cmd_update_impl
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
  acquire_lock
  cmd_stop_impl
}

cmd_restart() {
  acquire_lock
  cmd_update_impl
  check_config
  cmd_stop_impl
  cmd_run_impl_without_update
  cmd_proxy_on
}

count_subscription_nodes() {
  jq '[.outbounds[]? | select(.tag and (.type | IN("direct", "block", "dns", "selector", "urltest") | not))] | length' "$1"
}

fetch_subscription_cache() {
  check_command curl

  local url tmp_subscription node_count
  url=$(subscription_url)
  tmp_subscription=$(mktemp "$script_dir/.subscription.XXXXXX.json")

  echo "fetching subscription config"
  if ! curl -fsSL "$url" -o "$tmp_subscription"; then
    rm -f "$tmp_subscription"
    if [[ -f "$subscription_cache_file" ]]; then
      echo "warning: failed to fetch subscription config; using cached subscription"
      return 0
    fi
    fail "failed to fetch subscription config and no cache exists"
  fi

  if ! jq -e '.outbounds | type == "array"' "$tmp_subscription" >/dev/null; then
    rm -f "$tmp_subscription"
    if [[ -f "$subscription_cache_file" ]]; then
      echo "warning: subscription response is invalid; using cached subscription"
      return 0
    fi
    fail "subscription response is not a sing-box config with outbounds and no cache exists"
  fi

  node_count=$(count_subscription_nodes "$tmp_subscription")
  if [[ "$node_count" -le 0 ]]; then
    rm -f "$tmp_subscription"
    if [[ -f "$subscription_cache_file" ]]; then
      echo "warning: subscription config contains no proxy outbounds; using cached subscription"
      return 0
    fi
    fail "subscription config contains no proxy outbounds and no cache exists"
  fi
  mv "$tmp_subscription" "$subscription_cache_file"
}

generate_config_from_cache() {
  check_config_template
  [[ -f "$subscription_cache_file" ]] || fail "missing subscription cache: $subscription_cache_file"

  local tmp_merged node_count
  tmp_merged=$(mktemp "$script_dir/.config.XXXXXX.json")

  node_count=$(count_subscription_nodes "$subscription_cache_file")
  [[ "$node_count" -gt 0 ]] || fail "subscription cache contains no proxy outbounds"

  if ! jq --slurpfile subscription "$subscription_cache_file" '
    def is_node:
      .tag and (.type | IN("direct", "block", "dns", "selector", "urltest") | not);

    ($subscription[0].outbounds | map(select(is_node))) as $nodes
    | ($nodes | map(.tag)) as $node_tags
    | .outbounds =
        (
          [.outbounds[] | select(is_node | not)
            | if .type == "selector" then .outbounds = $node_tags else . end]
          + $nodes
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

cmd_update_impl() {
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

cmd_update() {
  acquire_lock
  cmd_update_impl
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
  echo "system proxy enabled on $network_service: $host:$port"
}

cmd_proxy_off() {
  networksetup -setwebproxystate           "$network_service" off
  networksetup -setsecurewebproxystate     "$network_service" off
  networksetup -setsocksfirewallproxystate "$network_service" off
  echo "system proxy disabled on $network_service"
}

cmd_env() {
  local http_url socks_url
  http_url="http://$host:$port"
  socks_url="socks5://$host:$port"

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
      printf 'socks5://%s:%s\n' "$host" "$port"
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

  section "TUN"
  show_shell "ifconfig | awk '/^[a-z0-9]+:/{iface=\$1} /172\\.19\\.0\\.1/{print iface \" \" \$0}'"
  show_shell "netstat -rn -f inet | awk '/172\\.19\\.0\\.1|utun/{print}'"
}

main() {
  local command=${1:-help}
  shift || true

  case "$command" in
    run|start)
      [[ "$#" -eq 0 ]] || fail "$command takes no arguments"
      cmd_run
      cmd_proxy_on
      ;;
    stop)
      [[ "$#" -eq 0 ]] || fail "stop takes no arguments"
      cmd_stop
      cmd_proxy_off
      ;;
    restart)
      [[ "$#" -eq 0 ]] || fail "restart takes no arguments"
      cmd_restart
      ;;
    update)
      [[ "$#" -eq 0 ]] || fail "update takes no arguments"
      cmd_update
      ;;
    proxies)
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
        *)
          fail "usage: $0 proxies list|switch|test"
          ;;
      esac
      ;;
    proxy)
      case "${1:-}" in
        on)
          [[ "$#" -eq 1 ]] || fail "proxy on takes no extra arguments"
          cmd_proxy_on
          ;;
        off)
          [[ "$#" -eq 1 ]] || fail "proxy off takes no extra arguments"
          cmd_proxy_off
          ;;
        *)
          fail "usage: $0 proxy on|off"
          ;;
      esac
      ;;
    env)
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
        *)
          fail "usage: $0 env [on|off|check|test [url]|status]"
          ;;
      esac
      ;;
    inspect)
      [[ "$#" -eq 0 ]] || fail "inspect takes no arguments"
      cmd_inspect
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
