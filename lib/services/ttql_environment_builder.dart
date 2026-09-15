import 'package:ttql/models/ttql_connection_descriptor.dart';
import 'package:ttql/models/ttql_environment_context.dart';
import 'package:ttql/services/ttql_connection_provider.dart';

/// Builds a strictly airgapped [TtqlEnvironmentContext] exposing only connection IDs
/// and table schema metadata, guaranteeing that plaintext credentials never leak into scripts.
class TtqlEnvironmentBuilder {
  final TtqlConnectionProvider connectionProvider;

  TtqlEnvironmentBuilder({
    TtqlConnectionProvider? connectionProvider,
    TtqlConnectionProvider? poolManager,
  }) : connectionProvider = (connectionProvider ?? poolManager)!;

  /// Constructs the environment context from active connections in the pool,
  /// optionally scoped to a subset of allowed connection IDs.
  TtqlEnvironmentContext buildContext({Set<String>? allowedConnectionIds}) {
    final Map<String, TtqlConnectionDescriptor> connections = {};

    for (final connId in connectionProvider.activeConnectionIds) {
      if (allowedConnectionIds != null && !allowedConnectionIds.contains(connId)) {
        continue;
      }
      final engineType = connectionProvider.getEngineType(connId);
      final schemaOverview = connectionProvider.getSchemaOverview(connId);
      if (engineType == null || schemaOverview == null) continue;

      final tableNames = schemaOverview.keys.toList();
      final connName = connectionProvider.getConnectionName(connId);
      String safeAlias;
      String? altAlias;
      if (connName != null && connName.trim().isNotEmpty) {
        final snakeName = connName
            .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}');
        safeAlias = snakeName
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
            .replaceAll(RegExp(r'_+'), '_')
            .replaceAll(RegExp(r'^_+|_+$'), '');
        if (safeAlias.isEmpty || RegExp(r'^[0-9]').hasMatch(safeAlias)) {
          safeAlias = 'db_$safeAlias';
        }

        final plainAlias = connName
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
            .replaceAll(RegExp(r'_+'), '_')
            .replaceAll(RegExp(r'^_+|_+$'), '');
        if (plainAlias.isNotEmpty && plainAlias != safeAlias) {
          altAlias = RegExp(r'^[0-9]').hasMatch(plainAlias) ? 'db_$plainAlias' : plainAlias;
        }
      } else {
        safeAlias = connId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
        if (safeAlias.isEmpty || RegExp(r'^[0-9]').hasMatch(safeAlias)) {
          safeAlias = 'db_$safeAlias';
        }
      }

      final descriptor = TtqlConnectionDescriptor(
        id: connId,
        alias: safeAlias,
        engineType: engineType,
        tableNames: tableNames,
      );

      connections[safeAlias] = descriptor;
      if (altAlias != null) {
        connections[altAlias] = descriptor;
      }

      final rawIdAlias = RegExp(r'^[0-9]').hasMatch(connId) ? 'db_$connId' : connId;
      if (rawIdAlias != safeAlias && rawIdAlias != altAlias) {
        connections[rawIdAlias] = descriptor;
      }
    }

    return TtqlEnvironmentContext(connections: connections);
  }

  /// Generates TypeScript `.d.ts` schema definitions for code editor IntelliSense.
  String generateTypeDeclarations(TtqlEnvironmentContext context) {
    final buffer = StringBuffer();
    buffer.writeln('// Auto-generated TTQL Environment Intellisense');
    buffer.writeln('declare const environment: {');
    buffer.writeln('  connections: {');

    context.connections.forEach((alias, descriptor) {
      buffer.writeln('    $alias: {');
      buffer.writeln('      id: "${descriptor.id}",');
      buffer.writeln('      tables: {');
      for (final table in descriptor.tableNames) {
        buffer.writeln('        "$table": "$table",');
      }
      buffer.writeln('      }');
      buffer.writeln('    },');
    });

    buffer.writeln('  }');
    buffer.writeln('};');
    buffer.writeln('');
    buffer.writeln('declare function select(closure: () => void): {');
    buffer.writeln('  InnerJoin(closure: (entity: any) => void): any;');
    buffer.writeln('  LeftJoin(closure: (entity: any) => void): any;');
    buffer.writeln('};');
    buffer.writeln('declare function declare(expression: any): any;');
    buffer.writeln('declare function asyncRun(closure: () => void): any;');
    buffer.writeln('declare function PostgreSql(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function MySql(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function MongoDb(connId: string, collection: string): any;');
    buffer.writeln('declare function Mongo(connId: string, columns: string[], collection: string): any;');
    buffer.writeln('declare function Sqlite(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function Redis(connId: string, keyPattern: string): any;');
    buffer.writeln('declare function DuckDb(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function MsSql(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function ClickHouse(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function PlanetScale(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function CockroachDb(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function YugabyteDb(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function Oracle(connId: string, columns: string[], table: string): any;');
    buffer.writeln('declare function Cassandra(connId: string, columns: string[], table: string): any;');

    return buffer.toString();
  }
}
