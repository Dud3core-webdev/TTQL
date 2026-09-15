# Changelog

All notable changes to the `ttql` package will be documented in this file.

## 1.0.0

- **Initial Open-Source Release**: Sovereign, lightweight federated query engine and AST parser.
- **Cross-Engine Queries**: Unified execution across Relational (PostgreSQL, MySQL, SQLite), Document (MongoDB), and Key-Value (Redis) databases.
- **100% Read-Only Safety**: Enforces static lexing and parsing security invariants, throwing `TtqlSecurityException` on mutation attempts.
- **Ephemeral SQLite Sandbox**: Transient `:memory:` database handles per query execution (`sqlite3.openInMemory()`).
- **DAG Execution Planner**: Directed Acyclic Graph scheduler with $\le 3$ concurrency batch throttling.
- **UNIX CLI Executable**: Standalone CLI runner (`ttql lint`, `ttql plan`, `ttql run`) supporting table, JSON, and CSV result formatting with POSIX exit codes (`0`, `1`, `2`).
