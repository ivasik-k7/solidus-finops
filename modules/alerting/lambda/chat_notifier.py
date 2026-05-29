"""
FinOps chat notifier.

Receives SNS messages from the FinOps events bus and forwards them to Slack
and/or Teams. Each message is logged to CloudWatch with a structured payload
for downstream SIEM/audit consumption.

Environment variables:
    SLACK_WEBHOOK_SECRET_ARN - if set, fetch Slack webhook URL from this secret
    TEAMS_WEBHOOK_SECRET_ARN - if set, fetch Teams webhook URL from this secret

Banking notes:
    - Webhook URLs live in Secrets Manager (KMS-encrypted with the framework
      CMK). The Lambda role grants secretsmanager:GetSecretValue only on
      those specific secret ARNs.
    - Secrets are fetched once per warm container and cached in module scope.
    - All payloads are logged to CloudWatch Logs with structured JSON.
    - Failures raise so SNS treats the delivery as failed and the configured
      DLQ catches the unprocessed event.
"""
import json
import logging
import os
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SLACK_SECRET_ARN = os.environ.get("SLACK_WEBHOOK_SECRET_ARN", "").strip()
TEAMS_SECRET_ARN = os.environ.get("TEAMS_WEBHOOK_SECRET_ARN", "").strip()

SEVERITY_STYLES = {
    "critical": {"emoji": ":rotating_light:",     "color": "#D00000"},
    "high":     {"emoji": ":warning:",             "color": "#FF8C00"},
    "medium":   {"emoji": ":information_source:",  "color": "#FFC107"},
    "low":      {"emoji": ":bulb:",                "color": "#36A64F"},
    "info":     {"emoji": ":speech_balloon:",      "color": "#3498DB"},
}

# Lazy-initialized clients and cached webhook URLs. Module scope persists
# across warm Lambda invocations, so we pay Secrets Manager once per
# container, not once per message.
_sm_client = None
_webhook_cache = {}


def _secretsmanager():
    global _sm_client
    if _sm_client is None:
        _sm_client = boto3.client("secretsmanager")
    return _sm_client


def _resolve_webhook(arn):
    """Return the webhook URL for a given Secrets Manager ARN, cached per warm container."""
    if not arn:
        return ""
    if arn in _webhook_cache:
        return _webhook_cache[arn]
    resp = _secretsmanager().get_secret_value(SecretId=arn)
    url = (resp.get("SecretString") or "").strip()
    _webhook_cache[arn] = url
    return url


def handler(event, context):
    """SNS handler. SNS delivers one or more Records to Lambda."""
    logger.info("Received event with %d records", len(event.get("Records", [])))

    for record in event.get("Records", []):
        try:
            _process_record(record)
        except Exception:
            logger.exception("Failed to process SNS record")
            raise

    return {"status": "ok"}


def _process_record(record):
    sns = record.get("Sns", {})
    subject = sns.get("Subject") or "FinOps Alert"
    message_raw = sns.get("Message", "")
    timestamp = sns.get("Timestamp", "")

    parsed = _try_parse_json(message_raw)

    severity = _infer_severity(subject, parsed if isinstance(parsed, dict) else {})
    style = SEVERITY_STYLES.get(severity, SEVERITY_STYLES["info"])

    summary = _build_summary(subject, parsed, message_raw)

    logger.info(
        "Processing alert: subject=%s severity=%s ts=%s",
        subject, severity, timestamp,
    )

    slack_url = _resolve_webhook(SLACK_SECRET_ARN)
    teams_url = _resolve_webhook(TEAMS_SECRET_ARN)

    if slack_url:
        _post_slack(summary, subject, severity, style, slack_url)
    if teams_url:
        _post_teams(summary, subject, severity, style, teams_url)


def _try_parse_json(s):
    if not s:
        return None
    try:
        return json.loads(s)
    except (json.JSONDecodeError, TypeError):
        return None


def _infer_severity(subject, parsed):
    """Best-effort severity guess from subject and message content."""
    subj_lower = subject.lower()
    if any(k in subj_lower for k in ("critical", "exceeded", "anomaly", "high impact")):
        return "high"
    if any(k in subj_lower for k in ("warning", "forecast", "approaching")):
        return "medium"
    if any(k in subj_lower for k in ("info", "report", "weekly", "coverage")):
        return "info"
    if isinstance(parsed, dict):
        s = str(parsed.get("severity", "")).lower()
        if s in SEVERITY_STYLES:
            return s
    return "info"


def _build_summary(subject, parsed, raw):
    """Build a human-readable summary block."""
    if isinstance(parsed, dict):
        lines = []
        for key in ("AccountId", "AlertName", "Threshold", "Actual", "Forecasted",
                    "AnomalyScore", "Service", "ImpactUsd", "CostCategory",
                    "BudgetName", "ConfigRuleName", "Compliance"):
            if key in parsed:
                lines.append(f"*{key}*: {parsed[key]}")
        if lines:
            return "\n".join(lines)
        return f"```{json.dumps(parsed, indent=2, default=str)[:3500]}```"
    return raw[:3500] if raw else "(empty message)"


def _post_slack(summary, subject, severity, style, url):
    payload = {
        "text": f"{style['emoji']} *{subject}*",
        "attachments": [
            {
                "color": style["color"],
                "text": summary,
                "footer": f"FinOps Framework · severity={severity}",
            }
        ],
    }
    _http_post(url, payload, "slack")


def _post_teams(summary, subject, severity, style, url):
    payload = {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": style["color"].lstrip("#"),
        "summary": subject,
        "title": f"{style['emoji']} {subject}",
        "sections": [
            {
                "text": summary,
                "facts": [{"name": "Severity", "value": severity}],
            }
        ],
    }
    _http_post(url, payload, "teams")


def _http_post(url, payload, channel):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.getcode()
            body = resp.read().decode("utf-8", errors="replace")
            logger.info("Posted to %s: status=%s body=%s", channel, status, body[:200])
            if status >= 400:
                raise RuntimeError(f"{channel} webhook returned HTTP {status}")
    except urllib.error.HTTPError as e:
        logger.error("HTTP error posting to %s: %s %s", channel, e.code, e.reason)
        raise
    except urllib.error.URLError as e:
        logger.error("URL error posting to %s: %s", channel, e.reason)
        raise
