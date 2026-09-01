#!/usr/bin/env bash
# scripts/lib/manifest.sh
#
# Общий хелпер: читает release/manifest.yaml, чтобы ни один скрипт в репозитории
# не хардкодил версию компонента и не использовал "latest" (см. Phase 1 аудит, C1/C2/C5).
#
# Использование:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/manifest.sh"
#   RABBITMQ_OPERATOR_VERSION="$(manifest_get '.operators.rabbitmq_cluster_operator.version')"

# Путь к manifest.yaml вычисляется относительно этого файла, а не относительно CWD —
# так source работает одинаково независимо от того, откуда вызван скрипт.
MANIFEST_FILE="${MANIFEST_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/release/manifest.yaml}"

manifest_require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "Нужен yq (mikefarah/yq, версия 4.x) для чтения release/manifest.yaml." >&2
    echo "Установка: см. https://github.com/mikefarah/yq#install — например:" >&2
    echo "    sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq" >&2
    echo "(Да, здесь тоже 'latest' — но это одноразовая установка локального инструмента" >&2
    echo "оператором вручную, а не то, что тянет сам installer при каждом запуске.)" >&2
    exit 1
  fi
}

manifest_get() {
  local query="$1"
  manifest_require_yq
  if [ ! -f "$MANIFEST_FILE" ]; then
    echo "release/manifest.yaml не найден по пути: $MANIFEST_FILE" >&2
    exit 1
  fi
  local value
  value="$(yq eval "$query" "$MANIFEST_FILE")"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "Поле '$query' не найдено или пустое в $MANIFEST_FILE" >&2
    exit 1
  fi
  echo "$value"
}
