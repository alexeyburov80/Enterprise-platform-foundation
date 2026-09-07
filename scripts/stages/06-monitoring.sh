#!/usr/bin/env bash
set -euo pipefail
# scripts/stages/06-monitoring.sh
#
# Использование: ./scripts/stages/06-monitoring.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=../lib/secrets.sh
source "$REPO_ROOT/scripts/lib/secrets.sh"
# shellcheck source=../lib/install-online-components.sh
source "$REPO_ROOT/scripts/lib/install-online-components.sh"

echo "── Стадия 6: kube-prometheus-stack ──"
install_monitoring "$REPO_ROOT"

echo
echo "Готово. Дальше: scripts/stages/07-apply-manifests.sh --topology <single|standard|ha>"
