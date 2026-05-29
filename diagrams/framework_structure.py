#!/usr/bin/env python3
"""
FinOps Framework structure diagram — modules grouped by FinOps Foundation
Capability domain, connected through the central events SNS topic.

Renders framework-structure.png and framework-structure.svg in this directory.

Requirements:
    pip install -r requirements.txt
    # Graphviz must also be installed at the OS level (see aws_architecture.py).

Usage:
    cd diagrams && python framework_structure.py
"""
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.analytics import Athena, Glue
from diagrams.aws.compute import Lambda
from diagrams.aws.cost import (
    Budgets,
    CostExplorer,
    ReservedInstanceReporting,
)
from diagrams.aws.integration import SNS
from diagrams.aws.management import Cloudwatch, Config, SystemsManagerParameterStore
from diagrams.aws.security import IAM
from diagrams.aws.storage import S3
from diagrams.onprem.client import Users


GRAPH_ATTR = {
    "fontsize": "22",
    "fontname": "Helvetica",
    "labelloc": "t",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.5",
    "ranksep": "1.0",
    "bgcolor": "white",
}

NODE_ATTR = {"fontsize": "12", "fontname": "Helvetica"}
EDGE_ATTR = {"fontsize": "11", "fontname": "Helvetica"}


def main() -> None:
    with Diagram(
        "FinOps Framework — Structure &amp; Capabilities",
        filename="framework-structure",
        show=False,
        direction="TB",
        outformat=["png", "svg"],
        graph_attr=GRAPH_ATTR,
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        # =========================================================
        # FinOps Foundation Capability domains (as clusters)
        # =========================================================

        with Cluster("📊  UNDERSTAND — cloud usage &amp; cost"):
            m_cde = S3("cost-data-exports\nCUR 2.0 + FOCUS 1.0")
            m_athena = Athena("Athena workgroup +\nnamed queries")
            m_glue = Glue("Glue catalog +\ncrawler")
            m_tag = Config("tag-governance\nrequired tags + drift")
            m_anom = CostExplorer("anomaly-detection")

        with Cluster("💰  QUANTIFY — business value"):
            m_budgets = Budgets("budgets\naccount / service /\ntag / cost_category")
            m_kpi = Cloudwatch("finops-metrics\nallocation% • coverage%\nutilization% • forecast")

        with Cluster("⚡  OPTIMIZE — usage &amp; cost"):
            m_idle = Lambda("idle-resource-cleanup\nEBS • EIP • Snapshot\nNAT • ENI • LB")
            m_sched = Lambda("instance-scheduler\ntag-driven")
            m_cov = ReservedInstanceReporting("savings-coverage-reporter")
            m_opt = CostExplorer("optimization-services\nCompute Optimizer +\nCost Optimization Hub")

        with Cluster("🛠️  MANAGE — FinOps practice"):
            m_alert = SNS("alerting\nchat-notifier Lambda")
            m_policy = IAM("tag-governance\npolicy guardrails")

        with Cluster("🤝  EMBED — chargeback"):
            m_cc = CostExplorer("cost-categories\nallocation as code")

        # =========================================================
        # Central events bus
        # =========================================================
        events_bus = SNS("EVENTS BUS\nSNS topic\n(KMS-encrypted)")

        # =========================================================
        # Sinks
        # =========================================================
        with Cluster("Sinks"):
            sink_email = Users("Email subs")
            sink_chat = Users("Slack / Teams")
            sink_dash = Cloudwatch("CloudWatch\ndashboards")
            sink_ssm = SystemsManagerParameterStore("SSM Parameter Store\n(cross-workspace KPI mirror)")
            sink_bi = Users("BI tool\n(QuickSight /\nPowerBI / Looker)")

        # =========================================================
        # Data dependencies (solid)
        # =========================================================
        m_cde >> Edge(label="CUR table", color="navy") >> m_glue
        m_glue >> Edge(color="navy") >> m_athena
        m_athena >> Edge(label="SQL", color="navy") >> m_kpi
        m_athena >> Edge(label="SQL", color="navy") >> m_idle
        m_athena >> Edge(label="SQL", color="navy") >> m_tag
        m_athena >> Edge(label="query", style="dashed", color="navy") >> sink_bi
        m_cc >> Edge(label="category dim", color="navy") >> m_kpi
        m_cc >> Edge(label="category dim", color="navy") >> m_budgets

        # =========================================================
        # Event flows into the bus (red)
        # =========================================================
        m_budgets >> Edge(label="threshold breach", color="firebrick") >> events_bus
        m_anom >> Edge(label="anomaly", color="firebrick") >> events_bus
        m_tag >> Edge(label="non-compliance +\ndrift", color="firebrick") >> events_bus
        m_idle >> Edge(label="digests +\naging alarms", color="firebrick") >> events_bus
        m_sched >> Edge(label="start/stop events", color="firebrick") >> events_bus
        m_cov >> Edge(label="weekly report", color="firebrick") >> events_bus
        m_kpi >> Edge(label="KPI threshold\nalarms", color="firebrick") >> events_bus
        m_opt >> Edge(label="recommendations", color="firebrick", style="dashed") >> events_bus

        # =========================================================
        # Bus fan-out
        # =========================================================
        events_bus >> Edge(label="deliver", color="darkgreen") >> m_alert
        m_alert >> sink_email
        m_alert >> sink_chat

        # =========================================================
        # Observability mirrors
        # =========================================================
        m_kpi >> Edge(style="dashed", color="gray") >> sink_dash
        m_tag >> Edge(style="dashed", color="gray") >> sink_dash
        m_idle >> Edge(style="dashed", color="gray") >> sink_dash
        m_kpi >> Edge(style="dashed", color="gray") >> sink_ssm
        m_tag >> Edge(style="dashed", color="gray") >> sink_ssm
        m_idle >> Edge(style="dashed", color="gray") >> sink_ssm


if __name__ == "__main__":
    main()
    print("Wrote framework-structure.png and framework-structure.svg")
