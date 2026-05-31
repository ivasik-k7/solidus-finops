###############################################################################
# Locals — resource-type catalog + IAM statement bundles
#
# `catalog` is the single source of truth for the six resource types this
# module manages (ebs / eip / snapshot / nat / eni / lb). Every downstream
# resource (Lambda, IAM, DLQ, log group, alarm, schedule, dashboard widget)
# `for_each`-es over local.enabled_types — the catalog entries with
# `enabled = true`.
#
# `iam_statements` is the per-resource-type bundle of mutating IAM
# permissions. Combined in iam.tf with the common (DDB / KMS / CW / SQS /
# SNS / X-Ray) statements via concat().
###############################################################################

locals {
  metric_namespace = "FinOps/IdleResources"

  # Friendly resource-type label per catalog key. Used as the ResourceType
  # CloudWatch dimension AND the dashboard widget metric expression.
  resource_type_label = {
    ebs      = "EBS"
    eip      = "EIP"
    snapshot = "EBSSnapshot"
    nat      = "NATGateway"
    eni      = "ENI"
    lb       = "LoadBalancer"
  }

  catalog = {
    ebs = {
      enabled = var.enable_ebs_cleanup
      handler = "ebs_cleanup.handler"
      source  = "ebs_cleanup.py"
      timeout = 900
      memory  = 512
      cron    = var.ebs_schedule
      env = {
        MIN_AGE_DAYS            = tostring(var.ebs_min_age_days)
        PENDING_GRACE_HOURS     = tostring(var.ebs_pending_grace_hours)
        PENDING_GRACE_MAX_HOURS = tostring(var.ebs_pending_grace_max_hours)
      }
    }
    eip = {
      enabled = var.enable_eip_cleanup
      handler = "eip_cleanup.handler"
      source  = "eip_cleanup.py"
      timeout = 300
      memory  = 256
      cron    = var.eip_schedule
      env     = {}
    }
    snapshot = {
      enabled = var.enable_snapshot_cleanup
      handler = "snapshot_cleanup.handler"
      source  = "snapshot_cleanup.py"
      timeout = 900
      memory  = 512
      cron    = var.snapshot_schedule
      env     = { MIN_AGE_DAYS = tostring(var.snapshot_min_age_days) }
    }
    nat = {
      enabled = var.enable_nat_cleanup
      handler = "nat_cleanup.handler"
      source  = "nat_cleanup.py"
      timeout = 600
      memory  = 256
      cron    = var.nat_schedule
      env = {
        MIN_AGE_DAYS         = tostring(var.nat_min_age_days)
        IDLE_LOOKBACK_DAYS   = tostring(var.nat_idle_lookback_days)
        IDLE_BYTES_THRESHOLD = tostring(var.nat_idle_bytes_threshold)
      }
    }
    eni = {
      enabled = var.enable_eni_cleanup
      handler = "eni_cleanup.handler"
      source  = "eni_cleanup.py"
      timeout = 300
      memory  = 256
      cron    = var.eni_schedule
      env     = { MIN_AGE_DAYS = tostring(var.eni_min_age_days) }
    }
    lb = {
      enabled = var.enable_lb_cleanup
      handler = "lb_cleanup.handler"
      source  = "lb_cleanup.py"
      timeout = 600
      memory  = 256
      cron    = var.lb_schedule
      env = {
        MIN_AGE_DAYS           = tostring(var.lb_min_age_days)
        IDLE_LOOKBACK_DAYS     = tostring(var.lb_idle_lookback_days)
        IDLE_REQUEST_THRESHOLD = tostring(var.lb_idle_request_threshold)
      }
    }
  }

  # Per-resource-type IAM statements. Mutation actions are granted regardless
  # of dry_run — IAM has no dry-run mode; the Lambda enforces it at runtime.
  iam_statements = {
    ebs = [
      {
        Effect = "Allow",
        Action = [
          "ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:DescribeTags",
          "ec2:CreateSnapshot", "ec2:DeleteVolume", "ec2:CreateTags",
          "ec2:DeleteTags",
        ],
        Resource = "*",
      },
    ]
    eip = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeAddresses", "ec2:ReleaseAddress"],
        Resource = "*",
      },
    ]
    snapshot = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeSnapshots", "ec2:DescribeImages", "ec2:DeleteSnapshot"],
        Resource = "*",
      },
    ]
    nat = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeNatGateways", "ec2:DeleteNatGateway"],
        Resource = "*",
      },
      {
        Effect   = "Allow",
        Action   = ["cloudwatch:GetMetricStatistics"],
        Resource = "*",
      },
    ]
    eni = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"],
        Resource = "*",
      },
    ]
    lb = [
      {
        Effect = "Allow",
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DeleteLoadBalancer",
        ],
        Resource = "*",
      },
      {
        Effect   = "Allow",
        Action   = ["cloudwatch:GetMetricStatistics"],
        Resource = "*",
      },
    ]
  }

  enabled_types = { for k, v in local.catalog : k => v if v.enabled }

  common_env = {
    DRY_RUN                    = tostring(var.dry_run)
    EXCEPTION_TAG_KEY          = var.exception_tag_key
    SNS_TOPIC_ARN              = var.events_topic_arn
    METRIC_NAMESPACE           = local.metric_namespace
    COST_CEILING_USD           = tostring(var.cost_ceiling_usd)
    FINDINGS_TABLE_NAME        = aws_dynamodb_table.findings.name
    AGING_SEEN_COUNT_THRESHOLD = tostring(var.aging_seen_count_threshold)
    FINDINGS_TTL_DAYS          = tostring(var.findings_ttl_days)
    ACTIONS_TTL_DAYS           = tostring(var.actions_ttl_days)
    SCAN_REGIONS               = jsonencode(length(var.scan_regions) > 0 ? var.scan_regions : [data.aws_region.current.region])
  }
}
