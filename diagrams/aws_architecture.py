#!/usr/bin/env python3
"""
AWS architecture diagram for the FinOps Framework.

Renders aws-architecture.png and aws-architecture.svg in this directory.

Requirements:
    pip install -r requirements.txt
    # Graphviz must also be installed at the OS level:
    #   macOS:   brew install graphviz
    #   Ubuntu:  sudo apt install graphviz
    #   Windows: download from https://graphviz.org/download/

Usage:
    cd diagrams && python aws_architecture.py
"""
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.analytics import Athena, Glue, GlueCrawlers
from diagrams.aws.compute import Lambda
from diagrams.aws.cost import Budgets, CostExplorer
from diagrams.aws.database import Dynamodb
from diagrams.aws.integration import Eventbridge, SNS, SQS
from diagrams.aws.management import (
    Cloudwatch,
    CloudwatchAlarm,
    CloudwatchLogs,
    Cloudtrail,
    Config,
    SystemsManagerParameterStore,
)
from diagrams.aws.security import IAM, KMS, SecretsManager
from diagrams.aws.storage import S3
from diagrams.onprem.client import Users


GRAPH_ATTR = {
    "fontsize": "20",
    "fontname": "Helvetica",
    "labelloc": "t",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.6",
    "ranksep": "1.2",
    "bgcolor": "white",
}

NODE_ATTR = {"fontsize": "12", "fontname": "Helvetica"}
EDGE_ATTR = {"fontsize": "11", "fontname": "Helvetica"}


def main() -> None:
    with Diagram(
        "FinOps Framework — AWS Architecture",
        filename="aws-architecture",
        show=False,
        direction="LR",
        outformat=["png", "svg"],
        graph_attr=GRAPH_ATTR,
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        # ---------- Source ----------
        billing = CostExplorer("AWS Billing\n(BCM Data Exports)")

        # ---------- Data Plane ----------
        with Cluster("Data Plane"):
            s3_cur = S3("cost-data bucket\nCUR 2.0 + FOCUS")
            s3_athena = S3("athena-results")
            s3_config = S3("aws-config")
            ddb_idle = Dynamodb("idle-findings\nSTATE + ACTION")
            ddb_sched = Dynamodb("scheduler-state\nSTATE + ACTION + GSI")
            ddb_budgets = Dynamodb("budget-state\ntrend + audit")
            ddb_alerting = Dynamodb("alerting-events\nDEDUP + AUDIT")
            secrets = SecretsManager("webhook URLs")
            ssm = SystemsManagerParameterStore("KPI mirror")

        # ---------- Analytics Plane ----------
        with Cluster("Analytics Plane"):
            crawler = GlueCrawlers("CUR crawler")
            glue_db = Glue("Glue DB")
            athena = Athena("workgroup\n+ named queries")

        # ---------- Compute Plane ----------
        with Cluster("Compute Plane"):
            schedules = Eventbridge("EventBridge\nschedules + rules")
            with Cluster("Lambda fleet"):
                fn_idle = Lambda("6 idle scanners\n(EBS/EIP/snap/NAT/ENI/LB)")
                fn_kpi = Lambda("KPI aggregator")
                fn_tag = Lambda("untagged-cost +\ntag drift")
                fn_chat = Lambda("alerting dispatcher\n(chat-notifier)")
                fn_sched = Lambda("instance scheduler\n+ weekly discovery")
                fn_budget = Lambda("budget performance")
                fn_health = Lambda("cost-data health")
            dlqs = SQS("DLQs\n(one per Lambda)")
            cfg = Config("AWS Config\n+ required-tag rules")
            budgets = Budgets("AWS Budgets\n+ Budget Actions")

        # ---------- Messaging (events bus) ----------
        sns = SNS("Events SNS topic")

        # ---------- Observability Plane ----------
        with Cluster("Observability Plane"):
            cw_metrics = Cloudwatch("Metrics\nFinOps/*")
            cw_alarms = CloudwatchAlarm("Alarms")
            cw_dash = Cloudwatch("Dashboards\n(per-module)")
            cw_logs = CloudwatchLogs("Logs\nCMK-encrypted")
            ctrail = Cloudtrail("CloudTrail\n(account-managed)")

        # ---------- Security (cross-cutting) ----------
        with Cluster("Security (cross-cutting)"):
            kms = KMS("Framework CMK")
            iam = IAM("Least-privilege\nIAM roles")

        # ---------- External consumers ----------
        chat = Users("Slack / Teams /\nPagerDuty / Opsgenie")
        email = Users("Email subs")
        bi = Users("BI tool\n(Cloudability /\nQuickSight / PowerBI)")

        all_lambdas = [fn_idle, fn_kpi, fn_tag, fn_sched, fn_budget, fn_health, fn_chat]
        scheduled_lambdas = [fn_idle, fn_kpi, fn_tag, fn_sched, fn_budget, fn_health]

        # ===== Data flow =====
        billing >> Edge(label="CUR 2.0 + FOCUS") >> s3_cur
        s3_cur >> crawler >> glue_db >> athena
        athena >> s3_athena
        cfg >> s3_config

        # ===== Compute triggers + reads =====
        schedules >> Edge(label="cron") >> scheduled_lambdas
        all_lambdas >> Edge(style="dashed", color="firebrick") >> dlqs

        fn_kpi >> Edge(label="SQL") >> athena
        fn_tag >> Edge(label="SQL") >> athena
        fn_health >> Edge(label="probe") >> athena
        fn_idle >> Edge(label="state +\naudit log") >> ddb_idle
        fn_sched >> Edge(label="state +\naudit log") >> ddb_sched
        fn_budget >> Edge(label="trend") >> ddb_budgets
        fn_chat >> Edge(label="dedup +\naudit") >> ddb_alerting
        fn_chat >> Edge(label="resolve") >> secrets
        [fn_kpi, fn_tag] >> Edge(label="KPI") >> ssm

        # ===== Events bus inputs =====
        scheduled_lambdas >> Edge(label="digests") >> sns
        budgets >> Edge(label="breach") >> sns
        cfg >> Edge(label="non-compliance") >> schedules
        schedules >> Edge(label="tag drift") >> sns

        # ===== Events bus fan-out =====
        sns >> Edge(label="invoke") >> fn_chat
        sns >> Edge(label="deliver") >> email
        fn_chat >> Edge(label="POST webhook", style="dashed") >> chat

        # ===== Metrics + alarms =====
        scheduled_lambdas >> Edge(label="PutMetricData") >> cw_metrics
        all_lambdas >> Edge(label="logs") >> cw_logs
        cw_metrics >> cw_dash
        cw_metrics >> cw_alarms
        cw_alarms >> Edge(label="ALARM") >> sns

        # ===== BI consumes Athena =====
        athena >> Edge(label="query", style="dashed") >> bi

        # ===== Audit trail =====
        scheduled_lambdas >> Edge(style="dotted", color="gray") >> ctrail

        # ===== Encryption (KMS) =====
        kms >> Edge(label="encrypts at rest", style="dotted", color="purple") >> [
            s3_cur, s3_athena, s3_config,
            ddb_idle, ddb_sched, ddb_budgets, ddb_alerting,
            secrets, sns, cw_logs,
        ]

        # ===== IAM authorizes Lambdas =====
        iam >> Edge(label="authorize", style="dotted", color="darkgreen") >> all_lambdas


if __name__ == "__main__":
    main()
    print("Wrote aws-architecture.png and aws-architecture.svg")
