# Апгрейд

## Текущий статус: нет отдельного `--upgrade` флага, апгрейд — через повторный apply

`bootstrap.sh` пока не имеет отдельного режима апгрейда (это было в изначальном
плане, но не реализовано в рамках Phase 3 — см. `architecture.md`, инкремент 7
изначально включал этот пункт, по факту приоритет отдан документации того, что
уже есть). То, что описано ниже — рабочий, но ручной путь, не «нажал кнопку —
обновилось».

## Компонент за компонентом

### Версия платформы / состав релиза

Всё, что version-pinned, находится в `release/manifest.yaml`. Апгрейд —
изменить нужную версию там, затем повторить установку соответствующего шага.
Никогда не редактируйте версии в других местах (`kong-values.yaml`,
`kube-prometheus-stack-values.yaml`, скриптах) напрямую — `release/manifest.yaml`
единственный источник истины (Phase 1 аудит, находка C5).

### RabbitMQ Cluster Operator / Messaging Topology Operator

```bash
# 1. Поправить версии в release/manifest.yaml (operators.*)
# 2. Online:
kubectl apply -f "$(yq eval '.operators.rabbitmq_cluster_operator.manifest_url' release/manifest.yaml)"
kubectl apply -f "$(yq eval '.operators.rabbitmq_messaging_topology_operator.manifest_url_with_certmanager' release/manifest.yaml)"
```

⚠️ **Не проверено на реальном кластере в рамках этой работы**: мажорный
апгрейд RabbitMQ Cluster Operator (например, между релизами, меняющими
поведение StatefulSet-обновления) может потребовать внимания к порядку
рестарта реплик. Прочитайте release notes конкретной целевой версии оператора
перед апгрейдом продуктивного кластера — этот репозиторий не гарантирует
безопасность произвольного skip-апгрейда через несколько версий.

### Kong / kube-prometheus-stack (Helm-чарты)

```bash
# 1. Поправить версии в release/manifest.yaml (charts.*)
# 2.
helm upgrade kong kong/kong --version "$(yq eval '.charts.kong.version' release/manifest.yaml)" \
  -n platform -f infra/base/api-gateway/kong-values.yaml
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --version "$(yq eval '.charts.kube-prometheus-stack.version' release/manifest.yaml)" \
  -n platform -f infra/base/monitoring/kube-prometheus-stack-values.yaml
```

Секрет `grafana-admin-credentials` при этом не трогается (`scripts/lib/secrets.sh`
создаёт его только если отсутствует) — существующий пароль Grafana сохранится.

### k3s

```bash
K3S_VERSION="$(yq eval '.kubernetes.version' release/manifest.yaml)"
curl -fsSL "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh" -o /tmp/install-k3s.sh
INSTALL_K3S_VERSION="$K3S_VERSION" sh /tmp/install-k3s.sh
```

Для `standard`/`ha` — повторить на каждом узле кластера отдельно (общего
скрипта для этого пока нет, см. [HA.md](./HA.md) про ручное управление узлами).

### Манифесты платформы (RabbitmqCluster, mes-stub, NetworkPolicy и т.п.)

```bash
kubectl apply -k infra/overlays/<ваш профиль>
```

Обычный `kubectl apply` идемпотентен — безопасно применять повторно даже без
изменений.

## Офлайн-апгрейд

Собрать новый bundle с обновлёнными версиями в `release/manifest.yaml`
(`./infra/airgap/scripts/00-fetch-bundle.sh` на машине с интернетом), перенести
на целевой сервер так же, как при первой установке, и применить нужные шаги
вручную (`20-load-images.sh` для новых образов, затем соответствующий
`helm upgrade`/`kubectl apply` из разделов выше — не весь `bootstrap.sh` заново,
если не хотите пересоздавать уже настроенные компоненты). Единого
`--upgrade`-флага, который делает это автоматически, пока нет — см. начало
этого документа.

## Откат (rollback)

- **Helm-релизы** (Kong, kube-prometheus-stack): `helm rollback <release> <revision>`
  стандартным образом — Helm сам хранит историю.
- **RabbitMQ/Messaging Topology операторы**: применить манифест предыдущей
  версии тем же `kubectl apply -f`, что и апгрейд. Не тестировалось на
  реальном кластере в рамках этой работы — прочитайте release notes оператора,
  которую откатываете.
- **k3s**: `INSTALL_K3S_VERSION=<предыдущая версия>` тем же install.sh — k3s
  явно поддерживает установку конкретной версии поверх текущей.
- **Манифесты платформы**: `git checkout <предыдущий коммит/тег> -- infra/`, затем
  `kubectl apply -k infra/overlays/<профиль>` — сам репозиторий и есть источник
  истины состояния, откат = применить старую версию файлов.

## Диагностика после апгрейда

`./scripts/diagnose.sh` сразу после апгрейда — сравните с состоянием до
(если сохранили предыдущий вывод) на предмет новых рестартов/событий.
