#!/system/bin/sh
# Open AdGuard Home Web UI via Magisk/KSU/APatch Action button.

SCRIPT_DIR="/data/adb/agh/scripts"
[ -f "$SCRIPT_DIR/common.sh" ] && . "$SCRIPT_DIR/common.sh"

if ! is_agh_running; then
    echo "AdGuardHome 当前未运行，请检查 /data/adb/agh/agh.log 与 /data/adb/agh/crash.log。"
    exit 1
fi

PORT=$(get_yaml_http_port)
if [ -z "$PORT" ]; then
    echo "无法从 $YAML_FILE 读取 Web UI 端口。"
    exit 1
fi

if [ -f "$CRED_FILE" ]; then
    echo "首次随机凭据保存在：$CRED_FILE"
fi

echo "正在打开 Web UI: http://127.0.0.1:$PORT"
am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT" >/dev/null 2>&1
