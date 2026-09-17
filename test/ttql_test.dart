import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('package:ttql Engine & Parser Unit Tests', () {
    const sampleScript = '''
const pg = environment.connections.test_pg;
const mysql = environment.connections.test_mysql;
const targetId = 'cust_101';

from(pg.customers)
  .select('customer_id', 'full_name', 'email')
  .where(customer_id == targetId)
  .innerJoin(mysql.shipments, on: 'customer_id')
  .select('shipment_id', 'order_id')
  .orderBy(customer_id, 'ASC')
  .limit(10);
''';

    test('TtqlLexer tokenizes keywords and symbols', () {
      final lexer = TtqlLexer(sampleScript);
      final tokens = lexer.tokenize();
      expect(tokens, isNotEmpty);
      expect(tokens.any((t) => t.value == 'from'), isTrue);
      expect(tokens.any((t) => t.value == 'innerJoin'), isTrue);
      expect(tokens.any((t) => t.value == 'where'), isTrue);
    });

    test('TtqlParser parses script into AST', () {
      final lexer = TtqlLexer(sampleScript);
      final tokens = lexer.tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.declaredConstants['targetId'], equals('cust_101'));
      expect(ast.rootInvocations.length, equals(1));
      expect(ast.rootInvocations[0].targetTableOrCollection, equals('customers'));
      expect(ast.joins.length, equals(1));
      expect(ast.joins[0].queryInvocation.targetTableOrCollection, equals('shipments'));
      expect(ast.limit, equals(10));
    });

    test('TtqlDagPlanner plans execution stages', () {
      final lexer = TtqlLexer(sampleScript);
      final tokens = lexer.tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      final planner = const TtqlDagPlanner();
      final plan = planner.plan(ast);

      expect(plan.stages.length, equals(2));
      expect(plan.stages[0]!.length, equals(1));
      expect(plan.stages[1]!.length, equals(1));
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
