variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-3" # Paris; matches the KubeQuest lab regions
}

variable "project" {
  description = "Name prefix + tag applied to every resource, for easy find/cleanup."
  type        = string
  default     = "kubequest"
}

# The brief's 4-node layout (project.pdf p.4): kube-1 (control-plane+worker),
# kube-2 (worker), ingress (exposes services), monitoring (Prometheus/Grafana/
# Loki). Each entry sets the node's role + size. Sizing follows the brief's own
# role split: the monitoring node carries the heavy observability stack so it's
# 8GB; the rest do lighter work at 4GB. All types are FREE-TIER-ELIGIBLE
# (verify: aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true).
# `is_control_plane` marks where kubeadm init runs; `is_ingress` gets the EIP.
variable "nodes" {
  description = "Map of cluster nodes keyed by their KubeQuest role name."
  type = map(object({
    instance_type    = string
    is_control_plane = bool
    is_ingress       = bool
  }))
  default = {
    kube-1     = { instance_type = "m7i-flex.large", is_control_plane = true, is_ingress = false } # control plane + worker
    kube-2     = { instance_type = "c7i-flex.large", is_control_plane = false, is_ingress = false } # worker
    ingress    = { instance_type = "c7i-flex.large", is_control_plane = false, is_ingress = true }  # exposes services (gets EIP)
    monitoring = { instance_type = "m7i-flex.large", is_control_plane = false, is_ingress = false } # heavy observability stack -> 8GB
  }
}

variable "root_volume_gb" {
  description = "Root EBS volume size per node (Kubernetes + images + local-path PVs live here)."
  type        = number
  default     = 40
}

# Lock inbound SSH to your own IP for safety. Find yours: curl ifconfig.me
# Default is open-to-the-world so `terraform apply` works out of the box, but
# you SHOULD override it. 80/443 stay open to the world (that's the app).
variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (port 22). Set to <your-ip>/32."
  type        = string
  default     = "0.0.0.0/0"
}
