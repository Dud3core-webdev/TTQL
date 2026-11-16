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

  group('declare function projection macros', () {
    TtqlScriptNode _parse(String script) {
      final tokens = TtqlLexer(script).tokenize();
      return TtqlParser(tokens).parse();
    }

    test('Basic macro — mapStatistics produces all 6 projections', () {
      const script = '''
declare function mapStatistics(o) {
    return {
        o.status,
        count() as order_count,
        sum(o.total_amount) as total_volume,
        avg(o.total_amount) as average_ticket,
        min(o.total_amount) as smallest_order,
        max(o.total_amount) as largest_order
    };
}

from(pg.orders as o)
  .groupBy(o.status)
  .select(mapStatistics(o));
''';
      final ast = _parse(script);
      final projs = ast.projections;

      expect(projs.length, equals(6));

      // First: column projection for o.status
      final statusProj = projs[0] as TtqlColumnProjection;
      expect(statusProj.columnName, equals('status'));
      expect(statusProj.entityAlias, equals('o'));

      // Remaining: aggregate projections
      final aggs = projs.skip(1).cast<TtqlAggregateProjection>().toList();
      expect(aggs[0].functionName, equals('COUNT'));
      expect(aggs[0].alias, equals('order_count'));

      expect(aggs[1].functionName, equals('SUM'));
      expect(aggs[1].argumentColumn, equals('total_amount'));
      expect(aggs[1].entityAlias, equals('o'));
      expect(aggs[1].alias, equals('total_volume'));

      expect(aggs[2].functionName, equals('AVG'));
      expect(aggs[2].alias, equals('average_ticket'));

      expect(aggs[3].functionName, equals('MIN'));
      expect(aggs[3].alias, equals('smallest_order'));

      expect(aggs[4].functionName, equals('MAX'));
      expect(aggs[4].alias, equals('largest_order'));
    });

    test('Macro mixed with inline column — extra column appended after expansion', () {
      const script = '''
declare function mapStatistics(o) {
    return {
        o.status,
        count() as order_count,
        sum(o.total_amount) as total_volume
    };
}

from(pg.orders as o)
  .groupBy(o.status)
  .select(mapStatistics(o), o.region);
''';
      final ast = _parse(script);
      expect(ast.projections.length, equals(4));

      // Last item should be the extra inline column
      final last = ast.projections.last as TtqlColumnProjection;
      expect(last.columnName, equals('region'));
      expect(last.entityAlias, equals('o'));
    });

    test('Multiple declare functions — both usable in same query', () {
      const script = '''
declare function basicCols(o) {
    return { o.id, o.status };
}

declare function aggregates(o) {
    return { count() as cnt, sum(o.amount) as total };
}

from(pg.orders as o)
  .groupBy(o.status)
  .select(basicCols(o), aggregates(o));
''';
      final ast = _parse(script);
      expect(ast.projections.length, equals(4));

      expect((ast.projections[0] as TtqlColumnProjection).columnName, equals('id'));
      expect((ast.projections[1] as TtqlColumnProjection).columnName, equals('status'));
      expect((ast.projections[2] as TtqlAggregateProjection).functionName, equals('COUNT'));
      expect((ast.projections[3] as TtqlAggregateProjection).functionName, equals('SUM'));
    });

    test('Alias rebinding — caller uses different alias than declared parameter', () {
      const script = '''
declare function summary(row) {
    return { row.name, count() as cnt };
}

from(pg.products as p)
  .groupBy(p.name)
  .select(summary(p));
''';
      final ast = _parse(script);
      expect(ast.projections.length, equals(2));

      // entityAlias should be 'p' (the caller alias), not 'row' (the declared param)
      final col = ast.projections[0] as TtqlColumnProjection;
      expect(col.columnName, equals('name'));
      expect(col.entityAlias, equals('p'));
    });

    test('Error: unknown macro called inside select() throws TtqlParseException', () {
      const script = '''
from(pg.orders as o)
  .select(doesNotExist(o));
''';
      expect(
        () => _parse(script),
        throwsA(isA<TtqlParseException>()),
      );
    });

    test('Error: empty function body throws TtqlParseException', () {
      const script = '''
declare function empty(o) {
    return {};
}

from(pg.orders as o)
  .select(empty(o));
''';
      expect(
        () => _parse(script),
        throwsA(isA<TtqlParseException>().having(
          (e) => e.message,
          'message',
          contains('must return at least one'),
        )),
      );
    });

    test('Lexer: declare, function, return tokenise as keywords', () {
      const script = 'declare function foo(x) { return { x.col }; }';
      final tokens = TtqlLexer(script).tokenize();
      expect(tokens.any((t) => t.type == TtqlTokenType.keyword && t.value == 'declare'), isTrue);
      expect(tokens.any((t) => t.type == TtqlTokenType.keyword && t.value == 'function'), isTrue);
      expect(tokens.any((t) => t.type == TtqlTokenType.keyword && t.value == 'return'), isTrue);
    });

    test('Multi-parameter macro: mapCustomerInformation(customer, activityLogs)', () {
      const script = '''
declare function mapCustomerInformation(customer, activityLogs) {
    return {
        customer.customer_id,
        customer.full_name,
        s.carrier,
        s.tracking_code,
        activityLogs.event_type,
        activityLogs.platform
    }
}

from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: c.customer_id == s.customer_id)
  .innerJoin(mongo.user_activity_logs as l, on: c.customer_id == l.customer_id)
  .where(c.customer_id == 'cust_101')
  .select(mapCustomerInformation(c, l));
''';
      final ast = _parse(script);
      expect(ast.projections.length, equals(6));

      final p0 = ast.projections[0] as TtqlColumnProjection;
      expect(p0.columnName, equals('customer_id'));
      expect(p0.entityAlias, equals('c')); // rebound from customer -> c

      final p1 = ast.projections[1] as TtqlColumnProjection;
      expect(p1.columnName, equals('full_name'));
      expect(p1.entityAlias, equals('c')); // rebound from customer -> c

      final p2 = ast.projections[2] as TtqlColumnProjection;
      expect(p2.columnName, equals('carrier'));
      expect(p2.entityAlias, equals('s')); // non-parameter s remains s

      final p4 = ast.projections[4] as TtqlColumnProjection;
      expect(p4.columnName, equals('event_type'));
      expect(p4.entityAlias, equals('l')); // rebound from activityLogs -> l
    });

    test('Zero-parameter macro: mapAll() inlines body directly', () {
      const script = '''
declare function mapAll() {
    return {
        c.customer_id,
        s.carrier
    }
}

from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: c.customer_id == s.customer_id)
  .select(mapAll());
''';
      final ast = _parse(script);
      expect(ast.projections.length, equals(2));
      final p0 = ast.projections[0] as TtqlColumnProjection;
      expect(p0.columnName, equals('customer_id'));
      expect(p0.entityAlias, equals('c'));
      final p1 = ast.projections[1] as TtqlColumnProjection;
      expect(p1.columnName, equals('carrier'));
      expect(p1.entityAlias, equals('s'));
    });
  });

  group('Cross-Database Multi-Way Joins & Synthetic Staging Tests', () {
    test('Three-Way Cross-Database Join (PostgreSQL + MySQL + MongoDB) with Selective Projections', () async {
      final provider = CliConnectionProvider();
      provider.registerConnection(
        id: 'ecommerce_pg',
        name: 'Postgres Ecommerce',
        engineType: DbEngineType.postgres,
        connectionString: 'postgres://localhost/ecommerce',
        schemaOverview: {'customers': ['customer_id', 'full_name', 'email', 'country', 'created_at']},
        mockData: [
          {'customer_id': 'cust_101', 'full_name': 'Alice Smith', 'email': 'alice@example.com'},
          {'customer_id': 'cust_102', 'full_name': 'Bob Jones', 'email': 'bob@example.com'},
        ],
      );

      provider.registerConnection(
        id: 'inventory_mysql',
        name: 'MySQL Inventory',
        engineType: DbEngineType.mysql,
        connectionString: 'mysql://localhost/inventory',
        schemaOverview: {'shipments': ['shipment_id', 'order_id', 'customer_id', 'carrier', 'tracking_code']},
        mockData: [
          {'shipment_id': 'ship_1', 'customer_id': 'cust_101', 'carrier': 'FedEx', 'tracking_code': 'FX123'},
        ],
      );

      provider.registerConnection(
        id: 'analytics_mongo_db',
        name: 'Mongo Analytics',
        engineType: DbEngineType.mongodb,
        connectionString: 'mongodb://localhost/analytics',
        schemaOverview: {'user_activity_logs': ['log_id', 'customer_id', 'event_type', 'platform']},
        mockData: [
          {'log_id': 'log_1', 'customer_id': 'cust_101', 'event_type': 'checkout_completed', 'platform': 'web'},
        ],
      );

      const script = '''
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;
const mongo = environment.connections.analytics_mongo_db;

from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: c.customer_id == s.customer_id)
  .innerJoin(mongo.user_activity_logs as l, on: c.customer_id == l.customer_id)
  .where(c.customer_id == 'cust_101')
  .select([
    c.customer_id,
    c.full_name,
    s.carrier,
    s.tracking_code,
    l.event_type,
    l.platform
  ]);
''';

      // 1. Plan DAG
      final tokens = TtqlLexer(script).tokenize();
      final ast = TtqlParser(tokens).parse();
      final plan = const TtqlDagPlanner().plan(ast);

      expect(plan.stages.length, equals(3));
      // Stage 1 (shipments) and Stage 2 (user_activity_logs) must include customer_id in planned projectedColumns
      expect(plan.stages[1]!.first.projectedColumns, contains('customer_id'));
      expect(plan.stages[2]!.first.projectedColumns, contains('customer_id'));
      // Both joins must resolve to stage 0 (customers)
      expect(plan.stages[1]!.first.parentStagingTable, equals('ttql_stage_0_customers'));
      expect(plan.stages[2]!.first.parentStagingTable, equals('ttql_stage_0_customers'));

      // 2. Execute End-to-End through TtqlEngine
      final engine = TtqlEngine(connectionProvider: provider);
      final result = await engine.executeScript(script);

      expect(result.totalRowCount, equals(1));
      final row = result.rows.first;
      expect(row['customer_id'], equals('cust_101'));
      expect(row['full_name'], equals('Alice Smith'));
      expect(row['carrier'], equals('FedEx'));
      expect(row['tracking_code'], equals('FX123'));
      expect(row['event_type'], equals('checkout_completed'));
      expect(row['platform'], equals('web'));
    });

    test('Chained Joins: Stage 2 joins to Stage 1 instead of Stage 0', () async {
      const script = '''
from(pg.customers as c)
  .innerJoin(mysql.orders as o, on: c.customer_id == o.customer_id)
  .innerJoin(mysql.order_items as oi, on: o.order_id == oi.order_id)
  .select([
    c.customer_id,
    o.order_id,
    oi.item_id
  ]);
''';
      final tokens = TtqlLexer(script).tokenize();
      final ast = TtqlParser(tokens).parse();
      final plan = const TtqlDagPlanner().plan(ast);

      expect(plan.stages.length, equals(3));
      // Stage 1 (orders) parent is Stage 0 (customers)
      expect(plan.stages[1]!.first.parentStagingTable, equals('ttql_stage_0_customers'));
      expect(plan.stages[1]!.first.localJoinColumn, equals('customer_id'));
      expect(plan.stages[1]!.first.parentJoinColumn, equals('customer_id'));

      // Stage 2 (order_items) parent is Stage 1 (orders), NOT customers!
      expect(plan.stages[2]!.first.parentStagingTable, equals('ttql_stage_1_orders'));
      expect(plan.stages[2]!.first.localJoinColumn, equals('order_id'));
      expect(plan.stages[2]!.first.parentJoinColumn, equals('order_id'));
    });

    test('Join Symmetry: Target on left (s.id == c.id) vs parent on left (c.id == s.id)', () {
      const scriptA = '''
from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: c.customer_id == s.customer_id);
''';
      const scriptB = '''
from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: s.customer_id == c.customer_id);
''';

      final astA = TtqlParser(TtqlLexer(scriptA).tokenize()).parse();
      final astB = TtqlParser(TtqlLexer(scriptB).tokenize()).parse();

      final planA = const TtqlDagPlanner().plan(astA);
      final planB = const TtqlDagPlanner().plan(astB);

      final stepA = planA.stages[1]!.first;
      final stepB = planB.stages[1]!.first;

      expect(stepA.localJoinColumn, equals('customer_id'));
      expect(stepA.parentJoinColumn, equals('customer_id'));
      expect(stepA.parentStagingTable, equals(stepB.parentStagingTable));
      expect(stepB.localJoinColumn, equals('customer_id'));
      expect(stepB.parentJoinColumn, equals('customer_id'));
    });

    test('Qualified Array Constants & IN Spread Operator: Parses and executes Example 6 cleanly', () async {
      const script = '''
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

const productCols = [p.product_id, p.title, p.sku, p.price];
const targetSkus = ['SKU-001', 'SKU-002', 'SKU-003'];

from(pg.products as p)
  .innerJoin(mysql.warehouse_stock as w, on: p.product_id == w.product_id)
  .where(p.sku IN [...targetSkus] && w.quantity_on_hand >= 50)
  .select([...productCols, w.warehouse_code, w.quantity_on_hand])
  .orderBy(w.quantity_on_hand, 'DESC');
''';

      final ast = TtqlParser(TtqlLexer(script).tokenize()).parse();
      expect(ast.constantValues['productCols'], equals(['p.product_id', 'p.title', 'p.sku', 'p.price']));
      expect(ast.constantValues['targetSkus'], equals(['SKU-001', 'SKU-002', 'SKU-003']));

      final colProjs = ast.projections.whereType<TtqlColumnProjection>().toList();
      expect(colProjs.length, equals(6));
      expect(colProjs[0].entityAlias, equals('p'));
      expect(colProjs[0].columnName, equals('product_id'));
      expect(colProjs[4].entityAlias, equals('w'));
      expect(colProjs[4].columnName, equals('warehouse_code'));

      final linter = const TtqlLinter();
      final diagnostics = linter.lint(script);
      expect(diagnostics.where((d) => d.severity == TtqlDiagnosticSeverity.error), isEmpty);

      final provider = CliConnectionProvider();
      provider.registerConnection(
        id: 'ecommerce_pg',
        name: 'Postgres Ecommerce',
        engineType: DbEngineType.postgres,
        connectionString: 'postgres://localhost/ecommerce',
        schemaOverview: {'products': ['product_id', 'title', 'sku', 'price']},
        mockData: [
          {'product_id': 'prod_1', 'title': 'Mechanical Keyboard', 'sku': 'SKU-001', 'price': 149.99},
        ],
      );
      provider.registerConnection(
        id: 'inventory_mysql',
        name: 'MySQL Inventory',
        engineType: DbEngineType.mysql,
        connectionString: 'mysql://localhost/inventory',
        schemaOverview: {'warehouse_stock': ['product_id', 'warehouse_code', 'quantity_on_hand']},
        mockData: [
          {'product_id': 'prod_1', 'warehouse_code': 'WH-EAST', 'quantity_on_hand': 120},
        ],
      );

      final plan = const TtqlDagPlanner().plan(ast);
      final stage0Sql = SqlQueryDialect().buildQuery(
        step: plan.stages[0]!.first,
        foreignKeyLookup: (_, __) => [],
        maxRows: 500,
      );
      expect(stage0Sql, contains("WHERE \"sku\" IN ('SKU-001', 'SKU-002', 'SKU-003')"));

      final engine = TtqlEngine(connectionProvider: provider);
      final result = await engine.executeScript(script);
      expect(result.totalRowCount, equals(1));
      expect(result.rows.first['sku'], equals('SKU-001'));
      expect(result.rows.first['warehouse_code'], equals('WH-EAST'));
      expect(result.rows.first['quantity_on_hand'], equals(120));
    });

    test('Parser Fail-Fast Guard: Malformed array constants and IN lists throw TtqlParseException instead of hanging', () {
      const malformedScripts = [
        'const x = [p.;',
        'const x = [p.product_id, 1 + 2];',
        '''
const pg = environment.connections.ecommerce_pg;
from(pg.products as p)
  .where(p.sku IN [p.);
''',
        '''
const pg = environment.connections.ecommerce_pg;
from(pg.products as p)
  .where(p.sku IN [...targetSkus]);
''',
      ];

      final linter = const TtqlLinter();
      for (final bad in malformedScripts) {
        expect(
          () => TtqlParser(TtqlLexer(bad).tokenize()).parse(),
          throwsA(isA<TtqlParseException>()),
        );
        final diags = linter.lint(bad);
        expect(diags.any((d) => d.severity == TtqlDiagnosticSeverity.error), isTrue);
      }
    });

    test('SqlQueryDialect & SqlExpressionVisitor: Uses unquoted identifiers for Oracle/Cassandra and quoted elsewhere', () {
      final dialect = SqlQueryDialect();
      const oraStep = TtqlPlannedStep(
        stepId: 'step_3_join_2',
        stageIndex: 3,
        connectionId: '1794845612716',
        engineType: DbEngineType.oracle,
        targetTableOrCollection: 'ledger_transactions',
        projectedColumns: ['account_code', 'debit', 'invoice_id'],
        stagingTableName: 'ttql_stage_3_ledger_transactions',
        injectedDependencies: [
          TtqlDependencyBinding(
            sourceStagingTable: 'ttql_stage_1_invoices',
            sourceColumn: 'invoice_id',
            targetFilterField: 'invoice_id',
          ),
        ],
      );

      final oraSql = dialect.buildQuery(
        step: oraStep,
        foreignKeyLookup: (_, __) => ['inv_5001', 'inv_5002'],
        maxRows: 500,
      );
      expect(oraSql, equals("SELECT account_code, debit, invoice_id FROM ledger_transactions WHERE invoice_id IN ('inv_5001', 'inv_5002') LIMIT 500"));

      const cqlStep = TtqlPlannedStep(
        stepId: 'step_2_join_1',
        stageIndex: 1,
        connectionId: 'scylla_conn',
        engineType: DbEngineType.cassandra,
        targetTableOrCollection: 'device_metrics',
        projectedColumns: ['device_model', 'battery_level', 'customer_id'],
        stagingTableName: 'ttql_stage_2_device_metrics',
        injectedDependencies: [
          TtqlDependencyBinding(
            sourceStagingTable: 'ttql_stage_0_customers',
            sourceColumn: 'customer_id',
            targetFilterField: 'customer_id',
          ),
        ],
      );
      final cqlSql = dialect.buildQuery(
        step: cqlStep,
        foreignKeyLookup: (_, __) => ['cust_101', 'cust_102'],
        maxRows: 500,
      );
      expect(
        cqlSql,
        equals("SELECT device_model, battery_level, customer_id FROM device_metrics WHERE customer_id IN ('cust_101', 'cust_102') LIMIT 500 ALLOW FILTERING"),
      );

      final cqlExpr = SqlExpressionVisitor.translate(
        const TtqlComparisonExpression(fieldName: 'status', operator: '=', rightOperand: 'ACTIVE'),
        DbEngineType.cassandra,
      );
      expect(cqlExpr.sqlClause, equals('status = ?'));

      final pgExpr = SqlExpressionVisitor.translate(
        const TtqlComparisonExpression(fieldName: 'status', operator: '=', rightOperand: 'ACTIVE'),
        DbEngineType.postgres,
      );
      expect(pgExpr.sqlClause, equals('"status" = \$1'));

      final mysqlExpr = SqlExpressionVisitor.translate(
        const TtqlComparisonExpression(fieldName: 'status', operator: '=', rightOperand: 'ACTIVE'),
        DbEngineType.mysql,
      );
      expect(mysqlExpr.sqlClause, equals('`status` = ?'));
    });

    test('TtqlEphemeralStagingDatabase: Resolves uppercase Oracle staged column names case-insensitively', () {
      final staging = TtqlEphemeralStagingDatabase();
      try {
        const steps = [
          TtqlPlannedStep(
            stepId: 'step_0',
            stageIndex: 0,
            connectionId: 'pg',
            engineType: DbEngineType.postgres,
            targetTableOrCollection: 'invoices',
            projectedColumns: ['invoice_id'],
            stagingTableName: 'ttql_stage_0_invoices',
            entityAlias: 'i',
          ),
          TtqlPlannedStep(
            stepId: 'step_1',
            stageIndex: 1,
            connectionId: 'ora',
            engineType: DbEngineType.oracle,
            targetTableOrCollection: 'ledger_transactions',
            projectedColumns: ['account_code', 'debit', 'invoice_id'],
            stagingTableName: 'ttql_stage_1_ledger_transactions',
            entityAlias: 'l',
            joinType: 'leftJoin',
            parentStagingTable: 'ttql_stage_0_invoices',
            parentJoinColumn: 'invoice_id',
            localJoinColumn: 'invoice_id',
          ),
        ];

        staging.createStagingTable('ttql_stage_0_invoices', ['invoice_id']);
        staging.insertStagingRows('ttql_stage_0_invoices', [
          {'invoice_id': 'inv_5001'},
        ]);
        staging.createStagingTable('ttql_stage_1_ledger_transactions', ['ACCOUNT_CODE', 'DEBIT', 'INVOICE_ID']);
        staging.insertStagingRows('ttql_stage_1_ledger_transactions', [
          {'ACCOUNT_CODE': '4000-REV', 'DEBIT': 250.5, 'INVOICE_ID': 'inv_5001'},
        ]);

        final rows = staging.executeFinalSyntheticJoin(
          steps,
          projections: const [
            TtqlColumnProjection(entityAlias: 'i', columnName: 'invoice_id'),
            TtqlColumnProjection(entityAlias: 'l', columnName: 'account_code'),
            TtqlColumnProjection(entityAlias: 'l', columnName: 'debit'),
          ],
        );

        expect(rows.length, equals(1));
        expect(rows.first['invoice_id'], equals('inv_5001'));
      } finally {
        staging.dispose();
      }
    });

    test('TtqlEphemeralStagingDatabase: Sorts NUMERIC decimal strings numerically in ORDER BY', () {
      final staging = TtqlEphemeralStagingDatabase();
      try {
        const steps = [
          TtqlPlannedStep(
            stepId: 'step_0',
            stageIndex: 0,
            connectionId: 'yb',
            engineType: DbEngineType.yugabytedb,
            targetTableOrCollection: 'order_settlements',
            projectedColumns: ['order_id', 'settled_amount'],
            stagingTableName: 'ttql_stage_0_order_settlements',
            entityAlias: 'y',
          ),
        ];

        staging.insertStagingRows('ttql_stage_0_order_settlements', [
          {'order_id': 'ord_904', 'settled_amount': '84.20'},
          {'order_id': 'ord_902', 'settled_amount': '49.99'},
          {'order_id': 'ord_903', 'settled_amount': '389.00'},
          {'order_id': 'ord_906', 'settled_amount': '19.95'},
          {'order_id': 'ord_901', 'settled_amount': '129.50'},
          {'order_id': 'ord_905', 'settled_amount': '1250.00'},
        ]);

        final rows = staging.executeFinalSyntheticJoin(
          steps,
          orderBys: const [
            TtqlOrderByNode(fieldName: 'settled_amount', direction: 'DESC', entityAlias: 'y'),
          ],
          projections: const [
            TtqlColumnProjection(entityAlias: 'y', columnName: 'order_id'),
            TtqlColumnProjection(entityAlias: 'y', columnName: 'settled_amount'),
          ],
        );

        expect(
          rows.map((r) => r['order_id']).toList(),
          equals(['ord_905', 'ord_903', 'ord_901', 'ord_904', 'ord_902', 'ord_906']),
        );
        expect(
          rows.map((r) => r['settled_amount']).toList(),
          equals([1250.0, 389.0, 129.5, 84.2, 49.99, 19.95]),
        );
      } finally {
        staging.dispose();
      }
    });

    test('TtqlEngine: Enforces joined-stage constant WHERE predicate (event_type == eventType) in synthetic join', () async {
      final provider = CliConnectionProvider()
        ..registerConnection(
          id: 'ecommerce_pg',
          name: 'Postgres Ecommerce',
          engineType: DbEngineType.postgres,
          connectionString: 'postgres://localhost/ecommerce',
          schemaOverview: {'customers': ['customer_id', 'full_name']},
          mockData: [
            {'customer_id': 'cust_101', 'full_name': 'Alice Vance'},
            {'customer_id': 'cust_103', 'full_name': 'Carol Danvers'},
            {'customer_id': 'cust_105', 'full_name': 'Emma Watson'},
          ],
        )
        ..registerConnection(
          id: 'analytics_mongo',
          name: 'Mongo Analytics',
          engineType: DbEngineType.mongodb,
          connectionString: 'mongodb://localhost/analytics',
          schemaOverview: {'user_activity_logs': ['customer_id', 'event_type', 'platform']},
          mockData: [
            {'customer_id': 'cust_101', 'event_type': 'checkout_completed', 'platform': 'desktop_windows'},
            {'customer_id': 'cust_103', 'event_type': 'add_to_cart', 'platform': 'ios'},
            {'customer_id': 'cust_105', 'event_type': 'item_reviewed', 'platform': 'android'},
          ],
        );

      const script = '''
const pg = environment.connections.ecommerce_pg;
const mongo = environment.connections.analytics_mongo;
const eventType = 'checkout_completed';

from(pg.customers as c)
  .innerJoin(mongo.user_activity_logs as l, on: c.customer_id == l.customer_id)
  .where(l.event_type == eventType)
  .select([
    c.customer_id,
    c.full_name,
    l.event_type,
    l.platform
  ]);
''';

      final result = await TtqlEngine(connectionProvider: provider).executeScript(script);
      expect(result.totalRowCount, equals(1));
      expect(result.rows.first['customer_id'], equals('cust_101'));
      expect(result.rows.first['event_type'], equals('checkout_completed'));
    });
  });
}

