output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_ca_data" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "Used by IAM module to create IRSA trust policies"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "Used by IAM module to create IRSA trust policies"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_security_group_id" {
  description = "Used by RDS module to allow MySQL from nodes only"
  value       = aws_security_group.nodes.id
}

output "node_role_arn" {
  value = aws_iam_role.nodes.arn
}

output "node_role_name" {
  description = "Used by monitoring module to attach Loki S3 policy to nodes"
  value       = aws_iam_role.nodes.name
}
