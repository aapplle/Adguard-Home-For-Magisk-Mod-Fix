#!/system/bin/sh
# ============================================================================
# device_fix.sh —— 设备专属修复库
# 本机实测问题的全部修复逻辑集中于此文件，配合 service.sh / iptables.sh
# 中带 [MOD] 标记的调用点使用。
#
# 迁移上游新版模块的流程：
#   1) 本文件整体复制保留（上游不会包含此文件，rebase/合并时永不冲突）
#   2) 对照新版 service.sh / iptables.sh，把 [MOD] 标记行照抄到新版即可，
#      设备修复逻辑本身零改动
#
# 本机实测问题清单：
#   - pgrep/pkill -x 偶尔匹配不到运行中的实例，旧实例残留导致新实例因
#     sessions.db 被占用而 timeout 崩溃 -> 改用 PID 文件 + /proc 扫描
#   - 守护循环用"进程枚举"做健康检查会误判并引发重建风暴 -> 改用"端口真相"
#   - 软重启只重启 framework，不杀 Magisk 派生的进程 -> 内置清理流程
#   - 实例启动约 1 秒后可能崩溃，仅看 kill -0 会误判 -> 进程 + 端口双重验证
#   - 随机端口可能碰撞、YAML 改动可能损坏 -> 碰撞检测 + 备份回滚 + 回读校验
# ============================================================================

AGH_DIR=/data/adb/agh
SCRIPT_DIR=$AGH_DIR/scripts
BIN_DIR=$AGH_DIR/bin
CONFIG_FILE=$SCRIPT_DIR/config.prop
PID_FILE=$AGH_DIR/agh.pid
YAML_FILE=$BIN_DIR/AdGuardHome.yaml
YAML_BAK=$AGH_DIR/AdGuardHome.yaml.bak
MAIN_LOG=$AGH_DIR/agh.log
# AGH 自身输出单独存放：AGH 长期持有其日志文件的打开 fd，
# 与 agh.log 混用会导致截断后文件以稀疏形式"清不掉"
DAEMON_LOG=$AGH_DIR/agh_daemon.log
AGH_BIN=$BIN_DIR/AdGuardHome
AGH_MATCH=$AGH_DIR/bin/AdGuardHome

log() { echo "$(date '+%F %T') $*" >> "$MAIN_LOG"; }

# 列出所有 AdGuardHome 实例的 PID（PID 文件 + /proc/PID/cmdline 扫描，
# 不依赖 pgrep/pkill 的 -x 名称匹配）
agh_pids() {
    local p c d
    {
        [ -f "$PID_FILE" ] && {
            read -r p < "$PID_FILE" 2>/dev/null
            case "$p" in
                *[!0-9]*|'') ;;
                *)
                    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
                    case "$c" in *"$AGH_MATCH"*) echo "$p" ;; esac
                    ;;
            esac
        }
        for d in /proc/[0-9]*; do
            p=${d#/proc/}
            [ "$p" = "$$" ] && continue
            c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
            case "$c" in *"$AGH_MATCH"*) echo "$p" ;; esac
        done
    } | sort -u
}

# 按 cmdline 关键字杀掉守护脚本（iptables.sh / ProxyConfig.sh / 等）
kill_by_pattern() {
    local p c d
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        { [ "$p" = "$$" ] || [ "$p" = "$PPID" ]; } && continue
        c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        case "$c" in *"$1"*) kill -KILL "$p" 2>/dev/null ;; esac
    done
}

# 先 TERM 再 KILL，直到所有实例彻底退出
kill_agh() {
    local pids i p
    pids=$(agh_pids)
    [ -z "$pids" ] && return 0
    for p in $pids; do kill -TERM "$p" 2>/dev/null; done
    i=0
    while [ "$i" -lt 10 ]; do
        pids=$(agh_pids)
        [ -z "$pids" ] && return 0
        i=$((i+1)); sleep 1
    done
    for p in $pids; do kill -KILL "$p" 2>/dev/null; done
    i=0
    while [ "$i" -lt 5 ]; do
        pids=$(agh_pids)
        [ -z "$pids" ] && return 0
        i=$((i+1)); sleep 1
    done
    log "[ERROR] old AdGuardHome process could not be killed: $pids"
    return 1
}

# 端口监听检测（朴素匹配为本机实测可用版本；AGH 监听的本地端口必然出现在
# /proc/net 中，tcp 无需额外过滤 LISTEN 状态——toybox grep 的复杂正则在本机不生效）
port_listening() {
    local proto=$1 port=$2 hex
    hex=$(printf '%04X' "$port" 2>/dev/null)
    [ -z "$hex" ] && return 1
    grep -qs ":$hex " /proc/net/$proto /proc/net/${proto}6 2>/dev/null
}

# 从 YAML 读取 DNS 监听端口（所有 port: 行统一为同一端口，取第一个即可）
yaml_dns_port() {
    sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" 2>/dev/null | head -n1
}

# 从 YAML 读取 Web 管理端口
yaml_web_port() {
    sed -n 's/^[[:space:]]*address:[[:space:]]*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" 2>/dev/null
}

# 只更新 config.prop 中的 redir_port，保留其他键
sync_redir_port() {
    if grep -q '^redir_port=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^redir_port=.*/redir_port=$1/" "$CONFIG_FILE"
    else
        printf 'redir_port=%s\n' "$1" >> "$CONFIG_FILE"
    fi
}

# 碰撞检测选端口：R1 = DNS 端口，R2 = Web 端口，避开已监听端口，5 次重试
pick_ports() {
    local i t1 t2
    R1=""
    R2=""
    i=0
    while [ "$i" -lt 5 ]; do
        t1=$((30000 + RANDOM % 35536))
        t2=$((30000 + RANDOM % 35536))
        if [ "$t1" -ne "$t2" ] && ! port_listening udp "$t1" && ! port_listening tcp "$t2"; then
            R1=$t1
            R2=$t2
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

# 修改 YAML 全部 port: 行与 address 端口，保留原行缩进（强制改缩进会破坏
# go-yaml 结构导致启动失败），随后回读校验，失败返回 1（由调用方负责回滚备份）
patch_yaml_ports() {
    [ -n "$R1" ] && [ -n "$R2" ] || return 1
    sed -i \
        "s/^\([[:space:]]*\)port:[[:space:]]*[0-9][0-9]*/\1port: $R1/; \
         s/^\([[:space:]]*address:[[:space:]]*127\.0\.0\.1:\)[0-9][0-9]*/\1$R2/" \
        "$YAML_FILE" || return 1
    [ "$(sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" | sort -u | wc -l)" -eq 1 ] || return 1
    [ "$(sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" | sort -u)" = "$R1" ] || return 1
    [ "$(sed -n 's/^[[:space:]]*address:[[:space:]]*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$YAML_FILE")" = "$R2" ] || return 1
    return 0
}

# 启动 AGH 并验证：进程存活 且 DNS(UDP) 与 Web(TCP) 端口真实监听（最长 12 秒）。
# 仅看 kill -0 会误判"启动成功"（曾出现约 1 秒后因 DB 锁崩溃的实例）。
# 成功后导出 AGH_PID。
start_agh() {
    local i
    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    # 每次启动清空一次守护日志（AGH 输出与模块日志分离，截断互不影响）
    : > "$DAEMON_LOG" 2>/dev/null
    "$AGH_BIN" -c "$YAML_FILE" --no-check-update >> "$DAEMON_LOG" 2>&1 &
    AGH_PID=$!
    echo "$AGH_PID" > "$PID_FILE"
    i=0
    while [ "$i" -lt 12 ]; do
        sleep 1
        i=$((i+1))
        kill -0 "$AGH_PID" 2>/dev/null || break
        if port_listening udp "$R1" && port_listening tcp "$R2"; then
            return 0
        fi
    done
    kill -KILL "$AGH_PID" 2>/dev/null
    log "[ERROR] verify failed: pid=$AGH_PID alive=$(kill -0 "$AGH_PID" 2>/dev/null && echo YES || echo NO) udp:$R1=$(port_listening udp "$R1" && echo YES || echo NO) tcp:$R2=$(port_listening tcp "$R2" && echo YES || echo NO)"
    return 1
}

# 健康守护：以"端口真相"为准——YAML 指定的 DNS 端口正在监听即视为实例
# 健康（不依赖进程枚举，曾出现实例正常运行却被枚举误判而重建、新实例被
# sessions.db 锁挡死的现象）。端口与 config.prop 不一致时只做同步，不重建。
# 实例缺失或端口不一致时才重建。
ensure_agh() {
    local dport pids i
    dport=$(yaml_dns_port)
    [ -n "$dport" ] || dport=$redir_port
    if [ -n "$dport" ] && port_listening udp "$dport"; then
        [ "$redir_port" != "$dport" ] && sync_redir_port "$dport"
        return 0
    fi
    log "AdGuardHome 实例缺失或端口不一致，正在重建..."
    pids=$(agh_pids)
    for p in $pids; do kill -KILL "$p" 2>/dev/null; done
    sleep 1
    [ -n "$dport" ] || return 1
    if port_listening udp "$dport"; then
        # 仍有存活实例占用端口（如枚举漏掉），放弃本轮重建避免再被 DB 锁挡死
        log "port $dport still in use, skip rebuild"
        return 1
    fi
    sync_redir_port "$dport"
    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    : > "$DAEMON_LOG" 2>/dev/null
    "$AGH_BIN" -c "$YAML_FILE" --no-check-update >> "$DAEMON_LOG" 2>&1 &
    echo $! > "$PID_FILE"
    i=0
    while [ "$i" -lt 8 ] && ! port_listening udp "$dport"; do
        sleep 1
        i=$((i+1))
    done
}