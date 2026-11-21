#!/bin/sh
# /var/lib/webosbrew/bin/webos-memmgr.sh
# Root backend helper for Free Memory (org.webosbrew.freemem) and Task Manager (org.webosbrew.taskmgr)

LUNA="luna-send -a org.webosbrew.hbchannel -f -n 1"

is_protected_app() {
  case "$1" in
    com.webos.app.fullhome|\
    com.webos.app.home|\
    com.webos.app.screensaver|\
    com.webos.app.livetv|\
    com.webos.app.notificationcenter|\
    com.webos.app.volume|\
    com.webos.app.voice|\
    com.webos.app.systemui|\
    com.webos.app.hdmi*|\
    com.webos.app.externalinput*|\
    org.webosbrew.freemem|\
    org.webosbrew.taskmgr)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

get_mem_kb() {
  awk -v k="$1" '$1 == k":" { print $2; exit }' /proc/meminfo
}

send_toast() {
  MSG="$1"
  # Escape double quotes
  SAFE=$(printf '%s' "$MSG" | sed 's/"/\\"/g')
  $LUNA luna://com.webos.notification/createToast "{\"sourceId\":\"org.webosbrew.hbchannel\",\"message\":\"$SAFE\"}" >/dev/null 2>&1
}

force_close_pid() {
  PID="$1"
  WPID="$2"
  if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    $LUNA luna://com.webos.applicationManager/close "{\"processId\":\"$PID\"}" >/dev/null 2>&1
    # Brief wait for graceful teardown
    usleep 350000 2>/dev/null || sleep 1
    if [ -d "/proc/$PID" ]; then
      kill -9 "$PID" 2>/dev/null || true
    fi
  fi
  if [ -n "$WPID" ] && [ "$WPID" != "$PID" ] && [ -d "/proc/$WPID" ]; then
    kill -9 "$WPID" 2>/dev/null || true
  fi
}

cmd_status() {
  TOTAL=$(get_mem_kb MemTotal)
  FREE=$(get_mem_kb MemFree)
  AVAIL=$(get_mem_kb MemAvailable)
  RUNNING=$($LUNA luna://com.webos.applicationManager/running "{}" 2>/dev/null)

  # Collect RSS for every pid mentioned in running output
  PIDS=$(printf '%s\n' "$RUNNING" | grep -oE '"(web)?processid"[[:space:]]*:[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | sort -u)
  RSS_MAP=""
  for P in $PIDS; do
    if [ -r "/proc/$P/status" ]; then
      R=$(awk '$1 == "VmRSS:" { print $2; exit }' "/proc/$P/status")
      [ -z "$R" ] && R=0
      if [ -n "$RSS_MAP" ]; then
        RSS_MAP="${RSS_MAP},\"$P\":$R"
      else
        RSS_MAP="\"$P\":$R"
      fi
    fi
  done

  [ -z "$RUNNING" ] && RUNNING='{}'
  printf '{"mem":{"totalKb":%s,"freeKb":%s,"availKb":%s},"rssKb":{%s},"running":%s}\n' \
    "${TOTAL:-0}" "${FREE:-0}" "${AVAIL:-0}" "$RSS_MAP" "$RUNNING"
}

cmd_titles() {
  $LUNA luna://com.webos.applicationManager/listLaunchPoints "{}" 2>/dev/null
}

cmd_kill() {
  PID="$1"
  WPID="$2"
  LABEL="$3"
  BEFORE=$(get_mem_kb MemAvailable)
  force_close_pid "$PID" "$WPID"
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  AFTER=$(get_mem_kb MemAvailable)
  DIFF_MB=$(( (AFTER - BEFORE) / 1024 ))
  [ "$DIFF_MB" -lt 0 ] && DIFF_MB=0

  if [ -n "$LABEL" ]; then
    if [ "$DIFF_MB" -gt 0 ]; then
      send_toast "Closed $LABEL (+${DIFF_MB} MB RAM)"
    else
      send_toast "Closed $LABEL"
    fi
  fi
  printf '{"ok":true,"pid":"%s","freedMb":%s}\n' "$PID" "$DIFF_MB"
}

cmd_clean_all() {
  BEFORE_AVAIL=$(get_mem_kb MemAvailable)
  BEFORE_FREE=$(get_mem_kb MemFree)
  RUNNING=$($LUNA luna://com.webos.applicationManager/running "{}" 2>/dev/null)

  # Parse id / processid / webprocessid pairs using awk
  PAIRS=$(printf '%s\n' "$RUNNING" | awk '
    /"id"[[:space:]]*:/ {
      gsub(/.*"id"[[:space:]]*:[[:space:]]*"/, "");
      gsub(/".*/, "");
      id = $0;
    }
    /"webprocessid"[[:space:]]*:/ {
      gsub(/.*"webprocessid"[[:space:]]*:[[:space:]]*"/, "");
      gsub(/".*/, "");
      wpid = $0;
    }
    /"processid"[[:space:]]*:/ {
      gsub(/.*"processid"[[:space:]]*:[[:space:]]*"/, "");
      gsub(/".*/, "");
      pid = $0;
      if (id != "") {
        print id "|" pid "|" wpid;
        id = ""; pid = ""; wpid = "";
      }
    }
  ')

  CLOSED=0
  for LINE in $PAIRS; do
    APP_ID=$(printf '%s' "$LINE" | cut -d'|' -f1)
    APP_PID=$(printf '%s' "$LINE" | cut -d'|' -f2)
    APP_WPID=$(printf '%s' "$LINE" | cut -d'|' -f3)
    if is_protected_app "$APP_ID"; then
      continue
    fi
    force_close_pid "$APP_PID" "$APP_WPID"
    CLOSED=$((CLOSED + 1))
  done

  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  usleep 200000 2>/dev/null || true

  AFTER_AVAIL=$(get_mem_kb MemAvailable)
  AFTER_FREE=$(get_mem_kb MemFree)
  DIFF_AVAIL_MB=$(( (AFTER_AVAIL - BEFORE_AVAIL) / 1024 ))
  DIFF_FREE_MB=$(( (AFTER_FREE - BEFORE_FREE) / 1024 ))
  [ "$DIFF_AVAIL_MB" -lt 0 ] && DIFF_AVAIL_MB=0
  [ "$DIFF_FREE_MB" -lt 0 ] && DIFF_FREE_MB=0

  FREED_MB=$DIFF_AVAIL_MB
  [ "$DIFF_FREE_MB" -gt "$FREED_MB" ] && FREED_MB=$DIFF_FREE_MB

  if [ "$CLOSED" -gt 0 ]; then
    APP_WORD="apps"
    [ "$CLOSED" -eq 1 ] && APP_WORD="app"
    send_toast "Free Memory: Closed $CLOSED $APP_WORD (+${FREED_MB} MB RAM)"
  else
    send_toast "Free Memory: Caches flushed (+${FREED_MB} MB RAM)"
  fi

  printf '{"ok":true,"closed":%s,"freedMb":%s,"availMb":%s}\n' \
    "$CLOSED" "$FREED_MB" "$((AFTER_AVAIL / 1024))"
}

case "$1" in
  status)    cmd_status ;;
  titles)    cmd_titles ;;
  kill)      cmd_kill "$2" "$3" "$4" ;;
  clean-all) cmd_clean_all ;;
  *)
    echo "Usage: $0 {status|titles|kill <pid> [wpid] [label]|clean-all}"
    exit 1
    ;;
esac
