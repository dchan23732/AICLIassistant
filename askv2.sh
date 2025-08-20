#!/bin/sh
set -eu
umask 022

# Configure the host/port of your orchestrator
HOST="${HOST_ORCH:-192.168.0.52}"
PORT="${HOST_PORT:-8081}"

# Ensure /usr/local/bin exists (UserLAnd usually has this)
mkdir -p /usr/local/bin

###############################################################################
# /usr/local/bin/ask
###############################################################################
cat >/usr/local/bin/ask <<'EOF'
#!/bin/sh
set -eu

HOST="${HOST_ORCH:-192.168.122.1}"
PORT="${HOST_PORT:-8081}"

if [ $# -eq 0 ]; then
  echo 'Usage: ask "what you want to do"'
  echo '       ask code --lang python --out ~/Documents/hello.py -- "Print Hello World"'
  exit 1
fi

# Small parser for a "code" subcommand:
if [ "$1" = "code" ]; then
  shift
  LANG=""
  OUT=""
  # parse flags until we hit "--"
  while [ $# -gt 0 ]; do
    case "$1" in
      --lang)
        [ $# -ge 2 ] || { echo "Missing value for --lang" >&2; exit 2; }
        LANG="$2"; shift 2;;
      --out)
        [ $# -ge 2 ] || { echo "Missing value for --out" >&2; exit 2; }
        OUT="$2"; shift 2;;
      --)
        shift; break;;
      *)
        break;;
    esac
  done

  DESC="${*:-}"
  if [ -z "$DESC" ]; then
    echo "Provide a description after --" >&2
    exit 2
  fi
  if [ -z "$OUT" ]; then
    echo "Provide an output path with --out <file>" >&2
    exit 2
  fi

  # Resolve OUT to an absolute path
  # shellcheck disable=SC2164
  OUT_ABS="$OUT"
  case "$OUT_ABS" in
    /*) : ;;
    ~/*) OUT_ABS="$HOME/${OUT_ABS#~/}" ;;
    *) OUT_ABS="$(pwd)/$OUT_ABS" ;;
  esac
  OUT_DIR=$(dirname "$OUT_ABS")
  mkdir -p "$OUT_DIR"

  # Call your /code endpoint; expects raw code in response
  URL="http://$HOST:$PORT/code"
  # We URL-encode each field cleanly; NO stray ellipses!
  RESP="$(curl -sG \
    --data-urlencode "path=$OUT_ABS" \
    --data-urlencode "q=$DESC" \
    --data-urlencode "lang=$LANG" \
    "$URL" || true)"

  if [ -z "$RESP" ]; then
    echo "No response from code service" >&2
    exit 3
  fi

  printf '%s' "$RESP" >"$OUT_ABS"
  chmod +x "$OUT_ABS" 2>/dev/null || true
  echo "Wrote: $OUT_ABS"
  exit 0
fi

# Default path: freeform NL → command
ARGS="$*"
URL="http://$HOST:$PORT/nl"
CMD="$(curl -sG --data-urlencode "q=$ARGS" "$URL" || true)"
if [ -z "$CMD" ]; then
  echo "No command returned." >&2
  exit 4
fi

echo "Proposed: $CMD"
# Simple confirmation prompt
printf "Run it? [y/N] "
read ans
case "$ans" in
  y|Y|yes|YES)
    # shellcheck disable=SC2086
    sh -c "$CMD"
    ;;
  *)
    echo "Aborted."
    ;;
esac
EOF
chmod 0755 /usr/local/bin/ask

###############################################################################
# /usr/local/bin/agent-loop
###############################################################################
cat >/usr/local/bin/agent-loop <<'EOF'
#!/bin/sh
set -eu

HOST="${HOST_ORCH:-192.168.122.1}"
PORT="${HOST_PORT:-8081}"

echo "Starting agent loop against http://$HOST:$PORT/loop"
while :; do
  # Expect your orchestrator to return a single shell command to run,
  # or an empty string if idle. Adjust to your API contract as needed.
  CMD="$(curl -s "http://$HOST:$PORT/loop" || true)"
  if [ -n "$CMD" ]; then
    echo ">> $CMD"
    # shellcheck disable=SC2086
    sh -c "$CMD" || true
  fi
  sleep 2
done
EOF
chmod 0755 /usr/local/bin/agent-loop

###############################################################################
# Optional systemd unit (skipped on UserLAnd / no systemd)
###############################################################################
if command -v systemctl >/dev/null 2>&1; then
  cat >/etc/systemd/system/agent-loop.service <<'EOF'
[Unit]
Description=Agent loop
After=network.target

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
else
  echo "No systemd detected; skipping unit install. Run 'agent-loop' manually when needed."
fi

echo "Installed /usr/local/bin/ask and /usr/local/bin/agent-loop"
