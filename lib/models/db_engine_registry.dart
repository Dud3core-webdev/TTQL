import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_exceptions.dart';

/// Centralized registry for resolving canonical database engine identifiers,
/// connection scheme prefixes, and aliases with zero fuzzy-matching ambiguity.
class DbEngineRegistry {
  static const Map<String, DbEngineType> _canonicalMap = {
    // Relational SQL Engines
    'postgresql': DbEngineType.postgres,
    'postgres': DbEngineType.postgres,
    'pgsql': DbEngineType.postgres,
    'mysql': DbEngineType.mysql,
    'mariadb': DbEngineType.mysql,
    'sqlite': DbEngineType.sqlite,
    'sqlite3': DbEngineType.sqlite,
    'duckdb': DbEngineType.duckdb,
    'mssql': DbEngineType.mssql,
    'sqlserver': DbEngineType.mssql,
    'clickhouse': DbEngineType.clickhouse,
    'planetscale': DbEngineType.planetscale,
    'cockroachdb': DbEngineType.cockroachdb,
    'cockroach': DbEngineType.cockroachdb,
    'yugabytedb': DbEngineType.yugabytedb,
    'yugabyte': DbEngineType.yugabytedb,
    'oracle': DbEngineType.oracle,

    // Document, NoSQL & Cache
    'mongodb': DbEngineType.mongodb,
    'mongo': DbEngineType.mongodb,
    'redis': DbEngineType.redis,
    'cassandra': DbEngineType.cassandra,
    'scylla': DbEngineType.cassandra,
    'scylladb': DbEngineType.cassandra,
  };

  /// Returns true if [name] matches a recognized engine identifier or alias.
  static bool isEngine(String name) {
    return _canonicalMap.containsKey(name.trim().toLowerCase());
  }

  /// Resolves an engine identifier or alias to its [DbEngineType].
  /// Throws [TtqlParseException] if the identifier is unknown.
  static DbEngineType resolve(String name) {
    final clean = name.trim().toLowerCase();
    final engine = _canonicalMap[clean];
    if (engine == null) {
      throw TtqlParseException(
        'Unknown database engine identifier "$name". Supported engines: ${_canonicalMap.keys.toSet().join(", ")}',
      );
    }
    return engine;
  }

  /// Attempts to resolve an engine identifier, returning null if unrecognized.
  static DbEngineType? tryResolve(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    return _canonicalMap[name.trim().toLowerCase()];
  }
}
