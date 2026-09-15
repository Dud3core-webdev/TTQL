# Contributing to TTQL (TableTalk Query Language)

Thank you for your interest in contributing to **TTQL**! We welcome bug reports, feature proposals, language dialect visitors, and compiler enhancements from the open-source community.

---

## 🛠️ Development Setup

### Prerequisites
- [Dart SDK](https://dart.dev/get-dart) `>=3.0.0 <4.0.0`
- Git

### Initializing the Workspace
```bash
git clone https://github.com/tabletalk-io/ttql.git
cd ttql
dart pub get
```

---

## 🔬 Testing & Static Analysis

Before submitting a Pull Request, ensure that all tests pass cleanly and there are zero static analysis warnings:

```bash
# Run static analyzer
dart analyze

# Run unit and integration tests
dart test
```

---

## 🏛️ Compiler Invariants & Architecture Rules

When contributing code to `package:ttql`, please adhere to the following core engineering invariants:

1. **Strict Physical Separation of Types vs. Logic**:
   - Do NOT declare AST nodes, interfaces, or DTOs in the same file as business logic services or engine orchestrators.
   - All AST models belong in `lib/models/`. Services belong in `lib/services/`.

2. **100% Read-Only Safety**:
   - TTQL is strictly a read-only query language.
   - Any new token or keyword introduced into `ttql_lexer.dart` must check against `TtqlConstants.forbiddenMutationKeywords` to prevent accidental execution of data modification queries (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, etc.).

3. **Concurrency Throttling ($\le 3$ Queries per Batch)**:
   - Modifications to `ttql_dag_planner.dart` must respect `TtqlConstants.maxConcurrentQueriesPerBatch` (3). Batches of queries dispatched across remote database connections must be chunked to avoid socket exhaustion.

4. **Zero-UI & Portable Dependencies**:
   - `package:ttql` must remain a zero-UI, pure Dart package.
   - Do NOT import `package:flutter` or desktop UI packages into `packages/ttql/lib/`.

---

## 🔀 Submitting a Pull Request

1. **Fork & Branch**: Create a feature branch off `main` (e.g., `git checkout -b feature/redis-hash-translator`).
2. **Commit Hygiene**: Use clear, concise commit messages.
3. **Tests**: Add unit test coverage in `test/` for any new parser rule or execution step.
4. **Pull Request**: Open a PR against `tabletalk-io/ttql` with a summary of changes and test evidence.

Thank you for making TTQL the best open-source federated query engine!
