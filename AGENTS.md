# Pricing Support Agent — Multi-Agent

This project uses separate instruction files per agent. See the `agents/` folder:

- `agents/orchestrator.md` — Primary agent that receives requests and delegates
- `agents/investigator.md` — Searches Confluence and GitHub
- `agents/data-analyst.md` — Queries BigQuery when data validation is needed
