# 3. File-by-File Technical Breakdown

[⬅️ 2. Pipeline Architecture](02_pipeline_architecture.md) | [Main Index](README.md) | [Next: 4. Join Walkthrough ➔](04_cross_db_join_walkthrough.md)

---

### 1. `ttql_lexer.dart`
- **Source Path**: [`packages/ttql/lib/services/ttql_lexer.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_lexer.dart)
- **Purpose**: Converts raw TTQL query string source code into a stream of structured tokens (`List<TtqlToken>`).
- **Scanned Tokens**:
  - `TtqlTokenType.keyword`: `DECLARE`, `ASYNC_RUN`, `SELECT`, `WHERE`, `INNER_JOIN`, `LEFT_JOIN`, `ORDER_BY`, `LIMIT`, `CONST`, `IS`.
  - `TtqlTokenType.identifier`: Identifiers for table names, column names, connection aliases, variables.
  - `TtqlTokenType.operator`: `=`, `!=`, `<`, `<=`, `>`, `>=`, `AND`, `OR`, `NOT`, `...`.
  - `TtqlTokenType.stringLiteral`, `numberLiteral`, `punctuation` (`(`, `)`, `{`, `}`, `,`, `;`, `=>`).

**100% Read-Only Safety Enforcement**:
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

### 2. `ttql_parser.dart`
- **Source Path**: [`packages/ttql/lib/services/ttql_parser.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_parser.dart)
- **Purpose**: Consumes `List<TtqlToken>` emitted by the lexer and constructs a strongly typed Abstract Syntax Tree (AST) rooted at `TtqlScriptNode`.
- **Emitted AST Nodes**:
  - `TtqlScriptNode`: Root node containing connection declarations, constants, query invocations, joins, selection criteria, order by, and limit constraints.
  - `TtqlQueryInvocationNode`: Describes a single database read call (`@conn_id.collection_or_table{col1, col2}`).
  - `TtqlJoinNode`: Represents an `INNER JOIN` or `LEFT JOIN` relationship between query targets.
  - `TtqlWherePredicateNode`: Encapsulates filtering predicates.
  - `TtqlComparisonExpression`, `TtqlBinaryLogicalExpression`: Represent logical tree expressions (`user_id = 101 AND status = 'active'`).
- **Syntax Error & Dialect Handling**:
  Uses recursive descent parsing with lookahead. It validates syntax bounds, requires balanced braces/parentheses, and maps dialect variations (such as `INNER JOIN` vs `JOIN`) into unified AST representations. Syntax errors throw detailed `TtqlParseException` objects containing line and column numbers.

---

### 3. `ttql_dag_planner.dart`
- **Source Path**: [`packages/ttql/lib/services/ttql_dag_planner.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_dag_planner.dart)
- **Purpose**: Transforms the validated `TtqlScriptNode` AST into a Directed Acyclic Graph (DAG) query execution plan (`TtqlQueryPlan`).

**DAG & Batch Scheduling ($\le 3$ Concurrency Threshold)**:
- Discovers independent root queries and dependent join queries.
- Groups independent queries into **Execution Stages** (`Map<int, List<TtqlPlannedStep>>`).
- Enforces `TtqlConstants.maxConcurrentQueriesPerBatch = 3`. Root queries are split into chunks of at most 3 steps per stage, preventing socket starvation or connection pool exhaustion when executing multiple remote queries.
- Dependent joins are scheduled into subsequent stages after their parent stages complete, allowing foreign keys to be extracted from in-memory staging tables and injected into downstream query filters.

---

### 4. `ttql_ephemeral_staging_database.dart`
- **Source Path**: [`packages/ttql/lib/services/ttql_ephemeral_staging_database.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_ephemeral_staging_database.dart)
- **Purpose**: Manages the embedded C-based SQLite in-memory engine handle (`sqlite3.openInMemory()`).
- **Dynamic Table Creation & Teardown**:
  - Dynamic Table Definition: `createStagingTable(tableName, columns)` builds SQLite tables on the fly with sanitized column identifiers (`"id" TEXT, "total" TEXT`).
  - Batch Transaction Ingestion: `insertStagingRows(tableName, rows)` wraps bulk inserts inside a single `BEGIN TRANSACTION;` / `COMMIT;` block using prepared statements (`statement.execute(values)`).
  - Synthetic SQL Join Execution: `executeSyntheticJoin(...)` constructs and executes a unified SQL query across all staging tables (`ttql_stage_0_orders JOIN ttql_stage_1_users ON ...`).
  - Memory Leak Prevention: Implements `dispose()`. Calling `_db.dispose()` frees all memory allocated by SQLite for the in-memory database.

---

### 5. `ttql_engine.dart`
- **Source Path**: [`packages/ttql/lib/services/ttql_engine.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_engine.dart)
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

### 6. `ttql_connection_provider.dart` & `cli_connection_provider.dart`
- **Source Path**: [`packages/ttql/lib/services/ttql_connection_provider.dart`](file:///c:/projects/TableTalk/packages/ttql/lib/services/ttql_connection_provider.dart)
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

[⬅️ 2. Pipeline Architecture](02_pipeline_architecture.md) | [Main Index](README.md) | [Next: 4. Join Walkthrough ➔](04_cross_db_join_walkthrough.md)
