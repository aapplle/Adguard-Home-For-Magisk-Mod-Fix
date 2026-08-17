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

# 本启动周期已存在健康世代则直接跳过（外部启动器会并发双跑/重复触发
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

# 动态端口随机化（以 boot_id 为种子：同一启动周期内取值恒定——外部启动器
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
sed -i "s/^\([[:space:]]*port:\) [0-9]*/\1 $R1/; s/^\([[:space:]]*address:\) 127\.0\.0\.1:[0-9]*/\1 127.0.0.1:$R2/" "$BIN_DIR/AdGuardHome.yaml"
sed -i "s/^redir_port=.*/redir_port=$R1/" "$SCRIPT_DIR/config.prop" || echo "redir_port=$R1" > "$SCRIPT_DIR/config.prop"

# 启动AdGuardHome（最多等待默认路由就绪 15 秒：避免在网络尚未恢复的
# 窗口里启动，导致上游 DoH 连接自出生即黑洞、DNS 持续失败——实机症状：
# 端口/规则全部正确但 DNS 解析异常无网络）
n=0
while [ "$n" -lt 15 ] && ! ip route 2>/dev/null | grep -q '^default'; do
    sleep 1; n=$((n+1))
done
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