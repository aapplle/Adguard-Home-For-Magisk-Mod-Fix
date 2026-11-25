#!/system/bin/sh
# Shared runtime helpers for AdGuard Home For Android (POSIX / mksh compatible).

AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
SCRIPT_DIR="$AGH_DIR/scripts"
RUN_DIR="$AGH_DIR/run"
BACKUP_DIR="$AGH_DIR/backup"
MOD_DIR="/data/adb/modules/AdGuardHome"
AGH_BIN="$BIN_DIR/AdGuardHome"
YAML_FILE="$BIN_DIR/AdGuardHome.yaml"
CONFIG_FILE="$SCRIPT_DIR/config.prop"
MAIN_LOG="$AGH_DIR/agh.log"
CRED_FILE="$AGH_DIR/initial_credentials.txt"
SYS_STATE_FILE="$BACKUP_DIR/system_settings.bak"
AGH_GID="9000"

# Default runtime configuration (overridden safely by load_config).
redir_port="35353"
sni_ports="443,8443"
PROXY_URL=""
watch_interval="30"
enable_noads="true"
enable_proxy_sync="true"
disable_private_dns="true"
disable_tfo="true"
allow_airplane_refresh="false"

detect_lang() {
    _loc=$(getprop persist.sys.locale 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$_loc" in
        en*) echo "en" ;;
        *)   echo "zh" ;;
    esac
}

setup_timezone() {
    _tz=$(getprop persist.sys.timezone 2>/dev/null)
    [ -n "$_tz" ] && export TZ="$_tz"
}

agh_log() {
    _level="$1"
    shift
    mkdir -p "$AGH_DIR" 2>/dev/null
    if [ -f "$MAIN_LOG" ]; then
        _sz=$(wc -c < "$MAIN_LOG" 2>/dev/null)
        [ -n "$_sz" ] && [ "$_sz" -ge 102400 ] 2>/dev/null && mv -f "$MAIN_LOG" "${MAIN_LOG}.1" 2>/dev/null
    fi
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$_level" "$*" >> "$MAIN_LOG"
}

# Safe line-by-line key=value parser: NEVER sources config.prop as shell code.
load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|'#'*) continue ;;
            *'='*) ;;
            *) continue ;;
        esac
        _key=${_line%%=*}
        _val=${_line#*=}
        # Strip leading/trailing whitespace on key and surrounding quotes on val.
        _key=$(printf '%s' "$_key" | tr -d ' \t\r')
        _val=$(printf '%s' "$_val" | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$_val" in
            '"'*'"') _val=${_val#\"}; _val=${_val%\"} ;;
            "'"*"'") _val=${_val#\'}; _val=${_val%\'} ;;
        esac
        case "$_key" in
            redir_port|watch_interval)
                case "$_val" in
                    ''|*[!0-9]*) ;;
                    *)
                        [ "$_key" = "redir_port" ] && redir_port="$_val"
                        [ "$_key" = "watch_interval" ] && watch_interval="$_val"
                        ;;
                esac
                ;;
            sni_ports)
                case "$_val" in
                    ''|*[!0-9,\ ]*) ;;
                    *) sni_ports="$_val" ;;
                esac
                ;;
            enable_noads|enable_proxy_sync|disable_private_dns|disable_tfo|allow_airplane_refresh)
                case "$_val" in
                    true|false)
                        case "$_key" in
                            enable_noads) enable_noads="$_val" ;;
                            enable_proxy_sync) enable_proxy_sync="$_val" ;;
                            disable_private_dns) disable_private_dns="$_val" ;;
                            disable_tfo) disable_tfo="$_val" ;;
                            allow_airplane_refresh) allow_airplane_refresh="$_val" ;;
                        esac
                        ;;
                esac
                ;;
            PROXY_URL)
                _val=$(printf '%s' "$_val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                case "$_val" in
                    '') PROXY_URL="" ;;
                    http://*|https://*)
                        # Reject shell/control characters in URLs.
                        case "$_val" in
                            *[\`\$\;\(\)\{\}\|\<\>\'\"\\]*) agh_log WARN "Ignored unsafe characters in PROXY_URL" ;;
                            *) PROXY_URL="$_val" ;;
                        esac
                        ;;
                    *) agh_log WARN "Ignored invalid PROXY_URL scheme" ;;
                esac
                ;;
        esac
    done < "$CONFIG_FILE"
    [ "$watch_interval" -lt 10 ] 2>/dev/null && watch_interval=10
    return 0
}

# Read /proc/<pid>/cmdline safely without NUL truncation (critical for Android mksh).
read_cmdline() {
    [ -r "$1" ] || return 1
    # Avoid SC2086/SC2162 issues; read raw cmdline cleanly
    tr '\0' ' ' < "$1" 2>/dev/null
}

is_agh_running() {
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        _cmd=$(read_cmdline "$_p/cmdline")
        case "$_cmd" in
            "$AGH_BIN "*|"$AGH_BIN") return 0 ;;
        esac
    done
    return 1
}

# Bounded graceful-then-forceful shutdown of AdGuardHome and module scripts.
stop_all_processes() {
    _self="$$"
    _attempt=0
    while [ "$_attempt" -lt 5 ]; do
        _found=0
        _sig="TERM"
        [ "$_attempt" -ge 3 ] && _sig="KILL"
        for _p in /proc/[0-9]*; do
            _pid="${_p#/proc/}"
            [ "$_pid" = "$_self" ] && continue
            [ -r "$_p/cmdline" ] || continue
            _cmd=$(read_cmdline "$_p/cmdline")
            case "$_cmd" in
                "$AGH_BIN"*|*"$SCRIPT_DIR/"*)
                    kill "-$_sig" "$_pid" 2>/dev/null
                    _found=1
                    ;;
            esac
        done
        [ "$_found" -eq 0 ] && break
        _attempt=$((_attempt + 1))
        sleep 1
    done
}

# Atomic mkdir-based lock with stale-PID recovery.
acquire_lock() {
    _lock_name="$1"
    _lock_dir="$RUN_DIR/${_lock_name}.lock"
    mkdir -p "$RUN_DIR" 2>/dev/null
    if mkdir "$_lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$_lock_dir/pid"
        return 0
    fi
    if [ -f "$_lock_dir/pid" ]; then
        _old_pid=$(cat "$_lock_dir/pid" 2>/dev/null)
        if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
            _old_cmd=$(read_cmdline "/proc/$_old_pid/cmdline")
            case "$_old_cmd" in
                *"$_lock_name"*) return 1 ;;
            esac
        fi
    fi
    rm -rf "$_lock_dir" 2>/dev/null
    if mkdir "$_lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$_lock_dir/pid"
        return 0
    fi
    return 1
}

release_lock() {
    rm -rf "$RUN_DIR/${1}.lock" 2>/dev/null
}

# Single-Source-of-Truth YAML readers.
get_yaml_dns_port() {
    [ -f "$YAML_FILE" ] || return 1
    sed -n '/^dns:/,/^[^[:space:]]/ s/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" | head -n 1
}

get_yaml_http_port() {
    [ -f "$YAML_FILE" ] || return 1
    sed -n '/^http:/,/^[^[:space:]]/ s/^[[:space:]]*address:[[:space:]]*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" | head -n 1
}

get_yaml_blocking_mode() {
    [ -f "$YAML_FILE" ] || return 1
    sed -n '/^filtering:/,/^[^[:space:]]/ s/^[[:space:]]*blocking_mode:[[:space:]]*\([a-zA-Z0-9_-]*\).*/\1/p' "$YAML_FILE" | head -n 1
}

get_yaml_sni_queue() {
    [ -f "$YAML_FILE" ] || return 1
    sed -n '/^sni_filter:/,/^[^[:space:]]/ s/^[[:space:]]*queue_num:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" | head -n 1
}

get_yaml_sni_ports() {
    [ -f "$YAML_FILE" ] || return 1
    sed -n '/^sni_filter:/,/^[^[:space:]]/{ /^[[:space:]]*-[[:space:]]*\([0-9][0-9]*\)/s/^[[:space:]]*-[[:space:]]*\([0-9][0-9]*\).*/\1/p; }' "$YAML_FILE" | tr '\n' ',' | sed 's/,$//'
}

get_yaml_drop_quic() {
    [ -f "$YAML_FILE" ] || return 1
    sed -n '/^sni_filter:/,/^[^[:space:]]/ s/^[[:space:]]*drop_quic:[[:space:]]*\(true\|false\).*/\1/p' "$YAML_FILE" | head -n 1
}

# Probe whether nsenter supports -G <gid> isolation on this device.
has_nsenter_gid() {
    command -v nsenter >/dev/null 2>&1 && nsenter -G "$AGH_GID" -t 1 true 2>/dev/null
}

start_agh_process() {
    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    setup_timezone
    if has_nsenter_gid; then
        nsenter -G "$AGH_GID" -t 1 "$AGH_BIN" \
            -c "$YAML_FILE" -w "$BIN_DIR" \
            --no-check-update --crash-log "$AGH_DIR/crash.log" --logfile discard >/dev/null 2>&1 &
    else
        agh_log WARN "nsenter -G $AGH_GID unavailable; starting AdGuardHome with uid-only exemption"
        "$AGH_BIN" \
            -c "$YAML_FILE" -w "$BIN_DIR" \
            --no-check-update --crash-log "$AGH_DIR/crash.log" --logfile discard >/dev/null 2>&1 &
    fi
}

update_module_prop_status() {
    _prop="$MOD_DIR/module.prop"
    [ -f "$_prop" ] || return 0
    _lang=$(detect_lang)
    _mode="$1"
    if [ "$_mode" = "ok" ]; then
        if [ "$_lang" = "zh" ]; then
            _desc="运行中：DNS+SNI 过滤已启用，点击操作按钮打开面板（首次随机密码见 /data/adb/agh/initial_credentials.txt）"
        else
            _desc="Running: DNS+SNI filtering active. Tap Action to open Web UI (initial password in /data/adb/agh/initial_credentials.txt)."
        fi
    else
        _desc="$2"
    fi
    sed -i "s|^description=.*|description=$_desc|" "$_prop" 2>/dev/null
}
