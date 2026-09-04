#!/usr/bin/env bash
set -uo pipefail   # без -e: хотим сами показать диагностику при сбое, а не просто прерваться
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$HERE/airgap-bundle"

# shellcheck source=../../../scripts/lib/secrets.sh
source "$HERE/../../scripts/lib/secrets.sh"

kubectl get namespace platform >/dev/null 2>&1 || kubectl apply -f "$HERE/../base/namespace.yaml"

echo "==> Приводим уже существующие Kong CRD (если остались от прошлых попыток) под ownership Helm"
for crd in $(kubectl get crd -o name 2>/dev/null | grep 'konghq.com' || true); do
  kubectl label --overwrite "$crd" app.kubernetes.io/managed-by=Helm >/dev/null
  kubectl annotate --overwrite "$crd" meta.helm.sh/release-name=kong meta.helm.sh/release-namespace=platform >/dev/null
  echo "    адаптирован: $crd"
done

dump_diagnostics() {
  local label="$1"
  echo "    --- kubectl get pods -n platform ($label) ---"
  kubectl get pods -n platform -o wide
  echo "    --- поды не в Running/Completed: describe (последние события) ---"
  for pod in $(kubectl get pods -n platform --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null); do
    echo "    >>> $pod"
    kubectl describe "$pod" -n platform | tail -20
  done
}

echo "==> Kong (из локального .tgz, без helm repo add)"
if ! helm upgrade --install kong "$BUNDLE"/charts/kong-*.tgz \
    -n platform -f "$HERE/values/kong-offline-values.yaml" --wait --timeout 5m; then
  echo "!! Установка Kong не завершилась вовремя — вот что с подами:"
  dump_diagnostics "kong"
  echo "!! Частая причина: не импортировался какой-то вспомогательный образ (например busybox"
  echo "   для init-контейнеров) — смотрите Events в describe выше (ImagePullBackOff/ErrImageNeverPull)."
  exit 1
fi

echo "==> kube-prometheus-stack (из локального .tgz)"
ensure_grafana_admin_secret platform
if ! helm upgrade --install monitoring "$BUNDLE"/charts/kube-prometheus-stack-*.tgz \
    -n platform -f "$HERE/values/kube-prometheus-stack-offline-values.yaml" --wait --timeout 10m; then
  echo "!! Установка kube-prometheus-stack не завершилась вовремя — вот что с подами:"
  dump_diagnostics "monitoring"
  exit 1
fi

echo "==> Готово. Проверка:"
echo "    kubectl get pods -n platform"
