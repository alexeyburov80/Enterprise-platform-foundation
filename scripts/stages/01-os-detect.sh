#!/usr/bin/env bash
set -euo pipefail
# scripts/stages/01-os-detect.sh
#
# Стадия 1 из пошаговой установки (см. docs/ASTRA_LINUX.md, раздел
# "Поэтапная установка"). Ничего не меняет в системе, только показывает,
# что определено, и честно предупреждает про Astra Linux/ЗПС.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=../lib/os-detect.sh
source "$REPO_ROOT/scripts/lib/os-detect.sh"

echo "── Стадия 1: определение ОС ──"
if os_detect; then
  echo "    ${OS_PRETTY_NAME} (id=${OS_ID}, version=${OS_VERSION})"
  os_check_support >/dev/null || true
  if [ "${OS_ID:-}" = "astra" ]; then
    os_check_astra_zps
  fi
else
  echo "    ⚠ не удалось определить ОС (см. вывод выше)" >&2
  exit 1
fi

echo
echo "Готово. Дальше: scripts/stages/02-preflight.sh --profile <ваш профиль>"
