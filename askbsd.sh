#!/bin/sh
set -eu
umask 022

# Configure the host/port of your orchestrator
HOST="${HOST_ORCH:-192.168.122.1}"
PORT="${HOST_PORT:-8081}"

# Ensure /usr/local/bin exists (FreeBSD standard path)
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

  # Call orchestrator /code; server writes the file and returns a JSON summary
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
  echo "$RESP"
  exit 0
fi

# Default path: prefer autonomous action on FreeBSD
ARGS="$*"
URL="http://$HOST:$PORT/act"
RESP="$(curl -sG --data-urlencode "q=$ARGS" "$URL" || true)"
echo "$RESP"
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

echo "Starting agent loop against http://$HOST:$PORT/next"
while :; do
  resp="
$(pull_next)"
  [ -z "$resp" ] && sleep 2 && continue
  id=$(printf "%s\n" "$resp" | sed -n 's/^id:\(.*\)$/\1/p' | head -n1)
  b64=$(printf "%s\n" "$resp" | sed -n 's/^cmd_b64:\(.*\)$/\1/p' | head -n1)
  [ -z "$id" ] && sleep 1 && continue
  [ -z "$b64" ] && sleep 1 && continue
  cmd=$(printf "%s" "$b64" | base64 -d 2>/dev/null || printf "")
  [ -z "$cmd" ] && sleep 1 && continue
  tmpout=$(mktemp) || tmpout=/tmp/agent-out.$$ 
  tmperr=$(mktemp) || tmperr=/tmp/agent-err.$$ 
  sh -c "$cmd" >"$tmpout" 2>"$tmperr"; code=$?
  out=$(cat "$tmpout" 2>/dev/null || true)
  err=$(cat "$tmperr" 2>/dev/null || true)
  rm -f "$tmpout" "$tmperr"
  post_result "$id" "$code" "$out" "$err"
  sleep 1
done
EOF
chmod 0755 /usr/local/bin/agent-loop

###############################################################################
# FreeBSD rc.d service (standard FreeBSD init system)
###############################################################################
# FreeBSD rc.d service
if command -v sysrc >/dev/null 2>&1; then
  cat >/usr/local/etc/rc.d/agent_loop <<'EOF'
#!/bin/sh
# PROVIDE: agent_loop
# REQUIRE: DAEMON NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name=agent_loop
rcvar=agent_loop_enable
command=/usr/local/bin/agent-loop
pidfile=/var/run/${name}.pid

load_rc_config $name
: ${agent_loop_enable:=NO}

run_rc_command "$1"
EOF
  chmod 0755 /usr/local/etc/rc.d/agent_loop
  sysrc -q agent_loop_enable=YES || true
  service agent_loop restart || service agent_loop start || true
else
  echo "sysrc not found; skipping rc.d install. Run 'agent-loop' manually when needed."
fi

echo "FreeBSD orchestrator agent installed successfully!"
echo "Installed /usr/local/bin/ask and /usr/local/bin/agent-loop"
echo "Service can be managed with: service agent_loop start/stop/status"
echo "Enable on boot with: sysrc agent_loop_enable=YES"

