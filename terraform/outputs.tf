output "ingress_public_ip" {
  description = "Static Elastic IP of the first node (ingress entrypoint). Point *.local /etc/hosts here."
  value       = aws_eip.ingress.public_ip
}

output "node_public_ips" {
  description = "Public IP of every node."
  value       = aws_instance.node[*].public_ip
}

output "node_private_ips" {
  description = "Private (VPC) IP of every node — used for kubeadm join."
  value       = aws_instance.node[*].private_ip
}

output "ssh_private_key_file" {
  description = "Path to the generated SSH private key."
  value       = local_sensitive_file.private_key.filename
}

output "ssh_command" {
  description = "Ready-to-paste SSH command for the first node."
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${aws_eip.ingress.public_ip}"
}
