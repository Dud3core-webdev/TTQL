# TTQL Planner Subsystem (`lib/planner`)

## 1. Primary Responsibility
The **Planner** subsystem represents the compiler's middle-end. It compiles an immutable `TtqlScriptNode` AST into an executable Directed Acyclic Graph (DAG) query plan (`TtqlQueryPlan`). 

Key planning responsibilities:
1. **Concurrency Throttling**: Batches independent root queries into stages of at most 3 concurrent isolate queries (`TtqlConstants.maxConcurrentQueriesPerBatch = 3`).
2. **Join Dependency Extraction**: Dissects compound AST `WHERE` predicates to separate local database filter predicates from cross-database foreign key dependency bindings.
3. **Staging Namespace Allocation**: Allocates deterministic staging table names (`ttql_stage_0_<table>`).

## 2. Public API Contracts & Key Interfaces
- **`TtqlDagPlanner`**: Core compiler class transforming `TtqlScriptNode` into `TtqlQueryPlan`.
- **`TtqlQueryPlan`**: Immutable execution schedule mapping sequential stage indices to lists of `TtqlPlannedStep`.
- **`TtqlPlannedStep`**: Specification of an isolated query step containing connection ID, engine type, target collection/table, projected columns, staging table, and foreign key bindings.
- **`TtqlDependencyBinding`**: Foreign key link declaring a dependency between a parent staging table column and a target step's filter parameter.

## 3. Dependency Rules
- **Upstream Dependencies**: `lib/compiler/` (consumes AST models and constants).
- **Downstream Dependencies**:
  - Consumed by `lib/runtime/` to execute the staged pipeline.
  - Consumed by CLI runner (`bin/ttql.dart plan`) to output dry-run DAG plans.
