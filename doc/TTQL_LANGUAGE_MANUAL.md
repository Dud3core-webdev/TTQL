# TableTalk Query Language (TTQL)
## Official Language Manual & Specification

---

## 1. Executive Overview

**TableTalk Query Language (TTQL)** is a domain-neutral, type-safe, federated query language engineered to execute read-only analytical queries across heterogeneous database engines (PostgreSQL, MySQL, MongoDB, Redis, SQLite, DuckDB, CockroachDB, and more) in a single unified script.

Unlike traditional SQL dialects tied to a single database server, or heavy distributed query engines requiring multi-node Java/JVM clusters (such as Presto or Trino), TTQL operates as a lightweight, embeddable, airgapped compiler and execution runtime. It pushes query predicates and projections down to native databases, stages intermediate results in an ephemeral in-memory relational engine, and synthesizes cross-engine joins, aggregations, and pagination with sub-millisecond overhead.

```
┌─────────────────────────────────────────────────────────────┐
│                       TTQL Script                           │
│  from(pg.customers as c)                                    │
│    .innerJoin(mysql.orders as o, on: c.id == o.customer_id) │
│    .groupBy(c.country)                                      │
│    .select([c.country, sum(o.amount) as total_rev])         │
│    .having(count() > 5)                                     │
│    .orderBy(total_rev, 'DESC')                              │
│    .limit(10)                                               │
└──────────────────────────────┬──────────────────────────────┘
                               │
                [ Lexer -> Parser -> AST ]
                               │
               [ TtqlDagPlanner & Optimizer ]
                               │
               ┌───────────────┴───────────────┐
               ▼                               ▼
    [ Stage 0: PostgreSQL ]        [ Stage 1: MySQL ]
     Pushdown SELECT + WHERE       Injected FK IN (...)
               │                               │
               └───────────────┬───────────────┘
                               │
             [ Ephemeral SQLite :memory: Staging ]
        Relational Join + GROUP BY + HAVING + ORDER BY
                               │
                               ▼
                 [ Normalized Result Set ]
```

---

## 2. Design Philosophy & Core Invariants

### 2.1 The Read-Only Security Invariant
TTQL is strictly an **analytical retrieval language**. Mutation operations are architecturally forbidden:
- Any occurrence of mutating keywords (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `REPLACE`, `CREATE`, `GRANT`, `REVOKE`, `UPSERT`, `FLUSHDB`, etc.) is quarantined and rejected at both lexical analysis time and AST construction.
- Violations trigger an immediate `TtqlSecurityException`.

### 2.2 Airgapped Environment Context
TTQL scripts never contain raw passwords, secrets, or connection strings. All connection targets are referenced via abstract aliases (`environment.connections.<alias>`), resolving to descriptors managed securely by the host application.

### 2.3 Zero-Memory-Leak Disposable Staging
Cross-database federation relies on disposable in-memory SQLite instances (`:memory:`). The lifecycle of each staging database is bound strictly to the duration of the query execution. Upon query completion or error, the staging database is forcibly disposed, ensuring zero memory leaks.

---

## 3. Environment Declarations & Constants

A TTQL script begins with optional declarations of connection aliases and literal constants.

### 3.1 Connection Aliases
Connections configure which physical databases participate in the query.
```ttql
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.inventory_mysql;
const mongo = environment.connections.analytics_mongo;
```

### 3.2 Literal Constants
Constants define reusable values for filters, limits, and array predicates.
```ttql
const maxThreshold = 1000;
const defaultPageSize = 25;
const targetStatus = 'completed';
```

### 3.3 List Constants & The Spread Operator (`...`)
Lists of values can be declared and unpacked into filter predicates or projection arrays using the `...` spread operator:
```ttql
const priorityTiers = ['enterprise', 'vip', 'government'];
const standardColumns = ['customer_id', 'full_name', 'email'];

from(pg.customers)
  .select([...standardColumns, 'account_balance'])
  .where(tier IN [...priorityTiers]);
```

---

## 4. Modern Fluent Pipeline (Specification)

The fluent pipeline is TTQL's primary syntax. Every query flows sequentially from a root data source through joins, filters, grouping, projections, ordering, and pagination.

```ttql
from(dataSource)
  [.as('alias')]
  [.innerJoin(...) | .leftJoin(...) | .rightJoin(...) | .fullOuterJoin(...)]
  [.where(...)]
  [.groupBy(...)]
  [.select(...)]
  [.having(...)]
  [.orderBy(...)]
  [.limit(...)]
  [.offset(...) | .skip(...)];
```

### 4.1 Data Source (`from`)
Specifies the primary root table and optional inline alias:
```ttql
from(pg.customers)
from(pg.customers as c)
from(pg.customers).as('c')
from(pg.tables['customers'])
```

### 4.2 Projections (`.select(...)`)
Controls which columns and computed aggregates appear in the final result set.

#### A. Column List
```ttql
from(pg.customers)
  .select('customer_id', 'full_name', 'email');

// Array notation:
from(pg.customers)
  .select(['customer_id', 'full_name', 'email']);
```

#### B. Column Aliasing (`as`)
```ttql
from(pg.customers as c)
  .select([
    c.customer_id as id,
    c.full_name as client_name,
    c.email as contact_email
  ]);
```

#### C. Implicit Wildcard Projections
If `.select(...)` is omitted, TTQL automatically defaults to projecting all available columns (`SELECT *`):
```ttql
from(pg.customers)
  .where(status == 'active');
```

---

### 4.3 Filtering (`.where(...)`)
Specifies row-level filter predicates. TTQL automatically pushes down filter expressions to the source database engine whenever possible.

#### A. Comparison Operators
| Operator | Alternative | Semantics |
|---|---|---|
| `==` | `=` | Strict equality |
| `!=` | `<>` | Inequality |
| `<` | | Less than |
| `<=` | | Less than or equal |
| `>` | | Greater than |
| `>=` | | Greater than or equal |
| `LIKE` | | String pattern match (`%` wildcard) |
| `NOT LIKE` | | Negated pattern match |
| `IN` | | Set inclusion |
| `NOT IN` | | Set exclusion |
| `is null` | `== null` | Null check |
| `is not null` | `!= null` | Non-null check |

#### B. Logical Conjunctions
Predicates can be combined with `&&` (`AND`), `||` (`OR`), and `!` (`NOT`), with explicit parentheses:
```ttql
from(pg.orders)
  .where((status == 'delivered' || status == 'shipped') && total_amount >= 100);
```

#### C. Arrow Function Syntax
Where clauses can optionally accept lambda arrow parameter syntax:
```ttql
from(pg.orders as o)
  .where(o => o.status == 'delivered' && o.total_amount > 500);
```

#### D. Table Qualifier Disambiguation
When querying across joined tables, field references can be qualified by table name or alias to route pushdown predicates to the correct database:
```ttql
from(pg.customers as c)
  .innerJoin(mysql.orders as o, on: c.id == o.customer_id)
  .where(c.country == 'US' && o.total_amount > 250);
```

---

### 4.4 Relational Joins
TTQL supports federated joins across completely different database vendors. The execution runtime resolves parent dependencies, extracts foreign keys, injects them into downstream queries, and synthesizes the join in the staging database.

#### Supported Join Types
- `.innerJoin(target, on: condition)`
- `.leftJoin(target, on: condition)`
- `.rightJoin(target, on: condition)`
- `.fullOuterJoin(target, on: condition)`

#### A. Short-Form Equijoins (`on: 'common_column'`)
When both tables share the same join key name:
```ttql
from(pg.customers)
  .innerJoin(mysql.orders, on: 'customer_id');
```

#### B. Qualified Key Predicates
When keys have different names across databases:
```ttql
from(pg.customers as c)
  .innerJoin(mysql.orders as o, on: c.id == o.client_id);
```

#### C. Chained Multi-Join Pipelines
```ttql
from(pg.customers as c)
  .innerJoin(mysql.orders as o, on: c.id == o.customer_id)
  .leftJoin(mongo.audit_logs as a, on: o.id == a.order_id);
```

---

### 4.5 Grouping (`.groupBy(...)`)
Groups rows that share the same values in specified summary columns:
```ttql
from(pg.orders)
  .groupBy('status');

// Multi-column grouping:
from(pg.orders as o)
  .groupBy(o.customer_id, o.status);

// Arrow function syntax:
from(pg.orders as o)
  .groupBy(o => o.status);
```

---

### 4.6 Built-in Aggregation Functions
When used with `.groupBy(...)`, aggregate functions calculate summary metrics across rows:

| Function | Signature | Description |
|---|---|---|
| `count()` | `count()` or `count(*)` or `count(col)` | Total number of rows |
| `sum(col)` | `sum(numeric_column)` | Mathematical summation |
| `avg(col)` | `avg(numeric_column)` | Arithmetic mean |
| `min(col)` | `min(column)` | Minimum value |
| `max(col)` | `max(column)` | Maximum value |

```ttql
from(pg.orders as o)
  .groupBy(o.status)
  .select([
    o.status,
    count() as order_count,
    sum(o.total_amount) as total_revenue,
    avg(o.total_amount) as average_order_value,
    min(o.total_amount) as smallest_order,
    max(o.total_amount) as largest_order
  ]);
```

---

### 4.7 Post-Aggregation Filtering (`.having(...)`)
Filters the grouped aggregate results. Unlike `.where(...)` which filters raw rows prior to aggregation, `.having(...)` filters after summary calculations:
```ttql
from(pg.orders as o)
  .groupBy(o.status)
  .select([
    o.status,
    count() as order_count,
    sum(o.total_amount) as total_revenue
  ])
  .having(count() > 10 && total_revenue >= 5000);
```

---

### 4.8 Sorting & Ordering (`.orderBy(...)`)
Sorts the final result set in ascending (`ASC`) or descending (`DESC`) direction.

#### A. Single Column Sort
```ttql
from(pg.orders)
  .orderBy('created_at', 'DESC');
```

#### B. Chained Multi-Column Sort
```ttql
from(pg.orders)
  .orderBy('status', 'ASC')
  .orderBy('created_at', 'DESC');
```

#### C. Multi-Column Parameterized Sort
```ttql
from(pg.orders)
  .orderBy('status', 'ASC', 'total_amount', 'DESC');
```

---

### 4.9 Pagination (`.limit(...)`, `.offset(...)`, `.skip(...)`)
Restricts the volume of returned rows and offsets the starting record for deterministic pagination:
```ttql
from(pg.customers)
  .orderBy('created_at', 'DESC')
  .limit(25)
  .offset(50); // or .skip(50)
```

Pagination parameters can be driven dynamically by declared constants:
```ttql
const pageSize = 20;
const pageNumber = 3;
const offsetRows = 40;

from(pg.orders)
  .orderBy('order_date', 'DESC')
  .limit(pageSize)
  .offset(offsetRows);
```

---

## 5. Dialect Adapters & Pushdown Capabilities

TTQL translates AST clauses into the most optimized native dialect for each remote connection:

```
                      ┌─────────────────────────┐
                      │  TTQL Planned Stage     │
                      └────────────┬────────────┘
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         ▼                         ▼                         ▼
   [ ANSI SQL ]               [ MongoDB ]               [ Redis ]
   - PostgreSQL               - Collection Query        - Hash Get
   - MySQL                    - JSON MQL Filter         - Set Intersect
   - SQLite                   - $match & $project       - Key Scan
   - DuckDB                   - BSON Serialization      - In-Memory Pipe
```

### 5.1 Relational Engines (PostgreSQL, MySQL, SQLite, DuckDB)
- **Projections**: Pushed down as `SELECT "col1", "col2"` (or backticks for MySQL/PlanetScale).
- **Predicates**: Pushed down as parameterized SQL clauses (`$1`, `$2` or `?`).
- **Dependency Injections**: When a stage depends on a parent join stage, distinct foreign keys are injected as `WHERE "foreign_key" IN ('val1', 'val2', ...)`.

### 5.2 Document Engines (MongoDB)
- Queries translate to MongoDB JSON Query Language payloads:
```json
{
  "find": "orders",
  "filter": {
    "status": "completed",
    "total_amount": { "$gt": 100 },
    "customer_id": { "$in": ["cust_101", "cust_102"] }
  },
  "projection": { "order_id": 1, "customer_id": 1, "total_amount": 1 }
}
```

### 5.3 Key-Value / In-Memory Engines (Redis)
- Hashes and sets are queried using native Redis commands (`HGETALL`, `HMGET`, `SMEMBERS`).
- Complex predicates that cannot be evaluated natively in Redis are pushed into the ephemeral SQLite staging layer.

---

## 6. Language Server Protocol (LSP) & IDE Tooling

TTQL features a full-fledged, standards-compliant Language Server Protocol daemon (`bin/ttql.dart lsp`).

### 6.1 Real-Time Diagnostics
- Syntax errors, missing parentheses, unclosed strings, and forbidden mutation keywords trigger immediate error markers in the editor.
- Warnings highlight unused constants or unindexed join predicates.

### 6.2 Schema-Aware IntelliSense Autocompletion
- **Connection autocompletion**: Triggered on `from(` or `join(`.
- **Table autocompletion**: Triggered on connection dot (`pg.`).
- **Pipeline method autocompletion**: Triggered on method dot (`.`).
- **Column autocompletion**: Recommends column names from all active connection schemas within `.select(...)`, `.where(...)`, `.groupBy(...)`, and `.orderBy(...)`.
- **Aggregate functions**: Automatically suggests `count()`, `sum()`, `avg()`, `min()`, `max()`.

### 6.3 Hover Documentation
- Hovering over keywords, connection aliases, and table names displays engine metadata and schema breakdowns.

---

## 7. Headless CLI Usage

The TTQL runtime can be run directly from the terminal or integrated into CI/CD automation pipelines.

### 7.1 Execute a Script
```bash
dart run bin/ttql.dart run query.ttql --config connections.json --format table
```

### 7.2 Output Formats
| Format | Command Flag | Description |
|---|---|---|
| **ASCII Table** | `--format table` | Human-readable terminal grid |
| **JSON Array** | `--format json` | Formatted JSON array for pipeline piping |
| **CSV** | `--format csv` | RFC-4180 compliant comma-separated values |

### 7.3 Start the LSP Server
```bash
dart run bin/ttql.dart lsp --config connections.json
```

---

## 8. TTQL Cookbook: 8 Real-World Recipes

### Recipe 1: Cross-Database E-Commerce Fulfillment (Postgres + MySQL)
Joins customer master data in PostgreSQL with real-time shipment statuses in MySQL:
```ttql
const pg = environment.connections.ecommerce_pg;
const mysql = environment.connections.warehouse_mysql;

from(pg.customers as c)
  .innerJoin(mysql.shipments as s, on: c.customer_id == s.client_id)
  .where(s.status == 'in_transit' && c.country == 'US')
  .select([
    c.customer_id,
    c.full_name,
    c.email,
    s.tracking_number,
    s.carrier
  ])
  .orderBy(c.full_name, 'ASC')
  .limit(50);
```

---

### Recipe 2: Financial Aggregation & High-Value Customer Segmentation
Calculates customer spending tiers and filters using `.having(...)`:
```ttql
const pg = environment.connections.ledger_pg;

from(pg.transactions as t)
  .where(t.transaction_type == 'settlement' && t.is_flagged == false)
  .groupBy(t.account_id)
  .select([
    t.account_id,
    count() as transaction_count,
    sum(t.amount) as total_volume,
    avg(t.amount) as average_ticket
  ])
  .having(transaction_count >= 10 && total_volume > 100000)
  .orderBy(total_volume, 'DESC')
  .limit(20);
```

---

### Recipe 3: Paginated Admin Audit Log
Demonstrates deterministic keyset-independent pagination with `.limit()` and `.offset()`:
```ttql
const pg = environment.connections.security_pg;

const pageSize = 15;
const pageOffset = 30; // Page 3

from(pg.audit_events as a)
  .where(a.severity IN ['HIGH', 'CRITICAL'])
  .orderBy(a.timestamp, 'DESC')
  .limit(pageSize)
  .offset(pageOffset);
```

---

### Recipe 4: Hybrid Relational-NoSQL Analytics (Postgres + MongoDB)
Correlates relational customer accounts with unstructured event logs in MongoDB:
```ttql
const pg = environment.connections.users_pg;
const mongo = environment.connections.telemetry_mongo;

from(pg.users as u)
  .innerJoin(mongo.user_sessions as s, on: u.user_id == s.account_id)
  .where(u.is_active == true && s.device_type == 'mobile')
  .select([
    u.user_id,
    u.username,
    s.session_id,
    s.ip_address,
    s.last_activity
  ])
  .orderBy(s.last_activity, 'DESC')
  .limit(100);
```

---

### Recipe 5: Microservice Cache Hydration (MySQL + Redis)
Cross-references relational inventory levels in MySQL with hot session keys in Redis:
```ttql
const mysql = environment.connections.catalog_mysql;
const redis = environment.connections.session_redis;

from(mysql.products as p)
  .innerJoin(redis.active_carts as c, on: p.sku == c.product_sku)
  .where(p.stock_quantity <= 5)
  .select([
    p.sku,
    p.title,
    p.stock_quantity,
    c.user_session_id
  ])
  .orderBy(p.stock_quantity, 'ASC');
```

---

### Recipe 6: Multi-Stage Analytical Aggregation with HAVING
Aggregates sales performance by regional territory:
```ttql
const pg = environment.connections.sales_pg;

from(pg.sales_records as s)
  .groupBy(s.region, s.sales_rep)
  .select([
    s.region,
    s.sales_rep,
    count() as deals_closed,
    sum(s.contract_value) as quarterly_revenue
  ])
  .having(deals_closed >= 5 && quarterly_revenue > 250000)
  .orderBy(quarterly_revenue, 'DESC');
```

---

### Recipe 7: Chained 3-Way Federated Join (Postgres + MySQL + DuckDB)
Joins customers across PostgreSQL, orders across MySQL, and warehouse analytics across DuckDB:
```ttql
const pg = environment.connections.crm_pg;
const mysql = environment.connections.erp_mysql;
const duck = environment.connections.warehouse_duckdb;

from(pg.customers as c)
  .innerJoin(mysql.orders as o, on: c.id == o.customer_id)
  .innerJoin(duck.fulfillment_metrics as f, on: o.order_id == f.order_id)
  .where(o.status == 'shipped')
  .select([
    c.full_name,
    o.order_id,
    o.order_total,
    f.dispatch_latency_minutes,
    f.delivery_score
  ])
  .orderBy(f.dispatch_latency_minutes, 'ASC')
  .limit(25);
```

---

### Recipe 8: Dynamic Filter Injection with Spread Arrays
Unpacks dynamic constant lists for flexible filter maintenance:
```ttql
const pg = environment.connections.app_pg;

const activeChannels = ['web', 'ios', 'android'];
const targetRegions = ['NA', 'EMEA', 'APAC'];

from(pg.user_acquisitions as u)
  .where(u.channel IN [...activeChannels] && u.region IN [...targetRegions])
  .groupBy(u.channel)
  .select([
    u.channel,
    count() as total_users,
    sum(u.ltv) as aggregate_ltv
  ])
  .orderBy(aggregate_ltv, 'DESC');
```

---

## 9. Formal Grammar (EBNF Specification)

```ebnf
Script            ::= ConstDecl* FluentPipeline Semicolon? EOF ;

ConstDecl         ::= "const" Identifier "=" ConstValue Semicolon? ;
ConstValue        ::= "environment" "." "connections" "." Identifier
                    | StringLiteral
                    | NumberLiteral
                    | BooleanLiteral
                    | "[" ( ConstListItem ( "," ConstListItem )* )? "]" ;
ConstListItem     ::= "..." Identifier | StringLiteral | NumberLiteral | BooleanLiteral | Identifier ;

FluentPipeline    ::= "from" "(" TableRef ")" PipelineStage* ;
TableRef          ::= ( Identifier "." )? Identifier ( "." "as" "(" StringOrId ")" | "as" Identifier )? ;

PipelineStage     ::= "." "as" "(" StringOrId ")"
                    | "." "select" "(" ( ProjectionList | "[" ProjectionList "]" ) ")"
                    | "." "where" "(" PredicateExpr ")"
                    | "." JoinKeyword "(" TableRef ( "," "on" ":" JoinPredicate )? ")"
                    | "." "groupBy" "(" GroupByList ")"
                    | "." "having" "(" PredicateExpr ")"
                    | "." "orderBy" "(" OrderByList ")"
                    | "." "limit" "(" IntegerOrConst ")"
                    | "." ( "offset" | "skip" ) "(" IntegerOrConst ")" ;

JoinKeyword       ::= "innerJoin" | "leftJoin" | "rightJoin" | "fullOuterJoin" | "join" ;
JoinPredicate     ::= StringLiteral | Identifier | ComparisonExpr ;

ProjectionList    ::= ProjectionItem ( "," ProjectionItem )* ;
ProjectionItem    ::= "..." Identifier
                    | AggregateCall ( "as" Identifier )?
                    | QualifiedIdent ( "as" Identifier )? ;

AggregateCall     ::= ( "count" | "sum" | "avg" | "min" | "max" ) "(" ( "*" | QualifiedIdent )? ")" ;

GroupByList       ::= GroupByItem ( "," GroupByItem )* | "[" GroupByItem ( "," GroupByItem )* "]" ;
GroupByItem       ::= QualifiedIdent | ArrowExpr ;

OrderByList       ::= OrderByItem ( "," OrderByItem )* ;
OrderByItem       ::= QualifiedIdent ( "," ( "ASC" | "DESC" ) )? ;

PredicateExpr     ::= LogicalOr ;
LogicalOr         ::= LogicalAnd ( ( "||" | "OR" ) LogicalAnd )* ;
LogicalAnd        ::= LogicalNot ( ( "&&" | "AND" ) LogicalNot )* ;
LogicalNot        ::= ( "!" | "NOT" )? PrimaryPredicate ;
PrimaryPredicate  ::= "(" PredicateExpr ")" | ComparisonExpr ;

ComparisonExpr    ::= LeftOperand CompOp RightOperand ;
LeftOperand       ::= AggregateCall | QualifiedIdent ;
RightOperand      ::= Literal | QualifiedIdent | "[" ( Literal ( "," Literal )* )? "]" ;
CompOp            ::= "==" | "=" | "!=" | "<>" | "<" | "<=" | ">" | ">="
                    | "LIKE" | "NOT LIKE" | "IN" | "NOT IN" | "is" ( "not" )? ;

QualifiedIdent    ::= ( Identifier "." )? Identifier ;
```

---
*TableTalk Query Language (TTQL) is developed and maintained by the TableTalk project.*
