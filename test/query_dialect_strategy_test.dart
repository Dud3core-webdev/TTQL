import 'dart:convert';
import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('DbEngineRegistry Unit Tests', () {
    test('resolves canonical and alias engine identifiers accurately', () {
      expect(DbEngineRegistry.resolve('postgresql'), equals(DbEngineType.postgres));
      expect(DbEngineRegistry.resolve('postgres'), equals(DbEngineType.postgres));
      expect(DbEngineRegistry.resolve('pgsql'), equals(DbEngineType.postgres));
      expect(DbEngineRegistry.resolve('mysql'), equals(DbEngineType.mysql));
      expect(DbEngineRegistry.resolve('mariadb'), equals(DbEngineType.mysql));
      expect(DbEngineRegistry.resolve('mongodb'), equals(DbEngineType.mongodb));
      expect(DbEngineRegistry.resolve('mongo'), equals(DbEngineType.mongodb));
      expect(DbEngineRegistry.resolve('redis'), equals(DbEngineType.redis));
      expect(DbEngineRegistry.resolve('sqlite'), equals(DbEngineType.sqlite));
      expect(DbEngineRegistry.resolve('sqlite3'), equals(DbEngineType.sqlite));
      expect(DbEngineRegistry.resolve('duckdb'), equals(DbEngineType.duckdb));
      expect(DbEngineRegistry.resolve('cassandra'), equals(DbEngineType.cassandra));
      expect(DbEngineRegistry.resolve('scylla'), equals(DbEngineType.cassandra));
    });

    test('throws TtqlParseException on unknown engine identifier', () {
      expect(
        () => DbEngineRegistry.resolve('non_existent_db'),
        throwsA(isA<TtqlParseException>()),
      );
    });

    test('tryResolve returns null on unknown or empty string', () {
      expect(DbEngineRegistry.tryResolve('unknown'), isNull);
      expect(DbEngineRegistry.tryResolve(''), isNull);
      expect(DbEngineRegistry.tryResolve(null), isNull);
    });
  });

  group('QueryDialectStrategy Unit Tests', () {
    test('SqlQueryDialect generates ANSI SQL with proper quoting and limit', () {
      const dialect = SqlQueryDialect();
      final step = TtqlPlannedStep(
        stepId: 'step_1',
        stageIndex: 0,
        connectionId: 'conn_pg',
        engineType: DbEngineType.postgres,
        targetTableOrCollection: 'users',
        projectedColumns: ['id', 'email'],
        stagingTableName: 'stage_users',
        entityAlias: 'u',
        injectedDependencies: [
          const TtqlDependencyBinding(
            sourceStagingTable: 'stage_orders',
            sourceColumn: 'user_id',
            targetFilterField: 'id',
          ),
        ],
      );

      final query = dialect.buildQuery(
        step: step,
        foreignKeyLookup: (table, col) => [101, 102],
        maxRows: 100,
      );

      expect(query, contains('SELECT "id", "email" FROM "users"'));
      expect(query, contains('"id" IN (\'101\', \'102\')'));
      expect(query, contains('LIMIT 100'));
    });

    test('SqlQueryDialect applies MySQL backticks for MySQL and PlanetScale', () {
      const dialect = SqlQueryDialect();
      final step = TtqlPlannedStep(
        stepId: 'step_2',
        stageIndex: 0,
        connectionId: 'conn_mysql',
        engineType: DbEngineType.mysql,
        targetTableOrCollection: 'products',
        projectedColumns: ['sku', 'price'],
        stagingTableName: 'stage_products',
        entityAlias: 'p',
      );

      final query = dialect.buildQuery(
        step: step,
        foreignKeyLookup: (table, col) => [],
        maxRows: 50,
      );

      expect(query, equals('SELECT `sku`, `price` FROM `products` LIMIT 50'));
    });

    test('MongoQueryDialect generates valid JSON MQL filter payload', () {
      const dialect = MongoQueryDialect();
      final step = TtqlPlannedStep(
        stepId: 'step_3',
        stageIndex: 0,
        connectionId: 'conn_mongo',
        engineType: DbEngineType.mongodb,
        targetTableOrCollection: 'customers',
        projectedColumns: ['name', 'address'],
        stagingTableName: 'stage_customers',
        entityAlias: 'c',
        injectedDependencies: [
          const TtqlDependencyBinding(
            sourceStagingTable: 'stage_orders',
            sourceColumn: 'customer_id',
            targetFilterField: '_id',
          ),
        ],
      );

      final query = dialect.buildQuery(
        step: step,
        foreignKeyLookup: (table, col) => ['cust_1', 'cust_2'],
        maxRows: 25,
      );

      final decoded = jsonDecode(query) as Map<String, dynamic>;
      expect(decoded['collection'], equals('customers'));
      expect(decoded['limit'], equals(25));
      expect(decoded['filter']['_id']['\$in'], equals(['cust_1', 'cust_2']));
    });

    test('RedisQueryDialect formats KEYS pattern query', () {
      const dialect = RedisQueryDialect();
      final step = TtqlPlannedStep(
        stepId: 'step_4',
        stageIndex: 0,
        connectionId: 'conn_redis',
        engineType: DbEngineType.redis,
        targetTableOrCollection: 'session:*',
        projectedColumns: [],
        stagingTableName: 'stage_redis',
        entityAlias: 'r',
      );

      final query = dialect.buildQuery(
        step: step,
        foreignKeyLookup: (table, col) => [],
        maxRows: 10,
      );

      expect(query, equals('KEYS session:*'));
    });
  });

  group('TtqlEphemeralStagingDatabase Domain-Neutral Join Tests', () {
    test('throws descriptive TtqlExecutionException on ambiguous multiple common columns', () {
      final stagingDb = TtqlEphemeralStagingDatabase();
      try {
        stagingDb.insertStagingRows('table_a', [
          {'user_id': 1, 'org_id': 10, 'created_at': '2026-01-01'},
        ]);
        stagingDb.insertStagingRows('table_b', [
          {'user_id': 1, 'org_id': 10, 'created_at': '2026-01-01', 'metric': 42},
        ]);

        final stepA = TtqlPlannedStep(
          stepId: 'a',
          stageIndex: 0,
          connectionId: 'c1',
          engineType: DbEngineType.sqlite,
          targetTableOrCollection: 'a',
          projectedColumns: ['user_id', 'org_id'],
          stagingTableName: 'table_a',
          entityAlias: 'a',
        );

        final stepB = TtqlPlannedStep(
          stepId: 'b',
          stageIndex: 1,
          connectionId: 'c2',
          engineType: DbEngineType.sqlite,
          targetTableOrCollection: 'b',
          projectedColumns: ['user_id', 'metric'],
          stagingTableName: 'table_b',
          entityAlias: 'b',
          parentStagingTable: 'table_a',
          // Deliberately omit parentJoinColumn and localJoinColumn
        );

        expect(
          () => stagingDb.executeFinalSyntheticJoin([stepA, stepB]),
          throwsA(isA<TtqlExecutionException>().having(
            (e) => e.message,
            'message',
            contains('Ambiguous join between "table_a" and "table_b": Multiple common columns found'),
          )),
        );
      } finally {
        stagingDb.dispose();
      }
    });

    test('joins automatically on unambiguous single common column', () {
      final stagingDb = TtqlEphemeralStagingDatabase();
      try {
        stagingDb.insertStagingRows('users', [
          {'user_key': 'u1', 'name': 'Alice'},
        ]);
        stagingDb.insertStagingRows('profiles', [
          {'user_key': 'u1', 'bio': 'Architect'},
        ]);

        final stepUsers = TtqlPlannedStep(
          stepId: 'u',
          stageIndex: 0,
          connectionId: 'c1',
          engineType: DbEngineType.sqlite,
          targetTableOrCollection: 'users',
          projectedColumns: ['user_key', 'name'],
          stagingTableName: 'users',
          entityAlias: 'u',
        );

        final stepProfiles = TtqlPlannedStep(
          stepId: 'p',
          stageIndex: 1,
          connectionId: 'c2',
          engineType: DbEngineType.sqlite,
          targetTableOrCollection: 'profiles',
          projectedColumns: ['user_key', 'bio'],
          stagingTableName: 'profiles',
          entityAlias: 'p',
          parentStagingTable: 'users',
        );

        final rows = stagingDb.executeFinalSyntheticJoin([stepUsers, stepProfiles]);
        expect(rows.length, equals(1));
        expect(rows.first['name'], equals('Alice'));
        expect(rows.first['bio'], equals('Architect'));
      } finally {
        stagingDb.dispose();
      }
    });
  });
}
