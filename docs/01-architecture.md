# Architecture & Security

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          DEVELOPER WORKFLOW                            │
│                                                                        │
│  Push to terraform/**  ──►  GitHub Actions (OIDC)  ──►  terraform apply│
│  Push to qa branch     ──►  GitHub Actions (OIDC)  ──►  Build + Deploy │
│  Merge to main         ──►  GitHub Actions (OIDC)  ──►  Retag + Deploy │
│                                                                        │
│  No static AWS keys anywhere. All authentication is short-lived OIDC.  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                        AWS (ap-south-1)                                 │
│                                                                        │
│  ┌─────────────── VPC (10.0.0.0/16) ───────────────────────────────┐   │
│  │                                                                  │   │
│  │  Public Subnets (10.0.1.0/24, 10.0.2.0/24)                     │   │
│  │  ├── ALB (created by ALB Controller in K8s layer)               │   │
│  │  └── NAT Gateway (single, cost-optimised)                       │   │
│  │                                                                  │   │
│  │  Private Subnets (10.0.10.0/24, 10.0.11.0/24)                  │   │
│  │  ├── EKS Node Group (2x t3.medium, ON_DEMAND)                  │   │
│  │  │     ├── Namespace: qa    (backend app)                       │   │
│  │  │     ├── Namespace: prod  (backend app)                       │   │
│  │  │     └── Namespace: monitoring (Prometheus, Loki, Grafana)    │   │
│  │  └── VPC Endpoints (S3, ECR, Secrets Manager, STS)             │   │
│  │        └── AWS API calls never leave the VPC                    │   │
│  │                                                                  │   │
│  │  Isolated Subnets (10.0.20.0/24, 10.0.21.0/24)                 │   │
│  │  └── RDS MySQL 8.0 (db.t3.micro)                               │   │
│  │        ├── No internet route — physically unreachable from web  │   │
│  │        ├── SG allows only EKS node SG on port 3306              │   │
│  │        └── Two databases: qa_db, prod_db                        │   │
│  │                                                                  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                        │
│  WAF v2 ── attached to ALB                                             │
│  ├── IP Reputation List (blocks known malicious IPs)                   │
│  ├── Common Rule Set (OWASP Top 10)                                    │
│  ├── SQL Injection Rules                                               │
│  ├── Known Bad Inputs                                                  │
│  └── Rate Limiting (2000 req/5min per IP)                              │
│                                                                        │
│  KMS ── 4 separate keys (EBS, RDS, Secrets Manager, S3)               │
│  ACM ── wildcard cert (*.domain) for ALB HTTPS                         │
│  Route53 ── DNS records (created after ALB exists)                     │
│  S3 ── Loki log storage bucket                                         │
│  Secrets Manager ── RDS credentials (qa, prod, root)                   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Tool | What It Does | Why This Over Alternatives |
|------|-------------|--------------------------|
| **Terraform** | Infrastructure as Code | Declarative, state-tracked, reproducible. CloudFormation is AWS-only and verbose. Pulumi requires a programming language. Terraform is the industry standard for multi-cloud IaC. |
| **EKS** | Managed Kubernetes | AWS manages the control plane (etcd, API server, scheduler). We manage only worker nodes. |
| **RDS MySQL** | Managed database | Automated backups, patching, encryption. Self-managed MySQL on K8s means you own backup/recovery/failover. RDS handles it for ~$12/month. |
| **GitHub Actions** | CI/CD pipelines | Native to GitHub, free for public repos, OIDC integration with AWS means zero static credentials. |
| **OIDC** | Keyless authentication | GitHub generates a short-lived JWT per workflow run. AWS verifies it and issues temporary credentials. Keys can't leak because they don't exist. |
| **IRSA** | Pod-level AWS access | Without IRSA, all pods on a node share the node's IAM role (overprivileged). With IRSA, each pod gets only the permissions it needs. |
| **External Secrets Operator** | Syncs AWS secrets into K8s | App reads credentials from K8s secrets (standard pattern). ESO keeps them in sync with Secrets Manager. No credentials in git or Docker images. |
| **AWS WAF** | Layer 7 firewall | Stops SQL injection, XSS, bad bots, and DDoS before traffic hits your app. AWS managed rules update automatically. |
| **KMS** | Encryption key management | Separate keys per service means compromising one doesn't expose all data. Automatic key rotation enabled. |
| **VPC Endpoints** | Private AWS API connectivity | Without: node → NAT → internet → AWS API. With: node → endpoint → AWS API. Saves NAT costs and keeps traffic private. |
| **ACM** | SSL/TLS certificates | Free, auto-renewed, DNS-validated. Terraform automates issuance. |

## Security Architecture

### Zero Static Credentials

No AWS access keys, database passwords, or tokens exist as static values anywhere:

```
GitHub Actions → AWS:
  GitHub OIDC JWT → AWS STS → Temporary credentials (1 hour max)

Pods → AWS services:
  K8s Service Account → IRSA → AWS STS → Temporary credentials (auto-rotated)

App → Database credentials:
  AWS Secrets Manager → ESO → K8s Secret → Pod env vars
  Terraform generates passwords → stores in Secrets Manager → never visible in code
```

### Network Security — Defense in Depth

```
Layer 1: WAF
  Blocks malicious requests before they reach the ALB

Layer 2: Public/Private/Isolated subnet separation
  ALB in public — only thing internet-facing
  EKS nodes in private — no public IP, outbound via NAT only
  RDS in isolated — no internet route at all, not even outbound

Layer 3: Security Groups
  ALB SG → allows 80/443 from internet
  Node SG → allows traffic only from ALB SG and other nodes
  RDS SG → allows 3306 only from Node SG
  VPC Endpoint SG → allows 443 only from VPC CIDR

Layer 4: VPC Endpoints
  AWS API calls (ECR, Secrets Manager, STS, S3) stay on AWS private network
  Even if NAT fails, nodes can still pull images and fetch secrets

Layer 5: KMS Encryption
  4 separate KMS keys — EBS, RDS, Secrets Manager, S3
  Key rotation enabled on all keys

Layer 6: IAM Least Privilege (IRSA)
  ESO QA → can only read QA secret, cannot read PROD
  ESO PROD → can only read PROD secret, cannot read QA
  Loki → can only write to Loki S3 bucket, nothing else
  ALB controller → can manage ELBs, nothing else
  EBS CSI → can manage EBS volumes, nothing else
```

### What's Not Zero Trust Yet

Full zero trust requires additional layers being added in the Kubernetes phase:

| Missing Layer | What It Does | When It's Added |
|--------------|-------------|----------------|
| Network Policies | Restrict pod-to-pod traffic between namespaces | Phase 2 (K8s) |
| Pod Security Standards | Prevent privileged containers, host networking | Phase 2 (K8s) |
| Image signing (Cosign) | Verify container images before deployment | Phase 4 (CI/CD) |
| mTLS / Service mesh | Encrypt and authenticate all pod-to-pod communication | Future |

The current infrastructure provides the **network foundation** for zero trust. The Kubernetes layer completes it.
