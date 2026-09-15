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
  });
}
