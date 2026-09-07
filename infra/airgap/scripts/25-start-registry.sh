#!/usr/bin/env bash
set -uo pipefail   # без -e: печатаем свою диагностику, не просто падаем на первой ошибке

# infra/airgap/scripts/25-start-registry.sh
#
# Phase 1 аудит, находка H5: `k3s ctr images import` (20-load-images.sh)
# грузит образы ТОЛЬКО в containerd текущего узла — на профилях standard/ha
# (несколько узлов) остальные control-plane/worker-узлы этим путём образы
# не получат вообще. Этот скрипт поднимает локальный registry на "главном"
# узле (том, где распакован bundle) и настраивает k3s всех узлов забирать
# образы через него, вместо прямого обращения в интернет.
#
# Запускать ТОЛЬКО для профилей standard/ha (single — не нужно, там и так всё
# на одном узле, см. release/manifest.yaml registry.mode: none по умолчанию).
# Запускать ПОСЛЕ 20-load-images.sh — используется уже импортированный туда
# на этом узле образ registry (из общего image-list.txt, см. 00-fetch-bundle.sh).
#
# ⚠️ Многоузловой join (добавление control-plane/worker узлов в кластер)
# сам по себе НЕ автоматизирован этим репозиторием — эта часть по-прежнему
# ручная (см. вывод в конце этого скрипта). Здесь решается только задача
# "образы физически можно получить с любого узла офлайн", а не
# "провижининг дополнительных узлов k3s" целиком.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="$HERE/airgap-bundle"
BLOBS="$BUNDLE/images/blobs"
export PATH="$BUNDLE/bin:$PATH"

# shellcheck source=../../../scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"

REGISTRY_IMAGE="$(manifest_get '.registry.image')"
REGISTRY_PORT="$(manifest_get '.registry.port')"
K3S_VERSION="$(manifest_get '.kubernetes.version')"
DATA_DIR="/var/lib/local-registry"

if ! command -v crane >/dev/null 2>&1; then
  echo "crane не найден в $BUNDLE/bin — пересоберите bundle через 00-fetch-bundle.sh (обновлённая версия)" >&2
  exit 1
fi

echo "==> [1/4] Запускаем локальный registry ($REGISTRY_IMAGE) на этом узле"
if k3s ctr task ls 2>/dev/null | grep -q '^local-registry\b'; then
  echo "    Уже запущен (local-registry) — пропускаем."
else
  mkdir -p "$DATA_DIR"
  k3s ctr run -d \
    --net-host \
    --env REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry \
    --mount type=bind,src="$DATA_DIR",dst=/var/lib/registry,options=rbind:rw \
    "$REGISTRY_IMAGE" local-registry
fi

echo "==> [2/4] Ждём готовности registry на 127.0.0.1:${REGISTRY_PORT}"
ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  echo "registry не ответил на /v2/ за 60 секунд — смотрите 'k3s ctr task ls' / логи containerd" >&2
  exit 1
fi
echo "    OK"

# ── Канонизация имени образа под то, как его резолвит containerd-mirror ───
# containerd, обращаясь к mirror-endpoint для образа "quay.io/x/y:tag",
# запрашивает у него путь "x/y:tag" (хост-часть отбрасывается, остальной
# путь — как есть). Для образов без явного хоста (например "rabbitmq:3.13")
# Docker Hub неявно разворачивает их в "docker.io/library/rabbitmq:3.13" —
# поэтому такие образы в реестре должны лежать под "library/<name>:<tag>".
# Проверено юнит-тестом на 7 характерных образах (rabbitmq/kong/quay.io/
# registry.k8s.io/bitnami/ghcr.io/grafana) перед тем, как использовать здесь.
canonical_repo_path() {
  local img="$1"
  local name="${img%:*}"
  local tag="${img##*:}"
  local first_segment="${name%%/*}"
  if [[ "$first_segment" == *"."* || "$first_segment" == *":"* || "$first_segment" == "localhost" ]]; then
    local rest="${name#*/}"
    echo "${rest}:${tag}"
  else
    if [[ "$name" == */* ]]; then
      echo "${name}:${tag}"
    else
      echo "library/${name}:${tag}"
    fi
  fi
}

echo "==> [3/4] Пушим образы из bundle в локальный registry (crane)"
if [ ! -d "$BLOBS" ]; then
  echo "Не найдено $BLOBS — пересоберите bundle через 00-fetch-bundle.sh" >&2
  exit 1
fi

IMAGES_FILE="$BUNDLE/images/image-list.txt"
FAILED=()
OK=0

push_one() {
  local blob="$1" dest_ref="$2"
  echo "    $blob -> 127.0.0.1:${REGISTRY_PORT}/${dest_ref}"
  crane push --insecure "$blob" "127.0.0.1:${REGISTRY_PORT}/${dest_ref}"
}

if [ -f "$IMAGES_FILE" ]; then
  while read -r img; do
    [ -z "$img" ] && continue
    # registry-образ сам себя не пушит (он — сервер, не полезная нагрузка кластера)
    [ "$img" = "$REGISTRY_IMAGE" ] && continue
    fname="$(echo "$img" | tr '/:' '__').tar"
    blob="$BLOBS/$fname"
    if [ ! -f "$blob" ]; then
      echo "    !! нет файла $blob для $img — пропускаем" >&2
      FAILED+=("$img")
      continue
    fi
    if push_one "$blob" "$(canonical_repo_path "$img")"; then
      OK=$((OK + 1))
    else
      FAILED+=("$img")
    fi
  done < "$IMAGES_FILE"
fi

# mes-stub — свой образ, не с публичного registry вообще (нет host-префикса
# в манифесте по умолчанию — infra/base/stub-service/deployment.yaml
# использует "mes-stub:offline"), поэтому та же неявная docker.io/library
# канонизация, что и для rabbitmq/kong.
mes_stub_blob="$BLOBS/mes-stub_offline.tar"
if [ -f "$mes_stub_blob" ]; then
  if push_one "$mes_stub_blob" "$(canonical_repo_path "mes-stub:offline")"; then
    OK=$((OK + 1))
  else
    FAILED+=("mes-stub:offline")
  fi
fi

echo
echo "==> Запушено успешно: $OK"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "==> Не удалось запушить:"
  printf '    - %s\n' "${FAILED[@]}"
  echo "    Кластер, скорее всего, частично неработоспособен без этих образов на других узлах."
  exit 1
fi

echo "==> [4/4] Настраиваем containerd mirror на ЭТОМ узле (/etc/rancher/k3s/registries.yaml)"
NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "$NODE_IP" ]; then
  echo "Не удалось автоматически определить IP этого узла (hostname -I пуст) — впишите его в" >&2
  echo "/etc/rancher/k3s/registries.yaml вручную (endpoint: http://<IP узла>:${REGISTRY_PORT})." >&2
  exit 1
fi

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<EOF
# Сгенерировано infra/airgap/scripts/25-start-registry.sh — НЕ редактировать вручную,
# при повторном запуске скрипта будет перезаписан.
#
# Wildcard-mirror ("*") — редиректит ЛЮБОЙ образ (docker.io, quay.io,
# registry.k8s.io, ghcr.io — какой бы регистр ни был прописан в манифесте)
# через локальный registry, без переписывания image: полей в самих манифестах.
# Поддержка "*" в k3s — с релизов начала 2024 (наша pinned версия
# ${K3S_VERSION} новее, есть).
mirrors:
  "*":
    endpoint:
      - "http://${NODE_IP}:${REGISTRY_PORT}"
EOF
echo "    Записано: /etc/rancher/k3s/registries.yaml (endpoint http://${NODE_IP}:${REGISTRY_PORT})"
echo "    Если k3s на этом узле уже запущен — перезапустите: systemctl restart k3s"
echo "    (registries.yaml читается containerd только при старте)"

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Локальный registry поднят на этом узле: ${NODE_IP}:${REGISTRY_PORT}"
echo
echo " Для КАЖДОГО дополнительного узла (control-plane или worker), который"
echo " будет присоединён к кластеру — ДО запуска k3s/k3s-agent на нём:"
echo "   1. Создайте на нём тот же файл /etc/rancher/k3s/registries.yaml"
echo "      с тем же содержимым, что выше (endpoint: http://${NODE_IP}:${REGISTRY_PORT})"
echo "   2. Убедитесь, что порт ${REGISTRY_PORT} на этом узле (${NODE_IP})"
echo "      доступен с сетей остальных узлов (firewall/security group)"
echo "   3. Сам процесс присоединения узла (k3s agent --server ... --token ...)"
echo "      этим репозиторием пока НЕ автоматизирован — см. docs/HA.md"
echo "      (появится в одном из следующих инкрементов) или официальную"
echo "      документацию k3s о добавлении узлов."
echo "════════════════════════════════════════════════════════════════════"
