import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:ttql/formatters/cli_result_formatter.dart';
import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/services/cli_connection_provider.dart';
import 'package:ttql/services/ttql_dag_planner.dart';
import 'package:ttql/services/ttql_engine.dart';
import 'package:ttql/services/ttql_environment_builder.dart';
import 'package:ttql/services/ttql_lexer.dart';
import 'package:ttql/services/ttql_linter.dart';
import 'package:ttql/services/ttql_lsp_server.dart';
import 'package:ttql/services/ttql_parser.dart';

void main(List<String> args) async {
  final runner = CommandRunner<int>(
    'ttql',
    'TableTalk Query Language (TTQL) - Standalone CLI Analytical Query Runner & Linter.',
  )
    ..addCommand(LintCommand())
    ..addCommand(PlanCommand())
    ..addCommand(RunCommand())
    ..addCommand(LspCommand());

  try {
    final exitCode = await runner.run(args);
    if (exitCode != null) {
      exit(exitCode);
    }
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(2);
  } catch (e) {
    stderr.writeln('CLI Error: $e');
    exit(1);
  }
}

/// Helper to read script source from file or stdin.
String _readScriptSource(String scriptPath) {
  if (scriptPath == '-') {
    return stdin.readLineSync() ?? '';
  }
  final file = File(scriptPath);
  if (!file.existsSync()) {
    throw FileSystemException('TTQL Script file not found', scriptPath);
  }
  return file.readAsStringSync();
}

/// Helper to build a CLI connection provider from config path or default fallback.
CliConnectionProvider _buildConnectionProvider(String? configPath) {
  final provider = CliConnectionProvider();
  if (configPath != null) {
    final configFile = File(configPath);
    provider.loadFromConfigFile(configFile);
  } else if (File('connections.json').existsSync()) {
    provider.loadFromConfigFile(File('connections.json'));
  } else {
    // Default fallback mock connection
    provider.registerConnection(
      id: 'default_db',
      name: 'Default Database Connection',
      engineType: DbEngineType.sqlite,
      connectionString: ':memory:',
      schemaOverview: {},
    );
  }
  return provider;
}

/// `ttql lint <script.ttql>`
class LintCommand extends Command<int> {
  @override
  final String name = 'lint';

  @override
  final String description = 'Perform static lexing, parsing, and 100% read-only security invariant validation on a TTQL script.';

  LintCommand();

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('Error: Missing script file path. Usage: ttql lint <script.ttql>');
      return 2;
    }

    final scriptPath = argResults!.rest.first;
    final source = _readScriptSource(scriptPath);

    final linter = const TtqlLinter();
    final diagnostics = linter.lint(source);

    if (diagnostics.isNotEmpty) {
      stderr.writeln('❌ TTQL Lint Violations Found (${diagnostics.length}):');
      for (final diag in diagnostics) {
        stderr.writeln('   - $diag');
      }
      return 2; // POSIX 2: Lint/Syntax violation
    }

    stdout.writeln('✔ TTQL Script is valid and 100% read-only.');
    return 0; // POSIX 0: Success
  }
}

/// `ttql plan <script.ttql>`
class PlanCommand extends Command<int> {
  @override
  final String name = 'plan';

  @override
  final String description = 'Inspect execution DAG stages, target engines, and ephemeral staging table names without opening live database sockets.';

  PlanCommand() {
    argParser.addOption('config', abbr: 'c', help: 'Path to connections.json configuration file.');
  }

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('Error: Missing script file path. Usage: ttql plan <script.ttql>');
      return 2;
    }

    final scriptPath = argResults!.rest.first;
    final source = _readScriptSource(scriptPath);
    final configPath = argResults!['config'] as String?;

    final provider = _buildConnectionProvider(configPath);

    final tokens = TtqlLexer(source).tokenize();
    final parser = TtqlParser(tokens);
    final ast = parser.parse();

    final envContext = TtqlEnvironmentBuilder(connectionProvider: provider).buildContext();
    final planner = TtqlDagPlanner(environmentContext: envContext);
    final plan = planner.plan(ast);

    stdout.writeln('=== TTQL Directed Acyclic Graph (DAG) Execution Plan ===');
    stdout.writeln('Total Stages: ${plan.stages.length}');
    stdout.writeln();

    for (final entry in plan.stages.entries) {
      stdout.writeln('Stage ${entry.key}:');
      for (final step in entry.value) {
        stdout.writeln('  • Step ID: ${step.stepId}');
        stdout.writeln('    Target Engine: ${step.engineType.name}');
        stdout.writeln('    Connection ID: ${step.connectionId}');
        stdout.writeln('    Target Table:  ${step.targetTableOrCollection}');
        stdout.writeln('    Staging Table: ${step.stagingTableName}');
        stdout.writeln('    Projected Cols: ${step.projectedColumns.join(", ")}');
      }
      stdout.writeln();
    }

    return 0;
  }
}

/// `ttql run <script.ttql> --format table|json|csv --config connections.json`
class RunCommand extends Command<int> {
  @override
  final String name = 'run';

  @override
  final String description = 'Execute a TTQL analytical script and format output result set.';

  RunCommand() {
    argParser.addOption(
      'format',
      abbr: 'f',
      defaultsTo: 'table',
      allowed: ['table', 'json', 'csv'],
      help: 'Output result set formatting style.',
    );
    argParser.addOption('config', abbr: 'c', help: 'Path to connections.json configuration file.');
    argParser.addFlag('verbose', abbr: 'v', negatable: false, help: 'Enable detailed execution logs.');
  }

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('Error: Missing script file path. Usage: ttql run <script.ttql>');
      return 2;
    }

    final scriptPath = argResults!.rest.first;
    final source = _readScriptSource(scriptPath);
    final formatStyle = argResults!['format'] as String;
    final configPath = argResults!['config'] as String?;
    final verbose = argResults!['verbose'] as bool;

    // 1. Lint check
    final linter = const TtqlLinter();
    final diagnostics = linter.lint(source);
    if (diagnostics.isNotEmpty) {
      stderr.writeln('❌ TTQL Execution Aborted. Syntax or security violations found:');
      for (final diag in diagnostics) {
        stderr.writeln('   - $diag');
      }
      return 2;
    }

    // 2. Build Connection Provider & Engine
    final provider = _buildConnectionProvider(configPath);
    final engine = TtqlEngine(connectionProvider: provider);

    if (verbose) {
      stdout.writeln('[TTQL CLI Driver] Loaded ${provider.activeConnectionIds.length} active connection definitions.');
      stdout.writeln('[TTQL CLI Driver] Executing script pipeline...');
    }

    // 3. Execute Script
    try {
      final result = await engine.executeScript(source);
      final formatter = CliResultFormatter.forType(formatStyle);
      final output = formatter.format(result.rows);

      stdout.write(output);
      if (!output.endsWith('\n')) stdout.writeln();

      return 0;
    } catch (e) {
      stderr.writeln('❌ TTQL Execution Failure: $e');
      return 1; // POSIX 1: Execution failure
    }
  }
}

/// Command to start the native Language Server Protocol (LSP) background service.
class LspCommand extends Command<int> {
  @override
  final name = 'lsp';

  @override
  final description = 'Start the TTQL Language Server Protocol (LSP) background process for real-time IDE diagnostics.';

  LspCommand() {
    argParser.addOption(
      'config',
      abbr: 'c',
      help: 'Path to connections configuration file (e.g. connections.json)',
    );
  }

  @override
  Future<int> run() async {
    final configPath = argResults!['config'] as String?;
    final lspServer = TtqlLspServer(configPath: configPath);

    await lspServer.start();
    return 0;
  }
}

