#!/system/bin/sh
AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
YAML_FILE="$BIN_DIR/AdGuardHome.yaml"

echo "等待 1 秒..."
sleep 1

# 获取当前 Web UI 端口
PORT=$(sed -n 's/^[[:space:]]*address:[[:space:]]*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" | head -n 1)

if [ -z "$PORT" ]; then
    echo "无法从 AdGuardHome.yaml 获取 Web UI 端口。"
    exit 1
fi

echo "正在打开浏览器 (端口 $PORT)..."
am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT"
