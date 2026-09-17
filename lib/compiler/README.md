# TTQL Compiler Subsystem (`lib/compiler`)

## 1. Primary Responsibility
The **Compiler** subsystem represents the language frontend. It parses raw TableTalk Query Language (TTQL) script text into an immutable Abstract Syntax Tree (AST), validates syntax rules, resolves constants and spread operators (`...`), enforces read-only security invariants, and maps engine tokens to canonical database types via `DbEngineRegistry`.

Mutating SQL operations (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `FLUSHALL`) are strictly rejected during token scanning.

## 2. Public API Contracts & Key Interfaces
- **`TtqlLexer`**: Tokenizes source text into `TtqlToken` instances; throws `TtqlSecurityException` on any mutation keyword.
- **`TtqlParser`**: Recursive descent parser enforcing the modern fluent pipeline starting with `from(...)` (`.select()`, `.where()`, `.innerJoin(..., on: ...)`, `.groupBy()`, `.having()`, `.orderBy()`, `.limit()`, `.offset()`).
- **`DbEngineRegistry`**: Canonical $O(1)$ engine resolver mapping engine names and aliases to `DbEngineType`.
- **AST Nodes**:
  - `TtqlScriptNode`: Root AST node holding declared constants, connection aliases, root query invocations, joins, projections, groupBy, having, orderBys, offset, and limit.
  - `TtqlQueryInvocationNode`: Target database query specification.
  - `TtqlJoinNode`: Relational join specification (`innerJoin`, `leftJoin`, `rightJoin`, `fullOuterJoin`).
  - `TtqlWherePredicateNode`: Filter condition node holding an immutable `TtqlExpression` root tree.
  - `TtqlExpression`: Composite boolean/relational expressions (`TtqlBinaryLogicalExpression`, `TtqlUnaryLogicalExpression`, `TtqlComparisonExpression`, `TtqlGroupExpression`).

## 3. Dependency Rules
- **Upstream Dependencies**: Dart Core SDK only. Zero third-party packages.
- **Downstream Dependencies**:
  - Consumed by `lib/planner/` to generate Directed Acyclic Graph (DAG) query plans.
  - Consumed by `lib/tooling/` for static lint diagnostics and real-time LSP analysis.
