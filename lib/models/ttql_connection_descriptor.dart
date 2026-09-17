import 'package:ttql/models/db_engine_type.dart';

/// Abstract connection descriptor injected into the TTQL script environment.
/// Exposes safe metadata and table schemas, strictly excluding credentials or passwords.
class TtqlConnectionDescriptor {
  final String id;
  final String alias;
  final DbEngineType engineType;
  final List<String> tableNames;
  final Map<String, List<String>> tableColumns;

  const TtqlConnectionDescriptor({
    required this.id,
    required this.alias,
    required this.engineType,
    required this.tableNames,
    this.tableColumns = const {},
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'alias': alias,
      'engineType': engineType.name,
      'tableNames': tableNames,
      if (tableColumns.isNotEmpty) 'tableColumns': tableColumns,
    };
  }
}
