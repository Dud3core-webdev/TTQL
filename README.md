# 🛸 TTQL (TableTalk Query Language)

[![Dart CI](https://github.com/tabletalk-io/ttql/actions/workflows/ttql-ci.yml/badge.svg)](https://github.com/tabletalk-io/ttql/actions/workflows/ttql-ci.yml)
[![pub package](https://img.shields.io/pub/v/ttql.svg)](https://pub.dev/packages/ttql)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**TTQL (TableTalk Query Language)** is a sovereign, lightweight, cross-engine federated query engine and AST parser built in pure Dart. It allows developers to run SQL-like analytical queries across heterogeneous databases (**PostgreSQL**, **MySQL**, **SQLite**, **MongoDB**, **Redis**) in a single unified script.

---

## 🌟 Key Features

- ⚡ **Cross-Engine Federated Joins**: Perform declarative relational joins across Relational (PostgreSQL, MySQL, SQLite), Document (MongoDB), and Key-Value (Redis) databases in a single execution.
- 🔒 **100% Read-Only Safety**: Enforces static lexing and parsing security invariants. Mutation operations (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, etc.) throw `TtqlSecurityException` before network sockets open.
- 🧠 **Ephemeral In-Memory Staging Engine**: Spans a transient SQLite `:memory:` database (`sqlite3.openInMemory()`) per query run, ingesting batches and executing synthetic ANSI SQL cross-joins with zero memory leaks.
- ⚙️ **DAG Stage Scheduler**: Constructs execution dependency graphs and throttles concurrent remote connection queries to $\le 3$ per batch stage to prevent socket starvation.
- 💻 **UNIX-Composable CLI Tool**: Execute scripts directly from terminal environments and CI/CD automation pipelines (`ttql lint`, `ttql plan`, `ttql run`).

---

## 🚀 Quickstart & Installation

### Option A: Install via Pub CLI
```bash
dart pub global activate ttql
```

### Option B: Run via Source Repository
```bash
git clone https://github.com/tabletalk-io/ttql.git
cd ttql
dart pub get
```

---

## 🖥️ Command Line Usage (`ttql`)

The `ttql` executable provides subcommands matching industry-standard tools:

### 1. Static Linting & Read-Only Check (`ttql lint`)
Lints syntax and validates security invariants offline without opening database sockets:
```bash
ttql lint path/to/script.ttql
```

### 2. Execution Plan Inspector (`ttql plan`)
Inspects the Directed Acyclic Graph (DAG) stages, target database engines, and ephemeral staging tables:
```bash
ttql plan path/to/script.ttql
```

### 3. Live Query Execution (`ttql run`)
Executes the analytical query script and formats the result set:
```bash
# Tabular ASCII Grid Output
ttql run path/to/script.ttql --config connections.json --format table

# Formatted JSON Output (UNIX Piping)
ttql run path/to/script.ttql --config connections.json --format json | jq .

# Comma-Separated Values (CSV) Export
ttql run path/to/script.ttql --config connections.json --format csv > results.csv
```

### 4. Language Server Protocol (`ttql lsp`)
Spins up the JSON-RPC 2.0 Language Server communicating over standard input/output (`stdio`) for real-time IDE diagnostics and linting:
```bash
ttql lsp
```

---

## ⚙️ Connection Configuration JSON Schema (`--config`)

When running scripts via `ttql run`, provide database connection strings or offline mock records in a JSON file:

```json
{
  "connections": [
    {
      "id": "ecommerce_pg",
      "name": "PostgreSQL E-Commerce",
      "engine": "postgres",
      "connectionString": "postgres://${PG_USER}:${PG_PASS}@localhost:5434/ecommerce_pg",
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

- **Environment Variable Expansion**: Passwords and URIs can use `${VAR_NAME}` placeholders resolved dynamically at runtime.
- **Offline Mock Execution**: Including `mockData` allows testing queries and synthetic joins without requiring network access to live databases.

---

## 💻 VS Code & Antigravity IDE Extension

For rich syntax highlighting, auto-completion, and real-time inline diagnostics in your editor, see the [**TTQL VS Code Extension**](../../editors/vscode/README.md).


## 📝 Programmatic Usage in Dart

You can also embed `package:ttql` directly into your Dart/Flutter applications:

```dart
import 'package:ttql/ttql.dart';

void main() async {
  final source = '''
    const pg = environment.connections.ecommerce_pg;
    const mysql = environment.connections.inventory_mysql;
    const targetCustomer = 'cust_101';
    const customerFields = ['customer_id', 'full_name', 'email'];

    select(() => {
        declare asyncRun(() => {
            PostgreSql(pg.id, [...customerFields], pg.tables['customers']),
            MySql(mysql.id, ['shipment_id', 'order_id', 'customer_id'], mysql.tables['shipments'])
        })
        .where((row) => row.customer_id is targetCustomer)
    })
    .orderBy(row => row.customer_id, 'asc')
    .limit(10);
  ''';

  final engine = TtqlEngine(connectionProvider: myConnectionProvider);
  final result = await engine.executeScript(source);

  for (final row in result.rows) {
    print(row);
  }
}
```

---

## 📖 Technical Compiler Architecture Wiki

For an in-depth breakdown of lexing, AST nodes, DAG planning, and ephemeral staging, view the modular technical wiki:
- [**TTQL Architecture Wiki Index**](doc/wiki/README.md)
  - [1. High-Level Concept & The "Why"](doc/wiki/01_high_level_concept.md)
  - [2. End-to-End Pipeline ASCII Architecture](doc/wiki/02_pipeline_architecture.md)
  - [3. File-by-File Technical Breakdown](doc/wiki/03_file_by_file_breakdown.md)
  - [4. Concrete Walkthrough of a Cross-Database Join](doc/wiki/04_cross_db_join_walkthrough.md)

---

## 📜 License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for details.
