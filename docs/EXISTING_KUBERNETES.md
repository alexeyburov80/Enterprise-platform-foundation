# Профиль existing — Kubernetes уже есть

Для managed-кластера (EKS/GKE/AKS/облачный k8s) или собственного кластера,
поднятого не через k3s этим репозиторием.

## Отличие от single/standard/ha

`--profile existing` — это флаг **"не ставить k3s"**, а не отдельная топология
реплик. Реплики/anti-affinity всё равно берутся из одного из трёх обычных
overlay (`single`/`standard`/`ha`) — какой именно, указывается явно через
`--topology`:

```bash
sudo ./bootstrap.sh --profile existing --topology standard
```

## Что проверяет preflight для этого профиля

Меньше, чем для single/standard/ha — не проверяются systemd, cgroup v2, порты
6443/10250/30080/30443, минимумы CPU/RAM/диска (это всё не наша забота, кластер
уже настроен кем-то другим). Проверяется:
- доступность кластера через текущий `$KUBECONFIG`/`~/.kube/config`
  (`kubectl get nodes` должен отработать) — если недоступен, preflight
  завершится с FAIL с понятным сообщением;
- root не требуется (только доступ к kubectl).

## Что нужно сделать заранее

1. `kubectl config current-context` должен указывать на нужный кластер —
   `bootstrap.sh` использует именно текущий контекст, ничего не переключает
   сам.
2. **StorageClass**: для `--topology ha` в `infra/overlays/ha/kustomization.yaml`
   всё равно нужно вручную заменить `__SET_STORAGECLASS_IN_OVERLAY__` на
   реальный StorageClass вашего кластера (managed k8s почти всегда предоставляет
   свой — `gp2`/`gp3` на EKS, `standard`/`premium-rwo` на GKE/AKS и т.п.) —
   проверьте `kubectl get storageclass` заранее.
3. **Сеть**: Kong по умолчанию — NodePort (30080/30443), что на managed-кластере
   работает, но обычно неоптимально (managed k8s почти всегда имеет нормальный
   облачный LoadBalancer). Чтобы использовать его — примените
   `infra/base/api-gateway/kong-values-cloud-lb.yaml` поверх базовых values (см.
   комментарий в этом файле и [SECURITY.md](./SECURITY.md) про то, почему
   дефолт — именно NodePort, а не LoadBalancer).
4. **NetworkPolicy**: применяется так же, как и на k3s, но **enforcement
   зависит от вашего CNI**. k3s enforces NetworkPolicy из коробки через
   встроенный kube-router-контроллер — на managed/existing кластере нужно
   отдельно убедиться, что ваш CNI (Calico/Cilium/облачный CNI) это умеет.
   Применённые, но не исполняемые NetworkPolicy не дают ошибки — они просто
   ничего не блокируют. Проверьте это до того, как полагаться на них
   в продакшене (см. [SECURITY.md](./SECURITY.md)).
5. RabbitMQ Cluster Operator и Messaging Topology Operator ссылаются на
   `cert-manager.io` — если у вас его ещё нет в кластере, установите отдельно
   ИЛИ используйте тот же путь без cert-manager, что и air-gap-профиль (см.
   `scripts/lib/rabbitmq-webhook-certs.sh`, вызывается автоматически
   `bootstrap.sh` независимо от online/offline — начиная с Phase 3, инкремент 3,
   оба пути ведут себя одинаково, cert-manager не обязателен ни для одного).

## Установка

```bash
sudo ./bootstrap.sh --profile existing --topology standard --skip-preflight
```

(`--skip-preflight` не обязателен — preflight для `existing` и так лёгкий, но
если ваш кластер за VPN/bastion и `curl github.com` изнутри окружения, где вы
запускаете `bootstrap.sh`, недоступен даже с ключом `--offline` не указанным,
`--force` тоже поможет пройти сетевую проверку, если она ложноположительная
именно для вашей сетевой топологии.)

## Диагностика

`./scripts/diagnose.sh` работает одинаково для всех профилей — не зависит от
того, кто поставил Kubernetes. См. [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).
