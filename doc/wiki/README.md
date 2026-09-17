# TTQL Compiler Architecture Wiki

Technical documentation for **TTQL (TableTalk Query Language)**, a federated query engine and AST parser written in pure Dart.

This wiki covers the compilation pipeline, DAG scheduler, ephemeral staging database, and cross-engine execution model.

---

## Contents

1. [High-Level Concept](01_high_level_concept.md)
   - The problem TTQL solves.
   - Role of ephemeral in-memory SQLite (`sqlite3.openInMemory()`).
   - Querying across relational, document, and key-value databases.

2. [Pipeline Architecture](02_pipeline_architecture.md)
   - End-to-end execution lifecycle and diagram.
   - Stage scheduling and connection concurrency limits.

3. [File-by-File Breakdown](03_file_by_file_breakdown.md)
   - Overview of core services in `lib/`:
     - `lib/services/ttql_lexer.dart` (Tokenization and read-only validation)
     - `lib/services/ttql_parser.dart` (AST generation and syntax checking)
     - `lib/services/ttql_dag_planner.dart` (DAG scheduling and batch throttling)
     - `lib/services/ttql_ephemeral_staging_database.dart` (In-memory staging via SQLite C-bindings)
     - `lib/services/ttql_engine.dart` (Execution orchestration)
     - `lib/services/ttql_connection_provider.dart` & `lib/services/cli_connection_provider.dart` (Connection abstraction)

4. [Cross-Database Join Walkthrough](04_cross_db_join_walkthrough.md)
   - Step-by-step example script joining PostgreSQL and MySQL data.
   - Native query translation, staging schema, and synthetic ANSI SQL execution.

5. [Module Architectural Boundaries & Subsystems](05_architectural_boundaries.md)
   - Official topological subsystem specifications and dependency rules.
   - Public API contracts for Compiler, Planner, Runtime, Dialects, and Tooling.

---

[Next: High-Level Concept](01_high_level_concept.md)
