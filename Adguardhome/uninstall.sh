#!/system/bin/sh
# Clean uninstaller for AdGuard Home For Android (Hardened Fix).

AGH_DIR="/data/adb/agh"
SCRIPT_DIR="$AGH_DIR/scripts"
ADGPATH="/data/adb/modules/AdGuardHome"

if [ -f "$SCRIPT_DIR/common.sh" ]; then
    # shellcheck source=common.sh
    . "$SCRIPT_DIR/common.sh"
    stop_all_processes
else
    _attempt=0
    while [ "$_attempt" -lt 5 ]; do
        _found=0
        for _p in /proc/[0-9]*; do
            [ -r "$_p/cmdline" ] || continue
            _cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
            case "$_cmd" in
                "$AGH_DIR/bin/AdGuardHome"*|*"$SCRIPT_DIR/"*)
                    kill -9 "${_p#/proc/}" 2>/dev/null
                    _found=1
                    ;;
            esac
        done
        [ "$_found" -eq 0 ] && break
        _attempt=$((_attempt + 1))
        sleep 1
    done
fi

# 1. Restore proxy configurations
[ -x "$SCRIPT_DIR/ProxyConfig.sh" ] && "$SCRIPT_DIR/ProxyConfig.sh" clean

# 2. Clean all iptables/ip6tables chains and legacy rules
[ -x "$SCRIPT_DIR/iptables.sh" ] && "$SCRIPT_DIR/iptables.sh" clean

# 3. Unlock ad-cache targets and restore original private_dns / tcp_fastopen settings
[ -x "$SCRIPT_DIR/NoAdsService.sh" ] && "$SCRIPT_DIR/NoAdsService.sh" clean

# 4. Remove any immutable flags left on scripts
find "$SCRIPT_DIR" "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \; 2>/dev/null

# 5. Remove module data and directory
rm -rf "$AGH_DIR" "$ADGPATH"
