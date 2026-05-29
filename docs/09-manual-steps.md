# Manual Steps

Every manual step required for the project, in order. Everything not listed here is automated.

## Phase 1 — Infrastructure (Terraform)

### Prerequisites (your machine)

- [ ] AWS CLI installed and configured (`aws configure` with AdministratorAccess user)
- [ ] Terraform >= 1.7 installed
- [ ] Git installed
- [ ] kubectl installed
- [ ] Helm installed (needed for K8s phase)

### Bootstrap (one-time, local)

- [ ] Fill `terraform/bootstrap/terraform.tfvars` with your `github_org` and `github_repo`
- [ ] Run `terraform init && terraform apply` inside `terraform/bootstrap/`
- [ ] Run `.\finish.ps1` (Windows) or `bash finish.sh` (Linux/Mac) to generate `backend.tf`
- [ ] Copy `github_oidc_provider_arn` from finish script output into `terraform/terraform.tfvars`
- [ ] Commit and push `terraform/backend.tf` and `terraform/terraform.tfvars`

### GitHub Configuration (one-time, UI)

**Secrets** (repo → Settings → Secrets and variables → Actions → New secret):

| Secret Name | Value | When To Add |
|------------|-------|-------------|
| `TF_PIPELINE_ROLE_ARN` | From bootstrap `terraform_pipeline_role_arn` output | After bootstrap |
| `AWS_REGION` | `ap-south-1` | After bootstrap |
| `AWS_ROLE_TO_ASSUME` | From main apply `github_qa_deploy_role_arn` output | After first apply |
| `AWS_ROLE_TO_ASSUME_PROD` | From main apply `github_prod_deploy_role_arn` output | After first apply |
| `DOCKERHUB_TOKEN` | From hub.docker.com → Settings → Security | Before app CI pipeline |

**Variables** (repo → Settings → Secrets and variables → Actions → Variables tab):

| Variable Name | Value | When To Add |
|--------------|-------|-------------|
| `DOCKERHUB_USERNAME` | `jayyp2op` | Before app CI pipeline |

**Environments** (repo → Settings → Environments):

- [ ] Create environment named `production`
- [ ] Set deployment branches to `main` only

### After First Successful Apply

- [ ] Grant your local IAM user EKS cluster access:
  ```bash
  aws eks create-access-entry \
    --cluster-name uplatform-cluster \
    --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<IAM_USER> \
    --region ap-south-1

  aws eks associate-access-policy \
    --cluster-name uplatform-cluster \
    --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<IAM_USER> \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster \
    --region ap-south-1
  ```
- [ ] Connect kubectl: `aws eks update-kubeconfig --region ap-south-1 --name uplatform-cluster`
- [ ] Verify: `kubectl get nodes` (should show 2 Ready nodes)
- [ ] Add `AWS_ROLE_TO_ASSUME` and `AWS_ROLE_TO_ASSUME_PROD` GitHub secrets from terraform outputs

### After Destroy + Recreate

When you destroy and recreate infrastructure, some steps need to be repeated:

- [ ] Grant IAM user EKS access again (new cluster = new access entries)
- [ ] Force delete Secrets Manager secrets if they're in deletion window:
  ```bash
  aws secretsmanager delete-secret --secret-id "uplatform/qa/mysql-secret" --force-delete-without-recovery --region ap-south-1
  aws secretsmanager delete-secret --secret-id "uplatform/prod/mysql-secret" --force-delete-without-recovery --region ap-south-1
  aws secretsmanager delete-secret --secret-id "uplatform/rds/root" --force-delete-without-recovery --region ap-south-1
  ```
- [ ] Unlock state if previous run was cancelled:
  ```powershell
  '{"LockID": {"S": "uplat-tf-state-796197769514/state.tfstate"}}' | Out-File -FilePath lock.json -Encoding ascii
  aws dynamodb delete-item --table-name uplat-tf-lock --region ap-south-1 --key file://lock.json
  ```

### Route53 (if domain bought outside AWS)

- [ ] Point domain nameservers to the Route53 hosted zone NS records

### After ALB Exists (K8s phase)

- [ ] Get ALB DNS: `kubectl get ingress -A`
- [ ] Fill `alb_dns_name` in `terraform/terraform.tfvars`
- [ ] Push — pipeline creates Route53 DNS records

---

## Phase 2 — Kubernetes

*Steps will be added when this phase is complete.*

## Phase 3 — Docker

*Steps will be added when this phase is complete.*

## Phase 4 — CI/CD Pipelines

*Steps will be added when this phase is complete.*

## Phase 5 — Monitoring

*Steps will be added when this phase is complete.*
