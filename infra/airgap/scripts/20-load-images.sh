#!/usr/bin/env bash
set -uo pipefail   # без -e: один битый образ не должен прерывать весь импорт
# k3s сам подхватывает tar-файлы из /var/lib/rancher/k3s/agent/images/ при старте —
# этим же путём заносим наши платформенные образы (не только системные k3s).
# Отдельный registry на одном узле не нужен: containerd берёт образ из локального
# кэша по тегу, если он там уже есть — сети для этого не требуется.
#
# Каждый образ импортируется отдельным файлом — если какой-то битый,
# остальные всё равно встанут, а в конце будет чёткий список, что не удалось.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$HERE/airgap-bundle"
BLOBS="$BUNDLE/images/blobs"

if [ ! -d "$BLOBS" ]; then
  echo "Не найдено $BLOBS — пересоберите bundle через 00-fetch-bundle.sh (обновлённая версия)" >&2
  exit 1
fi

FAILED=()
OK=0
TOTAL=$(find "$BLOBS" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)

for f in "$BLOBS"/*.tar; do
  name="$(basename "$f")"
  echo "==> Импортируем $name"
  if k3s ctr images import "$f"; then
    OK=$((OK+1))
  else
    echo "    !! ОШИБКА импорта $name — образ будет недоступен, разберём отдельно"
    FAILED+=("$name")
  fi
done

echo
echo "==> Импортировано успешно: $OK из $TOTAL"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "==> Не удалось импортировать:"
  printf '    - %s\n' "${FAILED[@]}"
  echo "    Пересоздайте именно эти образы на машине с интернетом и повторите этот шаг."
  exit 1
fi

echo "==> Проверяем, что образы на месте"
k3s ctr images ls | grep -E "rabbitmq|kong|prometheus|grafana|alertmanager|mes-stub" || true

echo "==> Готово. Все Deployment/StatefulSet в проекте используют"
echo "    imagePullPolicy: IfNotPresent — повторных обращений к сети не будет."
