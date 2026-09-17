# 2. Pipeline Architecture

[Back: High-Level Concept](01_high_level_concept.md) | [Main Index](README.md) | [Next: File Breakdown](03_file_by_file_breakdown.md)

---

## Complete Pipeline Lifecycle Diagram

The diagram below outlines how a TTQL query script moves through tokenization, parsing, DAG scheduling, remote execution, in-memory SQLite staging, and result formatting:

```
                 Raw TTQL Script (String)
                            │
                            ▼
                   ┌─────────────────┐
                   │    TtqlLexer    │  Rejects mutation keywords
                   └────────┬────────┘  Emits token stream
                            │ Tokens
                            ▼
                   ┌─────────────────┐
                   │   TtqlParser    │  Constructs AST (TtqlScriptNode)
                   └────────┬────────┘  Validates syntax and structure
                            │ AST
                            ▼
                   ┌─────────────────┐
                   │ TtqlDagPlanner  │  Builds dependency execution graph
                   └────────┬────────┘  Groups independent queries into stages (<= 3 concurrent)
                            │ TtqlQueryPlan
                            ▼
                   ┌─────────────────┐
                   │   TtqlEngine    │  Orchestrates execution lifecycle
                   └────────┬────────┘
                            │
    ┌───────────────────────┼───────────────────────┐
    │ Stage 0 (Parallel)    │ Stage 0 (Parallel)    │ Stage 1 (Dependent)
    ▼                       ▼                       ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│ Connection A  │       │ Connection B  │       │ Connection C  │
│ (PostgreSQL)  │       │   (MongoDB)   │       │    (Redis)    │
└───────┬───────┘       └───────┬───────┘       └───────┬───────┘
        │ Rows                  │ Rows                  │ Filter injected from parent
        └───────────────┬───────┴───────────────────────┘
                        │ Normalized Map Records
                        ▼
       ┌─────────────────────────────────────────────────┐
       │          TtqlEphemeralStagingDatabase           │
       │            (sqlite3.openInMemory())             │
       │                                                 │
       │  CREATE TABLE ttql_stage_0_orders (...)         │
       │  CREATE TABLE ttql_stage_0_users (...)          │
       │  INSERT INTO ... (Transaction Batch)            │
       └────────────────────────┬────────────────────────┘
                                │
                                ▼
       ┌─────────────────────────────────────────────────┐
       │     Synthetic ANSI SQL Cross-Join Execution     │
       │   SELECT ... FROM ttql_stage_0_orders JOIN ...  │
       └────────────────────────┬────────────────────────┘
                                │
                                ▼
                      ┌──────────────────┐
                      │  Output Dataset  │  List<Map<String, dynamic>>
                      └──────────────────┘  Formatted to Table / JSON / CSV
```

---

## Execution Stages and Constraints

1. **Phase 1: Lexical Inspection & Tokenization**
   - Synchronous scan of the query source.
   - Evaluates scanned words against forbidden mutation keywords (`INSERT`, `UPDATE`, `DELETE`, etc.), throwing a `TtqlSecurityException` if any are detected before network sockets are used.

2. **Phase 2: AST Construction & DAG Planning**
   - Parses the token stream into strongly-typed AST nodes.
   - Determines data dependencies between root queries and `JOIN` blocks.
   - Groups operations into execution stages, enforcing a default concurrency limit (`maxConcurrentQueriesPerBatch = 3`) to prevent socket starvation across connection pools.

3. **Phase 3: Remote Execution & In-Memory Staging**
   - Dispatches independent queries for the current stage via `Future.wait()`.
   - Populates the in-memory SQLite database via prepared statements inside a single transaction per table.
   - For dependent join stages, extracts keys from staged tables and injects them into downstream filter predicates (`IN (...)` or `$in`).
   - Executes the final synthetic SQL query across staging tables.
   - Closes the SQLite instance in a `finally` block to release memory.

---

[Back: High-Level Concept](01_high_level_concept.md) | [Main Index](README.md) | [Next: File Breakdown](03_file_by_file_breakdown.md)
