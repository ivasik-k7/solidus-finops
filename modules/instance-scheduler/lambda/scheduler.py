"""
Tag-driven EC2 instance scheduler.

Decision model:
  - For each running or stopped EC2 instance, read the OPT_IN_TAG_KEY tag.
  - If the tag is missing -> skip.
  - If the tag value is not in SCHEDULES_JSON -> skip and log a warning.
  - Otherwise, look at the schedule's start_cron and stop_cron and decide
    whether the instance should currently be running or stopped, then
    issue StartInstances or StopInstances if there's a mismatch.

Cron evaluation:
  We use a minimal cron expression evaluator restricted to the AWS
  CloudWatch Events cron format. To avoid bringing in heavyweight deps, the
  evaluator handles the common shapes: '0 6 ? * MON-FRI *' and similar.

  IMPORTANT: this Lambda only START/STOP toggles. It is a windowed scheduler,
  not a one-shot. The "should be running now" function returns True if the
  current time is within [start, stop) for the schedule's days-of-week.
"""
import datetime
import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

OPT_IN_TAG_KEY = os.environ.get("OPT_IN_TAG_KEY", "Schedule")
SCHEDULES = json.loads(os.environ.get("SCHEDULES_JSON", "{}"))
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")

ec2 = boto3.client("ec2")
sns = boto3.client("sns") if SNS_TOPIC_ARN else None

# CloudWatch cron format: minute hour day-of-month month day-of-week year
# We support the subset: minute hour ? * <DAYS> *  (the typical office-hours pattern)
DAY_NAMES = {"SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6}


def handler(event, context):
    now = datetime.datetime.utcnow()
    logger.info("Scheduler tick at %s UTC", now.isoformat())

    summary = {"started": [], "stopped": [], "skipped_no_tag": 0,
               "skipped_unknown_schedule": 0, "in_correct_state": 0,
               "errors": []}

    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate():
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                try:
                    _process_instance(inst, now, summary)
                except Exception as e:
                    logger.exception("Failed for instance %s", inst.get("InstanceId"))
                    summary["errors"].append({"instance_id": inst.get("InstanceId"), "error": str(e)})

    logger.info("Summary: %s", json.dumps(summary))

    if (summary["started"] or summary["stopped"] or summary["errors"]) and sns:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="FinOps scheduler tick",
            Message=json.dumps({
                "AlertName": "Instance scheduler action",
                "severity": "info" if not summary["errors"] else "medium",
                **summary,
            }, indent=2),
        )

    return summary


def _process_instance(inst, now, summary):
    state = inst["State"]["Name"]
    if state not in ("running", "stopped"):
        return  # pending, stopping, terminated, etc. — let AWS finish.

    tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
    schedule_name = tags.get(OPT_IN_TAG_KEY)
    if not schedule_name:
        summary["skipped_no_tag"] += 1
        return

    schedule = SCHEDULES.get(schedule_name)
    if not schedule:
        summary["skipped_unknown_schedule"] += 1
        logger.warning("Instance %s has unknown schedule %r", inst["InstanceId"], schedule_name)
        return

    should_run = _should_be_running(now, schedule["start_cron"], schedule["stop_cron"])
    iid = inst["InstanceId"]

    if should_run and state == "stopped":
        ec2.start_instances(InstanceIds=[iid])
        summary["started"].append(iid)
        logger.info("Started %s (schedule=%s)", iid, schedule_name)
    elif (not should_run) and state == "running":
        ec2.stop_instances(InstanceIds=[iid])
        summary["stopped"].append(iid)
        logger.info("Stopped %s (schedule=%s)", iid, schedule_name)
    else:
        summary["in_correct_state"] += 1


def _should_be_running(now, start_cron, stop_cron):
    """Return True if `now` falls within the schedule's running window today."""
    sm, sh, sdays = _parse_cron(start_cron)
    em, eh, edays = _parse_cron(stop_cron)

    today_dow = now.isoweekday() % 7  # 0=Sun, 1=Mon, ...
    if today_dow not in sdays:
        return False  # not a running day

    start = now.replace(hour=sh, minute=sm, second=0, microsecond=0)
    end = now.replace(hour=eh, minute=em, second=0, microsecond=0)

    # Handle stop-cron that's "the next morning" by spanning midnight, e.g. 0 0 ? * TUE-SAT *.
    # We approximate by checking: if end <= start, treat end as next day.
    if end <= start:
        end = end + datetime.timedelta(days=1)

    return start <= now < end


def _parse_cron(expr):
    """Minimal parser for 'M H ? * <DAYS> *' style CloudWatch cron expressions.

    Returns (minute, hour, set_of_dow_ints).
    """
    parts = expr.split()
    if len(parts) != 6:
        raise ValueError(f"Unsupported cron expression: {expr!r}")
    minute, hour, _dom, _month, dow, _year = parts
    m = int(minute)
    h = int(hour)
    return m, h, _parse_dow(dow)


def _parse_dow(field):
    """Parse a day-of-week field: SUN, MON-FRI, MON,WED,FRI, *."""
    if field == "*" or field == "?":
        return set(range(7))
    days = set()
    for chunk in field.split(","):
        if "-" in chunk:
            start, end = chunk.split("-")
            si = DAY_NAMES[start.upper()]
            ei = DAY_NAMES[end.upper()]
            if si <= ei:
                days.update(range(si, ei + 1))
            else:
                # wrap-around (FRI-MON style)
                days.update(range(si, 7))
                days.update(range(0, ei + 1))
        else:
            days.add(DAY_NAMES[chunk.upper()])
    return days
