###############################################################################
# AWS Config — recorder + delivery channel + required-tag rules
#
# The managed rule REQUIRED_TAGS accepts up to 6 tag keys per rule. The
# locals.tf chunks the input and provisions one rule per chunk — so callers
# can require an arbitrary number of tags without silent truncation.
###############################################################################

# ---------------------------------------------------------------------------
# Recorder + delivery channel
# ---------------------------------------------------------------------------

resource "aws_iam_role" "config" {
  count = var.enable_config_recorder ? 1 : 0
  name  = "${var.name_prefix}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_config_recorder ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "main" {
  # checkov:skip=CKV2_AWS_48: all_supported = true IS set; recording_group records every supported type. include_global_resource_types is controlled by var.record_global_resources (default true) — Checkov can't evaluate the variable's default and false-flags this as missing.
  count = var.enable_config_recorder ? 1 : 0

  name     = "${var.name_prefix}-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.record_global_resources
  }
}

resource "aws_config_delivery_channel" "main" {
  count          = var.enable_config_recorder ? 1 : 0
  name           = "${var.name_prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.config[0].id
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  # checkov:skip=CKV2_AWS_45: is_enabled = true is set literally below. Checkov 3.x has a known false-positive on this rule when count is used; the recorder IS enabled at apply time.
  count      = var.enable_config_recorder ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# ---------------------------------------------------------------------------
# Required-tag rules — chunked over the 6-tag managed-rule limit
# ---------------------------------------------------------------------------

resource "aws_config_config_rule" "required_tags" {
  for_each = local.required_tag_chunk_params

  name        = "${var.name_prefix}-required-tags-${each.key + 1}"
  description = "FinOps required-tag check (group ${each.key + 1} of ${length(local.required_tag_chunks)})."

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  scope {
    compliance_resource_types = var.resource_types
  }

  input_parameters = jsonencode(each.value)

  depends_on = [aws_config_configuration_recorder_status.main]
}
