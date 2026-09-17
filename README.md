# TTQL (TableTalk Query Language)

[![Dart CI](https://github.com/tabletalk-io/ttql/actions/workflows/ttql-ci.yml/badge.svg)](https://github.com/tabletalk-io/ttql/actions/workflows/ttql-ci.yml)
[![pub package](https://img.shields.io/pub/v/ttql.svg)](https://pub.dev/packages/ttql)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

TTQL (TableTalk Query Language) is a federated, cross-database query engine and AST parser written in pure Dart. It enables executing read-only analytical queries that join data across heterogeneous database systems (PostgreSQL, MySQL, SQLite, MongoDB, Redis) in a single script.

---

## Key Features

- **Federated Cross-Engine Joins**: Execute declarative joins across relational databases (PostgreSQL, MySQL, SQLite), document stores (MongoDB), and key-value stores (Redis) in one query.
- **Read-Only Safety**: Lexical and AST validation reject mutation operations (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, etc.) before any network connection or query execution occurs.
- **In-Memory SQLite Staging**: Uses an ephemeral in-memory SQLite database (`sqlite3.openInMemory()`) to stage intermediate datasets and compute relational joins.
- **DAG Execution Planner**: Constructs dependency graphs to schedule independent queries in parallel while throttling concurrent connections per stage (default batch limit: 3).
- **Command-Line Interface**: Run queries, inspect execution plans, lint scripts, or launch a Language Server Protocol (LSP) daemon (`ttql lint`, `ttql plan`, `ttql run`, `ttql lsp`).

---

## 📚 Documentation

- ⚡ **[Developer Syntax Guide](doc/SYNTAX_GUIDE.md)**: Rich, developer-friendly cheat sheet, pipeline diagrams, operators, and copy-paste recipes.
- 📖 **[Official Language Manual & Specification](doc/TTQL_LANGUAGE_MANUAL.md)**: Comprehensive reference manual, pushdown mechanics, and formal EBNF grammar.
- 🏛️ **[Compiler Architecture Wiki](TTQL_COMPILER_WIKI.md)**: Deep dive into the frontend compiler, DAG optimizer, and ephemeral staging engine.

## Installation

### Via Pub

```bash
dart pub global activate ttql
```

### From Source

```bash
git clone https://github.com/tabletalk-io/ttql.git
cd ttql
dart pub get
```

---

## Command Line Usage

The `ttql` executable provides commands for validation, inspection, and execution:

### 1. Static Linting (`ttql lint`)

Validates script syntax and checks for forbidden mutation keywords without connecting to any database:

```bash
ttql lint path/to/script.ttql
```

### 2. Execution Plan Inspection (`ttql plan`)

Displays the Directed Acyclic Graph (DAG) stages, target database engines, and staging tables:

```bash
ttql plan path/to/script.ttql
```

### 3. Query Execution (`ttql run`)

Executes the query script and formats the results:

```bash
# Tabular output
ttql run path/to/script.ttql --config connections.json --format table

# JSON output
ttql run path/to/script.ttql --config connections.json --format json

# CSV export
ttql run path/to/script.ttql --config connections.json --format csv > results.csv
```

### 4. Language Server Protocol (`ttql lsp`)

Starts the JSON-RPC 2.0 Language Server over standard input/output (`stdio`) for IDE diagnostics and completion:

```bash
ttql lsp
```

---

## Connection Configuration (`--config`)

Query execution requires a JSON configuration file specifying connection strings or offline mock data:

```json
{
  "connections": [
    {
      "id": "ecommerce_pg",
      "name": "PostgreSQL E-Commerce",
      "engine": "postgres",
      "connectionString": "postgres://${PG_USER}:${PG_PASS}@localhost:5432/ecommerce_pg",
      "schemaOverview": {
        "customers": ["customer_id", "full_name", "email"]
      },
      "mockData": [
        { "customer_id": "cust_101", "full_name": "Alice Vance", "email": "alice@tabletalk.io" },
        { "customer_id": "cust_102", "full_name": "Bob Smith", "email": "bob.smith@techcorp.dev" }
      ]
    }
  ]
}
```

- **Environment Variable Expansion**: `${VAR_NAME}` placeholders in connection strings are resolved from the environment at runtime.
- **Offline Mock Execution**: Defining `mockData` allows evaluating scripts and testing joins without live database connections.

---

## Editor Support

Syntax highlighting, diagnostic linting, and completion support for VS Code and compatible editors is available in the [TTQL VS Code Extension](editors/vscode/README.md).

---

## Programmatic Usage in Dart

`package:ttql` can be integrated directly into Dart applications:

```dart
import 'package:ttql/ttql.dart';

void main() async {
  final script = '''
    const pg = environment.connections.ecommerce_pg;
    const mysql = environment.connections.inventory_mysql;
    const targetCustomer = 'cust_101';
    const customerFields = ['customer_id', 'full_name', 'email'];

    from(pg.customers)
      .select([...customerFields])
      .where(customer_id == targetCustomer)
      .innerJoin(mysql.shipments, on: 'customer_id')
      .select('shipment_id', 'order_id')
      .orderBy(customer_id, 'ASC')
      .limit(10);
  ''';

  final engine = TtqlEngine(connectionProvider: myConnectionProvider);
  final result = await engine.executeScript(script);

  for (final row in result.rows) {
    print(row);
  }
}
```

---

## Fluent Query Pipeline

TTQL features an ergonomic fluent chaining pipeline:

```ttql
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: c.customer_id == s.customer_id)
  .where(s.status == 'in_transit' && c.country == 'US')
  .groupBy(c.country)
  .select([
    c.country,
    count() as shipment_count
  ])
  .having(shipment_count > 5)
  .orderBy(shipment_count, 'DESC')
  .limit(20)
  .offset(0);
```

For the exhaustive specification, formal EBNF grammar, and real-world recipes, read the [Official TTQL Language Manual](doc/TTQL_LANGUAGE_MANUAL.md).

---

## Architecture Documentation

For details on the compiler pipeline, AST representation, DAG planner, and staging database:

- [Official TTQL Language Manual](doc/TTQL_LANGUAGE_MANUAL.md) - The complete language specification and cookbook.
- [Architecture Wiki Index](doc/wiki/README.md)
  - [1. High-Level Concept](doc/wiki/01_high_level_concept.md)
  - [2. Pipeline Architecture](doc/wiki/02_pipeline_architecture.md)
  - [3. File Breakdown](doc/wiki/03_file_by_file_breakdown.md)
  - [4. Cross-Database Join Walkthrough](doc/wiki/04_cross_db_join_walkthrough.md)

---

## License

MIT License. See [LICENSE](LICENSE) for details.
