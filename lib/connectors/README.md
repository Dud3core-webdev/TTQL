# TTQL Connectors Subsystem (`lib/connectors`)

## 1. Primary Responsibility
The **Connectors** subsystem abstracts database sockets, connection pools, and environment schemas away from the query compiler and execution runtime.

It ensures that plaintext credentials (passwords, connection strings) are never leaked into user scripts by maintaining a strictly air-gapped `TtqlEnvironmentContext` exposing only logical aliases, connection IDs, and table schema definitions.

## 2. Public API Contracts & Key Interfaces
- **`TtqlConnectionProvider`**: Abstract interface required by `TtqlEngine` to dispatch queries to database drivers:
  ```dart
  abstract class TtqlConnectionProvider {
    List<String> get activeConnectionIds;
    String? getConnectionName(String connectionId);
    DbEngineType? getEngineType(String connectionId);
    Map<String, dynamic>? getSchemaOverview(String connectionId);
    Future<List<Map<String, dynamic>>> executeQueryOnConnection(
      String connectionId,
      String query, {
      int maxRows = 500,
    });
  }
  ```
- **`CliConnectionProvider`**: Headless CLI driver provider capable of loading connection descriptors from `connections.json` and expanding OS environment variables (`${VAR_NAME}`).
- **`TtqlEnvironmentBuilder`**: Generates `TtqlEnvironmentContext` and TypeScript `.d.ts` declaration files for IDE autocompletion.
- **`TtqlEnvironmentContext`**: Air-gapped registry of active connection aliases and schema catalogs.
- **`TtqlConnectionDescriptor`**: Metadata record holding logical alias, connection ID, engine type, and available table/collection names.

## 3. Dependency Rules
- **Upstream Dependencies**: `lib/compiler/` (`DbEngineType`, `DbEngineRegistry`).
- **Downstream Dependencies**:
  - Consumed by `lib/runtime/` (`TtqlEngine`).
  - Consumed by `lib/tooling/` (`TtqlLspServer` and CLI runner).
