#!/bin/bash
# EC2 user-data: prepares an Amazon Linux 2023 node for Kubernetes (containerd
# + kubeadm + kubelet). It deliberately does NOT run `kubeadm init` — that's a
# one-time, interactive-ish step you run over SSH (see terraform/README.md), so
# you can capture the join command and kubeconfig cleanly. This just gets every
# node to the point where `kubeadm init`/`join` will work.
set -euxo pipefail

# --- kernel / sysctl prerequisites ------------------------------------------
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# swap must be off for kubelet
swapoff -a || true

# --- container runtime: containerd ------------------------------------------
dnf install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# use the systemd cgroup driver (required to match kubelet)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# --- kubeadm / kubelet / kubectl --------------------------------------------
K8S_MINOR="v1.30"
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet

# Pre-pull control-plane images so `kubeadm init` is fast.
kubeadm config images pull || true

echo "Node prepared for kubeadm. Run 'kubeadm init' (first node) or 'kubeadm join' (workers) over SSH."
