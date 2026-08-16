#!/bin/bash
# apply-fixes.sh — idempotently apply the minfix race-condition fixes onto a
# PRISTINE upstream module tree (Adguardhome/: service.sh, scripts/, ...).
#
# Usage:  bash apply-fixes.sh <module-tree-dir> [FIXREV]
#   FIXREV defaults to the value in fixes/fixrev (fallback: 4).
# Safe to re-run on an already-fixed tree (every edit checks its marker).
# Exits non-zero if an expected upstream anchor is missing (i.e. upstream
# changed shape and the fix needs manual re-porting — see 修复说明.md).
set -euo pipefail

DIR="${1:?usage: apply-fixes.sh <module-tree-dir> [FIXREV]}"
FIXREV="${2:-$(cat "$(dirname "$0")/fixrev" 2>/dev/null || echo 4)}"
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
# 关键点：垂死的旧看门狗可能恰好在拉起 AGH（fork 后、exec 前 cmdline 仍是
# 旧值）。因此：1) 先杀守护并等 1 秒让其最后一次 spawn 落地；2) 用
# pkill/pgrep -f 按二进制全路径匹配（正则锚定结尾，防误伤 .yaml 等邻串），
# 先 TERM 再等最多 5 秒、SIGKILL 兜底——fork-exec 窗口内的实例在下一轮
# 检查/兜底中必被捕获；3) 全部退出后再随机化端口，避免 sessions.db 锁冲突。
# 注意：不要用 shell 循环逐个读 /proc/*/cmdline——实机曾致 toybox tr 死循环
# 烧满 CPU，且每周期数百次 fork 不可接受。
pkill -f "$SCRIPT_DIR/" 2>/dev/null
sleep 1
AGHPAT="$BIN_DIR/AdGuardHome( |$)"
pkill -f "$AGHPAT" 2>/dev/null
n=0
while [ "$n" -lt 10 ] && pgrep -f "$AGHPAT" >/dev/null 2>&1; do sleep 0.5; n=$((n+1)); done
pkill -9 -f "$AGHPAT" 2>/dev/null
pgrep -f "$AGHPAT" >/dev/null 2>&1; RC=$?
echo "$(date '+%F %T') [minfix v20260720.6] 旧世代清理完成 (清理后 pgrep -f rc=$RC)" >> "$MAIN_LOG"

# 动态端口随机化
''',
'[minfix v20260720.6]')

edit("service.sh",
'''# 启动AdGuardHome
export SSL_CERT_DIR="/system/etc/security/cacerts/"
''',
'''# 启动AdGuardHome（最多等待默认路由就绪 15 秒：避免在网络尚未恢复的
# 窗口里启动，导致上游 DoH 连接自出生即黑洞、DNS 持续失败）
n=0
while [ "$n" -lt 15 ] && ! ip route 2>/dev/null | grep -q '^default'; do
    sleep 1; n=$((n+1))
done
export SSL_CERT_DIR="/system/etc/security/cacerts/"
''',
'默认路由就绪')

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

# AGH 存活检查：pgrep -f 按二进制全路径匹配（正则锚定结尾防误伤邻串），
# 不依赖按名匹配语义（实机存在 fork-exec 窗口期盲区）。
# 不要用 shell 循环扫 /proc/*/cmdline：实机曾致 toybox tr 死循环烧满 CPU。
agh_running() {
    pgrep -f "$AGH_DIR/bin/AdGuardHome( |$)" >/dev/null 2>&1
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
    # 仅在 framework 完全启动后执行：软重启/开机早期 service.sh 先于系统就绪，
    # 此时广播会丢失，飞行模式可能被"打开"后无人关闭 → 射频关闭、整机断网
    # （REDIRECT 拦截 53 端口不依赖客户端刷新，跳过无副作用）
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
# AGH 同样用 -f 全路径正则清杀，不依赖 pgrep 语义），
# 并清理 DNS 重定向规则，避免卸载后规则仍指向已删除的死端口导致断网
pkill -f "$AGH_DIR/scripts/" 2>/dev/null
pkill -9 -f "$AGH_DIR/bin/AdGuardHome( |$)" 2>/dev/null
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
