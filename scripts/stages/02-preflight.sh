#!/usr/bin/env bash
set -euo pipefail
# scripts/stages/02-preflight.sh -- passthrough к scripts/preflight.sh.
#
# Отдельный файл существует ради единообразной нумерации стадий (см.
# docs/ASTRA_LINUX.md) — сама логика проверки не дублируется, она одна
# в scripts/preflight.sh.
#
# Использование: sudo ./scripts/stages/02-preflight.sh --profile single [--offline] [--force]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "── Стадия 2: preflight ──"
"$REPO_ROOT/scripts/preflight.sh" "$@"
status=$?
echo
if [ $status -eq 0 ]; then
  echo "Готово. Дальше: sudo scripts/stages/03-k3s.sh --profile <ваш профиль>"
fi
exit $status
