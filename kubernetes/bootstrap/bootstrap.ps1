$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# CONFIGURATION — fill these from terraform output after each apply
# Role ARNs are stable across destroy/recreate. Cert, WAF, VPC change.
# -----------------------------------------------------------------------------

$AWS_REGION          = "ap-south-1"
$CLUSTER_NAME        = "uplatform-cluster"
$DOMAIN              = "jp2op-project.site"
$GITHUB_REPO         = "https://github.com/Jp2op/user-platform-project-V2"

# From terraform output (role ARNs are stable, don't change per recreate)
$ALB_CONTROLLER_ROLE_ARN = "arn:aws:iam::796197769514:role/uplatform-alb-controller-role"
$ESO_QA_ROLE_ARN         = "arn:aws:iam::796197769514:role/uplatform-eso-qa-role"
$ESO_PROD_ROLE_ARN       = "arn:aws:iam::796197769514:role/uplatform-eso-prod-role"
$LOKI_ROLE_ARN           = "arn:aws:iam::796197769514:role/uplatform-loki-role"
$EXTERNAL_DNS_ROLE_ARN   = "arn:aws:iam::796197769514:role/uplatform-external-dns-role"

# From terraform output (these CHANGE on every destroy/recreate)
$ACM_CERT_ARN = "arn:aws:acm:ap-south-1:796197769514:certificate/d52286ef-3e36-405d-84ee-8962ef43fb00"
$WAF_ACL_ARN  = "arn:aws:wafv2:ap-south-1:796197769514:regional/webacl/uplatform-waf/40de3f5b-5095-440f-b283-65737917a3fb"
$VPC_ID       = "vpc-04cc0ab3c2c119fb3"

# DockerHub credentials
$DOCKERHUB_USERNAME = "jayyp2op"
$DOCKERHUB_TOKEN    = "dckr_pat_VUUGhpGJRFlW52WU5BwXGOcG2n8"

# Component versions
$ARGOCD_VERSION         = "7.3.4"
$ALB_CONTROLLER_VERSION = "3.4.0"
$ESO_VERSION            = "0.9.19"
$GATEWAY_API_VERSION    = "v1.2.1"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '  Kubernetes Bootstrap' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ''

# ─── Cluster connectivity ────────────────────────────────────────────────────
Write-Host '>> Verifying cluster connectivity...' -ForegroundColor Yellow
try {
    kubectl cluster-info --request-timeout=10s 2>&1 | Out-Null
    Write-Host '   OK Cluster reachable' -ForegroundColor Green
} catch {
    Write-Host 'ERROR: Cannot reach cluster.' -ForegroundColor Red
    Write-Host "Run: aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
    exit 1
}

# ─── Namespaces ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '>> Creating namespaces...' -ForegroundColor Yellow
foreach ($NS in @('argocd', 'qa', 'prod', 'monitoring', 'external-secrets')) {
    kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
}
kubectl label namespace qa   environment=qa   --overwrite 2>&1 | Out-Null
kubectl label namespace prod environment=prod --overwrite 2>&1 | Out-Null
Write-Host '   OK Namespaces ready' -ForegroundColor Green

# ─── DockerHub pull secrets ──────────────────────────────────────────────────
Write-Host ''
Write-Host '>> Creating DockerHub pull secrets...' -ForegroundColor Yellow
foreach ($NS in @('qa', 'prod')) {
    kubectl create secret docker-registry regcred `
        --docker-server=https://index.docker.io/v1/ `
        --docker-username="$DOCKERHUB_USERNAME" `
        --docker-password="$DOCKERHUB_TOKEN" `
        --namespace="$NS" `
        --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
}
Write-Host '   OK Pull secrets created' -ForegroundColor Green

# ─── IRSA service accounts ──────────────────────────────────────────────────
Write-Host ''
Write-Host '>> Creating IRSA service accounts...' -ForegroundColor Yellow

kubectl create serviceaccount eso-qa-sa `
    --namespace qa --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl annotate serviceaccount eso-qa-sa `
    --namespace qa `
    "eks.amazonaws.com/role-arn=$ESO_QA_ROLE_ARN" --overwrite 2>&1 | Out-Null

kubectl create serviceaccount eso-prod-sa `
    --namespace prod --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl annotate serviceaccount eso-prod-sa `
    --namespace prod `
    "eks.amazonaws.com/role-arn=$ESO_PROD_ROLE_ARN" --overwrite 2>&1 | Out-Null

kubectl create serviceaccount loki `
    --namespace monitoring --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl annotate serviceaccount loki `
    --namespace monitoring `
    "eks.amazonaws.com/role-arn=$LOKI_ROLE_ARN" --overwrite 2>&1 | Out-Null

Write-Host '   OK IRSA service accounts ready' -ForegroundColor Green

# ─── Gateway API CRDs ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '>> Installing Gateway API CRDs...' -ForegroundColor Yellow

# Standard Gateway API CRDs (GatewayClass, Gateway, HTTPRoute, etc.)
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/experimental-install.yaml" 2>&1 | Out-Null

Write-Host '   OK Gateway API CRDs installed' -ForegroundColor Green

# ─── AWS Load Balancer Controller ────────────────────────────────────────────
Write-Host ''
Write-Host '>> Installing AWS Load Balancer Controller v3.4.0...' -ForegroundColor Yellow
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
    --set "vpcId=$VPC_ID" `
    --wait --timeout 5m

# v3.x bundles AWS-specific Gateway CRDs (TargetGroupConfiguration,
# LoadBalancerConfiguration, ListenerRuleConfiguration) but Helm doesn't
# update CRDs on upgrade. Apply them explicitly via --include-crds.
Write-Host '>> Installing AWS Gateway API CRDs (TargetGroupConfiguration, etc.)...' -ForegroundColor Yellow
helm template aws-lb-crds eks/aws-load-balancer-controller `
    --version "$ALB_CONTROLLER_VERSION" `
    --set "enableGatewayAPI=true" `
    --set "clusterName=$CLUSTER_NAME" `
    --include-crds `
    | kubectl apply --server-side --force-conflicts -f - 2>&1 | Out-Null

Write-Host '   OK ALB Controller installed (Gateway API enabled)' -ForegroundColor Green

# ─── ExternalDNS ─────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '>> Installing ExternalDNS...' -ForegroundColor Yellow
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns 2>&1 | Out-Null
helm repo update external-dns 2>&1 | Out-Null

helm upgrade --install external-dns external-dns/external-dns `
    --namespace kube-system `
    --set "provider.name=aws" `
    --set "domainFilters[0]=$DOMAIN" `
    --set "policy=sync" `
    --set "txtOwnerId=$CLUSTER_NAME" `
    --set "sources[0]=ingress" `
    --set "sources[1]=gateway-httproute" `
    --set "serviceAccount.create=true" `
    --set "serviceAccount.name=external-dns" `
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$EXTERNAL_DNS_ROLE_ARN" `
    --wait --timeout 5m

Write-Host '   OK ExternalDNS installed' -ForegroundColor Green

# ─── External Secrets Operator ───────────────────────────────────────────────
Write-Host ''
Write-Host '>> Installing External Secrets Operator...' -ForegroundColor Yellow
helm repo add external-secrets https://charts.external-secrets.io 2>&1 | Out-Null
helm repo update external-secrets 2>&1 | Out-Null

helm upgrade --install external-secrets external-secrets/external-secrets `
    --namespace external-secrets `
    --version "$ESO_VERSION" `
    --set installCRDs=true `
    --wait --timeout 5m

Write-Host '   OK ESO installed' -ForegroundColor Green

# ─── StorageClass + GatewayClass ─────────────────────────────────────────────
Write-Host ''
Write-Host '>> Applying StorageClass and GatewayClass...' -ForegroundColor Yellow
kubectl apply -f "$SCRIPT_DIR\storageclass.yaml"
kubectl apply -f "$SCRIPT_DIR\gatewayclass.yaml"
Write-Host '   OK StorageClass + GatewayClass created' -ForegroundColor Green

# ─── ArgoCD ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '>> Installing ArgoCD...' -ForegroundColor Yellow
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

Write-Host '   OK ArgoCD installed' -ForegroundColor Green

# ─── Root App-of-Apps ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '>> Applying root App-of-Apps...' -ForegroundColor Yellow
$rootAppContent = Get-Content "$SCRIPT_DIR\..\argocd-apps\root-app.yaml" -Raw
$rootAppContent = $rootAppContent -replace 'GITHUB_REPO_URL', $GITHUB_REPO
$rootAppContent | kubectl apply -f - 2>&1 | Out-String | Out-Null
Write-Host '   OK Root app applied - ArgoCD is now in control' -ForegroundColor Green

# ─── Done ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '  Bootstrap complete' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ''
$argoUrl = 'https://argocd.' + $DOMAIN
Write-Host "ArgoCD UI: $argoUrl"
Write-Host ''
Write-Host 'Initial admin password:'
$password = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>$null
if ($password) {
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($password))
} else {
    Write-Host '  (not available yet - wait for ArgoCD pods to be ready)'
}
Write-Host ''
Write-Host 'Next:' -ForegroundColor Yellow
Write-Host '  1. Open ArgoCD UI and verify apps are syncing'
Write-Host '  2. ExternalDNS auto-creates DNS records - no action needed'
Write-Host "  3. Wait 2-3 min, then access $argoUrl"
Write-Host ''
