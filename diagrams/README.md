# Diagrams

Visual companions to the framework. Both are written in **Mermaid** so they render natively in GitHub, GitLab, VS Code, JetBrains IDEs, and most modern markdown viewers — and stay in version control alongside the code.

| Diagram | Audience | Question it answers |
|---|---|---|
| [framework-structure.md](framework-structure.md) | FinOps practitioners, leadership, framework adopters | "What does this framework *do*, and how do the pieces fit together against the FinOps Foundation Capability model?" |
| [aws-architecture.md](aws-architecture.md) | Platform engineers, security reviewers, anyone reading the Terraform | "What AWS services does this framework actually provision, and how do they connect?" |

## How to view

The diagrams are Mermaid code blocks inside markdown files. Three ways to render them:

- **GitHub / GitLab**: just open the `.md` file in the web UI — it renders inline.
- **IDE**: open in VS Code (with the Markdown All in One or Mermaid Preview extension), Cursor, or JetBrains' Markdown plugin.
- **CLI / standalone**: copy the ` ```mermaid ` block into [mermaid.live](https://mermaid.live) for an interactive view.

## Why Mermaid (and not draw.io / Lucid / PowerPoint)

- **Text-based** — diffable, code-reviewable, no merge conflicts on a binary file.
- **Versioned with the code** — diagram drift is impossible; the diagram lives in the same commit as the change that affected it.
- **No license / no vendor lock-in** — open syntax, multiple renderers, embeddable.
- **Re-styleable in seconds** — change the `classDef` lines to match a brand or audience.

## When to add a new diagram

Add one when a new view answers a question the existing diagrams don't:
- A **module-level deep dive** (e.g. "show me the EBS two-phase lifecycle as a state machine") — use `stateDiagram-v2`.
- A **deployment topology** when multi-account / multi-region patterns get added — use `flowchart LR` with subgraphs per account.
- A **sequence diagram** of a specific runbook flow (e.g. anomaly → events bus → chat-notifier → owner Slack DM) — use `sequenceDiagram`.

Keep each file self-contained: title, one Mermaid block, and a short "how to read it" section.
