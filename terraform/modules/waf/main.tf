# -----------------------------------------------------------------------------
# WAF MODULE
#
# AWS WAF v2 WebACL with:
#   - AWS Managed Rules (AWSManagedRulesCommonRuleSet) — OWASP top 10
#   - AWS Managed Rules (AWSManagedRulesKnownBadInputsRuleSet) — bad bots
#   - AWS Managed Rules (AWSManagedRulesSQLiRuleSet) — SQL injection
#   - IP reputation list (AWSManagedRulesAmazonIpReputationList) — known bad IPs
#   - Rate limiting — 2000 requests per 5 minutes per IP
#
# Associated to the ALB that fronts EKS.
# CloudFront has its own WAF association (must be in us-east-1 for CF).
# This WAF is regional (ap-south-1) for the ALB.
#
# Cost: ~$5/month base + $0.60 per million requests
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

resource "aws_wafv2_web_acl" "main" {
  name        = "${var.project_name}-waf"
  description = "WAF for ${var.project_name} ALB"
  scope       = "REGIONAL"  # REGIONAL for ALB; CLOUDFRONT for CloudFront (needs us-east-1 provider)

  default_action {
    allow {}  # default allow — rules below block specific bad traffic
  }

  # Rule 1: IP Reputation — blocks known malicious IPs (botnets, scrapers, attackers)
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 1

    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Common Rule Set — OWASP Top 10 protections
  # Blocks: XSS, path traversal, file inclusion, protocol attacks
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # SizeRestrictions_BODY can cause false positives with large API payloads
        # Override to COUNT instead of BLOCK so we can monitor before enforcing
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use { count {} }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: Known Bad Inputs — blocks request patterns known to exploit vulnerabilities
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: SQL Injection — dedicated SQL injection protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 4

    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 5: Rate limiting — prevents brute force and DDoS
  # 2000 requests per 5 minutes per IP. Adjust based on your traffic patterns.
  rule {
    name     = "RateLimitPerIP"
    priority = 5

    action { block {} }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-waf"
  })
}

# WAF logs to CloudWatch — useful for debugging blocked requests
resource "aws_cloudwatch_log_group" "waf" {
  # WAF log group names must start with aws-waf-logs-
  name              = "aws-waf-logs-${var.project_name}"
  retention_in_days = 30

  tags = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  # Log all requests (both allowed and blocked)
  # In high-traffic scenarios, enable redacted_fields to exclude sensitive data
}
