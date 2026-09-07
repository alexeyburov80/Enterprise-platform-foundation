#!/usr/bin/env bash
set -euo pipefail
# scripts/stages/05-kong.sh
#
# Использование: ./scripts/stages/05-kong.sh --topology single

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TOPOLOGY="standard"
while [ $# -gt 0 ]; do
  case "$1" in
    --topology) TOPOLOGY="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=../lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=../lib/install-online-components.sh
source "$REPO_ROOT/scripts/lib/install-online-components.sh"

echo "── Стадия 5: Kong (topology=${TOPOLOGY}) ──"
install_kong "$REPO_ROOT" "$TOPOLOGY"

echo
echo "Готово (после того, как проверка выше пройдёт). Дальше: scripts/stages/06-monitoring.sh"
