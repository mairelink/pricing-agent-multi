# Pricing Support Agent — Multi-Agent

> **CRITICAL — READ-ONLY POLICY: No agent in this system may ever write to, insert into, update, delete from, or otherwise modify any BigQuery table. All BigQuery access is strictly read-only (`SELECT`/`WITH` only). `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `CREATE TABLE`, `DROP`, `TRUNCATE`, and all other DDL/DML statements are strictly forbidden.**

This project uses separate instruction files per agent. See the `agents/` folder:

- `agents/orchestrator.md` — Primary agent that receives requests and delegates
- `agents/investigator.md` — Searches Confluence and GitHub
- `agents/data-analyst.md` — Queries BigQuery when data validation is needed
