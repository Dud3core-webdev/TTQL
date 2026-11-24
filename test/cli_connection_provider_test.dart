import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('CliConnectionProvider Unit Tests', () {
    test('expands environment variables in connection strings with \${VAR_NAME}', () {
      final expanded = CliConnectionProvider.expandEnvVars('postgres://\${USER}:secret@localhost:5432/main');
      expect(expanded.contains('\${USER}'), isFalse);
    });

    test('loads connection descriptors and mock data from JSON config string', () {
      final provider = CliConnectionProvider();
      const jsonConfig = '''
      {
        "connections": [
          {
            "id": "pg_test",
            "name": "Postgres Test Connection",
            "engine": "postgres",
            "connectionString": "postgres://user:pass@localhost:5432/testdb",
            "schemaOverview": {
              "users": ["id", "name", "email"]
            },
            "mockData": [
              {"id": 1, "name": "Alice", "email": "alice@example.com"}
            ]
          }
        ]
      }
      ''';

      provider.loadFromJsonString(jsonConfig);

      expect(provider.activeConnectionIds, contains('pg_test'));
      expect(provider.getConnectionName('pg_test'), equals('Postgres Test Connection'));
      expect(provider.getEngineType('pg_test'), equals(DbEngineType.postgres));

      final schema = provider.getSchemaOverview('pg_test');
      expect(schema, isNotNull);
      expect(schema!['users'], equals(['id', 'name', 'email']));
    });

    test('executes query and returns registered mock data', () async {
      final provider = CliConnectionProvider();
      provider.registerConnection(
        id: 'sqlite_mock',
        name: 'SQLite Mock',
        engineType: DbEngineType.sqlite,
        connectionString: ':memory:',
        schemaOverview: {'stock': ['sku', 'qty']},
        mockData: [
          {'sku': 'ITEM_A', 'qty': 42}
        ],
      );

      final results = await provider.executeQueryOnConnection(
        'sqlite_mock',
        'SELECT * FROM stock',
      );

      expect(results.length, equals(1));
      expect(results.first['sku'], equals('ITEM_A'));
      expect(results.first['qty'], equals(42));
    });

    test('executes live read-only SQL query against local SQLite file when mockData is omitted', () async {
      final tempDir = Directory.systemTemp.createTempSync('ttql_cli_sqlite_');
      final dbFile = File('${tempDir.path}/live_test.sqlite');
      final db = sqlite3.open(dbFile.path);
      db.execute('CREATE TABLE items (sku TEXT PRIMARY KEY, qty INTEGER);');
      db.execute("INSERT INTO items VALUES ('SKU-99', 15);");
      // Keep dispose() for compatibility with sqlite3 2.x and 3.x.
      // ignore: deprecated_member_use
      db.dispose();

      try {
        final provider = CliConnectionProvider();
        provider.registerConnection(
          id: 'local_wh',
          name: 'Local Warehouse',
          engineType: DbEngineType.sqlite,
          connectionString: dbFile.path,
          schemaOverview: {'items': ['sku', 'qty']},
        );

        final rows = await provider.executeQueryOnConnection(
          'local_wh',
          'SELECT sku, qty FROM items',
        );
        expect(rows.length, equals(1));
        expect(rows.first['sku'], equals('SKU-99'));
        expect(rows.first['qty'], equals(15));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('fails fast with TtqlExecutionException when remote engine lacks mockData or liveQueryExecutor', () async {
      final provider = CliConnectionProvider();
      provider.registerConnection(
        id: 'pg_unconfigured',
        name: 'Unconfigured PG',
        engineType: DbEngineType.postgres,
        connectionString: 'postgres://localhost:5432/db',
        schemaOverview: {},
      );

      expect(
        () => provider.executeQueryOnConnection('pg_unconfigured', 'SELECT 1'),
        throwsA(isA<TtqlExecutionException>()),
      );
    });
  });
}
