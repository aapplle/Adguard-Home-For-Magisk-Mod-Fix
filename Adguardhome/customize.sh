#!/system/bin/sh
# shellcheck disable=SC2154
SKIPUNZIP=1

# Locale detection
locale=$(getprop persist.sys.locale 2>/dev/null | tr '[:upper:]' '[:lower:]')
[ -z "$locale" ] && locale="zh"
case "$locale" in
    en*) language="en" ;;
    *)   language="zh" ;;
esac

i18n_print() {
    if [ "$language" = "zh" ]; then
        ui_print "$2"
    else
        ui_print "$1"
    fi
}

AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
SCRIPT_DIR="$AGH_DIR/scripts"
BACKUP_DIR="$AGH_DIR/backup"
USERFILTER_DIR="$BIN_DIR/data/userfilters"
ADGPATH="/data/adb/modules/AdGuardHome"
CRED_FILE="$AGH_DIR/initial_credentials.txt"

# 1. Warn on Hosts modules without silently deleting user modules
i18n_print "- Checking for conflicting Hosts modules" "- 正在检测 Hosts 类冲突模块"
found_hosts=0
for module in /data/adb/modules/*; do
    [ -d "$module" ] || continue
    [ -f "$module/disable" ] && continue
    [ -f "$module/remove" ] && continue
    if [ -f "$module/system/etc/hosts" ] && [ -f "$module/module.prop" ]; then
        if [ "$found_hosts" -eq 0 ]; then
            i18n_print "! Warning: active Hosts module(s) detected (not auto-removed):" "! 警告：检测到启用的 Hosts 模块（不会自动删除，建议自行禁用以避免冲突）："
            found_hosts=1
        fi
        ui_print "  - $(grep_prop name "$module/module.prop")"
    fi
done

# 2. Extract core Magisk module lifecycle files
i18n_print "- Extracting basic module files" "- 正在解压模块基本文件"
for file in uninstall.sh module.prop service.sh action.sh; do
    unzip -o "$ZIPFILE" "$file" -d "$MODPATH" >/dev/null
done

# 3. Gracefully stop running processes with bounded retries (mksh NUL-safe)
if [ -d "$AGH_DIR" ]; then
    i18n_print "- Stopping existing AdGuardHome and module processes" "- 正在停止现有 AdGuardHome 及模块进程"
    _attempt=0
    while [ "$_attempt" -lt 5 ]; do
        _found=0
        _sig="TERM"
        [ "$_attempt" -ge 3 ] && _sig="KILL"
        for _p in /proc/[0-9]*; do
            [ -r "$_p/cmdline" ] || continue
            _cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
            case "$_cmd" in
                "$BIN_DIR/AdGuardHome"*|*"$SCRIPT_DIR/"*)
                    kill "-$_sig" "${_p#/proc/}" 2>/dev/null
                    _found=1
                    ;;
            esac
        done
        [ "$_found" -eq 0 ] && break
        _attempt=$((_attempt + 1))
        sleep 1
    done
fi

# 4. Unlock any legacy chattr +i flags (from earlier upstream releases)
for _dir in "$SCRIPT_DIR" "$ADGPATH"; do
    [ -d "$_dir" ] && find "$_dir" -type f -name "*.sh" -exec chattr -i {} \; 2>/dev/null
done
for _legacy in "/data/system/ifw" "/data/system/cube" "/data/data/com.galaxy.stock/files"; do
    [ -e "$_legacy" ] && chattr -R -i "$_legacy" 2>/dev/null
done

# 5. Back up existing user configuration before upgrade
IS_UPGRADE=0
if [ -f "$BIN_DIR/AdGuardHome.yaml" ]; then
    IS_UPGRADE=1
    i18n_print "- Backing up existing user configuration" "- 正在备份现有用户配置"
    mkdir -p "$BACKUP_DIR"
    cp -f "$BIN_DIR/AdGuardHome.yaml" "$BACKUP_DIR/AdGuardHome.yaml"
    [ -f "$SCRIPT_DIR/config.prop" ] && cp -f "$SCRIPT_DIR/config.prop" "$BACKUP_DIR/config.prop"
fi

# 6. Clean obsolete script residues (preserve user data/querylog/stats)
rm -rf "$AGH_DIR/ifw" "$SCRIPT_DIR" "$BIN_DIR/agh_pid"
mkdir -p "$AGH_DIR" "$BIN_DIR" "$SCRIPT_DIR" "$BACKUP_DIR" "$USERFILTER_DIR" "$AGH_DIR/run"

# 7. Extract scripts and binaries
i18n_print "- Extracting scripts and AdGuardHome core" "- 正在解压脚本与 AdGuardHome 核心"
unzip -o "$ZIPFILE" "scripts/*" -d "$AGH_DIR" >/dev/null

if [ "$IS_UPGRADE" -eq 1 ]; then
    # Upgrade: update binary, built-in rule list, and pre-bundled filters while preserving user YAML
    unzip -o "$ZIPFILE" "bin/AdGuardHome" -d "$AGH_DIR" >/dev/null
    unzip -o "$ZIPFILE" "bin/data/userfilters/*" -d "$AGH_DIR" >/dev/null
    unzip -o "$ZIPFILE" "bin/data/filters/*" -d "$AGH_DIR" >/dev/null
    i18n_print "- Preserved existing AdGuardHome.yaml (password, upstreams, user_rules)" "- 已保留原有 AdGuardHome.yaml（密码、上游 DNS 与自定义规则）"
else
    # Fresh install: extract full bin/ including initial AdGuardHome.yaml
    unzip -o "$ZIPFILE" "bin/*" -d "$AGH_DIR" >/dev/null
fi

# 8. Merge preserved config.prop settings safely
if [ -f "$BACKUP_DIR/config.prop" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|'#'*) continue ;;
            watch_interval=*|enable_noads=*|enable_proxy_sync=*|disable_private_dns=*|disable_tfo=*|allow_airplane_refresh=*|PROXY_URL=*)
                _k=${_line%%=*}
                _v=${_line#*=}
                # Skip legacy single-space placeholder PROXY_URL=" "
                if [ "$_k" = "PROXY_URL" ] && [ "$_v" = '" "' ]; then
                    continue
                fi
                sed -i "/^${_k}=/d" "$SCRIPT_DIR/config.prop"
                printf '%s=%s\n' "$_k" "$_v" >> "$SCRIPT_DIR/config.prop"
                ;;
        esac
    done < "$BACKUP_DIR/config.prop"
    i18n_print "- Preserved user settings in config.prop" "- 已保留 config.prop 用户配置"
fi

# 9. Set secure permissions (no chattr +i on module scripts)
i18n_print "- Setting file permissions" "- 正在设置文件权限"
find "$AGH_DIR" -type d -exec chmod 0700 {} \;
chmod 0700 "$BIN_DIR/AdGuardHome"
chmod 0700 "$SCRIPT_DIR"/*.sh
chmod 0600 "$SCRIPT_DIR/config.prop" "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null

# 10. Generate a unique random per-device Web UI password on fresh install
if [ "$IS_UPGRADE" -eq 0 ] && [ -x "$BIN_DIR/AdGuardHome" ]; then
    _rand_pw=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)
    if [ -n "$_rand_pw" ]; then
        _hash=$(printf '%s\n' "$_rand_pw" | "$BIN_DIR/AdGuardHome" --hash-password 2>/dev/null)
        case "$_hash" in
            # shellcheck disable=SC2016
            '$2'*)
                _esc_hash=$(printf '%s' "$_hash" | sed 's/[\\&|]/\\&/g')
                sed -i "s|^\([[:space:]]*password:\).*|\1 ${_esc_hash}|" "$BIN_DIR/AdGuardHome.yaml"
                {
                    printf 'username=admin\n'
                    printf 'password=%s\n' "$_rand_pw"
                } > "$CRED_FILE"
                chmod 0600 "$CRED_FILE"
                i18n_print "- Generated unique Web UI password (saved to $CRED_FILE):" "- 已生成本机独立管理密码（保存在 $CRED_FILE）："
                ui_print "  admin / $_rand_pw"
                ;;
            *)
                i18n_print "! Notice: change the default Web UI password immediately after first login." "! 提示：首次登录后请立即在 Web UI 修改默认密码。"
                ;;
        esac
    fi
fi

i18n_print "- Installation complete. Please reboot." "- 安装完成，请重启设备。"
