# Diagrams

Architecture diagrams generated with the Python [`diagrams`](https://diagrams.mingrammer.com/) library (Graphviz-based, real AWS icons). The source is Python — the output is PNG + SVG, committed alongside the code so they always match the framework.

| Source script | Outputs | What it shows |
|---|---|---|
| [framework_structure.py](framework_structure.py) | `framework-structure.png` / `.svg` | Modules grouped by FinOps Foundation Capability domain (Understand / Quantify / Optimize / Manage / Embed) with data and event flows through the central events bus |
| [aws_architecture.py](aws_architecture.py) | `aws-architecture.png` / `.svg` | AWS services the framework provisions, organized into Data / Analytics / Compute / Observability / Security planes, with KMS as a cross-cutting concern |

## Prerequisites

Two things must be installed:

1. **Python `diagrams` package** (in this repo's `requirements.txt`):
   ```bash
   pip install -r requirements.txt
   ```

2. **Graphviz** at the OS level (the library shells out to `dot`):
   - macOS: `brew install graphviz`
   - Ubuntu/Debian: `sudo apt install graphviz`
   - Fedora/RHEL: `sudo dnf install graphviz`
   - Windows: download from [graphviz.org/download](https://graphviz.org/download/) and add to `PATH`

## Render the diagrams

```bash
cd diagrams
python framework_structure.py
python aws_architecture.py
```

Each script writes both a PNG (for embedding in docs) and an SVG (for crisp scaling in presentations).

## Why this library

- **Real AWS icons** out of the box — `S3`, `Lambda`, `Dynamodb`, `Eventbridge`, `Cloudwatch`, etc. — no manual asset wrangling.
- **Code → image** is reproducible: the diagram is a side effect of the script, so it always matches the current intent.
- **Text-based source**: PRs diff cleanly; reviewers can see what changed in the diagram by reading the Python.
- **Layout is automatic** (Graphviz) so contributors don't fight with manual positioning. Tweak `direction`, `nodesep`, `ranksep`, etc. when you want to nudge the layout.

## File layout

```
diagrams/
├── README.md                      # this file
├── requirements.txt               # diagrams package
├── framework_structure.py         # source for framework-structure.png/svg
├── aws_architecture.py            # source for aws-architecture.png/svg
├── framework-structure.png        # generated; commit alongside the source
├── framework-structure.svg        # generated; commit alongside the source
├── aws-architecture.png           # generated
└── aws-architecture.svg           # generated
```

PNGs and SVGs are committed so reviewers don't need to install Graphviz just to look at the diagrams. Regenerate them whenever you edit the `.py` files.

## When to add a new diagram

Each new view should answer a question the existing diagrams don't. Common candidates:

- **Module state-machine** — e.g. the EBS two-phase deletion lifecycle as a `diagrams.generic.compute` + edges. Use a state-machine-like layout (`direction="LR"`).
- **Deployment topology** — multi-account / multi-region. Use nested `Cluster()` blocks per account.
- **Runbook sequence** — anomaly → events bus → chat-notifier → owner Slack DM. The `diagrams` library is less ideal for sequence diagrams; consider a dedicated tool for that view.

Follow the existing conventions: one Python script per diagram, both outputs (`png` + `svg`), graph/node/edge attrs at module top so they stay consistent across diagrams.

## Embedding in markdown

```markdown
![FinOps Framework — Structure](diagrams/framework-structure.png)
![AWS Architecture](diagrams/aws-architecture.png)
```

Or, for crisp scaling on GitHub:

```markdown
<img src="diagrams/framework-structure.svg" width="900" alt="FinOps Framework structure">
```
