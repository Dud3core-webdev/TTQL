# 1. High-Level Concept

[Back to Wiki Index](README.md) | [Next: Pipeline Architecture](02_pipeline_architecture.md)

---

## What Problem TTQL Solves

In polyglot application architectures, data is often split across multiple database engines. For example, transactional orders may live in **PostgreSQL**, user session tokens in **Redis**, product catalogs in **MongoDB**, and local application caches in **SQLite**.

Querying across these boundaries usually forces developers to either:
1. Write custom glue code in microservices to fetch records from database A, extract identifiers, and pass `$in` or `IN (...)` filters to database B.
2. Build and maintain ETL pipelines solely to run analytical relational queries across disparate sources.

**TTQL (TableTalk Query Language)** is a federated query engine and AST parser written in pure Dart. It provides a declarative, read-only syntax that allows querying and joining data across heterogeneous database engines in a single script.

---

## The Role of Ephemeral In-Memory SQLite (`sqlite3.openInMemory()`)

Different query engines use incompatible transport protocols, index structures, and query capabilities. Redis does not natively evaluate relational SQL `JOIN`s, and MongoDB cannot directly run SQL subqueries against external PostgreSQL sockets.

Instead of implementing a custom relational join engine from scratch, TTQL uses an embedded in-memory SQLite database:

1. **Isolated Execution Sandbox**: For every query execution, TTQL creates a transient SQLite `:memory:` database using Dart C-bindings (`sqlite3.openInMemory()`).
2. **Staging Tables**: Data retrieved from remote connections (PostgreSQL, MongoDB, Redis, MySQL) is inserted into ephemeral staging tables (such as `ttql_stage_0_orders` and `ttql_stage_1_users`) using prepared statements in a single transaction.
3. **Synthetic Relational Join**: After data is staged, TTQL executes an ANSI SQL query directly in SQLite to evaluate `JOIN`, `WHERE`, `ORDER BY`, and `LIMIT` expressions.
4. **Deterministic Resource Cleanup**: Upon query completion or on failure, the SQLite handle is explicitly closed and disposed via `_db.dispose()`, releasing allocated memory.

---

## Cross-Engine Data Abstraction

TTQL abstracts database communication through the `TtqlConnectionProvider` interface:
- **Relational Databases (PostgreSQL, MySQL, SQLite)**: TTQL translates `WHERE` conditions into native SQL predicates and dispatches `SELECT` statements.
- **Document Databases (MongoDB)**: TTQL translates predicates into JSON `$match` filters and projections into `$project` maps.
- **Key-Value Stores (Redis)**: TTQL translates lookups into key scans or `MGET` commands and normalizes key-value pairs into rows.

Results from all engines are converted into normalized Dart maps (`List<Map<String, dynamic>>`), loaded into SQLite staging tables, and joined.

---

[Back to Wiki Index](README.md) | [Next: Pipeline Architecture](02_pipeline_architecture.md)
