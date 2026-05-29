"""
Auto-discovery Lambda for the instance-scheduler module.

Runs weekly. Scans EC2 + RDS resources that are NOT tagged with the Schedule
opt-in tag and NOT FinOpsException-tagged, then queries CloudWatch for
14-day average CPU. Resources with average CPU below the configured
threshold are proposed as candidates for scheduling.

Output:
  - SNS digest with the candidate list (resource ID, type, owner, avg CPU, region)
  - CloudWatch metric "DiscoveryCandidateCount" per ResourceType for the dashboard

This is advisory — it does NOT modify resources. The FinOps team reviews
the digest and applies `Schedule=<name>` tags manually (or via an automated
pipeline downstream).
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

OPT_IN_TAG_KEY    = os.environ["OPT_IN_TAG_KEY"]
EXCEPTION_TAG_KEY = os.environ["EXCEPTION_TAG_KEY"]
SNS_TOPIC_ARN     = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE  = os.environ.get("METRIC_NAMESPACE", "FinOps/InstanceScheduler")
SCAN_REGIONS      = json.loads(os.environ.get("SCAN_REGIONS", "[]"))
CPU_THRESHOLD     = float(os.environ.get("CPU_THRESHOLD_PCT", "5"))
LOOKBACK_DAYS     = int(os.environ.get("LOOKBACK_DAYS", "14"))

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw_global = boto3.client("cloudwatch", config=_boto)


def handler(event, context):
    logger.info("Discovery scan: regions=%s cpu<%s%% lookback=%sd", SCAN_REGIONS, CPU_THRESHOLD, LOOKBACK_DAYS)

    all_candidates: list[dict] = []
    errors: list[dict] = []
    counts = {"EC2": 0, "RDSInstance": 0}

    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=LOOKBACK_DAYS)

    for region in SCAN_REGIONS:
        try:
            ec2 = boto3.client("ec2", region_name=region, config=_boto)
            rds = boto3.client("rds", region_name=region, config=_boto)
            cw = boto3.client("cloudwatch", region_name=region, config=_boto)

            ec2_cands = _discover_ec2(ec2, cw, region, start, end)
            counts["EC2"] += len(ec2_cands)
            all_candidates.extend(ec2_cands)

            rds_cands = _discover_rds(rds, cw, region, start, end)
            counts["RDSInstance"] += len(rds_cands)
            all_candidates.extend(rds_cands)
        except Exception as e:
            logger.exception("Region %s discovery failed", region)
            errors.append({"region": region, "error": str(e)})

    _publish_metrics(counts)
    _publish_digest(all_candidates, counts, errors, end)
    return {"candidates": len(all_candidates), "errors": len(errors)}


def _discover_ec2(ec2, cw, region: str, start: dt.datetime, end: dt.datetime) -> list[dict]:
    candidates: list[dict] = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["running"]}]):
        for res in page.get("Reservations", []) or []:
            for inst in res.get("Instances", []) or []:
                tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                if OPT_IN_TAG_KEY in tags or EXCEPTION_TAG_KEY in tags:
                    continue
                # Skip prod resources by default — discovery is for non-prod hygiene
                if tags.get("Environment", "").lower() == "prod":
                    continue
                avg = _avg_cpu_ec2(cw, inst["InstanceId"], start, end)
                if avg is None or avg >= CPU_THRESHOLD:
                    continue
                candidates.append({
                    "ResourceType": "EC2",
                    "ResourceId": inst["InstanceId"],
                    "Region": region,
                    "InstanceType": inst.get("InstanceType"),
                    "AvgCpuPct": round(avg, 2),
                    "Owner": tags.get("Owner") or "(no Owner tag)",
                    "Environment": tags.get("Environment") or "(unset)",
                    "SuggestedSchedule": "office-hours-cet",
                })
    return candidates


def _discover_rds(rds, cw, region: str, start: dt.datetime, end: dt.datetime) -> list[dict]:
    candidates: list[dict] = []
    paginator = rds.get_paginator("describe_db_instances")
    for page in paginator.paginate():
        for db in page.get("DBInstances", []) or []:
            tags = {t["Key"]: t["Value"] for t in db.get("TagList", []) or []}
            if OPT_IN_TAG_KEY in tags or EXCEPTION_TAG_KEY in tags:
                continue
            if tags.get("Environment", "").lower() == "prod":
                continue
            if db["DBInstanceStatus"] != "available":
                continue
            avg = _avg_db_connections(cw, db["DBInstanceIdentifier"], start, end)
            # For RDS, "idle" = average DatabaseConnections < 1 over the lookback
            if avg is None or avg >= 1.0:
                continue
            candidates.append({
                "ResourceType": "RDSInstance",
                "ResourceId": db["DBInstanceIdentifier"],
                "Region": region,
                "InstanceClass": db.get("DBInstanceClass"),
                "AvgDbConnections": round(avg, 2),
                "Owner": tags.get("Owner") or "(no Owner tag)",
                "Environment": tags.get("Environment") or "(unset)",
                "SuggestedSchedule": "office-hours-cet",
            })
    return candidates


def _avg_cpu_ec2(cw, instance_id: str, start, end) -> float | None:
    try:
        resp = cw.get_metric_statistics(
            Namespace="AWS/EC2",
            MetricName="CPUUtilization",
            Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
            StartTime=start, EndTime=end,
            Period=3600, Statistics=["Average"],
        )
        points = resp.get("Datapoints", []) or []
        if not points:
            return None
        return sum(p["Average"] for p in points) / len(points)
    except Exception:
        logger.exception("CPU metric lookup failed for %s", instance_id)
        return None


def _avg_db_connections(cw, db_id: str, start, end) -> float | None:
    try:
        resp = cw.get_metric_statistics(
            Namespace="AWS/RDS",
            MetricName="DatabaseConnections",
            Dimensions=[{"Name": "DBInstanceIdentifier", "Value": db_id}],
            StartTime=start, EndTime=end,
            Period=3600, Statistics=["Average"],
        )
        points = resp.get("Datapoints", []) or []
        if not points:
            return None
        return sum(p["Average"] for p in points) / len(points)
    except Exception:
        logger.exception("DB-connections lookup failed for %s", db_id)
        return None


def _publish_metrics(counts: dict):
    data = [
        {
            "MetricName": "DiscoveryCandidateCount", "Value": float(c), "Unit": "Count",
            "Dimensions": [{"Name": "ResourceType", "Value": t}],
        }
        for t, c in counts.items()
    ]
    cw_global.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=data)


def _publish_digest(candidates: list[dict], counts: dict, errors: list, generated_at: dt.datetime):
    if not SNS_TOPIC_ARN:
        return  # standalone mode without an events topic — metrics only
    severity = "info" if not candidates else "medium"
    summary = {
        "AlertName": "FinOps scheduler — auto-discovery candidates",
        "severity": severity,
        "GeneratedAt": generated_at.isoformat(),
        "ScanRegions": SCAN_REGIONS,
        "CpuThresholdPct": CPU_THRESHOLD,
        "LookbackDays": LOOKBACK_DAYS,
        "CandidateCounts": counts,
        "TotalCandidates": len(candidates),
        "Candidates": candidates[:50],
        "Errors": errors,
        "Hint": (
            "These resources show very low utilisation and aren't tagged with "
            f"{OPT_IN_TAG_KEY}=*. Consider adding the tag with a suitable schedule "
            "(e.g. office-hours-cet). Review with the resource owner first."
        ),
    }
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: scheduler discovery candidates",
        Message=json.dumps(summary, default=str, indent=2),
    )
