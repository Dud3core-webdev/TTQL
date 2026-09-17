# Contributing to TTQL

Thank you for contributing to TTQL. We welcome issues, documentation improvements, and pull requests.

---

## Development Setup

### Prerequisites

- [Dart SDK](https://dart.dev/get-dart) `>=3.0.0 <4.0.0`
- Git

### Setup

```bash
git clone https://github.com/tabletalk-io/ttql.git
cd ttql
dart pub get
```

---

## Testing & Static Analysis

Ensure that the static analyzer reports no issues and all tests pass before submitting changes:

```bash
# Static analysis
dart analyze

# Unit and integration tests
dart test
```

---

## Architectural Guidelines

When submitting code to `ttql`, adhere to the following project conventions:

1. **Separation of Models and Services**:
   - Keep AST nodes, configuration classes, and data structures in `lib/models/`.
   - Place engine orchestration, lexical scanning, parsing, and execution logic in `lib/services/`.

2. **Read-Only Invariant**:
   - TTQL is strictly a read-only query language.
   - Any new syntax or keyword additions in `ttql_lexer.dart` must respect `TtqlConstants.forbiddenMutationKeywords` to reject data modification operations (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, etc.).

3. **Concurrency Throttling**:
   - Changes to the planner (`ttql_dag_planner.dart`) must honor `TtqlConstants.maxConcurrentQueriesPerBatch` (default: 3) to prevent connection pool exhaustion across remote engines.

4. **Zero UI Dependencies**:
   - `ttql` is a pure Dart package with no Flutter or GUI framework dependencies.

---

## Pull Request Guidelines

1. **Branching**: Create a feature branch off `main` (`git checkout -b feature/my-feature`).
2. **Tests**: Add corresponding unit tests in `test/` for new parser rules, planner logic, or CLI features.
3. **Commit Messages**: Write clear, descriptive commit messages.
4. **Pull Request**: Open a pull request against `tabletalk-io/ttql` explaining the changes and how they were tested.
