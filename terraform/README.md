# Terraform Setup

This Terraform configuration provisions the AWS runtime for StatusPulse in `us-east-1`.
It uses local Terraform state on your machine, not an S3 backend, so `terraform.tfstate` stays in the `terraform/` directory and is ignored by git.

## What it creates

- An EC2 instance in the default VPC
- A static Elastic IP
- A security group that exposes only ports 80 and 443
- An instance profile with Systems Manager access
- A GitHub Actions OIDC role for deploy automation

## Prerequisites

- Terraform 1.5 or newer
- AWS credentials with permission to create EC2, IAM, and EIP resources
- GitHub repository slug in `owner/name` form

## Important variables

- `github_repository`
  - Defaults to `AshokSelf/statuspulse`.
- `ghcr_image`
  - Defaults to `ghcr.io/ashokself/statuspulse`.
- `repository_clone_url`
  - Defaults to `https://github.com/AshokSelf/statuspulse.git`.
  - If your repo is private, replace the bootstrap strategy with a deploy key or other authenticated clone method.
- `domain_name`
  - Defaults to `ak-info.online`.
- `caddy_email`
  - Used by Let’s Encrypt registration in Caddy.

## Apply

```bash
cd /home/ashok/statuspulse/terraform
terraform init
terraform plan
terraform apply
```

## Outputs

- `elastic_ip`
  - Point your DNS `A` record for `ak-info.online` to this value.
- `site_url`
  - The public HTTPS URL once DNS resolves.
- `github_actions_role_arn`
  - Use this ARN in the GitHub Actions deploy workflow for OIDC.

## Bootstrapped host state

The EC2 user data script installs Docker, the Compose plugin, Git, AWS CLI, and the SSM agent, then:

- clones the repository into `/opt/statuspulse`
- creates `/opt/statuspulse/.env`
- generates random database and Redis passwords
- prepares backup and log directories
- installs cron jobs for the health monitor and database backups
- marks `/opt/statuspulse` as a Git safe directory so GitHub Actions can trigger SSM-based deploys cleanly
- writes a complete `/opt/statuspulse/.env` file, including blue-green image tags, database and Redis credentials, monitoring thresholds, backup settings, and AWS metadata

The first deployment can then be executed from GitHub Actions without manual server setup.
