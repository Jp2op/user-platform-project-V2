#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# BOOTSTRAP — run ONCE after terraform apply
#
# Prerequisites:
#   - kubectl configured (run kubeconfig_command from terraform output)
#   - helm v3 installed
#   - terraform outputs available
#
# What this does:
#   1. Creates namespaces
#   2. Creates DockerHub pull secrets
#   3. Creates IRSA-annotated service accounts for ESO
#   4. Installs Gateway API CRDs
#   5. Installs ALB controller (with Gateway API enabled)
#   6. Installs External Secrets Operator
#   7. Creates EBS StorageClass + GatewayClass
#   8. Installs ArgoCD
#   9. Applies root App-of-Apps → ArgoCD manages everything else
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------
# FILL THESE FROM: terraform output (in terraform/ directory)
# -----------------------------------------------------------------------

AWS_REGION="ap-south-1"
CLUSTER_NAME="uplatform-cluster"
DOMAIN="jp2op-project.site"
GITHUB_REPO="https://github.com/Jp2op/user-platform-project-V2"

# From terraform output:
ALB_CONTROLLER_ROLE_ARN="FILL_FROM_TERRAFORM_OUTPUT"
ESO_QA_ROLE_ARN="FILL_FROM_TERRAFORM_OUTPUT"
ESO_PROD_ROLE_ARN="FILL_FROM_TERRAFORM_OUTPUT"
LOKI_ROLE_ARN="FILL_FROM_TERRAFORM_OUTPUT"
ACM_CERT_ARN="FILL_FROM_TERRAFORM_OUTPUT"
WAF_ACL_ARN="FILL_FROM_TERRAFORM_OUTPUT"

# DockerHub
DOCKERHUB_USERNAME="jayyp2op"
DOCKERHUB_TOKEN="FILL_IN"

# Versions
ARGOCD_VERSION="7.3.4"
ALB_CONTROLLER_VERSION="1.8.1"
ESO_VERSION="0.9.19"
GATEWAY_API_VERSION="v1.2.1"

# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Kubernetes Bootstrap"
echo "═══════════════════════════════════════════════════"
echo ""

# Verify cluster access
echo "▶ Verifying cluster connectivity..."
kubectl cluster-info --request-timeout=10s > /dev/null 2>&1 || {
  echo "ERROR: Cannot reach cluster."
  echo "Run: aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
  exit 1
}
echo "  ✓ Cluster reachable"

# -----------------------------------------------------------------------
# STEP 1 — Namespaces
# -----------------------------------------------------------------------
echo ""
echo "▶ Creating namespaces..."

for NS in argocd qa prod monitoring external-secrets; do
  kubectl create namespace "$NS" \
    --dry-run=client -o yaml | kubectl apply -f -
done

kubectl label namespace qa   environment=qa   --overwrite
kubectl label namespace prod environment=prod --overwrite

echo "  ✓ Namespaces ready"

# -----------------------------------------------------------------------
# STEP 2 — DockerHub pull secrets
# -----------------------------------------------------------------------
echo ""
echo "▶ Creating DockerHub pull secrets..."

for NS in qa prod; do
  kubectl create secret docker-registry regcred \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="$DOCKERHUB_USERNAME" \
    --docker-password="$DOCKERHUB_TOKEN" \
    --namespace="$NS" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo "  ✓ Pull secrets created"

# -----------------------------------------------------------------------
# STEP 3 — IRSA service accounts for ESO
# -----------------------------------------------------------------------
echo ""
echo "▶ Creating IRSA service accounts..."

# QA ESO
kubectl create serviceaccount eso-qa-sa \
  --namespace qa --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount eso-qa-sa \
  --namespace qa \
  "eks.amazonaws.com/role-arn=$ESO_QA_ROLE_ARN" --overwrite

# PROD ESO
kubectl create serviceaccount eso-prod-sa \
  --namespace prod --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount eso-prod-sa \
  --namespace prod \
  "eks.amazonaws.com/role-arn=$ESO_PROD_ROLE_ARN" --overwrite

# Loki (monitoring)
kubectl create serviceaccount loki \
  --namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount loki \
  --namespace monitoring \
  "eks.amazonaws.com/role-arn=$LOKI_ROLE_ARN" --overwrite

echo "  ✓ IRSA service accounts ready"

# -----------------------------------------------------------------------
# STEP 4 — Gateway API CRDs
# Gateway API is not installed by default in Kubernetes.
# These CRDs define Gateway, HTTPRoute, GatewayClass resources.
# Must be installed BEFORE the ALB controller starts watching for them.
# -----------------------------------------------------------------------
echo ""
echo "▶ Installing Gateway API CRDs..."

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "  ✓ Gateway API CRDs installed"

# -----------------------------------------------------------------------
# STEP 5 — ALB Controller (with Gateway API enabled)
# -----------------------------------------------------------------------
echo ""
echo "▶ Installing AWS Load Balancer Controller..."

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "$ALB_CONTROLLER_VERSION" \
  --set "clusterName=$CLUSTER_NAME" \
  --set "serviceAccount.create=true" \
  --set "serviceAccount.name=aws-load-balancer-controller" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_CONTROLLER_ROLE_ARN" \
  --set "enableGatewayAPI=true" \
  --wait --timeout 5m

echo "  ✓ ALB Controller installed (Gateway API enabled)"

# -----------------------------------------------------------------------
# STEP 6 — External Secrets Operator
# -----------------------------------------------------------------------
echo ""
echo "▶ Installing External Secrets Operator..."

helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --version "$ESO_VERSION" \
  --set installCRDs=true \
  --wait --timeout 5m

echo "  ✓ ESO installed"

# -----------------------------------------------------------------------
# STEP 7 — StorageClass + GatewayClass
# -----------------------------------------------------------------------
echo ""
echo "▶ Applying StorageClass and GatewayClass..."

kubectl apply -f "$SCRIPT_DIR/storageclass.yaml"
kubectl apply -f "$SCRIPT_DIR/gatewayclass.yaml"

echo "  ✓ StorageClass + GatewayClass created"

# -----------------------------------------------------------------------
# STEP 8 — ArgoCD
# -----------------------------------------------------------------------
echo ""
echo "▶ Installing ArgoCD..."

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "$ARGOCD_VERSION" \
  --values "$SCRIPT_DIR/argocd-values.yaml" \
  --set "server.ingress.annotations.alb\.ingress\.kubernetes\.io/certificate-arn=$ACM_CERT_ARN" \
  --set "server.ingress.annotations.alb\.ingress\.kubernetes\.io/wafv2-acl-arn=$WAF_ACL_ARN" \
  --set "global.domain=argocd.$DOMAIN" \
  --wait --timeout 10m

echo "  ✓ ArgoCD installed"

# -----------------------------------------------------------------------
# STEP 9 — ArgoCD Root App-of-Apps
# -----------------------------------------------------------------------
echo ""
echo "▶ Applying root App-of-Apps..."

sed "s|GITHUB_REPO_URL|$GITHUB_REPO|g" \
  "$SCRIPT_DIR/../argocd-apps/root-app.yaml" \
  | kubectl apply -f -

echo "  ✓ Root app applied — ArgoCD is now in control"

# -----------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Bootstrap complete"
echo "═══════════════════════════════════════════════════"
echo ""
echo "ArgoCD UI: https://argocd.$DOMAIN"
echo ""
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
echo ""
echo "Next:"
echo "  1. Open ArgoCD UI and verify apps are syncing"
echo "  2. Get ALB DNS: kubectl get gateway -A"
echo "  3. Fill alb_dns_name in terraform/terraform.tfvars"
echo "  4. Push → pipeline creates Route53 DNS records"
echo ""
