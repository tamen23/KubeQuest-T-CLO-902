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
  content  = tls_private_key.node.private_key_pem
  filename = "${path.module}/${var.project}-key.pem"
  # NO file_permission set: on Windows, Terraform's local_sensitive_file fails
  # with "Access is denied" when it tries to reopen a file it just chmod'd to a
  # restrictive mode (0400/0600) — AND a stale read-only .pem from a prior run
  # blocks the overwrite entirely. So let Terraform write with OS defaults
  # (always succeeds), then lock the key down out-of-band. scripts/cluster-up.sh
  # deletes any stale key first and runs `icacls` after; on Unix, chmod 600.
}

# --- EC2 nodes ---------------------------------------------------------------
# One instance per entry in var.nodes, named kubequest-<role> (kube-1, kube-2,
# ingress, monitoring). Each carries its role as a tag so you can see the
# layout in the console and so the outputs can group them.

resource "aws_instance" "node" {
  for_each               = var.nodes
  ami                    = data.aws_ami.al2023.id
  instance_type          = each.value.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.node.key_name
  user_data              = file("${path.module}/user-data-kubeadm.sh")

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  tags = {
    Name           = "${var.project}-${each.key}"
    Role           = each.key
    IsControlPlane = tostring(each.value.is_control_plane)
  }
}

# --- Elastic IP on the ingress node ------------------------------------------
# The brief's `ingress` node exposes services externally, so the static public
# IP (survives stop/start, keeps DNS/etc/hosts valid) attaches there.

resource "aws_eip" "ingress" {
  domain = "vpc"
  instance = one([
    for name, cfg in var.nodes : aws_instance.node[name].id if cfg.is_ingress
  ])
  tags = { Name = "${var.project}-ingress-eip" }
}

# --- Elastic IP on the control-plane node ------------------------------------
# A STATIC public IP for kube-1 so the kubeconfig (and the API cert SANs) never
# change: bake this IP into the apiserver cert once with --apiserver-cert-extra-
# sans, generate KUBECONFIG_B64 once, and it keeps working across stop/start and
# even destroy/recreate (the address is reserved to the account). Without this,
# the control-plane's public IP is ephemeral and you'd regenerate the kubeconfig
# every session.
resource "aws_eip" "control_plane" {
  domain = "vpc"
  instance = one([
    for name, cfg in var.nodes : aws_instance.node[name].id if cfg.is_control_plane
  ])
  tags = { Name = "${var.project}-control-plane-eip" }
}
