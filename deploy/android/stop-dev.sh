#!/system/bin/sh
set -eu

APP_DIR="${PIH_APP_DIR:-/data/local/tmp/phone-image-host-dev}"
PID_PATH="$APP_DIR/server.pid"

if [ ! -f "$PID_PATH" ]; then
  echo "not running: no pid file"
  exit 0
fi

RUNNING_PID="$(cat "$PID_PATH")"
if [ -z "$RUNNING_PID" ] || ! kill -0 "$RUNNING_PID" 2>/dev/null; then
  rm -f "$PID_PATH"
  echo "not running: removed stale pid file"
  exit 0
fi

kill -TERM "$RUNNING_PID"
WAIT_COUNT=0
while kill -0 "$RUNNING_PID" 2>/dev/null && [ "$WAIT_COUNT" -lt 10 ]; do
  sleep 1
  WAIT_COUNT=$((WAIT_COUNT + 1))
done
if kill -0 "$RUNNING_PID" 2>/dev/null; then
  echo "process did not stop within 10 seconds: pid=$RUNNING_PID" >&2
  exit 1
fi
rm -f "$PID_PATH"
echo "stopped: pid=$RUNNING_PID"
