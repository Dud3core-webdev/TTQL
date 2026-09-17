import 'dart:convert';
import 'dart:io';
import 'package:ttql/models/db_engine_registry.dart';
import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/services/ttql_connection_provider.dart';

/// Descriptor for connection metadata registered in [CliConnectionProvider].
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

/// Dynamic connection provider for headless CLI execution and standalone automation pipelines.
/// Supports parsing local JSON config files and expanding environment variables (`${VAR_NAME}`).
class CliConnectionProvider implements TtqlConnectionProvider {
  final Map<String, CliConnectionDescriptor> _descriptors = {};
  final Map<String, List<Map<String, dynamic>>> _mockDataStore = {};

  CliConnectionProvider();

  /// Expands environment variables in the format `${VAR_NAME}` using current OS environment bindings.
  static String expandEnvVars(String input) {
    final pattern = RegExp(r'\$\{([a-zA-Z0-9_]+)\}');
    return input.replaceAllMapped(pattern, (match) {
      final varName = match.group(1)!;
      return Platform.environment[varName] ?? '';
    });
  }

  /// Manually registers a database connection descriptor.
  void registerConnection({
    required String id,
    required String name,
    required DbEngineType engineType,
    required String connectionString,
    required Map<String, dynamic> schemaOverview,
    List<Map<String, dynamic>>? mockData,
  }) {
    final expandedConnStr = expandEnvVars(connectionString);
    _descriptors[id] = CliConnectionDescriptor(
      id: id,
      name: name,
      engineType: engineType,
      connectionString: expandedConnStr,
      schemaOverview: schemaOverview,
    );
    if (mockData != null) {
      _mockDataStore[id] = mockData;
    }
  }

  /// Loads connections from a JSON string representation.
  void loadFromJsonString(String jsonContent) {
    final Map<String, dynamic> decoded = jsonDecode(jsonContent);
    final List<dynamic> conns = decoded['connections'] ?? [];
    for (final conn in conns) {
      if (conn is Map<String, dynamic>) {
        final id = conn['id']?.toString() ?? '';
        final name = conn['name']?.toString() ?? id;
        final engineRaw = conn['engine']?.toString() ?? 'sqlite';
        final rawConnStr = conn['connectionString']?.toString() ?? '';
        final connStr = expandEnvVars(rawConnStr);
        final schema = conn['schemaOverview'] is Map<String, dynamic>
            ? conn['schemaOverview'] as Map<String, dynamic>
            : <String, dynamic>{};
        final List<Map<String, dynamic>>? mockData = conn['mockData'] is List
            ? (conn['mockData'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : null;

        final DbEngineType engineType = DbEngineRegistry.tryResolve(engineRaw) ?? DbEngineType.sqlite;

        _descriptors[id] = CliConnectionDescriptor(
          id: id,
          name: name,
          engineType: engineType,
          connectionString: connStr,
          schemaOverview: schema,
        );

        if (mockData != null) {
          _mockDataStore[id] = mockData;
        }
      }
    }
  }

  /// Loads database connections from a file path.
  void loadFromConfigFile(File configFile) {
    if (!configFile.existsSync()) {
      throw FileSystemException('CLI Driver: Configuration file not found', configFile.path);
    }
    loadFromJsonString(configFile.readAsStringSync());
  }

  @override
  List<String> get activeConnectionIds => _descriptors.keys.toList();

  @override
  String? getConnectionName(String connectionId) => _descriptors[connectionId]?.name;

  @override
  DbEngineType? getEngineType(String connectionId) => _descriptors[connectionId]?.engineType;

  @override
  Map<String, dynamic>? getSchemaOverview(String connectionId) => _descriptors[connectionId]?.schemaOverview;

  @override
  Future<List<Map<String, dynamic>>> executeQueryOnConnection(
    String connectionId,
    String query, {
    int maxRows = 500,
  }) async {
    final desc = _descriptors[connectionId];
    if (desc == null) {
      throw Exception('CLI Driver: Unregistered connection ID "$connectionId".');
    }

    if (_mockDataStore.containsKey(connectionId)) {
      final rows = _mockDataStore[connectionId]!;
      return rows.take(maxRows).toList();
    }

    return [
      {'status': 'executed', 'connectionId': connectionId, 'query': query}
    ];
  }
}
