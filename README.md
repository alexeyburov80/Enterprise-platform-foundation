# Фундамент ИТ-архитектуры предприятия

Практический старт по разделу 6.1 ТЗ: k8s-кластер, RabbitMQ, API Gateway, мониторинг,
CI/CD и пример модуля-заглушки, демонстрирующий паттерн «MVP + стаб» (принцип 6 ТЗ).

## Структура репозитория

```
project/
├── bootstrap.sh                 # единая точка входа: preflight → k3s (если нужно) →
│                                 # операторы/чарты → манифесты платформы, см. `./bootstrap.sh --help`
├── release/
│   └── manifest.yaml            # единственный источник версий всех внешних компонентов
├── docs/
│   ├── INSTALL.md                # с чего начать — выбор профиля, все флаги bootstrap.sh
│   ├── ASTRA_LINUX.md            # статус поддержки (честно: не подтверждено прогоном), ЗПС
│   ├── AIRGAP.md                 # установка без интернета, включая registry.local
│   ├── SINGLE_NODE.md            # профиль single
│   ├── HA.md                     # профили standard/ha, включая ручной join узлов
│   ├── EXISTING_KUBERNETES.md    # профиль existing (managed/свой k8s)
│   ├── UPGRADE.md                # апгрейд компонент за компонентом, откат
│   ├── TROUBLESHOOTING.md        # известные проблемы и как их узнать
│   ├── SECURITY.md               # модель угроз: что покрыто, что нет
│   ├── RELEASE.md                # release/manifest.yaml, что проверяет CI
│   └── ROADMAP.md                # роадмап по разделу 6 ТЗ (фазы, задачи, оценки)
├── scripts/
│   ├── preflight.sh             # проверки системы ДО установки (можно и отдельно)
│   ├── diagnose.sh              # сбор диагностики уже установленной платформы
│   └── lib/                     # общие библиотеки для bootstrap.sh (os-detect, k3s, Helm/операторы)
├── infra/
│   ├── base/
│   │   ├── namespace.yaml
│   │   ├── rabbitmq/           # RabbitMQ-кластер (RabbitMQ Cluster Operator) + quorum queues
│   │   ├── api-gateway/        # Kong (declarative, DB-less) — скелет без бизнес-логики
│   │   ├── monitoring/         # values для kube-prometheus-stack + свои алерты
│   │   ├── stub-service/       # пример заглушки-модуля (MES-stub) с Dockerfile
│   │   └── kustomization.yaml
│   ├── overlays/
│   │   ├── staging/            # отдельный staging-контур (принцип отказоустойчивости)
│   │   ├── single/              # 1 узел (dev/edge/офлайн-сервер)
│   │   ├── standard/            # несколько узлов, мягкая anti-affinity
│   │   └── ha/                  # 3+ узла, гарантированный разъезд реплик
│   └── airgap/                  # сборка/установка офлайн-бандла — см. вариант B ниже
└── .github/workflows/ci-cd.yaml
```

## Что это закрывает из раздела 6.1 ТЗ

| Задача из ТЗ | Где реализовано |
|---|---|
| Базовый k8s-кластер + CI/CD + мониторинг | `bootstrap.sh`, `.github/workflows/ci-cd.yaml`, `infra/base/monitoring/` |
| Базовый RabbitMQ-кластер + API Gateway (скелет) | `infra/base/rabbitmq/`, `infra/base/api-gateway/` |
| MVP + заглушки (принцип 6) | `infra/base/stub-service/` — пример на модуле MES |
| Отказоустойчивость с самого начала (раздел 5) | quorum queues, PDB + antiaffinity в манифестах, отдельный staging-оверлей |
| Универсальность/автономность разворачивания | `bootstrap.sh` (единая точка входа, online+offline), `scripts/preflight.sh`, `release/manifest.yaml` |

Реальные модули (SCADA/MES/ERP/CRM/отчётность) и миграция Oracle→PostgreSQL — не входят в
этот стартовый пакет, разворачиваются поверх фундамента по мере готовности (см. `docs/ROADMAP.md`).

## Документация

Начните с [`docs/INSTALL.md`](./docs/INSTALL.md) — выбор профиля и все флаги
`bootstrap.sh`. Дальше по ситуации: [`SINGLE_NODE.md`](./docs/SINGLE_NODE.md),
[`HA.md`](./docs/HA.md), [`EXISTING_KUBERNETES.md`](./docs/EXISTING_KUBERNETES.md),
[`AIRGAP.md`](./docs/AIRGAP.md) (сервер без интернета),
[`ASTRA_LINUX.md`](./docs/ASTRA_LINUX.md) (если у вас Astra Linux — статус
поддержки там указан честно, включая то, что не проверено). Дальше —
[`UPGRADE.md`](./docs/UPGRADE.md), [`TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md),
[`SECURITY.md`](./docs/SECURITY.md), [`RELEASE.md`](./docs/RELEASE.md).

## Порядок разворачивания

`bootstrap.sh` в корне репозитория — единая точка входа для всех сценариев (online и
offline), см. `./bootstrap.sh --help`. Он сам определяет ОС, прогоняет preflight-проверки
ДО каких-либо изменений системы, ставит k3s при необходимости, затем операторы/чарты и
манифесты платформы под выбранный профиль.

```
# один узел (dev/edge/тест) — самый быстрый способ попробовать
sudo ./bootstrap.sh --profile single

# несколько узлов, обычная прод-установка
sudo ./bootstrap.sh --profile standard

# 3+ узла, критичная установка (сначала отредактируйте
# infra/overlays/ha/kustomization.yaml — укажите реальный StorageClass)
sudo ./bootstrap.sh --profile ha

# кластер уже существует и управляется отдельно — k3s не ставится,
# но нужно явно сказать, под какую топологию разворачивать манифесты
./bootstrap.sh --profile existing --topology standard
```

Промежуточная проверка на staging перед `standard`/`ha` — по желанию:
`kubectl apply -k infra/overlays/staging`.

## Офлайн-разворачивание (сервер без интернета)

Тот же `bootstrap.sh`, но с флагом `--offline` и заранее собранным бандлом — без единого
`helm repo add` или `kubectl apply -f https://...` на целевой машине. Подробности и
объяснение схемы — в `infra/airgap/README.md`. Коротко:

```
# на машине с интернетом (может быть та же машина, если сеть есть сейчас)
./infra/airgap/scripts/00-fetch-bundle.sh   # → infra/airgap/airgap-bundle.tar.gz
                                              # (версии — из release/manifest.yaml)

# перенести airgap-bundle.tar.gz на целевой сервер (USB/rsync/scp), дальше — без интернета:
sudo ./bootstrap.sh --profile single --offline --bundle infra/airgap/airgap-bundle.tar.gz
```

## Важные допущения (уточнить перед прод-разворачиванием)

- Использован RabbitMQ Cluster Operator и Kong Ingress Controller как готовые open-source
  компоненты (принцип 3 ТЗ — не пишем своё там, где не нужна кастомная логика).
- StorageClass: `single`/`standard` используют рабочий дефолт `local-path` (k3s
  из коробки); `ha` — нет, там нужно явно указать реальный StorageClass перед
  применением (см. [`docs/HA.md`](./docs/HA.md)). Управляемый провайдер k8s и
  точные ресурсные лимиты (`ResourceQuota` в `infra/base/namespace.yaml`,
  сейчас единая для всех профилей) — по-прежнему требуют подстройки под
  реальную инфраструктуру.
- PostgreSQL-кластер (Patroni) и сама шина CDC (Debezium) в этот пакет пока не входят —
  добавляются на старте раздела 6.3 (миграция первой БД).
