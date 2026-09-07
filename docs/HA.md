# Профили standard и ha — несколько узлов

## Разница между standard и ha

| | `standard` | `ha` |
|---|---|---|
| Anti-affinity RabbitMQ/mes-stub | мягкая (`preferred` + `topologySpreadConstraints`) | жёсткая (`required`) — гарантированный разъезд по разным узлам |
| Минимум узлов, чтобы под не завис в Pending | 1 (но смысл теряется) | 3+ (по числу реплик RabbitMQ) |
| StorageClass по умолчанию | `local-path` (можно оставить для теста, для прода — замените) | **обязательно** заменить вручную (`infra/overlays/ha/kustomization.yaml` содержит заглушку `__SET_STORAGECLASS_IN_OVERLAY__`, которая специально не резолвится ни во что — PVC будет висеть в Pending, пока не отредактируете) |
| Минимумы preflight | 2 CPU / 8Gi RAM / 20Gi диск на узел | 4 CPU / 16Gi RAM / 40Gi диск на узел |

`ha` не получает безопасный дефолт StorageClass намеренно: `local-path`
привязывает данные к конкретному узлу, что убивает саму идею отказоустойчивости
при потере этого узла — лучше явная остановка на Pending, чем тихая ложная
уверенность в отказоустойчивости.

## Установка (первый control-plane узел)

Online:
```bash
sudo ./bootstrap.sh --profile standard
# или
sudo ./bootstrap.sh --profile ha   # сначала отредактируйте infra/overlays/ha/kustomization.yaml!
```

Offline — см. [AIRGAP.md](./AIRGAP.md), там же — что делает
`infra/airgap/scripts/25-start-registry.sh` для этих профилей.

## Добавление дополнительных узлов — ЧЕСТНО: пока вручную

Этот репозиторий на данный момент **не автоматизирует** присоединение
дополнительных control-plane/worker узлов к кластеру. `bootstrap.sh`
устанавливает k3s только на том узле, на котором его запустили. Чтобы добавить
ещё узлы:

1. Возьмите join-токен с первого узла:
   ```bash
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```
2. **Для offline-установки**: см. [AIRGAP.md](./AIRGAP.md#несколько-узлов-офлайн-профили-standardha) —
   на КАЖДОМ дополнительном узле нужно вручную создать
   `/etc/rancher/k3s/registries.yaml` (с адресом registry первого узла) ДО
   запуска k3s/k3s-agent на нём, иначе он попытается тянуть образы из
   интернета и упадёт.
3. На дополнительном control-plane узле (для `ha`) — используем тот же
   зафиксированный на версии `install.sh`, что и `scripts/lib/k3s-install-online.sh`
   (не `get.k3s.io` — тот всегда отдаёт последнюю версию скрипта независимо от
   `INSTALL_K3S_VERSION`, что ломает воспроизводимость, см. комментарий в этом файле):
   ```bash
   K3S_VERSION="$(yq eval '.kubernetes.version' release/manifest.yaml)"
   curl -fsSL "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh" -o /tmp/install-k3s.sh
   INSTALL_K3S_VERSION="$K3S_VERSION" \
     INSTALL_K3S_EXEC="server --server https://<IP первого узла>:6443 --token <TOKEN> --disable traefik --write-kubeconfig-mode 644" \
     sh /tmp/install-k3s.sh
   ```
   На дополнительном worker-узле (для `standard`/`ha`) — то же самое, но
   `INSTALL_K3S_EXEC="agent --server https://<IP первого узла>:6443 --token <TOKEN>"`.
   (Офлайн-эквивалент — тот же принцип, но бинарник `k3s` и образы берутся из
   перенесённого на этот узел bundle, а не из интернета; отдельного
   автоматизирующего скрипта под это пока нет — см. предупреждение выше.)
4. Проверьте, что узел появился: `kubectl get nodes` — со всех control-plane
   узлов должно быть видно одно и то же.
5. Firewall/security group между узлами — порт 6443 (k3s API), 10250
   (kubelet), при offline ещё и порт registry (по умолчанию 5000).

Планируется автоматизировать этот процесс в одном из следующих инкрементов —
не заявляем это готовым, пока это не так.

## После того как все узлы присоединены

Манифесты платформы применяются один раз, с любого узла с доступом к kubectl:
```bash
kubectl apply -k infra/overlays/standard   # или ha
```
(Если ставили через `bootstrap.sh` изначально — это уже сделано для той
топологии, которую вы выбрали при первом запуске.)

## Диагностика

`./scripts/diagnose.sh` собирает состояние **всех** узлов (`kubectl get nodes -o wide`,
`kubectl describe nodes`) — полезно в первую очередь для многоузловых профилей,
где проблема часто в том, что под не может приземлиться на конкретный узел
(taints, ресурсы, anti-affinity). См. также [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).
