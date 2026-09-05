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
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi

  # Баг, найденный реальным прогоном (не в песочнице): раньше здесь был
  # просто `exit 1` с инструкцией поставить yq вручную. Из-за классической
  # ловушки bash — `var="$(func)"` под `set -e` роняет весь ВЫЗЫВАЮЩИЙ
  # скрипт молча, без единого PASS/FAIL в отчёте preflight, — это выглядело
  # как необъяснимый мгновенный краш сразу после определения ОС, а не как
  # понятная ошибка "нужен yq". Теперь вместо ручной установки — автоматическая:
  # yq нужен только как локальный инструмент чтения release/manifest.yaml,
  # ставить его руками каждому, кто клонирует репозиторий, не должно быть
  # обязательным шагом онбординга.
  echo "yq не найден — устанавливаю (одна из немногих вещей в этом репозитории," >&2
  echo "которая тянется по фиксированной версии, но не из release/manifest.yaml —" >&2
  echo "у самого yq нет способа прочитать версию yq для самого себя)." >&2

  local yq_version="v4.44.3"   # тот же пин, что и tooling.yq.version в release/manifest.yaml —
                                 # продублирован здесь намеренно (см. комментарий выше)
  local yq_url="https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_amd64"
  local dest="/usr/local/bin/yq"

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl тоже не найден — не могу автоматически поставить yq." >&2
    echo "Поставьте вручную: $yq_url -> $dest (chmod +x), затем повторите запуск." >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL --max-time 15 "$yq_url" -o "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "Не удалось скачать yq с $yq_url (нет интернета? см. --offline в docs/AIRGAP.md" >&2
    echo "про то, что yq на офлайн-сервере должен быть предустановлен заранее)." >&2
    echo "Поставьте вручную: $yq_url -> $dest (chmod +x), затем повторите запуск." >&2
    return 1
  fi

  chmod +x "$tmp"
  if [ -w "$(dirname "$dest")" ]; then
    mv "$tmp" "$dest"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mv "$tmp" "$dest"
  else
    echo "Скачал yq во временный файл $tmp, но нет прав записать в $dest и нет sudo." >&2
    echo "Переместите вручную: sudo mv $tmp $dest && sudo chmod +x $dest" >&2
    return 1
  fi

  if ! command -v yq >/dev/null 2>&1; then
    echo "yq скачан в $dest, но почему-то всё ещё не находится в PATH — проверьте \$PATH." >&2
    return 1
  fi
  echo "yq ${yq_version} установлен в $dest." >&2
  return 0
}

manifest_get() {
  local query="$1"
  if ! manifest_require_yq; then
    return 1
  fi
  if [ ! -f "$MANIFEST_FILE" ]; then
    echo "release/manifest.yaml не найден по пути: $MANIFEST_FILE" >&2
    return 1
  fi
  local value
  value="$(yq eval "$query" "$MANIFEST_FILE")"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "Поле '$query' не найдено или пустое в $MANIFEST_FILE" >&2
    return 1
  fi
  echo "$value"
}
