#!/usr/bin/env bash
# bootstrap.sh — единая точка входа для установки Enterprise Platform Foundation.
#
# Заменяет два раньше независимых пути (scripts/bootstrap.sh для online +
# ручной набор infra/airgap/scripts/{10..90} для offline) единым скриптом,
# который сам решает, что делать, по профилю и источнику (Phase 1 аудит,
# находка C3; architecture.md, раздел 10).
#
# --usage-start--
# Использование:
#   sudo ./bootstrap.sh --profile single
#   sudo ./bootstrap.sh --profile standard
#   sudo ./bootstrap.sh --profile ha
#   sudo ./bootstrap.sh --profile existing --topology standard   # k3s НЕ ставится
#
#   sudo ./bootstrap.sh --profile single --offline --bundle infra/airgap/airgap-bundle.tar.gz
#
# Флаги:
#   --profile single|standard|ha|existing   (обязателен)
#   --topology single|standard|ha           (нужен только с --profile existing —
#                                            существующий кластер не переустанавливает
#                                            k3s, но манифесты платформы всё равно
#                                            нужно выбрать под нужную топологию)
#   --offline                               источник — офлайн-бандл, не интернет
#   --bundle PATH                           путь к airgap-bundle.tar.gz (с --offline);
#                                            если не задан, ожидается уже распакованный
#                                            infra/airgap/airgap-bundle/
#   --skip-preflight                        не рекомендуется — пропустить проверки
#   --force                                 передать --force в preflight (продолжать
#                                            при WARN/FAIL)
#   -h, --help                              показать это сообщение
# --usage-end--

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '/^# --usage-start--/{flag=1; next} /^# --usage-end--/{flag=0} flag' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

PROFILE=""
TOPOLOGY=""
OFFLINE="false"
BUNDLE_PATH=""
SKIP_PREFLIGHT="false"
FORCE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --topology) TOPOLOGY="$2"; shift 2 ;;
    --offline) OFFLINE="true"; shift ;;
    --bundle) BUNDLE_PATH="$2"; shift 2 ;;
    --skip-preflight) SKIP_PREFLIGHT="true"; shift ;;
    --force) FORCE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$PROFILE" ]; then
  echo "Нужен --profile single|standard|ha|existing" >&2
  usage
  exit 2
fi
case "$PROFILE" in
  single|standard|ha) TOPOLOGY="$PROFILE" ;;
  existing)
    if [ -z "$TOPOLOGY" ]; then
      echo "--profile existing требует --topology single|standard|ha (какие манифесты платформы применять к уже существующему кластеру)" >&2
      exit 2
    fi
    case "$TOPOLOGY" in single|standard|ha) ;; *) echo "Некорректный --topology: $TOPOLOGY" >&2; exit 2 ;; esac
    ;;
  *) echo "Некорректный --profile: $PROFILE (ожидается single|standard|ha|existing)" >&2; exit 2 ;;
esac

echo "══════════════════════════════════════════════════════════════════"
echo " Enterprise Platform Foundation — установка"
echo " profile=${PROFILE} topology=${TOPOLOGY} offline=${OFFLINE}"
echo "══════════════════════════════════════════════════════════════════"
echo

# Бандл распаковывается ЗДЕСЬ, до Шага 1, а не на Шаге 3, как было раньше —
# нашли реальным прогоном: Шаг 1 (определение ОС) уже вызывает manifest_get
# (нужен yq), а на настоящем air-gap сервере без интернета yq неоткуда
# взять, кроме как из самого бандла (scripts/lib/manifest.sh умеет
# автоматически ставить yq по сети, но офлайн так и должно быть невозможно —
# это единственный компонент, который специально не пытается прыгнуть через
# --offline). Распаковывая бандл первым делом и сразу добавляя его bin/ в
# PATH, любой manifest_get дальше по скрипту находит yq локально.
if [ "$OFFLINE" = "true" ]; then
  BUNDLE_DIR="$REPO_ROOT/infra/airgap/airgap-bundle"
  if [ -n "$BUNDLE_PATH" ]; then
    echo "Распаковываю бандл: $BUNDLE_PATH"
    mkdir -p "$REPO_ROOT/infra/airgap"
    tar -xzf "$BUNDLE_PATH" -C "$REPO_ROOT/infra/airgap"
    echo
  fi
  if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Не найден распакованный бандл в $BUNDLE_DIR и не передан --bundle. См. docs/AIRGAP.md." >&2
    exit 1
  fi
  export PATH="$BUNDLE_DIR/bin:$PATH"
fi

# shellcheck source=scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=scripts/lib/os-detect.sh
source "$REPO_ROOT/scripts/lib/os-detect.sh"

echo "── Шаг 1/6: определение ОС ──"
if os_detect; then
  echo "    ${OS_PRETTY_NAME} (id=${OS_ID}, version=${OS_VERSION})"
  os_check_support >/dev/null || true
  if [ "${OS_ID:-}" = "astra" ]; then
    os_check_astra_zps
  fi
else
  echo "    ⚠ не удалось определить ОС (см. вывод выше)" >&2
fi
echo

echo "── Шаг 2/6: preflight ──"
if [ "$SKIP_PREFLIGHT" = "true" ]; then
  echo "    ПРОПУЩЕНО (--skip-preflight) — не рекомендуется, установка может упасть на середине"
else
  preflight_args=(--profile "$PROFILE" )
  [ "$OFFLINE" = "true" ] && preflight_args+=(--offline)
  [ "$FORCE" = "true" ] && preflight_args+=(--force)
  if ! "$REPO_ROOT/scripts/preflight.sh" "${preflight_args[@]}"; then
    echo "Preflight провален — установка остановлена ДО каких-либо изменений системы." >&2
    echo "Перезапустите с --force, если уверены, что это ложное срабатывание, или" >&2
    echo "с --skip-preflight, чтобы пропустить проверки совсем (не рекомендуется)." >&2
    exit 1
  fi
fi
echo

echo "── Шаг 3/6: Kubernetes (k3s) ──"
if [ "$PROFILE" = "existing" ]; then
  echo "    profile=existing — k3s не устанавливается, используется уже настроенный kubectl-контекст"
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
else
  # Проверяем и обычный $KUBECONFIG/~/.kube/config (кластер, поднятый не
  # этим installer'ом), И штатный путь k3s (/etc/rancher/k3s/k3s.yaml) —
  # раньше проверялся только первый вариант, из-за чего повторный запуск
  # ПОСЛЕ уже успешной установки k3s этим же bootstrap.sh не находил его
  # (обычный `kubectl` без KUBECONFIG смотрит на localhost:8080, которого
  # никогда не существует — k3s слушает на :6443) и пытался ставить k3s
  # заново поверх уже работающего.
  #
  # KUBECONFIG принудительно переключается на k3s.yaml ТОЛЬКО в ветках,
  # где речь реально идёт о k3s — если уже была обнаружена рабочая связка
  # через обычный $KUBECONFIG/~/.kube/config (не обязательно k3s), она
  # используется как есть и не перезатирается (это тоже был баг: раньше
  # безусловный export ниже по этому блоку срабатывал в любом случае).
  K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
  if kubectl get nodes >/dev/null 2>&1; then
    echo "    ⚠ kubectl уже видит работающий кластер — пропускаю установку k3s."
    echo "      Если это не тот кластер, который вы ожидали, прервите (Ctrl+C) и"
    echo "      разберитесь вручную, либо используйте --profile existing."
  elif [ -r "$K3S_KUBECONFIG" ] && KUBECONFIG="$K3S_KUBECONFIG" kubectl get nodes >/dev/null 2>&1; then
    echo "    ⚠ Обнаружен уже работающий k3s ($K3S_KUBECONFIG) — пропускаю установку."
    export KUBECONFIG="$K3S_KUBECONFIG"
  elif [ "$OFFLINE" = "true" ]; then
    "$REPO_ROOT/infra/airgap/scripts/10-install-k3s.sh"
    export KUBECONFIG="$K3S_KUBECONFIG"
  else
    # shellcheck source=scripts/lib/k3s-install-online.sh
    source "$REPO_ROOT/scripts/lib/k3s-install-online.sh"
    k3s_install_online   # сама экспортирует KUBECONFIG=/etc/rancher/k3s/k3s.yaml при успехе
  fi
fi
echo

echo "── Шаг 4/6: RabbitMQ-операторы + Kong + kube-prometheus-stack ──"
if [ "$OFFLINE" = "true" ]; then
  "$REPO_ROOT/infra/airgap/scripts/20-load-images.sh"
  if [ "$TOPOLOGY" != "single" ]; then
    # Phase 1 аудит, находка H5: `ctr images import` выше грузит образы
    # ТОЛЬКО в containerd этого узла — на standard/ha нужен доступный с
    # других узлов registry, иначе они не смогут стянуть образы офлайн.
    echo "    Топология '${TOPOLOGY}' — поднимаю локальный registry для остальных узлов кластера"
    "$REPO_ROOT/infra/airgap/scripts/25-start-registry.sh"
  fi
  "$REPO_ROOT/infra/airgap/scripts/30-install-operators.sh"
  "$REPO_ROOT/infra/airgap/scripts/40-install-charts.sh" "$TOPOLOGY"
else
  # shellcheck source=scripts/lib/rabbitmq-webhook-certs.sh
  source "$REPO_ROOT/scripts/lib/rabbitmq-webhook-certs.sh"
  # shellcheck source=scripts/lib/secrets.sh
  source "$REPO_ROOT/scripts/lib/secrets.sh"
  # shellcheck source=scripts/lib/install-online-components.sh
  source "$REPO_ROOT/scripts/lib/install-online-components.sh"
  install_online_components "$REPO_ROOT" "$TOPOLOGY"
fi
echo

echo "── Шаг 5/6: манифесты платформы (kustomize overlays/${TOPOLOGY}) ──"
kubectl apply -k "$REPO_ROOT/infra/overlays/${TOPOLOGY}"
if [ "$TOPOLOGY" = "ha" ]; then
  echo "    ⚠ Профиль 'ha' требует, чтобы вы заранее отредактировали"
  echo "      infra/overlays/ha/kustomization.yaml (реальный StorageClass вместо"
  echo "      __SET_STORAGECLASS_IN_OVERLAY__) — если вы этого не сделали, PVC"
  echo "      RabbitMQ сейчас в Pending. Проверьте: kubectl get pvc -n platform"
fi
echo

echo "── Шаг 6/6: готово ──"
echo "    kubectl get pods -n platform"
echo "    Диагностика при проблемах: ./scripts/diagnose.sh"
if [ "$OFFLINE" != "true" ]; then
  echo "    Kong снаружи: NodePort 30080 (HTTP) / 30443 (HTTPS) на любом узле кластера"
fi
