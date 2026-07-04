# Terraform — AWS cluster provisioning

Provisions the raw AWS infrastructure the KubeQuest Kubernetes stack runs *on*,
matching the brief's 4-node layout (project.pdf p.4):

| Node | Role | Size |
|------|------|------|
| `kube-1` | control plane + worker (kubeadm init runs here) | m7i-flex.large (8GB) |
| `kube-2` | worker | c7i-flex.large (4GB) |
| `ingress` | exposes services externally (**gets the Elastic IP**) | c7i-flex.large (4GB) |
| `monitoring` | Prometheus / Grafana / Loki (heavy) | m7i-flex.large (8GB) |

Plus a VPC, a security group (22/80/443 + all intra-cluster), and a static
Elastic IP on the ingress node. All instance types are free-tier-eligible.
Node roles/sizes are defined in the `nodes` variable in `variables.tf` — edit
there to change the layout.

> **This is the AWS layer only.** The Kubernetes GitOps (ingress, monitoring,
> Vault, the app, …) lives in `infrastructure/` and `applications/` on the
> `kubequest-infra` branch and is deployed *after* the cluster exists — see the
> repo README's Deployment section.

## Prerequisites

- Terraform >= 1.5 — `winget install -e --id Hashicorp.Terraform`
- AWS CLI configured (`aws configure`), a user with EC2/VPC permissions.
- Your public IP for the SSH rule: `curl ifconfig.me`

## Apply

```sh
cd terraform
terraform init
terraform apply -var="ssh_ingress_cidr=<your-ip>/32"
```

Key outputs: `control_plane_public_ip` (SSH here for kubeadm init),
`control_plane_private_ip` (workers join this), `ingress_public_ip` (point
`*.local` /etc/hosts here), `nodes` (per-node public/private IPs), and the
private-key path `terraform/kubequest-key.pem` (gitignored).

```sh
terraform output nodes                    # see all four nodes' IPs + roles
terraform output -raw control_plane_public_ip
```

## Stand up Kubernetes (4 nodes)

### 1. On the control-plane node (kube-1)

```sh
ssh -i ./kubequest-key.pem ec2-user@<control_plane_public_ip>

sudo kubeadm init --pod-network-cidr=192.168.0.0/16

# kubectl for ec2-user
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config

# Calico CNI (nodes stay NotReady until this is applied)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

`kubeadm init` prints a `kubeadm join <cp-private-ip>:6443 --token ... --discovery-token-ca-cert-hash ...`
command — **copy it**, you need it for the workers.

### 2. On each of the other 3 nodes (kube-2, ingress, monitoring)

```sh
ssh -i ./kubequest-key.pem ec2-user@<that-node's-public-ip>
sudo kubeadm join <cp-private-ip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

### 3. Back on kube-1, label the nodes per the brief

```sh
kubectl get nodes -o wide   # confirm all 4 are present + Ready

# node names are the EC2 private DNS (ip-10-0-x-x...). Map each to its role:
kubectl label node <kube-2-nodename>    node-role.kubernetes.io/worker=worker
kubectl label node <ingress-nodename>   node-role.kubernetes.io/ingress=ingress
kubectl label node <monitoring-nodename> node-role.kubernetes.io/monitoring=monitoring
```

(The infra manifests use `node-role.kubernetes.io/ingress` and
`node-role.kubernetes.io/monitoring` selectors — those two labels are the ones
that matter for scheduling.)

## Get the kubeconfig onto your laptop

```sh
scp -i terraform/kubequest-key.pem ec2-user@<control_plane_public_ip>:~/.kube/config ./kubeconfig-kubequest
# edit the `server:` line to the control-plane node's PUBLIC ip, then:
export KUBECONFIG=$PWD/kubeconfig-kubequest
kubectl get nodes
```

Now follow the repo README's Deployment section to deploy `kubequest-infra`.

## COST — the brief's own model: shut down when idle

The brief (p.4) says the lab VMs "are automatically shut down every evening to
conserve resources." Do the same: the cluster is **disposable** — the defense
(p.5) says to spin up a *fresh* cluster for presenting. So don't leave it
running.

```sh
# STOP all nodes when not using them (keeps disks + EIP, stops compute billing):
aws ec2 stop-instances --instance-ids $(aws ec2 describe-instances \
  --filters Name=tag:Project,Values=kubequest Name=instance-state-name,Values=running \
  --query "Reservations[].Instances[].InstanceId" --output text)

# START them again next session:
aws ec2 start-instances --instance-ids <same ids>
# NOTE: on restart, worker nodes' private IPs are unchanged (same subnet), and
# the ingress EIP is static — but the cluster's internal state persists on the
# EBS disks, so the k8s cluster comes back up as-is.

# ...or destroy EVERYTHING when done (irreversible):
terraform destroy -var="ssh_ingress_cidr=0.0.0.0/0"
```

Set a **billing budget alarm** in AWS Billing → Budgets on day one.

## Changing the layout

Edit the `nodes` map in `variables.tf` — add/remove nodes or change sizes.
For example a cheaper 2-node test: keep only `kube-1` and one worker. Re-run
`terraform apply`.
