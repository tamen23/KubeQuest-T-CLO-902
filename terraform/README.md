# Terraform — AWS cluster provisioning

Provisions the raw AWS infrastructure the KubeQuest Kubernetes stack runs *on*:
a VPC, a security group (ports 22/80/443 + all intra-cluster), one or more
EC2 nodes (Amazon Linux 2023, pre-installed with containerd + kubeadm via
user-data), and a static Elastic IP on the first node.

Defaults to **1 × t3.large** node for a cheap end-to-end test. Bump
`node_count` to 4 later for the full kube-1/kube-2/ingress/monitoring layout.

> **This is the AWS layer only.** The Kubernetes GitOps (ingress, monitoring,
> Vault, the app, …) lives in `infrastructure/` and `applications/` on the
> `kubequest-infra` branch and is deployed *after* the cluster exists — see the
> repo README's Deployment section.

## Prerequisites

- Terraform >= 1.5 — `winget install -e --id Hashicorp.Terraform`
- AWS CLI configured with your account credentials (`aws configure`), a user
  with EC2/VPC permissions.
- Know your public IP for the SSH rule: `curl ifconfig.me`

## Apply

```sh
cd terraform
terraform init
# lock SSH to your own IP (recommended) and pick a region:
terraform apply -var="ssh_ingress_cidr=$(curl -s ifconfig.me)/32" -var="region=eu-west-3"
```

Outputs include the ingress Elastic IP, the SSH command, and the private-key
path (written to `terraform/kubequest-key.pem`, gitignored).

## Stand up Kubernetes (single node)

SSH in (`terraform output -raw ssh_command` gives the exact line), then:

```sh
# on the node
sudo kubeadm init --pod-network-cidr=192.168.0.0/16

# make kubectl work for ec2-user
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config

# install the Calico CNI
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

# single-node only: let workloads schedule on the control-plane node
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# for the KubeQuest node labels, label this one node as ingress + monitoring
kubectl label node $(hostname) node-role.kubernetes.io/ingress=ingress node-role.kubernetes.io/monitoring=monitoring
```

## Get the kubeconfig onto your laptop

```sh
# from your laptop
scp -i terraform/kubequest-key.pem ec2-user@<ingress-ip>:~/.kube/config ./kubeconfig-kubequest
# edit the `server:` line in that file to the node's PUBLIC ip, then:
export KUBECONFIG=$PWD/kubeconfig-kubequest
kubectl get nodes   # should show the node Ready
```

Now follow the repo README's Deployment section to deploy `kubequest-infra`.

## COST — read this

A `t3.large` runs ~$0.09/hr (~$2/day) if left on 24/7, which eats the $200
credit steadily. **Discipline:**

```sh
# stop the node when not using it (keeps the disk + Elastic IP, stops compute billing)
aws ec2 stop-instances --instance-ids $(terraform output -json node_public_ips >/dev/null; terraform state show 'aws_instance.node[0]' | awk '/id  *=/{print $3; exit}' | tr -d '"')

# ...or nuke EVERYTHING when done (irreversible):
terraform destroy
```

Also set a **billing budget alarm** in AWS Billing → Budgets on day one.

## Scaling to 4 nodes later

`terraform apply -var="node_count=4"` creates 3 more nodes. Then `kubeadm init`
on node-0 prints a `kubeadm join ...` command — run it (via SSH) on nodes 1–3
using their **private** IPs (`terraform output node_private_ips`), and label
each node per the brief (kube-1/kube-2 = workers, one = ingress, one =
monitoring).
