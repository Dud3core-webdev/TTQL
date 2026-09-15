import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('package:ttql Engine & Parser Unit Tests', () {
    const sampleScript = '''
const pg = environment.connections.test_pg;
const mysql = environment.connections.test_mysql;
const targetId = 'cust_101';

select(() => {
    declare asyncRun(() => {
        PostgreSql(pg.id, ['customer_id', 'full_name', 'email'], pg.tables['customers']),
        MySql(mysql.id, ['shipment_id', 'order_id', 'customer_id'], mysql.tables['shipments'])
    })
    .where((row) => row.customer_id is targetId)
});
''';

    test('TtqlLexer tokenizes keywords and symbols', () {
      final lexer = TtqlLexer(sampleScript);
      final tokens = lexer.tokenize();
      expect(tokens, isNotEmpty);
      expect(tokens.any((t) => t.value == 'select'), isTrue);
      expect(tokens.any((t) => t.value == 'PostgreSql'), isTrue);
    });

    test('TtqlParser parses script into AST', () {
      final lexer = TtqlLexer(sampleScript);
      final tokens = lexer.tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.declaredConstants['targetId'], equals('cust_101'));
      expect(ast.rootInvocations.length, equals(2));
      expect(ast.rootInvocations[0].engineType, equals(DbEngineType.postgres));
      expect(ast.rootInvocations[1].engineType, equals(DbEngineType.mysql));
    });

    test('TtqlDagPlanner plans execution stages', () {
      final lexer = TtqlLexer(sampleScript);
      final tokens = lexer.tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      final planner = const TtqlDagPlanner();
      final plan = planner.plan(ast);

      expect(plan.stages.length, equals(1));
      expect(plan.stages[0]!.length, equals(2));
    });

    test('TtqlSecurityException rejects forbidden mutation SQL statements', () {
      const dropScript = "DROP TABLE users;";
      final lexer = TtqlLexer(dropScript);
      expect(
        () => lexer.tokenize(),
        throwsA(isA<TtqlSecurityException>()),
      );
    });
  });
}
