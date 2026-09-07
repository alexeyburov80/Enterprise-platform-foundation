# Профиль single — один узел

Для тестового стенда, демо, edge-сервера или маленькой продуктивной установки на
одном сервере.

## Что отличается от standard/ha

- 1 реплика RabbitMQ, 1 реплика `mes-stub` (см. `infra/overlays/single/kustomization.yaml`) —
  hard pod anti-affinity из `infra/base/` при 1 реплике безвредна (не с кем
  конфликтовать за узел), отдельно её убирать не нужно.
- `storageClassName: local-path` — дефолтный StorageClass k3s, работает из коробки.
- Никакого `registry.local` — `infra/airgap/scripts/20-load-images.sh` (в offline-режиме)
  импортирует образы напрямую в containerd этого же узла, отдельный registry не нужен.
- Минимумы preflight ниже, чем у standard/ha: 2 CPU, 4Gi RAM, 20Gi диска (см.
  `scripts/preflight.sh`) — это рекомендации, не жёсткий предел (WARN, не FAIL при
  недостатке).

## Установка

Online:
```bash
sudo ./bootstrap.sh --profile single
```

Offline — см. [AIRGAP.md](./AIRGAP.md):
```bash
sudo ./bootstrap.sh --profile single --offline --bundle infra/airgap/airgap-bundle.tar.gz
```

## Доступ

Kong снаружи — NodePort на самом сервере: `http://<IP сервера>:30080` (HTTP),
`https://<IP сервера>:30443` (HTTPS). Никакого MetalLB/облачного LoadBalancer не
требуется — это осознанный дефолт (см. [SECURITY.md](./SECURITY.md) и Phase 1
аудит, находка C6: `LoadBalancer` по умолчанию вечно висел бы в `<pending>` на
одиночном сервере без облачного контроллера).

## Когда стоит перейти на standard/ha

Если серверу требуется отказоустойчивость при потере узла — единственная
физическая машина этого дать не может независимо от количества реплик k8s.
Переход на `standard`/`ha` — это уже установка на нескольких серверах, см.
[HA.md](./HA.md).

## Диагностика

`./scripts/diagnose.sh` и [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).
