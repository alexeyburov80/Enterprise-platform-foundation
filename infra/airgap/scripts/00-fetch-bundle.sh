#!/usr/bin/env bash
set -euo pipefail

# Запускать ТОЛЬКО на машине с доступом в интернет (не на целевом air-gap сервере).
# Требуются: docker (или podman с алиасом docker), curl, tar.
# Результат: ./airgap-bundle.tar.gz — переносится на целевой сервер офлайн-способом.

K3S_VERSION="${K3S_VERSION:-v1.30.5+k3s1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.30.5}"
HELM_VERSION="${HELM_VERSION:-v3.15.4}"
ARCH="${ARCH:-amd64}"

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

echo "==> [1/6] Бинарники: k3s, kubectl, helm"
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
chmod +x "$BUNDLE"/bin/*
export PATH="$BUNDLE/bin:$PATH"   # чтобы шаги ниже использовали скачанные helm/kubectl, а не системные

echo "==> [2/6] RabbitMQ operator manifesты (без cert-manager)"
curl -fL "https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml" \
  -o "$BUNDLE/manifests/cluster-operator.yml"
curl -fL "https://github.com/rabbitmq/messaging-topology-operator/releases/latest/download/messaging-topology-operator.yaml" \
  -o "$BUNDLE/manifests/messaging-topology-operator.yaml"

echo "==> [3/6] Helm-чарты (kong, kube-prometheus-stack) — скачиваем как .tgz"
helm repo add kong https://charts.konghq.com >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm pull kong/kong --destination "$BUNDLE/charts"
helm pull prometheus-community/kube-prometheus-stack --destination "$BUNDLE/charts"

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
echo "rabbitmq:3.13-management" >> "$IMAGES_FILE"

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
