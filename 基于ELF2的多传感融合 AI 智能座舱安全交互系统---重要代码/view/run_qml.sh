#!/bin/bash

APP_USER="elf"
APP_BIN="/opt/qml/bin/qml"
LOG_FILE="/tmp/qml.log"
GATEWAY_SCRIPT="/opt/qml/bin/guardian_gateway/server.py"
GATEWAY_LOG="/tmp/guardian_gateway.log"
IMU_CONFIG_SOURCE="/root/workspace/QT/qml/assets/config/cockpit-imu.json"
IMU_CONFIG="/opt/qml/bin/assets/config/cockpit-imu.json"
BACKLIGHT="/sys/class/backlight/backlight-dsi0/brightness"
USB_AUDIO_KEYWORD="usb-Solid_State_System"

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo /root/run_qml.sh"
  exit 1
fi

echo "[1/7] 关闭旧 qml 和守护网关进程"
pkill -9 -x qml 2>/dev/null || true
pkill -f '/opt/qml/bin/guardian_gateway/server.py' 2>/dev/null || true

echo "[2/7] 放开屏幕亮度权限"
if [ -e "$BACKLIGHT" ]; then
  chmod 666 "$BACKLIGHT" 2>/dev/null || true
fi

uid=$(id -u "$APP_USER")
runtime="/run/user/$uid"

echo "[3/7] 设置 USB 音响为默认输出"
sink=$(sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" \
  pactl list short sinks 2>/dev/null | awk -v key="$USB_AUDIO_KEYWORD" '$0 ~ key {print $2; exit}')

if [ -n "$sink" ]; then
  echo "使用输出设备: $sink"
  sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" pactl set-default-sink "$sink" 2>/dev/null || true
  sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" pactl set-sink-mute "$sink" 0 2>/dev/null || true
  sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" pactl set-sink-volume "$sink" 120% 2>/dev/null || true
else
  echo "未找到 USB 输出设备，使用系统默认输出"
fi

echo "[4/7] 设置 USB 麦克风为默认输入"
source_name=$(sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" \
  pactl list short sources 2>/dev/null | awk -v key="$USB_AUDIO_KEYWORD" '$0 ~ key && $2 !~ /monitor/ {print $2; exit}')

if [ -n "$source_name" ]; then
  echo "使用输入设备: $source_name"
  sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" pactl set-default-source "$source_name" 2>/dev/null || true
  sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" pactl set-source-mute "$source_name" 0 2>/dev/null || true
  sudo -u "$APP_USER" env XDG_RUNTIME_DIR="$runtime" pactl set-source-volume "$source_name" 100% 2>/dev/null || true
else
  echo "未找到 USB 输入设备，使用系统默认输入"
fi

echo "[5/7] 查找 XWayland 授权文件"
xauth=$(ls "$runtime"/.mutter-Xwaylandauth* 2>/dev/null | head -1)

if [ -z "$xauth" ]; then
  echo "警告：没有找到 .mutter-Xwaylandauth，仍尝试启动"
fi

if [ ! -x "$APP_BIN" ]; then
  echo "错误：找不到可执行文件 $APP_BIN"
  exit 1
fi

if [ ! -f "$GATEWAY_SCRIPT" ]; then
  echo "错误：找不到守护网关 $GATEWAY_SCRIPT"
  exit 1
fi

if [ ! -f "$IMU_CONFIG_SOURCE" ]; then
  echo "错误：找不到 IMU 配置 $IMU_CONFIG_SOURCE"
  exit 1
fi

install -D -m 644 "$IMU_CONFIG_SOURCE" "$IMU_CONFIG"

rm -f "$LOG_FILE" "$GATEWAY_LOG"

echo "[6/7] 启动平安守护网关"
sudo -u "$APP_USER" env \
  HOME="/home/$APP_USER" \
  USER="$APP_USER" \
  XDG_RUNTIME_DIR="$runtime" \
  PYTHONUNBUFFERED=1 \
  python3 "$GATEWAY_SCRIPT" >"$GATEWAY_LOG" 2>&1 < /dev/null &
gateway_pid=$!
qml_pid=""
keyboard_pid=""
terminal_state=""
cleaning_up=0
watch_for_ctrl_c() {
  local key
  while IFS= read -r -n 1 key; do
    if [ "$key" = $'\003' ]; then
      kill -TERM "$$"
      return
    fi
  done
}
cleanup_guardian() {
  if [ "$cleaning_up" -ne 0 ]; then
    return
  fi
  cleaning_up=1
  trap - INT TERM EXIT

  if [ -n "$keyboard_pid" ]; then
    kill "$keyboard_pid" 2>/dev/null || true
    wait "$keyboard_pid" 2>/dev/null || true
    keyboard_pid=""
  fi
  if [ -n "$terminal_state" ]; then
    stty "$terminal_state" 2>/dev/null || stty sane 2>/dev/null || true
    terminal_state=""
  else
    stty sane 2>/dev/null || true
  fi

  if [ -n "$qml_pid" ]; then
    kill "$qml_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$qml_pid" 2>/dev/null || true
    wait "$qml_pid" 2>/dev/null || true
  fi
  pkill -9 -x qml 2>/dev/null || true

  if [ -n "$gateway_pid" ]; then
    kill "$gateway_pid" 2>/dev/null || true
    wait "$gateway_pid" 2>/dev/null || true
  fi
  pkill -f "$GATEWAY_SCRIPT" 2>/dev/null || true
}
on_interrupt() {
  cleanup_guardian
  printf '\r\033[K\nQt 和守护网关已停止。\n'
  exit 130
}
trap cleanup_guardian EXIT
trap on_interrupt INT TERM
sleep 1
if ! kill -0 "$gateway_pid" 2>/dev/null; then
  echo "错误：守护网关启动失败，查看 $GATEWAY_LOG"
  exit 1
fi

if [ -t 0 ]; then
  terminal_state=$(stty -g 2>/dev/null || true)
  if [ -n "$terminal_state" ]; then
    stty -isig -icanon -echo min 1 time 0
    watch_for_ctrl_c < /dev/tty &
    keyboard_pid=$!
  fi
fi

echo "[7/7] 启动 Qt"
sudo -u "$APP_USER" env \
  HOME="/home/$APP_USER" \
  USER="$APP_USER" \
  XDG_RUNTIME_DIR="$runtime" \
  DISPLAY=":0" \
  XAUTHORITY="$xauth" \
  LD_LIBRARY_PATH="/opt/qml/bin" \
  COCKPIT_IMU_CONFIG="$IMU_CONFIG" \
  COCKPIT_FULLSCREEN=1 \
  "$APP_BIN" >"$LOG_FILE" 2>&1 < /dev/null &
qml_pid=$!
wait "$qml_pid" 2>/dev/null
qml_status=$?
qml_pid=""
exit "$qml_status"
