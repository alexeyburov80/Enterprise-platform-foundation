#!/usr/bin/env bash
set -euo pipefail
# scripts/stages/04-rabbitmq-operators.sh
#
# Использование: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # если ещё не выставлен
#                ./scripts/stages/04-rabbitmq-operators.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=../lib/rabbitmq-webhook-certs.sh
source "$REPO_ROOT/scripts/lib/rabbitmq-webhook-certs.sh"
# shellcheck source=../lib/install-online-components.sh
source "$REPO_ROOT/scripts/lib/install-online-components.sh"

echo "── Стадия 4: RabbitMQ Cluster Operator + Messaging Topology Operator ──"
install_namespace_and_rabbitmq_operators "$REPO_ROOT"

echo
echo "Готово. Дальше: scripts/stages/05-kong.sh --topology <single|standard|ha>"
