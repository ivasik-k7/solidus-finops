# AWS Architecture — High-Level View

This diagram shows the AWS services the framework provisions and how they connect at a logical level. Encryption, IAM, and operational scaffolding are factored out as cross-cutting boxes to keep the data flow legible.

```mermaid
flowchart LR
    classDef src fill:#fef3c7,stroke:#a16207,color:#713f12
    classDef data fill:#dbeafe,stroke:#1e40af,color:#1e3a8a
    classDef compute fill:#fed7aa,stroke:#9a3412,color:#7c2d12
    classDef msg fill:#fee2e2,stroke:#991b1b,color:#7f1d1d
    classDef obs fill:#dcfce7,stroke:#166534,color:#14532d
    classDef sec fill:#e9d5ff,stroke:#6b21a8,color:#4c1d95
    classDef ext fill:#e5e7eb,stroke:#374151,color:#1f2937

    %% ============ SOURCE ============
    BILL["🧾 AWS Billing<br/>(BCM Data Exports API)"]:::src

    %% ============ DATA PLANE ============
    subgraph DATA["📂 Data Plane"]
        S3CUR["S3<br/>cost-data bucket<br/>(CUR 2.0 + FOCUS 1.0)<br/>Glacier IR lifecycle"]:::data
        S3ATH["S3<br/>athena-results bucket"]:::data
        S3CFG["S3<br/>aws-config bucket"]:::data
        DDB["DynamoDB<br/>idle-findings table<br/>STATE + ACTION rows<br/>PITR + TTL"]:::data
        SM["Secrets Manager<br/>Slack &amp; Teams<br/>webhook URLs"]:::data
        SSM["SSM Parameter Store<br/>KPI mirror"]:::data
    end

    %% ============ ANALYTICS ============
    subgraph QUERY["🔍 Analytics Plane"]
        GLUE["AWS Glue<br/>database +<br/>crawler"]:::data
        ATHENA["Athena<br/>workgroup<br/>+ named queries"]:::data
    end

    %% ============ COMPUTE ============
    subgraph COMPUTE["⚙️ Compute Plane"]
        EVENTS["EventBridge<br/>schedules &amp; rules<br/>(per-Lambda crons,<br/>tag drift, anomaly)"]:::compute
        LAMBDAS["AWS Lambda<br/>11 functions<br/>chat-notifier • coverage<br/>scheduler • KPI aggregator<br/>tag drift • 6 idle scanners"]:::compute
        SQS["SQS DLQs<br/>(one per Lambda)"]:::compute
        CONFIG["AWS Config<br/>recorder +<br/>required-tag rules"]:::compute
        AB["AWS Budgets<br/>(polymorphic budgets)"]:::compute
        ANOM["Cost Anomaly Detection<br/>monitor + subscription"]:::compute
        CO["Compute Optimizer<br/>+ Cost Optimization Hub"]:::compute
        RG["Resource Groups<br/>per allocation dimension"]:::compute
    end

    %% ============ MESSAGING ============
    SNS(("📣 SNS<br/>events topic"))
    class SNS msg

    %% ============ OBSERVABILITY ============
    subgraph OBS["📈 Observability Plane"]
        CWMET["CloudWatch Metrics<br/>FinOps/IdleResources<br/>FinOps/KPIs<br/>FinOps/TagGovernance"]:::obs
        CWALM["CloudWatch Alarms<br/>per-Lambda Errors +<br/>DLQ depth + KPI thresholds"]:::obs
        CWDASH["CloudWatch Dashboard<br/>idle-cleanup<br/>(6 widgets)"]:::obs
        CWLOGS["CloudWatch Logs<br/>CMK-encrypted<br/>configurable retention"]:::obs
        CT["CloudTrail<br/>(account-managed,<br/>captures all API calls)"]:::obs
    end

    %% ============ SECURITY (cross-cutting) ============
    KMS["🔐 KMS CMK<br/>(framework key)"]:::sec
    IAM["🪪 IAM<br/>(least-privilege<br/>per Lambda)"]:::sec

    %% ============ EXTERNAL ============
    SLACK["💬 Slack / Teams"]:::ext
    EMAIL["📧 Email"]:::ext
    BI["📊 BI tools<br/>(QuickSight /<br/>PowerBI / Looker)"]:::ext

    %% ============ DATA FLOW EDGES ============
    BILL -->|"CUR 2.0 + FOCUS"| S3CUR
    S3CUR --> GLUE
    GLUE --> ATHENA
    ATHENA --> S3ATH
    CONFIG --> S3CFG

    EVENTS -->|"cron triggers"| LAMBDAS
    LAMBDAS -->|"failed events"| SQS
    LAMBDAS -->|"read CUR via SQL"| ATHENA
    LAMBDAS -->|"state &amp; audit"| DDB
    LAMBDAS -->|"resolve webhooks"| SM
    LAMBDAS -->|"KPI values"| SSM
    LAMBDAS -->|"PutMetricData"| CWMET
    LAMBDAS -->|"logs"| CWLOGS
    LAMBDAS -->|"digests"| SNS

    AB -->|"threshold breaches"| SNS
    ANOM -->|"detections"| SNS
    CONFIG -->|"compliance changes"| EVENTS
    EVENTS -->|"tag drift"| SNS

    CWMET --> CWDASH
    CWMET --> CWALM
    CWALM -->|"alarm state"| SNS

    SNS -->|"fan-out"| LAMBDAS
    SNS --> EMAIL
    LAMBDAS -.->|"webhook POST"| SLACK
    ATHENA -.->|"queries"| BI

    %% ============ SECURITY EDGES (dotted) ============
    KMS -.->|"encrypts at rest"| S3CUR
    KMS -.->|"encrypts at rest"| S3ATH
    KMS -.->|"encrypts at rest"| S3CFG
    KMS -.->|"encrypts at rest"| DDB
    KMS -.->|"encrypts at rest"| SM
    KMS -.->|"encrypts at rest"| SNS
    KMS -.->|"encrypts at rest"| CWLOGS
    IAM -.->|"authorizes"| LAMBDAS

    %% Audit trail
    LAMBDAS -.->|"writes"| CT
```

## What it shows at a glance

- **One data lake on S3**, one query layer (Glue + Athena), one state store (DynamoDB), one events bus (SNS). The framework is structurally simple — the cleverness is in the lifecycle logic on top.
- **Every Lambda has the same shape**: triggered by EventBridge → reads from Athena/DDB → writes to DDB (audit) + CloudWatch (metrics) + SNS (digest). Failures go to per-Lambda DLQs.
- **Encryption is uniform**: a single CMK encrypts S3, DDB, Secrets Manager, SNS, CloudWatch Logs. No encryption gaps.
- **Observability is uniform**: every Lambda emits to CloudWatch metrics under a `FinOps/*` namespace; every Lambda has Errors + DLQ-depth alarms.
- **External integrations are explicit**: chat notifier resolves webhooks from Secrets Manager and POSTs to Slack/Teams; BI tools query Athena directly.

## Cross-cutting concerns

| Concern | How it shows up |
|---|---|
| Encryption at rest | KMS CMK → S3 / DDB / Secrets Manager / SNS / CloudWatch Logs |
| Encryption in transit | TLS-only S3 bucket policy; SNS HTTPS subscriptions |
| Audit trail | CloudTrail (assumed enabled at account level) + DDB ACTION rows with 7-year TTL |
| Least privilege | One IAM role per Lambda with action-and-resource-scoped statements |
| Recovery | `prevent_destroy` on KMS / cost-data S3 / DDB findings table |
| Cost discipline | Glacier IR (not Deep Archive) on current CUR data; Pay-per-request DynamoDB; Lambda free-tier-friendly |

## Operational gotchas highlighted by the diagram

- The crawler step (`S3CUR → GLUE → ATHENA`) is **eventually consistent** — first apply has a ~24-48h delay before Athena queries return data.
- Cost Anomaly Detection has its own 14-day learning window before alerts become useful — the diagram doesn't show that latency, but it's a real first-month operational note.
- DLQs are per-Lambda — there's no single "framework DLQ" to query; each Lambda has its own.
