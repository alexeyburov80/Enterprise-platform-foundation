#!/usr/bin/env bash
set -euo pipefail
# scripts/stages/07-apply-manifests.sh
#
# Использование: ./scripts/stages/07-apply-manifests.sh --topology single

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

TOPOLOGY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --topology) TOPOLOGY="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$TOPOLOGY" ]; then
  echo "Нужен --topology single|standard|ha" >&2
  exit 2
fi

echo "── Стадия 7: манифесты платформы (kustomize overlays/${TOPOLOGY}) ──"
kubectl apply -k "$REPO_ROOT/infra/overlays/${TOPOLOGY}"

if [ "$TOPOLOGY" = "ha" ]; then
  echo "    ⚠ Профиль 'ha' требует, чтобы вы заранее отредактировали"
  echo "      infra/overlays/ha/kustomization.yaml (реальный StorageClass вместо"
  echo "      __SET_STORAGECLASS_IN_OVERLAY__) — если вы этого не сделали, PVC"
  echo "      RabbitMQ сейчас в Pending. Проверьте: kubectl get pvc -n platform"
fi

echo
echo "Проверка: kubectl get pods -n platform"
echo "Ожидается: все поды Running (RabbitMQ может подниматься 1-2 минуты)."
echo "           kubectl get networkpolicy -n platform  — должно быть 10 объектов."
echo
echo "Готово — установка завершена."
