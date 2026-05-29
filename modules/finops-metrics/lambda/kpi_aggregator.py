"""
FinOps KPI aggregator — daily.

Runs once per day on an EventBridge schedule. Produces a comprehensive
FinOps KPI surface from the data the rest of the framework already
collects (CUR via Athena, AWS Cost Explorer). Emits to four sinks:

  1. CloudWatch custom metrics under $METRIC_NAMESPACE (default FinOps/KPIs)
  2. SSM Parameter Store under $SSM_PREFIX (scalar KPIs only)
  3. DynamoDB snapshot table — one row per KPI per day, retained for trend math
  4. SNS digest topic (skipped when SNS_TOPIC_ARN is empty — standalone mode)

It also re-PUTs the CloudWatch dashboard on every run so that:
  - per-tag-value widgets reflect the current distinct values
  - custom-KPI widgets appear without a Terraform apply
  - trend-line widgets are always wired to the metric names actually emitted

Built-in KPIs (each gated by $BUILTIN_KPIS_ENABLED):
  - AllocationCoveragePct       (Athena over CUR)
  - CommitmentCoveragePct       (Cost Explorer: RI + SP coverage)
  - CommitmentUtilizationPct    (Cost Explorer: RI + SP utilization)
  - AnomalyImpactUsdMtd         (Cost Explorer: anomalies)
  - ForecastAbsDriftPct         (Cost Explorer: actual MTD vs. forecast)
  - SpendByServiceUsd           (Athena over CUR, top 10, with Service dim)

Derived metrics (gated by $TREND_METRICS_ENABLED, computed from DDB history):
  - <Metric>_7dAvg              7-day moving average
  - <Metric>_30dAvg             30-day moving average
  - <Metric>_WoWDriftPct        this-week-avg vs last-week-avg, %
                                negative = degradation

Per-tag-value spend (gated by $TAG_VALUE_DASHBOARD_TAG):
  - SpendByTagValueUsd with Dimension {TagKey=<key>, TagValue=<value>}

Custom KPIs (one per $CUSTOM_KPIS_JSON entry):
  - Custom_<key>                value from the user-supplied Athena query

Design principles:
  - Per-KPI try/except — one upstream failing doesn't abort the rest
  - Standalone-mode safe — no SNS publish when SNS_TOPIC_ARN is empty
  - Idempotent — re-running on the same day overwrites snapshots safely
  - Modern datetime API — datetime.now(timezone.utc), no utcnow() deprecation
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import time
from decimal import Decimal
from typing import Any

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

METRIC_NAMESPACE             = os.environ["METRIC_NAMESPACE"]
SSM_PREFIX                   = os.environ["SSM_PREFIX"]
ATHENA_WORKGROUP             = os.environ["ATHENA_WORKGROUP"]
ATHENA_DATABASE              = os.environ["ATHENA_DATABASE"]
CUR_TABLE                    = os.environ["CUR_TABLE"]
CUR_FULL_TABLE               = os.environ["CUR_FULL_TABLE"]
ALLOCATION_TAG_KEYS          = json.loads(os.environ.get("ALLOCATION_TAG_KEYS", "[]"))
SNS_TOPIC_ARN                = os.environ.get("SNS_TOPIC_ARN", "")
SNAPSHOT_TABLE_NAME          = os.environ["SNAPSHOT_TABLE_NAME"]
SNAPSHOT_TTL_DAYS            = int(os.environ.get("SNAPSHOT_TTL_DAYS", "400"))
BUILTIN_KPIS_ENABLED         = json.loads(os.environ.get("BUILTIN_KPIS_ENABLED", "{}"))
CUSTOM_KPIS                  = json.loads(os.environ.get("CUSTOM_KPIS_JSON", "{}"))
TREND_METRICS_ENABLED        = os.environ.get("TREND_METRICS_ENABLED", "true").lower() == "true"
WOW_DRIFT_ALARM_THRESHOLD    = os.environ.get("WOW_DRIFT_ALARM_THRESHOLD_PCT", "")
TAG_VALUE_DASHBOARD_TAG      = os.environ.get("TAG_VALUE_DASHBOARD_TAG", "")
TAG_VALUE_DASHBOARD_TOP_N    = int(os.environ.get("TAG_VALUE_DASHBOARD_TOP_N", "12"))
DASHBOARD_NAME               = os.environ["DASHBOARD_NAME"]
NAME_PREFIX                  = os.environ["NAME_PREFIX"]

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
athena = boto3.client("athena", config=_boto)
cw     = boto3.client("cloudwatch", config=_boto)
ssm    = boto3.client("ssm", config=_boto)
ce     = boto3.client("ce", config=_boto)
sns    = boto3.client("sns", config=_boto)
ddb    = boto3.resource("dynamodb").Table(SNAPSHOT_TABLE_NAME)

ATHENA_POLL_SECONDS = 2
ATHENA_MAX_WAIT_SECONDS = 180


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------


def handler(event, context):
    today = dt.datetime.now(dt.timezone.utc).date()
    errors: list[str] = []
    emitted_metrics: list[str] = []
    summary: dict[str, Any] = {}
    tag_value_panels: list[dict[str, Any]] = []
    custom_kpi_panels: list[dict[str, Any]] = []

    # ----- Built-in scalar KPIs -----
    for kpi_name, fn, enabled_key in (
        ("AllocationCoveragePct",   _allocation_coverage,    "allocation_coverage"),
        ("CommitmentCoveragePct",   _commitment_coverage,    "commitment_coverage"),
        ("CommitmentUtilizationPct", _commitment_utilization, "commitment_utilization"),
        ("AnomalyImpactUsdMtd",     _anomaly_impact_mtd,     "anomaly_impact"),
        ("ForecastAbsDriftPct",     _forecast_drift,         "forecast_drift"),
    ):
        if not BUILTIN_KPIS_ENABLED.get(enabled_key, True):
            continue
        try:
            value = fn()
            if value is None:
                logger.info("Skipped %s (no value)", kpi_name)
                continue
            _publish_scalar_kpi(kpi_name, value, today)
            summary[kpi_name] = value
            emitted_metrics.append(kpi_name)
        except Exception as e:
            logger.exception("Failed to compute %s", kpi_name)
            errors.append(f"{kpi_name}: {e}")

    # ----- Top-10 spend by service (dimensioned, no SSM mirror) -----
    if BUILTIN_KPIS_ENABLED.get("spend_by_service", True):
        try:
            top_services = _spend_by_service_top10()
            for svc, cost in top_services:
                _publish_dimensioned_metric(
                    "SpendByServiceUsd", cost,
                    dimensions=[{"Name": "Service", "Value": svc}],
                )
            summary["SpendByServiceTop10"] = [{"service": s, "cost_usd": c} for s, c in top_services]
        except Exception as e:
            logger.exception("Failed to compute SpendByService")
            errors.append(f"SpendByService: {e}")

    # ----- Trend metrics (moving averages + WoW drift) -----
    if TREND_METRICS_ENABLED:
        for kpi_name in list(emitted_metrics):
            try:
                trends = _compute_trends(kpi_name, today)
                for tname, tvalue in trends.items():
                    _publish_dimensioned_metric(tname, tvalue, dimensions=[])
                if trends:
                    summary[f"{kpi_name}_trends"] = trends
            except Exception as e:
                logger.exception("Failed to compute trends for %s", kpi_name)
                errors.append(f"trends:{kpi_name}: {e}")

    # ----- Per-tag-value spend -----
    if TAG_VALUE_DASHBOARD_TAG:
        try:
            tag_pairs = _spend_by_tag_value(TAG_VALUE_DASHBOARD_TAG)
            for tv, cost in tag_pairs:
                _publish_dimensioned_metric(
                    "SpendByTagValueUsd", cost,
                    dimensions=[
                        {"Name": "TagKey",   "Value": TAG_VALUE_DASHBOARD_TAG},
                        {"Name": "TagValue", "Value": tv},
                    ],
                )
            top = tag_pairs[: TAG_VALUE_DASHBOARD_TOP_N]
            tag_value_panels = [{"tag_value": tv, "cost_usd": c} for tv, c in top]
            summary["SpendByTagValueTop"] = tag_value_panels
        except Exception as e:
            logger.exception("Failed to compute SpendByTagValue")
            errors.append(f"SpendByTagValue: {e}")

    # ----- Custom KPIs -----
    for ckey, cspec in CUSTOM_KPIS.items():
        metric_name = f"Custom_{ckey}"
        try:
            value = _run_custom_kpi(cspec)
            if value is None:
                logger.info("Custom KPI %s returned no value — skipped", ckey)
                continue
            _publish_scalar_kpi(metric_name, value, today, unit=cspec.get("unit", "None"))
            summary[metric_name] = value
            custom_kpi_panels.append({
                "key":         ckey,
                "metric":      metric_name,
                "value":       value,
                "description": cspec.get("description", ""),
            })
        except Exception as e:
            logger.exception("Failed custom KPI %s", ckey)
            errors.append(f"custom:{ckey}: {e}")

    # ----- Dashboard refresh -----
    try:
        _update_dashboard(emitted_metrics, tag_value_panels, custom_kpi_panels)
    except Exception as e:
        logger.exception("Dashboard refresh failed")
        errors.append(f"dashboard: {e}")

    # ----- SNS digest (standalone-mode guarded) -----
    _publish_summary(summary, errors)

    if errors:
        # Partial-failure: data still landed, but mark the invocation as
        # failed so the DLQ catches a copy for ops to inspect.
        raise RuntimeError(f"{len(errors)} KPI(s) failed: {'; '.join(errors)}")

    return {"status": "ok", "kpis": list(summary.keys())}


# ---------------------------------------------------------------------------
# Built-in KPI implementations
# ---------------------------------------------------------------------------


def _allocation_coverage() -> float | None:
    if not ALLOCATION_TAG_KEYS:
        return None
    predicate = " AND ".join(
        f"resource_tags['user_{k}'] IS NOT NULL AND resource_tags['user_{k}'] != ''"
        for k in ALLOCATION_TAG_KEYS
    )
    sql = f"""
        SELECT
          ROUND(100.0 * SUM(CASE WHEN {predicate} THEN line_item_unblended_cost ELSE 0 END)
                      / NULLIF(SUM(line_item_unblended_cost), 0), 2) AS pct
        FROM {CUR_FULL_TABLE}
        WHERE billing_period = date_format(current_date, '%Y-%m')
    """
    rows = _run_athena(sql)
    if not rows or len(rows) < 2:
        return None
    raw = rows[1][0]
    return float(raw) if raw else 0.0


def _commitment_coverage() -> float | None:
    end = dt.date.today()
    start = end - dt.timedelta(days=30)
    time_period = {"Start": start.isoformat(), "End": end.isoformat()}

    ri = ce.get_reservation_coverage(TimePeriod=time_period).get("Total", {})
    sp = ce.get_savings_plans_coverage(TimePeriod=time_period).get("Total", {})

    ri_pct = float(ri.get("CoverageHoursPercentage", "0") or "0") if ri else 0.0
    sp_pct = float(((sp or {}).get("Coverage") or {}).get("CoveragePercentage", "0") or "0")

    return round(min(100.0, ri_pct + sp_pct), 2)


def _commitment_utilization() -> float | None:
    end = dt.date.today()
    start = end - dt.timedelta(days=30)
    time_period = {"Start": start.isoformat(), "End": end.isoformat()}

    ri_util = ce.get_reservation_utilization(TimePeriod=time_period).get("Total", {})
    sp_util = ce.get_savings_plans_utilization(TimePeriod=time_period).get("Total", {})

    ri_pct = float(ri_util.get("UtilizationPercentage", "0") or "0") if ri_util else 0.0
    sp_pct = float(((sp_util or {}).get("Utilization") or {}).get("UtilizationPercentage", "0") or "0")

    if ri_pct == 0 and sp_pct == 0:
        return None
    if ri_pct == 0:
        return round(sp_pct, 2)
    if sp_pct == 0:
        return round(ri_pct, 2)
    return round((ri_pct + sp_pct) / 2.0, 2)


def _anomaly_impact_mtd() -> float | None:
    today = dt.date.today()
    first_of_month = today.replace(day=1)
    if today == first_of_month:
        return 0.0
    resp = ce.get_anomalies(DateInterval={
        "StartDate": first_of_month.isoformat(),
        "EndDate":   today.isoformat(),
    })
    anomalies = resp.get("Anomalies", []) or []
    total = 0.0
    for a in anomalies:
        impact = (a.get("Impact") or {}).get("TotalImpact", 0)
        total += float(impact or 0)
    return round(total, 2)


def _forecast_drift() -> float | None:
    """Skip on days 1-3 — forecast is unreliable that early in the month."""
    today = dt.date.today()
    first_of_month = today.replace(day=1)
    if (today - first_of_month).days < 3:
        return None

    next_month = (today.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
    if today >= next_month:
        return None

    actual_resp = ce.get_cost_and_usage(
        TimePeriod={"Start": first_of_month.isoformat(), "End": today.isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
    )
    actual_mtd = sum(
        float(r["Total"]["UnblendedCost"]["Amount"])
        for r in actual_resp.get("ResultsByTime", [])
    )

    try:
        forecast_resp = ce.get_cost_forecast(
            TimePeriod={"Start": today.isoformat(), "End": next_month.isoformat()},
            Metric="UNBLENDED_COST",
            Granularity="MONTHLY",
        )
        remaining_forecast = float(forecast_resp["Total"]["Amount"])
    except ce.exceptions.ClientError:
        return None

    projected_full_month = actual_mtd + remaining_forecast
    if projected_full_month <= 0:
        return None

    days_in_month = (next_month - first_of_month).days
    days_elapsed = (today - first_of_month).days or 1
    expected_mtd = projected_full_month * (days_elapsed / days_in_month)
    if expected_mtd <= 0:
        return None

    drift = abs(1.0 - (actual_mtd / expected_mtd)) * 100.0
    return round(drift, 2)


def _spend_by_service_top10() -> list[tuple[str, float]]:
    sql = f"""
        SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS cost_usd
        FROM {CUR_FULL_TABLE}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY product_servicecode
        ORDER BY cost_usd DESC
        LIMIT 10
    """
    return _athena_rows_as_pairs(sql)


def _spend_by_tag_value(tag_key: str) -> list[tuple[str, float]]:
    """Distinct values of a tag + their current-month cost, sorted desc."""
    sql = f"""
        SELECT
          COALESCE(NULLIF(resource_tags['user_{tag_key}'], ''), 'unallocated') AS tag_value,
          SUM(line_item_unblended_cost) AS cost_usd
        FROM {CUR_FULL_TABLE}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY COALESCE(NULLIF(resource_tags['user_{tag_key}'], ''), 'unallocated')
        ORDER BY cost_usd DESC
    """
    return _athena_rows_as_pairs(sql)


def _run_custom_kpi(spec: dict) -> float | None:
    sql = spec.get("sql", "")
    if not sql:
        return None
    rows = _run_athena(sql)
    if not rows or len(rows) < 2:
        return None
    cells = rows[1]
    if not cells:
        return None
    raw = cells[0]
    if raw in (None, ""):
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        logger.warning("Custom KPI returned non-numeric value %r — skipping", raw)
        return None


# ---------------------------------------------------------------------------
# Trend math (moving averages + WoW drift)
# ---------------------------------------------------------------------------


def _compute_trends(metric_name: str, today: dt.date) -> dict[str, float]:
    """Read up to 30 days of DDB history for this KPI and derive trend metrics."""
    pk = f"KPI#{metric_name}"
    start_sk = (today - dt.timedelta(days=29)).isoformat()
    resp = ddb.query(
        KeyConditionExpression="PK = :pk AND SK BETWEEN :start AND :end",
        ExpressionAttributeValues={
            ":pk":    pk,
            ":start": start_sk,
            ":end":   today.isoformat(),
        },
    )
    items = resp.get("Items", []) or []
    if len(items) < 2:
        return {}

    by_date = {it["SK"]: float(it["Value"]) for it in items if "Value" in it}

    def avg(start: dt.date, end: dt.date) -> float | None:
        vals = [v for d, v in by_date.items() if start.isoformat() <= d <= end.isoformat()]
        return round(sum(vals) / len(vals), 4) if vals else None

    out: dict[str, float] = {}

    avg7 = avg(today - dt.timedelta(days=6), today)
    if avg7 is not None:
        out[f"{metric_name}_7dAvg"] = avg7

    avg30 = avg(today - dt.timedelta(days=29), today)
    if avg30 is not None:
        out[f"{metric_name}_30dAvg"] = avg30

    # Week-over-week drift — positive = improvement, negative = degradation.
    this_week = avg(today - dt.timedelta(days=6), today)
    last_week = avg(today - dt.timedelta(days=13), today - dt.timedelta(days=7))
    if this_week is not None and last_week not in (None, 0):
        out[f"{metric_name}_WoWDriftPct"] = round(
            ((this_week - last_week) / last_week) * 100.0, 2
        )

    return out


# ---------------------------------------------------------------------------
# Sinks
# ---------------------------------------------------------------------------


def _publish_scalar_kpi(name: str, value: float, today: dt.date, unit: str = "None"):
    """CloudWatch metric + SSM Parameter + DDB snapshot (one row per day)."""
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{"MetricName": name, "Value": float(value), "Unit": unit}],
    )
    ssm.put_parameter(
        Name=f"{SSM_PREFIX}/{_snake(name)}",
        Value=str(value),
        Type="String",
        Overwrite=True,
        Tier="Standard",
    )
    ddb.put_item(Item={
        "PK":          f"KPI#{name}",
        "SK":          today.isoformat(),
        "MetricName":  name,
        "Value":       Decimal(str(value)),
        "Unit":        unit,
        "GeneratedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "ExpireAt":    int((dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=SNAPSHOT_TTL_DAYS)).timestamp()),
    })
    logger.info("Published KPI %s = %s", name, value)


def _publish_dimensioned_metric(name: str, value: float, dimensions: list[dict[str, str]]):
    """CloudWatch only — dimensioned metrics aren't suitable for the scalar SSM mirror."""
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{
            "MetricName": name,
            "Value":      float(value),
            "Unit":       "None",
            "Dimensions": dimensions,
        }],
    )


def _publish_summary(summary: dict[str, Any], errors: list[str]):
    if not SNS_TOPIC_ARN:
        return  # standalone mode — no events topic, metrics + DDB + SSM still ran
    msg = {
        "AlertName":   "FinOps daily KPI digest",
        "severity":    "info" if not errors else "medium",
        "GeneratedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "KPIs":        {k: v for k, v in summary.items() if not isinstance(v, (list, dict))},
        "TopServices": summary.get("SpendByServiceTop10", []),
        "TopTagValues": summary.get("SpendByTagValueTop", []),
    }
    if errors:
        msg["Errors"] = errors
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps daily KPI digest",
        Message=json.dumps(msg, default=_decimal_default, indent=2),
    )


# ---------------------------------------------------------------------------
# Dashboard rebuilder
# ---------------------------------------------------------------------------


def _update_dashboard(
    emitted_metrics: list[str],
    tag_value_panels: list[dict[str, Any]],
    custom_kpi_panels: list[dict[str, Any]],
):
    """Re-PUT the dashboard with a dynamic layout that reflects what was emitted."""
    widgets: list[dict[str, Any]] = []
    y = 0

    widgets.append({
        "type": "text", "x": 0, "y": y, "width": 24, "height": 2,
        "properties": {
            "markdown": (
                f"## FinOps KPIs — {NAME_PREFIX}\n\n"
                f"Namespace `{METRIC_NAMESPACE}` — DDB snapshots `{SNAPSHOT_TABLE_NAME}` — "
                f"refreshed by `{NAME_PREFIX}-kpi-aggregator` on every daily run."
            )
        },
    })
    y += 2

    # Headline scalar KPIs
    if emitted_metrics:
        scalar_metric_rows = [[METRIC_NAMESPACE, m] for m in emitted_metrics[:6]]
        widgets.append({
            "type": "metric", "x": 0, "y": y, "width": 24, "height": 6,
            "properties": {
                "title":   "Headline KPIs (latest value)",
                "view":    "singleValue",
                "stacked": False,
                "period":  86400,
                "stat":    "Average",
                "metrics": scalar_metric_rows,
            },
        })
        y += 6

    # 7d/30d trend lines per scalar KPI
    if TREND_METRICS_ENABLED:
        for i, m in enumerate(emitted_metrics):
            widgets.append({
                "type": "metric",
                "x": 12 * (i % 2), "y": y + 6 * (i // 2),
                "width": 12, "height": 6,
                "properties": {
                    "title":   f"{m} — daily + 7d avg + 30d avg",
                    "view":    "timeSeries",
                    "stacked": False,
                    "period":  86400,
                    "stat":    "Average",
                    "metrics": [
                        [METRIC_NAMESPACE, m],
                        [".", f"{m}_7dAvg"],
                        [".", f"{m}_30dAvg"],
                    ],
                },
            })
        if emitted_metrics:
            y += 6 * ((len(emitted_metrics) + 1) // 2)

    # Spend by service — top 10
    widgets.append({
        "type": "metric", "x": 0, "y": y, "width": 24, "height": 6,
        "properties": {
            "title":   "Spend by service — top 10 (current month)",
            "view":    "timeSeries",
            "stacked": True,
            "period":  86400,
            "stat":    "Sum",
            "metrics": [[{"expression": f"SEARCH('Namespace=\"{METRIC_NAMESPACE}\" MetricName=\"SpendByServiceUsd\"', 'Sum')", "id": "e1"}]],
        },
    })
    y += 6

    # Per-tag-value panel — one merged time-series widget showing top N values
    if TAG_VALUE_DASHBOARD_TAG and tag_value_panels:
        metric_rows = [
            [
                METRIC_NAMESPACE,
                "SpendByTagValueUsd",
                "TagKey", TAG_VALUE_DASHBOARD_TAG,
                "TagValue", p["tag_value"],
            ]
            for p in tag_value_panels[:TAG_VALUE_DASHBOARD_TOP_N]
        ]
        widgets.append({
            "type": "metric", "x": 0, "y": y, "width": 24, "height": 8,
            "properties": {
                "title":   f"Spend by {TAG_VALUE_DASHBOARD_TAG} — top {min(len(tag_value_panels), TAG_VALUE_DASHBOARD_TOP_N)}",
                "view":    "timeSeries",
                "stacked": True,
                "period":  86400,
                "stat":    "Sum",
                "metrics": metric_rows,
            },
        })
        y += 8

    # Custom KPI panel
    if custom_kpi_panels:
        rows = [[METRIC_NAMESPACE, p["metric"]] for p in custom_kpi_panels]
        widgets.append({
            "type": "metric", "x": 0, "y": y, "width": 24, "height": 6,
            "properties": {
                "title":   "Custom KPIs",
                "view":    "timeSeries",
                "stacked": False,
                "period":  86400,
                "stat":    "Average",
                "metrics": rows,
            },
        })
        y += 6

    body = {"widgets": widgets}
    cw.put_dashboard(DashboardName=DASHBOARD_NAME, DashboardBody=json.dumps(body))
    logger.info("Dashboard %s updated — %d widgets", DASHBOARD_NAME, len(widgets))


# ---------------------------------------------------------------------------
# Athena
# ---------------------------------------------------------------------------


def _run_athena(sql: str) -> list[list[str]]:
    """Submit a query, wait, return all result rows (paginated). First row is headers."""
    resp = athena.start_query_execution(
        QueryString=sql,
        WorkGroup=ATHENA_WORKGROUP,
        QueryExecutionContext={"Database": ATHENA_DATABASE},
    )
    qid = resp["QueryExecutionId"]

    waited = 0
    while waited < ATHENA_MAX_WAIT_SECONDS:
        status = athena.get_query_execution(QueryExecutionId=qid)
        state = status["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            reason = status["QueryExecution"]["Status"].get("StateChangeReason", "(no reason)")
            raise RuntimeError(f"Athena query {qid} {state}: {reason}")
        time.sleep(ATHENA_POLL_SECONDS)
        waited += ATHENA_POLL_SECONDS
    else:
        raise TimeoutError(f"Athena query {qid} did not complete in {ATHENA_MAX_WAIT_SECONDS}s")

    rows: list[list[str]] = []
    next_token: str | None = None
    while True:
        kwargs: dict[str, Any] = {"QueryExecutionId": qid}
        if next_token:
            kwargs["NextToken"] = next_token
        page = athena.get_query_results(**kwargs)
        for row in page["ResultSet"]["Rows"]:
            rows.append([cell.get("VarCharValue") for cell in row.get("Data", [])])
        next_token = page.get("NextToken")
        if not next_token:
            break
    return rows


def _athena_rows_as_pairs(sql: str) -> list[tuple[str, float]]:
    rows = _run_athena(sql)
    if not rows or len(rows) < 2:
        return []
    out: list[tuple[str, float]] = []
    for row in rows[1:]:
        label = row[0] or "unknown"
        try:
            value = float(row[1])
        except (TypeError, ValueError):
            value = 0.0
        out.append((label, value))
    return out


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _decimal_default(o):
    if isinstance(o, Decimal):
        return float(o)
    raise TypeError(f"not JSON-serializable: {type(o).__name__}")


def _snake(name: str) -> str:
    out = [name[0].lower()]
    for ch in name[1:]:
        if ch.isupper():
            out.append("_")
            out.append(ch.lower())
        else:
            out.append(ch)
    return "".join(out)
