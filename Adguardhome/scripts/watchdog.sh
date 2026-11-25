#!/system/bin/sh
# Unified low-power watchdog supervising AdGuardHome, iptables, NoAdsService, and ProxyConfig.
# Replaces the 4 overlapping 5-second daemons with one single-instance loop.

SCRIPT_BASE=$(dirname "$0")
. "$SCRIPT_BASE/common.sh"

acquire_lock "watchdog" || exit 0
trap 'release_lock "watchdog"; exit 0' INT TERM EXIT

setup_timezone

MAX_CONSECUTIVE_FIXES=3
fix_failures=0
restart_failures=0
noads_tick=0

while true; do
    load_config

    # 1. Process liveness with bounded backoff
    if ! is_agh_running; then
        restart_failures=$((restart_failures + 1))
        if [ "$restart_failures" -le 5 ]; then
            agh_log WARN "AdGuardHome process missing; restarting (attempt $restart_failures/5)"
            start_agh_process
            sleep 2
            if is_agh_running; then
                agh_log INFO "AdGuardHome recovered"
                restart_failures=0
            fi
        else
            agh_log ERROR "AdGuardHome failed to stay running after 5 attempts; pausing restarts for 5 minutes"
            sleep 300
            restart_failures=0
            continue
        fi
    else
        restart_failures=0
    fi

    # 2. Firewall rules check with circuit breaker (prevents infinite rebuild loops)
    if ! "$SCRIPT_DIR/iptables.sh" check; then
        if [ "$fix_failures" -lt "$MAX_CONSECUTIVE_FIXES" ]; then
            agh_log WARN "iptables rules drift detected; reapplying"
            "$SCRIPT_DIR/iptables.sh" apply
            if "$SCRIPT_DIR/iptables.sh" check; then
                fix_failures=0
            else
                fix_failures=$((fix_failures + 1))
                agh_log ERROR "iptables verification still failing ($fix_failures/$MAX_CONSECUTIVE_FIXES)"
            fi
        fi
    else
        fix_failures=0
    fi

    # 3. Proxy config sync (every cycle when enabled)
    if [ "$enable_proxy_sync" = "true" ]; then
        "$SCRIPT_DIR/ProxyConfig.sh" apply
    fi

    # 4. Ad-cache lock & Private DNS guard (every 4th cycle ≈ 2 minutes)
    noads_tick=$(( (noads_tick + 1) % 4 ))
    if [ "$noads_tick" -eq 0 ]; then
        "$SCRIPT_DIR/NoAdsService.sh" apply
    fi

    sleep "$watch_interval"
done
