# Astra Linux

## Текущий статус: НЕ подтверждено реальным прогоном

`release/manifest.yaml` → `os_support` перечисляет Astra Linux Special Edition
(версии 1.7, 1.8) с полем `verified: false`. Это значит: код (`scripts/lib/os-detect.sh`,
`scripts/preflight.sh`) написан с учётом известных особенностей Astra Linux и
должен работать по документации, но никто не прогонял `preflight.sh`/`bootstrap.sh`
на реальном сервере Astra Linux в рамках этой работы. Не считайте эту страницу
подтверждением совместимости — считайте её чек-листом для первого реального прогона.

Если вы прогнали установку на Astra Linux и она сработала (или не сработала) —
обновите `verified: true`/зафиксируйте проблему в этом файле с версией ОС и k3s,
на которой проверяли.

## Что уже проверяется автоматически (`scripts/preflight.sh`)

- **Определение ОС**: `/etc/os-release` → `ID=astra` — читается через
  `scripts/lib/os-detect.sh`, сверяется со списком `os_support` в
  `release/manifest.yaml`.
- **systemd**: k3s ставится как systemd-сервис — preflight проверяет
  `/run/systemd/system`. Astra Linux (deb-дериватив) использует systemd, здесь
  проблем не ожидается.
- **cgroup v2**: containerd (внутри k3s) требует cgroup v2 —
  проверяется `/sys/fs/cgroup/cgroup.controllers`. Если на вашей сборке Astra
  используется более старое ядро с cgroup v1 по умолчанию — понадобится
  включить cgroup v2 на уровне загрузчика/ядра ДО установки (вне скоупа этого
  репозитория — см. документацию Astra Linux по вашей версии).
- **Замкнутая программная среда (ЗПС) / PARSEC** — см. ниже, отдельный пункт.

## Замкнутая программная среда (ЗПС) — проверьте вручную

Astra Linux использует собственную мандатную модель разграничения доступа
(PARSEC) поверх обычного DAC — это **не** SELinux и **не** AppArmor, отдельный
механизм. Один из режимов — замкнутая программная среда (ЗПС): в этом режиме
запуск непроверенных/неподписанных бинарников может блокироваться политикой
целостности. Это прямо касается установки:

- бинарник `k3s` (скачанный с интернета или распакованный из air-gap bundle),
- бинарники `crane`, `kubectl`, `helm` из air-gap bundle,
- образы контейнеров, распакованные `ctr images import`.

`scripts/lib/os-detect.sh` (`os_check_astra_zps`) пытается определить статус ЗПС
через утилиту `pdpl-control`, если она есть в `PATH`, и печатает её вывод. **Это
best-effort проверка** — у нас нет подтверждённого списка всех возможных
названий/путей этой утилиты на разных версиях Astra, поэтому если утилита не
найдена, preflight честно говорит "не удалось проверить автоматически", а не
делает вид, что всё в порядке.

**Перед установкой вручную проверьте:**
1. Включена ли на сервере ЗПС (спросите у администратора ОС/сверьтесь с
   политикой безопасности организации, если сервер выдан централизованно).
2. Если включена — как для неё зарегистрировать/разрешить исполнение бинарников
   из `/usr/local/bin` (или туда, куда `bootstrap.sh` их ставит) и запуск
   образов контейнеров. Конкретный порядок действий зависит от версии Astra
   и корпоративной политики — обратитесь к документации Astra Linux Special
   Edition по вашей версии или к администратору ОС.

## Пакетный менеджер и репозитории

Astra Linux использует `apt`, но со своими (ФСТЭК-сертифицированными)
репозиториями, а не публичными Ubuntu/Debian зеркалами. `bootstrap.sh` и
`scripts/preflight.sh` **не** ставят системные пакеты через `apt` сами.
Два внешних инструмента, `yq` и `helm`, устанавливаются installer'ом
автоматически при первом обращении (не через apt, отдельными бинарниками с
GitHub/get.helm.sh) — руками ставить их не нужно, если есть интернет. Если
сервер без доступа даже к GitHub — используйте `--offline` (см.
[AIRGAP.md](./AIRGAP.md)), там оба инструмента уже лежат в самом bundle,
сеть на целевом сервере не нужна вообще.

## Поэтапная установка (рекомендуется для первого прогона на Astra Linux)

`sudo ./bootstrap.sh --profile single` ставит всё одной командой, но если
что-то пойдёт не так (а на неподтверждённой ОС это вероятнее, чем на
проверенной), заранее непонятно, на каком именно шаге. Ниже — та же самая
установка, разбитая на отдельно запускаемые стадии (`scripts/stages/`) —
**это не сокращённая версия, а буквально тот же код**: `bootstrap.sh`
вызывает те же функции, что и эти скрипты, просто без остановок между ними.
После каждой стадии — команда проверки и то, что ожидается увидеть, прежде
чем переходить к следующей.

### Стадия 1 — определение ОС (ничего не меняет в системе)

```bash
./scripts/stages/01-os-detect.sh
```
Ожидается: строка с `Astra Linux ...` и, скорее всего, предупреждение про
`verified: false` (см. начало этого документа — это нормально, не ошибка) и
про ЗПС (см. выше — проверьте вручную, если не уверены).

### Стадия 2 — preflight (тоже ничего не меняет)

```bash
sudo ./scripts/stages/02-preflight.sh --profile single
```
Ожидается: таблица PASS/WARN/FAIL и в конце `Preflight пройден`. Если
FAIL — **остановитесь здесь**, разберитесь с конкретной причиной (см.
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)) прежде чем продолжать. `--force`
в конце команды продолжит через FAIL, но только если вы уверены, что это
ложное срабатывание.

### Стадия 3 — k3s (первое реальное изменение системы)

```bash
sudo ./scripts/stages/03-k3s.sh --profile single
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # для стадий 4+ в этом же шелле
```
Проверка:
```bash
kubectl get nodes
```
Ожидается: один узел, статус `Ready`. Если не `Ready` больше пары минут —
`sudo journalctl -u k3s -n 100 --no-pager` и смотрите на реальную ошибку, а
не только "не Ready".

### Стадия 4 — RabbitMQ Cluster Operator + Messaging Topology Operator

```bash
./scripts/stages/04-rabbitmq-operators.sh
```
Проверка:
```bash
kubectl get pods -n rabbitmq-system
```
Ожидается: `rabbitmq-cluster-operator-*` и `messaging-topology-operator-*`
оба `Running 1/1`. Certificate/Issuer в выводе выше ожидаемо падают с
ошибкой — это нормально, вебхуки используют самоподписанные сертификаты
(`scripts/lib/rabbitmq-webhook-certs.sh`), не cert-manager.

### Стадия 5 — Kong (самая частая точка сбоя на реальных прогонах)

```bash
./scripts/stages/05-kong.sh --topology single
```
Проверка:
```bash
kubectl get pods -n platform -l app.kubernetes.io/name=kong
```
Ожидается: под `Running`, **все** контейнеры готовы (например `2/2`, не `1/2`).

**Если под завис в `Pending`**: `kubectl describe pod <имя> -n platform`,
смотрите `Events` в самом низу. Известная причина (встречена и исправлена
реальным прогоном на Ubuntu, актуально и для Astra) —
`didn't match pod anti-affinity rules`: значит вы на одном узле, но
использовались values без `kong-values-single.yaml` (`--topology` был
передан неправильно, например `standard` вместо `single`).

**Если под `Running`, но не все контейнеры готовы** (например `1/2`,
`CrashLoopBackOff`): `kubectl logs <имя> -n platform --all-containers` —
частая причина, встреченная реальным прогоном — RBAC-ошибка вида
`configmaps is forbidden ... at the cluster scope` у ServiceAccount
`kong-kong`. Если увидите её — не пытайтесь лечить конкретную роль,
проще и надёжнее: `helm uninstall kong -n platform`, затем повторить эту
стадию — Kong полностью stateless, переустановка ничего не теряет.

### Стадия 6 — kube-prometheus-stack (самая долгая стадия)

```bash
./scripts/stages/06-monitoring.sh
```
Это может занять несколько минут (большой чарт: Prometheus, Alertmanager,
Grafana, kube-state-metrics, node-exporter, admission-webhook job). **Не
прерывайте Ctrl+C**, если кажется, что зависло — прерванный `helm upgrade`
оставляет релиз в состоянии `pending-upgrade`, и следующий запуск сразу
упадёт с `another operation is in progress` (усугубляет проблему, не решает).

Пароль Grafana admin печатается в конце **один раз** — сохраните сразу.

Проверка:
```bash
kubectl get pods -n platform | grep monitoring
kubectl get jobs -n platform
```
Ожидается: все `monitoring-*` поды `Running`; Job'ы (`admission-create`/
`-patch`) — `Completed`, не висят в `Running` больше пары минут. Застрявший
Job — известная причина, по которой ПОСЛЕДУЮЩИЕ запуски этой стадии
подвисают (см. [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)).

Если релиз всё же завис (`another operation is in progress` при повторном
запуске): `helm uninstall monitoring -n platform`, затем стадия заново —
метрики за прошлый период потеряются, но это тестовая установка, не жалко.

### Стадия 7 — манифесты платформы

```bash
./scripts/stages/07-apply-manifests.sh --topology single
```
Проверка:
```bash
kubectl get pods -n platform
kubectl get networkpolicy -n platform   # должно быть ровно 10
```
Если RabbitMQ/mes-stub не `Running`, а NetworkPolicy — не 10 штук, значит
эта стадия не отработала полностью (проверьте вывод команды на ошибки) —
она идемпотентна, безопасно запустить ещё раз.

### Итог

Если все 7 стадий прошли проверку — установка полностью завершена, дальше
как в [INSTALL.md](./INSTALL.md#после-установки).

## Если что-то пошло не так

- Проверьте вывод `sudo ./scripts/preflight.sh --profile single` целиком — он
  печатает PASS/WARN/FAIL по каждому пункту, а не только первую ошибку.
- Соберите диагностику: `./scripts/diagnose.sh`.
- Смотрите [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).
- Сообщите, что именно не сработало (версия Astra, вывод preflight, вывод
  `journalctl -u k3s`) — это первый реальный прогон, и любая находка ценна для
  обновления `verified` в `release/manifest.yaml`.
