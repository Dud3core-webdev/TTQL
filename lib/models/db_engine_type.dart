/// Supported database engine types in TTQL queries and drivers.
enum DbEngineType {
  sqlite(id: 1, name: 'SQLite', hint: 'C:\\path\\to\\database.sqlite', defaultPort: null),
  postgres(id: 2, name: 'PostgreSQL', hint: 'postgres://user:password@localhost:5432/dbname', defaultPort: 5432),
  mysql(id: 3, name: 'MySQL', hint: 'mysql://user:password@localhost:3306/dbname', defaultPort: 3306),
  mongodb(id: 4, name: 'MongoDB', hint: 'mongodb://user:password@localhost:27017/dbname', defaultPort: 27017),
  redis(id: 5, name: 'Redis', hint: 'redis://:password@localhost:6379/0', defaultPort: 6379),
  duckdb(id: 6, name: 'DuckDB', hint: 'C:\\path\\to\\analytics.duckdb or :memory:', defaultPort: null),
  mssql(id: 7, name: 'Microsoft SQL Server', hint: 'mssql://user:password@localhost:1433/dbname', defaultPort: 1433),
  clickhouse(id: 8, name: 'ClickHouse', hint: 'http://user:password@localhost:8123/dbname', defaultPort: 8123),
  planetscale(id: 9, name: 'PlanetScale', hint: 'mysql://user:password@aws.connect.psdb.cloud/dbname', defaultPort: 3306),
  cockroachdb(id: 10, name: 'CockroachDB', hint: 'postgresql://user:password@localhost:26257/dbname', defaultPort: 26257),
  yugabytedb(id: 11, name: 'YugabyteDB', hint: 'postgresql://user:password@localhost:5433/dbname', defaultPort: 5433),
  oracle(id: 12, name: 'Oracle Database', hint: 'oracle://user:password@localhost:1521/XEPDB1', defaultPort: 1521),
  cassandra(id: 13, name: 'Cassandra / ScyllaDB', hint: 'cassandra://user:password@localhost:9042/keyspace', defaultPort: 9042);

  final int id;
  final String name;
  final String hint;
  final int? defaultPort;

  const DbEngineType({
    required this.id,
    required this.name,
    required this.hint,
    this.defaultPort,
  });

  /// True if engine is a networked server supporting multi-database/keyspace/logical-DB discovery.
  bool get supportsServerPoolDiscovery {
    return this != DbEngineType.sqlite && this != DbEngineType.duckdb;
  }

  /// Map an integer ID back to the matching [DbEngineType].
  static DbEngineType fromId(int id) {
    return DbEngineType.values.firstWhere(
      (e) => e.id == id,
      orElse: () => DbEngineType.sqlite,
    );
  }

  /// Attempts to infer [DbEngineType] from a connection string URI scheme or file path extension.
  static DbEngineType? fromConnectionString(String connStr) {
    final trimmed = connStr.trim().toLowerCase();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('planetscale://') || trimmed.contains('.psdb.cloud') || trimmed.contains('planetscale')) return DbEngineType.planetscale;
    if (trimmed.startsWith('cockroach://') || trimmed.startsWith('cockroachdb://') || trimmed.contains('cockroach') || trimmed.contains(':26257')) return DbEngineType.cockroachdb;
    if (trimmed.startsWith('yugabyte://') || trimmed.startsWith('yugabytedb://') || trimmed.contains('yugabyte') || trimmed.contains(':5435')) return DbEngineType.yugabytedb;

    if (trimmed.startsWith('postgres://') || trimmed.startsWith('postgresql://')) return DbEngineType.postgres;
    if (trimmed.startsWith('mysql://') || trimmed.startsWith('mariadb://')) return DbEngineType.mysql;
    if (trimmed.startsWith('mongodb://') || trimmed.startsWith('mongodb+srv://')) return DbEngineType.mongodb;
    if (trimmed.startsWith('redis://') || trimmed.startsWith('rediss://')) return DbEngineType.redis;
    if (trimmed.startsWith('duckdb://') || trimmed.endsWith('.duckdb')) return DbEngineType.duckdb;
    if (trimmed.startsWith('mssql://') || trimmed.startsWith('sqlserver://')) return DbEngineType.mssql;
    if (trimmed.startsWith('clickhouse://')) return DbEngineType.clickhouse;
    if (trimmed.startsWith('oracle://')) return DbEngineType.oracle;
    if (trimmed.startsWith('cassandra://') || trimmed.startsWith('scylla://')) return DbEngineType.cassandra;
    if (trimmed.endsWith('.db') || trimmed.endsWith('.sqlite') || trimmed.endsWith('.sqlite3') || trimmed.endsWith('.db3')) return DbEngineType.sqlite;
    return null;
  }
}
