"""
Idle Elastic IP detector with multi-region scanning and DDB-backed state.

EIPs cost ~$3.65/month each when unassociated.

State tracking via idle_state (shared helper) dedups findings across runs,
escalates aging entries, honors snooze/exception status, and writes an
audit row for every release.
"""

from __future__ import annotations

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
EXCEPTION_TAG_KEY = os.environ.get("EXCEPTION_TAG_KEY", "FinOpsException")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FinOps/IdleResources")
EIP_MONTHLY_USD = float(os.environ.get("EIP_MONTHLY_USD", "3.65"))
SCAN_REGIONS: list[str] = json.loads(os.environ.get("SCAN_REGIONS", "[]"))

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts")

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"


def handler(event, context):
    logger.info(
        "EIP idle scan: dry_run=%s regions=%s", DRY_RUN, SCAN_REGIONS or "[home]"
    )

    findings: list[dict] = []
    released: list[str] = []
    errors: list[dict] = []
    cumulative_savings = 0.0

    for region in SCAN_REGIONS or [None]:
        ec2 = boto3.client("ec2", region_name=region, config=_boto)
        eff_region = region or ec2.meta.region_name
        try:
            addresses = ec2.describe_addresses().get("Addresses", [])
        except Exception as e:
            logger.exception("describe_addresses failed in %s", eff_region)
            errors.append({"region": eff_region, "error": str(e)})
            continue

        for addr in addresses:
            try:
                outcome = _process(ec2, eff_region, addr)
                if outcome.get("finding"):
                    findings.append(outcome["finding"])
                if outcome.get("released"):
                    released.append(outcome["released"])
                    cumulative_savings += EIP_MONTHLY_USD
            except Exception as e:
                logger.exception("Failed to process EIP %s", addr.get("AllocationId"))
                errors.append(
                    {
                        "region": eff_region,
                        "allocation_id": addr.get("AllocationId"),
                        "error": str(e),
                    }
                )

    total_waste = round(sum(f["EstimatedMonthlyCostUsd"] for f in findings), 2)
    aging_count = sum(1 for f in findings if f.get("IsAging"))
    summary = {
        "AlertName": "Idle Elastic IP scan",
        "severity": _severity(total_waste, aging_count),
        "DryRun": DRY_RUN,
        "Regions": SCAN_REGIONS or ["home"],
        "FoundCount": len(findings),
        "ReleasedCount": len(released),
        "AgingCount": aging_count,
        "EstimatedMonthlyWasteUsd": total_waste,
        "RunSavingsUsd": round(cumulative_savings, 2),
        "Findings": findings[:50],
        "Truncated": len(findings) > 50,
    }
    if errors:
        summary["Errors"] = errors[:20]

    logger.info(json.dumps(summary))

    _publish_metrics(total_waste, len(findings), len(released), cumulative_savings)
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: Idle EIP scan",
        Message=json.dumps(summary, indent=2),
    )
    return summary


def _process(ec2, region: str, addr: dict) -> dict:
    public_ip = addr.get("PublicIp")
    alloc_id = addr.get("AllocationId")
    tags = {t["Key"]: t["Value"] for t in addr.get("Tags", [])}

    if addr.get("AssociationId") or EXCEPTION_TAG_KEY in tags:
        return {}

    owner = tags.get("Owner") or "(no Owner tag)"
    state = idle_state.upsert_state(
        resource_type="EIP",
        resource_id=alloc_id or public_ip,
        region=region,
        account_id=_ACCOUNT_ID,
        estimated_monthly_cost_usd=EIP_MONTHLY_USD,
        owner=owner,
        tags=tags,
        resource_attrs={"PublicIp": public_ip, "Domain": addr.get("Domain")},
    )

    if not idle_state.is_actionable(state):
        return {}

    finding: dict[str, Any] = {
        "PublicIp": public_ip,
        "AllocationId": alloc_id,
        "Region": region,
        "Domain": addr.get("Domain"),
        "EstimatedMonthlyCostUsd": EIP_MONTHLY_USD,
        "Owner": owner,
        "Tags": tags,
        "SeenCount": state["SeenCount"],
        "Status": state["Status"],
        "IsAging": state["IsAging"],
    }

    if state["IsNew"]:
        idle_state.record_action(
            resource_type="EIP",
            resource_id=alloc_id or public_ip,
            region=region,
            account_id=_ACCOUNT_ID,
            action_type="detected",
            actor_id=_ACTOR_ID,
        )

    if DRY_RUN or not alloc_id:
        return {"finding": finding}

    ec2.release_address(AllocationId=alloc_id)
    idle_state.record_action(
        resource_type="EIP",
        resource_id=alloc_id,
        region=region,
        account_id=_ACCOUNT_ID,
        action_type="released",
        actor_id=_ACTOR_ID,
        estimated_savings_usd=EIP_MONTHLY_USD,
    )
    logger.info("Released %s in %s", alloc_id, region)
    return {"finding": finding, "released": alloc_id}


def _severity(total, aging_count):
    if aging_count > 0 or total > 50:
        return "high"
    if total > 10:
        return "medium"
    return "low"


def _publish_metrics(waste, found, actions, savings):
    dim = [{"Name": "ResourceType", "Value": "EIP"}]
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "MonthlyWasteUsd",
                "Value": float(waste),
                "Unit": "None",
                "Dimensions": dim,
            },
            {
                "MetricName": "FoundCount",
                "Value": float(found),
                "Unit": "Count",
                "Dimensions": dim,
            },
            {
                "MetricName": "ActionsTakenCount",
                "Value": float(actions),
                "Unit": "Count",
                "Dimensions": dim,
            },
            {
                "MetricName": "RunSavingsUsd",
                "Value": float(savings),
                "Unit": "None",
                "Dimensions": dim,
            },
        ],
    )
