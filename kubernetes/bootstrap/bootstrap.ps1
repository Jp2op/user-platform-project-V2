# -----------------------------------------------------------------------------
# BOOTSTRAP — run ONCE after terraform apply
#
# Prerequisites:
#   - kubectl configured (run kubeconfig_command from terraform output)
#   - helm v3 installed
#   - terraform outputs available
#
# Usage: .\bootstrap.ps1
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------
# FILL THESE FROM: terraform output (in terraform/ directory)
# -----------------------------------------------------------------------

$AWS_REGION          = "ap-south-1"
$CLUSTER_NAME        = "uplatform-cluster"
$DOMAIN              = "jp2op-project.site"
$GITHUB_REPO         = "https://github.com/Jp2op/user-platform-project-V2"

# From terraform output:
$ALB_CONTROLLER_ROLE_ARN = "FILL_FROM_TERRAFORM_OUTPUT"
$ESO_QA_ROLE_ARN         = "FILL_FROM_TERRAFORM_OUTPUT"
$ESO_PROD_ROLE_ARN       = "FILL_FROM_TERRAFORM_OUTPUT"
$LOKI_ROLE_ARN           = "FILL_FROM_TERRAFORM_OUTPUT"
$ACM_CERT_ARN            = "FILL_FROM_TERRAFORM_OUTPUT"
$WAF_ACL_ARN             = "FILL_FROM_TERRAFORM_OUTPUT"

# DockerHub
$DOCKERHUB_USERNAME = "jayyp2op"
$DOCKERHUB_TOKEN    = "FILL_IN"

# Versions
$ARGOCD_VERSION      = "7.3.4"
$ALB_CONTROLLER_VERSION = "1.8.1"
$ESO_VERSION         = "0.9.19"
$GATEWAY_API_VERSION = "v1.2.1"

# -----------------------------------------------------------------------

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  Kubernetes Bootstrap" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

# Verify cluster access
Write-Host ">> Verifying cluster connectivity..." -ForegroundColor Yellow
try {
    kubectl cluster-info --request-timeout=10s 2>&1 | Out-Null
    Write-Host "   OK Cluster reachable" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Cannot reach cluster." -ForegroundColor Red
    Write-Host "Run: aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
    exit 1
}

# -----------------------------------------------------------------------
# STEP 1 — Namespaces
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Creating namespaces..." -ForegroundColor Yellow

foreach ($NS in @("argocd", "qa", "prod", "monitoring", "external-secrets")) {
    kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
}

kubectl label namespace qa   environment=qa   --overwrite 2>&1 | Out-Null
kubectl label namespace prod environment=prod --overwrite 2>&1 | Out-Null

Write-Host "   OK Namespaces ready" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 2 — DockerHub pull secrets
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Creating DockerHub pull secrets..." -ForegroundColor Yellow

foreach ($NS in @("qa", "prod")) {
    kubectl create secret docker-registry regcred `
        --docker-server=https://index.docker.io/v1/ `
        --docker-username="$DOCKERHUB_USERNAME" `
        --docker-password="$DOCKERHUB_TOKEN" `
        --namespace="$NS" `
        --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
}

Write-Host "   OK Pull secrets created" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 3 — IRSA service accounts for ESO
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Creating IRSA service accounts..." -ForegroundColor Yellow

# QA ESO
kubectl create serviceaccount eso-qa-sa `
    --namespace qa --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl annotate serviceaccount eso-qa-sa `
    --namespace qa `
    "eks.amazonaws.com/role-arn=$ESO_QA_ROLE_ARN" --overwrite 2>&1 | Out-Null

# PROD ESO
kubectl create serviceaccount eso-prod-sa `
    --namespace prod --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl annotate serviceaccount eso-prod-sa `
    --namespace prod `
    "eks.amazonaws.com/role-arn=$ESO_PROD_ROLE_ARN" --overwrite 2>&1 | Out-Null

# Loki (monitoring)
kubectl create serviceaccount loki `
    --namespace monitoring --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl annotate serviceaccount loki `
    --namespace monitoring `
    "eks.amazonaws.com/role-arn=$LOKI_ROLE_ARN" --overwrite 2>&1 | Out-Null

Write-Host "   OK IRSA service accounts ready" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 4 — Gateway API CRDs
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Installing Gateway API CRDs..." -ForegroundColor Yellow

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" 2>&1 | Out-Null

Write-Host "   OK Gateway API CRDs installed" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 5 — ALB Controller (with Gateway API enabled)
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Installing AWS Load Balancer Controller..." -ForegroundColor Yellow

helm repo add eks https://aws.github.io/eks-charts 2>&1 | Out-Null
helm repo update eks 2>&1 | Out-Null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
    --namespace kube-system `
    --version "$ALB_CONTROLLER_VERSION" `
    --set "clusterName=$CLUSTER_NAME" `
    --set "serviceAccount.create=true" `
    --set "serviceAccount.name=aws-load-balancer-controller" `
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_CONTROLLER_ROLE_ARN" `
    --set "enableGatewayAPI=true" `
    --wait --timeout 5m

Write-Host "   OK ALB Controller installed (Gateway API enabled)" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 6 — External Secrets Operator
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Installing External Secrets Operator..." -ForegroundColor Yellow

helm repo add external-secrets https://charts.external-secrets.io 2>&1 | Out-Null
helm repo update external-secrets 2>&1 | Out-Null

helm upgrade --install external-secrets external-secrets/external-secrets `
    --namespace external-secrets `
    --version "$ESO_VERSION" `
    --set installCRDs=true `
    --wait --timeout 5m

Write-Host "   OK ESO installed" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 7 — StorageClass + GatewayClass
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Applying StorageClass and GatewayClass..." -ForegroundColor Yellow

kubectl apply -f "$SCRIPT_DIR\storageclass.yaml"
kubectl apply -f "$SCRIPT_DIR\gatewayclass.yaml"

Write-Host "   OK StorageClass + GatewayClass created" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 8 — ArgoCD
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Installing ArgoCD..." -ForegroundColor Yellow

helm repo add argo https://argoproj.github.io/argo-helm 2>&1 | Out-Null
helm repo update argo 2>&1 | Out-Null

helm upgrade --install argocd argo/argo-cd `
    --namespace argocd `
    --version "$ARGOCD_VERSION" `
    --values "$SCRIPT_DIR\argocd-values.yaml" `
    --set "server.ingress.annotations.alb\.ingress\.kubernetes\.io/certificate-arn=$ACM_CERT_ARN" `
    --set "server.ingress.annotations.alb\.ingress\.kubernetes\.io/wafv2-acl-arn=$WAF_ACL_ARN" `
    --set "global.domain=argocd.$DOMAIN" `
    --wait --timeout 10m

Write-Host "   OK ArgoCD installed" -ForegroundColor Green

# -----------------------------------------------------------------------
# STEP 9 — ArgoCD Root App-of-Apps
# -----------------------------------------------------------------------
Write-Host ""
Write-Host ">> Applying root App-of-Apps..." -ForegroundColor Yellow

$rootAppContent = Get-Content "$SCRIPT_DIR\..\argocd-apps\root-app.yaml" -Raw
$rootAppContent = $rootAppContent -replace "GITHUB_REPO_URL", $GITHUB_REPO
$rootAppContent | kubectl apply -f - 2>&1 | Out-Null

Write-Host "   OK Root app applied — ArgoCD is now in control" -ForegroundColor Green

# -----------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  Bootstrap complete" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "ArgoCD UI: https://argocd.$DOMAIN"
Write-Host ""
Write-Host "Initial admin password:"
$password = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>$null
if ($password) {
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($password))
} else {
    Write-Host "  (not available yet — wait for ArgoCD pods to be ready)"
}
Write-Host ""
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. Open ArgoCD UI and verify apps are syncing"
Write-Host "  2. Get ALB DNS: kubectl get gateway -A"
Write-Host "  3. Fill alb_dns_name in terraform/terraform.tfvars"
Write-Host "  4. Push -> pipeline creates Route53 DNS records"
Write-Host ""
