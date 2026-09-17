# TTQL Query Dialects Subsystem (`lib/dialects`)

## 1. Primary Responsibility
The **Dialects** subsystem implements the Gang of Four (GoF) **Strategy Pattern** to translate planned AST query steps into native query payloads for disparate database engines.

It isolates database-specific syntax (ANSI SQL identifier quoting, MongoDB JSON MQL formatting, Redis key scanning) completely away from the core execution engine.

## 2. Public API Contracts & Key Interfaces
- **`QueryDialectStrategy`**: Base strategy interface with factory method `forEngine(DbEngineType)`.
  ```dart
  abstract class QueryDialectStrategy {
    String buildQuery({
      required TtqlPlannedStep step,
      required List<dynamic> Function(String stagingTable, String column) foreignKeyLookup,
      required int maxRows,
    });
  }
  ```
- **`SqlQueryDialect`**: Concrete strategy for relational databases (PostgreSQL, MySQL, SQLite, DuckDB, CockroachDB, YugabyteDB, PlanetScale, MSSQL, Oracle, ClickHouse). Handles column projection, table quoting (backtick vs double quote), parameterized WHERE clauses, and LIMIT appending.
- **`MongoQueryDialect`**: Concrete strategy for MongoDB collections. Produces JSON payloads containing collection name, `$match` filters with `$in` foreign key injection, and limit constraints.
- **`RedisQueryDialect`**: Concrete strategy for Redis key stores. Generates `KEYS <pattern>` query payloads.
- **Expression Visitors**:
  - `SqlExpressionVisitor`: Traverses composite `TtqlExpression` trees to generate SQL WHERE clause strings and parameter bindings.
  - `MongoExpressionVisitor`: Traverses composite `TtqlExpression` trees to generate nested MongoDB MQL query maps.

## 3. Dependency Rules
- **Upstream Dependencies**:
  - `lib/compiler/` (consumes `TtqlExpression` and AST models).
  - `lib/planner/` (consumes `TtqlPlannedStep`).
- **Downstream Dependencies**:
  - Consumed exclusively by `lib/runtime/` (`TtqlEngine`).
