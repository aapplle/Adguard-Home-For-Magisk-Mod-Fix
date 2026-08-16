#!/system/bin/sh
AGH_DIR="/data/adb/agh"
ADGPATH="/data/adb/modules/AdGuardHome"
PROXY_SCRIPT="$AGH_DIR/scripts/ProxyConfig.sh"

# 检查并停止运行中的进程
pkill -9 "NoAdsService"
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

# 还原代理模块修改
[ -f "$PROXY_SCRIPT" ] && "$PROXY_SCRIPT" --clean

# 解除锁定并删除残留文件
grep 'block_ad' "$AGH_DIR/scripts/NoAdsService.sh"|grep -o '".*"'|tr -d '"'|while IFS= read -r p;do [ -n "$p" ]&&[ -e "$p" ]&&find "$p" \( -type f -o -type d \) |while IFS= read -r f;do if [ -d "$f" ];then lsattr -d "$f"|grep -q "i-"&&{ chattr -i "$f";rmdir "$f";};else lsattr "$f"|grep -q "i-"&&{ chattr -i "$f";rm -f "$f";};fi;done;done

# 解除脚本防篡改保护
find "$AGH_DIR/scripts" "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \;

# 删除AGH残留目录
[ -d "$AGH_DIR" ] && rm -rf "$AGH_DIR"
[ -d "$ADGPATH" ] && rm -rf "$ADGPATH"