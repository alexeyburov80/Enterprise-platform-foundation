#!/usr/bin/env bash
# scripts/lib/k3s-stage.sh
#
# Общая логика "определить, есть ли уже k3s, иначе поставить" — вынесена
# в библиотеку (не просто в scripts/stages/03-k3s.sh как отдельный скрипт),
# потому что она делает `export KUBECONFIG=...`, а экспорт из дочернего
# процесса не долетает до вызвавшего его bootstrap.sh. Функция вызывается
# ЛИБО из bootstrap.sh (source + вызов в том же процессе — экспорт остаётся
# в силе для всех следующих шагов bootstrap.sh), ЛИБО из
# scripts/stages/03-k3s.sh для ручного пошагового запуска (там KUBECONFIG
# либо уже фиксированный путь /etc/rancher/k3s/k3s.yaml, который следующая
# стадия просто продублирует у себя, либо профиль existing, где k3s не
# устанавливается вовсе).
#
# Использование:
#   source scripts/lib/k3s-stage.sh
#   k3s_detect_or_install "$REPO_ROOT" "$PROFILE" "$OFFLINE"

k3s_detect_or_install() {
  local repo_root="$1" profile="$2" offline="$3"

  if [ "$profile" = "existing" ]; then
    echo "    profile=existing — k3s не устанавливается, используется уже настроенный kubectl-контекст"
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    return 0
  fi

  # Проверяем и обычный $KUBECONFIG/~/.kube/config (кластер, поднятый не
  # этим installer'ом), И штатный путь k3s (/etc/rancher/k3s/k3s.yaml) —
  # раньше проверялся только первый вариант, из-за чего повторный запуск
  # ПОСЛЕ уже успешной установки k3s этим же bootstrap.sh не находил его
  # (обычный `kubectl` без KUBECONFIG смотрит на localhost:8080, которого
  # никогда не существует — k3s слушает на :6443) и пытался ставить k3s
  # заново поверх уже работающего.
  local k3s_kubeconfig="/etc/rancher/k3s/k3s.yaml"
  if kubectl get nodes >/dev/null 2>&1; then
    echo "    ⚠ kubectl уже видит работающий кластер — пропускаю установку k3s."
    echo "      Если это не тот кластер, который вы ожидали, прервите (Ctrl+C) и"
    echo "      разберитесь вручную, либо используйте --profile existing."
    return 0
  fi
  if [ -r "$k3s_kubeconfig" ] && KUBECONFIG="$k3s_kubeconfig" kubectl get nodes >/dev/null 2>&1; then
    echo "    ⚠ Обнаружен уже работающий k3s ($k3s_kubeconfig) — пропускаю установку."
    export KUBECONFIG="$k3s_kubeconfig"
    return 0
  fi
  if [ "$offline" = "true" ]; then
    "$repo_root/infra/airgap/scripts/10-install-k3s.sh"
    export KUBECONFIG="$k3s_kubeconfig"
  else
    # shellcheck source=k3s-install-online.sh
    source "$repo_root/scripts/lib/k3s-install-online.sh"
    k3s_install_online   # сама экспортирует KUBECONFIG=/etc/rancher/k3s/k3s.yaml при успехе
  fi
}
