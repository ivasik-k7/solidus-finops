"""
Weekly Savings Plan and Reserved Instance coverage & utilization reporter.

Behaviour:
  - Queries ce:GetSavingsPlansCoverage, ce:GetSavingsPlansUtilization,
    ce:GetReservationCoverage, ce:GetReservationUtilization for the last
    30 days.
  - Publishes a structured report to SNS.
  - Sets severity to 'medium' if either coverage falls below
    TARGET_COVERAGE_PCT, otherwise 'info'.
  - Surfaces low-utilization commitments (under 95%).

The numbers in this report mirror what a FinOps team would otherwise
manually pull from Cost Explorer once a week. The point is to push the
report to where decisions are made (Slack / Teams / ticketing) rather than
require humans to remember to look.
"""
import datetime
import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
TARGET_COVERAGE_PCT = float(os.environ.get("TARGET_COVERAGE_PCT", "70"))

ce = boto3.client("ce", region_name="us-east-1")  # Cost Explorer API lives in us-east-1
sns = boto3.client("sns")


def handler(event, context):
    end = datetime.date.today()
    start = end - datetime.timedelta(days=30)
    period = {"Start": start.isoformat(), "End": end.isoformat()}

    logger.info("Pulling coverage and utilization for %s -> %s", start, end)

    sp_cov = _safe_call(ce.get_savings_plans_coverage, TimePeriod=period, Granularity="MONTHLY")
    sp_util = _safe_call(ce.get_savings_plans_utilization, TimePeriod=period, Granularity="MONTHLY")
    ri_cov = _safe_call(ce.get_reservation_coverage, TimePeriod=period, Granularity="MONTHLY")
    ri_util = _safe_call(ce.get_reservation_utilization, TimePeriod=period, Granularity="MONTHLY")

    report = {
        "AlertName": "Weekly RI/SP coverage report",
        "Period": period,
        "TargetCoveragePct": TARGET_COVERAGE_PCT,
        "SavingsPlans": _summarize_sp(sp_cov, sp_util),
        "ReservedInstances": _summarize_ri(ri_cov, ri_util),
    }

    flags = []
    if report["SavingsPlans"]["CoveragePct"] is not None \
            and report["SavingsPlans"]["CoveragePct"] < TARGET_COVERAGE_PCT:
        flags.append(f"SP coverage {report['SavingsPlans']['CoveragePct']:.1f}% < target {TARGET_COVERAGE_PCT}%")
    if report["ReservedInstances"]["CoveragePct"] is not None \
            and report["ReservedInstances"]["CoveragePct"] < TARGET_COVERAGE_PCT:
        flags.append(f"RI coverage {report['ReservedInstances']['CoveragePct']:.1f}% < target {TARGET_COVERAGE_PCT}%")
    if report["SavingsPlans"]["UtilizationPct"] is not None \
            and report["SavingsPlans"]["UtilizationPct"] < 95:
        flags.append(f"SP utilization {report['SavingsPlans']['UtilizationPct']:.1f}% < 95%")
    if report["ReservedInstances"]["UtilizationPct"] is not None \
            and report["ReservedInstances"]["UtilizationPct"] < 95:
        flags.append(f"RI utilization {report['ReservedInstances']['UtilizationPct']:.1f}% < 95%")

    report["severity"] = "medium" if flags else "info"
    report["Flags"] = flags

    logger.info(json.dumps(report, default=str))

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: Weekly RI/SP coverage report",
        Message=json.dumps(report, default=str, indent=2),
    )
    return report


def _safe_call(fn, **kwargs):
    try:
        return fn(**kwargs)
    except Exception:
        logger.exception("CE call failed: %s", fn.__name__)
        return None


def _summarize_sp(coverage, utilization):
    out = {"CoveragePct": None, "UtilizationPct": None, "NetSavingsUsd": None}
    if coverage and coverage.get("SavingsPlansCoverages"):
        # Take the latest period
        latest = coverage["SavingsPlansCoverages"][-1]["Coverage"]
        out["CoveragePct"] = float(latest.get("CoveragePercentage", 0) or 0)
    if utilization and utilization.get("Total"):
        total = utilization["Total"]
        u = total.get("Utilization", {})
        out["UtilizationPct"] = float(u.get("UtilizationPercentage", 0) or 0)
        savings = total.get("Savings", {})
        out["NetSavingsUsd"] = float(savings.get("NetSavings", 0) or 0)
    return out


def _summarize_ri(coverage, utilization):
    out = {"CoveragePct": None, "UtilizationPct": None, "NetSavingsUsd": None}
    if coverage and coverage.get("Total"):
        cov = coverage["Total"]["Coverage"]["CoverageHours"]
        out["CoveragePct"] = float(cov.get("CoverageHoursPercentage", 0) or 0)
    if utilization and utilization.get("Total"):
        total = utilization["Total"]
        out["UtilizationPct"] = float(total.get("UtilizationPercentage", 0) or 0)
        out["NetSavingsUsd"] = float(total.get("NetRISavings", 0) or 0)
    return out
