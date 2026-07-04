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

# Start at 1 for the cheap single-node test; bump to 4 later to match the
# brief's kube-1 / kube-2 / ingress / monitoring layout without rewriting anything.
variable "node_count" {
  description = "How many EC2 instances to create."
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "EC2 size. t3.large (2 vCPU / 8GB) is the realistic floor for the full stack on one node."
  type        = string
  default     = "t3.large"
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
