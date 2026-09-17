# TTQL Tooling & Presentation Subsystem (`lib/tooling`)

## 1. Primary Responsibility
The **Tooling** subsystem provides developer experience (DX) tooling:
1. **Language Server Protocol (LSP)**: Real-time JSON-RPC 2.0 language server providing sub-millisecond red-squiggly syntax and security diagnostics in IDE editors (VS Code, IntelliJ, etc.).
2. **Static Linter**: Validates TTQL scripts for syntax errors, mutation keyword violations, and unknown schema entities without executing queries.
3. **Result Formatters**: Pretty-prints analytical execution results into clean ASCII tables, UNIX-composable JSON (`jq`), or CSV.

## 2. Public API Contracts & Key Interfaces
- **`TtqlLspServer`**: Native JSON-RPC 2.0 language server implementation.
- **`JsonRpcTransport`**: Wire-level byte framing handling `Content-Length` headers and stream chunking.
- **`LspDocumentStore`**: In-memory synchronized text buffer of active open documents in the editor.
- **`TtqlLinter`**: Static analyzer returning `List<TtqlDiagnostic>`.
- **`CliResultFormatter`**: Abstract output formatter with factory method `forType(String format)`:
  - `TableResultFormatter`: Renders tabular ASCII grid with headers and row counts.
  - `JsonResultFormatter`: Renders indented JSON arrays.
  - `CsvResultFormatter`: Renders standard comma-separated values with quote escaping.

## 3. Dependency Rules
- **Upstream Dependencies**:
  - `lib/compiler/` (`TtqlLexer`, `TtqlParser`, AST models, `TtqlDiagnostic`).
  - `lib/connectors/` (`TtqlEnvironmentContext` for schema entity verification).
- **Downstream Dependencies**:
  - Consumed by CLI executable (`bin/ttql.dart`).
  - Consumed by external IDE LSP clients.
