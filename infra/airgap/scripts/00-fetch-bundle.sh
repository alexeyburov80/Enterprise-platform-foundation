#!/usr/bin/env bash
set -euo pipefail

# Запускать ТОЛЬКО на машине с доступом в интернет (не на целевом air-gap сервере).
# Требуются: docker (или podman с алиасом docker), curl, tar, yq (для release/manifest.yaml).
# Результат: ./airgap-bundle.tar.gz — переносится на целевой сервер офлайн-способом.
#
# Все версии читаются из release/manifest.yaml — единственного источника истины
# (Phase 1 аудит, находка C2: раньше здесь был "latest" для RabbitMQ-операторов,
# из-за чего bundle, собранный сегодня и через месяц, был двумя разными,
# невоспроизводимыми релизами).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"

K3S_VERSION="${K3S_VERSION:-$(manifest_get '.kubernetes.version')}"
KUBECTL_VERSION="${KUBECTL_VERSION:-$(manifest_get '.tooling.kubectl.version')}"
HELM_VERSION="${HELM_VERSION:-$(manifest_get '.tooling.helm.version')}"
RABBITMQ_OPERATOR_VERSION="$(manifest_get '.operators.rabbitmq_cluster_operator.version')"
RABBITMQ_OPERATOR_URL="$(manifest_get '.operators.rabbitmq_cluster_operator.manifest_url')"
TOPOLOGY_OPERATOR_VERSION="$(manifest_get '.operators.rabbitmq_messaging_topology_operator.version')"
TOPOLOGY_OPERATOR_URL="$(manifest_get '.operators.rabbitmq_messaging_topology_operator.manifest_url_no_certmanager')"
RABBITMQ_IMAGE="$(manifest_get '.images.rabbitmq')"
REGISTRY_IMAGE="$(manifest_get '.registry.image')"
CRANE_VERSION="$(manifest_get '.tools_extra.crane.version')"
CRANE_URL="$(manifest_get '.tools_extra.crane.source')"
ARCH="${ARCH:-amd64}"

echo "==> Версии из release/manifest.yaml:"
echo "    k3s=${K3S_VERSION} kubectl=${KUBECTL_VERSION} helm=${HELM_VERSION}"
echo "    rabbitmq-cluster-operator=${RABBITMQ_OPERATOR_VERSION} messaging-topology-operator=${TOPOLOGY_OPERATOR_VERSION}"
echo "    registry-image=${REGISTRY_IMAGE} crane=${CRANE_VERSION}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$WORKDIR/airgap-bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"/{bin,images,k3s-airgap,charts,manifests}

if ! command -v skopeo >/dev/null 2>&1; then
  echo "Нужен skopeo (для чистого скачивания образов без attestation-мусора, из-за которого" >&2
  echo "падает 'content digest not found' при импорте в containerd). Установите и перезапустите:" >&2
  echo "    sudo apt-get update && sudo apt-get install -y skopeo" >&2
  exit 1
fi

echo "==> [1/6] Бинарники: k3s, kubectl, helm, crane"
curl -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s" \
  -o "$BUNDLE/bin/k3s"
curl -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s-airgap-images-${ARCH}.tar.gz" \
  -o "$BUNDLE/k3s-airgap/k3s-airgap-images-${ARCH}.tar.gz"
curl -fL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
  -o "$BUNDLE/bin/kubectl"
curl -fL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
  -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
cp "/tmp/linux-${ARCH}/helm" "$BUNDLE/bin/helm"
# crane — только для infra/airgap/scripts/25-start-registry.sh (профили
# standard/ha: пушит образы из bundle в локальный registry). Для профиля
# single не используется вообще, но кладём в bundle всегда — он маленький
# (один статический бинарник), а разница online/offline/профиль решается
# уже на целевом сервере, не на этапе сборки bundle.
curl -fL "$CRANE_URL" -o /tmp/crane.tar.gz
tar -xzf /tmp/crane.tar.gz -C /tmp crane
cp /tmp/crane "$BUNDLE/bin/crane"
chmod +x "$BUNDLE"/bin/*
export PATH="$BUNDLE/bin:$PATH"   # чтобы шаги ниже использовали скачанные helm/kubectl, а не системные

echo "==> [2/6] RabbitMQ operator manifesты ${RABBITMQ_OPERATOR_VERSION}/${TOPOLOGY_OPERATOR_VERSION} (без cert-manager, pinned)"
curl -fL "$RABBITMQ_OPERATOR_URL" \
  -o "$BUNDLE/manifests/cluster-operator.yml"
curl -fL "$TOPOLOGY_OPERATOR_URL" \
  -o "$BUNDLE/manifests/messaging-topology-operator.yaml"

KONG_CHART_VERSION="$(manifest_get '.charts.kong.version')"
PROMETHEUS_CHART_VERSION="$(manifest_get '.charts.kube-prometheus-stack.version')"

echo "==> [3/6] Helm-чарты kong=${KONG_CHART_VERSION} kube-prometheus-stack=${PROMETHEUS_CHART_VERSION} (pinned, .tgz)"
helm repo add kong https://charts.konghq.com >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm pull kong/kong --version "$KONG_CHART_VERSION" --destination "$BUNDLE/charts"
helm pull prometheus-community/kube-prometheus-stack --version "$PROMETHEUS_CHART_VERSION" --destination "$BUNDLE/charts"

echo "==> [4/6] Собираем образ mes-stub (явно под linux/amd64 — избегаем multi-arch manifest list)"
docker build --platform linux/amd64 -t mes-stub:offline "$WORKDIR/../base/stub-service/app"

echo "==> [5/6] Вычисляем полный список образов из чартов и манифестов (без обращения к кластеру)"
IMAGES_FILE="$BUNDLE/images/image-list.txt"
: > "$IMAGES_FILE"

helm template kong "$BUNDLE"/charts/kong-*.tgz -f "$WORKDIR/values/kong-offline-values.yaml" \
  | grep -oP '^\s*image:\s*"?\K[^"\s]+' >> "$IMAGES_FILE" || true
helm template monitoring "$BUNDLE"/charts/kube-prometheus-stack-*.tgz -f "$WORKDIR/values/kube-prometheus-stack-offline-values.yaml" \
  | grep -oP '^\s*image:\s*"?\K[^"\s]+' >> "$IMAGES_FILE" || true
grep -oP '(?<=image: ).*' "$BUNDLE/manifests/cluster-operator.yml" | tr -d '"' >> "$IMAGES_FILE" || true
grep -oP '(?<=image: ).*' "$BUNDLE/manifests/messaging-topology-operator.yaml" | tr -d '"' >> "$IMAGES_FILE" || true
echo "$RABBITMQ_IMAGE" >> "$IMAGES_FILE"
echo "$REGISTRY_IMAGE" >> "$IMAGES_FILE"
# registry-образ добавлен в общий список специально (не отдельным
# curl/skopeo-вызовом) — он проходит тот же путь скачивания без
# attestation-манифестов, что и остальные образы (см. комментарий к шагу
# [6/6] ниже), это уже отлаженный путь, дублировать его не нужно.

sort -u -o "$IMAGES_FILE" "$IMAGES_FILE"
echo "    Найдено образов: $(wc -l < "$IMAGES_FILE")"
echo "    Проверьте $IMAGES_FILE перед следующим шагом — при необходимости дополните вручную."

echo "==> [6/6] Скачиваем образы через skopeo (linux/amd64, без attestation-манифестов) — по одному tar на образ"
mkdir -p "$BUNDLE/images/blobs"
rm -f "$BUNDLE/images"/*.tar 2>/dev/null || true

while read -r img; do
  [ -z "$img" ] && continue
  fname="$(echo "$img" | tr '/:' '__').tar"
  echo "    skopeo copy $img"
  skopeo copy --override-os linux --override-arch amd64 \
    "docker://$img" "docker-archive:$BUNDLE/images/blobs/$fname:$img"
done < "$IMAGES_FILE"

docker save mes-stub:offline -o "$BUNDLE/images/blobs/mes-stub_offline.tar"

echo "==> Упаковываем bundle"
tar -czf "$WORKDIR/airgap-bundle.tar.gz" -C "$WORKDIR" airgap-bundle
echo "Готово: $WORKDIR/airgap-bundle.tar.gz"
echo "Перенесите этот файл на целевой сервер офлайн-способом и распакуйте в infra/airgap/"
