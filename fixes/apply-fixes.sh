#!/bin/bash
# apply-fixes.sh — idempotently apply the minfix race-condition fixes onto a
# PRISTINE upstream module tree (Adguardhome/: service.sh, scripts/, ...).
#
# Usage:  bash apply-fixes.sh <module-tree-dir> [FIXREV]
#   FIXREV defaults to the value in fixes/fixrev (fallback: 8).
# Safe to re-run on an already-fixed tree (every edit checks its marker).
# Exits non-zero if an expected upstream anchor is missing (i.e. upstream
# changed shape and the fix needs manual re-porting — see 修复说明.md).
set -euo pipefail

DIR="${1:?usage: apply-fixes.sh <module-tree-dir> [FIXREV]}"
FIXREV="${2:-$(cat "$(dirname "$0")/fixrev" 2>/dev/null || echo 8)}"
FORK_REPO_RAW="https://raw.githubusercontent.com/aapplle/Adguard-Home-For-Magisk-Mod-Fix/main/Update.json"

python3 - "$DIR" "$FIXREV" "$FORK_REPO_RAW" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
fixrev = sys.argv[2]
update_json = sys.argv[3]

def edit(rel, old, new, marker):
    """Replace `old` with `new` once; skip if `marker` already present."""
    p = root / rel
    s = p.read_text(encoding="utf-8")
    if marker in s:
        return
    if old not in s:
        sys.exit(f"ANCHOR MISSING in {rel}: {old[:60]!r}...")
    p.write_text(s.replace(old, new, 1), encoding="utf-8")

# ---------------- service.sh ----------------
edit("service.sh",
'''AGH_MODULE_PROP="/data/adb/modules/AdGuardHome/module.prop"
''',
'''AGH_MODULE_PROP="/data/adb/modules/AdGuardHome/module.prop"

# 补全守护进程运行环境：部分启动路径的 PATH 缺少 /system/bin，
# 导致守护脚本里 date/getprop 不可用（日志无时间戳、语言检测失效）
export PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"
''',
'补全守护进程运行环境')

edit("service.sh",
'''# 动态端口随机化
''',
'''# KSU 软重启时旧进程仍存活：清理上一世代，保证单实例单世代。
# 关键点：垂死的旧看门狗可能恰好在拉起 AGH（fork 后、exec 前 comm 仍是
# sh，pgrep/pkill 按名匹配存在窗口期盲区）。因此：
# 1) 先杀守护并等 1 秒，让其最后一次 spawn 落地成完整进程；
# 2) 按 /proc/*/cmdline 首参数前缀匹配 AGH 二进制全路径，多轮扫描清杀
#    （不依赖 pgrep 匹配语义，fork-exec 窗口后一轮必被捕获）；cmdline 用
#    shell 内建 read 直读（NUL 剥离后各参数无缝拼接，前缀即锚定 argv[0]，
#    实测 mksh/bash 语义一致）：零 fork 零外部命令——旧 tr|grep 逐进程管道
#    曾致 toybox tr 对某个 /proc 文件死循环烧满一核；
# 3) 全部退出后再随机化端口启新实例，避免 sessions.db 单实例锁冲突。
pkill -f "$SCRIPT_DIR/" 2>/dev/null
sleep 1
i=0
while [ "$i" -lt 5 ]; do
    FOUND=0
    for p in /proc/[0-9]*; do
        c=
        IFS= read -r c < "$p/cmdline" 2>/dev/null
        case "$c" in
        "$BIN_DIR/AdGuardHome"*) kill "${p#/proc/}" 2>/dev/null; FOUND=1 ;;
        esac
    done
    [ "$FOUND" = 0 ] && break
    sleep 0.5; i=$((i+1))
done
for p in /proc/[0-9]*; do
    c=
    IFS= read -r c < "$p/cmdline" 2>/dev/null
    case "$c" in
    "$BIN_DIR/AdGuardHome"*) kill -9 "${p#/proc/}" 2>/dev/null ;;
    esac
done
pkill -x "AdGuardHome" 2>/dev/null
pkill -9 -x "AdGuardHome" 2>/dev/null
pgrep -x "AdGuardHome" >/dev/null 2>&1; RC=$?
echo "$(date '+%F %T') [minfix v20260720.8] 旧世代清理完成 (清理后 pgrep -x rc=$RC)" >> "$MAIN_LOG"

# 动态端口随机化
''',
'[minfix v20260720.8]')

edit("service.sh",
'''# KSU 软重启时旧进程仍存活：清理上一世代，保证单实例单世代。
''',
'''# 本启动周期已存在健康世代则直接跳过（外部启动器会并发双跑/重复触发
# service.sh；此前每次触发都拆掉健康世代重建，等路由+重启的十几秒里 DNS
# 完全中断——实机 02:53 世代切换窗口即「短暂无网络」的来源）。仅在
# 「确证健康」时跳过：AGH 存活（cmdline 前缀）+ 看门狗存活 + config 端口
# 真实监听，三者齐备；任一不成立即走下方正常清理重建（宁重建勿漏判）。
gen_healthy() {
    GH=0; WD=0
    for p in /proc/[0-9]*; do
        c=
        IFS= read -r c < "$p/cmdline" 2>/dev/null
        case "$c" in
        "$BIN_DIR/AdGuardHome"*) GH=1 ;;
        *"$SCRIPT_DIR/iptables.sh"*) WD=1 ;;
        esac
    done
    [ "$GH" = 1 ] && [ "$WD" = 1 ] || return 1
    . "$SCRIPT_DIR/config.prop" 2>/dev/null
    [ -n "${redir_port:-}" ] && grep -q " 0100007F:$(printf '%04X' "$redir_port" 2>/dev/null) " /proc/net/udp /proc/net/tcp 2>/dev/null
}
if gen_healthy; then
    echo "$(date '+%F %T') [minfix v20260720.8] 当前世代健康，跳过重复启动" >> "$MAIN_LOG"
    exit 0
fi
# 并发双跑合并：健康门未过但另有 service.sh 实例存活（零 fork 内建扫描
# 按 pid 剔除自身后命中，即外部启动器并发双跑，另一实例大概率正处于
# 等路由的启动窗口——冷启动期
# 「清理,清理,成功,成功」形态的来源）。最多等 20 秒，期间变为健康则跳过；
# 超时仍不健康则本实例照常走下方清理重建（兜底行为与原先完全一致，无锁
# 无标记文件，等待仅以「另一实例存活」为准，失败安全）。
otherservice() {
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        c=
        IFS= read -r c < "$p/cmdline" 2>/dev/null
        case "$c" in
        *"$ADGPATH/service.sh"*) return 0 ;;
        esac
    done
    return 1
}
n=0
while [ "$n" -lt 20 ] && otherservice; do
    if gen_healthy; then
        echo "$(date '+%F %T') [minfix v20260720.8] 另一实例已完成启动，本实例跳过" >> "$MAIN_LOG"
        exit 0
    fi
    sleep 1; n=$((n+1))
done
# 终局判定：另一实例退出后，其拉起的世代（AGH+看门狗独立进程）仍在服役；
# 此处健康即跳过——1 秒轮询可能错过「看门狗已起→实例退出」的亚秒级窗口。
if gen_healthy; then
    echo "$(date '+%F %T') [minfix v20260720.8] 另一实例已完成启动，本实例跳过" >> "$MAIN_LOG"
    exit 0
fi

# KSU 软重启时旧进程仍存活：清理上一世代，保证单实例单世代。
''',
'当前世代健康，跳过重复启动')

edit("service.sh",
'''# 动态端口随机化
R1=$((30000+RANDOM%35536)); R2=$((30000+RANDOM%35536))
''',
'''# 动态端口随机化（以 boot_id 为种子：同一启动周期内取值恒定——外部启动器
# 并发双跑/重复触发 service.sh 时，两次随机化写入相同值，不再互相覆盖产生
# 端口漂移（漂移时规则指向死端口 → 短暂无网络）。种子取 cksum 十进制的
# 两个不重叠 5 位切片并强制 10# 十进制：数值 <10^5 远离 32 位边界，
# mksh/bash 实测逐位一致——整数位运算曾在设备 mksh 求值失败（minfix9 教训）。
# 跨完整重启端口仍每次变化；R1==R2 时 +13 错开，防 DNS-TCP 与 web 端口冲突。）
BOOT_SEED=$(cksum /proc/sys/kernel/random/boot_id 2>/dev/null)
BOOT_SEED=${BOOT_SEED%% *}
if [ -n "$BOOT_SEED" ]; then
    SA=${BOOT_SEED:0:5}; SB=${BOOT_SEED:5:5}
    R1=$((30000+10#${SA:-0}%32768)); R2=$((30000+10#${SB:-0}%32768))
else
    R1=$((30000+RANDOM%35536)); R2=$((30000+RANDOM%35536))
fi
[ "$R1" = "$R2" ] && R2=$((30000+(R2-30000+13)%32768))
''',
'以 boot_id 为种子')

edit("service.sh",
'''    exec "$0"
''',
'''    # 清空 DNS 重定向让流量直通（避免规则指向死端口断网），退避 5 秒后重试
    iptables -w 2 -t nat -F ADGUARD 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
    sleep 5
    exec "$0"
''',
'退避 5 秒后重试')

edit("service.sh",
'''# 启动AdGuardHome
export SSL_CERT_DIR="/system/etc/security/cacerts/"
''',
'''# 启动AdGuardHome（最多等待默认路由就绪 15 秒：避免在网络尚未恢复的
# 窗口里启动，导致上游 DoH 连接自出生即黑洞、DNS 持续失败——实机症状：
# 端口/规则全部正确但 DNS 解析异常无网络）
n=0
while [ "$n" -lt 15 ] && ! ip route 2>/dev/null | grep -q '^default'; do
    sleep 1; n=$((n+1))
done
export SSL_CERT_DIR="/system/etc/security/cacerts/"
''',
'默认路由就绪')

# ---------------- scripts/iptables.sh ----------------
edit("scripts/iptables.sh",
'''AGH_DIR="/data/adb/agh"
. "$AGH_DIR/scripts/config.prop"
MAIN_LOG="$AGH_DIR/agh.log"
''',
'''AGH_DIR="/data/adb/agh"
MAIN_LOG="$AGH_DIR/agh.log"

# 补全运行环境：实机存在 PATH 残缺环境下被拉起的守护实例
# （date/getprop/pgrep 全部不可用 → 日志无时间戳、看门狗误判进程丢失疯狂重生）。
# 无论本脚本被谁以何种环境启动，先自救补全 PATH。
export PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"
''',
'补全运行环境')

edit("scripts/iptables.sh",
'''[ $(pgrep -f "$0" | wc -l) -gt 1 ] && exit

setup_rules() {
''',
'''[ $(pgrep -f "$0" | wc -l) -gt 1 ] && exit

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
''',
'agh_running() {')

edit("scripts/iptables.sh",
'''    # 启动 AdGuardHome（掉进程重启）
    pgrep -x "AdGuardHome" || {
''',
'''    # 启动 AdGuardHome（掉进程重启）
    agh_running || {
''',
'agh_running || {')

edit("scripts/iptables.sh",
'''        "$AGH_DIR/bin/AdGuardHome" --no-check-update &
    }

    # DNS重定向规则
''',
'''        "$AGH_DIR/bin/AdGuardHome" --no-check-update &
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
''',
'等待端口真实监听')

edit("scripts/iptables.sh",
'''    # IPv6 DNS 阻断
    ip6tables -w 2 -A OUTPUT -p udp --dport 53 -j DROP
    ip6tables -w 2 -A OUTPUT -p tcp --dport 53 -j DROP
''',
'''    # IPv6 DNS 阻断（先查后加，避免重复追加）
    ip6tables -w 2 -C OUTPUT -p udp --dport 53 -j DROP || ip6tables -w 2 -A OUTPUT -p udp --dport 53 -j DROP
    ip6tables -w 2 -C OUTPUT -p tcp --dport 53 -j DROP || ip6tables -w 2 -A OUTPUT -p tcp --dport 53 -j DROP
''',
'先查后加，避免重复追加')

edit("scripts/iptables.sh",
'''    # 刷新网络（开关飞行模式）
    for s in 1 0; do
        settings put global airplane_mode_on $s
        am broadcast -a android.intent.action.AIRPLANE_MODE
    done
''',
'''    # 刷新网络（开关飞行模式）
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
''',
'sys.boot_completed')


edit("scripts/iptables.sh",
'''# 规则守护循环
while true; do
    if ! pgrep -x "AdGuardHome" || \\
''',
'''# 规则守护循环
while true; do
    # 每轮重新读取端口：即使本守护是旧世代漏网存活，也跟随当前配置收敛，
    # 而不是固守启动时缓存的过期端口（配合下方监听检查不会写死端口）
    . "$AGH_DIR/scripts/config.prop"
    if ! agh_running || \\
''',
'每轮重新读取端口')

# ---------------- uninstall.sh ----------------
edit("uninstall.sh",
'''pkill -9 "NoAdsService"
pkill -9 "ProxyConfig"
''',
'''pkill -9 "NoAdsService"
pkill -9 "ProxyConfig"
# 停止其余守护与 AGH（-f 按命令行匹配，comm 为 sh 时原名匹配不中；
# AGH 按 /proc/*/cmdline 首参数精确匹配清杀，不依赖 pgrep 语义），
# 并清理 DNS 重定向规则，避免卸载后规则仍指向已删除的死端口导致断网
pkill -f "$AGH_DIR/scripts/" 2>/dev/null
for p in /proc/[0-9]*; do
    c=
    IFS= read -r c < "$p/cmdline" 2>/dev/null
    case "$c" in
    "$AGH_DIR/bin/AdGuardHome"*) kill -9 "${p#/proc/}" 2>/dev/null ;;
    esac
done
iptables -w 2 -t nat -F ADGUARD 2>/dev/null
iptables -w 2 -t nat -D OUTPUT -j ADGUARD 2>/dev/null
iptables -w 2 -t nat -X ADGUARD 2>/dev/null
ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
''',
'停止其余守护与 AGH')

# ---------------- customize.sh ----------------
edit("customize.sh",
'''pkill -9 "AdGuardHome"
fi

# 正在停止NoAdsService
[ -f "$AGH_DIR/scripts/NoAdsService.sh" ] && {
    i18n_print "- Stopping NoAdsService process" "- 正在终止NoAdsService进程"
    pkill -9 "NoAdsService"
}

# 正在停止ProxyConfig
[ -f "$AGH_DIR/scripts/ProxyConfig.sh" ] && {
    i18n_print "- Stopping ProxyConfig process" "- 正在终止ProxyConfig进程"
    pkill -9 "ProxyConfig"
}
''',
'''pkill -9 "AdGuardHome"
# 守护脚本以 sh 解释执行（comm=sh），按名字 pkill 匹配不到，必须 -f 按路径匹配；
# 否则旧世代守护（含 iptables.sh 看门狗）会在升级后继续存活，与新世代并发竞态
pkill -9 -f "$AGH_DIR/scripts/" 2>/dev/null
sleep 1
pkill -9 -f "$AGH_DIR/scripts/" 2>/dev/null
fi
''',
'必须 -f 按路径匹配')

# ---------------- module.prop ----------------
import re
p = root / "module.prop"
s = p.read_text(encoding="utf-8")
if "minfix" not in s:
    m = re.search(r"^version=(\S+)", s, re.M)
    c = re.search(r"^versionCode=(\d+)", s, re.M)
    if not m or not c:
        sys.exit("ANCHOR MISSING in module.prop: version/versionCode")
    s = re.sub(r"^version=.*$", f"version={m.group(1)}-minfix{fixrev}", s, flags=re.M)
    s = re.sub(r"^versionCode=.*$", f"versionCode={int(c.group(1)) + int(fixrev)}", s, flags=re.M)
    s = re.sub(r"^updateJson=.*$", f"updateJson={update_json}", s, flags=re.M)
    p.write_text(s, encoding="utf-8")

print("apply-fixes: all fixes applied (fixrev=%s)" % fixrev)
PYEOF
