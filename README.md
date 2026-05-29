# User Platform V2

A 3-tier CRUD application (React + Node.js + MySQL) deployed on AWS EKS with production-grade infrastructure, security, and CI/CD.

## Architecture

```
Internet
    │
    ▼
AWS WAF ──► ALB (public subnet)
                │
                ▼
          EKS Cluster (private subnets)
          ├── qa namespace    ──► backend pods
          ├── prod namespace  ──► backend pods
          └── monitoring      ──► Prometheus, Loki, Grafana
                │
                ▼
          RDS MySQL (isolated subnet — no internet route)
```

**Key design decisions:**
- Zero static credentials — OIDC + IRSA everywhere, no AWS keys stored
- Infrastructure runs only from pipeline — S3 bucket policy enforces this
- One infra, two environments — QA and PROD share the cluster, separated by namespaces
- Cost-optimised — single NAT, 2-AZ, db.t3.micro, destroyable via pipeline

## Quick Start

```bash
# 1. Bootstrap (one-time, local)
cd terraform/bootstrap
terraform init && terraform apply
.\finish.ps1

# 2. Add GitHub secrets (see docs/09-manual-steps.md)

# 3. Push — pipeline provisions everything
git push origin main

# 4. Connect to cluster
aws eks update-kubeconfig --region ap-south-1 --name uplatform-cluster
kubectl get nodes
```

## Documentation

| Doc | What It Covers |
|-----|---------------|
| [Architecture & Security](docs/01-architecture.md) | Tools, why each, network security layers, zero trust roadmap |
| [Terraform](docs/02-terraform.md) | Bootstrap, modules, pipeline, how to customise |
| [Kubernetes](docs/03-kubernetes.md) | ArgoCD, Helm charts, bootstrap script — *coming soon* |
| [Docker](docs/04-docker.md) | Frontend and backend Dockerfiles — *coming soon* |
| [CI/CD Pipelines](docs/05-cicd.md) | QA full CI, PROD CD, image signing — *coming soon* |
| [Monitoring](docs/06-monitoring.md) | Prometheus, Loki, Tempo, Grafana — *coming soon* |
| [Security](docs/07-security.md) | Full security posture, network policies — *coming soon* |
| [Runbook](docs/08-runbook.md) | Deploy, rollback, debug, destroy — *coming soon* |
| [Manual Steps](docs/09-manual-steps.md) | Every one-time manual step with commands |

## Cost

~$213/month when running. $1/month when destroyed (just the bootstrap KMS key).

```bash
# Destroy everything (saves ~$213/month, rebuild in ~20 min)
GitHub → Actions → Terraform Destroy → type DESTROY

# Rebuild everything
GitHub → Actions → Terraform → Run workflow
```

## Repository Structure

```
├── app/
│   ├── client/              ← React frontend
│   └── server/              ← Node.js backend
├── terraform/
│   ├── bootstrap/           ← One-time state bucket + pipeline role
│   ├── modules/             ← vpc, eks, rds, iam, kms, s3, waf, dns
│   └── main.tf              ← Root module wiring
├── .github/workflows/
│   ├── terraform.yaml       ← Plan on push, Apply on merge
│   └── terraform-destroy.yaml
└── docs/                    ← Detailed documentation per layer
```