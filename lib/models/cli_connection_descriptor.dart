import 'package:ttql/models/db_engine_type.dart';

/// Immutable descriptor for connection metadata registered in [CliConnectionProvider].
class CliConnectionDescriptor {
  final String id;
  final String name;
  final DbEngineType engineType;
  final String connectionString;
  final Map<String, dynamic> schemaOverview;

  const CliConnectionDescriptor({
    required this.id,
    required this.name,
    required this.engineType,
    required this.connectionString,
    required this.schemaOverview,
  });
}
