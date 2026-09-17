import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('TTQL Query Pipeline Tests', () {
    test('Lexer tokenizes fluent operators and keywords (from, on, ==, &&, ||)', () {
      const script = "from(pg.customers).innerJoin(mysql.orders, on: 'id').where(a == 1 && b || c);";
      final lexer = TtqlLexer(script);
      final tokens = lexer.tokenize();

      expect(tokens.any((t) => t.type == TtqlTokenType.keyword && t.value == 'from'), isTrue);
      expect(tokens.any((t) => t.type == TtqlTokenType.keyword && t.value == 'on'), isTrue);
      expect(tokens.any((t) => t.type == TtqlTokenType.operator && t.value == '=='), isTrue);
      expect(tokens.any((t) => t.type == TtqlTokenType.keyword && t.value == 'AND'), isTrue);
      expect(tokens.any((t) => t.type == TtqlTokenType.keyword && t.value == 'OR'), isTrue);
    });

    test('Parses basic fluent pipeline (from.select.where.orderBy.limit) into AST', () {
      const script = '''
const pg = environment.connections.ecommerce_pg;

from(pg.customers)
  .select('customer_id', 'full_name', 'email')
  .where(customer_id == 'cust_101')
  .orderBy(customer_id, 'asc')
  .limit(10);
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.rootInvocations.length, equals(1));
      final root = ast.rootInvocations.first;
      expect(root.targetTableOrCollection, equals('customers'));
      expect(root.projectedColumns, equals(['customer_id', 'full_name', 'email']));
      expect(root.wherePredicate, isNotNull);
      expect(root.wherePredicate!.rootExpression, isA<TtqlComparisonExpression>());

      final comp = root.wherePredicate!.rootExpression as TtqlComparisonExpression;
      expect(comp.fieldName, equals('customer_id'));
      expect(comp.operator, equals('='));
      expect(comp.rightOperand, equals('cust_101'));

      expect(ast.orderBy, isNotNull);
      expect(ast.orderBy!.fieldName, equals('customer_id'));
      expect(ast.orderBy!.direction, equals('ASC'));
      expect(ast.limit, equals(10));
    });

    test('Implicit Projections: Omitting .select(...) defaults to empty wildcard projection', () {
      const script = '''
const pg = environment.connections.ecommerce_pg;

from(pg.customers)
  .where(customer_id == 'cust_101');
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.rootInvocations.first.projectedColumns, isEmpty);

      // Verify DAG planner accepts wildcard projection
      final planner = const TtqlDagPlanner();
      final plan = planner.plan(ast);
      expect(plan.stages.length, equals(1));
      expect(plan.stages[0]!.first.projectedColumns, isEmpty);
    });

    test('Short-Form Join: Supports natural equijoin on: "customer_id"', () {
      const script = '''
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

from(pg.customers)
  .select('customer_id', 'full_name')
  .innerJoin(mysql.shipments, on: 'customer_id')
  .select('shipment_id', 'order_id')
  .limit(20);
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.joins.length, equals(1));
      final join = ast.joins.first;
      expect(join.joinType, equals('innerJoin'));
      expect(join.parentEntityAlias, equals('customers'));
      expect(join.queryInvocation.targetTableOrCollection, equals('shipments'));
      expect(join.queryInvocation.projectedColumns, equals(['shipment_id', 'order_id']));

      // Verify join comparison in AST
      final joinPred = join.queryInvocation.wherePredicate;
      expect(joinPred, isNotNull);
      final comp = joinPred!.rootExpression as TtqlComparisonExpression;
      expect(comp.fieldName, equals('customer_id'));
      expect(comp.isRightOperandFieldReference, isTrue);
      expect(comp.rightOperand, equals('customer_id'));
      expect(comp.rightFieldEntityAlias, equals('customers'));

      // Verify DAG planner correctly creates 2 sequential stages with dependency binding
      final planner = const TtqlDagPlanner();
      final plan = planner.plan(ast);
      expect(plan.stages.length, equals(2));

      final joinStep = plan.stages[1]!.first;
      expect(joinStep.injectedDependencies.length, equals(1));
      expect(joinStep.injectedDependencies.first.sourceColumn, equals('customer_id'));
      expect(joinStep.injectedDependencies.first.targetFilterField, equals('customer_id'));
      expect(joinStep.localJoinColumn, equals('customer_id'));
      expect(joinStep.parentJoinColumn, equals('customer_id'));
    });

    test('Explicit Mismatched Keys: Supports explicit equality predicate in on: clause', () {
      const script = '''
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

from(pg.customers)
  .select('id', 'name')
  .innerJoin(mysql.orders, on: mysql.orders.client_id == pg.customers.id)
  .select('order_id', 'amount');
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.joins.length, equals(1));
      final join = ast.joins.first;
      final comp = join.queryInvocation.wherePredicate!.rootExpression as TtqlComparisonExpression;
      expect(comp.fieldName, equals('client_id'));
      expect(comp.rightOperand, equals('id'));
      expect(comp.isRightOperandFieldReference, isTrue);

      final planner = const TtqlDagPlanner();
      final plan = planner.plan(ast);
      final joinStep = plan.stages[1]!.first;
      expect(joinStep.localJoinColumn, equals('client_id'));
      expect(joinStep.parentJoinColumn, equals('id'));
      expect(joinStep.injectedDependencies.first.targetFilterField, equals('client_id'));
      expect(joinStep.injectedDependencies.first.sourceColumn, equals('id'));
    });

    test('Explicit Mismatched Keys: Automatically re-orients if parent table is on the left side of on:', () {
      const script = '''
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

from(pg.customers)
  .select('id', 'name')
  .innerJoin(mysql.orders, on: pg.customers.id == mysql.orders.client_id);
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      final join = ast.joins.first;
      final comp = join.queryInvocation.wherePredicate!.rootExpression as TtqlComparisonExpression;
      // Target is orders, so fieldName must be client_id and rightOperand must be id
      expect(comp.fieldName, equals('client_id'));
      expect(comp.rightOperand, equals('id'));
      expect(comp.isRightOperandFieldReference, isTrue);
    });

    test('Table Qualifier Disambiguation in .where(...): Routes qualified conditions to proper tables', () {
      const script = '''
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: 'customer_id')
  .where(c.customer_id == 'cust_101' && s.status == 'delivered');
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      // Root customers query should have c.customer_id == 'cust_101'
      final rootPred = ast.rootInvocations.first.wherePredicate;
      expect(rootPred, isNotNull);
      final rootComp = rootPred!.rootExpression as TtqlComparisonExpression;
      expect(rootComp.fieldName, equals('customer_id'));
      expect(rootComp.rightOperand, equals('cust_101'));

      // Join shipments query should have s.status == 'delivered' combined with equijoin condition
      final joinPred = ast.joins.first.queryInvocation.wherePredicate;
      expect(joinPred, isNotNull);
      expect(joinPred!.rootExpression, isA<TtqlBinaryLogicalExpression>());

      // DAG planner will extract the join condition and push down the filter
      final planner = const TtqlDagPlanner();
      final plan = planner.plan(ast);
      final joinStep = plan.stages[1]!.first;
      expect(joinStep.localJoinColumn, equals('customer_id'));
      expect(joinStep.wherePredicate, isNotNull);
      final filterComp = joinStep.wherePredicate!.rootExpression as TtqlComparisonExpression;
      expect(filterComp.fieldName, equals('status'));
      expect(filterComp.rightOperand, equals('delivered'));
    });

    test('Supports arrow function closures in .where() and .orderBy()', () {
      const script = '''
const pg = environment.connections.ecommerce_pg;

from(pg.customers)
  .select('id', 'name')
  .where((row) => row.id == 42)
  .orderBy(row => row.name, 'desc');
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      final comp = ast.rootInvocations.first.wherePredicate!.rootExpression as TtqlComparisonExpression;
      expect(comp.fieldName, equals('id'));
      expect(comp.rightOperand, equals(42));
      expect(ast.orderBy!.fieldName, equals('name'));
      expect(ast.orderBy!.direction, equals('DESC'));
    });

    test('End-to-End Execution: Evaluates fluent pipeline across federated mock connections', () async {
      final provider = CliConnectionProvider();
      provider.registerConnection(
        id: 'pg_main',
        name: 'Postgres Main',
        engineType: DbEngineType.postgres,
        connectionString: 'postgres://localhost/main',
        schemaOverview: {'customers': ['customer_id', 'full_name']},
        mockData: [
          {'customer_id': 'cust_101', 'full_name': 'Alice Smith'},
        ],
      );

      provider.registerConnection(
        id: 'mysql_inventory',
        name: 'MySQL Inventory',
        engineType: DbEngineType.mysql,
        connectionString: 'mysql://localhost/inventory',
        schemaOverview: {'shipments': ['shipment_id', 'customer_id', 'status']},
        mockData: [
          {'shipment_id': 'ship_1', 'customer_id': 'cust_101', 'status': 'delivered'},
        ],
      );

      const script = '''
const pg = environment.connections.pg_main;
const mysql = environment.connections.mysql_inventory;

from(pg.customers)
  .select('customer_id', 'full_name')
  .where(customer_id == 'cust_101')
  .innerJoin(mysql.shipments, on: 'customer_id')
  .select('shipment_id', 'status');
''';

      final engine = TtqlEngine(connectionProvider: provider);
      final result = await engine.executeScript(script);

      expect(result.totalRowCount, equals(1));
      final row = result.rows.first;
      expect(row['customer_id'], equals('cust_101'));
      expect(row['full_name'], equals('Alice Smith'));
      expect(row['shipment_id'], equals('ship_1'));
      expect(row['status'], equals('delivered'));
    });

    test('Pagination: Parses and executes .limit() with .offset() and .skip()', () async {
      final provider = CliConnectionProvider();
      provider.registerConnection(
        id: 'pg_main',
        name: 'Postgres',
        engineType: DbEngineType.postgres,
        connectionString: 'postgres://user:pass@localhost:5432/test',
        schemaOverview: {'items': ['id', 'val']},
        mockData: [
          {'id': '1', 'val': 10},
          {'id': '2', 'val': 20},
          {'id': '3', 'val': 30},
          {'id': '4', 'val': 40},
          {'id': '5', 'val': 50},
        ],
      );

      const script = '''
const pg = environment.connections.pg_main;
from(pg.items)
  .orderBy(val, 'ASC')
  .limit(2)
  .offset(2);
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.limit, equals(2));
      expect(ast.offset, equals(2));

      final engine = TtqlEngine(connectionProvider: provider);
      final result = await engine.executeScript(script);

      expect(result.totalRowCount, equals(2));
      expect(result.rows[0]['id'], equals('3'));
      expect(result.rows[1]['id'], equals('4'));
    });

    test('Multi-Column Ordering: Chained .orderBy calls and multi-column lists', () {
      const script = '''
from(pg.orders)
  .orderBy('status', 'ASC')
  .orderBy('created_at', 'DESC');
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.orderBys.length, equals(2));
      expect(ast.orderBys[0].fieldName, equals('status'));
      expect(ast.orderBys[0].direction, equals('ASC'));
      expect(ast.orderBys[1].fieldName, equals('created_at'));
      expect(ast.orderBys[1].direction, equals('DESC'));
    });

    test('Analytical Aggregations & GroupBy: End-to-End evaluation with COUNT, SUM, AVG, and HAVING', () async {
      final provider = CliConnectionProvider();
      provider.registerConnection(
        id: 'pg_main',
        name: 'Postgres',
        engineType: DbEngineType.postgres,
        connectionString: 'postgres://user:pass@localhost:5432/test',
        schemaOverview: {'orders': ['order_id', 'status', 'amount']},
        mockData: [
          {'order_id': 'o1', 'status': 'completed', 'amount': 100},
          {'order_id': 'o2', 'status': 'completed', 'amount': 200},
          {'order_id': 'o3', 'status': 'completed', 'amount': 300},
          {'order_id': 'o4', 'status': 'pending', 'amount': 50},
        ],
      );

      const script = '''
const pg = environment.connections.pg_main;
from(pg.orders)
  .groupBy('status')
  .select([
    status,
    count() as order_count,
    sum(amount) as total_revenue,
    avg(amount) as avg_revenue
  ])
  .having(count() > 1)
  .orderBy(total_revenue, 'DESC');
''';
      final tokens = TtqlLexer(script).tokenize();
      final parser = TtqlParser(tokens);
      final ast = parser.parse();

      expect(ast.groupByColumns, equals(['status']));
      expect(ast.havingPredicate, isNotNull);
      expect(ast.projections.length, equals(4));

      final engine = TtqlEngine(connectionProvider: provider);
      final result = await engine.executeScript(script);

      // Only 'completed' has count > 1
      expect(result.totalRowCount, equals(1));
      final row = result.rows.first;
      expect(row['status'], equals('completed'));
      expect(row['order_count'], equals(3));
      expect(row['total_revenue'], equals(600));
      expect(row['avg_revenue'], equals(200.0));
    });

    test('Syntax Error: Scripts not beginning with from() throw parse exception', () {
      const invalidScript = "where(x == 1);";
      final tokens = TtqlLexer(invalidScript).tokenize();
      final parser = TtqlParser(tokens);
      expect(
        () => parser.parse(),
        throwsA(isA<TtqlParseException>().having(
          (e) => e.message,
          'message',
          contains('Expected "from" statement to start query pipeline'),
        )),
      );
    });
  });
}
