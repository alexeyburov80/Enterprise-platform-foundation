# Фундамент ИТ-архитектуры предприятия

Практический старт по разделу 6.1 ТЗ: k8s-кластер, RabbitMQ, API Gateway, мониторинг,
CI/CD и пример модуля-заглушки, демонстрирующий паттерн «MVP + стаб» (принцип 6 ТЗ).

## Структура репозитория

```
project/
├── docs/
│   └── ROADMAP.md              # роадмап по разделу 6 ТЗ (фазы, задачи, оценки)
├── infra/
│   ├── base/
│   │   ├── namespace.yaml
│   │   ├── rabbitmq/           # RabbitMQ-кластер (RabbitMQ Cluster Operator) + quorum queues
│   │   ├── api-gateway/        # Kong (declarative, DB-less) — скелет без бизнес-логики
│   │   ├── monitoring/         # values для kube-prometheus-stack + свои алерты
│   │   ├── stub-service/       # пример заглушки-модуля (MES-stub) с Dockerfile
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── staging/            # отдельный staging-контур (принцип отказоустойчивости)
│       └── prod/
├── .github/workflows/ci-cd.yaml
└── scripts/bootstrap.sh        # установка операторов (RabbitMQ, Kong, kube-prometheus-stack)
```

## Что это закрывает из раздела 6.1 ТЗ

| Задача из ТЗ | Где реализовано |
|---|---|
| Базовый k8s-кластер + CI/CD + мониторинг | `scripts/bootstrap.sh`, `.github/workflows/ci-cd.yaml`, `infra/base/monitoring/` |
| Базовый RabbitMQ-кластер + API Gateway (скелет) | `infra/base/rabbitmq/`, `infra/base/api-gateway/` |
| MVP + заглушки (принцип 6) | `infra/base/stub-service/` — пример на модуле MES |
| Отказоустойчивость с самого начала (раздел 5) | quorum queues, PDB + antiaffinity в манифестах, отдельный staging-оверлей |

Реальные модули (SCADA/MES/ERP/CRM/отчётность) и миграция Oracle→PostgreSQL — не входят в
этот стартовый пакет, разворачиваются поверх фундамента по мере готовности (см. `docs/ROADMAP.md`).

## Порядок разворачивания (вариант A: онлайн, managed/self-hosted k8s)

1. Поднять k8s-кластер (минимум 3 узла для профиля `ha`, меньше — для `standard`) любым
   удобным способом (managed или self-hosted) — вне скоупа этого репозитория.
2. `scripts/bootstrap.sh` — установить операторы: RabbitMQ Cluster Operator, Kong, kube-prometheus-stack.
3. `kubectl apply -k infra/overlays/staging` — развернуть фундамент в staging.
4. Убедиться, что RabbitMQ-кластер и Kong отвечают, дашборды Grafana доступны.
5. `kubectl apply -k infra/overlays/standard` (несколько узлов, мягкая anti-affinity) или
   `kubectl apply -k infra/overlays/ha` (3+ узла, гарантированный разъезд реплик) — после
   проверки на staging. `ha` требует явно указать реальный StorageClass в самом overlay
   перед применением — см. комментарий в `infra/overlays/ha/kustomization.yaml`.
6. Дальше — по роадмапу: первый модуль-пилот (см. `docs/ROADMAP.md`).

## Порядок разворачивания (вариант B: с нуля, локально / офлайн-сервер без интернета)

Отдельный контур `infra/airgap/` — тот же результат, что в варианте A, но без единого
`helm repo add` или `kubectl apply -f https://...` на целевой машине. Подходит и для
локального теста прямо сейчас, и для последующего переноса на изолированный сервер.
Подробности и объяснение схемы — в `infra/airgap/README.md`. Коротко:

```
# на машине с интернетом (может быть та же машина, если сеть есть сейчас)
cd infra/airgap
./scripts/00-fetch-bundle.sh          # → airgap-bundle.tar.gz

# перенести airgap-bundle.tar.gz на целевой сервер (USB/rsync/scp), распаковать рядом
# со скриптами, дальше — уже без интернета:

sudo ./scripts/10-install-k3s.sh      # k3s, 1 узел
sudo ./scripts/20-load-images.sh      # образы в containerd, без registry
./scripts/30-install-operators.sh     # RabbitMQ operator + самоподписанный TLS вебхука
./scripts/40-install-charts.sh        # Kong + kube-prometheus-stack из локальных .tgz
./scripts/90-deploy-app.sh            # сам проект: RabbitMQ-кластер, mes-stub, алерты
```

## Важные допущения (уточнить перед прод-разворачиванием)

- Использован RabbitMQ Cluster Operator и Kong Ingress Controller как готовые open-source
  компоненты (принцип 3 ТЗ — не пишем своё там, где не нужна кастомная логика).
- StorageClass, конкретный managed-провайдер k8s и точные ресурсные лимиты — placeholder-значения,
  требуют подстройки под реальную инфраструктуру.
- PostgreSQL-кластер (Patroni) и сама шина CDC (Debezium) в этот пакет пока не входят —
  добавляются на старте раздела 6.3 (миграция первой БД).
