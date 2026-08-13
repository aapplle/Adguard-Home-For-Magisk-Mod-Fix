#!/system/bin/sh
SCRIPT_DIR="/data/adb/agh/scripts"
ADGPATH="/data/adb/modules/AdGuardHome"
AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
MAIN_LOG="$AGH_DIR/agh.log"
MODULES_DIR="/data/adb/modules"
AGH_MODULE_PROP="/data/adb/modules/AdGuardHome/module.prop"

# [MOD] 设备专属修复库（全部修复逻辑在 scripts/device_fix.sh，本文件其余部分保持与上游一致，迁移时只需照抄带 [MOD] 标记的行）
. "$SCRIPT_DIR/device_fix.sh"

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

# =============================================================================
# [MOD] 设备专属启动流程（原版此处直接随机端口并启动 AGH）：
#   完整逻辑见 device_fix.sh 的 device_boot()：
#   持锁 -> 清理旧进程(三段式) -> 备份 YAML -> 选端口 -> 改 YAML 回读校验
#   -> check-config -> 启动并双重验证（进程 + 端口）-> 成功后才同步 config.prop
#   全程持有启动互斥锁：软重启时漏网的旧 iptables.sh 守护会在清理/启动窗口内
#   并发拉起 AGH，两个实例竞争 sessions.db 使后启动者 DB 锁超时崩溃且无人再
#   拉起（历史 bug：正常重启+一次软重启后 AGH 无法启动）。
# =============================================================================
mkdir -p "$AGH_DIR" "$SCRIPT_DIR" "$BIN_DIR"
device_boot "$lang" || exit 1

# 启动模块附加脚本
"$SCRIPT_DIR/iptables.sh" &
"$SCRIPT_DIR/ModuleMOD.sh" &
"$SCRIPT_DIR/NoAdsService.sh" &
"$SCRIPT_DIR/ProxyConfig.sh" &

# 执行脚本防篡改保护
find "$ADGPATH" -type f -name "*.sh" -exec chattr +i {} \;

# 日志超限时清空
[ "$(wc -c < "$MAIN_LOG")" -ge 102400 ] && : > "$MAIN_LOG"