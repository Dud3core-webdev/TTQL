import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:ttql/models/cli_connection_descriptor.dart';
import 'package:ttql/models/db_engine_registry.dart';
import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/services/ttql_connection_provider.dart';

/// Optional live query executor delegate for custom transport drivers in CLI mode.
typedef CliLiveQueryExecutor = Future<List<Map<String, dynamic>>> Function(
  CliConnectionDescriptor descriptor,
  String query,
  int maxRows,
);

/// Dynamic connection provider for headless CLI execution and standalone automation pipelines.
/// Supports parsing local JSON config files, expanding environment variables (`${VAR_NAME}`),
/// executing native read-only queries against local SQLite files and ClickHouse HTTP endpoints,
/// or delegating to an injected [liveQueryExecutor].
class CliConnectionProvider implements TtqlConnectionProvider {
  final Map<String, CliConnectionDescriptor> _descriptors = {};
  final Map<String, List<Map<String, dynamic>>> _mockDataStore = {};
  final CliLiveQueryExecutor? liveQueryExecutor;

  CliConnectionProvider({this.liveQueryExecutor});

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

  /// Retrieves the registered [CliConnectionDescriptor] for [connectionId].
  CliConnectionDescriptor? getDescriptor(String connectionId) => _descriptors[connectionId];

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
      throw TtqlExecutionException('CLI Driver: Unregistered connection ID "$connectionId".');
    }

    if (_mockDataStore.containsKey(connectionId)) {
      final rows = _mockDataStore[connectionId]!;
      return rows.take(maxRows).toList();
    }

    if (liveQueryExecutor != null) {
      return await liveQueryExecutor!(desc, query, maxRows);
    }

    if (desc.engineType == DbEngineType.sqlite || desc.engineType == DbEngineType.duckdb) {
      return _executeLocalSqliteQuery(desc, query, maxRows);
    }

    if (desc.engineType == DbEngineType.clickhouse) {
      return await _executeClickHouseHttpQuery(desc, query, maxRows);
    }

    throw TtqlExecutionException(
      'CLI Driver: Live socket execution for engine "${desc.engineType.name}" '
      'on connection "$connectionId" requires either "mockData" in connections.json, '
      'a local SQLite/ClickHouse endpoint, or an injected liveQueryExecutor.',
    );
  }

  List<Map<String, dynamic>> _executeLocalSqliteQuery(
    CliConnectionDescriptor desc,
    String sql,
    int maxRows,
  ) {
    final path = desc.connectionString.trim();
    if (path.isEmpty || path == ':memory:') {
      throw TtqlExecutionException(
        'CLI Driver: Connection "${desc.id}" specifies ":memory:" without "mockData".',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw TtqlExecutionException(
        'CLI Driver: Local database file not found at "$path" for connection "${desc.id}".',
      );
    }

    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      String finalSql = sql.trim();
      if (finalSql.endsWith(';')) {
        finalSql = finalSql.substring(0, finalSql.length - 1);
      }
      final resultSet = db.select(finalSql);
      final List<Map<String, dynamic>> rows = [];
      for (final row in resultSet) {
        final map = <String, dynamic>{};
        for (final col in resultSet.columnNames) {
          map[col] = row[col];
        }
        rows.add(map);
        if (rows.length >= maxRows) break;
      }
      return rows;
    } finally {
      db.dispose();
    }
  }

  Future<List<Map<String, dynamic>>> _executeClickHouseHttpQuery(
    CliConnectionDescriptor desc,
    String sql,
    int maxRows,
  ) async {
    var rawUri = desc.connectionString.trim();
    if (rawUri.startsWith('clickhouse://')) {
      rawUri = 'http://${rawUri.substring('clickhouse://'.length)}';
    } else if (!rawUri.contains('://')) {
      rawUri = 'http://$rawUri';
    }
    final parsed = Uri.parse(rawUri);
    final dbName = parsed.pathSegments.isNotEmpty && parsed.pathSegments.first.isNotEmpty
        ? parsed.pathSegments.first
        : 'default';
    String user = 'default';
    String password = '';
    if (parsed.userInfo.isNotEmpty) {
      final parts = parsed.userInfo.split(':');
      user = Uri.decodeComponent(parts[0]);
      if (parts.length > 1) {
        password = Uri.decodeComponent(parts.sublist(1).join(':'));
      }
    }

    final endpoint = Uri(
      scheme: parsed.scheme == 'https' ? 'https' : 'http',
      host: parsed.host.isNotEmpty ? parsed.host : 'localhost',
      port: parsed.hasPort ? parsed.port : 8123,
      path: '/',
      queryParameters: {
        'database': dbName,
        'default_format': 'JSON',
      },
    );

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(endpoint);
      req.headers.set('X-ClickHouse-User', user);
      if (password.isNotEmpty) {
        req.headers.set('X-ClickHouse-Key', password);
      }
      String cleanSql = sql.trim();
      if (cleanSql.endsWith(';')) {
        cleanSql = cleanSql.substring(0, cleanSql.length - 1);
      }
      req.write(cleanSql);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw TtqlExecutionException('ClickHouse HTTP ${resp.statusCode}: $body');
      }
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['data'] is List) {
        return (decoded['data'] as List)
            .take(maxRows)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      return [];
    } finally {
      client.close(force: true);
    }
  }
}
