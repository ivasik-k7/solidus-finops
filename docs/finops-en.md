# FinOps Study Guide — Exam-Ready, AWS & Banking Focus

**Aligned with:** FinOps Foundation Framework 2025 + FOCP (FinOps Certified Practitioner) exam objectives
**Cloud focus:** AWS
**Industry direction:** Banking / Financial Services

---

## How to use this guide

This guide is structured in four parts:

1. **The Framework** — what the FOCP exam actually tests (definitions, principles, phases, domains, capabilities, personas, maturity, scopes, terminology).
2. **AWS-specific FinOps** — pricing models, native tools, allocation, and optimization mechanics. The exam is cloud-agnostic, but AWS is the world's largest provider and the dominant context in practice.
3. **Banking direction** — regulatory pressure, allocation under audit, unit economics, banking workload patterns, and how the framework bends in a regulated environment.
4. **Exam strategy and sample questions** — pacing, question patterns, and self-test items.

Study order: Part 1 first (it is ~70% of the exam), then weave Parts 2 and 3 into your mental model. The exam will not ask you AWS questions directly — but it _will_ ask scenario questions, and the scenarios feel obvious if you know AWS.

---

# Part 1 — The FinOps Framework (2025)

## 1.1 The definition (memorize this)

> FinOps is an operational framework and cultural practice which maximizes the business value of technology, enables timely data-driven decision making, and creates financial accountability through collaboration between engineering, finance, and business teams.

Three things to notice in the 2025 wording:

- **"Technology"**, not "cloud". The 2025 framework formally expanded FinOps to cover SaaS, licensing, data center, and private cloud spend in addition to public cloud.
- **"Operational framework AND cultural practice"** — both halves matter. The exam tests both.
- **"Collaboration"** is structural, not optional. Decisions made by finance alone, or engineering alone, are _not_ FinOps.

### What FinOps is _not_

- Not just cost cutting. It is value maximization, which sometimes means **spending more** (e.g., adding capacity to win a customer).
- Not a finance-owned function. Engineering owns usage.
- Not a one-time project. It is a continuous practice.
- Not a tool. Tools support FinOps; they don't _are_ FinOps.

---

## 1.2 The six principles (2025 wording)

The exam will paraphrase these. Learn the _intent_ of each so you can recognize them in rewording.

| #   | Principle (2025)                                           | What it means in practice                                                                                         |
| --- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 1   | **Teams need to collaborate**                              | Finance, engineering, product, and business sit at the same table. Real-time, not quarterly.                      |
| 2   | **Business value drives technology decisions**             | Unit economics and value metrics > raw spend. Speed/quality/cost are conscious trade-offs.                        |
| 3   | **Everyone takes ownership of their technology usage**     | Accountability pushed to the edge — engineers own cost from design through ops. Teams manage their own budgets.   |
| 4   | **FinOps data should be accessible, timely, and accurate** | Real-time visibility (hours, not weeks). Discounts and prepayments reflected in shown costs.                      |
| 5   | **A centralized team enables FinOps**                      | A central team (CCoE / FinOps team) drives the practice; execution is decentralized.                              |
| 6   | **Take advantage of the variable cost model of the cloud** | Variable cost is a feature, not a bug. Use it. Don't replicate static datacenter procurement habits in the cloud. |

### Common exam traps on principles

- **"Centralized team drives FinOps"** does **not** mean centralized cost decisions. It means a central team **enables** the practice; teams make their own decisions.
- **"Business value drives decisions"** beats "lowest cost wins" _every time_ on the exam. If an answer says "always choose the cheapest option," it is wrong.
- **"Everyone takes ownership"** means engineering too — not just finance. If an answer puts cost accountability only in finance, it's wrong.

### 2025 update note

The 2019 principle "Decisions are driven by the business value **of cloud**" was reworded in 2025 to "**Business value drives technology decisions**" — to reflect the framework's expansion beyond cloud. The intent is unchanged.

---

## 1.3 The FinOps Lifecycle — Inform, Optimize, Operate

The three phases are **iterative**, not sequential. A mature organization runs all three simultaneously across different workloads and teams.

### Inform

**Goal:** Visibility, allocation, and shared accountability.

Activities:

- Ingest billing data (CUR in AWS, Cost Management in Azure)
- Tag resources and allocate cost to teams, products, environments, cost centers
- Build dashboards and reports finance, engineering, and product all use
- Budget and forecast based on observed patterns
- Benchmark teams against each other and the wider industry
- Show **fully-loaded** costs — apply commitments, RIs, Savings Plans, and credits so the displayed cost reflects what the team would pay if they were a standalone unit.

You are in Inform when teams say "I had no idea we spent that much on X."

### Optimize

**Goal:** Identify and act on opportunities to reduce cost or improve value.

Activities:

- **Rate optimization** — Reserved Instances, Savings Plans, committed-use discounts, negotiated agreements
- **Usage optimization** — rightsizing, scheduling off-hours shutdown, eliminating idle/zombie resources, storage tiering, deleting unattached volumes/IPs/snapshots
- **Architecture optimization** — moving to Graviton, serverless, spot capacity, more efficient databases, caching
- **Workload placement** — region choice, edge vs. core, multi-cloud arbitrage
- **Anomaly detection and remediation**

You are in Optimize when you have visibility but waste is not yet falling.

### Operate

**Goal:** Sustain the practice. Make FinOps a continuous part of how the organization works.

Activities:

- Build policy and governance (guardrails, tagging policies, approval workflows)
- Embed FinOps into engineering processes (cost in design reviews, CI/CD gates, IaC reviews)
- Automate (auto-scaling, scheduled shutdowns, RI/SP coverage automation)
- Define KPIs, track them, report up and across
- Cross-charge or showback to teams; close the feedback loop
- Run regular reviews — weekly anomaly triage, monthly cost reviews, quarterly commitment reviews

You are in Operate when the practice survives the departure of any one person.

### The maturity model: Crawl, Walk, Run

Each capability has Crawl/Walk/Run maturity descriptors. The model is **per-capability**, not per-organization — a single org will be Run on Allocation, Walk on Forecasting, and Crawl on Anomaly Management at the same time.

| Maturity  | Characteristics                                                                                                                    |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Crawl** | Some processes exist but are inconsistent. Coverage is partial (<50%). Manual. Reactive. Few KPIs.                                 |
| **Walk**  | Processes are documented and broadly followed. Coverage 50–75%. Some automation. Defined KPIs. Proactive in some areas.            |
| **Run**   | Processes are automated, measured, and continuously improved. Coverage >75%. Predictive. KPIs drive decisions. Edge cases handled. |

**Exam tip:** "Crawl, Walk, Run" is _not_ a checklist to complete — it is a way of describing where each capability sits. Don't expect everything to be at Run, and don't try to get there for every capability. The exam rewards "advance the capabilities that drive business value" answers.

---

## 1.4 Personas

The framework defines **Core** personas (who do FinOps) and **Allied** personas (who interact with FinOps).

### Core personas

- **FinOps Practitioner** — runs the FinOps function day-to-day. Owns reporting, allocation, optimization recommendations.
- **Engineering and Operations** (sometimes "Engineer/Ops") — builds and runs the workloads. Owns usage decisions.
- **Finance** — owns budgeting, forecasting, accounting, financial reporting, capitalization.
- **Procurement** — owns supplier relationships, contracts, commitment negotiations.
- **Product** — owns the value side: which features earn what, what's worth building, pricing.
- **Leadership** — sets strategy, removes blockers, sponsors the practice.

### Allied personas (interact, not lead)

- **ITAM (IT Asset Management)** — software licensing, asset inventory.
- **ITSM** — service management, change processes.
- **Sustainability** — carbon accounting, increasingly tied to cost via efficiency.
- **Security** — guardrails, controls; in regulated industries this overlaps heavily.
- **Risk and Compliance** — particularly important in banking (see Part 3).

### What to remember for the exam

- The FinOps **Practitioner** does not own cost. They enable it. Cost is owned by the teams consuming the resources.
- Procurement is **separate** from FinOps — but they negotiate the deals FinOps depends on.
- Engineering is a core persona, not allied. This trips people up.

---

## 1.5 Domains and Capabilities

The framework groups **Capabilities** (what you do) into **Domains** (the outcomes they drive).

### The 4 Domains (2025 names)

| Domain                         | Outcome                                          |
| ------------------------------ | ------------------------------------------------ |
| **Understand Usage and Cost**  | Know what you're spending and on what.           |
| **Quantify Business Value**    | Tie spend to business outcomes.                  |
| **Optimize Usage and Cost**    | Reduce waste, improve rates, improve efficiency. |
| **Manage the FinOps Practice** | Run FinOps itself effectively.                   |

Note: "Cloud" was removed from domain names in 2025 to reflect the broadened scope. The exam may use either wording — treat them as equivalent.

### Capabilities mapped to domains

**Understand Usage and Cost**

- Data Ingestion & Normalization
- Allocation
- Reporting & Analytics
- Anomaly Management
- Forecasting

**Quantify Business Value**

- Planning & Estimating
- Budgeting
- Forecasting (overlaps with above; the framework treats forecasting as bridging)
- Measuring Unit Costs
- Benchmarking

**Optimize Usage and Cost**

- Architecting for Cost
- Rate Optimization
- Workload Optimization
- Licensing & SaaS
- Cloud Sustainability (energy and carbon efficiency)

**Manage the FinOps Practice**

- FinOps Practice Operations
- FinOps Education & Enablement
- Onboarding Workloads
- Policy & Governance (renamed from "Cloud Policy & Governance" in 2025)
- FinOps Assessment
- Chargeback & IT Finance Integration
- Intersecting Disciplines (DevOps, Security, ITAM, ITSM, Sustainability)
- Invoicing & Chargeback (in some framework versions, this sits here)

You don't need to memorize every capability verbatim, but you should be able to:

- Place a real activity in the correct domain
- Recognize when an activity is **not** a FinOps capability (e.g., negotiating a software license is procurement; deciding architecture for resilience is engineering — though both intersect with FinOps)

### Capability vs. activity

A **capability** is a functional area (e.g., Allocation). An **activity** is a specific thing you do within it (e.g., applying a tag policy in AWS Organizations). The exam will give you activities and ask which capability they belong to.

---

## 1.6 Scopes (new in 2025)

The 2025 framework introduced **Scopes** as a core element to reflect that practitioners are increasingly applying FinOps beyond public cloud.

Examples of Scopes:

- Public Cloud (the foundational scope — always primary)
- SaaS (Snowflake, Salesforce, Workday, etc.)
- Private Cloud / Data Center
- Licensing
- AI workloads (training, inference, GPU clusters)
- Containers (as a slice cutting across cloud)

### Key exam points on scopes

- Scopes are **not mutually exclusive**. A container cost scope overlaps with a public cloud scope.
- Public cloud remains the **primary** scope — the framework was born there and that's where most maturity sits.
- "Cloud+" is the informal term for FinOps practitioners managing public cloud **plus** additional scopes.
- The framework's capabilities apply across scopes, but the _implementation_ differs (e.g., Allocation in SaaS uses license assignment, not tagging).

### Why this matters in banking

Banks rarely have only public cloud. They have on-prem mainframes, private cloud, multiple SaaS contracts, market data licensing, and increasingly large AI/ML workloads. **Cloud+ FinOps is the realistic operating model for a bank.**

---

## 1.7 Key terminology

| Term                                     | Definition                                                                                                                                                  |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Amortization**                         | Spreading a one-time prepayment (e.g., All Upfront RI) across the term it covers, so monthly cost reports reflect economic reality rather than cash timing. |
| **Anomaly**                              | A statistically unexpected change in cost or usage (positive or negative).                                                                                  |
| **Blended rate**                         | An average rate across a billing family or organization. Hides whose workload drove which cost.                                                             |
| **Unblended rate**                       | The actual rate each account would pay if it were standalone. Preferred for chargeback.                                                                     |
| **Chargeback**                           | Allocating cloud cost to a business unit so it shows up on **their** P&L. Real financial transfer.                                                          |
| **Showback**                             | Same allocation, but informational — no real financial transfer. Common starting point.                                                                     |
| **Cost allocation**                      | Assigning costs to teams, products, environments, cost centers using tags, accounts, or other dimensions.                                                   |
| **Coverage**                             | % of eligible spend covered by commitments (RIs, Savings Plans). Industry benchmark: 70–80%.                                                                |
| **Utilization**                          | % of commitments actually used. Target: >95% (unused commitments are waste).                                                                                |
| **Effective Savings Rate (ESR)**         | Net savings vs. on-demand, after factoring in unused commitments. The honest measure.                                                                       |
| **Forecasting**                          | Predicting future cost based on historical data, plans, and known changes.                                                                                  |
| **Rate optimization**                    | Reducing the price-per-unit (commitments, negotiated discounts, region choice).                                                                             |
| **Usage optimization**                   | Reducing units consumed (rightsizing, shutdown, deletion, architecture).                                                                                    |
| **Rightsizing**                          | Matching resource size to actual workload needs.                                                                                                            |
| **Spot / Preemptible**                   | Discounted capacity that can be reclaimed by the provider. 60–90% cheaper, but interruptible.                                                               |
| **Tag**                                  | Key-value metadata attached to resources for allocation and policy.                                                                                         |
| **Tag policy / Tag enforcement**         | Rules that require certain tags before a resource can be provisioned.                                                                                       |
| **Tag coverage**                         | % of resources with required tags. Target: >95%.                                                                                                            |
| **Unit economics**                       | Cost per business-meaningful unit (per user, per transaction, per GB processed).                                                                            |
| **TBM (Technology Business Management)** | A broader taxonomy for mapping IT cost to business. FinOps can plug into TBM.                                                                               |
| **Reserved Instance (RI)**               | AWS commitment to specific instance configuration for 1 or 3 years for a discount.                                                                          |
| **Savings Plan (SP)**                    | AWS commitment to a $/hour spend for 1 or 3 years for a discount; more flexible than RI.                                                                    |
| **Commitment-based discount (CBD)**      | Generic term for RIs, SPs, CUDs, etc.                                                                                                                       |
| **Cloud bill**                           | The detailed billing data from a provider; in AWS this is the CUR (Cost and Usage Report).                                                                  |
| **FOCUS**                                | FinOps Open Cost & Usage Specification — an open standard for normalizing cost data across providers. Increasingly important on the 2025+ exam.             |

### FOCUS — worth a dedicated note

**FOCUS (FinOps Open Cost and Usage Specification)** is a FinOps Foundation–led open specification that defines a common schema for cloud billing data. It exists because every cloud provider's bill has different columns, units, and conventions, which makes multi-cloud allocation a nightmare. AWS, Azure, GCP, Oracle, and others now publish FOCUS-conformant exports. If a question mentions multi-cloud cost normalization, FOCUS is likely in the right answer.

---

# Part 2 — AWS-Specific FinOps

The FOCP exam is cloud-agnostic, but every practical scenario maps onto a concrete cloud. This section gives you AWS depth that lets you answer scenario questions confidently and lets you actually do the job.

## 2.1 AWS pricing models — when to use what

| Model                                                                   | Discount vs. On-Demand | Commitment                                | Flexibility                                                | Best for                                              |
| ----------------------------------------------------------------------- | ---------------------- | ----------------------------------------- | ---------------------------------------------------------- | ----------------------------------------------------- |
| **On-Demand**                                                           | 0% (baseline)          | None                                      | Total                                                      | Spiky, unpredictable, new workloads                   |
| **Spot Instances**                                                      | Up to ~90%             | None                                      | Interruptible (2-min warning)                              | Stateless, fault-tolerant, batch, dev/test, big data  |
| **Savings Plans — Compute**                                             | Up to ~66%             | 1 or 3 yr, $/hr                           | Cross-region, EC2/Fargate/Lambda, instance family flexible | Most general-purpose compute                          |
| **Savings Plans — EC2 Instance**                                        | Up to ~72%             | 1 or 3 yr, $/hr, instance family + region | Locked to family/region                                    | Steady-state EC2 of known family                      |
| **Savings Plans — SageMaker**                                           | Up to ~64%             | 1 or 3 yr, $/hr                           | SageMaker only                                             | ML training/inference steady-state                    |
| **Reserved Instances — Standard**                                       | Up to ~72%             | 1 or 3 yr, instance config                | Region, family, OS, tenancy locked                         | Highly predictable, single-config workloads           |
| **Reserved Instances — Convertible**                                    | Up to ~54%             | 1 or 3 yr                                 | Can swap families                                          | Predictable spend but evolving architecture           |
| **Capacity Reservations**                                               | No discount            | Reserves capacity in AZ                   | High — pay on-demand                                       | Disaster recovery, predictable capacity for spiky use |
| **Enterprise Discount Program (EDP) / Private Pricing Agreement (PPA)** | Negotiated             | Usually 3-yr total commit                 | Across services                                            | Large enterprise customers                            |

### Choosing between Savings Plans and RIs

The exam-friendly rule of thumb:

- **Compute Savings Plan** = default for most organizations. Maximum flexibility for moderate-to-good discount.
- **EC2 Instance Savings Plan** = for the slice of workload you're certain stays on a specific family.
- **Standard RI** = for RDS, ElastiCache, OpenSearch, Redshift (Savings Plans don't cover these).
- **Convertible RI** = legacy in practice; SPs replaced most of its use cases.

### A typical layered strategy

1. **Bottom layer** — Spot for everything that can tolerate interruption.
2. **Middle layer** — Savings Plans (3-yr, No Upfront or Partial Upfront) for the steady baseline. Aim for ~70–80% coverage.
3. **Top layer** — On-Demand for the spiky top that justifies the premium.

For RDS / ElastiCache / OpenSearch / Redshift, use RIs in the steady layer because SPs don't apply.

### Payment options

- **All Upfront** — biggest discount, biggest cash impact.
- **Partial Upfront** — middle.
- **No Upfront** — smallest discount, no cash outlay (commitment instead).

In a CFO-led finance org (most banks), **No Upfront** is often preferred because it preserves cash even though it sacrifices ~2–4% discount. Whether this is "right" depends on the discount rate the bank uses to value cash — a treasury question, not a FinOps one. On the exam, the principle is: **FinOps surfaces the trade-off; finance makes the call.**

---

## 2.2 AWS-native FinOps tools

| Tool                                                     | Purpose                                                                                     | Where it fits       |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------- |
| **Cost Explorer**                                        | Interactive exploration of cost and usage, with 12-mo forecasts and savings recommendations | Inform / Optimize   |
| **AWS Budgets**                                          | Define budgets, get alerts when forecast or actual breach thresholds                        | Inform / Operate    |
| **Cost and Usage Report (CUR / CUR 2.0 / FOCUS export)** | Detailed billing data export to S3; the raw source of truth                                 | Inform              |
| **Cost Optimization Hub**                                | Centralized recommendations across services — rightsizing, idle, RI/SP, Graviton            | Optimize            |
| **AWS Compute Optimizer**                                | ML-driven recommendations for EC2, EBS, Lambda, ASG rightsizing                             | Optimize            |
| **AWS Trusted Advisor**                                  | Broad checks including cost optimization (idle LB, underutilized EC2, etc.)                 | Optimize            |
| **AWS Organizations**                                    | Multi-account structure, consolidated billing, Service Control Policies (SCPs)              | Operate / Govern    |
| **Tag Policies (in Organizations)**                      | Enforce tagging rules across accounts                                                       | Operate / Govern    |
| **AWS Billing Conductor**                                | Internal pricing/chargeback views (e.g., applying a markup or sharing a discount among BUs) | Operate             |
| **AWS Cost Anomaly Detection**                           | ML-based anomaly detection with alerts                                                      | Inform / Operate    |
| **AWS Pricing Calculator**                               | Pre-build cost estimates                                                                    | Inform (Planning)   |
| **AWS Application Cost Profiler**                        | Allocate shared resource cost to tenants                                                    | Inform (Allocation) |

### CUR vs. CUR 2.0 vs. FOCUS export

AWS now offers three formats of detailed billing data:

- **CUR (legacy)** — the original schema, ~140 columns, denormalized.
- **CUR 2.0** — refreshed schema, easier to query, better defaults.
- **FOCUS 1.0 export** — FOCUS-conformant export. Use this if you want to normalize against Azure/GCP data later.

For new implementations, **CUR 2.0 + a FOCUS export** is the typical pattern. Many banks store both in S3 and load them into Athena / Redshift / Snowflake for analysis.

---

## 2.3 Tagging strategy

A FinOps practice lives or dies on tagging.

### Minimum tag set (industry standard)

| Tag key              | Example value                          | Purpose                                          |
| -------------------- | -------------------------------------- | ------------------------------------------------ |
| `CostCenter`         | `CC-4521`                              | Maps to the financial cost center for chargeback |
| `Environment`        | `prod`, `nonprod`, `dr`                | Drives shutdown policies and chargeback rates    |
| `Application`        | `payments-api`                         | Application-level allocation                     |
| `Owner`              | `team-payments`                        | Who to contact / who pays                        |
| `BusinessUnit`       | `retail-banking`                       | BU-level reporting                               |
| `Compliance`         | `pci`, `sox`, `none`                   | Regulatory scope (critical in banking)           |
| `DataClassification` | `restricted`, `confidential`, `public` | Data-handling rules and policy enforcement       |

### Tag enforcement mechanics

- **Tag Policies in AWS Organizations** — define required keys and allowed values across accounts.
- **Service Control Policies (SCPs)** — block resource creation if required tags are missing. The strongest enforcement.
- **AWS Config rules** — detect non-compliant resources after the fact.
- **IaC reviews** — catch tag gaps before deployment (CloudFormation/Terraform). Cheapest and least disruptive.

### What to remember

- Retroactive tagging is **always** more expensive than preventing tag gaps at provision time.
- Aim for **>95% tag coverage** on the minimum tag set.
- Tag values must be **controlled** — `prod`, `Prod`, and `production` will not match each other.

---

## 2.4 Allocation — chargeback vs. showback in AWS

### Account structure as primary allocation

The simplest allocation in AWS is the **account boundary**. Many banks use a one-account-per-application or one-account-per-team model so that allocation is trivial: the account _is_ the cost center.

### When tags are needed

Shared accounts (centralized data platforms, shared networking, shared security tooling) require tag-based allocation. This is harder because:

- Some costs (Direct Connect, Transit Gateway data processing, KMS) are hard to attribute by tag.
- Some services don't tag (e.g., legacy data transfer charges).

### Shared cost handling

Three common approaches:

1. **Even split** — divide shared cost equally among consumers. Simple, but unfair to small consumers.
2. **Proportional** — split by each consumer's direct spend. Fair, but penalizes the disciplined.
3. **Usage-based** — measure actual consumption (e.g., bytes through Transit Gateway). Best, but expensive to instrument.

In banking, the **regulatory reporting requirement often dictates proportional or usage-based**. Even-split is typically a non-starter for audit.

### Chargeback vs. Showback decision

|                        | Showback   | Chargeback                     |
| ---------------------- | ---------- | ------------------------------ |
| Financial transfer     | None       | Yes — moves money on the books |
| Behavior change        | Moderate   | Strong                         |
| Implementation effort  | Low–Medium | High                           |
| Audit burden           | Low        | High                           |
| Typical starting point | ✓          | Later                          |
| Bank typical end state |            | ✓                              |

Banks **almost always end at chargeback** because internal financial control demands real cost attribution. They typically start at showback to debug the allocation logic before turning on real money flows.

---

## 2.5 Optimization — the practical lever order

When you have a fresh AWS environment, optimization opportunities are usually found in this order (cheapest effort first):

1. **Delete waste** — unattached EBS volumes, idle load balancers, old snapshots, unattached EIPs, orphaned RDS read replicas, dev environments left running overnight. Free money.
2. **Schedule non-production** — shut down dev/test outside business hours. ~65–70% savings on non-prod compute.
3. **Right-size** — Compute Optimizer recommendations. Be careful: rightsizing **before** committing to RIs/SPs avoids stranded commitments.
4. **Storage tiering** — S3 Intelligent-Tiering, lifecycle policies to S3 IA / Glacier / Deep Archive. EBS gp2 → gp3 (~20% cheaper, same/better performance).
5. **Architecture** — migrate eligible workloads to Graviton (ARM), serverless (Lambda, Fargate), or managed databases. Often 20–40% cost reduction plus performance gains.
6. **Commitment-based discounts** — Savings Plans + RIs to cover the steady-state. 30–70% discount on covered usage.
7. **Spot for fault-tolerant** — batch, CI/CD runners, stateless web tiers behind load balancers. Up to ~90% discount.
8. **Data transfer** — the most overlooked. Cross-AZ, cross-region, NAT Gateway, and egress charges often hide the real waste. VPC endpoints (PrivateLink) often pay for themselves quickly.

### Why this order matters for the exam

The exam may ask: "What should the FinOps practitioner do **first** when starting at a new organization?" The answer is almost always **visibility (Inform) before optimization** — you cannot optimize what you cannot see. The implication is: **don't commit to RIs/SPs until you have rightsized and have stable usage data**, because stranded commitments are expensive mistakes.

---

## 2.6 Forecasting in AWS

The simple model: **forecast = historical baseline + known changes + uncertainty band**.

Inputs to a good AWS forecast:

- Historical CUR data (12+ months ideal)
- Planned migrations (workloads moving in)
- Planned decommissions (workloads moving out)
- Product roadmap (new features → new infrastructure)
- Commitment terms ending (RIs/SPs expiring change effective rate)
- Seasonality (retail banks: Black Friday, year-end close, tax season)

Cost Explorer's built-in forecast is a starting point but is naïve — it doesn't know about your roadmap. Most banks build their own forecasting on top of CUR + a planning input from product/engineering.

### Accuracy targets

- **Walk** maturity: ±20% monthly accuracy
- **Run** maturity: ±10% monthly accuracy at the workload level

These are real industry benchmarks. Tighter than ±10% requires near-perfect visibility into planned changes, which is rare.

---

# Part 3 — Banking Direction

This is where FinOps gets interesting. The framework is industry-agnostic, but banking bends it in specific, predictable ways. Knowing these will help you on scenario questions and is essential if you're actually doing FinOps in a bank.

## 3.1 The regulatory landscape that shapes everything

| Regulation                                    | Region                | What it forces on FinOps                                                                                      |
| --------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------- |
| **SOX (Sarbanes-Oxley)**                      | US public companies   | Auditable financial controls. Every cost allocation must be traceable, reproducible, and defensible.          |
| **GLBA (Gramm-Leach-Bliley)**                 | US financial          | Data privacy and safeguards. Affects data classification tagging and shared infrastructure decisions.         |
| **PCI DSS**                                   | Global, card data     | Strict environment isolation. Drives account/VPC segregation, which simplifies allocation but increases cost. |
| **GDPR**                                      | EU residents' data    | Data residency, right to erasure, processing records. Drives region selection and storage cost.               |
| **DORA (Digital Operational Resilience Act)** | EU financial services | Operational resilience, ICT third-party risk register. Forces FinOps to participate in vendor risk reviews.   |
| **Basel III / IV**                            | Global banks (BCBS)   | Capital requirements; indirect impact via FRTB/BCBS 239 driving large compute needs for risk calc.            |
| **MiFID II**                                  | EU markets            | Transaction reporting and record retention. Huge storage and compute footprint.                               |
| **CCAR / DFAST**                              | US large banks        | Stress testing — periodic spikes in compute, ideal for spot/burstable allocation.                             |
| **OFAC / Sanctions**                          | US                    | Region restrictions; affects multi-region cost strategy.                                                      |
| **Various national banking regs**             | Country-by-country    | Data residency, often requires in-country data centers or sovereign cloud regions.                            |

### What this means in practice

1. **Allocation must be auditable.** Allocation logic that a FinOps analyst built in a spreadsheet is **not acceptable**. The logic must be documented, version-controlled, and reproducible from raw CUR.
2. **Data residency increases cost.** You don't always get to pick the cheapest region. EU customer data may have to live in Frankfurt or Dublin even though Ohio is cheaper.
3. **Tagging carries compliance weight.** A `Compliance: PCI` tag isn't documentation — it drives policy enforcement, audit scope, and cost reporting to regulators.
4. **Retention is non-negotiable.** Most banks must retain transaction data for 5–10 years. Storage tiering (S3 Glacier Deep Archive) is essential, not optional.
5. **Risk and Compliance becomes a core, not allied, persona.** The framework lists them as allied; in a bank they sit at the same table as engineering and finance.

---

## 3.2 The banking FinOps operating model

A typical banking FinOps team looks like this:

```
          CFO ----dotted line---- Cloud Center of Excellence (FinOps)
                                         |
            +----------------------------+----------------------------+
            |                            |                            |
    Cloud Financial Analysts    FinOps Engineers           Cloud Governance Specialists
    (allocation models,         (automated controls,        (policy as code,
     forecast, chargeback)       guardrails, IaC)            audit alignment)

         WORKS WITH:
         - Risk & Compliance (mandatory)
         - Internal Audit (periodic review)
         - Procurement (vendor agreements, EDP)
         - Engineering teams (decentralized usage owners)
         - Lines of Business (chargeback recipients)
```

Two things differ from a typical tech-company FinOps team:

- **Three-line partnership** — Tech, Finance, Risk. The framework's "engineering + finance + business" becomes "engineering + finance + risk-and-compliance + business."
- **The FinOps team typically reports into the CTO with a dotted line to the CFO**, not directly to the CFO. This positions it close to engineering, where decisions are actually made.

---

## 3.3 Allocation models in banking

Banks allocate cost at multiple levels simultaneously. A single trade incurs cost that must roll up to:

1. **The trader/desk** (for compensation and P&L)
2. **The product** (FX, fixed income, equities)
3. **The legal entity** (Bank PLC vs. Bank International — different regulators)
4. **The cost center** (for the GL)
5. **The regulatory bucket** (PCI? GDPR? FRTB?)

### How this plays out in AWS

- **Account-level** allocation maps to legal entity or product line.
- **Tag-based** allocation maps to desk, application, cost center.
- **Custom dimensions** in cost data (via CUR + business mapping tables) map to the regulatory bucket.

### Unit economics that matter in banking

| Unit cost                      | Why it matters                                                  |
| ------------------------------ | --------------------------------------------------------------- |
| Cost per trade                 | Trading desk profitability                                      |
| Cost per transaction           | Retail and payments                                             |
| Cost per customer              | Customer-level profitability, drives pricing and churn analysis |
| Cost per loan originated       | Mortgage and consumer lending                                   |
| Cost per risk calculation      | Risk and capital teams                                          |
| Cost per KYC check             | Onboarding                                                      |
| Cost per regulatory report run | Compliance teams                                                |
| Cost per VaR run               | Market risk                                                     |

The exam will not ask you to compute these, but it **will** ask whether you should be measuring them. The answer in banking is: **yes, always**. Aggregate cloud spend tells you nothing useful in a bank; cost per unit of business does.

---

## 3.4 Banking workload archetypes

| Workload                                  | Pattern                                                                               | Optimization angle                                                            |
| ----------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| **Trading platforms**                     | Low-latency, deterministic. Often dedicated tenancy. Spiky around market open/close.  | Reserved capacity, careful with spot (latency-sensitive), close to exchanges. |
| **Risk / VaR / FRTB calc**                | Massive, embarrassingly parallel, runs overnight or end-of-day. Idle 80% of the time. | Spot fleet, Graviton, Batch, scheduled. **Huge** optimization potential.      |
| **Fraud detection**                       | Real-time, ML-heavy, 24/7. Latency-sensitive.                                         | Reserved capacity, Compute SP, careful with spot.                             |
| **KYC / AML**                             | Batch + real-time. Document storage heavy.                                            | S3 lifecycle, OCR via spot.                                                   |
| **Core banking ledger**                   | OLTP, high uptime, often legacy.                                                      | Often the _last_ to move to cloud. RDS/Aurora reserved.                       |
| **Regulatory reporting**                  | Monthly/quarterly cycles, predictable spikes.                                         | Scale-up scheduled compute, Glacier for retained data.                        |
| **Stress testing (CCAR/DFAST)**           | Annual or semi-annual massive spike.                                                  | Spot + ephemeral, ideal cloud workload.                                       |
| **Data lake / market data**               | Storage-dominant, very large.                                                         | S3 tiering, deletion policies, separate from compute.                         |
| **Customer-facing apps / mobile banking** | Variable, customer-driven.                                                            | Auto-scaling, serverless where possible, CDN for static.                      |
| **GenAI / model copilots**                | Increasingly material spend. GPU-intensive.                                           | Bedrock vs. self-hosted trade-off, prompt caching, model distillation.        |

### What an exam scenario might look like

> "A bank runs an overnight FRTB risk calculation that takes 6 hours on a fleet of EC2 instances. The workload is fault-tolerant — failures simply retry. What is the most cost-effective FinOps recommendation?"

The answer: **Spot Instances** (potentially with AWS Batch for orchestration), because the workload is fault-tolerant and time-flexible. Add Graviton if compatible. Avoid 3-year RIs/SPs on this fleet because the workload is intermittent — coverage utilization would crash.

---

## 3.5 Cost controls that banks need that other industries don't

1. **Pre-deployment cost approval gates.** For changes >$X/month estimated impact, FinOps signs off before the IaC deploys. Embedded in the CI/CD pipeline via Pricing Calculator estimates or Infracost / similar.
2. **Tagged-or-deny policies.** Resources without the required tags cannot be created. Enforced via SCPs in AWS Organizations.
3. **Region whitelisting.** SCPs prevent provisioning in regions not approved for data residency reasons. Important corollary: this prevents accidental cheap-region usage that creates compliance risk.
4. **Audit trails of allocation logic.** Every monthly chargeback must be reproducible 7 years later from the raw CUR. Treat the allocation pipeline as financially-material code.
5. **Vendor risk linkage.** Adding a new SaaS or cloud service goes through vendor risk review before cost is considered (DORA in EU). FinOps participates in this but does not gatekeep.
6. **Disaster recovery cost transparency.** DR is mandatory for many systems. The cost of warm/hot standby is non-negotiable but should be visible, optimized (pilot light, warm standby tiers), and allocated to the right cost center.

---

## 3.6 Common banking FinOps anti-patterns

These come up in interviews and in real assessments — and the exam tests recognition of bad practice.

1. **Treating cloud like a data center.** Buying 3-year RIs to "match the depreciation schedule" of the old on-prem hardware. Misses the entire point of variable cost.
2. **Charging back without showing back first.** Charging real money to a BU based on allocation logic they don't trust → political mess. Always run showback for 1–2 quarters to validate.
3. **Ignoring data transfer costs.** Banks build sprawling cross-region, cross-AZ architectures for resilience and forget that data transfer is now 8–15% of the bill.
4. **Letting risk veto without dialogue.** Risk team blocks an optimization for "unspecified compliance reasons." FinOps should bring risk into the conversation early, not late.
5. **One central RI/SP pool but no internal accountability.** Saves money but teams over-provision because they don't see the discount benefit.
6. **Cost as a vanity metric.** "We saved $5M this quarter!" without unit economics is meaningless if revenue grew faster than cost should have.
7. **Building FinOps in finance with no engineering presence.** Doomed to fail. Cost is owned by the people who provision resources.

---

# Part 4 — Exam Strategy

## 4.1 What the FOCP exam is like

- **Format:** Multiple-choice, online, proctored.
- **Length:** ~2 hours, ~60 questions (verify on the FinOps Foundation site for current details; numbers do change).
- **Passing score:** ~75% (verify current threshold).
- **Open book?** No.
- **Validity:** 2 years, then renewal.

The exam tests **recognition and application**, not memorization of obscure capability names. You will see:

- "Which principle applies here?" — recognize the principle from a description.
- "Which phase is this team in?" — recognize Inform/Optimize/Operate from activities.
- "Which domain/capability?" — place an activity correctly.
- "What should the practitioner do first/next?" — apply the framework to a scenario.
- "Which persona owns this?" — know who does what.

## 4.2 Question patterns and how to attack them

### Pattern 1: "Best" answers, not just "correct"

Two answers will often both be defensible. Pick the one that aligns most directly with FinOps principles. The framework's principles are the tiebreaker.

### Pattern 2: "First" vs. "next"

"What should the practitioner do **first**?" almost always points to an Inform-phase answer (visibility before action). "What should they do **next**?" depends on context — read carefully.

### Pattern 3: Persona attribution

When a question asks who owns something, default to the persona whose **outcome** the activity drives:

- Cost of an EC2 instance → engineering owns the usage; FinOps practitioner enables visibility.
- Forecast accuracy → finance owns the budget; FinOps practitioner enables data.
- Negotiating a Savings Plan term → procurement owns the deal; FinOps practitioner provides usage analysis.

### Pattern 4: "Always" / "never" answers are usually wrong

FinOps is about trade-offs. An answer that says "always pick the cheapest option" or "never commit beyond 12 months" is almost certainly wrong. Look for answers that frame the decision as a trade-off informed by data.

### Pattern 5: Tools are not the answer

If a question asks how to achieve an outcome, "Use [Tool X]" is rarely the best answer. The best answer is the capability or practice — the tool follows.

## 4.3 Self-test questions

Try these without looking back. Answers and explanations at the bottom.

**Q1.** A bank's retail trading platform has steady daytime traffic and very low overnight traffic. The application can scale horizontally and tolerates rolling restarts. Which **combination** is the most appropriate FinOps recommendation?

A. 3-year All-Upfront Standard RIs for the entire fleet
B. 1-year No-Upfront Compute Savings Plan for baseline + Spot for the burst tier + scheduled shutdown of dev environments
C. Pure On-Demand because the workload is critical
D. 3-year EC2 Instance Savings Plan for the entire fleet

---

**Q2.** A FinOps practitioner notices that a development account in a bank has $40k/month of unattached EBS volumes and idle load balancers. The practitioner emails the team listed in the `Owner` tag. The team does not respond for three weeks. What is the **best** next step?

A. Delete the resources immediately to stop the bleeding.
B. Escalate to the team's leadership for action while keeping the resources running.
C. Implement an automated policy that quarantines (snapshots and detaches) unattached volumes after 30 days unless tagged with a documented exception.
D. Send a stronger email.

---

**Q3.** Which of the following is **NOT** a core FinOps persona?

A. Engineering
B. Procurement
C. Internal Audit
D. Finance

---

**Q4.** A bank is implementing chargeback for the first time. Which is the most appropriate **first** step?

A. Turn on chargeback immediately so teams feel the pain.
B. Run showback for one or two quarters first, validate the allocation logic with BU finance partners, then transition to chargeback.
C. Negotiate a 3-year EDP with AWS first.
D. Eliminate untagged resources before allocating anything.

---

**Q5.** A team running an overnight FRTB risk-calc job (fault-tolerant, time-flexible) is currently on On-Demand m6i.4xlarge instances. Compute Optimizer recommends m7g.4xlarge with no performance impact, and the job is interruption-tolerant. What is the **best** optimization sequence?

A. Buy 3-year Standard RIs for the m6i fleet.
B. Migrate to m7g (Graviton) on Spot, orchestrated via AWS Batch.
C. Move to Lambda.
D. Move to Fargate Spot with no other changes.

---

**Q6.** Which 2025 framework concept allows a FinOps practice to formally extend to SaaS, licensing, and data center spend?

A. Capabilities
B. Domains
C. Scopes
D. Personas

---

**Q7.** A regulatory body asks a bank to produce, for a transaction that occurred 4 years ago, the exact cloud cost attributable to processing that transaction. The bank cannot produce it because the allocation logic has changed three times and the historical CUR data is partially gone. Which **capability** has failed?

A. Anomaly Management
B. Allocation (and adjacent Policy & Governance / audit trail)
C. Rate Optimization
D. Forecasting

---

**Q8.** Which is the **most accurate** description of the relationship between a centralized FinOps team and engineering teams in a mature organization?

A. The FinOps team owns all cloud cost decisions; engineering implements.
B. Engineering owns all cloud cost decisions; the FinOps team merely reports.
C. The FinOps team enables, educates, and provides data and recommendations; engineering teams own usage decisions for their workloads.
D. The CFO owns all cloud cost decisions; FinOps and engineering both execute.

---

### Answers

**Q1: B.** Trading platforms with steady + spiky pattern call for layered strategy: SP for baseline, Spot for burst, scheduling for non-prod. 3-year All-Upfront on the _entire_ fleet (A) over-commits and ignores the spiky portion. Pure On-Demand (C) misses obvious savings. Locking to a single instance family for 3 years (D) is too rigid.

**Q2: C.** This is an Operate-phase question. The right answer is policy + automation + documented exceptions. (A) is too aggressive without verification. (B) doesn't solve the systemic issue. (D) is not action.

**Q3: C.** Internal Audit is allied, not core. Core personas include Engineering, Procurement, Finance, Product, FinOps Practitioner, Leadership.

**Q4: B.** Showback first is the safest path. The allocation logic must be trusted before money flows. (A) is the classic anti-pattern. (C) is unrelated. (D) sounds plausible but you don't need 100% tagging to start showback — you can show "unallocated" as its own bucket and use that to motivate tagging.

**Q5: B.** Combine usage optimization (Graviton, ~20% cheaper, no perf hit) with rate optimization (Spot, ~70–90% off) for an interruption-tolerant batch job. Orchestrate with Batch for the spot reclaim handling. RIs (A) would strand the commitment when usage is intermittent. Lambda (C) is wrong for long-running compute. Fargate Spot alone (D) leaves Graviton savings on the table.

**Q6: C.** Scopes is the 2025 addition that formalizes this. Capabilities and Domains existed before. Personas describes roles.

**Q7: B.** Allocation has failed (the logic isn't reproducible) and Policy & Governance has failed (no audit trail of changes). The exam-friendly answer is Allocation — but in banking specifically you want to recognize the audit-trail dimension.

**Q8: C.** This is the centralized-team-enables, decentralized-team-owns model. Principles 3 (everyone takes ownership) and 5 (centralized team enables) combine here.

---

## 4.4 Final pre-exam checklist

- [ ] I can state the FinOps definition in my own words and identify the 2025 changes.
- [ ] I can recite the 6 principles and explain each in one sentence.
- [ ] I can describe Inform / Optimize / Operate and place activities into each.
- [ ] I can list the 4 Domains and at least 3 Capabilities per Domain.
- [ ] I can describe Crawl / Walk / Run and explain why maturity is per-capability.
- [ ] I can identify Core vs. Allied personas and what each owns.
- [ ] I can explain Scopes and why they were added in 2025.
- [ ] I can distinguish showback from chargeback and when each is appropriate.
- [ ] I can distinguish unit economics from aggregate cost and explain why unit economics wins.
- [ ] I can explain the difference between rate optimization and usage optimization.
- [ ] I can list at least 3 AWS pricing models and when to use each.
- [ ] I can describe how regulatory requirements bend the framework in banking.
- [ ] I can recognize the "always/never," "first/next," and "best persona" question patterns.

---

# Appendix A — Key URLs to reference (current as of 2026)

- FinOps Foundation Framework overview: https://www.finops.org/framework/
- Principles: https://www.finops.org/framework/principles/
- Phases: https://www.finops.org/framework/phases/
- Domains: https://www.finops.org/framework/domains/
- Capabilities: https://www.finops.org/framework/capabilities/
- 2025 Framework PDF (download from finops.org): English-FinOps-Framework-2025.pdf
- State of FinOps 2025 report: https://data.finops.org/2025-report/
- FOCUS specification: https://focus.finops.org/
- AWS FinOps reference (re:Post articles & AWS Well-Architected Cost Optimization pillar)

# Appendix B — Suggested study sequence (2–3 weeks)

| Week | Focus                                                           | Output                                                                                  |
| ---- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| 1    | Part 1 of this guide + the official FinOps Framework pages      | Be able to write the 6 principles, 3 phases, 4 domains, and capability list from memory |
| 2    | Part 2 (AWS depth) + skim the AWS Cost Management documentation | Be able to map any AWS cost optimization technique to a domain/capability               |
| 2–3  | Part 3 (banking) + practice questions in Part 4                 | Be able to answer scenario questions with confidence                                    |
| 3    | Full mock exam + targeted weak-area review                      | Consistent 80%+ on mocks before sitting the real exam                                   |

---

_Built from the FinOps Foundation Framework 2025, public AWS documentation, and current industry practice in financial services. Verify exam logistics (length, passing score, fee, renewal terms) directly on finops.org as these change._
