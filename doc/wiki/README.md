# TTQL (TableTalk Query Language) Compiler Wiki

Welcome to the technical documentation wiki for **TTQL (TableTalk Query Language)**, a sovereign, lightweight federated query engine built in Dart.

This wiki provides a deep, file-by-file compiler engineering breakdown of how TTQL parses, plans, stages, and executes cross-engine queries across relational, document, and key-value databases.

---

## Table of Contents

1. [**High-Level Concept & The "Why"**](01_high_level_concept.md)
   - What problem TTQL actually solves in plain English.
   - The role of the ephemeral in-memory SQLite database (`sqlite3.openInMemory()`).
   - How TTQL pulls and joins disparate data across relational, document, and key-value databases.

2. [**End-to-End Pipeline ASCII Architecture**](02_pipeline_architecture.md)
   - Complete query execution lifecycle ASCII diagram.
   - Execution stage flow and thread throttling rules.

3. [**File-by-File Technical Breakdown**](03_file_by_file_breakdown.md)
   - Detailed analysis of every core component in `packages/ttql/lib/`:
     - `ttql_lexer.dart` (Read-only mutation safety)
     - `ttql_parser.dart` (AST nodes & syntax parsing)
     - `ttql_dag_planner.dart` (DAG scheduling & $\le 3$ concurrency limit)
     - `ttql_ephemeral_staging_database.dart` (C-bindings to SQLite `:memory:`)
     - `ttql_engine.dart` (Top-level orchestrator)
     - `ttql_connection_provider.dart` & `cli_connection_provider.dart` (Transport decoupling)

4. [**Concrete Walkthrough of a Cross-Database Join**](04_cross_db_join_walkthrough.md)
   - Real-world example script joining PostgreSQL orders with MongoDB user documents.
   - Native query translation, downstream foreign key state injection, in-memory SQLite staging tables, and synthetic ANSI SQL execution.

---

[**Next Page: 1. High-Level Concept & The "Why" ➔**](01_high_level_concept.md)
