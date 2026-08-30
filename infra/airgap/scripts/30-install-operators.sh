#!/usr/bin/env bash
set -uo pipefail   # без -e: apply манифестов частично "падает" на Certificate/Issuer — это ожидаемо
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$HERE/airgap-bundle"
NS="rabbitmq-system"

# Оба официальных манифеста RabbitMQ (Cluster Operator и Messaging Topology
# Operator) ссылаются на cert-manager.io Certificate/Issuer для TLS вебхука —
# офлайн cert-manager разворачивать не будем, вместо этого генерируем
# сертификаты сами через openssl (конфиг-файл вместо -addext — надёжнее
# между разными версиями openssl) и кладём их в секреты с именами,
# которые ожидают манифесты.

gen_cert() {
  # $1 = имя сервиса (для CN/SAN), $2 = имя секрета, $3 = namespace,
  # $4 = включить ключ ca.crt в секрет (yes/no, нужно для metrics-server-cert)
  local svc="$1" secret="$2" ns="$3" with_ca="${4:-no}"
  local tmp; tmp="$(mktemp -d)"

  cat > "$tmp/san.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = rabbitmq-operator-webhook
[ext]
subjectAltName = @alt
[alt]
DNS.1 = ${svc}.${ns}.svc
DNS.2 = ${svc}.${ns}.svc.cluster.local
CNF

  if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
      -config "$tmp/san.cnf" >"$tmp/openssl.log" 2>&1; then
    echo "    !! openssl не смог создать сертификат для ${svc}:" >&2
    cat "$tmp/openssl.log" >&2
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -s "$tmp/tls.crt" ]; then
    echo "    !! tls.crt пустой/не создан для ${svc}, лог openssl:" >&2
    cat "$tmp/openssl.log" >&2
    rm -rf "$tmp"
    return 1
  fi

  local apply_ok=1
  if [ "$with_ca" = "yes" ]; then
    kubectl create secret generic "$secret" -n "$ns" \
      --from-file=tls.crt="$tmp/tls.crt" --from-file=tls.key="$tmp/tls.key" \
      --from-file=ca.crt="$tmp/tls.crt" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>"$tmp/kubectl.log" || apply_ok=0
  else
    kubectl create secret tls "$secret" -n "$ns" \
      --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>"$tmp/kubectl.log" || apply_ok=0
  fi

  if [ "$apply_ok" -ne 1 ]; then
    echo "    !! не удалось создать секрет $secret:" >&2
    cat "$tmp/kubectl.log" >&2
    rm -rf "$tmp"
    return 1
  fi

  base64 -w0 < "$tmp/tls.crt"
  rm -rf "$tmp"
}

patch_cabundle() {
  local kind="$1" filter="$2" cabundle="$3"
  for wh in $(kubectl get "$kind" -o name | grep "$filter" || true); do
    local count
    count=$(kubectl get "$wh" -o jsonpath='{range .webhooks[*]}x{end}' | wc -c)
    if [ "$count" -eq 0 ]; then
      echo "    !! у $wh не найдено записей webhooks[] — пропускаю" >&2
      continue
    fi
    local patch="["
    for ((i = 0; i < count; i++)); do
      patch+="{\"op\":\"replace\",\"path\":\"/webhooks/${i}/clientConfig/caBundle\",\"value\":\"${cabundle}\"},"
    done
    patch="${patch%,}]"
    kubectl patch "$wh" --type=json -p="$patch" >/dev/null
    echo "    caBundle обновлён (${count} записей в webhooks[]): $wh"
  done
}

echo "==> [1/4] Cluster Operator: применяем манифест (Certificate/Issuer ожидаемо упадут — это нормально)"
kubectl apply -f "$BUNDLE/manifests/cluster-operator.yml" 2>&1 | grep -v "cert-manager.io/v1" || true

echo "==> [2/4] Cluster Operator: генерируем сертификат вебхука и патчим caBundle"
kubectl wait --for=condition=Established crd/rabbitmqclusters.rabbitmq.com --timeout=60s >/dev/null 2>&1 || true
for i in $(seq 1 20); do kubectl get svc cluster-operator-webhook-service -n "$NS" >/dev/null 2>&1 && break; sleep 3; done

CA1="$(gen_cert cluster-operator-webhook-service cluster-operator-webhook-server-cert "$NS" no)" \
  || { echo "Не удалось создать сертификат Cluster Operator — прерываю"; exit 1; }
patch_cabundle validatingwebhookconfigurations cluster-operator "$CA1"
patch_cabundle mutatingwebhookconfigurations cluster-operator "$CA1"
kubectl rollout restart deployment/rabbitmq-cluster-operator -n "$NS" >/dev/null 2>&1 || true

echo "==> [3/4] Messaging Topology Operator: применяем манифест (Certificate/Issuer ожидаемо упадут)"
kubectl apply -f "$BUNDLE/manifests/messaging-topology-operator.yaml" 2>&1 | grep -v "cert-manager.io/v1" || true

echo "==> [4/4] Messaging Topology Operator: сертификаты вебхука и метрик + caBundle"
for i in $(seq 1 20); do kubectl get svc messaging-topology-webhook-service -n "$NS" >/dev/null 2>&1 && break; sleep 3; done

CA2="$(gen_cert messaging-topology-webhook-service webhook-server-cert "$NS" no)" \
  || { echo "Не удалось создать сертификат вебхука Messaging Topology Operator — прерываю"; exit 1; }
gen_cert messaging-topology-controller-metrics-service metrics-server-cert "$NS" yes >/dev/null \
  || { echo "Не удалось создать сертификат метрик Messaging Topology Operator — прерываю"; exit 1; }
patch_cabundle validatingwebhookconfigurations messaging-topology "$CA2"
patch_cabundle mutatingwebhookconfigurations messaging-topology "$CA2"
kubectl rollout restart deployment/messaging-topology-operator -n "$NS" >/dev/null 2>&1 || true

echo "==> Ждём, что оба оператора реально поднялись"
kubectl rollout status deployment/rabbitmq-cluster-operator -n "$NS" --timeout=3m
kubectl rollout status deployment/messaging-topology-operator -n "$NS" --timeout=3m

echo "==> Готово: RabbitMQ Cluster Operator + Messaging Topology Operator установлены офлайн."
