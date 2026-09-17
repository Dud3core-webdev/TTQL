# 4. Cross-Database Join Walkthrough

[Back: File Breakdown](03_file_by_file_breakdown.md) | [Main Index](README.md)

---

## Scenario Overview

This walkthrough demonstrates how TTQL executes a join between customer profiles stored in PostgreSQL (`ecommerce_pg.customers`) and order shipments stored in MySQL (`inventory_mysql.shipments`).

---

## 1. Input TTQL Script

```ttql
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;

const targetCustomer = 'cust_101';
const customerFields = ['customer_id', 'full_name', 'email'];
const shipmentFields = ['shipment_id', 'order_id'];

from(pg.customers)
  .select([...customerFields])
  .where(customer_id == targetCustomer)
  .innerJoin(mysql.shipments, on: 'customer_id')
  .select([...shipmentFields])
  .orderBy(shipment_id, 'ASC')
  .limit(10);
```

---

## 2. Generated Remote Queries

### Stage 0: Executed against `@ecommerce_pg` (PostgreSQL)

TTQL translates the root stage into a native PostgreSQL query:

```sql
SELECT "customer_id", "full_name", "email"
FROM "customers";
```

Returned row:
```json
[{"customer_id": "cust_101", "full_name": "Alice Smith", "email": "alice@example.com"}]
```

### Stage 0: Executed against `@inventory_mysql` (MySQL, Parallel)

TTQL translates the `MySql` node into a native MySQL query:

```sql
SELECT `shipment_id`, `order_id`, `customer_id`
FROM `shipments`;
```

Returned row:
```json
[{"shipment_id": "shp_99", "order_id": "ord_55", "customer_id": "cust_101"}]
```

---

## 3. In-Memory SQLite Staging & Ingestion

Inside the temporary SQLite database (`sqlite3.openInMemory()`), TTQL creates staging tables and inserts the received records in a single transaction per table:

```sql
CREATE TABLE "ttql_stage_0_customers" (
  "customer_id" TEXT,
  "full_name" TEXT,
  "email" TEXT
);

BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_customers" ("customer_id", "full_name", "email")
VALUES ('cust_101', 'Alice Smith', 'alice@example.com');
COMMIT;

CREATE TABLE "ttql_stage_0_shipments" (
  "shipment_id" TEXT,
  "order_id" TEXT,
  "customer_id" TEXT
);

BEGIN TRANSACTION;
INSERT INTO "ttql_stage_0_shipments" ("shipment_id", "order_id", "customer_id")
VALUES ('shp_99', 'ord_55', 'cust_101');
COMMIT;
```

---

## 4. Synthetic SQL Execution

TTQL executes the synthetic join directly against SQLite:

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

### Output Result Set

| customer_id | full_name | email | shipment_id | order_id |
|---|---|---|---|---|
| cust_101 | Alice Smith | alice@example.com | shp_99 | ord_55 |

---

## Cleanup

Upon query completion, `stagingDb.dispose()` closes the temporary SQLite database handle, releasing all staging tables and allocated memory.

---

[Back: File Breakdown](03_file_by_file_breakdown.md) | [Main Index](README.md)
