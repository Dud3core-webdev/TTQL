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

      final Map<String, List<String>> tableColumns = {};
      for (final entry in schemaOverview.entries) {
        if (entry.value is List) {
          tableColumns[entry.key] = (entry.value as List).map((e) => e.toString()).toList();
        }
      }

      final descriptor = TtqlConnectionDescriptor(
        id: connId,
        alias: safeAlias,
        engineType: engineType,
        tableNames: tableNames,
        tableColumns: tableColumns,
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
    buffer.writeln('// Projection macros: use  declare function name(param) { return { ... }; }');
    buffer.writeln('// before from() to define reusable, inlined select() bodies.');
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
    buffer.writeln('interface TtqlPipeline {');
    buffer.writeln('  as(alias: string): TtqlPipeline;');
    buffer.writeln('  select(...columns: any[]): TtqlPipeline;');
    buffer.writeln('  where(predicate: any): TtqlPipeline;');
    buffer.writeln('  innerJoin(target: any, options?: { on?: any }): TtqlPipeline;');
    buffer.writeln('  leftJoin(target: any, options?: { on?: any }): TtqlPipeline;');
    buffer.writeln('  rightJoin(target: any, options?: { on?: any }): TtqlPipeline;');
    buffer.writeln('  fullOuterJoin(target: any, options?: { on?: any }): TtqlPipeline;');
    buffer.writeln('  groupBy(...columns: any[]): TtqlPipeline;');
    buffer.writeln('  having(predicate: any): TtqlPipeline;');
    buffer.writeln('  orderBy(...columnsOrDirections: any[]): TtqlPipeline;');
    buffer.writeln('  limit(count: number): TtqlPipeline;');
    buffer.writeln('  offset(count: number): TtqlPipeline;');
    buffer.writeln('  skip(count: number): TtqlPipeline;');
    buffer.writeln('}');
    buffer.writeln('');
    buffer.writeln('declare function from(dataSource: any): TtqlPipeline;');
    buffer.writeln('declare function count(column?: any): any;');
    buffer.writeln('declare function sum(column: any): any;');
    buffer.writeln('declare function avg(column: any): any;');
    buffer.writeln('declare function min(column: any): any;');
    buffer.writeln('declare function max(column: any): any;');

    return buffer.toString();
  }
}
