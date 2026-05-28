# -----------------------------------------------------------------------------
# VPC MODULE
#
# Creates the network foundation.
# Simplified for a project environment — single AZ, 3 subnets:
#
#   Public subnet   — ALB lives here (internet-facing)
#   Private subnet  — EKS nodes live here (no direct internet, egress via NAT)
#   Isolated subnet — RDS lives here (no internet route at all)
#
# Scaling up to multi-AZ later: add more CIDRs to the subnet list variables.
# The module handles any number of subnets via count — no code changes needed.
#
# CIDR layout (within the /16 VPC):
#   10.0.0.0/16    VPC
#   10.0.1.0/24    Public  (ALB)
#   10.0.10.0/24   Private (EKS nodes)
#   10.0.20.0/24   Isolated (RDS)
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true  # required for EKS node registration
  enable_dns_support   = true  # required for VPC endpoint DNS resolution

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
    # EKS uses this tag to discover the VPC
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# -----------------------------------------------------------------------------
# INTERNET GATEWAY
# Public subnet routes 0.0.0.0/0 here.
# Private and isolated subnets do NOT route here.
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

# -----------------------------------------------------------------------------
# PUBLIC SUBNET — ALB lives here
#
# Tags:
#   kubernetes.io/role/elb = 1  tells ALB controller this subnet is for
#                               internet-facing ALBs
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # No auto-assign public IP — only the ALB needs a public IP, and AWS
  # handles that automatically when the ALB is internet-facing
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-${data.aws_availability_zones.available.names[count.index]}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# -----------------------------------------------------------------------------
# PRIVATE SUBNET — EKS nodes live here
#
# Nodes have no public IP. Outbound goes via NAT gateway.
# Inbound only from ALB (enforced by security groups, not routing).
#
# Tags:
#   kubernetes.io/role/internal-elb = 1  for internal ALBs if ever needed
#   kubernetes.io/cluster/...= owned     EKS manages these subnet resources
# -----------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-${data.aws_availability_zones.available.names[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# -----------------------------------------------------------------------------
# ISOLATED SUBNET — RDS lives here
#
# No route to internet — not even via NAT gateway.
# The only traffic allowed is MySQL (3306) from EKS node security group.
# Even if RDS were misconfigured as publicly accessible, it cannot be reached
# because there is no route out of this subnet.
# -----------------------------------------------------------------------------

resource "aws_subnet" "isolated" {
  count = length(var.isolated_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.isolated_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name = "${var.project_name}-isolated-${data.aws_availability_zones.available.names[count.index]}"
  })
}

# -----------------------------------------------------------------------------
# ELASTIC IP + NAT GATEWAY
#
# Single NAT gateway (cost saving — one is enough for a project).
# Lives in the first public subnet.
# Private subnet routes all outbound traffic through it.
# Isolated subnet has NO route to NAT — intentional.
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-eip"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# ROUTE TABLES
# -----------------------------------------------------------------------------

# Public — all outbound goes to internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private — outbound goes via NAT gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Isolated — no routes to internet at all
# Only VPC-local traffic (to RDS from EKS nodes within the VPC) is allowed
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.main.id

  # Intentionally no default route — RDS cannot initiate outbound connections

  tags = merge(var.tags, {
    Name = "${var.project_name}-isolated-rt"
  })
}

resource "aws_route_table_association" "isolated" {
  count          = length(aws_subnet.isolated)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

# -----------------------------------------------------------------------------
# VPC ENDPOINTS
#
# Without endpoints, traffic from EKS nodes to AWS services (ECR, Secrets
# Manager, STS) goes: node → NAT gateway → internet → AWS API
# With endpoints, it goes: node → endpoint → AWS API  (never leaves AWS)
#
# Benefits:
#   Security  — traffic stays on AWS private network
#   Cost      — NAT gateway charges $0.045/GB. ECR image pulls are large.
#               VPC endpoints eliminate that NAT cost for AWS service traffic.
#   Latency   — one fewer hop
#
# S3 gateway endpoint is free. Interface endpoints cost ~$7/month each.
# For a project we keep only the high-value ones:
#   S3              — free, image layers cached here, Loki logs go here
#   ECR API + DKR   — image pulls (large, frequent)
#   Secrets Manager — ESO calls this on every secret sync
#   STS             — IRSA token exchange, called on every pod start
# -----------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints-sg"
  description = "Allow HTTPS from VPC CIDR to interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc-endpoints-sg"
  })
}

# S3 Gateway Endpoint — free, no SG needed, works via route table
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.isolated.id,
  ]

  tags = merge(var.tags, {
    Name = "${var.project_name}-s3-endpoint"
  })
}

# ECR API — docker pull authentication
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-ecr-api-endpoint"
  })
}

# ECR DKR — image layer transfers
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-ecr-dkr-endpoint"
  })
}

# Secrets Manager — ESO fetches secrets through here
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-secretsmanager-endpoint"
  })
}

# STS — IRSA token exchange on every pod startup
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-sts-endpoint"
  })
}
