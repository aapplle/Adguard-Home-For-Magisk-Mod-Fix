#!/system/bin/sh
AGH_DIR="/data/adb/agh"
MAIN_LOG="$AGH_DIR/agh.log"

# 补全运行环境：实机存在 PATH 残缺环境下被拉起的守护实例
# （date/getprop/pgrep 全部不可用 → 日志无时间戳、看门狗误判进程丢失疯狂重生）。
# 无论本脚本被谁以何种环境启动，先自救补全 PATH。
export PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"

# 防止重复启动
[ $(pgrep -f "$0" | wc -l) -gt 1 ] && exit

# 检查 DNS 端口是否真实监听（/proc/net/udp|tcp 中的 127.0.0.1:port）
port_listening() {
    grep -q " 0100007F:$(printf '%04X' "$1") " /proc/net/udp /proc/net/tcp 2>/dev/null
}

# AGH 存活检查：按 /proc/*/cmdline 首参数前缀匹配二进制全路径
# （read 剥离 NUL 后各参数无缝拼接，前缀即锚定 argv[0]，实测 mksh/bash
# 语义一致），不依赖 pgrep -x/comm 匹配语义（实机存在按名匹配窗口期盲区）。
# 纯内建实现零 fork：旧 tr|grep 管道曾致 toybox tr 对某个 /proc 文件
# 死循环烧满一核，且逐进程 fork 洪水不可接受。c= 先清空防重定向失败时
# 残留上一轮的值误杀。
agh_running() {
    for p in /proc/[0-9]*; do
        c=
        IFS= read -r c < "$p/cmdline" 2>/dev/null
        case "$c" in
        "$AGH_DIR/bin/AdGuardHome"*) return 0 ;;
        esac
    done
    return 1
}

setup_rules() {
    # 启动 AdGuardHome（掉进程重启）
    agh_running || {
        {
            case "$(getprop persist.sys.locale)" in
                zh*) echo "$(date '+%F %T') AdGuardHome 进程丢失，正在重启..." ;;
                *)   echo "$(date '+%F %T') AdGuardHome process lost, restarting..." ;;
            esac
        } >> "$MAIN_LOG"
        export SSL_CERT_DIR="/system/etc/security/cacerts/"
        "$AGH_DIR/bin/AdGuardHome" --no-check-update &
    }

    # 等待端口真实监听（最多 5 秒），起不来则清空重定向让 DNS 直通，
    # 由下一轮循环继续重试（宁可不过滤也不全断）
    n=0
    until port_listening "$redir_port"; do
        [ "$n" -ge 10 ] && break
        sleep 0.5; n=$((n+1))
    done
    port_listening "$redir_port" || {
        iptables -w 2 -t nat -F ADGUARD 2>/dev/null
        ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
        ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
        return 0
    }

    # DNS重定向规则
    iptables -w 2 -t nat -L ADGUARD || {
        iptables -w 2 -t nat -N ADGUARD
        iptables -w 2 -t nat -I OUTPUT -j ADGUARD
    }
    iptables -w 2 -t nat -F ADGUARD
    iptables -w 2 -t nat -I ADGUARD -m owner --uid-owner "$adg_user" --gid-owner "$adg_group" -j RETURN
    iptables -w 2 -t nat -A ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port"
    iptables -w 2 -t nat -A ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port"

    # IPv6 DNS 阻断（先查后加，避免重复追加）
    ip6tables -w 2 -C OUTPUT -p udp --dport 53 -j DROP || ip6tables -w 2 -A OUTPUT -p udp --dport 53 -j DROP
    ip6tables -w 2 -C OUTPUT -p tcp --dport 53 -j DROP || ip6tables -w 2 -A OUTPUT -p tcp --dport 53 -j DROP

    # 刷新网络（开关飞行模式）
    # 仅在 framework 完全启动后执行：软重启时 service.sh 先于系统就绪重跑，
    # 此时广播可能丢失，飞行模式会被"打开"后无人关闭 → 射频关闭、整机断网
    # （端口/规则全部正常，实机需第二次软重启才恢复——即本修复针对的症状）。
    # REDIRECT 拦截 53 端口不依赖客户端刷新，跳过无副作用。
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
        for s in 1 0; do
            settings put global airplane_mode_on $s
            am broadcast -a android.intent.action.AIRPLANE_MODE
        done
    fi
}

# 规则守护循环
while true; do
    # 每轮重新读取端口：即使本守护是旧世代漏网存活，也跟随当前配置收敛，
    # 而不是固守启动时缓存的过期端口（配合下方监听检查不会写死端口）
    . "$AGH_DIR/scripts/config.prop"
    if ! agh_running || \
       ! iptables -w 2 -t nat -C ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" || \
       ! iptables -w 2 -t nat -C ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" || \
       ! ip6tables -w 2 -C OUTPUT -p udp --dport 53 -j DROP || \
       ! ip6tables -w 2 -C OUTPUT -p tcp --dport 53 -j DROP; then
        setup_rules
    fi
    sleep 5
done &