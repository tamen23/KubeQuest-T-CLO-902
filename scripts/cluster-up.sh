#!/usr/bin/env bash
# =============================================================================
# KubeQuest — SCRIPT A: bring up the fresh cluster (run BEFORE the defense)
# =============================================================================
# The brief (project.pdf p.5) says: "before presenting, start a fresh new
# Kubernetes cluster in the cloud, with many nodes". This script does exactly
# that — terraform provisions 4 EC2 nodes, then kubeadm forms the cluster:
#   kube-1 = control-plane + worker, kube-2 = worker, ingress, monitoring.
#
# Run this from your laptop, from the repo root (needs terraform + ssh + the
# AWS CLI configured). It is idempotent-ish: safe to re-run; kubeadm steps
# skip if already done.
#
#   bash scripts/cluster-up.sh
#
# When it finishes it prints the control-plane SSH command and the ingress IP.
# Then run the deploy: SSH to kube-1 and follow scripts/deploy.sh (SCRIPT B).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
TF=terraform
KEY="$TF/kubequest-key.pem"
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30"
POD_CIDR=192.168.0.0/16

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$1"; }

# --- 1. provision the 4 nodes ------------------------------------------------
say "Terraform apply (4 nodes + VPC + 2 EIPs)"
# Clear any stale key file first: Terraform can't overwrite a read-only .pem
# left by a previous run ("Access is denied" on Windows). Remove attrs + file.
if [ -f "$KEY" ]; then
  chmod u+w "$KEY" 2>/dev/null || true
  command -v attrib.exe >/dev/null && attrib.exe -R "$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")" 2>/dev/null || true
  rm -f "$KEY" 2>/dev/null || true
fi
( cd "$TF" && terraform init -input=false >/dev/null && terraform apply -auto-approve -var="ssh_ingress_cidr=0.0.0.0/0" )
# Lock the freshly-written key so SSH accepts it (Windows: icacls; Unix: chmod).
if command -v icacls.exe >/dev/null 2>&1; then
  KEY_WIN="$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")"
  icacls.exe "$KEY_WIN" /inheritance:r >/dev/null 2>&1 || true
  icacls.exe "$KEY_WIN" /grant:r "$(whoami):(R)" >/dev/null 2>&1 || true
else
  chmod 600 "$KEY" 2>/dev/null || true
fi
ok "infrastructure applied + key locked"

# read outputs
CP_IP=$(cd "$TF" && terraform output -raw control_plane_public_ip)
CP_PRIV=$(cd "$TF" && terraform output -raw control_plane_private_ip)
INGRESS_IP=$(cd "$TF" && terraform output -raw ingress_public_ip)
# per-node public/private IPs (json)
NODES_JSON=$(cd "$TF" && terraform output -json nodes)
echo "  control-plane: $CP_IP (private $CP_PRIV) | ingress: $INGRESS_IP"

# helper: pull a node's public IP by role from the nodes output
node_ip() { echo "$NODES_JSON" | python -c "import sys,json;print(json.load(sys.stdin)['$1']['public_ip'])" 2>/dev/null \
            || echo "$NODES_JSON" | grep -A4 "\"$1\"" | grep public_ip | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; }

say "Waiting for nodes to finish the kubeadm bootstrap (containerd + kubeadm install)"
for role in kube-1 kube-2 ingress monitoring; do
  ip=$(node_ip "$role")
  echo -n "  $role ($ip): "
  for i in $(seq 1 30); do
    if ssh $SSH_OPTS ec2-user@"$ip" "command -v kubeadm >/dev/null && command -v containerd >/dev/null" 2>/dev/null; then
      echo "ready"; break
    fi
    sleep 10; echo -n "."
  done
done
ok "all nodes bootstrapped"

# --- 2. kubeadm init on kube-1 (control-plane) -------------------------------
say "kubeadm init on kube-1"
ssh $SSH_OPTS ec2-user@"$CP_IP" "
  if [ ! -f /etc/kubernetes/admin.conf ]; then
    sudo kubeadm init --pod-network-cidr=$POD_CIDR \
      --apiserver-cert-extra-sans=$CP_IP --control-plane-endpoint=$CP_PRIV
    mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown \$(id -u):\$(id -g) ~/.kube/config
    # Flannel CNI (VXLAN) — chosen over Calico because it's simple + reliable on
    # AWS EC2 (needs source_dest_check=false on the instances, set in terraform).
    # Flannel defaults to pod CIDR 10.244.0.0/16; patch it to match our
    # --pod-network-cidr above so pods get IPs in the right range.
    curl -sSL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml -o /tmp/flannel.yml
    sed -i 's#10.244.0.0/16#$POD_CIDR#g' /tmp/flannel.yml
    kubectl apply -f /tmp/flannel.yml
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
  else
    echo 'already initialized, skipping'
  fi
"
ok "control plane up + Flannel CNI + untainted"

# --- 3. join the 3 workers ---------------------------------------------------
say "Joining workers"
JOIN=$(ssh $SSH_OPTS ec2-user@"$CP_IP" "sudo kubeadm token create --print-join-command")
for role in kube-2 ingress monitoring; do
  ip=$(node_ip "$role")
  echo "  joining $role ($ip)..."
  ssh $SSH_OPTS ec2-user@"$ip" "
    if [ ! -f /etc/kubernetes/kubelet.conf ]; then sudo $JOIN; else echo 'already joined'; fi
  " 2>&1 | grep -iE "joined|already" | head -1
done
ok "workers joined"

# --- 4. label nodes per the brief --------------------------------------------
say "Labelling nodes (ingress + monitoring)"
K2=$(node_ip kube-2); ING=$(node_ip ingress); MON=$(node_ip monitoring)
# map public IP -> k8s node name (private-DNS) via each node's hostname
k8sname() { ssh $SSH_OPTS ec2-user@"$1" hostname 2>/dev/null; }
ssh $SSH_OPTS ec2-user@"$CP_IP" "
  kubectl label node $(k8sname "$K2")  node-role.kubernetes.io/worker=worker         --overwrite
  kubectl label node $(k8sname "$ING") node-role.kubernetes.io/ingress=ingress       --overwrite
  kubectl label node $(k8sname "$MON") node-role.kubernetes.io/monitoring=monitoring --overwrite
  kubectl get nodes -L node-role.kubernetes.io/ingress,node-role.kubernetes.io/monitoring,node-role.kubernetes.io/worker
"
ok "nodes labelled"

cat <<EOF

============================================================================
 CLUSTER READY. Now deploy the stack (SCRIPT B), on kube-1:

   # 1. copy the repo up:
   scp -i $KEY -r infrastructure applications crementation components backups scripts ec2-user@$CP_IP:~/kubequest/
   # 2. SSH in and run deploy.sh — pass the ingress IP so it wires up nip.io + Let's Encrypt:
   ssh -i $KEY ec2-user@$CP_IP
   export GH_ID=... GH_SECRET=... DH_USER=maxi2 DH_TOKEN=... AWS_KEY=... AWS_SECRET=...
   export INGRESS_PUBLIC_IP=$INGRESS_IP
   bash ~/kubequest/scripts/deploy.sh

 Ingress (app entrypoint) IP: $INGRESS_IP
 -> services will be at https://<name>.$INGRESS_IP.nip.io (trusted certs, no hosts file)
============================================================================
EOF
