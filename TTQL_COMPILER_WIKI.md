# TTQL (TableTalk Query Language) — Architecture & Compiler Wiki

> **Role**: Lead Systems Architect & Compiler Engineer  
> **Package**: `package:ttql` (`packages/ttql/`)  
> **Modular Wiki Directory**: [`packages/ttql/doc/wiki/`](doc/wiki/README.md)

---

## 📂 Modular Wiki Pages

1. [**High-Level Concept & The "Why"**](doc/wiki/01_high_level_concept.md)
2. [**End-to-End Pipeline ASCII Architecture**](doc/wiki/02_pipeline_architecture.md)
3. [**File-by-File Technical Breakdown**](doc/wiki/03_file_by_file_breakdown.md)
4. [**Concrete Walkthrough of a Cross-Database Join**](doc/wiki/04_cross_db_join_walkthrough.md)

---

## 1. High-Level Concept & The "Why"

### What Problem TTQL Solves
In modern polyglot application architectures, data is rarely stored in a single monolithic engine. An enterprise platform may store transactional orders in **PostgreSQL**, user session details in **Redis**, product catalogs in **MongoDB**, and analytics event streams in **MySQL** or **SQLite**. 

Historically, querying across these boundaries required developers to either:
1. Write custom glue code in backend microservices to fetch arrays from database A, extract IDs, and pass `$in` filters to database B.
2. Maintain heavy ETL pipelines (e.g., Debezium, Snowflake, Kafka Connect) just to run basic relational queries across disparate sources.

**TTQL (TableTalk Query Language)** is a sovereign, lightweight, cross-engine federated query engine. It provides a declarative SQL-like syntax that allows engineers to query and join heterogenous data engines (Relational, Document, Key-Value) in a single unified script.

### The Role of Ephemeral In-Memory SQLite (`sqlite3.openInMemory()`)
Query engines like PostgreSQL, MongoDB, and Redis speak completely different transport wire protocols, index formats, and query primitives. Redis does not natively evaluate SQL `INNER JOIN`s, nor does MongoDB natively run relational SQL subqueries across external Postgres sockets.

To resolve cross-engine joins deterministically without building a massive C++ relational join engine from scratch, TTQL uses an **ephemeral in-memory SQLite instance**:
1. **Isolated Execution Sandbox**: For every TTQL query, TTQL spins up a transient SQLite `:memory:` database using C-bindings (`sqlite3.openInMemory()`).
2. **Staging Micro-Tables**: Data fetched from remote connections (Postgres, Mongo, Redis) is inserted in binary-prepared batches into ephemeral SQLite staging tables (`ttql_stage_0_orders`, `ttql_stage_1_users`).
3. **Synthetic Relational Join Engine**: Once data is staged, TTQL issues an optimized synthetic SQL query directly to the in-memory SQLite engine to compute final `JOIN`, `WHERE`, `ORDER BY`, and `LIMIT` expressions.
4. **Deterministic Garbage Collection**: Upon query completion or exception, the in-memory SQLite handle is explicitly closed and disposed (`_db.dispose()`), immediately reclaiming all RAM allocations with zero memory leaks.

### How TTQL Joins Disparate Engine Types
TTQL abstracts connection transport via the `TtqlConnectionProvider` contract:
- **Relational Databases (PostgreSQL, MySQL, SQLite)**: TTQL translates `WHERE` conditions into native SQL predicates and executes `SELECT` statements over native drivers.
- **Document Databases (MongoDB)**: TTQL translates predicates into JSON `$match` filters and projections into Mongo `$project` maps.
- **Key-Value Stores (Redis)**: TTQL translates key lookups into `MGET` or pattern scans (`KEYS`/`SCAN`) and normalizes key-value pairs into tabular rows.

Results returned from all engines are normalized into generic Dart record maps (`List<Map<String, dynamic>>`), streamed into in-memory SQLite, and dynamically joined via standard relational ANSI SQL.

---

## 2. End-to-End Pipeline ASCII Architecture Diagram

```
                 RAW TTQL QUERY SCRIPT (String)
                                │
                                ▼
                       ┌─────────────────┐
                       │   TtqlLexer     │  <-- Enforces Read-Only Safety
                       └────────┬────────┘      (Throws TtqlSecurityException on INSERT/UPDATE/DELETE)
                                │ Tokens
                                ▼
                       ┌─────────────────┐
                       │   TtqlParser    │  <-- Emits AST (TtqlScriptNode)
                       └────────┬────────┘      Validates Syntax & Query Declarations
                                │ AST
                                ▼
                       ┌─────────────────┐
                       │ TtqlDagPlanner  │  <-- Builds Dependency Execution Graph
                       └────────┬────────┘      Groups steps into Stages (<= 3 Batch Limit)
                                │ TtqlQueryPlan
                                ▼
                       ┌─────────────────┐
                       │   TtqlEngine    │  <-- Execution Orchestrator
                       └────────┬────────┘
                                │
       ┌────────────────────────┼────────────────────────┐
       │ Stage 0 (Parallel)     │ Stage 0 (Parallel)     │ Stage 1 (Dependent)
       ▼                        ▼                        ▼
┌───────────────┐        ┌───────────────┐        ┌───────────────┐
│ Connection A  │        │ Connection B  │        │ Connection C  │
│ (PostgreSQL)  │        │   (MongoDB)   │        │    (Redis)    │
└───────┬───────┘        └───────┬───────┘        └───────┬───────┘
        │ Raw Rows               │ Raw Rows               │ Foreign Key Filter Injected
        └───────────────┬────────┴────────────────────────┘
                        │ Normalized Map Records
                        ▼
       ┌──────────────────────────────────────────────────┐
       │        TtqlEphemeralStagingDatabase              │
       │           (sqlite3.openInMemory())               │
       │                                                  │
       │  CREATE TABLE ttql_stage_0_orders (...)          │
       │  CREATE TABLE ttql_stage_0_users (...)           │
       │  INSERT INTO ... (Transaction Batch)             │
       └────────────────────────┬─────────────────────────┘
                                │
                                ▼
       ┌──────────────────────────────────────────────────┐
       │   Synthetic ANSI SQL Cross-Join Execution        │
       │   SELECT ... FROM ttql_stage_0_orders JOIN ...   │
       └────────────────────────┬─────────────────────────┘
                                │
                                ▼
                      ┌──────────────────┐
                      │  Output Dataset  │  <-- List<Map<String, dynamic>>
                      └──────────────────┘      Formatted to Table / JSON / CSV
```

---

## 3. File-by-File Technical Breakdown

### 1. [`ttql_lexer.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_lexer.dart)
- **Purpose**: Converts raw TTQL query string source code into a stream of structured tokens (`List<TtqlToken>`).
- **Scanned Tokens**:
  - `TtqlTokenType.keyword`: `DECLARE`, `ASYNC_RUN`, `SELECT`, `WHERE`, `INNER_JOIN`, `LEFT_JOIN`, `ORDER_BY`, `LIMIT`, `CONST`, `IS`.
  - `TtqlTokenType.identifier`: Identifiers for table names, column names, connection aliases, variables.
  - `TtqlTokenType.operator`: `=`, `!=`, `<`, `<=`, `>`, `>=`, `AND`, `OR`, `NOT`, `...`.
  - `TtqlTokenType.stringLiteral`, `numberLiteral`, `punctuation` (`(`, `)`, `{`, `}`, `,`, `;`, `=>`).
- **100% Read-Only Safety Enforcement**:
  During lexical scanning of identifiers (`_scanIdentifierOrKeyword`), every word is checked against `TtqlConstants.forbiddenMutationKeywords`:
  ```dart
  if (TtqlConstants.forbiddenMutationKeywords.contains(text.toUpperCase())) {
    throw TtqlSecurityException(
      'Mutation operation "$text" is forbidden. TTQL is strictly read-only.',
      keyword: text,
    );
  }
  ```
  Forbidden keywords include `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `CREATE`, `GRANT`, `REVOKE`, `EXEC`, `EXECUTE`, `UPSERT`. Any mutation attempt fails at the scanning phase before reaching the database.

---

### 2. [`ttql_parser.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_parser.dart)
- **Purpose**: Consumes `List<TtqlToken>` emitted by the lexer and constructs a strongly typed Abstract Syntax Tree (AST) rooted at `TtqlScriptNode`.
- **Emitted AST Nodes**:
  - [TtqlScriptNode](file:///c:/projects/TableTalk/packages/ttql/lib/models/ttql_script_node.dart): Root node containing connection declarations, constants, query invocations, joins, selection criteria, order by, and limit constraints.
  - [TtqlQueryInvocationNode](file:///c:/projects/TableTalk/packages/ttql/lib/models/ttql_query_invocation_node.dart): Describes a single database read call (`@conn_id.collection_or_table{col1, col2}`).
  - [TtqlJoinNode](file:///c:/projects/TableTalk/packages/ttql/lib/models/ttql_join_node.dart): Represents an `INNER JOIN` or `LEFT JOIN` relationship between query targets.
  - [TtqlWherePredicateNode](file:///c:/projects/TableTalk/packages/ttql/lib/models/ttql_where_predicate_node.dart): Encapsulates filtering predicates.
  - [TtqlComparisonExpression](file:///c:/projects/TableTalk/packages/ttql/lib/models/ttql_comparison_expression.dart), [TtqlBinaryLogicalExpression](file:///c:/projects/TableTalk/packages/ttql/lib/models/ttql_binary_logical_expression.dart): Represent logical tree expressions (`user_id = 101 AND status = 'active'`).
- **Syntax Error & Dialect Handling**:
  Uses recursive descent parsing with lookahead. It validates syntax bounds, requires balanced braces/parentheses, and maps dialect variations (such as `INNER JOIN` vs `JOIN`) into unified AST representations. Syntax errors throw detailed `TtqlParseException` objects containing line and column numbers.

---

### 3. [`ttql_dag_planner.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_dag_planner.dart)
- **Purpose**: Transforms the validated `TtqlScriptNode` AST into a Directed Acyclic Graph (DAG) query execution plan (`TtqlQueryPlan`).
- **DAG & Batch Scheduling ($\le 3$ Concurrency Threshold)**:
  - Discovers independent root queries and dependent join queries.
  - Groups independent queries into **Execution Stages** (`Map<int, List<TtqlPlannedStep>>`).
  - Enforces `TtqlConstants.maxConcurrentQueriesPerBatch = 3`. Root queries are split into chunks of at most 3 steps per stage, preventing socket starvation or connection pool exhaustion when executing multiple remote queries.
  - Dependent joins are scheduled into subsequent stages after their parent stages complete, allowing foreign keys to be extracted from in-memory staging tables and injected into downstream query filters.

---

### 4. [`ttql_ephemeral_staging_database.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_ephemeral_staging_database.dart)
- **Purpose**: Manages the embedded C-based SQLite in-memory engine handle (`sqlite3.openInMemory()`).
- **Dynamic Table Creation & Teardown**:
  - Dynamic Table Definition: `createStagingTable(tableName, columns)` builds SQLite tables on the fly with sanitized column identifiers (`"id" TEXT, "total" TEXT`).
  - Batch Transaction Ingestion: `insertStagingRows(tableName, rows)` wraps bulk inserts inside a single `BEGIN TRANSACTION;` / `COMMIT;` block using prepared statements (`statement.execute(values)`).
  - Synthetic SQL Join Execution: `executeSyntheticJoin(...)` constructs and executes a unified SQL query across all staging tables (`ttql_stage_0_orders JOIN ttql_stage_1_users ON ...`).
  - Memory Leak Prevention: Implements `dispose()`. Calling `_db.dispose()` frees all memory allocated by SQLite for the in-memory database.

---

### 5. [`ttql_engine.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_engine.dart)
- **Purpose**: Top-level orchestrator that drives the end-to-end execution lifecycle.
- **Orchestration Flow**:
  1. Instantiates `TtqlLexer(source).tokenize()` to scan tokens and check read-only invariants.
  2. Passes tokens to `TtqlParser(tokens).parse()` to construct the AST.
  3. Uses `TtqlDagPlanner(environmentContext).plan(script)` to generate the multi-stage `TtqlQueryPlan`.
  4. Initializes `TtqlEphemeralStagingDatabase()`.
  5. Executes stages in order:
     - For each stage, executes up to 3 planned steps concurrently using `Future.wait()`.
     - Calls `provider.executeQuery(...)` for each remote database connection.
     - Ingests returned rows into the ephemeral staging database.
     - For dependent join steps, queries foreign keys from parent staging tables and injects `$in` / `IN (...)` predicates into downstream queries.
  6. Invokes `stagingDb.executeSyntheticJoin(...)` to execute the final join query.
  7. Calls `stagingDb.dispose()` in a `finally` block to ensure zero memory leaks.
  8. Returns a clean `TtqlExecutionResult`.

---

### 6. [`ttql_connection_provider.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_connection_provider.dart) & [`cli_connection_provider.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/cli_connection_provider.dart)
- **Interface Contract (`TtqlConnectionProvider`)**:
  Decouples the core compilation engine from specific database drivers or network socket libraries.
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
  - `CrossDbPoolManager` (in `app/`): Desktop implementation utilizing live connection pools for PostgreSQL, MySQL, SQLite, MongoDB, and Redis.
  - `CliConnectionProvider` (in `packages/ttql/lib/services/cli_connection_provider.dart`): Standalone CLI provider capable of resolving mock configurations, environment variables, or connection strings without Flutter UI dependencies.

---

## 4. Concrete Walkthrough of a Cross-Database Join

### 1. Raw TTQL Query Script
Suppose we want to join customer profiles from a **PostgreSQL** database (`ecommerce_pg.customers`) with order shipments from a **MySQL** database (`inventory_mysql.shipments`).

```javascript
// TableTalk Query Language (TTQL) Federated Analytical Query
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

const targetCustomer = 'cust_101';
const customerFields = ['customer_id', 'full_name', 'email'];
const shipmentFields = ['shipment_id', 'order_id'];

select(() => {
    declare asyncRun(() => {
        PostgreSql(pg.id, [...customerFields], pg.tables['customers']),
        MySql(mysql.id, [...shipmentFields, 'customer_id'], mysql.tables['shipments'])
    })
    .where((row) => row.customer_id is targetCustomer)
})
.orderBy(row => row.shipment_id, 'asc')
.limit(10);
```

---

### 2. Generated Remote Queries

#### Stage 0: Executed against `@ecommerce_pg` (PostgreSQL)
TTQL translates `PostgreSql(pg.id, ...)` into a native PostgreSQL SQL query:
```sql
SELECT "customer_id", "full_name", "email"
FROM "customers";
```
*Result returned to engine*: 1 customer record:
- `[{customer_id: 'cust_101', full_name: 'Alice Smith', email: 'alice@example.com'}]`

#### Stage 0 (Parallel): Executed against `@inventory_mysql` (MySQL)
TTQL translates `MySql(mysql.id, ...)` into a native MySQL query:
```sql
SELECT `shipment_id`, `order_id`, `customer_id`
FROM `shipments`;
```
*Result returned to engine*: 1 shipment record:
- `[{shipment_id: 'shp_99', order_id: 'ord_55', customer_id: 'cust_101'}]`

---

### 3. Ephemeral SQLite Staging Schema & Ingestion

Inside `sqlite3.openInMemory()`, TTQL executes the following setup:

```sql
-- Create Staging Table 0 (PostgreSQL customers)
CREATE TABLE "ttql_stage_0_customers" (
  "customer_id" TEXT,
  "full_name" TEXT,
  "email" TEXT
);

-- Bulk Transaction Insert
BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_customers" ("customer_id", "full_name", "email") VALUES ('cust_101', 'Alice Smith', 'alice@example.com');
COMMIT;

-- Create Staging Table 1 (MySQL shipments)
CREATE TABLE "ttql_stage_0_shipments" (
  "shipment_id" TEXT,
  "order_id" TEXT,
  "customer_id" TEXT
);

-- Bulk Transaction Insert
BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_shipments" ("shipment_id", "order_id", "customer_id") VALUES ('shp_99', 'ord_55', 'cust_101');
COMMIT;
```

---

### 4. Synthetic SQL Execution & Final Output

TTQL executes the synthetic join directly against the in-memory SQLite database:

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

#### Final Returned Result Set:
| customer_id | full_name | email | shipment_id | order_id |
|---|---|---|---|---|
| cust_101 | Alice Smith | alice@example.com | shp_99 | ord_55 |

Immediately after returning this dataset, `stagingDb.dispose()` is invoked, dropping both `ttql_stage_0_customers` and `ttql_stage_0_shipments` and closing the SQLite in-memory handle. Memory footprint returns to zero.

