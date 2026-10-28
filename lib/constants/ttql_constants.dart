/// Centralized constants for TableTalk Query Language (TTQL).
/// Defines limits, keywords, staging identifiers, and forbidden tokens.
class TtqlConstants {
  /// Strict limit on concurrent queries per execution batch.
  /// Any surplus queries are automatically throttled into sequential FIFO stages.
  static const int maxConcurrentQueriesPerBatch = 3;

  /// Prefix for ephemeral SQLite staging tables.
  static const String stagingTablePrefix = 'ttql_stage_';

  /// SQLite in-memory connection specifier.
  static const String sqliteMemoryPath = ':memory:';

  /// TTQL Language Keywords.
  static const String keywordFrom = 'from';
  static const String keywordOn = 'on';
  static const String keywordJoin = 'join';
  static const String keywordSelect = 'select';
  static const String keywordWhere = 'where';
  static const String keywordInnerJoin = 'innerJoin';
  static const String keywordLeftJoin = 'leftJoin';
  static const String keywordRightJoin = 'rightJoin';
  static const String keywordFullOuterJoin = 'fullOuterJoin';
  static const String keywordConst = 'const';
  static const String keywordIs = 'is';
  static const String keywordAnd = 'AND';
  static const String keywordOr = 'OR';
  static const String keywordNot = 'NOT';
  static const String keywordLike = 'LIKE';
  static const String keywordIn = 'IN';
  static const String keywordOrderBy = 'orderBy';
  static const String keywordLimit = 'limit';
  static const String keywordOffset = 'offset';
  static const String keywordSkip = 'skip';
  static const String keywordGroupBy = 'groupBy';
  static const String keywordHaving = 'having';
  static const String keywordAs = 'as';
  static const String keywordDeclare = 'declare';
  static const String keywordFunction = 'function';
  static const String keywordReturn = 'return';
  static const String keywordCount = 'count';
  static const String keywordSum = 'sum';
  static const String keywordAvg = 'avg';
  static const String keywordMin = 'min';
  static const String keywordMax = 'max';
  static const String keywordAsc = 'ASC';
  static const String keywordDesc = 'DESC';
  static const String spreadOperator = '...';

  /// Engine Constructor Identifiers in TTQL scripts.
  static const String enginePostgres = 'PostgreSql';
  static const String engineMySql = 'MySql';
  static const String engineMongo = 'MongoDb';
  static const String engineSqlite = 'Sqlite';
  static const String engineRedis = 'Redis';
  static const String engineDuckDb = 'DuckDb';
  static const String engineMsSql = 'MsSql';
  static const String engineClickHouse = 'ClickHouse';
  static const String enginePlanetScale = 'PlanetScale';
  static const String engineCockroachDb = 'CockroachDb';
  static const String engineYugabyteDb = 'YugabyteDb';
  static const String engineOracle = 'Oracle';
  static const String engineCassandra = 'Cassandra';

  /// Environment Object identifiers.
  static const String envIdentifier = 'environment';
  static const String envConnectionsKey = 'connections';
  static const String envTablesKey = 'tables';
  static const String envIdKey = 'id';

  /// Forbidden mutation SQL/NoSQL tokens rejected at AST and query planning time.
  static const Set<String> forbiddenMutationKeywords = {
    'INSERT',
    'UPDATE',
    'DELETE',
    'DROP',
    'ALTER',
    'TRUNCATE',
    'REPLACE',
    'CREATE',
    'GRANT',
    'REVOKE',
    'UPSERT',
    'REMOVE',
    'RENAME',
    'FLUSHDB',
    'FLUSHALL',
  };
}
