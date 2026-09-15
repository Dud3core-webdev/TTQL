import 'package:ttql/models/db_engine_type.dart';

/// Abstract contract for executing queries on database connections within the pool.
/// Decouples the TTQL parsing and execution engine from desktop UI adapters and credential vaults.
abstract class TtqlConnectionProvider {
  /// Active connection IDs attached in the pool.
  List<String> get activeConnectionIds;

  /// Retrieves optional display name for a connection ID.
  String? getConnectionName(String connectionId);

  /// Retrieves the database engine type for a connection ID.
  DbEngineType? getEngineType(String connectionId);

  /// Retrieves the schema overview (table/collection names and structures) for a connection ID.
  Map<String, dynamic>? getSchemaOverview(String connectionId);

  /// Executes an isolated query payload on the specified target connection ID.
  Future<List<Map<String, dynamic>>> executeQueryOnConnection(
    String connectionId,
    String query, {
    int maxRows = 500,
  });
}
