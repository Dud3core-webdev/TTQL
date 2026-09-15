import 'package:ttql/models/db_engine_type.dart';
import 'package:ttql/models/ttql_binary_logical_expression.dart';
import 'package:ttql/models/ttql_comparison_expression.dart';
import 'package:ttql/models/ttql_environment_context.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/models/ttql_expression.dart';
import 'package:ttql/models/ttql_group_expression.dart';
import 'package:ttql/models/ttql_inferred_type.dart';
import 'package:ttql/models/ttql_join_node.dart';
import 'package:ttql/models/ttql_order_by_node.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';
import 'package:ttql/models/ttql_script_node.dart';
import 'package:ttql/models/ttql_select_node.dart';
import 'package:ttql/models/ttql_token.dart';
import 'package:ttql/models/ttql_unary_logical_expression.dart';
import 'package:ttql/models/ttql_where_predicate_node.dart';

/// Recursive descent parser for TableTalk Query Language (TTQL).
/// Produces a verified [TtqlScriptNode] AST and enforces 100% read-only invariants.
class TtqlParser {
  final List<TtqlToken> tokens;
  final TtqlEnvironmentContext? environmentContext;
  final Map<String, String> _connectionAliases = {};
  final Map<String, dynamic> _constantValues = {};
  final Map<String, TtqlInferredType> _constantTypes = {};
  int _current = 0;

  TtqlParser(this.tokens, {this.environmentContext});

  /// Parses the complete script into a [TtqlScriptNode].
  TtqlScriptNode parse() {
    _connectionAliases.clear();
    _constantValues.clear();
    _constantTypes.clear();

    // 1. Parse optional "const alias = environment.connections.target;" or "const var = 'literal';" statements
    while (_check(TtqlTokenType.keyword) && _peek().value == 'const') {
      _parseConstDeclaration(_connectionAliases, _constantValues, _constantTypes);
    }

    // 2. Parse root select(() => { ... })
    _consumeKeyword('select', 'Expected "select" statement.');
    final selectNode = _parseSelectBlock();

    // 3. Parse optional chained joins: .innerJoin(...) / .leftJoin(...) and modifiers .orderBy(...) / .limit(...)
    final List<TtqlJoinNode> joins = [];
    TtqlOrderByNode? orderBy;
    int? limit;

    while (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
      _advance(); // Consume '.'
      if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) &&
          (_peek().value.toLowerCase() == 'innerjoin' ||
              _peek().value.toLowerCase() == 'leftjoin' ||
              _peek().value.toLowerCase() == 'rightjoin' ||
              _peek().value.toLowerCase() == 'fullouterjoin')) {
        joins.add(_parseJoin());
      } else if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) &&
          _peek().value.toLowerCase() == 'orderby') {
        _advance(); // Consume 'orderBy'
        orderBy = _parseOrderBy();
      } else if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) &&
          _peek().value.toLowerCase() == 'limit') {
        _advance(); // Consume 'limit'
        limit = _parseLimit();
      } else {
        throw TtqlParseException(
          'Expected ".innerJoin", ".leftJoin", ".rightJoin", ".fullOuterJoin", ".orderBy", or ".limit", found "${_peek().value}"',
          line: _peek().line,
          column: _peek().column,
        );
      }
    }

    // Semicolon at end is optional
    if (_check(TtqlTokenType.punctuation) && _peek().value == ';') {
      _advance();
    }

    if (!_isAtEnd() && !_check(TtqlTokenType.eof)) {
      throw TtqlParseException(
        'Unexpected trailing token "${_peek().value}"',
        line: _peek().line,
        column: _peek().column,
      );
    }

    return TtqlScriptNode(
      declaredConstants: Map.from(_constantValues),
      connectionAliases: Map.from(_connectionAliases),
      rootInvocations: selectNode.queryInvocations,
      joins: joins,
      orderBy: orderBy,
      limit: limit,
    );
  }

  void _parseConstDeclaration(
    Map<String, String> connectionAliases,
    Map<String, dynamic> constantValues,
    Map<String, TtqlInferredType> constantTypes,
  ) {
    _consumeKeyword('const', 'Expected "const"');
    final varNameToken = _consume(TtqlTokenType.identifier, 'Expected constant identifier');
    _consumeOperator('=', 'Expected "=" after constant name');

    if (_check(TtqlTokenType.identifier) && _peek().value == 'environment') {
      _advance(); // consume 'environment'
      _consumePunctuation('.', 'Expected "." after environment');
      _consumeIdentifier('connections', 'Expected "connections"');
      _consumePunctuation('.', 'Expected "." after connections');
      final targetConnectionToken = _consume(TtqlTokenType.identifier, 'Expected target database name');
      connectionAliases[varNameToken.value] = targetConnectionToken.value;
      constantTypes[varNameToken.value] = TtqlInferredType.connectionRef;
    } else if (_check(TtqlTokenType.stringLiteral)) {
      final token = _advance();
      final raw = token.value;
      constantValues[varNameToken.value] = raw;
      constantTypes[varNameToken.value] = TtqlInferredType.string;
    } else if (_check(TtqlTokenType.numberLiteral)) {
      final token = _advance();
      final numVal = num.tryParse(token.value) ?? token.value;
      constantValues[varNameToken.value] = numVal;
      constantTypes[varNameToken.value] = TtqlInferredType.number;
    } else if (_check(TtqlTokenType.booleanLiteral)) {
      final token = _advance();
      constantValues[varNameToken.value] = token.value == 'true';
      constantTypes[varNameToken.value] = TtqlInferredType.boolean;
    } else if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
      _advance(); // Consume '['
      final list = <dynamic>[];
      while (!(_check(TtqlTokenType.punctuation) && _peek().value == ']') && !_isAtEnd()) {
        if (_check(TtqlTokenType.operator) && _peek().value == '...') {
          _advance();
          final spreadToken = _consume(TtqlTokenType.identifier, 'Expected identifier after spread operator "..."');
          final spreadVal = constantValues[spreadToken.value];
          if (spreadVal is List) {
            list.addAll(spreadVal);
          } else {
            throw TtqlParseException(
              'Cannot spread non-list constant "${spreadToken.value}" into array',
              line: spreadToken.line,
              column: spreadToken.column,
            );
          }
        } else if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
          final t = _advance().value;
          list.add(t);
        } else if (_check(TtqlTokenType.numberLiteral)) {
          final numToken = _advance();
          list.add(num.tryParse(numToken.value) ?? numToken.value);
        } else if (_check(TtqlTokenType.booleanLiteral)) {
          list.add(_advance().value == 'true');
        }
        if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
          _advance();
        }
      }
      _consumePunctuation(']', 'Expected "]" closing array in constant');
      constantValues[varNameToken.value] = list;
      if (list.every((e) => e is String)) {
        constantTypes[varNameToken.value] = TtqlInferredType.listString;
      } else if (list.every((e) => e is num)) {
        constantTypes[varNameToken.value] = TtqlInferredType.listNumber;
      } else {
        constantTypes[varNameToken.value] = TtqlInferredType.listAny;
      }
    } else if (_check(TtqlTokenType.identifier)) {
      final token = _advance();
      constantValues[varNameToken.value] = token.value;
      constantTypes[varNameToken.value] = TtqlInferredType.string;
    } else {
      throw TtqlParseException(
        'Expected literal value, list, or environment connection after "=" for constant "${varNameToken.value}"',
        line: _peek().line,
        column: _peek().column,
      );
    }

    if (_check(TtqlTokenType.punctuation) && _peek().value == ';') {
      _advance();
    }
  }

  TtqlSelectNode _parseSelectBlock() {
    _consumePunctuation('(', 'Expected "(" after "select"');
    _consumePunctuation('(', 'Expected "() =>" closure in select');
    _consumePunctuation(')', 'Expected "() =>" closure in select');
    _consumePunctuation('=>', 'Expected "=>" in select');
    _consumePunctuation('{', 'Expected "{" opening select body');

    final List<TtqlQueryInvocationNode> invocations = [];

    if (_check(TtqlTokenType.keyword) && _peek().value == 'declare') {
      _advance(); // Consume declare
      _consumeKeyword('asyncRun', 'Expected "asyncRun" after "declare"');
      invocations.addAll(_parseAsyncRun());
    } else {
      invocations.add(_parseQueryInvocation());
    }

    _consumePunctuation('}', 'Expected "}" closing select body');
    _consumePunctuation(')', 'Expected ")" closing select call');

    return TtqlSelectNode(queryInvocations: invocations);
  }

  List<TtqlQueryInvocationNode> _parseAsyncRun() {
    _consumePunctuation('(', 'Expected "(" after asyncRun');
    _consumePunctuation('(', 'Expected "() =>" closure in asyncRun');
    _consumePunctuation(')', 'Expected "() =>" closure in asyncRun');
    _consumePunctuation('=>', 'Expected "=>" in asyncRun');
    _consumePunctuation('{', 'Expected "{" opening asyncRun body');

    final List<TtqlQueryInvocationNode> queries = [];
    while (!(_check(TtqlTokenType.punctuation) && _peek().value == '}') && !_isAtEnd()) {
      queries.add(_parseQueryInvocation());
      if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
        _advance();
      }
    }

    _consumePunctuation('}', 'Expected "}" closing asyncRun body');
    _consumePunctuation(')', 'Expected ")" closing asyncRun call');

    TtqlWherePredicateNode? wherePredicate;
    if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
      _advance(); // Consume '.'
      if (_check(TtqlTokenType.keyword) && _peek().value == 'where') {
        _advance(); // Consume 'where'
        wherePredicate = _parseWherePredicate();
      }
    }

    if (wherePredicate != null) {
      return queries.map((q) {
        return TtqlQueryInvocationNode(
          engineType: q.engineType,
          connectionId: q.connectionId,
          targetTableOrCollection: q.targetTableOrCollection,
          projectedColumns: q.projectedColumns,
          wherePredicate: q.wherePredicate ?? wherePredicate,
        );
      }).toList();
    }

    return queries;
  }

  TtqlQueryInvocationNode _parseQueryInvocation() {
    final engineToken = _consumeEngineIdentifier('Expected database engine identifier');
    final engineType = _resolveEngineType(engineToken.value);

    _consumePunctuation('(', 'Expected "(" after engine name');

    final connId = _parseConnectionExpression();

    _consumePunctuation(',', 'Expected "," after connection argument');

    List<String> projectedColumns = [];
    String targetTable = '';

    if (engineType == DbEngineType.mongodb || engineType == DbEngineType.redis) {
      if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
        _advance();
        while (!(_check(TtqlTokenType.punctuation) && _peek().value == ']') && !_isAtEnd()) {
          if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
            projectedColumns.add(_advance().value);
          }
          if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
            _advance();
          }
        }
        _consumePunctuation(']', 'Expected "]"');
        if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
          _advance();
        }
      }

      if (!(_check(TtqlTokenType.punctuation) && _peek().value == ')')) {
        targetTable = _parseTableReference();
      }

      if (targetTable.isEmpty && projectedColumns.isNotEmpty) {
        targetTable = projectedColumns.last;
      }
    } else {
      if (_check(TtqlTokenType.identifier)) {
        final idToken = _advance();
        final constVal = _constantValues[idToken.value];
        if (constVal is List) {
          projectedColumns = constVal.map((e) => e.toString()).toList();
        } else if (constVal != null) {
          projectedColumns = [constVal.toString()];
        } else {
          projectedColumns = [idToken.value];
        }
        _consumePunctuation(',', 'Expected "," after projected properties');
      } else {
        _consumePunctuation('[', 'Expected "[" for projected properties array');
        while (!(_check(TtqlTokenType.punctuation) && _peek().value == ']') && !_isAtEnd()) {
          if (_check(TtqlTokenType.operator) && _peek().value == '...') {
            _advance();
            final spreadId = _consume(TtqlTokenType.identifier, 'Expected identifier after "..."');
            final val = _constantValues[spreadId.value];
            if (val is List) {
              projectedColumns.addAll(val.map((e) => e.toString()));
            } else {
              throw TtqlParseException('Cannot spread non-list constant "${spreadId.value}" into array');
            }
          } else if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
            projectedColumns.add(_advance().value);
          }
          if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
            _advance();
          }
        }
        _consumePunctuation(']', 'Expected "]"');
        _consumePunctuation(',', 'Expected "," after projected properties');
      }

      targetTable = _parseTableReference();
    }

    _consumePunctuation(')', 'Expected ")" closing query invocation');

    TtqlWherePredicateNode? wherePredicate;
    if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
      final mark = _current;
      _advance(); // Consume '.'
      if (_check(TtqlTokenType.keyword) && _peek().value == 'where') {
        _advance(); // Consume where
        wherePredicate = _parseWherePredicate();
      } else {
        _current = mark;
      }
    }

    return TtqlQueryInvocationNode(
      engineType: engineType,
      connectionId: connId,
      targetTableOrCollection: targetTable,
      projectedColumns: projectedColumns,
      wherePredicate: wherePredicate,
    );
  }

  String _parseConnectionExpression() {
    final buffer = StringBuffer();
    while (!(_check(TtqlTokenType.punctuation) && (_peek().value == ',' || _peek().value == ')')) && !_isAtEnd()) {
      buffer.write(_advance().value);
    }
    return buffer.toString().trim();
  }

  String _parseTableReference() {
    if (_check(TtqlTokenType.stringLiteral)) {
      return _advance().value;
    }

    final buffer = StringBuffer();
    if (_check(TtqlTokenType.identifier)) {
      final firstIdent = _advance().value;
      if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        buffer.write(firstIdent);
        _advance(); // .
        if (_check(TtqlTokenType.identifier)) {
          final tablesIdent = _advance().value;
          if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
            _advance(); // [
            if (_check(TtqlTokenType.operator) && _peek().value == '...') {
              _advance();
              final id = _consume(TtqlTokenType.identifier, 'Expected identifier after "..."');
              final spreadVal = _constantValues[id.value];
              if (spreadVal is! List || spreadVal.length != 1) {
                throw TtqlParseException('Spreading a table list into tables[...] requires exactly 1 table name.');
              }
              _consumePunctuation(']', 'Expected "]"');
              return spreadVal.first.toString();
            } else if (_check(TtqlTokenType.stringLiteral)) {
              final tableName = _advance().value;
              _consumePunctuation(']', 'Expected "]"');
              return tableName;
            } else if (_check(TtqlTokenType.identifier)) {
              final id = _advance().value;
              final resolved = _constantValues[id]?.toString() ?? id;
              _consumePunctuation(']', 'Expected "]"');
              return resolved;
            }
          } else if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
            _advance();
            if (_check(TtqlTokenType.identifier)) {
              return _advance().value;
            }
          }
          return tablesIdent;
        }
      } else {
        final constVal = _constantValues[firstIdent];
        if (constVal != null) {
          return constVal.toString();
        }
        return firstIdent;
      }
    }
    return buffer.toString();
  }

  TtqlWherePredicateNode _parseWherePredicate() {
    _consumePunctuation('(', 'Expected "(" after "where"');
    _consumePunctuation('(', 'Expected "(" in predicate parameter');
    final entityAlias = _consume(TtqlTokenType.identifier, 'Expected entity parameter name').value;
    _consumePunctuation(')', 'Expected ")" after predicate parameter');
    _consumePunctuation('=>', 'Expected "=>" in predicate');

    final rootExpr = _parseLogicalOr(entityAlias);
    _consumePunctuation(')', 'Expected ")" closing where clause');

    String firstField = '';
    String firstOp = '=';
    dynamic firstRight = '';
    bool firstIsFieldRef = false;
    String? firstRightEntity;

    void extractFirstComparison(TtqlExpression expr) {
      if (expr is TtqlComparisonExpression) {
        firstField = expr.fieldName;
        firstOp = expr.operator;
        firstRight = expr.rightOperand;
        firstIsFieldRef = expr.isRightOperandFieldReference;
        firstRightEntity = expr.rightFieldEntityAlias;
      } else if (expr is TtqlBinaryLogicalExpression) {
        extractFirstComparison(expr.left);
      } else if (expr is TtqlUnaryLogicalExpression) {
        extractFirstComparison(expr.operand);
      } else if (expr is TtqlGroupExpression) {
        extractFirstComparison(expr.inner);
      }
    }
    extractFirstComparison(rootExpr);

    return TtqlWherePredicateNode(
      entityAlias: entityAlias,
      fieldName: firstField,
      operator: firstOp,
      rightOperand: firstRight,
      isRightOperandFieldReference: firstIsFieldRef,
      rightFieldEntityAlias: firstRightEntity,
      rootExpression: rootExpr,
    );
  }

  TtqlExpression _parseLogicalOr(String defaultEntityAlias) {
    var expr = _parseLogicalAnd(defaultEntityAlias);

    while (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'OR') {
      _advance();
      final right = _parseLogicalAnd(defaultEntityAlias);
      expr = TtqlBinaryLogicalExpression(
        left: expr,
        operator: 'OR',
        right: right,
      );
    }
    return expr;
  }

  TtqlExpression _parseLogicalAnd(String defaultEntityAlias) {
    var expr = _parseLogicalNot(defaultEntityAlias);

    while (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'AND') {
      _advance();
      final right = _parseLogicalNot(defaultEntityAlias);
      expr = TtqlBinaryLogicalExpression(
        left: expr,
        operator: 'AND',
        right: right,
      );
    }
    return expr;
  }

  TtqlExpression _parseLogicalNot(String defaultEntityAlias) {
    if (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'NOT') {
      _advance();
      final operand = _parseLogicalNot(defaultEntityAlias);
      return TtqlUnaryLogicalExpression(
        operator: 'NOT',
        operand: operand,
      );
    }
    return _parsePrimaryOrComparison(defaultEntityAlias);
  }

  TtqlExpression _parsePrimaryOrComparison(String defaultEntityAlias) {
    if (_check(TtqlTokenType.punctuation) && _peek().value == '(') {
      _advance();
      final inner = _parseLogicalOr(defaultEntityAlias);
      _consumePunctuation(')', 'Expected ")" closing parenthesized expression');
      return TtqlGroupExpression(inner);
    }

    return _parseComparison(defaultEntityAlias);
  }

  TtqlComparisonExpression _parseComparison(String defaultEntityAlias) {
    final firstIdent = _consume(TtqlTokenType.identifier, 'Expected field or entity identifier');
    String field;

    if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
      _advance(); // Consume '.'
      field = _consume(TtqlTokenType.identifier, 'Expected field identifier after "."').value;
    } else {
      field = firstIdent.value;
    }

    String op = '=';
    if (_check(TtqlTokenType.keyword) && _peek().value == 'is') {
      _advance();
      if (_check(TtqlTokenType.keyword) && _peek().value == 'not') {
        _advance();
        op = '!=';
      } else {
        op = '=';
      }
    } else if (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'LIKE') {
      _advance();
      op = 'LIKE';
    } else if (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'IN') {
      _advance();
      op = 'IN';
    } else if (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'NOT') {
      _advance();
      if (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'LIKE') {
        _advance();
        op = 'NOT LIKE';
      } else if (_check(TtqlTokenType.keyword) && _peek().value.toUpperCase() == 'IN') {
        _advance();
        op = 'NOT IN';
      }
    } else if (_check(TtqlTokenType.operator)) {
      op = _advance().value;
    }

    dynamic rightOperand;
    bool isFieldRef = false;
    String? rightEntity;

    if (op == 'IN' || op == 'NOT IN') {
      if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
        _advance();
        final inList = <dynamic>[];
        while (!(_check(TtqlTokenType.punctuation) && _peek().value == ']') && !_isAtEnd()) {
          if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
            final val = _advance().value;
            inList.add(_constantValues[val] ?? val);
          } else if (_check(TtqlTokenType.numberLiteral)) {
            final numToken = _advance();
            inList.add(num.tryParse(numToken.value) ?? numToken.value);
          } else if (_check(TtqlTokenType.booleanLiteral)) {
            inList.add(_advance().value == 'true');
          }
          if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
            _advance();
          }
        }
        _consumePunctuation(']', 'Expected "]" closing IN array');
        rightOperand = inList;
      } else if (_check(TtqlTokenType.identifier)) {
        final idToken = _advance();
        rightOperand = _constantValues[idToken.value] ?? idToken.value;
      }
    } else if (_check(TtqlTokenType.stringLiteral)) {
      rightOperand = _advance().value;
    } else if (_check(TtqlTokenType.numberLiteral)) {
      final token = _advance();
      rightOperand = num.tryParse(token.value) ?? token.value;
    } else if (_check(TtqlTokenType.booleanLiteral)) {
      rightOperand = _advance().value == 'true';
    } else if (_check(TtqlTokenType.identifier)) {
      final rightIdent = _advance();
      if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        _advance(); // '.'
        final subProp = _consume(TtqlTokenType.identifier, 'Expected property after "."');
        isFieldRef = true;
        rightEntity = rightIdent.value;
        rightOperand = '${rightIdent.value}.${subProp.value}';
      } else {
        rightOperand = _constantValues[rightIdent.value] ?? rightIdent.value;
      }
    }

    return TtqlComparisonExpression(
      fieldName: field,
      operator: op,
      rightOperand: rightOperand,
      isRightOperandFieldReference: isFieldRef,
      rightFieldEntityAlias: rightEntity,
    );
  }

  TtqlOrderByNode _parseOrderBy() {
    _consumePunctuation('(', 'Expected "(" after "orderBy"');

    if (_check(TtqlTokenType.punctuation) && _peek().value == '(') {
      _advance();
      _consume(TtqlTokenType.identifier, 'Expected parameter in orderBy');
      _consumePunctuation(')', 'Expected ")" after parameter');
    } else {
      _consume(TtqlTokenType.identifier, 'Expected parameter in orderBy');
    }

    _consumePunctuation('=>', 'Expected "=>" in orderBy closure');
    final entityToken = _consume(TtqlTokenType.identifier, 'Expected entity in orderBy');
    final entityAlias = entityToken.value;

    String fieldName;
    if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
      _advance();
      fieldName = _consume(TtqlTokenType.identifier, 'Expected column identifier in orderBy').value;
    } else if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
      _advance();
      if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
        final raw = _advance().value;
        fieldName = _constantValues[raw]?.toString() ?? raw;
      } else {
        throw TtqlParseException('Expected column string or constant in orderBy bracket access');
      }
      _consumePunctuation(']', 'Expected "]"');
    } else {
      throw TtqlParseException('Expected "." or "[" in orderBy property access');
    }

    String direction = 'ASC';
    if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
      _advance();
      if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
        final raw = _advance().value;
        final resolved = _constantValues[raw]?.toString() ?? raw;
        direction = resolved.toUpperCase() == 'DESC' ? 'DESC' : 'ASC';
      }
    }
    _consumePunctuation(')', 'Expected ")" closing orderBy');

    return TtqlOrderByNode(
      fieldName: fieldName,
      direction: direction,
      entityAlias: entityAlias,
    );
  }

  int _parseLimit() {
    _consumePunctuation('(', 'Expected "(" after "limit"');

    int val;
    if (_check(TtqlTokenType.numberLiteral)) {
      final numToken = _advance();
      val = int.tryParse(numToken.value) ?? 10;
    } else if (_check(TtqlTokenType.identifier)) {
      final idToken = _advance();
      if (!_constantValues.containsKey(idToken.value)) {
        throw TtqlParseException(
          'Undefined constant "${idToken.value}" in limit()',
          line: idToken.line,
          column: idToken.column,
        );
      }
      final constVal = _constantValues[idToken.value];
      if (constVal is int) {
        val = constVal;
      } else if (constVal is num) {
        val = constVal.toInt();
      } else {
        val = int.tryParse(constVal?.toString() ?? '') ?? 10;
      }
    } else {
      throw TtqlParseException('Expected integer in limit()');
    }

    _consumePunctuation(')', 'Expected ")" closing limit');
    return val;
  }

  TtqlJoinNode _parseJoin() {
    final joinToken = _advance();
    final joinType = joinToken.value;

    _consumePunctuation('(', 'Expected "(" after "$joinType"');
    _consumePunctuation('(', 'Expected "(" for join closure parameter');
    final parentAlias = _consume(TtqlTokenType.identifier, 'Expected join parent parameter').value;
    _consumePunctuation(')', 'Expected ")" after join closure parameter');
    _consumePunctuation('=>', 'Expected "=>" in join closure');
    _consumePunctuation('{', 'Expected "{" opening join body');

    final targetInvocation = _parseQueryInvocation();

    _consumePunctuation('}', 'Expected "}" closing join body');
    _consumePunctuation(')', 'Expected ")" closing "$joinType" call');

    return TtqlJoinNode(
      joinType: joinType,
      parentEntityAlias: parentAlias,
      queryInvocation: targetInvocation,
    );
  }

  TtqlToken _consumeEngineIdentifier(String errorMessage) {
    if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword)) {
      final token = _peek();
      if (_isEngineName(token.value)) {
        return _advance();
      }
    }
    throw TtqlParseException(errorMessage, line: _peek().line, column: _peek().column);
  }

  bool _isEngineName(String text) {
    final lower = text.toLowerCase();
    return lower == 'postgresql' ||
        lower == 'postgres' ||
        lower == 'mysql' ||
        lower == 'mongodb' ||
        lower == 'mongo' ||
        lower == 'sqlite' ||
        lower == 'redis' ||
        lower == 'duckdb' ||
        lower == 'mssql' ||
        lower == 'clickhouse' ||
        lower == 'planetscale' ||
        lower == 'cockroachdb' ||
        lower == 'cockroach' ||
        lower == 'yugabytedb' ||
        lower == 'yugabyte' ||
        lower == 'oracle' ||
        lower == 'cassandra' ||
        lower == 'scylla';
  }

  DbEngineType _resolveEngineType(String text) {
    final lower = text.toLowerCase();
    switch (lower) {
      case 'postgresql':
      case 'postgres':
        return DbEngineType.postgres;
      case 'mysql':
        return DbEngineType.mysql;
      case 'mongodb':
      case 'mongo':
        return DbEngineType.mongodb;
      case 'sqlite':
        return DbEngineType.sqlite;
      case 'redis':
        return DbEngineType.redis;
      case 'duckdb':
        return DbEngineType.duckdb;
      case 'mssql':
        return DbEngineType.mssql;
      case 'clickhouse':
        return DbEngineType.clickhouse;
      case 'planetscale':
        return DbEngineType.planetscale;
      case 'cockroachdb':
      case 'cockroach':
        return DbEngineType.cockroachdb;
      case 'yugabytedb':
      case 'yugabyte':
        return DbEngineType.yugabytedb;
      case 'oracle':
        return DbEngineType.oracle;
      case 'cassandra':
      case 'scylla':
        return DbEngineType.cassandra;
      default:
        throw TtqlParseException('Unknown database engine identifier "$text"');
    }
  }

  bool _isAtEnd() => _peek().type == TtqlTokenType.eof;
  TtqlToken _peek() => tokens[_current];

  bool _check(TtqlTokenType type) {
    if (_isAtEnd()) return false;
    return _peek().type == type;
  }

  TtqlToken _advance() {
    if (!_isAtEnd()) _current++;
    return tokens[_current - 1];
  }

  TtqlToken _consume(TtqlTokenType type, String errorMessage) {
    if (_check(type)) return _advance();
    throw TtqlParseException(errorMessage, line: _peek().line, column: _peek().column);
  }

  TtqlToken _consumeKeyword(String keyword, String errorMessage) {
    if (_check(TtqlTokenType.keyword) && _peek().value.toLowerCase() == keyword.toLowerCase()) return _advance();
    throw TtqlParseException(errorMessage, line: _peek().line, column: _peek().column);
  }

  TtqlToken _consumePunctuation(String p, String errorMessage) {
    if (_check(TtqlTokenType.punctuation) && _peek().value == p) return _advance();
    throw TtqlParseException(errorMessage, line: _peek().line, column: _peek().column);
  }

  TtqlToken _consumeOperator(String op, String errorMessage) {
    if (_check(TtqlTokenType.operator) && _peek().value == op) return _advance();
    throw TtqlParseException(errorMessage, line: _peek().line, column: _peek().column);
  }

  TtqlToken _consumeIdentifier(String id, String errorMessage) {
    if (_check(TtqlTokenType.identifier) && _peek().value == id) return _advance();
    throw TtqlParseException(errorMessage, line: _peek().line, column: _peek().column);
  }
}
