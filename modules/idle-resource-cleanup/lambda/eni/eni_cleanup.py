"""
Idle ENI detector with multi-region scanning and DDB-backed state lifecycle.

ENIs are zero-cost individually but accumulate as leaked artifacts of failed
resource deletions (Lambda-in-VPC, EKS, RDS, EFS). Surfacing them lets the
practice keep VPC console views actionable and catch parent-resource
cleanup hygiene problems.
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
SCAN_REGIONS: list[str] = json.loads(os.environ.get("SCAN_REGIONS", "[]"))

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts")

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"


def handler(event, context):
    logger.info("ENI scan: dry_run=%s regions=%s", DRY_RUN, SCAN_REGIONS or "[home]")

    findings: list[dict] = []
    deleted: list[str] = []
    errors: list[dict] = []

    for region in SCAN_REGIONS or [None]:
        ec2 = boto3.client("ec2", region_name=region, config=_boto)
        eff_region = region or ec2.meta.region_name
        try:
            for page in ec2.get_paginator("describe_network_interfaces").paginate(
                Filters=[{"Name": "status", "Values": ["available"]}],
            ):
                for eni in page["NetworkInterfaces"]:
                    try:
                        outcome = _process(ec2, eff_region, eni)
                        if outcome.get("finding"):
                            findings.append(outcome["finding"])
                        if outcome.get("deleted"):
                            deleted.append(outcome["deleted"])
                    except Exception as e:
                        logger.exception(
                            "Failed processing ENI %s", eni.get("NetworkInterfaceId")
                        )
                        errors.append(
                            {
                                "region": eff_region,
                                "eni_id": eni.get("NetworkInterfaceId"),
                                "error": str(e),
                            }
                        )
        except Exception as e:
            logger.exception("ENI list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": "list", "error": str(e)})

    aging_count = sum(1 for f in findings if f.get("IsAging"))
    severity = (
        "high" if aging_count > 0 else ("medium" if len(findings) > 20 else "low")
    )
    summary = {
        "AlertName": "Idle ENI scan",
        "severity": severity,
        "DryRun": DRY_RUN,
        "Regions": SCAN_REGIONS or ["home"],
        "FoundCount": len(findings),
        "DeletedCount": len(deleted),
        "AgingCount": aging_count,
        "ErrorCount": len(errors),
        "Findings": findings[:50],
        "Truncated": len(findings) > 50,
    }
    if errors:
        summary["Errors"] = errors[:20]

    logger.info(json.dumps(summary, default=str))
    _publish_metrics(0.0, len(findings), len(deleted), 0.0)
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: Idle ENI scan",
        Message=json.dumps(summary, default=str, indent=2),
    )
    return summary


def _process(ec2, region: str, eni: dict) -> dict:
    eni_id = eni["NetworkInterfaceId"]
    tags = {t["Key"]: t["Value"] for t in eni.get("TagSet", [])}

    if EXCEPTION_TAG_KEY in tags or eni.get("Attachment"):
        return {}

    description = (eni.get("Description") or "").lower()
    leaked_hint = any(
        s in description
        for s in (
            "aws lambda",
            "elasticfilesystem",
            "amazon rds",
            "elasticloadbalancing",
            "efs mount",
            "vpc endpoint",
        )
    )

    owner = tags.get("Owner") or "(no Owner tag)"
    state = idle_state.upsert_state(
        resource_type="ENI",
        resource_id=eni_id,
        region=region,
        account_id=_ACCOUNT_ID,
        estimated_monthly_cost_usd=0.0,
        owner=owner,
        tags=tags,
        resource_attrs={
            "VpcId": eni.get("VpcId"),
            "SubnetId": eni.get("SubnetId"),
            "Description": eni.get("Description"),
            "InterfaceType": eni.get("InterfaceType"),
            "LeakedHint": leaked_hint,
        },
    )

    if not idle_state.is_actionable(state):
        return {}

    finding: dict[str, Any] = {
        "NetworkInterfaceId": eni_id,
        "Region": region,
        "VpcId": eni.get("VpcId"),
        "SubnetId": eni.get("SubnetId"),
        "Description": eni.get("Description"),
        "PrivateIp": eni.get("PrivateIpAddress"),
        "InterfaceType": eni.get("InterfaceType"),
        "LeakedHint": leaked_hint,
        "Owner": owner,
        "Tags": tags,
        "SeenCount": state["SeenCount"],
        "Status": state["Status"],
        "IsAging": state["IsAging"],
    }

    if state["IsNew"]:
        idle_state.record_action(
            resource_type="ENI",
            resource_id=eni_id,
            region=region,
            account_id=_ACCOUNT_ID,
            action_type="detected",
            actor_id=_ACTOR_ID,
            notes=f"LeakedHint={leaked_hint}",
        )

    if DRY_RUN:
        return {"finding": finding}

    ec2.delete_network_interface(NetworkInterfaceId=eni_id)
    idle_state.record_action(
        resource_type="ENI",
        resource_id=eni_id,
        region=region,
        account_id=_ACCOUNT_ID,
        action_type="deleted",
        actor_id=_ACTOR_ID,
    )
    logger.info("Deleted ENI %s in %s", eni_id, region)
    return {"finding": finding, "deleted": eni_id}


def _publish_metrics(waste, found, actions, savings):
    dim = [{"Name": "ResourceType", "Value": "ENI"}]
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
