# 3. File-by-File Technical Breakdown

[Back: Pipeline Architecture](02_pipeline_architecture.md) | [Main Index](README.md) | [Next: Join Walkthrough](04_cross_db_join_walkthrough.md)

---

### 1. `lib/services/ttql_lexer.dart`

- **Location**: [`lib/services/ttql_lexer.dart](../../lib/services/ttql_lexer.dart)
- **Responsibility**: Converts raw TTQL source code into a stream of structured tokens (`List<TtqlToken>`).
- **Token Classification**:
  - Keywords: `DECLARE`, `ASYNC_RUN`, `SELECT`, `WHERE`, `INNER_JOIN`, `LEFT_JOIN`, `ORDER_BY`, `LIMIT`, `CONST`, `IS`.
  - Identifiers: Database table names, column names, connection identifiers, and script variables.
  - Operators: `=`, `!=`, `<`, `<=`, `>`, `>=`, `AND`, `OR`, `NOT`.
  - Literals & Punctuation: String literals, number literals, delimiters (`(`, `)`, `{`, `}`, `,`, `;`, `=>`).

**Read-Only Safety Check**:
During identifier scanning, tokens are validated against `TtqlConstants.forbiddenMutationKeywords`:
```dart
if (TtqlConstants.forbiddenMutationKeywords.contains(text.toUpperCase())) {
  throw TtqlSecurityException(
    'Mutation operation "$text" is forbidden. TTQL is strictly read-only.',
    keyword: text,
  );
}
```
Forbidden operations include `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `CREATE`, `GRANT`, `REVOKE`, `EXEC`, `EXECUTE`, and `UPSERT`. Detection causes immediate rejection at lexical analysis.

---

### 2. `lib/services/ttql_parser.dart`

- **Location**: [`lib/services/ttql_parser.dart](../../lib/services/ttql_parser.dart)
- **Responsibility**: Consumes tokens from `TtqlLexer` and builds an Abstract Syntax Tree (AST) rooted at `TtqlScriptNode`.
- **Key AST Nodes**:
  - `TtqlScriptNode`: Root node containing connection declarations, constants, query invocations, joins, selection criteria, order-by clauses, and limits.
  - `TtqlQueryInvocationNode`: Represents an individual query target (e.g., `@conn_id.collection_or_table{col1, col2}`).
  - `TtqlJoinNode`: Describes `INNER JOIN` or `LEFT JOIN` relationships between query targets.
  - `TtqlWherePredicateNode`: Encapsulates filtering expressions.
  - `TtqlComparisonExpression`, `TtqlBinaryLogicalExpression`: Form conditional expression trees.
- **Error Handling**:
  Uses recursive descent parsing with lookahead. Syntax errors throw `TtqlParseException` with exact line and column numbers.

---

### 3. `lib/services/ttql_dag_planner.dart`

- **Location**: [`lib/services/ttql_dag_planner.dart](../../lib/services/ttql_dag_planner.dart)
- **Responsibility**: Translates the parsed `TtqlScriptNode` AST into an execution plan (`TtqlQueryPlan`).
- **Scheduling and Concurrency Limits**:
  - Identifies independent root queries versus dependent join queries.
  - Partitions independent queries into execution stages (`Map<int, List<TtqlPlannedStep>>`).
  - Limits concurrent queries per batch (`TtqlConstants.maxConcurrentQueriesPerBatch = 3`) to prevent socket exhaustion.
  - Schedules dependent joins into subsequent stages after root queries resolve so parent foreign keys can be injected into downstream filters.

---

### 4. `lib/services/ttql_ephemeral_staging_database.dart`

- **Location**: [`lib/services/ttql_ephemeral_staging_database.dart](../../lib/services/ttql_ephemeral_staging_database.dart)
- **Responsibility**: Wraps the in-memory SQLite database (`sqlite3.openInMemory()`).
- **Core Operations**:
  - `createStagingTable(tableName, columns)`: Dynamically generates SQLite tables with sanitized column identifiers.
  - `insertStagingRows(tableName, rows)`: Performs bulk inserts within a transaction using prepared statements.
  - `executeSyntheticJoin(...)`: Builds and executes the final ANSI SQL query combining all staged tables.
  - `dispose()`: Closes the SQLite database handle and releases memory.

---

### 5. `lib/services/ttql_engine.dart`

- **Location**: [`lib/services/ttql_engine.dart](../../lib/services/ttql_engine.dart)
- **Responsibility**: Coordinates the full execution flow.
- **Execution Lifecycle**:
  1. Tokenizes input with `TtqlLexer`.
  2. Parses tokens into an AST with `TtqlParser`.
  3. Generates the stage plan with `TtqlDagPlanner`.
  4. Creates `TtqlEphemeralStagingDatabase`.
  5. Executes stages in order:
     - Dispatches remote queries in batches via `Future.wait()`.
     - Ingests returned rows into staging tables.
     - Injects foreign key lists into dependent queries.
  6. Executes the final synthetic SQL join on the staging database.
  7. Invokes `stagingDb.dispose()` in a `finally` block.
  8. Returns a `TtqlExecutionResult`.

---

### 6. `lib/services/ttql_connection_provider.dart` & `lib/services/cli_connection_provider.dart`

- **Location**: [`lib/services/ttql_connection_provider.dart](../../lib/services/ttql_connection_provider.dart)
- **Interface Contract**: Decouples the engine from specific database drivers:
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
  - `CliConnectionProvider`: CLI provider supporting configuration files, environment variables, and offline mock records.
  - Application-level providers can implement live connection pooling for PostgreSQL, MySQL, SQLite, MongoDB, and Redis.

---

[Back: Pipeline Architecture](02_pipeline_architecture.md) | [Main Index](README.md) | [Next: Join Walkthrough](04_cross_db_join_walkthrough.md)
