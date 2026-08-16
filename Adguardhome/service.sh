#!/system/bin/sh
SCRIPT_DIR="/data/adb/agh/scripts"
ADGPATH="/data/adb/modules/AdGuardHome"
AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
MAIN_LOG="$AGH_DIR/agh.log"
MODULES_DIR="/data/adb/modules"
AGH_MODULE_PROP="/data/adb/modules/AdGuardHome/module.prop"

# 补全守护进程运行环境：部分启动路径的 PATH 缺少 /system/bin，
# 导致守护脚本里 date/getprop 不可用（日志无时间戳、语言检测失效）
export PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"

# 解锁脚本防篡改保护
find "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \;

# 系统语言检测
locale=$(getprop persist.sys.locale)
[ -z "$locale" ] && locale="zh"
case $locale in zh*) lang=zh ;; *) lang=en ;; esac

# 检查hosts模块并中止启动
found_hosts=false
for module in "$MODULES_DIR"/*; do 
  [ -d "$module" ] && [ -f "$module/system/etc/hosts" ] && {
    found_hosts=true
    touch "$module/remove"
  }
done
if [ "$found_hosts" = true ]; then
    if [ "$lang" = "zh" ]; then
        MSG="检测到hosts模块，AdGuardHome启动已中止"
        DESC="⚠️ AdGuardHome已禁用 - 检测到hosts模块（已标记移除，请重启设备）"
    else
        MSG="Hosts module detected, AdGuardHome startup aborted"
        DESC="⚠️ AdGuardHome disabled - Hosts module detected (marked for removal, Please restart the device)"
    fi
    [ -f "$AGH_MODULE_PROP" ] && sed -i "s/description=.*/description=$DESC/" "$AGH_MODULE_PROP"
    echo "$(date '+%F %T') [ERROR] $MSG" >> "$MAIN_LOG"
    exit 1
fi

# KSU 软重启时旧进程仍存活：清理上一世代，保证单实例单世代。
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
echo "$(date '+%F %T') [minfix v20260720.5] 旧世代清理完成 (清理后 pgrep -f rc=$RC)" >> "$MAIN_LOG"

# 动态端口随机化
R1=$((30000+RANDOM%35536)); R2=$((30000+RANDOM%35536))
sed -i "s/^\([[:space:]]*port:\) [0-9]*/\1 $R1/; s/^\([[:space:]]*address:\) 127\.0\.0\.1:[0-9]*/\1 127.0.0.1:$R2/" "$BIN_DIR/AdGuardHome.yaml"
sed -i "s/^redir_port=.*/redir_port=$R1/" "$SCRIPT_DIR/config.prop" || echo "redir_port=$R1" > "$SCRIPT_DIR/config.prop"

# 启动AdGuardHome
export SSL_CERT_DIR="/system/etc/security/cacerts/"
"$BIN_DIR/AdGuardHome" --no-check-update &

# 验证AdGuardHome是否启动成功
sleep 1
if pgrep "AdGuardHome"; then
    [ "$lang" = "zh" ] && echo "$(date '+%F %T') AdGuardHome 启动成功。" >> "$MAIN_LOG" || echo "$(date '+%F %T') AdGuardHome started successfully." >> "$MAIN_LOG"
else
    [ "$lang" = "zh" ] && echo "$(date '+%F %T') AdGuardHome启动失败，尝试重启..." >> "$MAIN_LOG" || echo "$(date '+%F %T') AdGuardHome failed to start, attempting restart..." >> "$MAIN_LOG"
    # 清空 DNS 重定向让流量直通（避免规则指向死端口断网），退避 5 秒后重试
    iptables -w 2 -t nat -F ADGUARD 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
    sleep 5
    exec "$0"
fi

# 启动模块附加脚本
"$SCRIPT_DIR/iptables.sh" &
"$SCRIPT_DIR/ModuleMOD.sh" &
"$SCRIPT_DIR/NoAdsService.sh" &
"$SCRIPT_DIR/ProxyConfig.sh" &

# 执行脚本防篡改保护
find "$ADGPATH" -type f -name "*.sh" -exec chattr +i {} \;

# 日志超限时清空
[ "$(wc -c < "$MAIN_LOG")" -ge 102400 ] && : > "$MAIN_LOG"