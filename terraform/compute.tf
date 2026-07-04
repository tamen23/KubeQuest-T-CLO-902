# --- SSH keypair -------------------------------------------------------------
# Terraform generates the keypair and writes the private key locally
# (gitignored). Use it to SSH in and to fetch the kubeconfig.

resource "tls_private_key" "node" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "node" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.node.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.node.private_key_pem
  filename        = "${path.module}/${var.project}-key.pem"
  file_permission = "0400"
}

# --- EC2 nodes ---------------------------------------------------------------
# node_count instances. With node_count=1 this is the cheap single-node test;
# bump to 4 and they'll be named kubequest-node-0..3.

resource "aws_instance" "node" {
  count                  = var.node_count
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.node.key_name
  user_data              = file("${path.module}/user-data-kubeadm.sh")

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-node-${count.index}" }
}

# --- Elastic IP for the first node (the ingress / entrypoint) ----------------
# A static public IP that survives stop/start, so DNS / /etc/hosts stays valid.

resource "aws_eip" "ingress" {
  domain   = "vpc"
  instance = aws_instance.node[0].id
  tags     = { Name = "${var.project}-ingress-eip" }
}
