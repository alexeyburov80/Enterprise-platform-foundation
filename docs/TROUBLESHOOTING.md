# Troubleshooting

Начните с `./scripts/diagnose.sh` — собирает состояние узлов, подов, событий,
PVC/PV, StorageClass, Ingress, NetworkPolicy, Helm-релизов и логи упавших
контейнеров в один файл. Ниже — известные конкретные проблемы и как их узнать.

## PVC RabbitMQ вечно в Pending

```bash
kubectl get pvc -n platform
kubectl describe pvc -n platform <имя>
```

Если в описании `storageClassName` содержит `__SET_STORAGECLASS_IN_OVERLAY__` —
это **ожидаемое** поведение профиля `ha` (см. [HA.md](./HA.md)): base намеренно
не даёт безопасного дефолта, нужно вручную отредактировать
`infra/overlays/ha/kustomization.yaml` перед применением. Для `single`/`standard`
такого быть не должно (там уже `local-path`) — если видите это там, значит
overlay был отредактирован и патч удалили по ошибке.

Если `storageClassName` — что-то другое, но реальное: проверьте, что этот
StorageClass вообще существует в кластере: `kubectl get storageclass`.

## Kong снаружи недоступен

```bash
kubectl get svc -n platform kong-kong-proxy
```

Профиль по умолчанию — `NodePort` (30080/30443), должен быть доступен на
IP любого узла кластера напрямую. Если видите `type: LoadBalancer` и
`EXTERNAL-IP: <pending>` — значит применили
`infra/base/api-gateway/kong-values-cloud-lb.yaml` на кластере без реального
облачного LoadBalancer-контроллера или MetalLB (Phase 1 аудит, находка C6) —
уберите этот values-патч, если это не managed/облачный кластер.

## Grafana — не помню пароль admin

Пароль генерировался один раз при первой установке
(`scripts/lib/secrets.sh`, вызывается автоматически `bootstrap.sh`) и печатался
в консоль только тогда. Посмотреть снова:
```bash
kubectl get secret grafana-admin-credentials -n platform \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

## Поды mes-stub/RabbitMQ не могут достучаться друг до друга

С Phase 3 (инкремент 4) в namespace `platform` включён default-deny
NetworkPolicy — разрешён только конкретный, явно описанный трафик (см.
[SECURITY.md](./SECURITY.md)). Если добавили новый компонент/маршрут и он не
работает:
```bash
kubectl get networkpolicy -n platform
```
Скорее всего, не хватает allow-правила для нового трафика — добавьте по
образцу существующих файлов в `infra/base/network-policy/`, а не отключайте
`default-deny-all` целиком.

**Если NetworkPolicy в принципе ничего не блокирует** (даже там, где должны) —
проверьте, что ваш CNI умеет их исполнять. k3s это делает из коробки
(встроенный kube-router-контроллер), но на профиле `existing` с чужим CNI это
не гарантировано — см. [SECURITY.md](./SECURITY.md) и
[EXISTING_KUBERNETES.md](./EXISTING_KUBERNETES.md).

## preflight падает с FAIL, но кажется, что всё в порядке

Прочитайте сообщение конкретной проверки — preflight печатает причину, не
просто "FAIL". Частые случаи:
- **`cgroup-v2`: FAIL внутри контейнера/песочницы** — ожидаемо, если вы
  тестируете `preflight.sh` не на реальном сервере, а во вложенном контейнере
  (Docker-in-Docker, CI-раннер, LXC без cgroup v2 проброса) — на реальном
  сервере эта проверка должна пройти.
- **`network`: FAIL** — либо действительно нет интернета (тогда используйте
  `--offline`, см. [AIRGAP.md](./AIRGAP.md)), либо интернет есть, но
  `github.com` заблокирован файрволом/прокси конкретно для исходящих с этого
  хоста — проверьте вручную `curl -v https://github.com`.
- Если проверка — заведомо ложное срабатывание для вашего конкретного случая:
  `--force` пропускает FAIL и продолжает установку (на ваш страх и риск), но
  не исправляет саму проблему — используйте только когда действительно уверены.

## Astra Linux — установка блокируется без явной ошибки k3s

Проверьте статус замкнутой программной среды (ЗПС) — см.
[ASTRA_LINUX.md](./ASTRA_LINUX.md). Это самая вероятная причина "бинарник
запускается, но ничего не происходит" именно на Astra.

## Air-gap: образ не найден на дополнительном узле (standard/ha + offline)

Скорее всего, на этом узле не создан `/etc/rancher/k3s/registries.yaml` ДО
запуска k3s/k3s-agent на нём, либо порт registry (по умолчанию 5000) закрыт
файрволом между узлами. См.
[AIRGAP.md](./AIRGAP.md#несколько-узлов-офлайн-профили-standardha) — это
единственный на сегодня НЕавтоматизированный шаг многоузловой офлайн-установки,
не забытая настройка installer'а.

## RabbitMQ Cluster Operator / Messaging Topology Operator — вебхук ошибки

Проверьте, что секреты с TLS-сертификатами для вебхуков были сгенерированы
(`scripts/lib/rabbitmq-webhook-certs.sh` — работает без cert-manager, вызывается
автоматически и для online, и для offline пути):
```bash
kubectl get secret -n rabbitmq-system | grep webhook
```

## Ничего из этого не помогло

Соберите `./scripts/diagnose.sh`, приложите вывод `sudo ./scripts/preflight.sh
--profile <ваш профиль>` целиком (не только последнюю строку) и версию ОС
(`cat /etc/os-release`).
