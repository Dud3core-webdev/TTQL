# Changelog

All notable changes to the `ttql` package are documented in this file.

## 1.0.2

- **Server Pool Discovery Metadata**: Updated `DbEngineType.supportsServerPoolDiscovery` to include networked `redis` servers (logical DB discovery) and exclude embedded single-file `duckdb` alongside `sqlite`.

## 1.0.1

- **Documentation & Package Metadata**: Updated `pubspec.yaml`, `README.md`, `CONTRIBUTING.md`, and VS Code extension metadata to point to `https://docs.tabletalkapp.net/`, `https://docs.tabletalkapp.net/docs`, and `https://github.com/Dud3core-webdev/TTQL`.
- **Example Config Fix**: Added missing `status` field to `shipments` mock schema/data in `example/connections.json.example`.

## 1.0.0

- **Initial Release**: Pure Dart federated query engine and AST parser for analytical queries across multiple databases.
- **Cross-Engine Queries**: Support for querying and joining data across PostgreSQL, MySQL, SQLite, MongoDB, and Redis.
- **Read-Only Safety**: Lexer- and parser-level rejection of data modification statements (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, etc.).
- **In-Memory SQLite Staging**: Ephemeral in-memory database staging (`sqlite3.openInMemory()`) to compute relational joins across disparate sources.
- **DAG Query Planner**: Execution plan generation with stage dependency scheduling and concurrency limits across remote database connections.
- **CLI Tooling**: `ttql` command-line executable providing `lint`, `plan`, `run` (table, JSON, CSV output), and `lsp` commands.
