#!/usr/bin/env bash
# scripts/diagnose.sh
#
# Собирает диагностику уже установленной платформы в один файл — для
# самостоятельной отладки или для передачи вместе с багрепортом
# (Phase 1 аудит, находка H9). НЕ меняет ничего в кластере — только читает.
#
# Использование:
#   ./scripts/diagnose.sh [-n platform] [-o /path/to/output.txt]
#
# Требует настроенный kubectl (KUBECONFIG или ~/.kube/config).

set -uo pipefail
# Осознанно без -e: одна упавшая kubectl-команда (например, если CRD ещё не
# установлен) не должна обрывать сбор остальной диагностики.

NAMESPACE="platform"
OUTPUT="diagnose-$(date +%Y%m%d-%H%M%S).txt"

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl не найден в PATH" >&2
  exit 1
fi

section() {
  {
    echo
    echo "########################################################################"
    echo "## $1"
    echo "########################################################################"
  } >>"$OUTPUT"
}

run() {
  # $1 — заголовок, остальное — сама команда
  local desc="$1"; shift
  {
    echo
    echo "--- ${desc} ($*) ---"
    "$@" 2>&1 || echo "(команда завершилась с ошибкой — см. вывод выше)"
  } >>"$OUTPUT"
}

: >"$OUTPUT"
{
  echo "Enterprise Platform Foundation — diagnose.sh"
  echo "Дата: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Namespace: $NAMESPACE"
} >>"$OUTPUT"

section "Версии клиента/сервера"
run "kubectl version" kubectl version
run "kubectl nodes" kubectl get nodes -o wide

section "Общее состояние namespace '$NAMESPACE'"
run "все ресурсы" kubectl get all -n "$NAMESPACE" -o wide
run "события (последние, по времени)" kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp
run "PVC" kubectl get pvc -n "$NAMESPACE" -o wide
run "StorageClass в кластере" kubectl get storageclass

section "RabbitMQ"
run "RabbitmqCluster CR" kubectl get rabbitmqcluster -n "$NAMESPACE" -o yaml
run "статус StatefulSet" kubectl get statefulset -n "$NAMESPACE" -l app.kubernetes.io/name=platform-rabbitmq -o wide

section "Kong"
run "поды Kong" kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=kong -o wide
run "Ingress" kubectl get ingress -n "$NAMESPACE" -o wide
run "Service kong-proxy (проверить <pending> у EXTERNAL-IP при type=LoadBalancer)" kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=kong

section "mes-stub"
run "поды" kubectl get pods -n "$NAMESPACE" -l app=mes-stub -o wide

section "Мониторинг"
run "поды kube-prometheus-stack" kubectl get pods -n "$NAMESPACE" -l release=monitoring -o wide
run "ServiceMonitor" kubectl get servicemonitor -n "$NAMESPACE"

section "Поды не в Running/Completed — describe + логи"
not_ready_pods="$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -z "$not_ready_pods" ]; then
  echo "(все поды в Running/Succeeded)" >>"$OUTPUT"
else
  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    run "describe $pod" kubectl describe pod "$pod" -n "$NAMESPACE"
    run "логи $pod (текущий контейнер)" kubectl logs "$pod" -n "$NAMESPACE" --tail=100
    run "логи $pod (предыдущий запуск, если был рестарт)" kubectl logs "$pod" -n "$NAMESPACE" --tail=100 --previous
  done <<<"$not_ready_pods"
fi

section "Диск/ресурсы узла (если скрипт выполняется на самом сервере)"
run "df -h" df -h
run "free -h" free -h

echo
echo "Готово: $OUTPUT"
echo "Файл содержит только конфигурацию/статусы/логи из namespace '$NAMESPACE' —"
echo "проверьте перед отправкой третьим лицам, нет ли в логах чувствительных данных."
