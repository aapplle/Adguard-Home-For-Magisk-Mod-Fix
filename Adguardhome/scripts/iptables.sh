#!/system/bin/sh
SCRIPT_DIR="/data/adb/agh/scripts"

# [MOD] 设备专属修复库（实例健康检查/重建/端口同步等逻辑在 device_fix.sh）
. "$SCRIPT_DIR/device_fix.sh"

# 本脚本只允许一个实例。
# service.sh 在每次 framework soft reboot 后会先清掉旧实例。
[ "$(pgrep -f "$SCRIPT_DIR/iptables.sh" | wc -l)" -gt 1 ] && exit 0

. "$CONFIG_FILE" 2>/dev/null

setup_rules() {
    # 使用当前 config.prop 中的 redir_port；为空则不配置
    [ -n "$redir_port" ] || return 1

    # DNS 重定向规则链
    iptables -w 2 -t nat -L ADGUARD >/dev/null 2>&1 || {
        iptables -w 2 -t nat -N ADGUARD
        iptables -w 2 -t nat -I OUTPUT -j ADGUARD
    }

    iptables -w 2 -t nat -F ADGUARD
    if [ -n "$adg_user" ] || [ -n "$adg_group" ]; then
        iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner "$adg_user" --gid-owner "$adg_group" -j RETURN 2>/dev/null
    fi
    iptables -w 2 -t nat -A ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port"
    iptables -w 2 -t nat -A ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port"

    # [MOD] IPv6 DROP 改为 -C 检测后幂等添加，避免重复
    ip6tables -w 2 -C OUTPUT -p udp --dport 53 -j DROP >/dev/null 2>&1 ||
        ip6tables -w 2 -A OUTPUT -p udp --dport 53 -j DROP
    ip6tables -w 2 -C OUTPUT -p tcp --dport 53 -j DROP >/dev/null 2>&1 ||
        ip6tables -w 2 -A OUTPUT -p tcp --dport 53 -j DROP

    # [MOD] 已移除原版"开关飞行模式刷新网络"：
    #       该操作在自愈循环中反复触发会导致网络频繁闪断；
    #       本机实测 DNS 重定向无需强制刷新网络即可生效
}

# [MOD] 启动即先确保实例健康（"端口真相"判定），再建规则，避免规则指向
#       与 YAML 不一致的旧端口
ensure_agh
. "$CONFIG_FILE" 2>/dev/null
setup_rules

while true; do
    if ! port_listening udp "$redir_port" || \
       ! iptables -w 2 -t nat -C ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" >/dev/null 2>&1 || \
       ! iptables -w 2 -t nat -C ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" >/dev/null 2>&1 || \
       ! ip6tables -w 2 -C OUTPUT -p udp --dport 53 -j DROP >/dev/null 2>&1 || \
       ! ip6tables -w 2 -C OUTPUT -p tcp --dport 53 -j DROP >/dev/null 2>&1; then
        ensure_agh
        . "$CONFIG_FILE" 2>/dev/null
        setup_rules
    fi
    sleep 5
done