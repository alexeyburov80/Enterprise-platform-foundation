#!/usr/bin/env bash
set -uo pipefail   # без -e: apply манифестов частично "падает" на Certificate/Issuer — это ожидаемо
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$HERE/airgap-bundle"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# shellcheck source=../../../scripts/lib/rabbitmq-webhook-certs.sh
source "$REPO_ROOT/scripts/lib/rabbitmq-webhook-certs.sh"

# Функции генерации сертификатов и caBundle вынесены в
# scripts/lib/rabbitmq-webhook-certs.sh — используются и здесь (offline),
# и в scripts/lib/install-online-components.sh (online), чтобы оба пути
# не расходились в поведении RabbitMQ-операторов (Phase 3, инкремент 3).

rabbitmq_install_operators_with_selfsigned_certs \
  "$BUNDLE/manifests/cluster-operator.yml" \
  "$BUNDLE/manifests/messaging-topology-operator.yaml"
