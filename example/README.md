# TTQL Example Queries

Sample query scripts and configuration templates for **TTQL (TableTalk Query Language)**.

---

## Files

- `cross_db_analytics.ttql`: Example query script joining data across PostgreSQL (`ecommerce_pg.customers`) and MySQL (`inventory_mysql.shipments`).
- `connections.json.example`: Example connection configuration file including mock data and environment variable templates (`${PG_PASS}`, `${MYSQL_PASS}`).

---

## Running the Examples

Run all commands from the repository root:

### 1. Static Linting

Validates syntax and verifies that no mutation keywords are used:

```bash
dart run bin/ttql.dart lint example/cross_db_analytics.ttql
```

### 2. Execution Plan Inspection

Inspects the query execution stages and target databases:

```bash
dart run bin/ttql.dart plan example/cross_db_analytics.ttql
```

### 3. Execution

Copy the example configuration to `connections.json`:

```bash
cp example/connections.json.example connections.json
```

Because `connections.json.example` includes `mockData`, the example runs out of the box without requiring live database connections:

```bash
# Tabular output
dart run bin/ttql.dart run example/cross_db_analytics.ttql --config connections.json --format table

# JSON output
dart run bin/ttql.dart run example/cross_db_analytics.ttql --config connections.json --format json

# CSV output
dart run bin/ttql.dart run example/cross_db_analytics.ttql --config connections.json --format csv
```

To run against live databases, edit `connections.json` with your database credentials or set the referenced environment variables.
