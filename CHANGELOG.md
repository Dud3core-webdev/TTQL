# Changelog

All notable changes to the `ttql` package are documented in this file.

## 1.0.0

- **Initial Release**: Pure Dart federated query engine and AST parser for analytical queries across multiple databases.
- **Cross-Engine Queries**: Support for querying and joining data across PostgreSQL, MySQL, SQLite, MongoDB, and Redis.
- **Read-Only Safety**: Lexer- and parser-level rejection of data modification statements (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, etc.).
- **In-Memory SQLite Staging**: Ephemeral in-memory database staging (`sqlite3.openInMemory()`) to compute relational joins across disparate sources.
- **DAG Query Planner**: Execution plan generation with stage dependency scheduling and concurrency limits across remote database connections.
- **CLI Tooling**: `ttql` command-line executable providing `lint`, `plan`, `run` (table, JSON, CSV output), and `lsp` commands.
