#!/system/bin/sh
# Boot-time launcher for AdGuard Home For Android (Hardened Fix).

SCRIPT_DIR="/data/adb/agh/scripts"
[ -f "$SCRIPT_DIR/common.sh" ] || exit 1
. "$SCRIPT_DIR/common.sh"

setup_timezone
load_config

# Wait for Android boot completion (bounded to 60s)
_wait=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_wait" -lt 60 ]; do
    sleep 1
    _wait=$((_wait + 1))
done

# Detect Hosts modules and warn (never auto-delete user modules)
for _m in /data/adb/modules/*; do
    [ -d "$_m" ] || continue
    [ -f "$_m/disable" ] && continue
    [ -f "$_m/remove" ] && continue
    if [ -f "$_m/system/etc/hosts" ]; then
        agh_log WARN "Active Hosts module detected: $_m (may interfere with DNS filtering)"
    fi
done

# Optionally disable TCP Fast Open (original value backed up by NoAdsService.sh)
"$SCRIPT_DIR/NoAdsService.sh" apply
if [ "$disable_tfo" = "true" ] && [ -w /proc/sys/net/ipv4/tcp_fastopen ]; then
    echo 0 > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null
fi

# Generate non-colliding random ports on cold start
pick_random_port() {
    _r=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -z "$_r" ] && _r=12345
    echo $((30000 + (_r % 35000)))
}

if ! is_agh_running; then
    R1=$(pick_random_port)
    R2=$(pick_random_port)
    while [ "$R1" = "$R2" ]; do
        R2=$(pick_random_port)
    done

    if [ -f "$YAML_FILE" ]; then
        sed -i "/^dns:/,/^[^[:space:]]/ s/^\([[:space:]]*port:\)[[:space:]]*[0-9]*/\1 $R1/" "$YAML_FILE"
        sed -i "/^http:/,/^[^[:space:]]/ s/^\([[:space:]]*address:\)[[:space:]]*127\.0\.0\.1:[0-9]*/\1 127.0.0.1:$R2/" "$YAML_FILE"
    fi

    # Bounded startup attempts with backoff (never infinite exec "$0")
    _started=0
    _try=1
    while [ "$_try" -le 5 ]; do
        start_agh_process
        sleep 2
        if is_agh_running; then
            _started=1
            break
        fi
        agh_log WARN "AdGuardHome start attempt $_try/5 failed; retrying after backoff"
        sleep "$_try"
        _try=$((_try + 1))
    done

    if [ "$_started" -eq 1 ]; then
        agh_log INFO "AdGuardHome started (dns=127.0.0.1:$R1, http=127.0.0.1:$R2)"
        update_module_prop_status ok
    else
        agh_log ERROR "AdGuardHome failed to start after 5 attempts; check $AGH_DIR/crash.log"
        update_module_prop_status err "⚠️ AdGuardHome 启动失败，请查看 /data/adb/agh/agh.log 与 crash.log"
        exit 1
    fi
else
    update_module_prop_status ok
fi

# Apply firewall and proxy integration once, then start single unified watchdog
"$SCRIPT_DIR/iptables.sh" apply
[ "$enable_proxy_sync" = "true" ] && "$SCRIPT_DIR/ProxyConfig.sh" apply
"$SCRIPT_DIR/watchdog.sh" >/dev/null 2>&1 &
