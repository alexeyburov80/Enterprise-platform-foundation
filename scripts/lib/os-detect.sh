#!/usr/bin/env bash
# scripts/lib/os-detect.sh
#
# Определяет ОС хоста и сверяет её с матрицей поддержки в release/manifest.yaml
# (Phase 1 аудит, находка C4: раньше в репозитории не было НИ ОДНОЙ проверки ОС —
# Astra Linux нигде не упоминалась).
#
# Использование:
#   source scripts/lib/os-detect.sh
#   os_detect          # заполняет переменные OS_ID / OS_VERSION / OS_PRETTY_NAME
#   os_check_support    # сверяет с release/manifest.yaml, печатает предупреждение
#                       # если verified: false или ОС не найдена в списке вовсе
#
# Намеренно НЕ считает "не найдено в manifest" фатальной ошибкой сама по себе —
# решение "продолжать или нет" принимает preflight.sh/bootstrap.sh (через --force),
# этот файл только определяет факты и печатает их.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_FOR_OS_DETECT="$(cd "$SCRIPT_LIB_DIR/../.." && pwd)"

# shellcheck source=manifest.sh
source "$SCRIPT_LIB_DIR/manifest.sh"

os_detect() {
  if [ ! -r /etc/os-release ]; then
    echo "Не удалось прочитать /etc/os-release — это точно Linux-хост?" >&2
    return 1
  fi

  # Подгружаем в подоболочке и переносим только нужные поля — чтобы не
  # затирать переменные окружения скрипта переменными вида NAME/VERSION,
  # которые /etc/os-release определяет под теми же именами.
  local os_id os_version os_pretty os_id_like
  os_id="$(. /etc/os-release && echo "${ID:-unknown}")"
  os_version="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"
  os_pretty="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
  os_id_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"

  OS_ID="$os_id"
  OS_VERSION="$os_version"
  OS_PRETTY_NAME="$os_pretty"
  OS_ID_LIKE="$os_id_like"

  export OS_ID OS_VERSION OS_PRETTY_NAME OS_ID_LIKE
}

# Проверяет наличие systemd — и k3s, и preflight-проверки (порты, cgroups)
# полагаются на systemd unit'ы.
os_has_systemd() {
  [ -d /run/systemd/system ]
}

# cgroups v2 — жёсткое требование k3s начиная с некоторых версий containerd.
# На реальном хосте (не во вложенном контейнере CI/sandbox) этот файл должен
# существовать. Отсутствие здесь ещё не означает, что на целевом сервере
# будет так же — но если его нет прямо на целевом сервере, k3s не запустится.
os_has_cgroup_v2() {
  [ -f /sys/fs/cgroup/cgroup.controllers ]
}

# Специфичная для Astra Linux проверка: пытаемся определить, включён ли режим
# замкнутой программной среды (ЗПС) — если включён, запуск непроверенных
# бинарников (k3s, распакованных из air-gap bundle) может блокироваться
# политикой PARSEC. Утилита называется pdpl-control в части версий Astra —
# честно: у меня нет проверенного на реальном сервере Astra списка всех
# возможных названий/путей этой утилиты, поэтому проверка — best-effort:
# если утилита не найдена, явно говорим "не удалось проверить автоматически",
# а не молчим и не делаем вид, что всё в порядке.
os_check_astra_zps() {
  if command -v pdpl-control >/dev/null 2>&1; then
    echo "    pdpl-control найден — вывод статуса ЗПС (интерпретируйте вручную):"
    pdpl-control --status 2>&1 | sed 's/^/    /' || true
  else
    echo "    ⚠ Не удалось автоматически определить статус замкнутой программной"
    echo "      среды (ЗПС) — утилита pdpl-control не найдена в PATH. Если на"
    echo "      этом сервере включён режим ЗПС, установка k3s/распаковка"
    echo "      air-gap bundle может быть заблокирована политикой контроля"
    echo "      целостности — проверьте это ВРУЧНУЮ перед продолжением."
    echo "      См. docs/ASTRA_LINUX.md."
  fi
}

# Сверяет OS_ID/OS_VERSION с release/manifest.yaml. Возвращает через echo
# одно из: verified | unverified | unknown — и печатает поясняющее сообщение.
os_check_support() {
  if [ -z "${OS_ID:-}" ]; then
    echo "os_check_support вызван до os_detect — сначала вызовите os_detect" >&2
    return 1
  fi

  manifest_require_yq
  local count idx entry_id entry_versions entry_verified entry_notes match_id match_verified match_notes
  count="$(yq eval '.os_support | length' "$MANIFEST_FILE")"
  match_id=""
  for ((idx = 0; idx < count; idx++)); do
    entry_id="$(yq eval ".os_support[$idx].id" "$MANIFEST_FILE")"
    if [ "$entry_id" = "$OS_ID" ]; then
      match_id="$entry_id"
      entry_versions="$(yq eval ".os_support[$idx].versions | join(\", \")" "$MANIFEST_FILE")"
      match_verified="$(yq eval ".os_support[$idx].verified" "$MANIFEST_FILE")"
      match_notes="$(yq eval ".os_support[$idx].notes" "$MANIFEST_FILE")"
      break
    fi
  done

  if [ -z "$match_id" ]; then
    echo "unknown"
    echo "    ⚠ ОС '${OS_ID}' не значится в release/manifest.yaml (os_support)." >&2
    echo "      Продолжение на свой риск — этот installer не тестировался на" >&2
    echo "      этой ОС вообще. Список известных ОС: astra, ubuntu, debian." >&2
    return 0
  fi

  echo "    ОС: ${OS_PRETTY_NAME} (id=${OS_ID}, version=${OS_VERSION})" >&2
  echo "    Заявленные версии для '${OS_ID}' в manifest: ${entry_versions}" >&2

  if [ "$match_verified" = "true" ]; then
    echo "verified"
  else
    echo "unverified"
    echo "    ⚠ os_support[${OS_ID}].verified: false — этот installer написан по" >&2
    echo "      документации, но реального прогона preflight+install на этой ОС" >&2
    echo "      ещё не было. ${match_notes}" >&2
  fi
}
