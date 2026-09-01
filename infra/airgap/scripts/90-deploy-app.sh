#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Применяем манифесты проекта (kustomize overlays/single — single-node: local-path StorageClass, 1 реплика вместо 3/2, тот же namespace 'platform')"
kubectl apply -k "$HERE/../overlays/single"

echo "==> Ждём готовности RabbitMQ-кластера (это StatefulSet оператора, может занять пару минут)"
kubectl wait --for=condition=ClusterAvailable rabbitmqcluster/platform-rabbitmq -n platform --timeout=5m || true

echo "==> Ждём готовности mes-stub"
kubectl rollout status deployment/mes-stub -n platform --timeout=3m

echo "==> Готово. Проверка снаружи (через port-forward, т.к. LoadBalancer офлайн недоступен):"
echo "    kubectl -n platform port-forward svc/kong-kong-proxy 8080:80"
echo "    curl http://localhost:8080/api/mes/dispatch/orders"
echo
echo "    kubectl -n platform port-forward svc/monitoring-grafana 3000:80"
echo "    открыть http://localhost:3000 (admin / см. values/kube-prometheus-stack-offline-values.yaml)"
