#!/usr/bin/env bash
set -euo pipefail

# Устанавливает готовые open-source компоненты фундамента (принцип 3 ТЗ)
# в уже существующий k8s-кластер (минимум 3 узла — предполагается, что
# кластер уже поднят и kubectl настроен на нужный контекст).

echo "==> Namespace platform"
kubectl apply -f infra/base/namespace.yaml

echo "==> RabbitMQ Cluster Operator + Messaging Topology Operator"
kubectl apply -f "https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml"
kubectl apply -f "https://github.com/rabbitmq/messaging-topology-operator/releases/latest/download/messaging-topology-operator-with-certmanager.yaml"

echo "==> Kong (Helm)"
helm repo add kong https://charts.konghq.com
helm repo update
helm upgrade --install kong kong/kong -n platform -f infra/base/api-gateway/kong-values.yaml

echo "==> kube-prometheus-stack (Helm)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n platform -f infra/base/monitoring/kube-prometheus-stack-values.yaml

echo "==> Готово. Дальше: kubectl apply -k infra/overlays/staging"
