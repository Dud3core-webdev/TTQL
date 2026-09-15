import 'package:ttql/ttql.dart';

void main() async {
  print('=== TableTalk Query Language (TTQL) Engine Demo ===\n');

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

  print('1. Tokenizing and Parsing Script...');
  final lexer = TtqlLexer(sampleScript);
  final tokens = lexer.tokenize();
  print('-> Tokenized ${tokens.length} tokens.');

  final parser = TtqlParser(tokens);
  final ast = parser.parse();
  print('-> Parsed AST with ${ast.rootInvocations.length} root database invocations.');

  print('\n2. Linting Script...');
  const linter = TtqlLinter();
  final diagnostics = linter.lint(sampleScript);
  if (diagnostics.isEmpty) {
    print('-> 0 lint errors found.');
  } else {
    for (final d in diagnostics) {
      print('   [${d.severity}] ${d.message}');
    }
  }

  print('\n3. Planning DAG Execution Stages...');
  const planner = TtqlDagPlanner();
  final plan = planner.plan(ast);
  print('-> Planned ${plan.stages.length} execution stages.');
  plan.stages.forEach((stageIndex, steps) {
    print('   Stage $stageIndex contains ${steps.length} parallel queries:');
    for (final step in steps) {
      print('     - ${step.engineType.name} on table: ${step.targetTableOrCollection}');
    }
  });

  print('\n4. Registering Mock Data Connections...');
  final provider = CliConnectionProvider();
  provider.registerConnection(
    id: 'test_pg',
    name: 'PostgreSQL Production',
    engineType: DbEngineType.postgres,
    connectionString: 'postgres://user:secret@localhost:5432/main',
    schemaOverview: {
      'customers': ['customer_id', 'full_name', 'email']
    },
    mockData: [
      {
        'customer_id': 'cust_101',
        'full_name': 'Alice Smith',
        'email': 'alice@example.com'
      },
    ],
  );

  provider.registerConnection(
    id: 'test_mysql',
    name: 'MySQL Logistics',
    engineType: DbEngineType.mysql,
    connectionString: 'mysql://user:secret@localhost:3306/logistics',
    schemaOverview: {
      'shipments': ['shipment_id', 'order_id', 'customer_id']
    },
    mockData: [
      {
        'shipment_id': 'shp_99',
        'order_id': 'ord_501',
        'customer_id': 'cust_101'
      },
    ],
  );

  print('-> Registered ${provider.activeConnectionIds.length} data connections.');

  print('\n5. Executing Engine Pipeline...');
  final engine = TtqlEngine(connectionProvider: provider);
  final executionResult = await engine.executeScript(sampleScript);
  print('-> Stages Executed: ${executionResult.stagesExecuted}');
  print('-> Returned ${executionResult.rows.length} joined rows in ${executionResult.executionDurationMs}ms:');

  const formatter = TableResultFormatter();
  print(formatter.format(executionResult.rows));
}
