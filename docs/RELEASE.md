# Release

## Единственный источник версий

`release/manifest.yaml` — версии k3s, kubectl, helm, kustomize, kubeconform,
yamllint, yq, crane, RabbitMQ Cluster/Topology Operator, Kong и
kube-prometheus-stack Helm-чартов, образов `rabbitmq`/`mes-stub`/registry, и
матрица поддерживаемых ОС (`os_support`, с честными флагами `verified`).

**Правило**: если версия чего-либо зафиксирована где-то ещё (в скрипте,
values-файле, CI workflow) — это баг, а не альтернативный источник истины.
Все скрипты читают версии отсюда через `scripts/lib/manifest.sh`
(`manifest_get '.путь.к.полю'`).

## Как обновить версию компонента

1. Правите `release/manifest.yaml`.
2. Прогоняете локально (или в CI) то, что использует эту версию:
   - `kustomize build infra/overlays/{staging,single,standard,ha}` — если
     менялось что-то в `infra/`;
   - `kubeconform` на результат — если появился новый CRD или изменился API;
   - `./infra/airgap/scripts/00-fetch-bundle.sh` — если менялась версия чего-то,
     что попадает в air-gap bundle (проверяет, что URL/тег реально существует).
3. См. [UPGRADE.md](./UPGRADE.md) для применения новой версии на уже
   развёрнутом кластере.

## `platform.version` в манифесте

Версия самой платформы (не путать с версиями компонентов) —
`release/manifest.yaml` → `platform.version`. На сегодня резервов
семантического версионирования (semver-политика breaking/minor/patch именно
для этого репозитория) не установлено отдельным документом — если это нужно
формализовать, начните с добавления `CHANGELOG.md` рядом с этим файлом.

## Что проверяет CI на каждый PR/push (`.github/workflows/ci-cd.yaml`)

| Job | Что делает |
|---|---|
| `lint` | yamllint (`infra/`, `release/manifest.yaml`, workflow-файлы) + shellcheck (все `*.sh` в репозитории) |
| `build` | Собирает `mes-stub` локально, сканирует Trivy (CRITICAL/HIGH fixable — блокирует), пушит в GHCR только на `main` |
| `validate-manifests` | `kustomize build` + `kubeconform` (схема + community CRD-каталог) на всех четырёх overlay: `staging`, `single`, `standard`, `ha` |

Ни один job не использует `latest`/неверсионированный тулинг — версии
kustomize/kubeconform/yq берутся из `release/manifest.yaml` теми же вызовами
`yq eval`, что и в остальных скриптах.

## Сборка air-gap bundle под конкретный релиз

```bash
cd infra/airgap
./scripts/00-fetch-bundle.sh
sha256sum airgap-bundle.tar.gz > airgap-bundle.tar.gz.sha256
```

Публикуйте `airgap-bundle.tar.gz` вместе с его `.sha256` как артефакт релиза —
получатель бандла должен сверить сумму перед распаковкой на изолированном
сервере (см. `infra/airgap/TRANSFER-CHECKLIST.md`).

**Не реализовано в CI автоматически**: сборка и публикация `airgap-bundle.tar.gz`
как GitHub Release asset на тег — сейчас это ручной шаг, выполняемый локально
перед релизом. Если нужна полная автоматизация — добавить отдельный job,
запускаемый по тегу `v*`, который вызывает `00-fetch-bundle.sh` в CI-раннере
(с реальным доступом в сеть) и прикладывает результат к GitHub Release.

## Что считается breaking-изменением для этого репозитория

Не формализовано отдельной политикой на сегодня. Ориентир по аналогии с тем,
что уже сделано в Phase 3: переименование `infra/overlays/*` (было
`offline`/`prod` → стало `single`/`ha`, инкремент 2) — это breaking для любого
внешнего кода/документации, ссылающегося на старые пути, но НЕ breaking для
конечного поведения кластера. Такие изменения стоит явно анонсировать в
описании релиза, даже без формальной semver-политики.
