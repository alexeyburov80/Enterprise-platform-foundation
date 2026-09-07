# Установка

Единая точка входа — `bootstrap.sh` в корне репозитория. Он сам определяет ОС,
проверяет систему (`preflight.sh`) и ставит всё нужное — Kubernetes (k3s), RabbitMQ
Operator, Kong, kube-prometheus-stack, манифесты платформы — под выбранный профиль.

## Выбор профиля

| Профиль | Когда использовать | Что ставит |
|---|---|---|
| `single` | Один сервер (тест, demo, edge) | k3s (1 узел), 1 реплика RabbitMQ/mes-stub |
| `standard` | Несколько узлов, обычная эксплуатация | k3s, 3/2 реплики, мягкая anti-affinity |
| `ha` | Критичная нагрузка, 3+ узла | k3s, 3/2 реплики, гарантированный разъезд по узлам |
| `existing` | Kubernetes уже есть (managed или свой) | k3s НЕ ставится, только манифесты платформы |

Подробности по каждому — [SINGLE_NODE.md](./SINGLE_NODE.md), [HA.md](./HA.md),
[EXISTING_KUBERNETES.md](./EXISTING_KUBERNETES.md). Для сервера без интернета —
[AIRGAP.md](./AIRGAP.md). Для Astra Linux — обязательно прочитайте
[ASTRA_LINUX.md](./ASTRA_LINUX.md) до установки.

## Быстрый старт (single, online, Ubuntu/Debian)

```bash
git clone https://github.com/alexeyburov80/Enterprise-platform-foundation.git
cd Enterprise-platform-foundation
sudo ./bootstrap.sh --profile single
```

Это:
1. Определит ОС и сверит с поддерживаемыми (`release/manifest.yaml`).
2. Прогонит `scripts/preflight.sh` — остановится ДО любых изменений системы, если
   найдёт критичные проблемы (недостаточно ресурсов, занятые порты, нет интернета
   и т.п.).
3. Поставит k3s (если ещё не установлен и не обнаружен работающий кластер).
4. Поставит RabbitMQ Cluster Operator + Messaging Topology Operator, Kong,
   kube-prometheus-stack — версии зафиксированы в `release/manifest.yaml`, никакого
   `latest`.
5. Сгенерирует пароль Grafana admin и покажет его один раз в конце — сохраните.
6. Применит манифесты платформы (`kubectl apply -k infra/overlays/single`).

```bash
kubectl get pods -n platform
```

Kong снаружи доступен на NodePort 30080 (HTTP) / 30443 (HTTPS) любого узла — без
дополнительной настройки LoadBalancer/MetalLB (см. [SECURITY.md](./SECURITY.md) и
раздел про сеть ниже, если нужен облачный LoadBalancer).

## Все флаги bootstrap.sh

```
sudo ./bootstrap.sh --profile single
sudo ./bootstrap.sh --profile standard
sudo ./bootstrap.sh --profile ha
sudo ./bootstrap.sh --profile existing --topology standard   # k3s НЕ ставится

sudo ./bootstrap.sh --profile single --offline --bundle infra/airgap/airgap-bundle.tar.gz
```

| Флаг | Значение |
|---|---|
| `--profile single\|standard\|ha\|existing` | обязателен |
| `--topology single\|standard\|ha` | нужен только с `--profile existing` — существующий кластер не переустанавливает k3s, но манифесты платформы всё равно нужно выбрать под нужную топологию |
| `--offline` | источник — офлайн-бандл, не интернет |
| `--bundle PATH` | путь к `airgap-bundle.tar.gz` (с `--offline`); если не задан, ожидается уже распакованный `infra/airgap/airgap-bundle/` |
| `--skip-preflight` | не рекомендуется — пропустить проверки |
| `--force` | передать `--force` в preflight (продолжать при WARN/FAIL) |
| `-h`, `--help` | показать справку |

## Поэтапная установка (по одному шагу с проверками)

`bootstrap.sh` ставит всё одной командой. Если хочется видеть прогресс и
проверять каждый шаг перед следующим (особенно полезно на неподтверждённой
ОС или при первом прогоне вообще) — та же самая установка доступна по
частям через `scripts/stages/{01..07}-*.sh`. Это не сокращённая версия — та
же логика, просто без объединения в одну команду. Подробный пошаговый
разбор с командами проверки на каждом шаге — в
[ASTRA_LINUX.md](./ASTRA_LINUX.md#поэтапная-установка-рекомендуется-для-первого-прогона-на-astra-linux)
(применимо не только к Astra — к любой ОС).

## Если preflight не проходит

`scripts/preflight.sh` можно запустить отдельно, до `bootstrap.sh`, чтобы
продиагностировать сервер заранее:

```bash
sudo ./scripts/preflight.sh --profile single
```

Он проверяет: права, ОС и её статус в `release/manifest.yaml` (verified/unverified/
unknown — см. [ASTRA_LINUX.md](./ASTRA_LINUX.md) про этот статус), systemd, cgroup v2,
CPU/RAM/диск по минимумам профиля, занятость портов (6443, 10250, 30080, 30443),
наличие уже работающего кластера, `curl`/`tar`, доступность интернета (если не
`--offline`). Полный список PASS/WARN/FAIL печатается в конце; при любом FAIL
установка не начинается, пока не исправите или не передадите `--force`.

## После установки

- Диагностика: `./scripts/diagnose.sh` — собирает состояние подов, событий, PVC,
  логи упавших контейнеров в один файл (без секретов).
- Апгрейд компонента — см. [UPGRADE.md](./UPGRADE.md).
- Проблемы — см. [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).
- Модель угроз/что покрыто NetworkPolicy — см. [SECURITY.md](./SECURITY.md).
- Что входит в конкретный релиз и как собрать air-gap bundle под него — см.
  [RELEASE.md](./RELEASE.md).
