import 'package:ttql/models/db_engine_type.dart';

/// Abstract connection descriptor injected into the TTQL script environment.
/// Exposes safe metadata and table schemas, strictly excluding credentials or passwords.
class TtqlConnectionDescriptor {
  final String id;
  final String alias;
  final DbEngineType engineType;
  final List<String> tableNames;

  const TtqlConnectionDescriptor({
    required this.id,
    required this.alias,
    required this.engineType,
    required this.tableNames,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'alias': alias,
      'engineType': engineType.name,
      'tableNames': tableNames,
    };
  }
}
