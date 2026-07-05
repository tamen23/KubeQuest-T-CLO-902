# =============================================================================
# KubeQuest — persistent Elastic IPs (SEPARATE Terraform state, on purpose)
# =============================================================================
# Two public IPs that must NEVER change, even across a full destroy+rebuild of
# the cluster itself:
#   - ingress:       every nip.io hostname (crementation.<ip>.nip.io, etc) is
#                    built from this IP. If it changes, EVERY certificate,
#                    ingress host, and — critically — the GitHub OAuth app's
#                    callback URL (an external, manually-configured setting
#                    GitHub itself stores) all break and need manual fixing.
#   - control-plane: the kubeconfig's `server:` field and the apiserver TLS
#                    cert's SANs are baked to this IP; KUBECONFIG_B64 (the
#                    GitHub Actions deploy secret) is only a true "set once"
#                    if this IP is permanent.
#
# These EIPs are allocated here, in their OWN state, deliberately isolated
# from ../ (the cluster's compute/network/instances). `terraform destroy` in
# ../ can NEVER reach these — an EIP that's merely "reserved" (not attached
# to any instance) costs nothing extra on AWS and is not affected by
# instance termination. Association back onto whichever instance is
# currently running happens from ../ via `aws_eip_association`, which is
# safe to destroy/recreate every rebuild — only the ADDRESS itself is
# permanent, never the attachment.
#
# One-time setup (before the first-ever cluster-up.sh run, or after this
# repo is cloned fresh): `cd terraform/eips && terraform init && terraform
# apply`. Never destroy this state as part of a normal cluster rebuild —
# only `terraform destroy` HERE would release these IPs, and that's a
# deliberate, rare, separate action (e.g. tearing down the whole project for
# good), not part of the "fresh cluster before the defense" flow.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  description = "AWS region — MUST match ../variables.tf's region (EIPs are region-scoped)."
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  description = "Name prefix/tag — MUST match ../variables.tf's project."
  type        = string
  default     = "kubequest"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform-eips" # distinct from the cluster state's "terraform"
    }
  }
}

resource "aws_eip" "ingress" {
  domain = "vpc"
  tags   = { Name = "${var.project}-ingress-eip" }
}

resource "aws_eip" "control_plane" {
  domain = "vpc"
  tags   = { Name = "${var.project}-control-plane-eip" }
}

output "ingress_ip" {
  value = aws_eip.ingress.public_ip
}

output "control_plane_ip" {
  value = aws_eip.control_plane.public_ip
}

output "ingress_allocation_id" {
  value = aws_eip.ingress.id
}

output "control_plane_allocation_id" {
  value = aws_eip.control_plane.id
}
