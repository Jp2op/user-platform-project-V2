output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Used by ALB and NAT gateway"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Used by EKS node group"
  value       = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  description = "Used by RDS subnet group"
  value       = aws_subnet.isolated[*].id
}

output "vpc_endpoints_security_group_id" {
  description = "SG attached to interface VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}
