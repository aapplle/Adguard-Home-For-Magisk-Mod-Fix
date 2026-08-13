#!/system/bin/sh
AGH_DIR="/data/adb/agh"
ADGPATH="/data/adb/modules/AdGuardHome"
PROXY_SCRIPT="$AGH_DIR/scripts/ProxyConfig.sh"

# 按脚本名子串杀进程（本机 pkill 按 /proc cmdline 匹配，实测可命中守护进程）
pkill -9 "AdGuardHome"
pkill -9 "iptables.sh"
pkill -9 "NoAdsService"
pkill -9 "ModuleMOD"
pkill -9 "ProxyConfig"

# 清理 iptables/ip6tables 规则：历史遗留 bug——卸载后 AGH 已死，但规则
# 残留会让 DNS 仍被 REDIRECT 到已死的随机端口、IPv6 DNS 被直接 DROP，
# 导致设备无网络。必须先杀守护进程再清理，避免守护循环重新拉起规则。
cleanup_iptables() {
    local i
    i=0
    while [ "$i" -lt 3 ]; do
        iptables -w 2 -t nat -D OUTPUT -j ADGUARD 2>/dev/null
        i=$((i+1))
    done
    iptables -w 2 -t nat -F ADGUARD 2>/dev/null
    iptables -w 2 -t nat -X ADGUARD 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
}
cleanup_iptables

# 还原代理模块修改
[ -f "$PROXY_SCRIPT" ] && "$PROXY_SCRIPT" --clean

# 解除锁定并删除残留文件
grep 'block_ad' "$AGH_DIR/scripts/NoAdsService.sh"|grep -o '".*"'|tr -d '"'|while IFS= read -r p;do [ -n "$p" ]&&[ -e "$p" ]&&find "$p" \( -type f -o -type d \) |while IFS= read -r f;do if [ -d "$f" ];then lsattr -d "$f"|grep -q "i-"&&{ chattr -i "$f";rmdir "$f";};else lsattr "$f"|grep -q "i-"&&{ chattr -i "$f";rm -f "$f";};fi;done;done

# 解除脚本防篡改保护
find "$AGH_DIR/scripts" "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \;

# 删除AGH残留目录
[ -d "$AGH_DIR" ] && rm -rf "$AGH_DIR"
[ -d "$ADGPATH" ] && rm -rf "$ADGPATH"