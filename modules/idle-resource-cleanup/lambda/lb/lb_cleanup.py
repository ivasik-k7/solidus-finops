"""
Idle load balancer detector with multi-region scanning and DDB-backed state
lifecycle. Covers ALB, NLB, and classic ELB.

A load balancer is "idle" if BOTH:
  - It has no healthy targets (ALB/NLB) or no registered instances (CLB), AND
  - Its CloudWatch request count over IDLE_LOOKBACK_DAYS is below threshold.
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
IDLE_REQUEST_THRESHOLD = int(os.environ.get("IDLE_REQUEST_THRESHOLD", "100"))
EXCEPTION_TAG_KEY = os.environ.get("EXCEPTION_TAG_KEY", "FinOpsException")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FinOps/IdleResources")
ALB_MONTHLY_USD = float(os.environ.get("ALB_MONTHLY_USD", "16.20"))
NLB_MONTHLY_USD = float(os.environ.get("NLB_MONTHLY_USD", "16.20"))
CLB_MONTHLY_USD = float(os.environ.get("CLB_MONTHLY_USD", "18.25"))
COST_CEILING_USD = float(os.environ.get("COST_CEILING_USD", "100"))
SCAN_REGIONS: list[str] = json.loads(os.environ.get("SCAN_REGIONS", "[]"))

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts")

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"


def handler(event, context):
    logger.info("LB scan: dry_run=%s lookback=%sd threshold=%s regions=%s",
                DRY_RUN, IDLE_LOOKBACK_DAYS, IDLE_REQUEST_THRESHOLD, SCAN_REGIONS or "[home]")

    findings: list[dict] = []
    deleted: list[str] = []
    errors: list[dict] = []
    cumulative_usd = 0.0
    cumulative_savings = 0.0
    ceiling_hit = False

    for region in (SCAN_REGIONS or [None]):
        elbv2 = boto3.client("elbv2", region_name=region, config=_boto)
        elb = boto3.client("elb", region_name=region, config=_boto)
        cw_regional = boto3.client("cloudwatch", region_name=region, config=_boto)
        eff_region = region or elbv2.meta.region_name

        try:
            for page in elbv2.get_paginator("describe_load_balancers").paginate():
                for lb in page["LoadBalancers"]:
                    try:
                        outcome = _process_v2(elbv2, cw_regional, eff_region, lb, cumulative_usd)
                        if outcome.get("ceiling_hit"):
                            ceiling_hit = True
                        if outcome.get("finding"):
                            findings.append(outcome["finding"])
                            cumulative_usd += outcome["finding"]["EstimatedMonthlyCostUsd"]
                        if outcome.get("deleted"):
                            deleted.append(outcome["deleted"])
                            cumulative_savings += outcome["finding"]["EstimatedMonthlyCostUsd"]
                    except Exception as e:
                        logger.exception("Failed LB %s", lb.get("LoadBalancerArn"))
                        errors.append({"region": eff_region, "lb_arn": lb.get("LoadBalancerArn"), "error": str(e)})
        except Exception as e:
            logger.exception("ALB/NLB list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": "list-elbv2", "error": str(e)})

        try:
            for page in elb.get_paginator("describe_load_balancers").paginate():
                for lb in page["LoadBalancerDescriptions"]:
                    try:
                        outcome = _process_v1(elb, cw_regional, eff_region, lb, cumulative_usd)
                        if outcome.get("ceiling_hit"):
                            ceiling_hit = True
                        if outcome.get("finding"):
                            findings.append(outcome["finding"])
                            cumulative_usd += outcome["finding"]["EstimatedMonthlyCostUsd"]
                        if outcome.get("deleted"):
                            deleted.append(outcome["deleted"])
                            cumulative_savings += outcome["finding"]["EstimatedMonthlyCostUsd"]
                    except Exception as e:
                        logger.exception("Failed CLB %s", lb.get("LoadBalancerName"))
                        errors.append({"region": eff_region, "lb_name": lb.get("LoadBalancerName"), "error": str(e)})
        except Exception as e:
            logger.exception("CLB list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": "list-elb", "error": str(e)})

    total = round(sum(f["EstimatedMonthlyCostUsd"] for f in findings), 2)
    aging_count = sum(1 for f in findings if f.get("IsAging"))
    summary = {
        "AlertName": "Idle load balancer scan",
        "severity": "high" if (total > 50 or aging_count > 0) else ("medium" if findings else "low"),
        "DryRun": DRY_RUN,
        "MinAgeDays": MIN_AGE_DAYS,
        "IdleLookbackDays": IDLE_LOOKBACK_DAYS,
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
        Subject="FinOps: Idle load balancer scan",
        Message=json.dumps(summary, default=str, indent=2),
    )
    return summary


def _process_v2(elbv2, cw_regional, region, lb, cumulative_usd):
    lb_arn = lb["LoadBalancerArn"]
    lb_name = lb["LoadBalancerName"]
    lb_type = lb["Type"]
    created = lb["CreatedTime"]
    age_days = (dt.datetime.now(created.tzinfo) - created).days
    if age_days < MIN_AGE_DAYS:
        return {}

    tags = _tags_v2(elbv2, lb_arn)
    if EXCEPTION_TAG_KEY in tags:
        return {}

    healthy = _has_healthy_targets_v2(elbv2, lb_arn)
    rcount = _v2_request_count(cw_regional, lb_arn, lb_type)
    if healthy and rcount >= IDLE_REQUEST_THRESHOLD:
        return {}

    monthly = ALB_MONTHLY_USD if lb_type == "application" else NLB_MONTHLY_USD
    owner = tags.get("Owner") or "(no Owner tag)"

    state = idle_state.upsert_state(
        resource_type="LoadBalancer",
        resource_id=lb_arn,
        region=region,
        account_id=_ACCOUNT_ID,
        estimated_monthly_cost_usd=monthly,
        owner=owner,
        tags=tags,
        resource_attrs={"Type": lb_type, "Name": lb_name, "HasHealthyTargets": healthy, "RecentRequestCount": int(rcount)},
    )
    if not idle_state.is_actionable(state):
        return {}

    finding = _v2_finding(lb_arn, lb_name, lb_type, created, age_days, healthy, rcount, monthly, owner, tags, state)

    if state["IsNew"]:
        idle_state.record_action(
            resource_type="LoadBalancer", resource_id=lb_arn, region=region,
            account_id=_ACCOUNT_ID, action_type="detected", actor_id=_ACTOR_ID,
        )

    if DRY_RUN:
        return {"finding": finding}
    if cumulative_usd + monthly > COST_CEILING_USD:
        idle_state.record_action(
            resource_type="LoadBalancer", resource_id=lb_arn, region=region,
            account_id=_ACCOUNT_ID, action_type="skipped-ceiling", actor_id=_ACTOR_ID,
        )
        return {"finding": finding, "ceiling_hit": True}

    elbv2.delete_load_balancer(LoadBalancerArn=lb_arn)
    idle_state.record_action(
        resource_type="LoadBalancer", resource_id=lb_arn, region=region,
        account_id=_ACCOUNT_ID, action_type="deleted", actor_id=_ACTOR_ID,
        estimated_savings_usd=monthly,
    )
    return {"finding": finding, "deleted": lb_arn}


def _process_v1(elb, cw_regional, region, lb, cumulative_usd):
    name = lb["LoadBalancerName"]
    created = lb["CreatedTime"]
    age_days = (dt.datetime.now(created.tzinfo) - created).days
    if age_days < MIN_AGE_DAYS:
        return {}

    tags = _tags_v1(elb, name)
    if EXCEPTION_TAG_KEY in tags:
        return {}

    instances = lb.get("Instances", [])
    rcount = _v1_request_count(cw_regional, name)
    if instances and rcount >= IDLE_REQUEST_THRESHOLD:
        return {}

    owner = tags.get("Owner") or "(no Owner tag)"
    state = idle_state.upsert_state(
        resource_type="LoadBalancer",
        resource_id=f"clb/{name}",
        region=region,
        account_id=_ACCOUNT_ID,
        estimated_monthly_cost_usd=CLB_MONTHLY_USD,
        owner=owner,
        tags=tags,
        resource_attrs={"Type": "classic", "Name": name, "RegisteredInstances": len(instances), "RecentRequestCount": int(rcount)},
    )
    if not idle_state.is_actionable(state):
        return {}

    finding: dict[str, Any] = {
        "LoadBalancerName": name,
        "Type": "classic",
        "Region": region,
        "CreatedTime": created.isoformat(),
        "AgeDays": age_days,
        "RegisteredInstances": len(instances),
        "RecentRequestCount": int(rcount),
        "EstimatedMonthlyCostUsd": CLB_MONTHLY_USD,
        "Owner": owner,
        "Tags": tags,
        "SeenCount": state["SeenCount"],
        "Status": state["Status"],
        "IsAging": state["IsAging"],
    }

    if state["IsNew"]:
        idle_state.record_action(
            resource_type="LoadBalancer", resource_id=f"clb/{name}", region=region,
            account_id=_ACCOUNT_ID, action_type="detected", actor_id=_ACTOR_ID,
        )

    if DRY_RUN:
        return {"finding": finding}
    if cumulative_usd + CLB_MONTHLY_USD > COST_CEILING_USD:
        idle_state.record_action(
            resource_type="LoadBalancer", resource_id=f"clb/{name}", region=region,
            account_id=_ACCOUNT_ID, action_type="skipped-ceiling", actor_id=_ACTOR_ID,
        )
        return {"finding": finding, "ceiling_hit": True}

    elb.delete_load_balancer(LoadBalancerName=name)
    idle_state.record_action(
        resource_type="LoadBalancer", resource_id=f"clb/{name}", region=region,
        account_id=_ACCOUNT_ID, action_type="deleted", actor_id=_ACTOR_ID,
        estimated_savings_usd=CLB_MONTHLY_USD,
    )
    return {"finding": finding, "deleted": name}


def _v2_finding(lb_arn, lb_name, lb_type, created, age_days, healthy, rcount, monthly, owner, tags, state):
    return {
        "LoadBalancerArn": lb_arn,
        "Name": lb_name,
        "Type": lb_type,
        "CreatedTime": created.isoformat(),
        "AgeDays": age_days,
        "HasHealthyTargets": healthy,
        "RecentRequestCount": int(rcount),
        "EstimatedMonthlyCostUsd": monthly,
        "Owner": owner,
        "Tags": tags,
        "SeenCount": state["SeenCount"],
        "Status": state["Status"],
        "IsAging": state["IsAging"],
    }


def _tags_v2(elbv2, lb_arn):
    try:
        descs = elbv2.describe_tags(ResourceArns=[lb_arn]).get("TagDescriptions", [])
        return {t["Key"]: t["Value"] for t in descs[0].get("Tags", [])} if descs else {}
    except Exception:
        return {}


def _tags_v1(elb, name):
    try:
        descs = elb.describe_tags(LoadBalancerNames=[name]).get("TagDescriptions", [])
        return {t["Key"]: t["Value"] for t in descs[0].get("Tags", [])} if descs else {}
    except Exception:
        return {}


def _has_healthy_targets_v2(elbv2, lb_arn):
    try:
        tgs = elbv2.describe_target_groups(LoadBalancerArn=lb_arn).get("TargetGroups", []) or []
        for tg in tgs:
            health = elbv2.describe_target_health(TargetGroupArn=tg["TargetGroupArn"])
            for t in health.get("TargetHealthDescriptions", []):
                if (t.get("TargetHealth") or {}).get("State") == "healthy":
                    return True
        return False
    except Exception:
        return True


def _v2_request_count(cw_regional, lb_arn, lb_type):
    name = "RequestCount" if lb_type == "application" else "ActiveFlowCount"
    dim_value = "/".join(lb_arn.split("/")[1:])
    namespace = "AWS/ApplicationELB" if lb_type == "application" else "AWS/NetworkELB"
    return _cw_sum(cw_regional, namespace, name, [{"Name": "LoadBalancer", "Value": dim_value}])


def _v1_request_count(cw_regional, name):
    return _cw_sum(cw_regional, "AWS/ELB", "RequestCount", [{"Name": "LoadBalancerName", "Value": name}])


def _cw_sum(cw_regional, namespace, metric_name, dimensions):
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=IDLE_LOOKBACK_DAYS)
    try:
        resp = cw_regional.get_metric_statistics(
            Namespace=namespace, MetricName=metric_name, Dimensions=dimensions,
            StartTime=start, EndTime=end, Period=86400, Statistics=["Sum"],
        )
        return sum(p["Sum"] for p in resp.get("Datapoints", []) or [])
    except Exception:
        return float("inf")


def _publish_metrics(waste, found, actions, savings):
    dim = [{"Name": "ResourceType", "Value": "LoadBalancer"}]
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": "MonthlyWasteUsd",   "Value": float(waste),   "Unit": "None",  "Dimensions": dim},
            {"MetricName": "FoundCount",        "Value": float(found),   "Unit": "Count", "Dimensions": dim},
            {"MetricName": "ActionsTakenCount", "Value": float(actions), "Unit": "Count", "Dimensions": dim},
            {"MetricName": "RunSavingsUsd",     "Value": float(savings), "Unit": "None",  "Dimensions": dim},
        ],
    )
