"""
finops_event — publisher library for the FinOps alerting bus.

DROP THIS FILE into any Lambda that needs to publish to the events bus. It
encodes the message shape the dispatcher Lambda + chat adapters expect:

    {
      "severity": "info" | "low" | "medium" | "high" | "critical",
      "AlertName": "<stable identifier — drives dedup>",
      "<extra fields...>": "<rendered as labelled rows in Slack/Teams>",
    }

Usage (synchronous publish via boto3):

    from finops_event import publish

    publish(
        topic_arn=os.environ["EVENTS_TOPIC_ARN"],
        subject="Idle EBS volume scan",
        severity="medium",
        alert_name="idle-ebs-scan",
        fields={
            "FoundCount": 12,
            "MonthlyWasteUsd": 142.50,
            "AccountId": "123456789012",
            "Region": "eu-central-1",
        },
    )

Or use `format_message()` to get the JSON string and publish however you like
(useful for tests + alternative transports).
"""

from __future__ import annotations

import json
from typing import Any

try:
    import boto3  # type: ignore
except ImportError:
    boto3 = None  # caller may use format_message() without boto3

VALID_SEVERITIES = ("info", "low", "medium", "high", "critical")


def format_message(
    *,
    severity: str,
    alert_name: str,
    fields: dict[str, Any] | None = None,
) -> str:
    """Render the framework-canonical SNS message body as a JSON string."""
    if severity not in VALID_SEVERITIES:
        raise ValueError(
            f"severity must be one of {VALID_SEVERITIES}, got {severity!r}"
        )
    body: dict[str, Any] = {
        "severity": severity,
        "AlertName": alert_name,
    }
    if fields:
        for k, v in fields.items():
            if k in body:
                continue  # reserved
            body[k] = v
    return json.dumps(body, default=str)


def publish(
    *,
    topic_arn: str,
    subject: str,
    severity: str,
    alert_name: str,
    fields: dict[str, Any] | None = None,
    sns_client: Any = None,
) -> dict[str, Any]:
    """Publish a single message to the events SNS topic.

    `sns_client` may be a pre-built boto3 SNS client; if None, one is created.
    """
    if sns_client is None:
        if boto3 is None:
            raise RuntimeError("boto3 not available; pass sns_client explicitly")
        sns_client = boto3.client("sns")
    msg = format_message(severity=severity, alert_name=alert_name, fields=fields)
    return sns_client.publish(
        TopicArn=topic_arn,
        Subject=subject[:100],  # SNS subject limit
        Message=msg,
    )
