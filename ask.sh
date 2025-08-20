#!/bin/sh
set -eu
umask 022

HOST="${HOST_ORCH:-192.168.122.1}"
PORT="${HOST_PORT:-8081}"

cat >/usr/local/bin/ask <<'EOF'
#!/bin/sh
HOST="${HOST_ORCH:-192.168.122.1}"
PORT="${HOST_PORT:-8081}"

if [ $# -eq 0 ]; then
  echo 'Usage: ask "what you want to do"'
  exit 1
fi

ARGS="$*"

# Try to detect code-generation: "edit <path> ..." or "write <path> ..." or "create <path> ..."
set -- $ARGS
OP="$1"; PATH_CAND="$2"
case "$OP" in
  edit|write|create)
    # If second token looks like a filename with an extension, route to /code
    if printf "%s" "$PATH_CAND" | grep -Eq '\\.[A-Za-z0-9]+$'; then
      DESC="$(printf "%s" "$ARGS" | sed -e "s/^$OP[[:space:]]\+$PATH_CAND[[:space:]]\?//")"
      # Normalize path to absolute (expand ~ and relative paths) using the caller's environment
      if printf "%s" "$PATH_CAND" | grep -qE '^~(/|$)'; then
        FILE_ABS="$(eval echo "$PATH_CAND")"
      elif printf "%s" "$PATH_CAND" | grep -qE '^/'; then
        FILE_ABS="$PATH_CAND"
      else
        FILE_ABS="$PWD/$PATH_CAND"
      fi
      # Guess language from extension
      EXT="$(printf "%s" "$FILE_ABS" | sed -n 's/^.*\.\([A-Za-z0-9]\+\)$/\1/p' | tr 'A-Z' 'a-z')"
      case "$EXT" in
        sh|bash) LANG=sh ;;
        py) LANG=python ;;
        js|jsx) LANG=javascript ;;
        ts|tsx) LANG=typescript ;;
        json) LANG=json ;;
        service|socket|timer) LANG=ini ;;
        desktop|ini) LANG=ini ;;
        *) LANG="" ;;
      esac
      URL="http://$HOST:$PORT/code"
      RESP="$(curl -sG --data-urlencode "path=$FILE_ABS" --data-urlencode "q=$DESC" --data-urlencode "lang=$LANG" "$URL" || true)"
      echo "$RESP"
      exit 0
    fi
    ;;
esac

# Fallback to NL→single command
CMD="$(curl -sG --data-urlencode "q=$ARGS" "http://$HOST:$PORT/nl" || true)"
if [ -n "$CMD" ]; then
  echo "Proposed: $CMD"
  # If the proposed command is a here-doc without body, switch to /code with the original ARGS
  if printf "%s" "$CMD" | grep -q "cat <<'EOF'"; then
    TARGET="$(printf "%s" "$CMD" | sed -nE "s/.*> *'?([^' ]+)'?.*/\1/p" | head -n1)"
    if [ -n "$TARGET" ]; then
      # Normalize to absolute path under the invoking user
      if printf "%s" "$TARGET" | grep -qE '^~(/|$)'; then
        FILE_ABS="$(eval echo "$TARGET")"
      elif printf "%s" "$TARGET" | grep -qE '^/'; then
        FILE_ABS="$TARGET"
      else
        FILE_ABS="$PWD/$TARGET"
      fi
      EXT="$(printf "%s" "$FILE_ABS" | sed -n 's/^.*\.\([A-Za-z0-9]\{1,16\}\)$/\1/p' | tr 'A-Z' 'a-z')"
      case "$EXT" in
        sh|bash) LANG=sh ;;
        py) LANG=python ;;
        js|jsx) LANG=javascript ;;
        ts|tsx) LANG=typescript ;;
        json) LANG=json ;;
        service|socket|timer|desktop|ini) LANG=ini ;;
        *) LANG="" ;;
      esac
      RESP="$(curl -sG --data-urlencode "path=$FILE_ABS" --data-urlencode "q=$ARGS" --data-urlencode "lang=$LANG" "http://$HOST:$PORT/code" || true)"
      echo "$RESP"
      exit 0
    fi
  fi
  sh -c "$CMD"
fi
EOF
chmod 755 /usr/local/bin/ask
sed -i 's/\r$//' /usr/local/bin/ask || true

# Install a lightweight VM agent loop to pull jobs and report results
cat >/usr/local/bin/agent-loop <<'EOF'
#!/bin/sh
set -u
HOST="${HOST_ORCH:-192.168.122.1}"
PORT="${HOST_PORT:-8081}"

pull_next() {
  curl -sf "http://$HOST:$PORT/next?fmt=b64" || true
}

post_result() {
  id="$1"; code="$2"; out="$3"; err="$4"
  out_b64=$(printf "%s" "$out" | base64 | tr -d '\n')
  err_b64=$(printf "%s" "$err" | base64 | tr -d '\n')
  curl -sf -X POST "http://$HOST:$PORT/result" \
    -d "id=$id" -d "code=$code" -d "out_b64=$out_b64" -d "err_b64=$err_b64" >/dev/null || true
}

while :; do
  resp="$(pull_next)"
  if [ -z "$resp" ]; then
    sleep 1
    continue
  fi
  id=$(printf "%s\n" "$resp" | sed -n 's/^id:\(.*\)$/\1/p' | head -n1)
  b64=$(printf "%s\n" "$resp" | sed -n 's/^cmd_b64:\(.*\)$/\1/p' | head -n1)
  [ -z "$id" ] && sleep 1 && continue
  [ -z "$b64" ] && sleep 1 && continue
  cmd=$(printf "%s" "$b64" | base64 -d 2>/dev/null || printf "")
  if [ -z "$cmd" ]; then
    sleep 1
    continue
  fi
  tmpout=$(mktemp) || tmpout=/tmp/agent-out.$$ 
  tmperr=$(mktemp) || tmperr=/tmp/agent-err.$$ 
  sh -c "$cmd" >"$tmpout" 2>"$tmperr"; code=$?
  out=$(cat "$tmpout" 2>/dev/null || true)
  err=$(cat "$tmperr" 2>/dev/null || true)
  rm -f "$tmpout" "$tmperr"
  post_result "$id" "$code" "$out" "$err"
done
EOF
chmod 755 /usr/local/bin/agent-loop
sed -i 's/\r$//' /usr/local/bin/agent-loop || true

if command -v systemctl >/dev/null 2>&1; then
  cat >/etc/systemd/system/agent-loop.service <<'EOF'
[Unit]
Description=VM Agent Loop
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/agent-loop
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  systemctl enable --now agent-loop.service || true
fi

echo "Installed /usr/local/bin/ask and /usr/local/bin/agent-loop"