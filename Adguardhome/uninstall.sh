#!/system/bin/sh
AGH_DIR="/data/adb/agh"
ADGPATH="/data/adb/modules/AdGuardHome"
PROXY_SCRIPT="$AGH_DIR/scripts/ProxyConfig.sh"

# 按 /proc cmdline 精确杀进程（不依赖 pkill 的进程名匹配，守护脚本进程名均为 sh）
kill_by_pattern() {
    local p c
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        case "$c" in *"$1"*) kill -KILL "$p" 2>/dev/null ;; esac
    done
}

# 检查并停止运行中的进程
kill_by_pattern "/data/adb/agh/bin/AdGuardHome"
kill_by_pattern "/data/adb/agh/scripts/iptables.sh"
kill_by_pattern "/data/adb/agh/scripts/NoAdsService.sh"
kill_by_pattern "/data/adb/agh/scripts/ModuleMOD.sh"
kill_by_pattern "/data/adb/agh/scripts/ProxyConfig.sh"

# 还原代理模块修改
[ -f "$PROXY_SCRIPT" ] && "$PROXY_SCRIPT" --clean

# 解除锁定并删除残留文件
grep 'block_ad' "$AGH_DIR/scripts/NoAdsService.sh"|grep -o '".*"'|tr -d '"'|while IFS= read -r p;do [ -n "$p" ]&&[ -e "$p" ]&&find "$p" \( -type f -o -type d \) |while IFS= read -r f;do if [ -d "$f" ];then lsattr -d "$f"|grep -q "i-"&&{ chattr -i "$f";rmdir "$f";};else lsattr "$f"|grep -q "i-"&&{ chattr -i "$f";rm -f "$f";};fi;done;done

# 解除脚本防篡改保护
find "$AGH_DIR/scripts" "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \;

# 删除AGH残留目录
[ -d "$AGH_DIR" ] && rm -rf "$AGH_DIR"
[ -d "$ADGPATH" ] && rm -rf "$ADGPATH"