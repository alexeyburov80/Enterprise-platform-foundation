#!/usr/bin/env bash
set -euo pipefail

# ЗАМЕЧАНИЕ (Phase 3, инкремент 1): этот скрипт — временный "online-only" путь,
# оставленный для обратной совместимости. Он будет заменён единым корневым
# bootstrap.sh с поддержкой профилей (single/standard/ha/existing) и офлайн-режима
# — см. architecture.md, раздел 10. Устанавливает готовые open-source компоненты
# фундамента (принцип 3 ТЗ) в уже существующий k8s-кластер (минимум 3 узла —
# предполагается, что кластер уже поднят и kubectl настроен на нужный контекст).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"

RABBITMQ_OPERATOR_VERSION="$(manifest_get '.operators.rabbitmq_cluster_operator.version')"
RABBITMQ_OPERATOR_URL="$(manifest_get '.operators.rabbitmq_cluster_operator.manifest_url')"
TOPOLOGY_OPERATOR_VERSION="$(manifest_get '.operators.rabbitmq_messaging_topology_operator.version')"
TOPOLOGY_OPERATOR_URL="$(manifest_get '.operators.rabbitmq_messaging_topology_operator.manifest_url_with_certmanager')"
KONG_CHART_VERSION="$(manifest_get '.charts.kong.version')"
PROMETHEUS_CHART_VERSION="$(manifest_get '.charts.kube-prometheus-stack.version')"

echo "==> Namespace platform"
kubectl apply -f infra/base/namespace.yaml

echo "==> RabbitMQ Cluster Operator ${RABBITMQ_OPERATOR_VERSION} + Messaging Topology Operator ${TOPOLOGY_OPERATOR_VERSION}"
echo "    (версии зафиксированы в release/manifest.yaml — не 'latest')"
echo "    Требуется предварительно установленный cert-manager (webhooks Topology Operator)."
kubectl apply -f "$RABBITMQ_OPERATOR_URL"
kubectl apply -f "$TOPOLOGY_OPERATOR_URL"

echo "==> Kong ${KONG_CHART_VERSION} (Helm)"
helm repo add kong https://charts.konghq.com
helm repo update
helm upgrade --install kong kong/kong --version "$KONG_CHART_VERSION" \
  -n platform -f infra/base/api-gateway/kong-values.yaml

echo "==> kube-prometheus-stack ${PROMETHEUS_CHART_VERSION} (Helm)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$PROMETHEUS_CHART_VERSION" \
  -n platform -f infra/base/monitoring/kube-prometheus-stack-values.yaml

echo "==> Готово. Дальше выберите профиль по топологии кластера:"
echo "      kubectl apply -k infra/overlays/single    # один узел"
echo "      kubectl apply -k infra/overlays/standard  # несколько узлов, мягкая anti-affinity"
echo "      kubectl apply -k infra/overlays/ha        # 3+ узла, гарантированный разъезд реплик"
echo "    (или infra/overlays/staging — тестовый контур в отдельном namespace)"
