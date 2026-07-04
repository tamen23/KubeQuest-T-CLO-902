output "ingress_public_ip" {
  description = "Static Elastic IP of the ingress node (external entrypoint). Point *.local /etc/hosts here."
  value       = aws_eip.ingress.public_ip
}

# Everything you need per node, keyed by role (kube-1/kube-2/ingress/monitoring):
# public IP for SSH, private IP for kubeadm join, and whether it's the CP.
output "nodes" {
  description = "Per-node role, public IP, private IP, control-plane flag."
  value = {
    for name, inst in aws_instance.node : name => {
      public_ip        = inst.public_ip
      private_ip       = inst.private_ip
      instance_type    = inst.instance_type
      is_control_plane = var.nodes[name].is_control_plane
    }
  }
}

# Convenience: the control-plane node's public IP (where you SSH to run
# `kubeadm init`) and its private IP (what the workers join against).
output "control_plane_public_ip" {
  description = "Public IP of the control-plane node (run kubeadm init here)."
  value       = one([for name, cfg in var.nodes : aws_instance.node[name].public_ip if cfg.is_control_plane])
}

output "control_plane_private_ip" {
  description = "Private IP of the control-plane node (workers join this)."
  value       = one([for name, cfg in var.nodes : aws_instance.node[name].private_ip if cfg.is_control_plane])
}

output "ssh_private_key_file" {
  description = "Path to the generated SSH private key."
  value       = local_sensitive_file.private_key.filename
}
