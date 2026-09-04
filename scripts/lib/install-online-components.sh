#!/usr/bin/env bash
# scripts/lib/install-online-components.sh
#
# Устанавливает RabbitMQ-операторы + Kong + kube-prometheus-stack на хосте
# с доступом в интернет. Раньше это была отдельная функциональность
# scripts/bootstrap.sh (см. git-историю) с двумя отличиями от offline-пути:
# требовала cert-manager и предполагала уже существующий кластер. Оба
# отличия убраны в Phase 3, инкременте 3:
#   - вебхуки RabbitMQ-операторов теперь используют тот же самоподписанный
#     сертификат, что и offline-путь (scripts/lib/rabbitmq-webhook-certs.sh) —
#     cert-manager как зависимость больше не нужен;
#   - установка/пропуск k3s теперь решается в корневом bootstrap.sh
#     ДО вызова этой функции, а не предполагается неявно.
#
# Использование:
# Использование:
#   source scripts/lib/manifest.sh
#   source scripts/lib/rabbitmq-webhook-certs.sh
#   source scripts/lib/secrets.sh
#   source scripts/lib/install-online-components.sh
#   install_online_components "$REPO_ROOT"

install_online_components() {
  local repo_root="$1"
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

  local rabbitmq_operator_url topology_operator_url kong_chart_version prometheus_chart_version
  rabbitmq_operator_url="$(manifest_get '.operators.rabbitmq_cluster_operator.manifest_url')"
  topology_operator_url="$(manifest_get '.operators.rabbitmq_messaging_topology_operator.manifest_url_no_certmanager')"
  kong_chart_version="$(manifest_get '.charts.kong.version')"
  prometheus_chart_version="$(manifest_get '.charts.kube-prometheus-stack.version')"

  echo "==> Namespace platform"
  kubectl apply -f "$repo_root/infra/base/namespace.yaml"

  echo "==> RabbitMQ Cluster Operator + Messaging Topology Operator (самоподписанные сертификаты, без cert-manager)"
  rabbitmq_install_operators_with_selfsigned_certs "$rabbitmq_operator_url" "$topology_operator_url"

  echo "==> Kong ${kong_chart_version} (Helm)"
  helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install kong kong/kong --version "$kong_chart_version" \
    -n platform --create-namespace -f "$repo_root/infra/base/api-gateway/kong-values.yaml"

  echo "==> kube-prometheus-stack ${prometheus_chart_version} (Helm)"
  ensure_grafana_admin_secret platform
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --version "$prometheus_chart_version" \
    -n platform --create-namespace -f "$repo_root/infra/base/monitoring/kube-prometheus-stack-values.yaml"
}
