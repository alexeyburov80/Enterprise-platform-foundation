#!/usr/bin/env bash
# scripts/lib/secrets.sh
#
# Phase 1 аудит, находка H3: раньше пароль Grafana лежал открытым текстом
# в infra/base/monitoring/kube-prometheus-stack-values.yaml (adminPassword:
# "CHANGE_ME") и коммитился в git как есть — легко забыть заменить перед
# прод-разворачиванием.
#
# Теперь values-файл ссылается на существующий Secret (grafana.admin.existingSecret) —
# сам Secret НЕ хранится в git, а создаётся здесь: если его ещё нет в
# кластере, генерируется случайный пароль и создаётся kubectl-ом, значение
# печатается ОДИН РАЗ в конце установки. Если секрет уже существует
# (повторный запуск installer'а/апгрейд) — ничего не трогаем, чтобы не
# сбросить пароль, который оператор уже мог сменить вручную.
#
# Использование:
#   source scripts/lib/secrets.sh
#   ensure_grafana_admin_secret   # печатает пароль в konsole, только если создан впервые

ensure_grafana_admin_secret() {
  local namespace="${1:-platform}"
  local secret_name="grafana-admin-credentials"

  if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    echo "    Secret '$secret_name' уже существует в namespace '$namespace' — не трогаю."
    return 0
  fi

  local password
  password="$(openssl rand -base64 24)"

  kubectl create secret generic "$secret_name" \
    --namespace "$namespace" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$password"

  echo
  echo "    ┌──────────────────────────────────────────────────────────────┐"
  echo "    │ Сгенерирован пароль Grafana admin — сохраните его СЕЙЧАС,     │"
  echo "    │ повторно он нигде не выводится и не хранится в этом выводе:  │"
  echo "    │                                                                │"
  printf "    │   user:     admin%-46s│\n" ""
  printf "    │   password: %-51s│\n" "$password"
  echo "    │                                                                │"
  echo "    │ Посмотреть снова:                                             │"
  echo "    │   kubectl get secret $secret_name -n $namespace \\           │"
  echo "    │     -o jsonpath='{.data.admin-password}' | base64 -d          │"
  echo "    └──────────────────────────────────────────────────────────────┘"
  echo
}
