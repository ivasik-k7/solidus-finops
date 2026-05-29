"""
Idle NAT Gateway detector with multi-region scanning, CloudWatch-based
utilization signal, and DDB-backed state lifecycle.
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
from typing import Any

import boto3
from botocore.config import Config

import idle_state

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"
MIN_AGE_DAYS = int(os.environ.get("MIN_AGE_DAYS", "14"))
IDLE_LOOKBACK_DAYS = int(os.environ.get("IDLE_LOOKBACK_DAYS", "7"))
IDLE_BYTES_THRESHOLD = int(os.environ.get("IDLE_BYTES_THRESHOLD", "1048576"))
EXCEPTION_TAG_KEY = os.environ.get("EXCEPTION_TAG_KEY", "FinOpsException")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FinOps/IdleResources")
NAT_MONTHLY_USD = float(os.environ.get("NAT_MONTHLY_USD", "32.40"))
COST_CEILING_USD = float(os.environ.get("COST_CEILING_USD", "100"))
SCAN_REGIONS: list[str] = json.loads(os.environ.get("SCAN_REGIONS", "[]"))

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts")

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"


def handler(event, context):
    logger.info("NAT scan: dry_run=%s min_age=%sd lookback=%sd regions=%s",
                DRY_RUN, MIN_AGE_DAYS, IDLE_LOOKBACK_DAYS, SCAN_REGIONS or "[home]")

    findings: list[dict] = []
    deleted: list[str] = []
    errors: list[dict] = []
    cumulative_usd = 0.0
    cumulative_savings = 0.0
    ceiling_hit = False

    for region in (SCAN_REGIONS or [None]):
        ec2 = boto3.client("ec2", region_name=region, config=_boto)
        cw_regional = boto3.client("cloudwatch", region_name=region, config=_boto)
        eff_region = region or ec2.meta.region_name

        try:
            for page in ec2.get_paginator("describe_nat_gateways").paginate(
                Filter=[{"Name": "state", "Values": ["available"]}],
            ):
                for nat in page["NatGateways"]:
                    try:
                        outcome = _process(ec2, cw_regional, eff_region, nat, cumulative_usd)
                        if outcome.get("ceiling_hit"):
                            ceiling_hit = True
                        if outcome.get("finding"):
                            findings.append(outcome["finding"])
                            cumulative_usd += outcome["finding"]["EstimatedMonthlyCostUsd"]
                        if outcome.get("deleted"):
                            deleted.append(outcome["deleted"])
                            cumulative_savings += NAT_MONTHLY_USD
                    except Exception as e:
                        logger.exception("Failed processing NAT %s", nat.get("NatGatewayId"))
                        errors.append({"region": eff_region, "nat_id": nat.get("NatGatewayId"), "error": str(e)})
        except Exception as e:
            logger.exception("NAT list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": "list", "error": str(e)})

    total = round(sum(f["EstimatedMonthlyCostUsd"] for f in findings), 2)
    aging_count = sum(1 for f in findings if f.get("IsAging"))
    summary = {
        "AlertName": "Idle NAT Gateway scan",
        "severity": "high" if (total > 64 or aging_count > 0) else ("medium" if findings else "low"),
        "DryRun": DRY_RUN,
        "MinAgeDays": MIN_AGE_DAYS,
        "IdleLookbackDays": IDLE_LOOKBACK_DAYS,
        "IdleBytesThreshold": IDLE_BYTES_THRESHOLD,
        "Regions": SCAN_REGIONS or ["home"],
        "FoundCount": len(findings),
        "MonthlyWasteUsd": total,
        "DeletedCount": len(deleted),
        "AgingCount": aging_count,
        "RunSavingsUsd": round(cumulative_savings, 2),
        "ErrorCount": len(errors),
        "CostCeilingUsd": COST_CEILING_USD,
        "CostCeilingReached": ceiling_hit,
        "Findings": findings[:50],
    }
    if errors:
        summary["Errors"] = errors[:20]

    logger.info(json.dumps(summary, default=str))
    _publish_metrics(total, len(findings), len(deleted), cumulative_savings)
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: Idle NAT Gateway scan",
        Message=json.dumps(summary, default=str, indent=2),
    )
    return summary


def _process(ec2, cw_regional, region: str, nat: dict, cumulative_usd: float) -> dict:
    nat_id = nat["NatGatewayId"]
    create_time = nat["CreateTime"]
    age_days = (dt.datetime.now(create_time.tzinfo) - create_time).days
    tags = {t["Key"]: t["Value"] for t in nat.get("Tags", [])}

    if EXCEPTION_TAG_KEY in tags or age_days < MIN_AGE_DAYS:
        return {}

    avg_bytes = _avg_daily_bytes_out(cw_regional, nat_id)
    if avg_bytes >= IDLE_BYTES_THRESHOLD:
        return {}

    owner = tags.get("Owner") or "(no Owner tag)"
    state = idle_state.upsert_state(
        resource_type="NATGateway",
        resource_id=nat_id,
        region=region,
        account_id=_ACCOUNT_ID,
        estimated_monthly_cost_usd=NAT_MONTHLY_USD,
        owner=owner,
        tags=tags,
        resource_attrs={"VpcId": nat.get("VpcId"), "SubnetId": nat.get("SubnetId"), "AvgDailyBytesOut": round(avg_bytes, 2)},
    )

    if not idle_state.is_actionable(state):
        return {}

    finding: dict[str, Any] = {
        "NatGatewayId": nat_id,
        "Region": region,
        "VpcId": nat.get("VpcId"),
        "SubnetId": nat.get("SubnetId"),
        "CreateTime": create_time.isoformat(),
        "AgeDays": age_days,
        "AvgDailyBytesOut": round(avg_bytes, 2),
        "EstimatedMonthlyCostUsd": NAT_MONTHLY_USD,
        "Owner": owner,
        "Tags": tags,
        "SeenCount": state["SeenCount"],
        "Status": state["Status"],
        "IsAging": state["IsAging"],
    }

    if state["IsNew"]:
        idle_state.record_action(
            resource_type="NATGateway", resource_id=nat_id, region=region,
            account_id=_ACCOUNT_ID, action_type="detected", actor_id=_ACTOR_ID,
            notes=f"AvgDailyBytesOut={round(avg_bytes, 2)}",
        )

    if DRY_RUN:
        return {"finding": finding}

    if cumulative_usd + NAT_MONTHLY_USD > COST_CEILING_USD:
        logger.warning("Cost ceiling reached — skipping delete for %s", nat_id)
        idle_state.record_action(
            resource_type="NATGateway", resource_id=nat_id, region=region,
            account_id=_ACCOUNT_ID, action_type="skipped-ceiling", actor_id=_ACTOR_ID,
        )
        return {"finding": finding, "ceiling_hit": True}

    ec2.delete_nat_gateway(NatGatewayId=nat_id)
    idle_state.record_action(
        resource_type="NATGateway", resource_id=nat_id, region=region,
        account_id=_ACCOUNT_ID, action_type="deleted", actor_id=_ACTOR_ID,
        estimated_savings_usd=NAT_MONTHLY_USD,
    )
    logger.info("Deleted NAT GW %s in %s", nat_id, region)
    return {"finding": finding, "deleted": nat_id}


def _avg_daily_bytes_out(cw_regional, nat_id):
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=IDLE_LOOKBACK_DAYS)
    try:
        resp = cw_regional.get_metric_statistics(
            Namespace="AWS/NATGateway",
            MetricName="BytesOutToDestination",
            Dimensions=[{"Name": "NatGatewayId", "Value": nat_id}],
            StartTime=start, EndTime=end,
            Period=86400, Statistics=["Sum"],
        )
        points = resp.get("Datapoints", []) or []
        if not points:
            return 0.0
        return sum(p["Sum"] for p in points) / len(points)
    except Exception:
        logger.exception("Failed to get CW metrics for %s", nat_id)
        return float("inf")


def _publish_metrics(waste, found, actions, savings):
    dim = [{"Name": "ResourceType", "Value": "NATGateway"}]
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": "MonthlyWasteUsd",   "Value": float(waste),   "Unit": "None",  "Dimensions": dim},
            {"MetricName": "FoundCount",        "Value": float(found),   "Unit": "Count", "Dimensions": dim},
            {"MetricName": "ActionsTakenCount", "Value": float(actions), "Unit": "Count", "Dimensions": dim},
            {"MetricName": "RunSavingsUsd",     "Value": float(savings), "Unit": "None",  "Dimensions": dim},
        ],
    )
