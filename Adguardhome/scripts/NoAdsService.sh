#!/system/bin/sh
# Safe, scoped ad-cache blocker & system setting guard.
# Usage: NoAdsService.sh [apply|clean]

SCRIPT_BASE=$(dirname "$0")
# shellcheck source=common.sh
. "$SCRIPT_BASE/common.sh"

PATHS_FILE="$SCRIPT_DIR/noads_paths.list"

is_safe_target() {
    case "$1" in
        /data/*)
            case "$1" in
                *..*|/data|/data/|/data/data|/data/data/|/data/system|/data/system/|/data/system/ifw*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

unlock_and_remove_path() {
    _target="$1"
    [ -e "$_target" ] || return 0
    if [ -d "$_target" ]; then
        find "$_target" -depth 2>/dev/null | while IFS= read -r _item; do
            chattr -i "$_item" 2>/dev/null
            if [ -d "$_item" ]; then
                rmdir "$_item" 2>/dev/null || rm -rf "$_item" 2>/dev/null
            else
                rm -f "$_item" 2>/dev/null
            fi
        done
    else
        chattr -i "$_target" 2>/dev/null
        rm -f "$_target" 2>/dev/null
    fi
}

save_system_settings_once() {
    [ -f "$SYS_STATE_FILE" ] && return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    _pdns=$(settings get global private_dns_mode 2>/dev/null)
    _tfo=$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)
    {
        printf 'orig_private_dns_mode=%s\n' "$_pdns"
        printf 'orig_tcp_fastopen=%s\n' "$_tfo"
    } > "$SYS_STATE_FILE"
}

restore_system_settings() {
    [ -f "$SYS_STATE_FILE" ] || return 0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _k=${_line%%=*}
        _v=${_line#*=}
        case "$_k" in
            orig_private_dns_mode)
                case "$_v" in
                    off|opportunistic|hostname)
                        settings put global private_dns_mode "$_v" 2>/dev/null
                        ;;
                esac
                ;;
            orig_tcp_fastopen)
                case "$_v" in
                    [0-9]*)
                        [ -w /proc/sys/net/ipv4/tcp_fastopen ] && printf '%s\n' "$_v" > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null
                        ;;
                esac
                ;;
        esac
    done < "$SYS_STATE_FILE"
    rm -f "$SYS_STATE_FILE" 2>/dev/null
}

apply_noads() {
    load_config
    save_system_settings_once

    if [ "$disable_private_dns" = "true" ]; then
        _cur_pdns=$(settings get global private_dns_mode 2>/dev/null)
        [ "$_cur_pdns" = "off" ] || settings put global private_dns_mode off 2>/dev/null
    fi

    [ "$enable_noads" = "true" ] || return 0
    [ -f "$PATHS_FILE" ] || return 0

    while IFS= read -r _p || [ -n "$_p" ]; do
        case "$_p" in
            ''|'#'*) continue ;;
        esac
        is_safe_target "$_p" || continue
        [ -e "$_p" ] || continue

        _attr=$(lsattr -d "$_p" 2>/dev/null | awk '{print $1}')
        case "$_attr" in
            *i*) continue ;;
        esac

        if [ -d "$_p" ]; then
            rm -rf "$_p" 2>/dev/null && mkdir -p "$_p" 2>/dev/null && chattr +i "$_p" 2>/dev/null
        elif [ -f "$_p" ]; then
            : > "$_p" 2>/dev/null && chattr +i "$_p" 2>/dev/null
        fi
    done < "$PATHS_FILE"

    # Clean up deleted app remnants that may have immutable locks.
    for _d in /data/data/*==deleted==; do
        [ -d "$_d" ] || continue
        chattr -R -i "$_d" 2>/dev/null
        rm -rf "$_d" 2>/dev/null
    done
}

clean_noads() {
    if [ -f "$PATHS_FILE" ]; then
        while IFS= read -r _p || [ -n "$_p" ]; do
            case "$_p" in
                ''|'#'*) continue ;;
            esac
            is_safe_target "$_p" || continue
            unlock_and_remove_path "$_p"
        done < "$PATHS_FILE"
    fi

    # Unlock hazardous legacy paths from earlier upstream releases if present.
    for _legacy in \
        "/data/system/ifw" \
        "/data/system/cube" \
        "/data/data/com.galaxy.stock/files"
    do
        [ -e "$_legacy" ] && chattr -R -i "$_legacy" 2>/dev/null
    done

    restore_system_settings
}

case "${1:-apply}" in
    apply) apply_noads ;;
    clean|--clean) clean_noads ;;
    *)     echo "Usage: $0 {apply|clean}" >&2; exit 1 ;;
esac
