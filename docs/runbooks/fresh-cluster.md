# Fresh Cluster Runbook

This runbook documents the fresh-cluster path implemented by
`scripts/cluster-up.sh`. It is the preparation step before deploying the full
KubeQuest platform.

Run it from your laptop, from the repository root:

```sh
bash scripts/cluster-up.sh
```

The script assumes Terraform, SSH, and AWS CLI access are available locally.

## What The Script Creates

The script runs Terraform from `terraform/` and creates:

- A VPC and cluster networking.
- Security group rules for SSH, HTTP, HTTPS, and intra-cluster traffic.
- Four EC2 instances: `kube-1`, `kube-2`, `ingress`, and `monitoring`.
- Static public addressing for the ingress path.
- A generated SSH private key at `terraform/kubequest-key.pem`.

After Terraform, it connects to the instances and forms the Kubernetes cluster
with kubeadm.

## Bootstrap Sequence

The important phases are:

1. Remove any stale local private key file that Terraform cannot overwrite.
2. Run `terraform init` and `terraform apply`.
3. Lock the generated private key permissions for SSH.
4. Read Terraform outputs for the control-plane, private API endpoint, and
   ingress public IP.
5. Wait for each node to finish its user-data bootstrap.
6. Run `kubeadm init` on `kube-1`.
7. Install Flannel and patch it to the configured pod CIDR.
8. Remove the control-plane taint so the lab can schedule workloads there.
9. Join `kube-2`, `ingress`, and `monitoring`.
10. Label nodes for worker, ingress, and monitoring placement.

## Node Label Contract

The deployment layer expects these labels:

```sh
node-role.kubernetes.io/worker=worker
node-role.kubernetes.io/ingress=ingress
node-role.kubernetes.io/monitoring=monitoring
```

ingress-nginx is pinned to the ingress node. The heavier observability
components are pinned to the monitoring node by their values files.

## Networking Notes

The kubeadm cluster uses:

- API server certificate SANs including the control-plane public IP.
- Control-plane endpoint set to the control-plane private IP.
- Flannel for pod networking.
- A pod CIDR of `192.168.0.0/16`.

The Terraform layer disables EC2 source destination checks so pod traffic can
cross nodes correctly.

## Expected Output

At the end, the script prints:

- The command to copy the repository content to `kube-1`.
- The SSH command for the control-plane node.
- The required environment variables for `scripts/deploy.sh`.
- The ingress public IP to pass as `INGRESS_PUBLIC_IP`.

That ingress IP becomes the public DNS suffix used by the deployment script:

```text
https://crementation.<ingress-ip>.nip.io
https://grafana.<ingress-ip>.nip.io
https://dashboard.<ingress-ip>.nip.io
https://argocd.<ingress-ip>.nip.io
```

## Before Continuing

Check the cluster from `kube-1`:

```sh
kubectl get nodes -o wide
kubectl get nodes -L node-role.kubernetes.io/ingress,node-role.kubernetes.io/monitoring,node-role.kubernetes.io/worker
```

All four nodes should be `Ready`, and the labels should match the intended
roles.

## Hand-Off To Deployment

After this runbook succeeds, SSH to `kube-1`, export the deployment secrets as
environment variables, and run:

```sh
bash ~/kubequest/scripts/deploy.sh
```

The full deployment order is documented in
[Full Deployment Runbook](full-deploy.md).
