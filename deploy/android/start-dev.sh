#!/system/bin/sh
set -eu

APP_DIR="${PIH_APP_DIR:-/data/local/tmp/phone-image-host-dev}"
BIN_PATH="$APP_DIR/phone-image-host"
TOKENS_PATH="$APP_DIR/tokens.json"
DATA_DIR="$APP_DIR/data"
PID_PATH="$APP_DIR/server.pid"
LOG_PATH="$APP_DIR/server.log"
LISTEN_ADDR="${PIH_ADDR:-0.0.0.0:8080}"

if [ ! -x "$BIN_PATH" ]; then
  echo "missing executable: $BIN_PATH" >&2
  exit 1
fi
if [ ! -r "$TOKENS_PATH" ]; then
  echo "missing token configuration: $TOKENS_PATH" >&2
  exit 1
fi

if [ -f "$PID_PATH" ]; then
  EXISTING_PID="$(cat "$PID_PATH")"
  if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "already running: pid=$EXISTING_PID"
    exit 0
  fi
fi

umask 077
mkdir -p "$DATA_DIR"
PIH_TOKENS_FILE="$TOKENS_PATH" \
PIH_COOKIE_SECURE=false \
PIH_DATA_DIR="$DATA_DIR" \
PIH_ADDR="$LISTEN_ADDR" \
nohup "$BIN_PATH" >>"$LOG_PATH" 2>&1 </dev/null &
STARTED_PID=$!
echo "$STARTED_PID" >"$PID_PATH"

sleep 1
if ! kill -0 "$STARTED_PID" 2>/dev/null; then
  echo "backend failed to start; inspect $LOG_PATH" >&2
  exit 1
fi
echo "started: pid=$STARTED_PID addr=$LISTEN_ADDR"
