# 2. End-to-End Pipeline ASCII Architecture

[⬅️ 1. High-Level Concept](01_high_level_concept.md) | [Main Index](README.md) | [Next: 3. File Breakdown ➔](03_file_by_file_breakdown.md)

---

## Complete Pipeline Lifecycle Diagram

The diagram below outlines how a raw TTQL query string moves through scanning, parsing, DAG scheduling, remote engine execution, in-memory SQLite staging, and final dataset formatting:

```
                 RAW TTQL QUERY SCRIPT (String)
                                │
                                ▼
                       ┌─────────────────┐
                       │   TtqlLexer     │  <-- Enforces Read-Only Safety
                       └────────┬────────┘      (Throws TtqlSecurityException on INSERT/UPDATE/DELETE)
                                │ Tokens
                                ▼
                       ┌─────────────────┐
                       │   TtqlParser    │  <-- Emits AST (TtqlScriptNode)
                       └────────┬────────┘      Validates Syntax & Query Declarations
                                │ AST
                                ▼
                       ┌─────────────────┐
                       │ TtqlDagPlanner  │  <-- Builds Dependency Execution Graph
                       └────────┬────────┘      Groups steps into Stages (<= 3 Batch Limit)
                                │ TtqlQueryPlan
                                ▼
                       ┌─────────────────┐
                       │   TtqlEngine    │  <-- Execution Orchestrator
                       └────────┬────────┘
                                │
       ┌────────────────────────┼────────────────────────┐
       │ Stage 0 (Parallel)     │ Stage 0 (Parallel)     │ Stage 1 (Dependent)
       ▼                        ▼                        ▼
┌───────────────┐        ┌───────────────┐        ┌───────────────┐
│ Connection A  │        │ Connection B  │        │ Connection C  │
│ (PostgreSQL)  │        │   (MongoDB)   │        │    (Redis)    │
└───────┬───────┘        └───────┬───────┘        └───────┬───────┘
        │ Raw Rows               │ Raw Rows               │ Foreign Key Filter Injected
        └───────────────┬────────┴────────────────────────┘
                        │ Normalized Map Records
                        ▼
       ┌──────────────────────────────────────────────────┐
       │        TtqlEphemeralStagingDatabase              │
       │           (sqlite3.openInMemory())               │
       │                                                  │
       │  CREATE TABLE ttql_stage_0_orders (...)          │
       │  CREATE TABLE ttql_stage_0_users (...)           │
       │  INSERT INTO ... (Transaction Batch)             │
       └────────────────────────┬─────────────────────────┘
                                │
                                ▼
       ┌──────────────────────────────────────────────────┐
       │   Synthetic ANSI SQL Cross-Join Execution        │
       │   SELECT ... FROM ttql_stage_0_orders JOIN ...   │
       └────────────────────────┬─────────────────────────┘
                                │
                                ▼
                      ┌──────────────────┐
                      │  Output Dataset  │  <-- List<Map<String, dynamic>>
                      └──────────────────┘      Formatted to Table / JSON / CSV
```

---

## Phase Execution Rules & Boundaries

1. **Phase A (Lexing & Mutation Inspection)**:
   - Synchronous string scan.
   - Enforces zero-mutation guarantees before any network socket is opened.

2. **Phase B (AST & DAG Batch Planning)**:
   - Determines dependency graph between `ASYNC_RUN` target tables and `JOIN` blocks.
   - Mandates `batchSize <= 3` to prevent pool exhaustion when running queries across multiple connections concurrently.

3. **Phase C (Staging Ingestion & Synthetic Joining)**:
   - Opens ephemeral SQLite C-handle.
   - Executes remote reads, streams rows into SQLite prepared statements within explicit `BEGIN TRANSACTION; ... COMMIT;` blocks.
   - Runs final synthetic SQL cross-join, retrieves dataset, and closes the in-memory handle immediately (`dispose()`).

---

[⬅️ 1. High-Level Concept](01_high_level_concept.md) | [Main Index](README.md) | [Next: 3. File Breakdown ➔](03_file_by_file_breakdown.md)
