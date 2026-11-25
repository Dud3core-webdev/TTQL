# TTQL Compiler & Ecosystem Rules

## Architectural Boundaries
- **Read Before Refactoring:** Before changing compiler stages or cross-module imports, read `doc/wiki/02_pipeline_architecture.md` and `doc/wiki/05_architectural_boundaries.md`.
- **Modular Barrels:** Respect the layer boundaries (`lib/compiler/`, `lib/planner/`, `lib/dialects/`, `lib/connectors/`, `lib/runtime/`, `lib/tooling/`). Export public APIs through their respective barrel files and `lib/ttql.dart`.
- **Surgical Parser Edits:** `lib/services/ttql_parser.dart` (~64KB) is large and complex. Make minimal, targeted edits—never rewrite entire parsing blocks or reorder unrelated grammar rules.

## Syntax & Dialect Parity Checklist
Whenever you add or modify a TTQL keyword, operator, or AST node (`lib/models/ttql_*.dart`), verify whether these also need updating:
1. `lib/constants/ttql_constants.dart` and `lib/services/ttql_lexer.dart`
2. All dialect translators in `lib/services/translators/` (`sql_query_dialect.dart`, `mongo_query_dialect.dart`, `redis_query_dialect.dart` and their expression visitors)
3. `lib/services/ttql_linter.dart` and `lib/services/ttql_lsp_server.dart`
4. `editors/vscode/syntaxes/ttql.tmLanguage.json` (VS Code syntax highlighting)
5. `doc/SYNTAX_GUIDE.md` and `doc/TTQL_LANGUAGE_MANUAL.md`

## Verification Loop
- After any compiler, planner, or dialect change, run `dart analyze` and `dart test`.
- Specifically verify `test/fluent_pipeline_test.dart` and `test/query_dialect_strategy_test.dart` pass before finishing.
- After modifying `pubspec.yaml`, `README.md`, or `CHANGELOG.md`, run `dart pub publish --dry-run` to ensure zero pub.dev warnings.