# 4. Concrete Walkthrough of a Cross-Database Join

[⬅️ 3. File Breakdown](03_file_by_file_breakdown.md) | [Main Index](README.md)

---

## Scenario Overview
Suppose we want to join customer profiles from a **PostgreSQL** database (`ecommerce_pg.customers`) with order shipments from a **MySQL** database (`inventory_mysql.shipments`).

---

## 1. Raw TTQL Query Script

```javascript
// TableTalk Query Language (TTQL) Federated Analytical Query
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

const targetCustomer = 'cust_101';
const customerFields = ['customer_id', 'full_name', 'email'];
const shipmentFields = ['shipment_id', 'order_id'];

select(() => {
    declare asyncRun(() => {
        PostgreSql(pg.id, [...customerFields], pg.tables['customers']),
        MySql(mysql.id, [...shipmentFields, 'customer_id'], mysql.tables['shipments'])
    })
    .where((row) => row.customer_id is targetCustomer)
})
.orderBy(row => row.shipment_id, 'asc')
.limit(10);
```

---

## 2. Generated Remote Queries

### Stage 0: Executed against `@ecommerce_pg` (PostgreSQL)
TTQL translates `PostgreSql(pg.id, ...)` into a native PostgreSQL query:
```sql
SELECT "customer_id", "full_name", "email"
FROM "customers";
```
*Result returned to engine*: 1 customer record:
- `[{customer_id: 'cust_101', full_name: 'Alice Smith', email: 'alice@example.com'}]`

---

### Stage 0 (Parallel): Executed against `@inventory_mysql` (MySQL)
TTQL translates `MySql(mysql.id, ...)` into a native MySQL query:
```sql
SELECT `shipment_id`, `order_id`, `customer_id`
FROM `shipments`;
```
*Result returned to engine*: 1 shipment record:
- `[{shipment_id: 'shp_99', order_id: 'ord_55', customer_id: 'cust_101'}]`

---

## 3. Ephemeral SQLite Staging Schema & Ingestion

Inside `sqlite3.openInMemory()`, TTQL executes the following setup:

```sql
-- Create Staging Table 0 (PostgreSQL customers)
CREATE TABLE "ttql_stage_0_customers" (
  "customer_id" TEXT,
  "full_name" TEXT,
  "email" TEXT
);

-- Bulk Transaction Insert
BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_customers" ("customer_id", "full_name", "email") VALUES ('cust_101', 'Alice Smith', 'alice@example.com');
COMMIT;

-- Create Staging Table 1 (MySQL shipments)
CREATE TABLE "ttql_stage_0_shipments" (
  "shipment_id" TEXT,
  "order_id" TEXT,
  "customer_id" TEXT
);

-- Bulk Transaction Insert
BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_shipments" ("shipment_id", "order_id", "customer_id") VALUES ('shp_99', 'ord_55', 'cust_101');
COMMIT;
```

---

## 4. Synthetic SQL Execution & Final Output

TTQL executes the synthetic join directly against the in-memory SQLite database:

```sql
SELECT 
  "ttql_stage_0_customers"."customer_id" AS "customer_id",
  "ttql_stage_0_customers"."full_name" AS "full_name",
  "ttql_stage_0_customers"."email" AS "email",
  "ttql_stage_0_shipments"."shipment_id" AS "shipment_id",
  "ttql_stage_0_shipments"."order_id" AS "order_id"
FROM "ttql_stage_0_customers"
INNER JOIN "ttql_stage_0_shipments" 
  ON "ttql_stage_0_shipments"."customer_id" = "ttql_stage_0_customers"."customer_id"
WHERE "ttql_stage_0_customers"."customer_id" = 'cust_101'
ORDER BY "ttql_stage_0_shipments"."shipment_id" ASC
LIMIT 10;
```

### Final Returned Result Set:
| customer_id | full_name | email | shipment_id | order_id |
|---|---|---|---|---|
| cust_101 | Alice Smith | alice@example.com | shp_99 | ord_55 |

---

## Teardown & Garbage Collection
Immediately after returning this dataset, `stagingDb.dispose()` is invoked:
- Drops `ttql_stage_0_customers` and `ttql_stage_0_shipments`.
- Closes the C-level SQLite handle (`_db = null`).
- Frees all heap memory allocated during query evaluation.

---

[⬅️ 3. File Breakdown](03_file_by_file_breakdown.md) | [Main Index](README.md)
