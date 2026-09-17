# TTQL Architecture & Compiler Reference

This document provides a technical overview of the TTQL (TableTalk Query Language) compilation and execution pipeline: lexing, parsing, DAG query planning, ephemeral staging, and cross-database query execution.

For modular documentation pages, see the [doc/wiki/](doc/wiki/README.md) directory:
1. [High-Level Concept](doc/wiki/01_high_level_concept.md)
2. [Pipeline Architecture](doc/wiki/02_pipeline_architecture.md)
3. [File Breakdown](doc/wiki/03_file_by_file_breakdown.md)
4. [Cross-Database Join Walkthrough](doc/wiki/04_cross_db_join_walkthrough.md)

---

## 1. High-Level Architecture

### The Problem TTQL Solves
Polyglot persistence often scatters application data across multiple database systems: transactional orders in PostgreSQL, product catalogs in MongoDB, cache or session data in Redis, and embedded application data in SQLite.

Querying across these boundaries usually forces developers to:
1. Write custom glue code in microservices to fetch data from engine A, extract IDs, and query engine B with `$in` or `IN (...)` filters.
2. Build and maintain ETL pipelines solely to run analytical joins across disparate data sources.

TTQL provides a declarative, read-only query language for querying and joining data across heterogeneous engines in a single script.

### Ephemeral In-Memory SQLite Staging
Different database engines use completely different wire protocols, index formats, and query semantics. Redis does not evaluate relational joins, and MongoDB cannot directly execute SQL joins across external PostgreSQL sockets.

Instead of writing a custom relational join engine from scratch, TTQL leverages an embedded in-memory SQLite database (`sqlite3.openInMemory()`):
1. **Isolated Sandbox**: Each query execution creates a transient SQLite in-memory instance via Dart C-bindings.
2. **Staging Tables**: Data returned from remote database connections is inserted in bulk transactions using prepared statements into staging tables (such as `ttql_stage_0_orders` and `ttql_stage_0_users`).
3. **Synthetic Relational Join**: Once the remote datasets are staged, TTQL executes an ANSI SQL query in SQLite to perform the requested `JOIN`, `WHERE`, `ORDER BY`, and `LIMIT` operations.
4. **Resource Cleanup**: When the query completes or if an error is encountered, `dispose()` is called on the database handle to immediately close the SQLite instance and release memory.

### Cross-Engine Translation
The query engine interacts with database drivers through the `TtqlConnectionProvider` interface:
- **Relational Databases (PostgreSQL, MySQL, SQLite)**: Predicates are translated into native SQL `WHERE` clauses and executed as `SELECT` queries.
- **Document Databases (MongoDB)**: Predicates are converted to JSON `$match` filters and projections to `$project` specifications.
- **Key-Value Stores (Redis)**: Lookups are translated to key scans (`SCAN`/`MGET`) and key-value records are normalized into tabular rows.

Results are returned as normalized Dart maps (`List<Map<String, dynamic>>`), loaded into the staging database, and joined.

---

## 2. Pipeline Execution Diagram

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

## 3. Core Component Breakdown

### [`lib/services/ttql_lexer.dart`](lib/services/ttql_lexer.dart)
- **Role**: Converts raw query text into a stream of tokens (`List<TtqlToken>`).
- **Token Categories**: Keywords (`SELECT`, `WHERE`, `INNER_JOIN`, `LEFT_JOIN`, `ORDER_BY`, `LIMIT`, `CONST`, `IS`), identifiers, operators (`=`, `!=`, `<`, `<=`, `>`, `>=`, `AND`, `OR`, `NOT`), literals (strings, numbers), and punctuation.
- **Read-Only Validation**: Checks scanned identifiers against `TtqlConstants.forbiddenMutationKeywords`:
  ```dart
  if (TtqlConstants.forbiddenMutationKeywords.contains(text.toUpperCase())) {
    throw TtqlSecurityException(
      'Mutation operation "$text" is forbidden. TTQL is strictly read-only.',
      keyword: text,
    );
  }
  ```
  Forbidden keywords include `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `CREATE`, `GRANT`, `REVOKE`, `EXEC`, `EXECUTE`, and `UPSERT`. Attempts to mutate state fail at tokenization.

### [`lib/services/ttql_parser.dart`](lib/services/ttql_parser.dart)
- **Role**: Consumes the token stream and constructs an Abstract Syntax Tree (AST) rooted at `TtqlScriptNode`.
- **Primary AST Nodes**:
  - `TtqlScriptNode`: Root node containing declarations, queries, joins, filters, ordering, and limit specifications.
  - `TtqlQueryInvocationNode`: Represents a target database query stage.
  - `TtqlJoinNode`: Represents an `INNER JOIN` or `LEFT JOIN` relationship between data sources.
  - `TtqlWherePredicateNode`: Encapsulates filtering expressions.
  - `TtqlComparisonExpression`, `TtqlBinaryLogicalExpression`: Represent logical condition trees (e.g. `user_id = 101 AND status = 'active'`).
- **Parser Mechanics**: Uses recursive descent parsing with lookahead. Validates syntax boundaries, balance of braces and parentheses, and produces detailed `TtqlParseException` errors with line and column numbers on failure.

### [`lib/services/ttql_dag_planner.dart`](lib/services/ttql_dag_planner.dart)
- **Role**: Analyzes the AST to build an execution dependency graph (`TtqlQueryPlan`).
- **Scheduling & Concurrency Throttling**:
  - Distinguishes independent root queries from dependent join queries.
  - Partitions independent queries into execution stages (`Map<int, List<TtqlPlannedStep>>`).
  - Enforces `TtqlConstants.maxConcurrentQueriesPerBatch` (default: 3) so that queries executed across remote connections do not saturate connection pools or sockets.
  - Dependent joins are scheduled into subsequent stages after their parent queries complete, allowing foreign keys to be extracted from staged tables and injected into downstream filters.

### [`lib/services/ttql_ephemeral_staging_database.dart`](lib/services/ttql_ephemeral_staging_database.dart)
- **Role**: Manages the transient SQLite in-memory instance (`sqlite3.openInMemory()`).
- **Functionality**:
  - `createStagingTable(tableName, columns)`: Dynamically creates staging tables with sanitized column identifiers.
  - `insertStagingRows(tableName, rows)`: Executes bulk inserts within a single `BEGIN TRANSACTION;` / `COMMIT;` block using compiled prepared statements.
  - `executeSyntheticJoin(...)`: Constructs and executes the final ANSI SQL query across staging tables.
  - `dispose()`: Closes the SQLite instance and releases resources.

### [`lib/services/ttql_engine.dart`](lib/services/ttql_engine.dart)
- **Role**: Top-level orchestrator coordinating the execution lifecycle.
- **Execution Flow**:
  1. Tokenizes input with `TtqlLexer`.
  2. Parses tokens into an AST with `TtqlParser`.
  3. Builds a staged plan with `TtqlDagPlanner`.
  4. Initializes `TtqlEphemeralStagingDatabase`.
  5. Executes stages in order:
     - Dispatches queries in batches using `Future.wait()`.
     - Ingests returned rows into SQLite staging tables.
     - Injects foreign key values into dependent downstream queries.
  6. Executes the synthetic join query on the staging database.
  7. Calls `stagingDb.dispose()` in a `finally` block.
  8. Returns a `TtqlExecutionResult`.

### [`lib/services/ttql_connection_provider.dart`](lib/services/ttql_connection_provider.dart) & [`lib/services/cli_connection_provider.dart`](lib/services/cli_connection_provider.dart)
- **Interface Contract**: Decouples the compiler engine from specific database transport implementations:
  ```dart
  abstract class TtqlConnectionProvider {
    Future<List<Map<String, dynamic>>> executeQuery({
      required String connectionId,
      required DbEngineType engineType,
      required String targetTableOrCollection,
      required List<String> projectedColumns,
      TtqlWherePredicateNode? wherePredicate,
    });
  }
  ```
- **Implementations**:
  - `CliConnectionProvider`: Standalone CLI provider supporting connection strings and offline mock data.
  - External providers (e.g. in client applications) can plug in live connection pools for PostgreSQL, MySQL, SQLite, MongoDB, and Redis.

---

## 4. Concrete Walkthrough: Cross-Database Join

### Example Scenario
Joining customer profiles from PostgreSQL (`ecommerce_pg.customers`) with order shipments from MySQL (`inventory_mysql.shipments`).

### 1. TTQL Query Script

```ttql
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

const targetCustomer = 'cust_101';
const customerFields = ['customer_id', 'full_name', 'email'];
const shipmentFields = ['shipment_id', 'order_id'];

from(pg.customers)
  .select([...customerFields])
  .where(customer_id == targetCustomer)
  .innerJoin(mysql.shipments, on: 'customer_id')
  .select([...shipmentFields])
  .orderBy(shipment_id, 'ASC')
  .limit(10);
```

### 2. Generated Remote Queries

#### PostgreSQL Query (Stage 0)
```sql
SELECT "customer_id", "full_name", "email"
FROM "customers";
```
*Returned row*:
```json
[{"customer_id": "cust_101", "full_name": "Alice Smith", "email": "alice@example.com"}]
```

#### MySQL Query (Stage 0, executed in parallel)
```sql
SELECT `shipment_id`, `order_id`, `customer_id`
FROM `shipments`;
```
*Returned row*:
```json
[{"shipment_id": "shp_99", "order_id": "ord_55", "customer_id": "cust_101"}]
```

### 3. In-Memory Staging Setup

TTQL creates staging tables in the temporary SQLite database and bulk-inserts the results:

```sql
CREATE TABLE "ttql_stage_0_customers" (
  "customer_id" TEXT,
  "full_name" TEXT,
  "email" TEXT
);

BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_customers" ("customer_id", "full_name", "email")
VALUES ('cust_101', 'Alice Smith', 'alice@example.com');
COMMIT;

CREATE TABLE "ttql_stage_0_shipments" (
  "shipment_id" TEXT,
  "order_id" TEXT,
  "customer_id" TEXT
);

BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_shipments" ("shipment_id", "order_id", "customer_id")
VALUES ('shp_99', 'ord_55', 'cust_101');
COMMIT;
```

### 4. Synthetic SQL Join Query

The engine executes the final join query directly against SQLite:

```sql
SELECT 
  "ttql_stage_0_customers"."customer_id" AS "customer_id",
  "ttql_stage_0_customers"."full_name" AS "full_name",
  "ttql_stage_0_customers"."email" AS "email",
  "ttql_stage_0_shipments"."shipment_id" AS "shipment_id",
  "ttql_stage_0_shipments"."order_id" AS "order_id"
FROM "ttql_stage_0_customers"
INNER JOIN "ttql_stage_0_shipments" 
  ON "ttql_stage_0_shipments"."customer_id" = "ttql_stage_0_customers"."customer_id"
WHERE "ttql_stage_0_customers"."customer_id" = 'cust_101'
ORDER BY "ttql_stage_0_shipments"."shipment_id" ASC
LIMIT 10;
```

### Result Dataset
| customer_id | full_name | email | shipment_id | order_id |
|---|---|---|---|---|
| cust_101 | Alice Smith | alice@example.com | shp_99 | ord_55 |

Once the result is returned, `stagingDb.dispose()` closes the in-memory SQLite database handle, releasing all staging resources.

---

## 5. Fluent Query Pipeline

TTQL uses a clean, ergonomic, chainable query pipeline:

```ttql
from(pg.customers)
  .select('customer_id', 'full_name', 'email')
  .where(customer_id == 'cust_101')
  .innerJoin(mysql.shipments, on: 'customer_id')
  .select('shipment_id', 'status')
  .orderBy(customer_id, 'ASC')
  .limit(10);
```

### Strategic Architectural Pillars

1. **AST Representation**:
   The fluent pipeline compiles directly into the immutable `TtqlScriptNode` AST. Downstream execution components—`TtqlDagPlanner`, `QueryDialectStrategy`, and `TtqlEphemeralStagingDatabase`—process stages deterministically.

3. **Operator Ergonomics**:
   `==` maps directly to `=` comparison. Conjunctions `&&` and `||` map directly to logical `AND` and `OR` tokens.

4. **Table Qualifier Disambiguation in `.where(...)`**:
   Conditions can be fully qualified (`pg.customers.customer_id == 'cust_101'`), alias-qualified (`c.customer_id == 'cust_101'`), or bare (`customer_id == 'cust_101'`). The parser automatically routes pushdown predicates to the target database stage.

5. **Short-Form vs. Explicit Join Conditions**:
   - **Natural Equijoin Shorthand**: `.innerJoin(mysql.shipments, on: 'customer_id')`
   - **Explicit Mismatched Key Predicates**: `.innerJoin(mysql.orders, on: mysql.orders.client_id == pg.customers.id)`
   - The parser detects operand orientation and automatically aligns target and parent columns regardless of left/right order.

6. **Implicit Wildcard Projections**:
   Omitting `.select(...)` entirely (`from(pg.customers).where(...)`) defaults to wildcard `SELECT *` projection. The ephemeral SQLite staging database dynamically captures all returned schema columns upon row ingestion.

