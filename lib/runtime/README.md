# TTQL Runtime & Ephemeral Staging Subsystem (`lib/runtime`)

## 1. Primary Responsibility
The **Runtime** subsystem orchestrates the live execution of a planned DAG pipeline:
1. Opens an isolated, in-memory SQLite sandbox database (`sqlite3.openInMemory()`).
2. Iterates through sequential execution stages, executing throttled parallel queries across target database connectors.
3. Ingests returned tabular records into staging tables using prepared statements and single-transaction batches.
4. Executes the final synthetic ANSI SQL cross-database join query over the staged data in SQLite.
5. Coerces output rows into normalized analytical maps (`DateTime.toIso8601String()`, JSON strings for nested objects), offloading to background worker isolates when row counts exceed 200.
6. Enforces zero memory leaks by disposing the ephemeral SQLite database immediately in a `finally` block.

## 2. Public API Contracts & Key Interfaces
- **`TtqlEngine`**: Central pipeline execution coordinator.
- **`TtqlEphemeralStagingDatabase`**: Disposable in-memory SQLite sandbox manager. Handles DDL table creation, transactional ingestion, foreign key extraction, and synthetic relational joins without domain heuristics.
- **`TtqlExecutionResult`**: Immutable query result object containing column list, normalized rows, total row count, duration in milliseconds, stages executed, and staged table row counts.

## 3. Dependency Rules
- **Upstream Dependencies**:
  - `lib/planner/` (consumes `TtqlQueryPlan` and `TtqlPlannedStep`).
  - `lib/dialects/` (delegates query string generation via `QueryDialectStrategy`).
  - `lib/connectors/` (executes queries over `TtqlConnectionProvider`).
  - `package:sqlite3` (SQLite C-bindings for `:memory:`).
- **Downstream Dependencies**:
  - Consumed by CLI runner (`bin/ttql.dart run`).
  - Consumed by embedding Dart applications importing `package:ttql/ttql.dart`.
