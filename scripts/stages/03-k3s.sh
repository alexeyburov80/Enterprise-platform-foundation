#!/usr/bin/env bash
set -euo pipefail
# scripts/stages/03-k3s.sh
#
# Использование: sudo ./scripts/stages/03-k3s.sh --profile single [--offline]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROFILE=""
OFFLINE="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --offline) OFFLINE="true"; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$PROFILE" ]; then
  echo "Нужен --profile single|standard|ha|existing" >&2
  exit 2
fi

# shellcheck source=../lib/k3s-stage.sh
source "$REPO_ROOT/scripts/lib/k3s-stage.sh"

echo "── Стадия 3: Kubernetes (k3s) ──"
k3s_detect_or_install "$REPO_ROOT" "$PROFILE" "$OFFLINE"

echo
echo "Проверка: sudo k3s kubectl get nodes    (или просто 'kubectl get nodes',"
echo "           если KUBECONFIG=/etc/rancher/k3s/k3s.yaml уже в окружении)"
echo "Ожидается: один узел в статусе Ready."
echo
echo "Готово. Дальше (не забудьте экспортировать KUBECONFIG в текущем шелле,"
echo "если продолжаете вручную): export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo "  scripts/stages/04-rabbitmq-operators.sh"
