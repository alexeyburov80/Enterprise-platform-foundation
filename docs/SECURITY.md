# Security

Модель угроз и что конкретно закрывают меры безопасности в этом репозитории —
без общих слов, по каждому механизму отдельно.

## NetworkPolicy

`infra/base/network-policy/` — default-deny (ingress+egress) для всего
namespace `platform`, плюс явные allow-правила только на трафик, который
реально нужен: Kong снаружи (NodePort), Kong → mes-stub, mes-stub ↔ RabbitMQ,
RabbitMQ inter-node кластеризация, messaging-topology-operator (namespace
`rabbitmq-system`) → RabbitMQ management API, Prometheus → RabbitMQ metrics,
Kong ingress-controller → Kubernetes API (`10.43.0.1:443` — дефолтный
`kubernetes.default` ClusterIP в k3s).

**Требует поддержки со стороны CNI.** NetworkPolicy — это только объект API;
исполняет его CNI. k3s поддерживает enforcement из коробки (встроенный
kube-router-контроллер), если явно не отключено флагом
`--disable-network-policy` (наши `scripts/lib/k3s-install-online.sh` и
`infra/airgap/scripts/10-install-k3s.sh` этот флаг не передают). На профиле
`existing` с чужим CNI — **обязательно проверьте отдельно**, поддерживает ли
он NetworkPolicy (Calico/Cilium — да; голый Flannel без доп. контроллера —
нет). Применённые, но не исполняемые NetworkPolicy не выдают ошибку — они
просто ничего не блокируют, создавая ложное чувство защищённости.

**Что НЕ покрыто**: mTLS между сервисами внутри namespace. NetworkPolicy
ограничивает, кто МОЖЕТ установить соединение (L3/L4), но не проверяет
подлинность/шифрует сам трафик между подами. Для среды с недоверенными
соседними подами в том же кластере (multi-tenant) этого недостаточно — нужен
service mesh (вне скоупа этого репозитория).

## securityContext

`infra/base/stub-service/deployment.yaml`: `runAsNonRoot`, конкретный
`runAsUser`/`runAsGroup` (1000 — совпадает с пользователем `node` в базовом
образе `node:20-alpine`, не выбран произвольно), `seccompProfile: RuntimeDefault`,
`capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true` (с отдельным
writable `emptyDir` под `/tmp` — Node.js ожидает туда доступ на запись, даже
если само приложение не пишет файлов).

RabbitMQ и Kong используют securityContext своих официальных
Operator/Helm-чарта — не переопределяются этим репозиторием; если нужно
ужесточить — правьте `infra/base/rabbitmq/rabbitmq-cluster.yaml`
(`spec.override`) или `kong-values.yaml` отдельно, с проверкой, что образ
конкретной версии это выдерживает (например, не требует записи в `/usr/local`).

## Секреты

Пароль Grafana admin **не хранится в git** — генерируется на месте
(`scripts/lib/secrets.sh`, `openssl rand -base64 24`) при первой установке,
печатается один раз, дальше хранится только в Kubernetes Secret
`grafana-admin-credentials`. Повторный запуск/апгрейд не перезаписывает
существующий секрет (не сбросит пароль, если вы его уже сменили вручную).

**Что НЕ реализовано**: шифрование секретов в git (SOPS/sealed-secrets) для
случаев, когда какой-то секрет всё же нужно закоммитить (например,
собственный values-патч с чувствительными данными для конкретного
заказчика) — на сегодня такой практики в репозитории просто нет, а не решена
инструментом. Если появится необходимость — заводите её отдельно, не
коммитьте секреты открытым текстом по аналогии со старым `CHANGE_ME`.

## Образы контейнеров

- `mes-stub`: сканируется Trivy в CI (`.github/workflows/ci-cd.yaml`) на
  CRITICAL/HIGH исправимые уязвимости — сборка падает, если такие найдены.
  RabbitMQ/Kong/Prometheus-стек образы — это то, что приходит с
  официальных Helm-чартов/операторов, отдельно этим репозиторием не
  сканируется (можно добавить `trivy image` вручную по конкретному тегу
  перед прод-развёртыванием, если требуется).
- Все версии/теги зафиксированы в `release/manifest.yaml` — не `latest`
  нигде, включая CI-тулинг (Phase 1 аудит, находки C1/C2/C5/H7).
- `trivy-action` в CI закреплён по конкретному commit SHA, не по тегу —
  после реальной supply-chain атаки на этот action в марте 2026
  (GHSA-69fq-xp46-6x23, компрометация 76 из 77 тегов) тег сам по себе
  недостаточная гарантия неизменности.

## Права/RBAC

Не рассматривается отдельно в этом документе — операторы (RabbitMQ Cluster
Operator, Messaging Topology Operator) ставятся с их официальными
ClusterRole/RoleBinding как есть, без дополнительного ограничения этим
репозиторием. Если ваша организация требует более узкий RBAC — это
отдельная, не решённая здесь задача.

## Что проверить перед продакшеном

- [ ] `kubectl get networkpolicy -n platform` — все 10 объектов на месте,
      и вы убедились, что ваш CNI их реально исполняет (см. выше).
- [ ] StorageClass в `ha`-профиле — не `__SET_STORAGECLASS_IN_OVERLAY__`.
- [ ] Пароль Grafana сохранён в надёжном месте (менеджер паролей, не чат).
- [ ] Если разворачиваете `existing` на managed-кластере — проверили RBAC
      для сервис-аккаунтов операторов на предмет соответствия политике
      организации.
- [ ] Замкнутая программная среда (Astra Linux) — см.
      [ASTRA_LINUX.md](./ASTRA_LINUX.md), если применимо.
