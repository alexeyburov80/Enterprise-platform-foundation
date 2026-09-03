#!/usr/bin/env bash
# scripts/lib/rabbitmq-webhook-certs.sh
#
# Оба официальных манифеста RabbitMQ (Cluster Operator и Messaging Topology
# Operator) по умолчанию ссылаются на cert-manager.io Certificate/Issuer для
# TLS вебхука. Вместо того чтобы тянуть cert-manager как ещё одну внешнюю
# зависимость (лишний online-компонент, отсутствующий в air-gap бандле),
# сертификаты генерируются локально через openssl — один и тот же код
# используется и в online, и в offline установке (Phase 3, инкремент 3:
# раньше online-путь требовал cert-manager, offline — нет, это было двумя
# разными путями с разным поведением одного и того же оператора).
#
# Используется из:
#   - infra/airgap/scripts/30-install-operators.sh (offline)
#   - scripts/lib/install-online-components.sh (online)

# $1 = имя сервиса (для CN/SAN), $2 = имя секрета, $3 = namespace,
# $4 = включить ключ ca.crt в секрет (yes/no, нужно для metrics-server-cert)
rabbitmq_gen_cert() {
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

# $1 = kind (validatingwebhookconfigurations|mutatingwebhookconfigurations),
# $2 = подстрока для фильтрации имени, $3 = base64 CA bundle
rabbitmq_patch_cabundle() {
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

# Полный флоу установки обоих операторов с самоподписанными сертификатами.
# $1 = путь/URL манифеста Cluster Operator
# $2 = путь/URL манифеста Messaging Topology Operator (вариант БЕЗ cert-manager)
rabbitmq_install_operators_with_selfsigned_certs() {
  local cluster_operator_src="$1"
  local topology_operator_src="$2"
  local ns="rabbitmq-system"

  echo "==> [1/4] Cluster Operator: применяем манифест (Certificate/Issuer ожидаемо упадут — это нормально)"
  kubectl apply -f "$cluster_operator_src" 2>&1 | grep -v "cert-manager.io/v1" || true

  echo "==> [2/4] Cluster Operator: генерируем сертификат вебхука и патчим caBundle"
  kubectl wait --for=condition=Established crd/rabbitmqclusters.rabbitmq.com --timeout=60s >/dev/null 2>&1 || true
  for i in $(seq 1 20); do kubectl get svc cluster-operator-webhook-service -n "$ns" >/dev/null 2>&1 && break; sleep 3; done

  local ca1
  ca1="$(rabbitmq_gen_cert cluster-operator-webhook-service cluster-operator-webhook-server-cert "$ns" no)" \
    || { echo "Не удалось создать сертификат Cluster Operator — прерываю"; return 1; }
  rabbitmq_patch_cabundle validatingwebhookconfigurations cluster-operator "$ca1"
  rabbitmq_patch_cabundle mutatingwebhookconfigurations cluster-operator "$ca1"
  kubectl rollout restart deployment/rabbitmq-cluster-operator -n "$ns" >/dev/null 2>&1 || true

  echo "==> [3/4] Messaging Topology Operator: применяем манифест (Certificate/Issuer ожидаемо упадут)"
  kubectl apply -f "$topology_operator_src" 2>&1 | grep -v "cert-manager.io/v1" || true

  echo "==> [4/4] Messaging Topology Operator: сертификаты вебхука и метрик + caBundle"
  for i in $(seq 1 20); do kubectl get svc messaging-topology-webhook-service -n "$ns" >/dev/null 2>&1 && break; sleep 3; done

  local ca2
  ca2="$(rabbitmq_gen_cert messaging-topology-webhook-service webhook-server-cert "$ns" no)" \
    || { echo "Не удалось создать сертификат вебхука Messaging Topology Operator — прерываю"; return 1; }
  rabbitmq_gen_cert messaging-topology-controller-metrics-service metrics-server-cert "$ns" yes >/dev/null \
    || { echo "Не удалось создать сертификат метрик Messaging Topology Operator — прерываю"; return 1; }
  rabbitmq_patch_cabundle validatingwebhookconfigurations messaging-topology "$ca2"
  rabbitmq_patch_cabundle mutatingwebhookconfigurations messaging-topology "$ca2"
  kubectl rollout restart deployment/messaging-topology-operator -n "$ns" >/dev/null 2>&1 || true

  echo "==> Ждём, что оба оператора реально поднялись"
  kubectl rollout status deployment/rabbitmq-cluster-operator -n "$ns" --timeout=3m
  kubectl rollout status deployment/messaging-topology-operator -n "$ns" --timeout=3m

  echo "==> Готово: RabbitMQ Cluster Operator + Messaging Topology Operator установлены (самоподписанные сертификаты, без cert-manager)."
}
