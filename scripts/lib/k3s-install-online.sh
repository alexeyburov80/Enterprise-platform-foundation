#!/usr/bin/env bash
# scripts/lib/k3s-install-online.sh
#
# Устанавливает k3s на хосте с доступом в интернет. Отдельно от
# infra/airgap/scripts/10-install-k3s.sh (тот ставит из уже распакованного
# офлайн-бандла, бинарники не скачивает).
#
# Использование:
#   source scripts/lib/manifest.sh
#   source scripts/lib/k3s-install-online.sh
#   k3s_install_online
#
# Пин версии: используется https://raw.githubusercontent.com/k3s-io/k3s/<version>/install.sh
# (скрипт, зафиксированный на конкретном git-теге релиза), а НЕ вечно
# актуальный https://get.k3s.io — тот всегда отдаёт последнюю версию своего
# кода независимо от INSTALL_K3S_VERSION, что для installer'а, который
# обещает воспроизводимость (release/manifest.yaml), не годится (тот же
# класс проблемы, что и C1/C2/H7 из Phase 1 аудита).
# Сам install.sh при этом всё равно проверяет sha256 скачиваемого бинарника
# k3s против официального релиза — эта проверка остаётся встроенной.

k3s_install_online() {
  local k3s_version
  k3s_version="$(manifest_get '.kubernetes.version')"

  echo "==> Скачиваем install.sh k3s, зафиксированный на версии ${k3s_version}"
  local install_script
  install_script="$(mktemp)"
  trap 'rm -f "$install_script"' RETURN

  # URL-encode "+" в версии тега (v1.30.5+k3s1 -> ...v1.30.5+k3s1, GitHub raw
  # понимает "+" в пути как есть, но на всякий случай печатаем итоговый URL,
  # чтобы при сетевой ошибке было видно, что именно запрашивалось).
  local url="https://raw.githubusercontent.com/k3s-io/k3s/${k3s_version}/install.sh"
  echo "    URL: $url"
  if ! curl -fsSL "$url" -o "$install_script"; then
    echo "Не удалось скачать install.sh для версии ${k3s_version}. Проверьте" >&2
    echo "интернет-соединение или актуальность версии в release/manifest.yaml." >&2
    return 1
  fi

  echo "==> Запускаем install.sh (INSTALL_K3S_VERSION=${k3s_version})"
  # --disable traefik: свой API Gateway (Kong), встроенный traefik не нужен
  #   (тот же выбор, что и в infra/airgap/scripts/10-install-k3s.sh — важно
  #   держать оба пути консистентными).
  # --write-kubeconfig-mode 644: чтобы kubectl работал не только из-под root.
  INSTALL_K3S_VERSION="$k3s_version" \
    INSTALL_K3S_EXEC="server --disable traefik --write-kubeconfig-mode 644" \
    sh "$install_script"

  echo "==> Ждём готовности узла..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local i
  for i in $(seq 1 60); do
    if kubectl get nodes 2>/dev/null | grep -q Ready; then
      echo "    Узел готов."
      kubectl get nodes
      return 0
    fi
    sleep 5
  done

  echo "Узел не перешёл в Ready за 5 минут — проверьте 'systemctl status k3s' и 'journalctl -u k3s'." >&2
  return 1
}
