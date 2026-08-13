#!/system/bin/sh
SCRIPT_DIR="/data/adb/agh/scripts"
ADGPATH="/data/adb/modules/AdGuardHome"
MODULES_DIR="/data/adb/modules"
AGH_MODULE_PROP="$ADGPATH/module.prop"

# [MOD] 设备专属修复库（全部修复逻辑在 scripts/device_fix.sh，本文件其余
#       部分保持与上游一致，迁移时只需照抄带 [MOD] 标记的行）
. "$SCRIPT_DIR/device_fix.sh"

# 解锁脚本防篡改保护
find "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \;

# 系统语言检测
locale=$(getprop persist.sys.locale)
[ -z "$locale" ] && locale="zh"
case "$locale" in
    zh*) lang=zh ;;
    *)   lang=en ;;
esac

# 检查 hosts 模块
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
    log "[ERROR] $MSG"
    exit 1
fi

mkdir -p "$AGH_DIR" "$SCRIPT_DIR" "$BIN_DIR"

# =============================================================================
# [MOD] 设备专属启动流程（原版此处直接随机端口并启动 AGH）：
#   清理旧进程 -> 备份 YAML -> 选端口 -> 改 YAML 并回读校验 -> check-config
#   -> 启动并双重验证（进程 + 端口）-> 成功后才同步 config.prop
# =============================================================================

# 关键：先杀掉可能自动拉起 AGH 的守护脚本，再处理 AGH 本体，
# 避免 kill 与"进程丢失自动重启"互相竞争（曾出现端口绑定失败的无限重试风暴）。
# 守护脚本杀掉后可能已被再次拉起（守护循环重启机制），因此 AGH 清理后再补杀一轮：
# "第一轮杀守护 -> 杀 AGH -> 第二轮杀守护"三段式，杜绝中间窗口期被重新拉起
kill_by_pattern "$SCRIPT_DIR/iptables.sh"
kill_by_pattern "$SCRIPT_DIR/ProxyConfig.sh"
kill_by_pattern "$SCRIPT_DIR/NoAdsService.sh"
kill_by_pattern "$SCRIPT_DIR/ModuleMOD.sh"

kill_agh || exit 1

kill_by_pattern "$SCRIPT_DIR/iptables.sh"
kill_by_pattern "$SCRIPT_DIR/ProxyConfig.sh"
kill_by_pattern "$SCRIPT_DIR/NoAdsService.sh"
kill_by_pattern "$SCRIPT_DIR/ModuleMOD.sh"

[ -f "$YAML_FILE" ] || {
    log "[ERROR] AdGuardHome.yaml not found"
    exit 1
}

# 备份旧配置，启动失败时回滚
cp -f "$YAML_FILE" "$YAML_BAK"

pick_ports || {
    log "[ERROR] failed to pick free ports"
    exit 1
}

patch_yaml_ports || {
    log "[ERROR] failed to update ports in YAML, rollback"
    cp -f "$YAML_BAK" "$YAML_FILE" 2>/dev/null
    exit 1
}

# 修改后的 YAML 必须通过 AGH 自带校验
"$AGH_BIN" --check-config -c "$YAML_FILE" >> "$MAIN_LOG" 2>&1 || {
    log "[ERROR] AdGuardHome configuration check failed, rollback"
    cp -f "$YAML_BAK" "$YAML_FILE" 2>/dev/null
    exit 1
}

if start_agh; then
    # 启动成功后才同步 config.prop（只更新 redir_port，保留 adg_user 等）
    sync_redir_port "$R1"
    if [ "$lang" = "zh" ]; then
        log "AdGuardHome 启动成功，DNS端口=$R1，Web端口=$R2，PID=$AGH_PID"
    else
        log "AdGuardHome started, DNS port=$R1, Web port=$R2, PID=$AGH_PID"
    fi
else
    log "[ERROR] AdGuardHome failed to start (pid=$AGH_PID, dns_port=$R1, web_port=$R2)"
    cp -f "$YAML_BAK" "$YAML_FILE" 2>/dev/null
    exit 1
fi

# 只有 AGH 启动成功之后，才启动规则/代理守护
"$SCRIPT_DIR/iptables.sh" &
"$SCRIPT_DIR/ModuleMOD.sh" &
"$SCRIPT_DIR/NoAdsService.sh" &
"$SCRIPT_DIR/ProxyConfig.sh" &

# 执行脚本防篡改保护
find "$ADGPATH" -type f -name "*.sh" -exec chattr +i {} \;

# 日志超限时清空
[ "$(wc -c < "$MAIN_LOG")" -ge 102400 ] && : > "$MAIN_LOG"