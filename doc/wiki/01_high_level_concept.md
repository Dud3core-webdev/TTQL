# 1. High-Level Concept & The "Why"

[⬅️ Back to Wiki Index](README.md) | [Next: 2. Pipeline Architecture ➔](02_pipeline_architecture.md)

---

## What Problem TTQL Solves

In modern polyglot application architectures, data is rarely stored in a single monolithic engine. An enterprise platform may store transactional orders in **PostgreSQL**, user session details in **Redis**, product catalogs in **MongoDB**, and analytics event streams in **MySQL** or **SQLite**. 

Historically, querying across these boundaries required developers to either:
1. Write custom glue code in backend microservices to fetch arrays from database A, extract IDs, and pass `$in` filters to database B.
2. Maintain heavy ETL pipelines (e.g., Debezium, Snowflake, Kafka Connect) just to run basic relational queries across disparate sources.

**TTQL (TableTalk Query Language)** is a sovereign, lightweight, cross-engine federated query engine. It provides a declarative SQL-like syntax that allows engineers to query and join heterogenous data engines (Relational, Document, Key-Value) in a single unified script.

---

## The Role of Ephemeral In-Memory SQLite (`sqlite3.openInMemory()`)

Query engines like PostgreSQL, MongoDB, and Redis speak completely different transport wire protocols, index formats, and query primitives. Redis does not natively evaluate SQL `INNER JOIN`s, nor does MongoDB natively run relational SQL subqueries across external Postgres sockets.

To resolve cross-engine joins deterministically without building a massive C++ relational join engine from scratch, TTQL uses an **ephemeral in-memory SQLite instance**:

1. **Isolated Execution Sandbox**: For every TTQL query, TTQL spins up a transient SQLite `:memory:` database using C-bindings (`sqlite3.openInMemory()`).
2. **Staging Micro-Tables**: Data fetched from remote connections (Postgres, Mongo, Redis) is inserted in binary-prepared batches into ephemeral SQLite staging tables (`ttql_stage_0_orders`, `ttql_stage_1_users`).
3. **Synthetic Relational Join Engine**: Once data is staged, TTQL issues an optimized synthetic SQL query directly to the in-memory SQLite engine to compute final `JOIN`, `WHERE`, `ORDER BY`, and `LIMIT` expressions.
4. **Deterministic Garbage Collection**: Upon query completion or exception, the in-memory SQLite handle is explicitly closed and disposed (`_db.dispose()`), immediately reclaiming all RAM allocations with zero memory leaks.

---

## How TTQL Joins Disparate Engine Types

TTQL abstracts connection transport via the `TtqlConnectionProvider` contract:
- **Relational Databases (PostgreSQL, MySQL, SQLite)**: TTQL translates `WHERE` conditions into native SQL predicates and executes `SELECT` statements over native drivers.
- **Document Databases (MongoDB)**: TTQL translates predicates into JSON `$match` filters and projections into Mongo `$project` maps.
- **Key-Value Stores (Redis)**: TTQL translates key lookups into `MGET` or pattern scans (`KEYS`/`SCAN`) and normalizes key-value pairs into tabular rows.

Results returned from all engines are normalized into generic Dart record maps (`List<Map<String, dynamic>>`), streamed into in-memory SQLite, and dynamically joined via standard relational ANSI SQL.

---

[⬅️ Back to Wiki Index](README.md) | [Next: 2. Pipeline Architecture ➔](02_pipeline_architecture.md)
