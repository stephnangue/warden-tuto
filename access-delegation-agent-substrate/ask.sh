ask() { # <agent> "<prompt>" as "<person's token>"
  local port
  case "$1" in
    claude-alice) port=8001 ;;
    claude-bob)   port=8002 ;;
    *) echo "unknown agent: $1 (claude-alice or claude-bob)" >&2; return 1 ;;
  esac
  if [ $# -ne 4 ] || [ "$3" != as ] || [ -z "$4" ]; then
    echo 'usage: ask <agent> "<prompt>" as "$TOKEN"' >&2; return 1
  fi
  curl -s --max-time 600 "localhost:$port/prompt" -H "X-User-Token: $4" -d "$2"; echo
  kubectl ate suspend actor "$1" -a claude-agents >/dev/null 2>&1
}
