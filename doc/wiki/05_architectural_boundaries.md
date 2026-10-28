# Module Architectural Boundaries & Subsystems

This document establishes the official architectural boundaries, responsibilities, public interfaces, and dependency rules for the TTQL codebase. Following these guidelines guarantees that any software engineer can navigate, maintain, and extend the system without relying on an LLM or violating SOLID principles.

---

## Architectural Topology

```
                         ┌───────────────────────┐
                         │   lib/compiler/       │  Frontend
                         │  (Lexing & Parsing)   │
                         └───────────┬───────────┘
                                     │ AST (TtqlScriptNode)
                                     ▼
                         ┌───────────────────────┐
                         │    lib/planner/       │  Middle-End
                         │   (DAG Scheduling)    │
                         └───────────┬───────────┘
                                     │ Plan (TtqlQueryPlan)
                                     ▼
┌──────────────────┐     ┌───────────────────────┐     ┌──────────────────┐
│  lib/connectors/ │◄────┤    lib/runtime/       ├────►│  lib/dialects/   │
│ (Driver Sockets) │     │ (Staging & Execution) │     │ (Query Strategy) │
└──────────────────┘     └───────────┬───────────┘     └──────────────────┘
                                     │ Results (List<Map<String, dynamic>>)
                                     ▼
                         ┌───────────────────────┐
                         │    lib/tooling/       │  Backend & Developer UX
                         │  (LSP, CLI, & Table)  │
                         └───────────────────────┘
```

---

## 1. Compiler Subsystem (`lib/compiler/compiler.dart` & `lib/models/`)

### Primary Responsibility
The compiler frontend scans raw TTQL query script text into tokens, enforces read-only security invariants (rejecting SQL mutations like `DROP`, `DELETE`, `INSERT`), validates syntax, and constructs an immutable Abstract Syntax Tree (AST).

### Public API Contracts & Key Types
* `TtqlLexer`: Scans source code and enforces mutation rejection.
* `TtqlParser`: Recursive descent parser producing `TtqlScriptNode`.
* `DbEngineRegistry`: Centralized $O(1)$ engine identifier resolver.
* AST Nodes: `TtqlScriptNode`, `TtqlSelectNode`, `TtqlJoinNode`, `TtqlWherePredicateNode`, `TtqlExpression`.

### Dependency Rules
* **Allowed Upstream**: Dart Core / Standard Library only. Zero third-party dependencies.
* **Allowed Downstream**: Consumed by `planner/` and `tooling/`.

---

## 2. Planner Subsystem (`lib/planner/planner.dart` & `lib/services/ttql_dag_planner.dart`)

### Primary Responsibility
Transforms a declarative AST into an executable Directed Acyclic Graph (DAG) query plan (`TtqlQueryPlan`). Throttles independent root queries into batches of at most 3 concurrent isolate queries (`TtqlConstants.maxConcurrentQueriesPerBatch`) and sequences foreign-key dependent joins into sequential stages.

### Public API Contracts & Key Types
* `TtqlDagPlanner`: Compiles `TtqlScriptNode` into `TtqlQueryPlan`.
* `TtqlQueryPlan`: Map of sequential stage indices to planned steps.
* `TtqlPlannedStep`: Specification of an isolated query step, target engine, projected columns, and staging table name.
* `TtqlDependencyBinding`: Foreign key link between a parent staging table column and a target step's filter field.

### Dependency Rules
* **Allowed Upstream**: `compiler/` (AST models).
* **Allowed Downstream**: Consumed by `runtime/`.

---

## 3. Runtime & Ephemeral Staging Subsystem (`lib/runtime/runtime.dart`)

### Primary Responsibility
Orchestrates end-to-end plan execution:
1. Opens a transient in-memory SQLite database (`sqlite3.openInMemory()`).
2. Dispatches staged query payloads through database connectors.
3. Ingests returned tabular rows into ephemeral staging tables via transactional batch inserts.
4. Executes the synthetic ANSI SQL join query across staging tables.
5. Deterministically closes and disposes the SQLite instance in a `finally` block to prevent memory leaks.

### Public API Contracts & Key Types
* `TtqlEngine`: Pipeline execution coordinator.
* `TtqlEphemeralStagingDatabase`: Sandbox SQLite database manager.
* `TtqlExecutionResult`: Analytical execution result containing column metadata, rows, and stage metrics.

### Dependency Rules
* **Allowed Upstream**: `planner/`, `dialects/`, `connectors/`, `package:sqlite3`.
* **Allowed Downstream**: Consumed by CLI runner (`bin/ttql.dart`) and external embedding applications.

---

## 4. Query Dialects Subsystem (`lib/dialects/dialects.dart` & `lib/services/translators/`)

### Primary Responsibility
Translates planned steps and AST filter expressions into native database query payloads using the **Strategy Pattern**:
* **SQL**: Formats ANSI/PostgreSQL/MySQL SELECT queries with proper identifier escaping (backticks vs double quotes) and parameterized WHERE clauses.
* **MongoDB**: Formats JSON MQL payloads with `$match`, `$in`, and collection targets.
* **Redis**: Formats key search patterns (`KEYS $pattern`).

### Public API Contracts & Key Types
* `QueryDialectStrategy`: Strategy interface defining `buildQuery()`.
* `SqlQueryDialect`: Concrete strategy for relational engines.
* `MongoQueryDialect`: Concrete strategy for MongoDB.
* `RedisQueryDialect`: Concrete strategy for Redis key-value stores.
* `SqlExpressionVisitor`: Dialect-aware AST expression visitor.
* `MongoExpressionVisitor`: MongoDB MQL AST expression visitor.

### Dependency Rules
* **Allowed Upstream**: `compiler/` (AST expressions), `planner/` (step models).
* **Allowed Downstream**: Consumed by `runtime/`.

---

## 5. Tooling & Presentation Subsystem (`lib/tooling/tooling.dart`)

### Primary Responsibility
Provides developer experience tooling and terminal presentation:
* **Language Server Protocol (LSP)**: Real-time JSON-RPC 2.0 language server providing sub-millisecond red-squiggly syntax and security diagnostics in IDEs (VS Code, IntelliJ, etc.).
* **Formatters**: Formats analytical result sets into clean ASCII tables, UNIX-composable JSON (`jq`), or CSV.

### Public API Contracts & Key Types
* `TtqlLspServer`: JSON-RPC 2.0 background server.
* `TtqlLinter`: Static syntax, security, and schema validator.
* `CliResultFormatter`: Pluggable output formatter interface (`TableResultFormatter`, `JsonResultFormatter`, `CsvResultFormatter`).

### Dependency Rules
* **Allowed Upstream**: `compiler/`, `runtime/`.
* **Allowed Downstream**: Terminal CLI (`bin/ttql.dart`), IDE LSP clients.
