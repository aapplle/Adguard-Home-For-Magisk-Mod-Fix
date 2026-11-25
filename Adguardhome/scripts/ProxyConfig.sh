#!/system/bin/sh
# Pure POSIX / mksh proxy module DNS synchronizer (Surfing/Box/Mihomo/Clash).
# Usage: ProxyConfig.sh [apply|clean]

SCRIPT_BASE=$(dirname "$0")
. "$SCRIPT_BASE/common.sh"

ALL_SECTIONS="direct-nameserver: proxy-server-nameserver: nameserver: default-nameserver:"

# Escape replacement string for sed with '|' delimiter.
escape_sed_repl() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

is_standard_config() {
    _file="$1"
    [ -f "$_file" ] || return 1
    if [ -n "$PROXY_URL" ]; then
        grep -qF "$PROXY_URL" "$_file" || return 1
    fi
    grep -q '^[[:space:]]*dns:' "$_file" || return 1
    grep -q '^[[:space:]]*enhanced-mode:[[:space:]]*redir-host' "$_file" || return 1

    for _sec in $ALL_SECTIONS; do
        grep -q "^[[:space:]]*['\"]*${_sec}" "$_file" || continue
        _content=$(sed -n "/^[[:space:]]*['\"]*${_sec}/,/^[^[:space:]#]/p" "$_file")
        _has_local=$(printf '%s\n' "$_content" | grep -c "^[[:space:]]*-[[:space:]]*${LOCAL_DNS}\$")
        _other=$(printf '%s\n' "$_content" | grep '^[[:space:]]*- ' | grep -v '^[[:space:]]*- *#' | grep -cvF "$LOCAL_DNS")
        _commented=$(printf '%s\n' "$_content" | grep -c "^[[:space:]]*#.*-[[:space:]]*${LOCAL_DNS}")
        [ "$_commented" -gt 0 ] && return 1
        [ "$_has_local" -eq 0 ] || [ "$_other" -gt 0 ] && return 1
    done
    return 0
}

clean_config() {
    _file="$1"
    [ -f "$_file" ] || return 1
    for _sec in $ALL_SECTIONS; do
        sed -i "/^[[:space:]]*['\"]*${_sec}/,/^[^[:space:]]/{/^[[:space:]]*#\{0,1\}[[:space:]]*-[[:space:]]*127\.0\.0\.1:[0-9][0-9]*$/d;s/^\([[:space:]]*\)#[[:space:]]*\(-[[:space:]]*[^#].*\)/\1\2/;}" "$_file"
    done
    return 0
}

process_config() {
    _file="$1"
    is_standard_config "$_file" && return 1

    _modified=0
    if [ -n "$PROXY_URL" ] && ! grep -qF "$PROXY_URL" "$_file"; then
        _esc_url=$(escape_sed_repl "$PROXY_URL")
        sed -i "/^[[:space:]]*proxy-providers:/,/^[^[:space:]]/{s|^\([[:space:]]*\)url:.*|\1url: \"${_esc_url}\"|;}" "$_file" && _modified=1
    fi

    if grep -q '^[[:space:]]*dns:' "$_file" && ! grep -q '^[[:space:]]*enhanced-mode:[[:space:]]*redir-host' "$_file"; then
        sed -i '/^[[:space:]]*dns:/,/^[^[:space:]]/s/^\([[:space:]]*enhanced-mode:\).*/\1 redir-host/' "$_file" && _modified=1
    fi

    clean_config "$_file"
    for _sec in $ALL_SECTIONS; do
        grep -q "^[[:space:]]*['\"]*${_sec}" "$_file" || continue
        sed -i "/^[[:space:]]*['\"]*${_sec}/,/^[[:space:]]*[^[:space:]#'\"=-]/{/- ${LOCAL_DNS}/! s/^\([[:space:]]*\)\(-[[:space:]]*[^#].*\)/\1# \2/;/- ${LOCAL_DNS}/b;/^[[:space:]]*['\"]*${_sec}/{n;:l;/^[[:space:]]*#*[[:space:]]*-/!{n;bl};/- ${LOCAL_DNS}/!{s/^\([[:space:]]*\)\(#*[[:space:]]*-[[:space:]]*.*\)/\1- ${LOCAL_DNS}\\
\1# \2/;};};}" "$_file"
        _modified=1
    done

    [ "$_modified" -eq 1 ] && return 0
    return 1
}

run_for_all_proxies() {
    _mode="$1"
    _entries="
/data/adb/box_bll/clash/*.yaml|/data/adb/box_bll/scripts/box.service restart
/data/adb/box/mihomo/*.yaml|/data/adb/box/scripts/box.service restart
/data/clash/*.yaml|/data/clash/scripts/clash.service -k && /data/clash/scripts/clash.service -s
/data/media/0/Android/Clash/*.yaml|/data/adb/modules/Clash/Scripts/Clash.Service stop; /data/adb/modules/Clash/Scripts/Clash.Service start
"
    printf '%s\n' "$_entries" | while IFS='|' read -r _glob _restart_cmd; do
        [ -n "$_glob" ] || continue
        _need_restart=0
        # shellcheck disable=SC2086
        for _cfg in $_glob; do
            [ -f "$_cfg" ] || continue
            if [ "$_mode" = "clean" ]; then
                clean_config "$_cfg"
            else
                if process_config "$_cfg"; then
                    _need_restart=1
                fi
            fi
        done
        if [ "$_mode" = "apply" ] && [ "$_need_restart" -eq 1 ] && [ -n "$_restart_cmd" ]; then
            agh_log INFO "Updated proxy config ($_glob); restarting proxy service"
            sh -c "$_restart_cmd" >/dev/null 2>&1
        fi
    done
}

load_config
YAML_DNS_PORT=$(get_yaml_dns_port)
[ -n "$YAML_DNS_PORT" ] && redir_port="$YAML_DNS_PORT"
LOCAL_DNS="127.0.0.1:${redir_port}"

case "${1:-apply}" in
    apply)
        [ "$enable_proxy_sync" = "true" ] || exit 0
        run_for_all_proxies apply
        ;;
    clean|--clean)
        run_for_all_proxies clean
        ;;
    *)
        echo "Usage: $0 {apply|clean}" >&2
        exit 1
        ;;
esac
