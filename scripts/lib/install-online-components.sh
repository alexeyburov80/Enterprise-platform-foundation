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
#   source scripts/lib/manifest.sh
#   source scripts/lib/rabbitmq-webhook-certs.sh
#   source scripts/lib/secrets.sh
#   source scripts/lib/install-online-components.sh
#   install_online_components "$REPO_ROOT" "$TOPOLOGY"

# Найдено реальным прогоном (не в песочнице): этот файл всегда предполагал,
# что helm уже стоит на системе, и никогда не проверял/не ставил его сам —
# в отличие от offline-пути (helm едет в самом bundle) и от yq (автоустановка
# добавлена отдельным фиксом ранее). Тот же класс проблемы, тот же фикс.
ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  local helm_version arch dest tmp
  helm_version="$(manifest_get '.tooling.helm.version')"
  arch="amd64"
  dest="/usr/local/bin/helm"
  echo "helm не найден — устанавливаю ${helm_version} (release/manifest.yaml)." >&2
  tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 30 "https://get.helm.sh/helm-${helm_version}-linux-${arch}.tar.gz" -o "$tmp/helm.tar.gz"; then
    echo "Не удалось скачать helm — нет интернета? Поставьте вручную: https://helm.sh/docs/intro/install/" >&2
    rm -rf "$tmp"
    return 1
  fi
  tar -xzf "$tmp/helm.tar.gz" -C "$tmp"
  if [ -w "$(dirname "$dest")" ]; then
    mv "$tmp/linux-${arch}/helm" "$dest"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mv "$tmp/linux-${arch}/helm" "$dest"
  else
    echo "Скачан helm, но нет прав записать в $dest и нет sudo. Переместите вручную: $tmp/linux-${arch}/helm" >&2
    return 1
  fi
  chmod +x "$dest" 2>/dev/null || sudo chmod +x "$dest"
  rm -rf "$tmp"
  if ! command -v helm >/dev/null 2>&1; then
    echo "helm скачан в $dest, но не находится в PATH — проверьте \$PATH." >&2
    return 1
  fi
  echo "helm ${helm_version} установлен в $dest." >&2
}

# Использование:
#   source scripts/lib/manifest.sh
#   source scripts/lib/rabbitmq-webhook-certs.sh
#   source scripts/lib/secrets.sh
#   source scripts/lib/install-online-components.sh
#
# Начиная с этого фикса (найдено долгой живой отладкой — Kong застревал в
# Pending, потом kube-prometheus-stack зависал на несколько минут и было
# непонятно, где именно, пока не Ctrl+C) — три отдельные, независимо
# вызываемые стадии вместо одной большой функции. Каждая проверяема сама
# по себе: scripts/stages/{03,04,05}-*.sh — тонкие обёртки вокруг них же.
#   install_namespace_and_rabbitmq_operators "$REPO_ROOT"
#   install_kong "$REPO_ROOT" "$TOPOLOGY"
#   install_monitoring "$REPO_ROOT"
# install_online_components (ниже) — просто вызывает все три подряд, для
# обратной совместимости и для automated-режима bootstrap.sh.

# Найдено реальным прогоном (не в песочнице): этот файл всегда предполагал,
# что helm уже стоит на системе, и никогда не проверял/не ставил его сам —
# в отличие от offline-пути (helm едет в самом bundle) и от yq (автоустановка
# добавлена отдельным фиксом ранее). Тот же класс проблемы, тот же фикс.
ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  local helm_version arch dest tmp
  helm_version="$(manifest_get '.tooling.helm.version')"
  arch="amd64"
  dest="/usr/local/bin/helm"
  echo "helm не найден — устанавливаю ${helm_version} (release/manifest.yaml)." >&2
  tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 30 "https://get.helm.sh/helm-${helm_version}-linux-${arch}.tar.gz" -o "$tmp/helm.tar.gz"; then
    echo "Не удалось скачать helm — нет интернета? Поставьте вручную: https://helm.sh/docs/intro/install/" >&2
    rm -rf "$tmp"
    return 1
  fi
  tar -xzf "$tmp/helm.tar.gz" -C "$tmp"
  if [ -w "$(dirname "$dest")" ]; then
    mv "$tmp/linux-${arch}/helm" "$dest"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mv "$tmp/linux-${arch}/helm" "$dest"
  else
    echo "Скачан helm, но нет прав записать в $dest и нет sudo. Переместите вручную: $tmp/linux-${arch}/helm" >&2
    return 1
  fi
  chmod +x "$dest" 2>/dev/null || sudo chmod +x "$dest"
  rm -rf "$tmp"
  if ! command -v helm >/dev/null 2>&1; then
    echo "helm скачан в $dest, но не находится в PATH — проверьте \$PATH." >&2
    return 1
  fi
  echo "helm ${helm_version} установлен в $dest." >&2
}

install_namespace_and_rabbitmq_operators() {
  local repo_root="$1"
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

  local rabbitmq_operator_url topology_operator_url
  rabbitmq_operator_url="$(manifest_get '.operators.rabbitmq_cluster_operator.manifest_url')"
  topology_operator_url="$(manifest_get '.operators.rabbitmq_messaging_topology_operator.manifest_url_no_certmanager')"

  echo "==> Namespace platform"
  kubectl apply -f "$repo_root/infra/base/namespace.yaml"

  echo "==> RabbitMQ Cluster Operator + Messaging Topology Operator (самоподписанные сертификаты, без cert-manager)"
  rabbitmq_install_operators_with_selfsigned_certs "$rabbitmq_operator_url" "$topology_operator_url"

  echo
  echo "Проверка: kubectl get pods -n rabbitmq-system"
  echo "Ожидается: rabbitmq-cluster-operator-* и messaging-topology-operator-* оба Running 1/1"
}

install_kong() {
  local repo_root="$1"
  local topology="${2:-standard}"
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  ensure_helm || return 1

  local kong_chart_version
  kong_chart_version="$(manifest_get '.charts.kong.version')"

  echo "==> Kong ${kong_chart_version} (Helm, topology=${topology})"
  helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
  helm repo update >/dev/null
  local kong_values_args=(-f "$repo_root/infra/base/api-gateway/kong-values.yaml")
  if [ "$topology" = "single" ]; then
    # См. kong-values-single.yaml — на одном узле base-конфиг (2 реплики +
    # hard anti-affinity) навсегда оставляет вторую/новую реплику в Pending.
    kong_values_args+=(-f "$repo_root/infra/base/api-gateway/kong-values-single.yaml")
  fi
  helm upgrade --install kong kong/kong --version "$kong_chart_version" \
    -n platform --create-namespace "${kong_values_args[@]}"

  echo
  echo "Проверка: kubectl get pods -n platform -l app.kubernetes.io/name=kong"
  echo "Ожидается: под(ы) в состоянии Running с готовыми ВСЕМИ контейнерами (например 2/2)."
  echo "Если под Pending — 'kubectl describe pod <имя> -n platform', смотрите Events в конце."
  echo "Если под Running, но не все контейнеры готовы (например 1/2) — не спешите продолжать,"
  echo "сначала 'kubectl logs <имя> -n platform --all-containers' и разберитесь, почему."
}

install_monitoring() {
  local repo_root="$1"
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  ensure_helm || return 1

  local prometheus_chart_version
  prometheus_chart_version="$(manifest_get '.charts.kube-prometheus-stack.version')"

  echo "==> kube-prometheus-stack ${prometheus_chart_version} (Helm)"
  echo "    Это самый долгий шаг — чарт большой (Prometheus, Alertmanager, Grafana,"
  echo "    kube-state-metrics, node-exporter, admission-webhook job). На обычном"
  echo "    канале несколько минут — НЕ спешите прерывать Ctrl+C, если кажется,"
  echo "    что зависло: прерванный helm upgrade оставляет релиз в состоянии"
  echo "    'pending-upgrade', и СЛЕДУЮЩИЙ upgrade сразу упадёт с 'another operation"
  echo "    is in progress' — эта проблема сама себя усугубляет при повторных Ctrl+C."
  ensure_grafana_admin_secret platform
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --version "$prometheus_chart_version" \
    -n platform --create-namespace -f "$repo_root/infra/base/monitoring/kube-prometheus-stack-values.yaml"

  echo
  echo "Проверка: kubectl get pods -n platform | grep monitoring"
  echo "Ожидается: monitoring-grafana, monitoring-kube-prometheus-operator,"
  echo "monitoring-kube-state-metrics, monitoring-prometheus-node-exporter — все Running."
  echo "Также: kubectl get jobs -n platform — admission-create/-patch должны быть Completed,"
  echo "не Running больше пары минут (застрявший Job — известная причина зависаний, см. TROUBLESHOOTING.md)."
}

install_online_components() {
  local repo_root="$1"
  local topology="${2:-standard}"
  install_namespace_and_rabbitmq_operators "$repo_root" || return 1
  install_kong "$repo_root" "$topology" || return 1
  install_monitoring "$repo_root" || return 1
}
