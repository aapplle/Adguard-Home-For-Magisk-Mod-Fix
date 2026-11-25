#!/system/bin/sh
# Idempotent iptables/ip6tables manager for AdGuardHome DNS redirect & SNI NFQUEUE.
# Usage: iptables.sh [apply|check|clean]

SCRIPT_BASE=$(dirname "$0")
# shellcheck source=common.sh
. "$SCRIPT_BASE/common.sh"

CONNBYTES_LIMIT="0:20480"
HAS_IPV6=0
HAS_NFQUEUE=0
HAS_CONNBYTES=0
OWNER_MATCH=""

detect_capabilities() {
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -w 5 -L OUTPUT >/dev/null 2>&1; then
        HAS_IPV6=1
    fi

    if has_nsenter_gid; then
        OWNER_MATCH="-m owner --uid-owner 0 --gid-owner $AGH_GID"
    else
        OWNER_MATCH="-m owner --uid-owner 0"
    fi

    # Prefer lock-free procfs capability checks to avoid xtables lock contention with netd at boot.
    if [ -r /proc/net/ip_tables_targets ]; then
        grep -qw "NFQUEUE" /proc/net/ip_tables_targets 2>/dev/null && HAS_NFQUEUE=1
    fi
    if [ "$HAS_NFQUEUE" -eq 1 ] && [ -r /proc/net/ip_tables_matches ]; then
        grep -qw "connbytes" /proc/net/ip_tables_matches 2>/dev/null && HAS_CONNBYTES=1
        return 0
    fi

    # Fallback probe via temporary chain with generous xtables lock wait.
    if iptables -w 10 -t filter -N AGH_PROBE 2>/dev/null || iptables -w 10 -t filter -F AGH_PROBE 2>/dev/null; then
        if iptables -w 10 -t filter -A AGH_PROBE -p tcp --dport 443 \
            -j NFQUEUE --queue-num 7 --queue-bypass 2>/dev/null; then
            HAS_NFQUEUE=1
            iptables -w 10 -t filter -F AGH_PROBE 2>/dev/null
            if iptables -w 10 -t filter -A AGH_PROBE -p tcp --dport 443 \
                -m connbytes --connbytes "$CONNBYTES_LIMIT" --connbytes-dir original --connbytes-mode bytes \
                -j NFQUEUE --queue-num 7 --queue-bypass 2>/dev/null; then
                HAS_CONNBYTES=1
            fi
        fi
        iptables -w 10 -t filter -F AGH_PROBE 2>/dev/null
        iptables -w 10 -t filter -X AGH_PROBE 2>/dev/null
    fi
}

load_runtime_params() {
    load_config
    YAML_DNS_PORT=$(get_yaml_dns_port)
    [ -n "$YAML_DNS_PORT" ] && redir_port="$YAML_DNS_PORT"

    YAML_BLOCKING_MODE=$(get_yaml_blocking_mode)
    [ -z "$YAML_BLOCKING_MODE" ] && YAML_BLOCKING_MODE="default"

    YAML_SNI_QUEUE=$(get_yaml_sni_queue)
    [ -z "$YAML_SNI_QUEUE" ] && YAML_SNI_QUEUE="7"

    YAML_SNI_PORTS=$(get_yaml_sni_ports)
    [ -n "$YAML_SNI_PORTS" ] && sni_ports="$YAML_SNI_PORTS"

    YAML_DROP_QUIC=$(get_yaml_drop_quic)
    [ -z "$YAML_DROP_QUIC" ] && YAML_DROP_QUIC="false"
}

add_sni_chain() {
    _cmd="$1"
    "$_cmd" -w 5 -t filter -N AGH_SNI 2>/dev/null
    "$_cmd" -w 5 -t filter -F AGH_SNI
    # shellcheck disable=SC2086
    "$_cmd" -w 5 -t filter -A AGH_SNI $OWNER_MATCH -j RETURN
    "$_cmd" -w 5 -t filter -A AGH_SNI -o lo -j RETURN

    _oldifs=$IFS
    IFS=', '
    # shellcheck disable=SC2086
    for _port in $sni_ports; do
        [ -n "$_port" ] || continue
        "$_cmd" -w 5 -t filter -A AGH_SNI -p tcp --dport "$_port" \
            --tcp-flags ALL ACK -j RETURN
        if [ "$HAS_CONNBYTES" -eq 1 ]; then
            "$_cmd" -w 5 -t filter -A AGH_SNI -p tcp --dport "$_port" \
                --tcp-flags SYN,FIN,RST NONE \
                -m connbytes --connbytes "$CONNBYTES_LIMIT" --connbytes-dir original --connbytes-mode bytes \
                -j NFQUEUE --queue-num "$YAML_SNI_QUEUE" --queue-bypass
        else
            "$_cmd" -w 5 -t filter -A AGH_SNI -p tcp --dport "$_port" \
                --tcp-flags SYN,FIN,RST NONE \
                -j NFQUEUE --queue-num "$YAML_SNI_QUEUE" --queue-bypass
        fi
    done
    IFS=$_oldifs

    "$_cmd" -w 5 -t filter -C OUTPUT -j AGH_SNI 2>/dev/null || \
        "$_cmd" -w 5 -t filter -I OUTPUT 1 -j AGH_SNI
}

check_sni_chain() {
    _cmd="$1"
    "$_cmd" -w 5 -t filter -C OUTPUT -j AGH_SNI 2>/dev/null || return 1
    # shellcheck disable=SC2086
    "$_cmd" -w 5 -t filter -C AGH_SNI $OWNER_MATCH -j RETURN 2>/dev/null || return 1
    "$_cmd" -w 5 -t filter -C AGH_SNI -o lo -j RETURN 2>/dev/null || return 1

    _oldifs=$IFS
    IFS=', '
    # shellcheck disable=SC2086
    for _port in $sni_ports; do
        [ -n "$_port" ] || continue
        "$_cmd" -w 5 -t filter -C AGH_SNI -p tcp --dport "$_port" \
            --tcp-flags ALL ACK -j RETURN 2>/dev/null || { IFS=$_oldifs; return 1; }
        if [ "$HAS_CONNBYTES" -eq 1 ]; then
            "$_cmd" -w 5 -t filter -C AGH_SNI -p tcp --dport "$_port" \
                --tcp-flags SYN,FIN,RST NONE \
                -m connbytes --connbytes "$CONNBYTES_LIMIT" --connbytes-dir original --connbytes-mode bytes \
                -j NFQUEUE --queue-num "$YAML_SNI_QUEUE" --queue-bypass 2>/dev/null || { IFS=$_oldifs; return 1; }
        else
            "$_cmd" -w 5 -t filter -C AGH_SNI -p tcp --dport "$_port" \
                --tcp-flags SYN,FIN,RST NONE \
                -j NFQUEUE --queue-num "$YAML_SNI_QUEUE" --queue-bypass 2>/dev/null || { IFS=$_oldifs; return 1; }
        fi
    done
    IFS=$_oldifs
    return 0
}

remove_chain() {
    _cmd="$1"
    _table="$2"
    _chain="$3"
    while "$_cmd" -w 5 -t "$_table" -C OUTPUT -j "$_chain" 2>/dev/null; do
        "$_cmd" -w 5 -t "$_table" -D OUTPUT -j "$_chain" 2>/dev/null || break
    done
    "$_cmd" -w 5 -t "$_table" -F "$_chain" 2>/dev/null
    "$_cmd" -w 5 -t "$_table" -X "$_chain" 2>/dev/null
}

apply_rules() {
    # 1. IPv4 NAT DNS redirect
    iptables -w 5 -t nat -N ADGUARD 2>/dev/null
    iptables -w 5 -t nat -F ADGUARD
    # shellcheck disable=SC2086
    iptables -w 5 -t nat -A ADGUARD $OWNER_MATCH -j RETURN
    iptables -w 5 -t nat -A ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port"
    iptables -w 5 -t nat -A ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port"
    iptables -w 5 -t nat -C OUTPUT -j ADGUARD 2>/dev/null || \
        iptables -w 5 -t nat -I OUTPUT 1 -j ADGUARD

    # 2. IPv4 filter outbound block (exempts AGH itself symmetrically with IPv6)
    iptables -w 5 -t filter -N ADGUARD_OUT 2>/dev/null
    iptables -w 5 -t filter -F ADGUARD_OUT
    # shellcheck disable=SC2086
    iptables -w 5 -t filter -A ADGUARD_OUT $OWNER_MATCH -j RETURN
    iptables -w 5 -t filter -A ADGUARD_OUT -o lo -j RETURN
    iptables -w 5 -t filter -A ADGUARD_OUT -p tcp --dport 853 -j REJECT
    iptables -w 5 -t filter -A ADGUARD_OUT -p udp --dport 853 -j REJECT --reject-with icmp-port-unreachable
    if [ "$YAML_DROP_QUIC" = "true" ]; then
        iptables -w 5 -t filter -A ADGUARD_OUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
    fi
    iptables -w 5 -t filter -C OUTPUT -j ADGUARD_OUT 2>/dev/null || \
        iptables -w 5 -t filter -I OUTPUT 1 -j ADGUARD_OUT

    # 3. IPv6 filter outbound block (when IPv6 is supported)
    if [ "$HAS_IPV6" -eq 1 ]; then
        ip6tables -w 5 -t filter -N ADGUARD6 2>/dev/null
        ip6tables -w 5 -t filter -F ADGUARD6
        # shellcheck disable=SC2086
        ip6tables -w 5 -t filter -A ADGUARD6 $OWNER_MATCH -j RETURN
        ip6tables -w 5 -t filter -A ADGUARD6 -o lo -j RETURN
        ip6tables -w 5 -t filter -A ADGUARD6 -p tcp --dport 853 -j REJECT
        ip6tables -w 5 -t filter -A ADGUARD6 -p udp --dport 853 -j REJECT --reject-with icmp6-port-unreachable
        ip6tables -w 5 -t filter -A ADGUARD6 -p tcp --dport 53 -j REJECT
        ip6tables -w 5 -t filter -A ADGUARD6 -p udp --dport 53 -j REJECT --reject-with icmp6-port-unreachable
        if [ "$YAML_DROP_QUIC" = "true" ]; then
            ip6tables -w 5 -t filter -A ADGUARD6 -p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable
        fi
        ip6tables -w 5 -t filter -C OUTPUT -j ADGUARD6 2>/dev/null || \
            ip6tables -w 5 -t filter -I OUTPUT 1 -j ADGUARD6
    fi

    # 4. SNI NFQUEUE rules (only when blocking_mode=strong and kernel supports NFQUEUE)
    if [ "$YAML_BLOCKING_MODE" = "strong" ] && [ "$HAS_NFQUEUE" -eq 1 ]; then
        if [ "$HAS_CONNBYTES" -eq 0 ]; then
            agh_log WARN "Kernel lacks xt_connbytes; SNI NFQUEUE running without byte limit"
        fi
        add_sni_chain iptables
        [ "$HAS_IPV6" -eq 1 ] && add_sni_chain ip6tables
    else
        remove_chain iptables filter AGH_SNI
        [ "$HAS_IPV6" -eq 1 ] && remove_chain ip6tables filter AGH_SNI
        if [ "$YAML_BLOCKING_MODE" = "strong" ] && [ "$HAS_NFQUEUE" -eq 0 ]; then
            agh_log WARN "Kernel lacks NFQUEUE support; downgraded to DNS-only filtering"
        fi
    fi

    # Optional user-requested airplane mode refresh (disabled by default).
    if [ "$allow_airplane_refresh" = "true" ]; then
        for _s in 1 0; do
            settings put global airplane_mode_on "$_s" 2>/dev/null
            am broadcast -a android.intent.action.AIRPLANE_MODE >/dev/null 2>&1
        done
    fi
}

check_rules() {
    iptables -w 5 -t nat -C OUTPUT -j ADGUARD 2>/dev/null || return 1
    # shellcheck disable=SC2086
    iptables -w 5 -t nat -C ADGUARD $OWNER_MATCH -j RETURN 2>/dev/null || return 1
    iptables -w 5 -t nat -C ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || return 1
    iptables -w 5 -t nat -C ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || return 1

    iptables -w 5 -t filter -C OUTPUT -j ADGUARD_OUT 2>/dev/null || return 1
    # shellcheck disable=SC2086
    iptables -w 5 -t filter -C ADGUARD_OUT $OWNER_MATCH -j RETURN 2>/dev/null || return 1
    iptables -w 5 -t filter -C ADGUARD_OUT -p tcp --dport 853 -j REJECT 2>/dev/null || return 1
    if [ "$YAML_DROP_QUIC" = "true" ]; then
        iptables -w 5 -t filter -C ADGUARD_OUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || return 1
    fi

    if [ "$HAS_IPV6" -eq 1 ]; then
        ip6tables -w 5 -t filter -C OUTPUT -j ADGUARD6 2>/dev/null || return 1
        ip6tables -w 5 -t filter -C ADGUARD6 -p udp --dport 53 -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || return 1
        if [ "$YAML_DROP_QUIC" = "true" ]; then
            ip6tables -w 5 -t filter -C ADGUARD6 -p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || return 1
        fi
    fi

    if [ "$YAML_BLOCKING_MODE" = "strong" ] && [ "$HAS_NFQUEUE" -eq 1 ]; then
        check_sni_chain iptables || return 1
        if [ "$HAS_IPV6" -eq 1 ]; then
            check_sni_chain ip6tables || return 1
        fi
    fi
    return 0
}

clean_rules() {
    remove_chain iptables nat ADGUARD
    remove_chain iptables filter ADGUARD_OUT
    remove_chain iptables filter AGH_SNI
    # Clean up legacy direct OUTPUT rules from earlier upstream versions.
    for _args in \
        "-p tcp --dport 853 -j REJECT" \
        "-p udp --dport 853 -j REJECT --reject-with icmp-port-unreachable" \
        "-p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable" \
        "-p tcp --dport 853 -j DROP" \
        "-p udp --dport 853 -j DROP"
    do
        # shellcheck disable=SC2086
        while iptables -w 5 -D OUTPUT $_args 2>/dev/null; do :; done
    done

    if [ "$HAS_IPV6" -eq 1 ]; then
        remove_chain ip6tables filter ADGUARD6
        remove_chain ip6tables filter AGH_SNI
        for _args in \
            "-p tcp --dport 853 -j REJECT" \
            "-p udp --dport 853 -j REJECT --reject-with icmp6-port-unreachable" \
            "-p tcp --dport 53 -j REJECT" \
            "-p udp --dport 53 -j REJECT --reject-with icmp6-port-unreachable" \
            "-p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable" \
            "-p tcp --dport 853 -j DROP" \
            "-p udp --dport 853 -j DROP" \
            "-p tcp --dport 53 -j DROP" \
            "-p udp --dport 53 -j DROP"
        do
            # shellcheck disable=SC2086
            while ip6tables -w 5 -D OUTPUT $_args 2>/dev/null; do :; done
        done
    fi
}

# Serialize concurrent iptables operations (e.g. service.sh vs watchdog.sh on soft reboot).
acquire_lock "iptables" 10 || {
    agh_log WARN "Could not acquire iptables lock within 10s; skipping $1"
    exit 0
}
trap 'release_lock "iptables"' INT TERM EXIT

detect_capabilities
load_runtime_params

case "${1:-apply}" in
    apply) apply_rules ;;
    check) check_rules ;;
    clean) clean_rules ;;
    *)     echo "Usage: $0 {apply|check|clean}" >&2; exit 1 ;;
esac
