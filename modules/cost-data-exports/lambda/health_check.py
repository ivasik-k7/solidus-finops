"""
Cost data exports — daily health check.

Verifies that the CUR pipeline is delivering data end-to-end:

  1. CUR delivery freshness  — newest object in the bucket via S3 ListObjectsV2
  2. Crawler last run        — Glue GetCrawler.LastCrawl
  3. Athena queryability     — a small probe query against the CUR table

Emits four CloudWatch metrics under FinOps/CostDataExports:

  - CurDeliveryHours        (float)  hours since the most-recent CUR file
  - CrawlerLastRunHours     (float)  hours since the crawler last succeeded
  - AthenaQueryability      (0/1)    1 if the probe query succeeded
  - BucketObjectCount       (int)    total objects in the bucket

Publishes a structured digest to SNS_TOPIC_ARN (if set) and raises on
failure so the framework's DLQ + Errors alarm catch unprocessed runs.
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import time
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME       = os.environ["BUCKET_NAME"]
CRAWLER_NAME      = os.environ.get("CRAWLER_NAME", "")
ATHENA_WORKGROUP  = os.environ.get("ATHENA_WORKGROUP", "")
ATHENA_DATABASE   = os.environ.get("ATHENA_DATABASE", "")
CUR_TABLE         = os.environ.get("CUR_TABLE", "")
SNS_TOPIC_ARN     = os.environ.get("SNS_TOPIC_ARN", "")
METRIC_NAMESPACE  = os.environ.get("METRIC_NAMESPACE", "FinOps/CostDataExports")

s3 = boto3.client("s3")
glue = boto3.client("glue")
athena = boto3.client("athena")
cw = boto3.client("cloudwatch")
sns = boto3.client("sns") if SNS_TOPIC_ARN else None


def handler(event, context):
    now = _now()
    errors: list[str] = []

    # ----- 1) CUR delivery freshness -----
    try:
        latest = _latest_object_age_hours()
        _publish_metric("CurDeliveryHours", latest["age_hours"])
        _publish_metric("BucketObjectCount", float(latest["object_count"]))
    except Exception as e:
        logger.exception("CUR delivery check failed")
        errors.append(f"cur-delivery: {e}")
        latest = {"age_hours": None, "newest_key": None, "object_count": 0}

    # ----- 2) Crawler last run -----
    crawler = {"age_hours": None, "state": "skipped", "status": "skipped"}
    if CRAWLER_NAME:
        try:
            crawler = _crawler_age_hours()
            if crawler["age_hours"] is not None:
                _publish_metric("CrawlerLastRunHours", crawler["age_hours"])
        except Exception as e:
            logger.exception("Crawler check failed")
            errors.append(f"crawler: {e}")

    # ----- 3) Athena queryability -----
    athena_status: dict[str, Any] = {"ok": None, "reason": "skipped"}
    if ATHENA_WORKGROUP and ATHENA_DATABASE and CUR_TABLE:
        try:
            athena_status = _athena_probe()
            _publish_metric("AthenaQueryability", 1.0 if athena_status["ok"] else 0.0)
        except Exception as e:
            logger.exception("Athena probe failed")
            errors.append(f"athena: {e}")
            _publish_metric("AthenaQueryability", 0.0)

    severity = _severity(latest, crawler, athena_status)
    summary = {
        "AlertName": "FinOps cost-data-exports health check",
        "severity": severity,
        "GeneratedAt": now.isoformat(),
        "BucketName": BUCKET_NAME,
        "Cur": latest,
        "Crawler": crawler,
        "Athena": athena_status,
        "Errors": errors,
    }
    logger.info(json.dumps(summary, default=str))

    if sns:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="FinOps: cost-data-exports health digest",
            Message=json.dumps(summary, default=str, indent=2),
        )

    if errors:
        raise RuntimeError(f"{len(errors)} check(s) failed: {'; '.join(errors)}")
    return summary


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def _latest_object_age_hours() -> dict[str, Any]:
    """Find the newest object under cur2/ and return its age in hours."""
    newest: dt.datetime | None = None
    newest_key: str | None = None
    count = 0
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET_NAME, Prefix="cur2/"):
        for obj in page.get("Contents", []) or []:
            count += 1
            lm = obj["LastModified"]
            if newest is None or lm > newest:
                newest = lm
                newest_key = obj["Key"]
    age_hours = None
    if newest is not None:
        age_hours = round((_now() - newest).total_seconds() / 3600.0, 2)
    return {"age_hours": age_hours, "newest_key": newest_key, "object_count": count}


def _crawler_age_hours() -> dict[str, Any]:
    """Inspect the Glue crawler's last successful run."""
    resp = glue.get_crawler(Name=CRAWLER_NAME)
    crawler = resp.get("Crawler", {})
    state = crawler.get("State", "UNKNOWN")
    last = crawler.get("LastCrawl", {}) or {}
    status = last.get("Status")
    last_end_str = last.get("LogStream") and None  # placeholder; CompletedOn is more useful
    completed_on = last.get("StartTime")  # Glue uses StartTime in LastCrawl
    age_hours = None
    if completed_on:
        age_hours = round((_now() - completed_on.replace(tzinfo=dt.timezone.utc)).total_seconds() / 3600.0, 2)
    return {"age_hours": age_hours, "state": state, "status": status}


def _athena_probe() -> dict[str, Any]:
    """Run a tiny COUNT(*) query against the CUR table."""
    query = f"SELECT COUNT(*) FROM {ATHENA_DATABASE}.{CUR_TABLE} LIMIT 1"
    try:
        start = athena.start_query_execution(
            QueryString=query,
            WorkGroup=ATHENA_WORKGROUP,
            QueryExecutionContext={"Database": ATHENA_DATABASE},
        )
        qid = start["QueryExecutionId"]
    except Exception as e:
        return {"ok": False, "reason": f"start: {e}"}

    # Poll for up to ~30s
    for _ in range(15):
        time.sleep(2)
        status = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        state = status["State"]
        if state == "SUCCEEDED":
            return {"ok": True, "reason": "ok", "query_id": qid}
        if state in ("FAILED", "CANCELLED"):
            return {"ok": False, "reason": f"{state}: {status.get('StateChangeReason', '(no reason)')}", "query_id": qid}
    return {"ok": False, "reason": "timeout", "query_id": qid}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _severity(latest: dict, crawler: dict, athena_status: dict) -> str:
    if not latest.get("age_hours") and latest.get("age_hours") != 0:
        return "high"  # no CUR data at all
    if (latest.get("age_hours") or 0) > 48:
        return "high"
    if athena_status.get("ok") is False:
        return "high"
    if (crawler.get("age_hours") or 0) > 48:
        return "medium"
    if (latest.get("age_hours") or 0) > 24:
        return "medium"
    return "info"


def _publish_metric(name: str, value: float | None):
    if value is None:
        return
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{"MetricName": name, "Value": float(value), "Unit": "None"}],
    )


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)
