#!/usr/bin/env bash
# scripts/preflight.sh
#
# Проверяет систему ДО того, как installer начнёт её менять (ставить systemd
# unit, писать в /var/lib/rancher, /usr/local/bin и т.п.) — Phase 1 аудит,
# находка H9. Можно запускать как отдельно (для диагностики "подойдёт ли
# этот сервер"), так и автоматически из корневого bootstrap.sh перед
# установкой.
#
# Использование:
#   sudo ./scripts/preflight.sh --profile single [--offline] [--force]
#
# Коды выхода: 0 — можно продолжать (могут быть WARN), 1 — есть FAIL,
# продолжать не стоит (--force это подавляет, но тогда ответственность на
# операторе — тут этот флаг не переопределяет ничего в самой системе, только
# решение "продолжать ли установку").

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/os-detect.sh
source "$REPO_ROOT/scripts/lib/os-detect.sh"

PROFILE="standard"
OFFLINE="false"
FORCE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --offline) OFFLINE="true"; shift ;;
    --force) FORCE="true"; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

case "$PROFILE" in
  single|standard|ha|existing) ;;
  *) echo "Некорректный --profile: $PROFILE (ожидается single|standard|ha|existing)" >&2; exit 2 ;;
esac

# ── Накопление результатов ──────────────────────────────────────────────
# Каждая проверка добавляет строку "СТАТУС|имя|сообщение" в этот массив,
# итоговый отчёт и exit code формируются один раз в конце — чтобы оператор
# видел ВСЕ проблемы сразу, а не только первую (в отличие от `set -e`
# внутри самих проверок, который остановил бы скрипт на первой же).
RESULTS=()
add_result() { RESULTS+=("$1|$2|$3"); }

echo "== Preflight: профиль=${PROFILE} offline=${OFFLINE} =="
echo

# ── 1. Права ────────────────────────────────────────────────────────────
if [ "$PROFILE" = "existing" ]; then
  if [ "$EUID" -eq 0 ]; then
    add_result WARN "root" "Запущено от root, но профиль 'existing' обычно этого не требует (нужен только доступ через kubectl)"
  else
    add_result PASS "root" "root не требуется для профиля existing"
  fi
else
  if [ "$EUID" -eq 0 ]; then
    add_result PASS "root" "запущено от root (нужно для установки k3s как systemd-сервиса)"
  else
    add_result FAIL "root" "профиль '$PROFILE' устанавливает k3s как системный сервис — запустите с sudo"
  fi
fi

# ── 2. ОС и совместимость ──────────────────────────────────────────────
if os_detect; then
  echo "-- Определение ОС:"
  support_status="$(os_check_support)"
  case "$support_status" in
    verified)
      add_result PASS "os" "${OS_PRETTY_NAME} — проверенная версия (release/manifest.yaml)"
      ;;
    unverified)
      add_result WARN "os" "${OS_PRETTY_NAME} — версия заявлена в manifest, но не подтверждена реальным прогоном (verified: false)"
      ;;
    unknown|*)
      add_result WARN "os" "${OS_PRETTY_NAME:-неизвестная ОС} — не значится в release/manifest.yaml вообще"
      ;;
  esac
  echo
else
  add_result FAIL "os" "не удалось прочитать /etc/os-release — это Linux-хост?"
fi

# ── 2b. Astra Linux — отдельная проверка ЗПС ───────────────────────────
if [ "${OS_ID:-}" = "astra" ]; then
  echo "-- Astra Linux: проверка замкнутой программной среды (ЗПС):"
  os_check_astra_zps
  add_result WARN "astra-zps" "проверьте вывод выше вручную — эта проверка best-effort (см. docs/ASTRA_LINUX.md)"
  echo
fi

# ── 3. systemd / cgroups v2 (не нужны для profile=existing — k3s не ставим) ──
if [ "$PROFILE" != "existing" ]; then
  if os_has_systemd; then
    add_result PASS "systemd" "обнаружен /run/systemd/system"
  else
    add_result FAIL "systemd" "не обнаружен — k3s ставится как systemd-сервис, без systemd installer не сработает"
  fi

  if os_has_cgroup_v2; then
    add_result PASS "cgroup-v2" "обнаружен /sys/fs/cgroup/cgroup.controllers"
  else
    add_result FAIL "cgroup-v2" "не обнаружен — начиная с containerd, который использует k3s, cgroup v2 обязателен. Если вы видите это ВНУТРИ контейнера/песочницы (не на реальном сервере) — это ожидаемо и не относится к целевому серверу"
  fi
fi

# ── 4. Ресурсы (минимумы по профилю; ha — это ТРЕБОВАНИЯ К УЗЛУ, не к сумме кластера) ──
case "$PROFILE" in
  single)   MIN_CPU=2;  MIN_MEM_GB=4;  MIN_DISK_GB=20 ;;
  standard) MIN_CPU=2;  MIN_MEM_GB=8;  MIN_DISK_GB=20 ;;
  ha)       MIN_CPU=4;  MIN_MEM_GB=16; MIN_DISK_GB=40 ;;
  existing) MIN_CPU=0;  MIN_MEM_GB=0;  MIN_DISK_GB=0 ;;
esac

if [ "$PROFILE" != "existing" ]; then
  cpu_count="$(nproc 2>/dev/null || echo 0)"
  if [ "$cpu_count" -ge "$MIN_CPU" ]; then
    add_result PASS "cpu" "${cpu_count} ядер (минимум для '${PROFILE}': ${MIN_CPU})"
  else
    add_result WARN "cpu" "${cpu_count} ядер — меньше рекомендованного минимума (${MIN_CPU}) для профиля '${PROFILE}'"
  fi

  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_gb=$((mem_kb / 1024 / 1024))
  if [ "$mem_gb" -ge "$MIN_MEM_GB" ]; then
    add_result PASS "memory" "~${mem_gb}Gi RAM (минимум для '${PROFILE}': ${MIN_MEM_GB}Gi)"
  else
    add_result WARN "memory" "~${mem_gb}Gi RAM — меньше рекомендованного минимума (${MIN_MEM_GB}Gi) для профиля '${PROFILE}'"
  fi

  disk_avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
  disk_avail_gb=$((disk_avail_kb / 1024 / 1024))
  if [ "$disk_avail_gb" -ge "$MIN_DISK_GB" ]; then
    add_result PASS "disk" "~${disk_avail_gb}Gi свободно на / (минимум для '${PROFILE}': ${MIN_DISK_GB}Gi)"
  else
    add_result WARN "disk" "~${disk_avail_gb}Gi свободно на / — меньше рекомендованного минимума (${MIN_DISK_GB}Gi)"
  fi
fi

# ── 5. Существующий кластер (детект для подсказки "может вам нужен --profile existing") ──
existing_kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
if [ -r "$existing_kubeconfig" ] && command -v kubectl >/dev/null 2>&1; then
  if KUBECONFIG="$existing_kubeconfig" kubectl get nodes >/dev/null 2>&1; then
    if [ "$PROFILE" = "existing" ]; then
      add_result PASS "existing-cluster" "обнаружен доступный кластер через $existing_kubeconfig — соответствует профилю 'existing'"
    else
      add_result WARN "existing-cluster" "обнаружен уже доступный кластер через $existing_kubeconfig, но выбран профиль '$PROFILE' — installer попытается поставить ЕЩЁ ОДИН k3s. Если это не то, что вы хотите — перезапустите с --profile existing"
    fi
  elif [ "$PROFILE" = "existing" ]; then
    add_result FAIL "existing-cluster" "профиль 'existing' выбран, но кластер через $existing_kubeconfig недоступен (kubectl get nodes упал)"
  fi
elif [ "$PROFILE" = "existing" ]; then
  add_result FAIL "existing-cluster" "профиль 'existing' выбран, но kubectl не найден или $existing_kubeconfig недоступен"
fi

# ── 6. Порты (пропускаем для existing — топология сети не под нашим контролем) ──
if [ "$PROFILE" != "existing" ]; then
  for port_desc in "6443:k3s API server" "10250:kubelet" "30080:Kong NodePort HTTP" "30443:Kong NodePort HTTPS"; do
    port="${port_desc%%:*}"
    desc="${port_desc#*:}"
    if command -v ss >/dev/null 2>&1; then
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"; then
        add_result WARN "port-${port}" "порт ${port} (${desc}) уже занят — установка может не запуститься"
      else
        add_result PASS "port-${port}" "порт ${port} (${desc}) свободен"
      fi
    else
      add_result WARN "port-${port}" "команда 'ss' недоступна — не удалось проверить порт ${port} (${desc}) автоматически"
    fi
  done
fi

# ── 7. Инструменты и сеть в зависимости от online/offline ─────────────
for bin in tar curl; do
  if command -v "$bin" >/dev/null 2>&1; then
    add_result PASS "bin-${bin}" "найден"
  else
    add_result FAIL "bin-${bin}" "не найден в PATH"
  fi
done

if [ "$OFFLINE" = "true" ]; then
  add_result PASS "network" "offline-режим — доступ в интернет не требуется и не проверяется"
else
  if curl -fsSL -o /dev/null --max-time 5 "https://github.com" 2>/dev/null; then
    add_result PASS "network" "github.com доступен (нужен для online-установки k3s/операторов/чартов)"
  else
    add_result FAIL "network" "нет доступа к github.com за 5 секунд — для online-установки нужен интернет, либо запустите с --offline и подготовленным bundle"
  fi
fi

# ── Итог ────────────────────────────────────────────────────────────────
echo
echo "== Итог preflight =="
fail_count=0
warn_count=0
for r in "${RESULTS[@]}"; do
  status="${r%%|*}"
  rest="${r#*|}"
  name="${rest%%|*}"
  msg="${rest#*|}"
  case "$status" in
    PASS) printf "  [OK]   %-18s %s\n" "$name" "$msg" ;;
    WARN) printf "  [WARN] %-18s %s\n" "$name" "$msg"; warn_count=$((warn_count + 1)) ;;
    FAIL) printf "  [FAIL] %-18s %s\n" "$name" "$msg"; fail_count=$((fail_count + 1)) ;;
  esac
done

echo
echo "PASS/WARN/FAIL: $(( ${#RESULTS[@]} - fail_count - warn_count ))/${warn_count}/${fail_count}"

if [ "$fail_count" -gt 0 ]; then
  if [ "$FORCE" = "true" ]; then
    echo "Есть FAIL-проверки, но передан --force — продолжаем на ваш страх и риск."
    exit 0
  fi
  echo "Есть FAIL-проверки — установка остановлена ДО каких-либо изменений системы."
  echo "Исправьте проблемы выше или перезапустите с --force, если уверены, что это ложное срабатывание."
  exit 1
fi

echo "Preflight пройден. Можно продолжать установку."
