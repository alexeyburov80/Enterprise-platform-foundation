# Развёртывание с нуля на сервере без доступа в интернет

Классическая схема для air-gap: **всё, что требует сети, собирается один раз на машине
с интернетом, затем переносится офлайн-носителем (USB/rsync) на целевой сервер.**
Дальше на целевом сервере интернет не нужен вообще, включая пересборку/рестарты.

Скрипты рассчитаны на **один узел** (то, что вы сейчас тестируете локально), но написаны
так, чтобы тот же bundle и та же схема масштабировались на несколько узлов позже —
тогда меняется только способ установки k3s (server+agents вместо одного server).

## Схема

```
[Машина с интернетом]                         [Офлайн-сервер / текущая локальная машина]
        │                                                    │
        │  ./scripts/00-fetch-bundle.sh                      │
        │  → airgap-bundle.tar.gz                            │
        │                                                     │
        └──── переносим офлайн (USB / rsync / scp) ─────────►│
                                                               │
                                              tar xzf airgap-bundle.tar.gz
                                              ./scripts/10-install-k3s.sh
                                              ./scripts/20-load-images.sh
                                              ./scripts/30-install-operators.sh
                                              ./scripts/40-install-charts.sh
                                              ./scripts/90-deploy-app.sh
```

## Что внутри bundle

```
airgap-bundle/
├── bin/            # k3s, kubectl, helm — статические бинарники
├── images/
│   ├── image-list.txt   # список образов, извлечённый из чартов/манифестов
│   └── blobs/            # по одному tar на образ (docker save) — так проще
│                          # диагностировать, если что-то не докачалось
├── k3s-airgap/     # официальный k3s-airgap-images-*.tar.gz (системные образы k3s)
├── charts/         # kong-*.tgz, kube-prometheus-stack-*.tgz — скачанные Helm-чарты
└── manifests/      # cluster-operator.yml, messaging-topology-operator.yaml
```

## Почему без cert-manager

Официальные манифесты **обоих** RabbitMQ-операторов (Cluster Operator и Messaging
Topology Operator) ссылаются на `cert-manager.io` (`Certificate`/`Issuer`) для TLS
вебхука и метрик. Устанавливать ради этого cert-manager офлайн — лишний образ и
лишняя точка отказа, поэтому `kubectl apply` на эти манифесты частично "падает"
(ожидаемо — сами CRD `cert-manager.io` в кластере не установлены), а секреты с
сертификатами генерируются через `openssl` и подставляются в
`caBundle` ValidatingWebhookConfiguration/MutatingWebhookConfiguration напрямую —
интернет и cert-manager для этого не нужны. Начиная с Phase 3 (инкремент 3) этот же
код (`scripts/lib/rabbitmq-webhook-certs.sh`) используется и в online-установке —
раньше online-путь требовал cert-manager отдельным шагом, теперь оба пути себя
ведут одинаково.

## Что нужно на машине для сборки bundle

- `docker` (только для сборки `mes-stub` и как зависимость `helm`/`skopeo` — сам демон в
  офлайн-кластере не участвует)
- `skopeo` — для скачивания образов из registry (`sudo apt-get install -y skopeo`).
  Обычный `docker pull` + `docker save` в части случаев кладёт в tar ссылки на
  attestation/provenance-манифесты (SBOM), которые `docker pull` не скачивает, а
  `ctr images import` потом падает с `content digest ... not found`. `skopeo copy` тянет
  ровно один платформенный манифест и такой проблемы не создаёт.
- `curl`, `tar`, `openssl` — обычно уже есть в системе

## Порядок запуска

Начиная с Phase 3 (инкремент 3) рекомендуемый способ — единый `bootstrap.sh` в корне
репозитория, который сам вызывает эти же скрипты по порядку и предваряет их preflight-
проверкой:

```
# 1. На машине с интернетом:
./scripts/00-fetch-bundle.sh          # соберёт airgap-bundle.tar.gz рядом со скриптом

# 2. Перенести airgap-bundle.tar.gz на целевой сервер любым офлайн-способом.

# 3. На целевом сервере, из корня репозитория:
sudo ./bootstrap.sh --profile single --offline --bundle infra/airgap/airgap-bundle.tar.gz
```

Пронумерованные скрипты ниже (`10-`…`90-`) остаются рабочими и вызываются
`bootstrap.sh` изнутри — держите этот способ под рукой для пошаговой отладки
(например, чтобы перезапустить только `40-install-charts.sh` после починки образа,
не проходя всё заново):

1. **На машине с интернетом:** `./scripts/00-fetch-bundle.sh` — соберёт
   `airgap-bundle.tar.gz` рядом со скриптом.
2. Перенести `airgap-bundle.tar.gz` на целевой сервер любым офлайн-способом.
3. **На целевом сервере**, распаковав архив в `infra/airgap/`:
   ```
   cd infra/airgap
   sudo ./scripts/10-install-k3s.sh
   sudo ./scripts/20-load-images.sh
   ./scripts/30-install-operators.sh
   ./scripts/40-install-charts.sh
   ./scripts/90-deploy-app.sh
   ```
4. Проверить: `kubectl get pods -n platform` — всё должно подняться без единого
   обращения наружу (можно проверить `iptables`/отключенным интерфейсом на сервере).

## Если тестируете прямо сейчас локально на одной машине с интернетом

Ничего специального делать не нужно — просто выполните шаги 1 и 3 подряд на одной и той
же машине (шаг 2, перенос, пропускается). Это и есть репетиция будущего офлайн-разворачивания:
если всё поднимется через этот bundle-путь, значит на изолированном сервере тоже поднимется.

## Перенос на реальный изолированный сервер

Когда дойдёте до настоящего air-gap сервера (не локальной репетиции) — см.
[`TRANSFER-CHECKLIST.md`](./TRANSFER-CHECKLIST.md): контрольные суммы, проверка "а
действительно ли сеть не используется", порядок действий и что передать эксплуатации.
