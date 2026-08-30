#!/usr/bin/env bash
set -euo pipefail
# Выполнять на целевом сервере (root/sudo), интернет не требуется.
# Ожидается, что архив airgap-bundle.tar.gz уже распакован рядом
# (структура infra/airgap/airgap-bundle/...).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$HERE/airgap-bundle"

if [ ! -d "$BUNDLE" ]; then
  echo "Не найдено $BUNDLE — распакуйте airgap-bundle.tar.gz в $HERE" >&2
  exit 1
fi

echo "==> Устанавливаем бинарники k3s/kubectl/helm"
install -m 0755 "$BUNDLE/bin/k3s" /usr/local/bin/k3s
install -m 0755 "$BUNDLE/bin/kubectl" /usr/local/bin/kubectl
install -m 0755 "$BUNDLE/bin/helm" /usr/local/bin/helm

echo "==> Кладём системные образы k3s туда, откуда k3s сам их подхватит при старте"
mkdir -p /var/lib/rancher/k3s/agent/images/
cp "$BUNDLE"/k3s-airgap/k3s-airgap-images-*.tar.gz /var/lib/rancher/k3s/agent/images/

echo "==> Регистрируем k3s как systemd-сервис (без установочного скрипта — он лезет в сеть)"
# --disable traefik: у нас свой API Gateway (Kong), встроенный traefik не нужен
# --write-kubeconfig-mode 644: чтобы kubectl работал не только из-под root
cat >/etc/systemd/system/k3s.service <<'EOF'
[Unit]
Description=Lightweight Kubernetes
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server --disable traefik --write-kubeconfig-mode 644
KillMode=process
Delegate=yes
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now k3s

echo "==> Ждём готовности узла..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 60); do
  if kubectl get nodes 2>/dev/null | grep -q Ready; then
    echo "    Узел готов."
    break
  fi
  sleep 5
done
kubectl get nodes

echo "==> Готово. Добавьте в ~/.bashrc:  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
