# Framework Structure — FinOps Foundation Capability Map

This diagram shows the framework's modules grouped by the five [FinOps Foundation Capability domains](https://www.finops.org/framework/), and how findings, KPIs, and alerts flow through the central events bus.

The **events SNS topic** is the spine: every module that produces a signal publishes there, and every consumer (chat notifier, downstream subscribers) attaches there.

```mermaid
flowchart TB
    classDef domainU fill:#dbeafe,stroke:#1e40af,color:#1e3a8a
    classDef domainQ fill:#dcfce7,stroke:#166534,color:#14532d
    classDef domainO fill:#fed7aa,stroke:#9a3412,color:#7c2d12
    classDef domainM fill:#fef3c7,stroke:#92400e,color:#78350f
    classDef domainE fill:#f3e8ff,stroke:#6b21a8,color:#581c87
    classDef bus fill:#fee2e2,stroke:#991b1b,color:#7f1d1d,stroke-width:3px
    classDef sink fill:#e5e7eb,stroke:#374151,color:#1f2937

    %% ====== UNDERSTAND ======
    subgraph U["📊 UNDERSTAND — cloud usage &amp; cost"]
        CDE["cost-data-exports<br/>CUR 2.0 + FOCUS 1.0<br/>Athena + Glue crawler"]
        TG["tag-governance<br/>Required tags • Drift audit<br/>Untagged-cost report"]
        AD["anomaly-detection<br/>Cost Anomaly Detection<br/>service-level monitor"]
    end

    %% ====== QUANTIFY ======
    subgraph Q["💰 QUANTIFY — business value"]
        B["budgets<br/>account / service / tag /<br/>cost_category scope"]
        FM["finops-metrics<br/>Allocation% • Coverage% •<br/>Utilization% • Forecast drift"]
    end

    %% ====== OPTIMIZE ======
    subgraph O["⚡ OPTIMIZE — usage &amp; cost"]
        IRC["idle-resource-cleanup<br/>EBS • EIP • Snapshot<br/>NAT • ENI • LB<br/>DDB state + audit log"]
        IS["instance-scheduler<br/>Tag-driven start/stop"]
        SCR["savings-coverage-reporter<br/>RI / SP coverage + util"]
        OS["optimization-services<br/>Compute Optimizer +<br/>Cost Optimization Hub"]
    end

    %% ====== MANAGE ======
    subgraph M["🛠️ MANAGE — FinOps practice"]
        A["alerting<br/>SNS events bus +<br/>chat-notifier Lambda"]
        TGP["tag-governance<br/>policy guardrails"]
    end

    %% ====== EMBED ======
    subgraph E["🤝 EMBED — chargeback &amp; ledger"]
        CC["cost-categories<br/>Allocation as code"]
    end

    %% ====== EVENTS BUS ======
    EB(("EVENTS BUS<br/>SNS Topic<br/>KMS-encrypted"))

    %% ====== SINKS ======
    EMAIL["📧 Email subscribers"]
    CHAT["💬 Slack / Teams<br/>(Secrets Manager URLs)"]
    DASH["📈 CloudWatch dashboards"]
    BI["📊 BI tool<br/>(QuickSight / PowerBI / Looker)"]
    SSM["🗝️ SSM Parameter Store<br/>cross-workspace KPI mirror"]

    %% ====== EDGES — data flow ======
    CDE -->|"CUR + FOCUS"| FM
    CDE -->|"Athena queries"| IRC
    CDE -->|"CUR table"| BI
    CC -->|"category dimension"| FM
    CC -->|"category dimension"| B

    %% ====== EDGES — events bus ======
    B -->|"threshold breaches"| EB
    AD -->|"anomalies"| EB
    TG -->|"non-compliance +<br/>drift events"| EB
    IRC -->|"weekly digests +<br/>aging alarms"| EB
    IS -->|"start/stop events"| EB
    SCR -->|"weekly coverage report"| EB
    FM -->|"KPI thresholds"| EB
    OS -.->|"recs surfaced"| EB

    %% ====== EDGES — alerting fan-out ======
    EB -->|"deliver"| A
    A --> EMAIL
    A --> CHAT

    %% ====== EDGES — observability ======
    FM --> DASH
    TG --> DASH
    IRC --> DASH
    FM --> SSM
    TG --> SSM
    IRC --> SSM

    %% ====== STYLING ======
    class CDE,TG,AD domainU
    class B,FM domainQ
    class IRC,IS,SCR,OS domainO
    class A,TGP domainM
    class CC domainE
    class EB bus
    class EMAIL,CHAT,DASH,BI,SSM sink
```

## How to read this diagram

- **Coloured groups** = FinOps Foundation Capability domains. Each module sits in the domain(s) it primarily serves.
- **The red bus** = single SNS events topic. Every module publishes here; the chat notifier and email subscribers consume from here. One topic, many channels.
- **Solid arrows** = synchronous data dependencies (e.g., `finops-metrics` queries the `cost-data-exports` Athena tables).
- **Solid arrows into the bus** = asynchronous events (alerts, anomalies, digests, alarms).
- **Dotted arrows** = informational / optional flows.

## Module-to-capability cross-reference

| Module | Primary capability | Secondary capability |
|---|---|---|
| `cost-data-exports` | Data Ingestion & Normalization | Reporting & Analytics |
| `cost-categories` | Allocation | Chargeback & Ledger |
| `tag-governance` | Policy & Governance | Allocation, Reporting |
| `anomaly-detection` | Anomaly Management | — |
| `budgets` | Budgeting | Forecasting |
| `finops-metrics` | Reporting & Analytics | Benchmarking, Unit Economics |
| `optimization-services` | Architecting for Cloud | Workload Optimization |
| `idle-resource-cleanup` | Workload Optimization | — |
| `instance-scheduler` | Workload Optimization | — |
| `savings-coverage-reporter` | Rate Optimization | — |
| `alerting` | FinOps Practice Operations | — |
