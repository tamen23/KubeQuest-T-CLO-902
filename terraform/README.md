# Terraform — AWS cluster provisioning

Provisions the raw AWS infrastructure the KubeQuest Kubernetes stack runs *on*,
matching the brief's 4-node layout (project.pdf p.4):

| Node | Role | Size |
|------|------|------|
| `kube-1` | control plane + worker (kubeadm init runs here) | m7i-flex.large (8GB) |
| `kube-2` | worker | c7i-flex.large (4GB) |
| `ingress` | exposes services externally (**gets the Elastic IP**) | c7i-flex.large (4GB) |
| `monitoring` | Prometheus / Grafana / Loki (heavy) | m7i-flex.large (8GB) |

Plus a VPC, a security group (22/80/443 + all intra-cluster), and two
persistent Elastic IPs (ingress + control-plane — see `eips/` below). All
instance types are free-tier-eligible. Node roles/sizes are defined in the
`nodes` variable in `variables.tf` — edit there to change the layout.

> **This is the AWS layer only.** The Kubernetes GitOps (ingress, monitoring,
> Vault, the app, …) lives in `infrastructure/` and `applications/` on the
> `kubequest-infra` branch and is deployed *after* the cluster exists — see the
> repo README's Deployment section.

## Prerequisites

- Terraform >= 1.5 — `winget install -e --id Hashicorp.Terraform`
- AWS CLI configured (`aws configure`), a user with EC2/VPC permissions.
- Your public IP for the SSH rule: `curl ifconfig.me`

## One-time setup: persistent Elastic IPs (`eips/`)

Before the very first `terraform apply` below (skip if `eips/` has already
been applied once — check with `cd eips && terraform show`):

```sh
cd terraform/eips
terraform init
terraform apply
cd ..
```

This allocates the ingress and control-plane Elastic IPs in their **own,
separate Terraform state** — deliberately isolated from the cluster's own
state below, so a normal `terraform destroy` (the "fresh cluster before the
defense" cycle) can never release them. Every nip.io hostname
(`crementation.<ip>.nip.io`, etc), the GitHub OAuth app's callback URL, and
`KUBECONFIG_B64` are all built on these IPs — if they changed on every
rebuild, all three would need manual fixing every time. Run this once, ever;
`terraform apply` below re-associates the *same* addresses onto whichever
instances come up on every subsequent rebuild.

## Apply

```sh
cd terraform
terraform init
terraform apply -var="ssh_ingress_cidr=<your-ip>/32"
```

Key outputs: `control_plane_public_ip` (SSH here for kubeadm init),
`control_plane_private_ip` (workers join this), `ingress_public_ip` (the
services are reachable at `<name>.<this-ip>.nip.io` — no `/etc/hosts` entry
needed, see the repo README), `nodes` (per-node public/private IPs), and the
private-key path `terraform/kubequest-key.pem` (gitignored).

```sh
terraform output nodes                    # see all four nodes' IPs + roles
terraform output -raw control_plane_public_ip
```

## Stand up Kubernetes (4 nodes)

### 1. On the control-plane node (kube-1)

```sh
ssh -i ./kubequest-key.pem ec2-user@<control_plane_public_ip>

# Include the node's PUBLIC IP in the API server certificate's valid names, so
# a remote client (your laptop, or the GitHub Actions deploy workflow) can talk
# to the API over the public IP without a TLS error. IMDSv2 is enforced on
# these instances, so fetch the IP with a token:
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBIP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-cert-extra-sans="$PUBIP"

# kubectl for ec2-user
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config

# Flannel CNI (nodes stay NotReady until this is applied). Flannel's default
# pod CIDR is 10.244.0.0/16 — patch it to match --pod-network-cidr above.
curl -sSL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml -o /tmp/flannel.yml
sed -i 's#10.244.0.0/16#192.168.0.0/16#g' /tmp/flannel.yml
kubectl apply -f /tmp/flannel.yml
```

> **Why `--apiserver-cert-extra-sans`:** kubeadm's API cert defaults to the
> node's *private* IP + internal names only. Remote clients reach the API over
> the *public* IP, so without adding it here you'd get
> `x509: certificate is valid for 10.x.x.x, not <public-ip>`. Adding it at init
> time is the clean fix. (If you forget, you can regenerate the apiserver cert
> later, but it's easier to get right now.)

> **Why Flannel, and why `source_dest_check = false` matters (compute.tf):**
> AWS drops any packet whose source/destination IP isn't the instance's own —
> which is exactly what CNI overlay traffic (VXLAN) and pod-to-pod networking
> look like. Without `source_dest_check = false` on every instance (already set
> in `compute.tf`), cross-node pod networking silently fails: pods on the same
> node work fine, but the ingress controller can't reach an app pod scheduled
> on a *different* node (504/timeout) — the exact symptom that cost real time
> to diagnose. We use Flannel over Calico here because Calico's on-disk CNI
> config (`/etc/cni/net.d/10-calico.conflist`) isn't removed by deleting its
> DaemonSet and can shadow a replacement CNI; Flannel is simpler and reliable
> on EC2 once `source_dest_check` is off. `scripts/cluster-up.sh` automates all
> of the above end-to-end.

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
scp -i ./kubequest-key.pem ec2-user@<control_plane_public_ip>:~/.kube/config ./kubeconfig-kubequest
# edit the `server:` line to the control-plane node's PUBLIC ip, then:
export KUBECONFIG=$PWD/kubeconfig-kubequest
kubectl get nodes
```

## Give the deploy workflow cluster access (KUBECONFIG_B64 secret)

The GitHub Actions **Deploy** workflow (`.github/workflows/deploy.yml`) seeds
Vault and hands off to ArgoCD — but it runs on GitHub's servers, so it needs a
kubeconfig to reach your cluster. Provide it as the repo secret `KUBECONFIG_B64`
(base64 of the kubeconfig above, with the **public** `server:` IP — which works
because you added `--apiserver-cert-extra-sans` at init):

```sh
# 1. confirm the kubeconfig's server line is the control-plane PUBLIC ip (edit if not)
grep server: ./kubeconfig-kubequest

# 2. base64-encode it (one line, no wrapping):
#    Git Bash / Linux / macOS:
base64 -w0 ./kubeconfig-kubequest   > kubeconfig.b64
#    (macOS without -w0:  base64 -i ./kubeconfig-kubequest -o kubeconfig.b64)
#    Windows PowerShell:
#    [Convert]::ToBase64String([IO.File]::ReadAllBytes("./kubeconfig-kubequest")) | Set-Content kubeconfig.b64

# 3. copy the contents of kubeconfig.b64 into GitHub:
#    Settings -> Secrets and variables -> Actions -> New repository secret
#    Name: KUBECONFIG_B64   Value: <paste>
rm kubeconfig.b64   # don't leave it lying around
```

**You only do this ONCE.** The control-plane node has a **persistent Elastic
IP**, allocated in `terraform/eips/` — a separate Terraform state, isolated
on purpose so a normal `terraform destroy` in this directory (the "fresh
cluster before the defense" cycle) can never release it. So the kubeconfig's
`server:` line stays valid forever and `KUBECONFIG_B64` never needs
regenerating, even across a full destroy+rebuild of the cluster itself. Then
trigger the deploy: **Actions tab → Deploy → Run workflow**. It seeds Vault
from your GitHub secrets and lets ArgoCD deploy everything — no secrets
typed.

> The only way to actually lose this IP is running `terraform destroy`
> **inside `terraform/eips/` itself** — a separate, deliberate, rare action
> you'd take only when tearing down the whole project for good, never as
> part of a normal rebuild. See `terraform/eips/main.tf`'s header comment.

Alternatively, deploy from your laptop with `personal/bootstrap.sh` (which
already has local cluster access) instead of the workflow.

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
