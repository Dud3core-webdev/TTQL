# TTQL Example Queries

Showcase query scripts and configuration templates demonstrating **TTQL (TableTalk Query Language)** cross-database federated analytics.

---

## 📁 Files in this Directory

- `cross_db_analytics.ttql`: Demonstrates an authentic cross-database join between PostgreSQL (`ecommerce_pg.customers`) and MySQL (`inventory_mysql.shipments`).
- `connections.json.example`: Connection configuration template with environment variable expansion (`${PG_PASS}`, `${MYSQL_PASS}`, etc.).

---

## 🚀 Running the Examples

From the `packages/ttql` directory:

### 1. Static Linting (Validates AST & Read-Only Safety)
```bash
dart run bin/ttql.dart lint example/cross_db_analytics.ttql
```

### 2. DAG Execution Plan Inspection
```bash
dart run bin/ttql.dart plan example/cross_db_analytics.ttql
```

### 3. Live Execution
Ensure the test databases are seeded with `./scripts/dev.ps1 db seed` (or `./scripts/dev.sh db seed`), then:
```bash
cp example/connections.json.example connections.json

# Tabular ASCII Table
dart run bin/ttql.dart run example/cross_db_analytics.ttql --config connections.json --format table

# Formatted JSON (Pipeable to jq)
dart run bin/ttql.dart run example/cross_db_analytics.ttql --config connections.json --format json

# CSV Output
dart run bin/ttql.dart run example/cross_db_analytics.ttql --config connections.json --format csv
```
