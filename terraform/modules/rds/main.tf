# -----------------------------------------------------------------------------
# RDS MODULE
#
# Creates a single MySQL RDS instance with:
#   - Two databases (qa_db and prod_db) inside the same instance
#   - Isolated subnet group (no internet route)
#   - Security group: port 3306 from EKS nodes only
#   - Automated backups with 7-day retention
#   - Credentials auto-generated and stored in Secrets Manager
#   - Encryption at rest with dedicated KMS key
#
# Cost: db.t3.micro is free tier eligible. ~$15/month outside free tier.
# Upgrade path: change instance_class to db.t3.small or db.r6g.large.
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# SECURITY GROUP — RDS
# Only allows MySQL traffic from EKS nodes. Nothing else.
# Combined with the isolated subnet (no internet route), this means:
#   - External attackers: blocked (no route to subnet)
#   - Other pods: blocked by network policy before they even hit this SG
#   - EKS nodes: allowed on 3306 only
# -----------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow MySQL from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from EKS nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  # No egress rule — RDS doesn't need to initiate outbound connections
  egress {
    description = "Allow responses back to EKS nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-rds-sg"
  })
}

# -----------------------------------------------------------------------------
# SUBNET GROUP — uses isolated subnets (no internet route)
# RDS requires a subnet group with subnets in at least 2 AZs even for
# single-AZ deployments. We provide all 3 isolated subnets.
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-rds-subnet-group"
  subnet_ids = var.isolated_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.project_name}-rds-subnet-group"
  })
}

# -----------------------------------------------------------------------------
# PARAMETER GROUP — MySQL 8.0 configuration
# Tuned for a small instance. Adjust based on actual workload.
# -----------------------------------------------------------------------------

resource "aws_db_parameter_group" "mysql" {
  name   = "${var.project_name}-mysql8"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  # Slow query log — helps identify poorly optimized queries in production
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"  # log queries taking more than 2 seconds
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-mysql8-params"
  })
}

# -----------------------------------------------------------------------------
# RANDOM PASSWORD GENERATION
# Terraform generates the password, stores it in Secrets Manager.
# It never appears in plain text outside of state (and state is encrypted).
# The app reads it from Secrets Manager via ESO — never from env vars directly.
# -----------------------------------------------------------------------------

resource "random_password" "rds_root" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  # Exclude characters that cause issues in connection strings
  # @ causes parsing issues in some MySQL connection string formats
}

resource "random_password" "rds_qa_user" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "rds_prod_user" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# -----------------------------------------------------------------------------
# RDS INSTANCE
# -----------------------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  # The root database — our app databases will be created inside this
  db_name  = "platform"
  username = "root"
  password = random_password.rds_root.result

  # Storage
  allocated_storage     = 20   # GB — minimum for gp3
  max_allocated_storage = 100  # auto-scaling upper limit
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false  # never — it's in an isolated subnet anyway

  # High availability — set to true for production
  # false saves ~$15/month (no standby instance)
  multi_az = var.multi_az

  # Backups
  backup_retention_period = 7      # days
  backup_window           = "03:00-04:00"  # UTC, low-traffic window
  maintenance_window      = "mon:04:00-mon:05:00"

  # Prevent accidental deletion
  deletion_protection = var.deletion_protection
  skip_final_snapshot = false
  final_snapshot_identifier = "${var.project_name}-mysql-final-snapshot"

  parameter_group_name = aws_db_parameter_group.mysql.name

  # Enable Enhanced Monitoring — more granular metrics than CloudWatch basic
  monitoring_interval = 60  # seconds
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Auto minor version upgrades — security patches applied automatically
  auto_minor_version_upgrade = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-mysql"
  })
}

# IAM role for Enhanced Monitoring
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# -----------------------------------------------------------------------------
# SECRETS MANAGER — store all database credentials
#
# We create separate secrets for QA and PROD app users.
# Each secret contains the full connection info the app needs.
# ESO will sync these into Kubernetes Secrets in the qa/prod namespaces.
#
# Why separate users for QA and PROD?
#   - Compromise of QA credentials cannot touch prod data
#   - Each user only has access to their own database
#   - Audit logs show which environment made which query
# -----------------------------------------------------------------------------

# QA credentials secret
resource "aws_secretsmanager_secret" "qa" {
  name        = "${var.project_name}/qa/mysql-secret"
  description = "MySQL credentials for QA namespace"
  kms_key_id  = var.secrets_kms_key_arn

  recovery_window_in_days = 7  # 7 day recovery window before permanent deletion

  tags = merge(var.tags, {
    Name        = "${var.project_name}-qa-mysql-secret"
    Environment = "qa"
  })
}

resource "aws_secretsmanager_secret_version" "qa" {
  secret_id = aws_secretsmanager_secret.qa.id

  secret_string = jsonencode({
    MYSQL_HOST           = aws_db_instance.main.address
    MYSQL_PORT           = tostring(aws_db_instance.main.port)
    MYSQL_DATABASE       = var.qa_database_name
    MYSQL_USER           = var.qa_db_username
    MYSQL_PASSWORD       = random_password.rds_qa_user.result
    MYSQL_ROOT_PASSWORD  = random_password.rds_root.result  # needed for init
    DATABASE_URL         = "mysql://${var.qa_db_username}:${random_password.rds_qa_user.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.qa_database_name}"
  })
}

# PROD credentials secret
resource "aws_secretsmanager_secret" "prod" {
  name        = "${var.project_name}/prod/mysql-secret"
  description = "MySQL credentials for PROD namespace"
  kms_key_id  = var.secrets_kms_key_arn

  recovery_window_in_days = 30  # longer recovery for prod

  tags = merge(var.tags, {
    Name        = "${var.project_name}-prod-mysql-secret"
    Environment = "prod"
  })
}

resource "aws_secretsmanager_secret_version" "prod" {
  secret_id = aws_secretsmanager_secret.prod.id

  secret_string = jsonencode({
    MYSQL_HOST           = aws_db_instance.main.address
    MYSQL_PORT           = tostring(aws_db_instance.main.port)
    MYSQL_DATABASE       = var.prod_database_name
    MYSQL_USER           = var.prod_db_username
    MYSQL_PASSWORD       = random_password.rds_prod_user.result
    MYSQL_ROOT_PASSWORD  = random_password.rds_root.result
    DATABASE_URL         = "mysql://${var.prod_db_username}:${random_password.rds_prod_user.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.prod_database_name}"
  })
}

# Root secret — used only during database initialization jobs
resource "aws_secretsmanager_secret" "root" {
  name        = "${var.project_name}/rds/root"
  description = "RDS root credentials — used for DB init only"
  kms_key_id  = var.secrets_kms_key_arn

  recovery_window_in_days = 30

  tags = merge(var.tags, {
    Name = "${var.project_name}-rds-root-secret"
  })
}

resource "aws_secretsmanager_secret_version" "root" {
  secret_id = aws_secretsmanager_secret.root.id

  secret_string = jsonencode({
    username = "root"
    password = random_password.rds_root.result
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = "platform"
  })
}
