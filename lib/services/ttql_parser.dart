import 'package:ttql/models/db_engine_registry.dart';
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
import 'package:ttql/models/ttql_projection_item.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';
import 'package:ttql/models/ttql_script_node.dart';
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
  final Map<String, _TtqlProjectionMacro> _declaredFunctions = {};
  int _current = 0;

  TtqlParser(this.tokens, {this.environmentContext});

  /// Parses the complete script into a [TtqlScriptNode].
  TtqlScriptNode parse() {
    _connectionAliases.clear();
    _constantValues.clear();
    _constantTypes.clear();
    _declaredFunctions.clear();

    // 1. Parse optional "const alias = environment.connections.target;" or "const var = 'literal';" statements
    while (_check(TtqlTokenType.keyword) && _peek().value == 'const') {
      _parseConstDeclaration(_connectionAliases, _constantValues, _constantTypes);
    }

    // 2. Parse optional projection macro declarations ("declare function name(param) { return { ... }; }")
    while (_check(TtqlTokenType.keyword) && _peek().value.toLowerCase() == 'declare') {
      _parseProjectionMacroDeclaration();
    }

    // 3. Parse query pipeline starting with 'from'
    if (_check(TtqlTokenType.keyword) && _peek().value.toLowerCase() == 'from') {
      return _parseFluentPipeline();
    }

    throw TtqlParseException(
      'Expected "from" statement to start query pipeline, found "${_isAtEnd() ? "EOF" : _peek().value}"',
      line: _isAtEnd() ? 1 : _peek().line,
      column: _isAtEnd() ? 1 : _peek().column,
    );
  }

  /// Parses a `declare function name(param) { return { ...projections... }; }` block
  /// and registers it as a reusable projection macro.
  void _parseProjectionMacroDeclaration() {
    _consumeKeyword('declare', 'Expected "declare"');
    _consumeKeyword('function', 'Expected "function" after "declare"');

    final nameToken = _consume(TtqlTokenType.identifier, 'Expected function name after "declare function"');
    final macroName = nameToken.value;

    _consumePunctuation('(', 'Expected "(" after function name "$macroName"');
    final List<String> paramNames = [];
    while (!(_check(TtqlTokenType.punctuation) && _peek().value == ')') && !_isAtEnd()) {
      final paramToken = _consume(TtqlTokenType.identifier, 'Expected parameter name in "declare function $macroName(...)"');
      paramNames.add(paramToken.value);
      if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
        _advance();
      } else {
        break;
      }
    }
    _consumePunctuation(')', 'Expected ")" after parameter in "declare function $macroName(...)"');

    _consumePunctuation('{', 'Expected "{" opening function body');
    _consumeKeyword('return', 'Expected "return" as the first statement in function body');
    _consumePunctuation('{', 'Expected "{" opening return object literal');

    // Parse projection items until closing '}'
    final defaultEntity = paramNames.isNotEmpty ? paramNames.first : '';
    final List<TtqlProjectionItem> body = [];
    while (!(_check(TtqlTokenType.punctuation) && _peek().value == '}') && !_isAtEnd()) {
      body.add(_parseSingleProjectionItem(defaultEntity));
      if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
        _advance();
      } else {
        break;
      }
    }

    _consumePunctuation('}', 'Expected "}" closing return object literal');
    if (_check(TtqlTokenType.punctuation) && _peek().value == ';') _advance();
    _consumePunctuation('}', 'Expected "}" closing function body');
    if (_check(TtqlTokenType.punctuation) && _peek().value == ';') _advance();

    if (body.isEmpty) {
      throw TtqlParseException(
        'Projection macro "$macroName" must return at least one column or aggregate',
        line: nameToken.line,
        column: nameToken.column,
      );
    }

    _declaredFunctions[macroName] = _TtqlProjectionMacro(
      name: macroName,
      paramNames: paramNames,
      body: body,
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
        final loopStart = _current;
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
        } else if (_check(TtqlTokenType.stringLiteral)) {
          list.add(_advance().value);
        } else if (_check(TtqlTokenType.identifier)) {
          final firstToken = _advance();
          if (!_isAtEnd() &&
              (_check(TtqlTokenType.punctuation) || _check(TtqlTokenType.operator)) &&
              _peek().value == '.') {
            _advance(); // Consume '.'
            final fieldToken = _consume(TtqlTokenType.identifier, 'Expected field name after "." in array constant');
            list.add('${firstToken.value}.${fieldToken.value}');
          } else {
            list.add(firstToken.value);
          }
        } else if (_check(TtqlTokenType.numberLiteral)) {
          final numToken = _advance();
          list.add(num.tryParse(numToken.value) ?? numToken.value);
        } else if (_check(TtqlTokenType.booleanLiteral)) {
          list.add(_advance().value == 'true');
        } else {
          final unexpected = _peek();
          throw TtqlParseException(
            'Unexpected token "${unexpected.value}" in constant array',
            line: unexpected.line,
            column: unexpected.column,
          );
        }
        if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
          _advance();
        }
        if (_current == loopStart) {
          final stuck = _peek();
          throw TtqlParseException(
            'Unexpected token "${stuck.value}" in constant array',
            line: stuck.line,
            column: stuck.column,
          );
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

  TtqlComparisonExpression _parseComparison(
    String defaultEntityAlias, {
    bool isJoinCondition = false,
    String? defaultRightEntity,
  }) {
    final String field;
    final String? entityAlias;

    if (_isAggregateFunctionCall()) {
      field = _parseAggregateCallString();
      entityAlias = defaultEntityAlias;
    } else {
      final firstToken = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword))
          ? _advance()
          : _consume(TtqlTokenType.identifier, 'Expected field or entity identifier');
      final idParts = <String>[firstToken.value];
      while (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        _advance(); // Consume '.'
        final nextToken = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword))
            ? _advance()
            : _consume(TtqlTokenType.identifier, 'Expected field identifier after "."');
        idParts.add(nextToken.value);
      }
      field = idParts.last;
      entityAlias = idParts.length > 1 ? idParts[idParts.length - 2] : defaultEntityAlias;
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
      if (op == '==') op = '=';
    }

    dynamic rightOperand;
    bool isFieldRef = false;
    String? rightEntity;

    if (op == 'IN' || op == 'NOT IN') {
      if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
        _advance();
        final inList = <dynamic>[];
        while (!(_check(TtqlTokenType.punctuation) && _peek().value == ']') && !_isAtEnd()) {
          final loopStart = _current;
          if (_check(TtqlTokenType.operator) && _peek().value == '...') {
            _advance();
            final spreadToken = _consume(TtqlTokenType.identifier, 'Expected identifier after spread operator "..."');
            final spreadVal = _constantValues[spreadToken.value];
            if (spreadVal is List) {
              inList.addAll(spreadVal);
            } else {
              throw TtqlParseException(
                'Cannot spread non-list constant "${spreadToken.value}" into IN array',
                line: spreadToken.line,
                column: spreadToken.column,
              );
            }
          } else if (_check(TtqlTokenType.stringLiteral)) {
            inList.add(_advance().value);
          } else if (_check(TtqlTokenType.identifier)) {
            final firstToken = _advance();
            if (!_isAtEnd() &&
                (_check(TtqlTokenType.punctuation) || _check(TtqlTokenType.operator)) &&
                _peek().value == '.') {
              _advance(); // Consume '.'
              final fieldToken = _consume(TtqlTokenType.identifier, 'Expected field name after "." in IN array');
              inList.add('${firstToken.value}.${fieldToken.value}');
            } else {
              final resolved = _constantValues[firstToken.value];
              if (resolved is List) {
                inList.addAll(resolved);
              } else {
                inList.add(resolved ?? firstToken.value);
              }
            }
          } else if (_check(TtqlTokenType.numberLiteral)) {
            final numToken = _advance();
            inList.add(num.tryParse(numToken.value) ?? numToken.value);
          } else if (_check(TtqlTokenType.booleanLiteral)) {
            inList.add(_advance().value == 'true');
          } else {
            final unexpected = _peek();
            throw TtqlParseException(
              'Unexpected token "${unexpected.value}" inside IN list',
              line: unexpected.line,
              column: unexpected.column,
            );
          }
          if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
            _advance();
          }
          if (_current == loopStart) {
            final stuck = _peek();
            throw TtqlParseException(
              'Unexpected token "${stuck.value}" inside IN list',
              line: stuck.line,
              column: stuck.column,
            );
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
      final rightParts = <String>[_advance().value];
      while (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        _advance(); // '.'
        rightParts.add(_consume(TtqlTokenType.identifier, 'Expected property after "."').value);
      }
      if (rightParts.length > 1) {
        isFieldRef = true;
        rightEntity = rightParts[rightParts.length - 2];
        rightOperand = rightParts.last;
      } else {
        final val = rightParts.single;
        if (isJoinCondition) {
          isFieldRef = true;
          rightEntity = defaultRightEntity ?? defaultEntityAlias;
          rightOperand = val;
        } else {
          rightOperand = _constantValues[val] ?? val;
        }
      }
    }

    return TtqlComparisonExpression(
      fieldName: field,
      operator: op,
      rightOperand: rightOperand,
      isRightOperandFieldReference: isFieldRef,
      rightFieldEntityAlias: rightEntity,
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

  // ===========================================================================
  // TTQL Fluent Pipeline Implementation
  // ===========================================================================

  TtqlScriptNode _parseFluentPipeline() {
    _consumeKeyword('from', 'Expected "from" statement.');
    _consumePunctuation('(', 'Expected "(" after "from".');

    final primaryRef = _parseFluentTableRef();
    _consumePunctuation(')', 'Expected ")" closing "from(...)".');

    final primaryTable = primaryRef.tableName;
    final Map<String, String> entityAliases = {};
    entityAliases[primaryTable] = primaryTable;
    if (primaryRef.connectionId != null) {
      entityAliases['${primaryRef.connectionId}.$primaryTable'] = primaryTable;
      entityAliases[primaryRef.connectionId!] = primaryTable;
    }
    if (primaryRef.alias != null) {
      entityAliases[primaryRef.alias!] = primaryTable;
    } else if (primaryTable.isNotEmpty && !entityAliases.containsKey(primaryTable[0].toLowerCase())) {
      entityAliases[primaryTable[0].toLowerCase()] = primaryTable;
    }

    final primaryEngine = _resolveEngineForConnection(primaryRef.connectionId);
    final List<String> rootColumns = [];
    TtqlWherePredicateNode? rootWhere;

    final List<_FluentJoinBuilder> joinBuilders = [];
    final List<TtqlOrderByNode> orderBys = [];
    int? limit;
    int? offset;
    final List<String> groupByColumns = [];
    TtqlExpression? havingPredicate;
    final List<TtqlProjectionItem> queryProjections = [];

    // Index of the currently chained join stage, or null if targeting the root table
    int? currentJoinIndex;

    while (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
      _advance(); // Consume '.'

      final methodToken = _peek();
      final methodName = methodToken.value.toLowerCase();

      if (methodName == 'as') {
        _advance();
        _consumePunctuation('(', 'Expected "(" after "as"');
        String alias;
        if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
          alias = _advance().value;
        } else {
          throw TtqlParseException('Expected alias identifier or string in .as(...)', line: _peek().line, column: _peek().column);
        }
        _consumePunctuation(')', 'Expected ")" after alias in .as(...)');

        if (currentJoinIndex == null) {
          entityAliases[alias] = primaryTable;
        } else {
          final jb = joinBuilders[currentJoinIndex];
          entityAliases[alias] = jb.targetTable;
          jb.alias = alias;
        }
      } else if (methodName == 'select') {
        _advance();
        final projs = _parseFluentSelectProjections(primaryTable);
        queryProjections.addAll(projs);

        for (final p in projs) {
          final ent = p is TtqlColumnProjection
              ? p.entityAlias
              : (p is TtqlAggregateProjection ? p.entityAlias : null);
          for (final refCol in p.referencedColumns) {
            if (ent != null) {
              if (ent == primaryTable || entityAliases[ent] == primaryTable) {
                if (!rootColumns.contains(refCol)) rootColumns.add(refCol);
              } else {
                final matched = entityAliases[ent] ?? ent;
                bool found = false;
                for (final jb in joinBuilders) {
                  if (jb.targetTable == matched || jb.alias == matched) {
                    if (!jb.projectedColumns.contains(refCol)) jb.projectedColumns.add(refCol);
                    found = true;
                    break;
                  }
                }
                if (!found && currentJoinIndex != null) {
                  if (!joinBuilders[currentJoinIndex].projectedColumns.contains(refCol)) {
                    joinBuilders[currentJoinIndex].projectedColumns.add(refCol);
                  }
                } else if (!found) {
                  if (!rootColumns.contains(refCol)) rootColumns.add(refCol);
                }
              }
            } else {
              // Unqualified column: assign to currently chained join stage if present, else root
              if (currentJoinIndex == null) {
                if (!rootColumns.contains(refCol)) rootColumns.add(refCol);
              } else {
                if (!joinBuilders[currentJoinIndex].projectedColumns.contains(refCol)) {
                  joinBuilders[currentJoinIndex].projectedColumns.add(refCol);
                }
              }
            }
          }
        }
      } else if (methodName == 'where') {
        _advance();
        final whereNode = _parseFluentWhere(primaryTable);

        _routeWherePredicate(
          whereNode,
          primaryTable: primaryTable,
          entityAliases: entityAliases,
          currentJoinIndex: currentJoinIndex,
          joinBuilders: joinBuilders,
          onRouteRoot: (expr) {
            if (rootWhere == null) {
              rootWhere = TtqlWherePredicateNode(
                entityAlias: whereNode.entityAlias,
                rootExpression: expr,
              );
            } else {
              rootWhere = TtqlWherePredicateNode(
                entityAlias: rootWhere!.entityAlias,
                rootExpression: TtqlBinaryLogicalExpression(
                  left: rootWhere!.rootExpression,
                  operator: 'AND',
                  right: expr,
                ),
              );
            }
          },
          onRouteJoin: (joinIdx, expr) {
            final jb = joinBuilders[joinIdx];
            if (jb.filterCondition == null) {
              jb.filterCondition = expr;
            } else {
              jb.filterCondition = TtqlBinaryLogicalExpression(
                left: jb.filterCondition!,
                operator: 'AND',
                right: expr,
              );
            }
          },
        );
      } else if (methodName == 'innerjoin' ||
          methodName == 'leftjoin' ||
          methodName == 'rightjoin' ||
          methodName == 'fullouterjoin' ||
          methodName == 'join') {
        final joinBuilder = _parseFluentJoin(primaryTable, entityAliases);
        joinBuilders.add(joinBuilder);
        currentJoinIndex = joinBuilders.length - 1;
      } else if (methodName == 'groupby') {
        _advance();
        final cols = _parseGroupByColumns(primaryTable);
        groupByColumns.addAll(cols);
        for (final g in cols) {
          final parts = g.split('.');
          final col = parts.last;
          final ent = parts.length > 1 ? parts.first : null;
          if (ent != null) {
            if (ent == primaryTable || entityAliases[ent] == primaryTable) {
              if (!rootColumns.contains(col)) rootColumns.add(col);
            } else {
              final matched = entityAliases[ent] ?? ent;
              for (final jb in joinBuilders) {
                if (jb.targetTable == matched || jb.alias == matched) {
                  if (!jb.projectedColumns.contains(col)) jb.projectedColumns.add(col);
                  break;
                }
              }
            }
          } else {
            if (currentJoinIndex == null) {
              if (!rootColumns.contains(col)) rootColumns.add(col);
            } else {
              if (!joinBuilders[currentJoinIndex].projectedColumns.contains(col)) {
                joinBuilders[currentJoinIndex].projectedColumns.add(col);
              }
            }
          }
        }
      } else if (methodName == 'having') {
        _advance();
        final havingNode = _parseFluentWhere(primaryTable);
        if (havingPredicate == null) {
          havingPredicate = havingNode.rootExpression;
        } else {
          havingPredicate = TtqlBinaryLogicalExpression(
            left: havingPredicate,
            operator: 'AND',
            right: havingNode.rootExpression,
          );
        }
      } else if (methodName == 'orderby') {
        _advance();
        final orders = _parseFluentOrderByList(primaryTable);
        orderBys.addAll(orders);
      } else if (methodName == 'limit') {
        _advance();
        limit = _parseLimit();
      } else if (methodName == 'offset' || methodName == 'skip') {
        _advance();
        offset = _parseLimit();
      } else {
        throw TtqlParseException(
          'Expected ".select", ".where", ".innerJoin", ".leftJoin", ".rightJoin", ".fullOuterJoin", ".groupBy", ".having", ".orderBy", ".limit", or ".offset", found "${methodToken.value}"',
          line: methodToken.line,
          column: methodToken.column,
        );
      }
    }

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

    final rootInvocation = TtqlQueryInvocationNode(
      engineType: primaryEngine,
      connectionId: primaryRef.connectionId ?? 'default',
      targetTableOrCollection: primaryTable,
      projectedColumns: rootColumns,
      entityAlias: primaryRef.alias ?? primaryTable,
      wherePredicate: rootWhere,
    );

    return TtqlScriptNode(
      declaredConstants: Map.from(_constantValues),
      connectionAliases: Map.from(_connectionAliases),
      entityAliases: Map.from(entityAliases),
      rootInvocations: [rootInvocation],
      joins: joinBuilders.map((b) => b.build()).toList(),
      orderBys: orderBys,
      limit: limit,
      offset: offset,
      groupByColumns: groupByColumns,
      havingPredicate: havingPredicate,
      projections: queryProjections,
    );
  }

  _FluentTableRef _parseFluentTableRef() {
    String? connId;
    String tableName = '';
    String? alias;

    if (_check(TtqlTokenType.stringLiteral)) {
      tableName = _advance().value;
    } else if (_check(TtqlTokenType.identifier)) {
      final firstId = _advance().value;
      if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        _advance(); // consume '.'
        connId = firstId;
        if (_check(TtqlTokenType.identifier) && _peek().value == 'tables') {
          _advance(); // consume 'tables'
          if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
            _advance(); // consume '.'
            tableName = _consume(TtqlTokenType.identifier, 'Expected table name after tables.').value;
          } else if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
            _advance(); // consume '['
            if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
              tableName = _advance().value;
            }
            _consumePunctuation(']', 'Expected "]" closing table access');
          }
        } else {
          tableName = _consume(TtqlTokenType.identifier, 'Expected table name after connection alias').value;
        }
      } else {
        tableName = firstId;
      }
    } else {
      throw TtqlParseException('Expected table reference in from() or join()', line: _peek().line, column: _peek().column);
    }

    // Check for inline .as('alias')
    if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
      final mark = _current;
      _advance(); // consume '.'
      if (_check(TtqlTokenType.identifier) && _peek().value.toLowerCase() == 'as') {
        _advance(); // consume 'as'
        _consumePunctuation('(', 'Expected "(" after .as');
        if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
          alias = _advance().value;
        }
        _consumePunctuation(')', 'Expected ")" after alias in .as(...)');
      } else {
        _current = mark;
      }
    }

    // Check for "as alias" or ", as: 'alias'"
    if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) && _peek().value.toLowerCase() == 'as') {
      _advance(); // consume 'as'
      alias = _consume(TtqlTokenType.identifier, 'Expected alias identifier after "as"').value;
    } else if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
      final mark = _current;
      _advance(); // consume ','
      if ((_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword)) && _peek().value.toLowerCase() == 'as') {
        _advance();
        if (_check(TtqlTokenType.punctuation) && _peek().value == ':') {
          _advance();
          if (_check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.identifier)) {
            alias = _advance().value;
          }
        } else {
          _current = mark;
        }
      } else {
        _current = mark; // rewind if not "as:"
      }
    }

    return _FluentTableRef(connectionId: connId, tableName: tableName, alias: alias);
  }

  DbEngineType _resolveEngineForConnection(String? connectionName) {
    if (connectionName == null) {
      return DbEngineType.postgres;
    }
    final targetName = _connectionAliases[connectionName] ?? connectionName;

    if (environmentContext != null) {
      final desc = environmentContext!.resolveAlias(targetName) ?? environmentContext!.resolveAlias(connectionName);
      if (desc != null) {
        return desc.engineType;
      }
    }

    final direct = DbEngineRegistry.tryResolve(connectionName) ?? DbEngineRegistry.tryResolve(targetName);
    if (direct != null) {
      return direct;
    }

    final parts = targetName.split(RegExp(r'[^a-zA-Z0-9]'));
    for (final part in parts.reversed) {
      final resolved = DbEngineRegistry.tryResolve(part);
      if (resolved != null) {
        return resolved;
      }
    }

    return DbEngineType.postgres;
  }

  TtqlWherePredicateNode _parseFluentWhere(String defaultEntityAlias) {
    _consumePunctuation('(', 'Expected "(" after "where"');

    String entityAlias = defaultEntityAlias;
    if (_check(TtqlTokenType.punctuation) && _peek().value == '(') {
      if (_isArrowFunction()) {
        _advance(); // consume '('
        entityAlias = _consume(TtqlTokenType.identifier, 'Expected parameter in where').value;
        _consumePunctuation(')', 'Expected ")" after parameter');
        _consumePunctuation('=>', 'Expected "=>" in where');
      }
    } else if (_check(TtqlTokenType.identifier) && _current + 1 < tokens.length && tokens[_current + 1].value == '=>') {
      entityAlias = _advance().value;
      _advance(); // consume '=>'
    }

    final rootExpr = _parseLogicalOr(entityAlias);
    _consumePunctuation(')', 'Expected ")" closing where clause');

    return TtqlWherePredicateNode(
      entityAlias: entityAlias,
      rootExpression: rootExpr,
    );
  }

  bool _isArrowFunction() {
    if (_current + 3 < tokens.length) {
      return tokens[_current].value == '(' &&
          tokens[_current + 1].type == TtqlTokenType.identifier &&
          tokens[_current + 2].value == ')' &&
          tokens[_current + 3].value == '=>';
    }
    return false;
  }

  bool _isAggregateFunctionCall() {
    if (_isAtEnd()) return false;
    final val = _peek().value.toLowerCase();
    if (val == 'count' || val == 'sum' || val == 'avg' || val == 'min' || val == 'max') {
      if (_current + 1 < tokens.length && tokens[_current + 1].value == '(') {
        return true;
      }
    }
    return false;
  }

  String _parseAggregateCallString() {
    final fnToken = _advance();
    final fnName = fnToken.value.toUpperCase();
    _consumePunctuation('(', 'Expected "(" after aggregate function');
    String arg = '*';
    if (!(_check(TtqlTokenType.punctuation) && _peek().value == ')')) {
      if (_check(TtqlTokenType.operator) && _peek().value == '*') {
        _advance();
        arg = '*';
      } else if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.keyword)) {
        final firstId = _advance().value;
        if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
          _advance();
          final secondId = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword))
              ? _advance().value
              : _consume(TtqlTokenType.identifier, 'Expected column name after "."').value;
          arg = '"$secondId"';
        } else {
          arg = '"$firstId"';
        }
      }
    }
    _consumePunctuation(')', 'Expected ")" after aggregate argument');
    return '$fnName($arg)';
  }

  List<TtqlProjectionItem> _parseFluentSelectProjections(String defaultEntity) {
    _consumePunctuation('(', 'Expected "(" after select');
    final List<TtqlProjectionItem> items = [];

    if (_check(TtqlTokenType.punctuation) && _peek().value == ')') {
      _advance();
      return items;
    }

    if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
      _advance(); // consume '['
      while (!(_check(TtqlTokenType.punctuation) && _peek().value == ']') && !_isAtEnd()) {
        final loopStart = _current;
        if (_check(TtqlTokenType.operator) && _peek().value == '...') {
          _advance();
          final id = _consume(TtqlTokenType.identifier, 'Expected identifier after "..."').value;
          final val = _constantValues[id];
          if (val is List) {
            for (final v in val) {
              final raw = v.toString();
              final dotIndex = raw.indexOf('.');
              if (dotIndex > 0 && dotIndex < raw.length - 1) {
                items.add(TtqlColumnProjection(
                  entityAlias: raw.substring(0, dotIndex),
                  columnName: raw.substring(dotIndex + 1),
                ));
              } else {
                items.add(TtqlColumnProjection(columnName: raw));
              }
            }
          }
        } else if (_isMacroCall()) {
          items.addAll(_expandMacroCall(defaultEntity));
        } else {
          items.add(_parseSingleProjectionItem(defaultEntity));
        }
        if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
          _advance();
        }
        if (_current == loopStart) {
          final stuck = _peek();
          throw TtqlParseException(
            'Unexpected token "${stuck.value}" in select array',
            line: stuck.line,
            column: stuck.column,
          );
        }
      }
      _consumePunctuation(']', 'Expected "]" closing select array');
    } else {
      while (!(_check(TtqlTokenType.punctuation) && _peek().value == ')') && !_isAtEnd()) {
        final loopStart = _current;
        if (_isMacroCall()) {
          items.addAll(_expandMacroCall(defaultEntity));
        } else {
          items.add(_parseSingleProjectionItem(defaultEntity));
        }
        if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
          _advance();
        } else {
          break;
        }
        if (_current == loopStart) {
          final stuck = _peek();
          throw TtqlParseException(
            'Unexpected token "${stuck.value}" in select arguments',
            line: stuck.line,
            column: stuck.column,
          );
        }
      }
    }

    _consumePunctuation(')', 'Expected ")" closing select(...)');
    return items;
  }

  /// Returns true if the current token is an identifier that names a known projection macro
  /// and is immediately followed by `(`.
  bool _isMacroCall() {
    if (!_check(TtqlTokenType.identifier)) return false;
    final name = _peek().value;
    if (!_declaredFunctions.containsKey(name)) return false;
    if (_current + 1 >= tokens.length) return false;
    return tokens[_current + 1].value == '(';
  }

  /// Consumes a macro call `name(arg1, arg2, ...)` and returns the inlined projection items
  /// with the declared parameter names substituted by the caller's entity aliases.
  List<TtqlProjectionItem> _expandMacroCall(String defaultEntity) {
    final nameToken = _advance(); // macro name
    final macro = _declaredFunctions[nameToken.value]!;

    _consumePunctuation('(', 'Expected "(" in macro call "${macro.name}(...)"');

    final List<String> callArgs = [];
    while (!(_check(TtqlTokenType.punctuation) && _peek().value == ')') && !_isAtEnd()) {
      if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword)) {
        callArgs.add(_advance().value);
      } else {
        break;
      }
      if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
        _advance();
      } else {
        break;
      }
    }

    _consumePunctuation(')', 'Expected ")" closing macro call "${macro.name}(...)"');

    // Build replacement mapping from declared parameter names to caller arguments
    final Map<String, String> aliasMap = {};
    for (int i = 0; i < macro.paramNames.length; i++) {
      if (i < callArgs.length) {
        aliasMap[macro.paramNames[i]] = callArgs[i];
      }
    }
    // If macro declared a single parameter and call was passed without arguments, default to defaultEntity
    if (macro.paramNames.length == 1 && callArgs.isEmpty && defaultEntity.isNotEmpty) {
      aliasMap[macro.paramNames.first] = defaultEntity;
    }

    // Inline the macro body, substituting parameter aliases with caller aliases
    return macro.body.map((item) => _rebindAliases(item, aliasMap)).toList();
  }

  /// Returns a copy of [item] with its entityAlias replaced if present in [aliasMap].
  TtqlProjectionItem _rebindAliases(TtqlProjectionItem item, Map<String, String> aliasMap) {
    if (aliasMap.isEmpty) return item;
    if (item is TtqlColumnProjection) {
      final bound = aliasMap[item.entityAlias] ?? item.entityAlias;
      return TtqlColumnProjection(
        columnName: item.columnName,
        entityAlias: bound,
        alias: item.alias,
      );
    } else if (item is TtqlAggregateProjection) {
      final bound = aliasMap[item.entityAlias] ?? item.entityAlias;
      return TtqlAggregateProjection(
        functionName: item.functionName,
        argumentColumn: item.argumentColumn,
        entityAlias: bound,
        alias: item.alias,
      );
    }
    return item;
  }

  TtqlProjectionItem _parseSingleProjectionItem(String defaultEntity) {
    if (_isAggregateFunctionCall()) {
      final fnToken = _advance();
      final fnName = fnToken.value.toUpperCase();
      _consumePunctuation('(', 'Expected "(" after aggregate function');
      String? argCol;
      String? entAlias;
      if (!(_check(TtqlTokenType.punctuation) && _peek().value == ')')) {
        if (_check(TtqlTokenType.operator) && _peek().value == '*') {
          _advance();
        } else if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.stringLiteral) || _check(TtqlTokenType.keyword)) {
          final first = _advance().value;
          if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
            _advance();
            final second = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword))
                ? _advance().value
                : _consume(TtqlTokenType.identifier, 'Expected column name after "."').value;
            entAlias = first;
            argCol = second;
          } else {
            argCol = first;
          }
        }
      }
      _consumePunctuation(')', 'Expected ")" after aggregate argument');

      String? alias;
      if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) && _peek().value.toLowerCase() == 'as') {
        _advance(); // 'as'
        if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.stringLiteral)) {
          alias = _advance().value;
        }
      } else if (_check(TtqlTokenType.punctuation) && _peek().value == ':') {
        _advance(); // ':'
        if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.stringLiteral)) {
          alias = _advance().value;
        }
      }

      return TtqlAggregateProjection(
        functionName: fnName,
        argumentColumn: argCol,
        entityAlias: entAlias,
        alias: alias,
      );
    }

    // Arrow function: o => o.status
    if (_check(TtqlTokenType.punctuation) && _peek().value == '(' && _isArrowFunction()) {
      _advance(); // '('
      final param = _consume(TtqlTokenType.identifier, 'Expected parameter').value;
      _consumePunctuation(')', 'Expected ")"');
      _consumePunctuation('=>', 'Expected "=>"');
      _consumeIdentifier(param, 'Expected parameter');
      _consumePunctuation('.', 'Expected "."');
      final col = _consume(TtqlTokenType.identifier, 'Expected column name').value;
      return TtqlColumnProjection(columnName: col, entityAlias: param);
    } else if (_check(TtqlTokenType.identifier) && _current + 1 < tokens.length && tokens[_current + 1].value == '=>') {
      final param = _advance().value;
      _advance(); // '=>'
      _consumeIdentifier(param, 'Expected parameter');
      _consumePunctuation('.', 'Expected "."');
      final col = _consume(TtqlTokenType.identifier, 'Expected column name').value;
      return TtqlColumnProjection(columnName: col, entityAlias: param);
    }

    // String literal: 'col'
    if (_check(TtqlTokenType.stringLiteral)) {
      final col = _advance().value;
      String? alias;
      if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) && _peek().value.toLowerCase() == 'as') {
        _advance(); // as
        alias = _advance().value;
      }
      return TtqlColumnProjection(columnName: col, alias: alias);
    }

    // Identifier or keyword: col or entity.col
    if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword)) {
      final first = _advance().value;
      String? entAlias;
      String colName = first;

      if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        _advance();
        entAlias = first;
        colName = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword))
            ? _advance().value
            : _consume(TtqlTokenType.identifier, 'Expected column name after "."').value;
      }

      String? alias;
      if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) && _peek().value.toLowerCase() == 'as') {
        _advance(); // as
        alias = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.stringLiteral))
            ? _advance().value
            : null;
      }

      return TtqlColumnProjection(
        columnName: colName,
        entityAlias: entAlias,
        alias: alias,
      );
    }

    throw TtqlParseException(
      'Expected column projection or aggregate function in select()',
      line: _peek().line,
      column: _peek().column,
    );
  }

  List<String> _parseGroupByColumns(String defaultEntity) {
    _consumePunctuation('(', 'Expected "(" after groupBy');
    final List<String> groupCols = [];

    if (_check(TtqlTokenType.punctuation) && _peek().value == ')') {
      _advance();
      return groupCols;
    }

    if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
      _advance(); // '['
      while (!(_check(TtqlTokenType.punctuation) && _peek().value == ']') && !_isAtEnd()) {
        final loopStart = _current;
        groupCols.add(_parseSingleGroupCol(defaultEntity));
        if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
          _advance();
        }
        if (_current == loopStart) {
          final stuck = _peek();
          throw TtqlParseException(
            'Unexpected token "${stuck.value}" in groupBy array',
            line: stuck.line,
            column: stuck.column,
          );
        }
      }
      _consumePunctuation(']', 'Expected "]" closing groupBy array');
    } else {
      while (!(_check(TtqlTokenType.punctuation) && _peek().value == ')') && !_isAtEnd()) {
        final loopStart = _current;
        groupCols.add(_parseSingleGroupCol(defaultEntity));
        if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
          _advance();
        } else {
          break;
        }
        if (_current == loopStart) {
          final stuck = _peek();
          throw TtqlParseException(
            'Unexpected token "${stuck.value}" in groupBy arguments',
            line: stuck.line,
            column: stuck.column,
          );
        }
      }
    }

    _consumePunctuation(')', 'Expected ")" closing groupBy(...)');
    return groupCols;
  }

  String _parseSingleGroupCol(String defaultEntity) {
    if (_check(TtqlTokenType.punctuation) && _peek().value == '(' && _isArrowFunction()) {
      _advance(); // '('
      final param = _consume(TtqlTokenType.identifier, 'Expected parameter in arrow function').value;
      _consumePunctuation(')', 'Expected ")"');
      _consumePunctuation('=>', 'Expected "=>"');
      _consumeIdentifier(param, 'Expected parameter access in arrow function');
      _consumePunctuation('.', 'Expected "."');
      final col = _consume(TtqlTokenType.identifier, 'Expected column name in groupBy').value;
      return '$param.$col';
    } else if (_check(TtqlTokenType.identifier) && _current + 1 < tokens.length && tokens[_current + 1].value == '=>') {
      final param = _advance().value;
      _advance(); // '=>'
      _consumeIdentifier(param, 'Expected parameter access in arrow function');
      _consumePunctuation('.', 'Expected "."');
      final col = _consume(TtqlTokenType.identifier, 'Expected column name in groupBy').value;
      return '$param.$col';
    } else if (_check(TtqlTokenType.stringLiteral)) {
      return _advance().value;
    } else if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword)) {
      final first = _advance().value;
      if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        _advance();
        final second = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword))
            ? _advance().value
            : _consume(TtqlTokenType.identifier, 'Expected column name after "."').value;
        return '$first.$second';
      }
      return first;
    } else {
      throw TtqlParseException('Expected column name or arrow function in groupBy');
    }
  }

  List<TtqlOrderByNode> _parseFluentOrderByList(String defaultEntity) {
    _consumePunctuation('(', 'Expected "(" after orderBy');
    final List<TtqlOrderByNode> orderBys = [];

    while (!(_check(TtqlTokenType.punctuation) && _peek().value == ')') && !_isAtEnd()) {
      final loopStart = _current;
      if (_check(TtqlTokenType.punctuation) && _peek().value == '[') {
        _advance(); // '['
        final node = _parseSingleOrderBy(defaultEntity);
        _consumePunctuation(']', 'Expected "]" closing orderBy element');
        orderBys.add(node);
      } else {
        final node = _parseSingleOrderBy(defaultEntity);
        orderBys.add(node);
      }
      if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
        _advance();
      } else {
        break;
      }
      if (_current == loopStart) {
        final stuck = _peek();
        throw TtqlParseException(
          'Unexpected token "${stuck.value}" in orderBy arguments',
          line: stuck.line,
          column: stuck.column,
        );
      }
    }

    _consumePunctuation(')', 'Expected ")" closing orderBy');
    return orderBys;
  }

  TtqlOrderByNode _parseSingleOrderBy(String defaultEntity) {
    String entityAlias = defaultEntity;
    String fieldName;

    if (_check(TtqlTokenType.punctuation) && _peek().value == '(' && _isArrowFunction()) {
      _advance(); // '('
      entityAlias = _consume(TtqlTokenType.identifier, 'Expected parameter in orderBy').value;
      _consumePunctuation(')', 'Expected ")"');
      _consumePunctuation('=>', 'Expected "=>"');
      _consumeIdentifier(entityAlias, 'Expected entity parameter in property access');
      _consumePunctuation('.', 'Expected "."');
      fieldName = _consume(TtqlTokenType.identifier, 'Expected column name in orderBy').value;
    } else if (_check(TtqlTokenType.identifier) && _current + 1 < tokens.length && tokens[_current + 1].value == '=>') {
      entityAlias = _advance().value;
      _advance(); // '=>'
      _consumeIdentifier(entityAlias, 'Expected entity parameter in property access');
      _consumePunctuation('.', 'Expected "."');
      fieldName = _consume(TtqlTokenType.identifier, 'Expected column name in orderBy').value;
    } else if (_check(TtqlTokenType.stringLiteral)) {
      fieldName = _advance().value;
    } else if (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword)) {
      final firstId = _advance().value;
      if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
        _advance();
        final secondId = (_check(TtqlTokenType.identifier) || _check(TtqlTokenType.keyword))
            ? _advance().value
            : _consume(TtqlTokenType.identifier, 'Expected column name after "."').value;
        if (_check(TtqlTokenType.punctuation) && _peek().value == '.') {
          _advance();
          final thirdId = _consume(TtqlTokenType.identifier, 'Expected column name after "."').value;
          entityAlias = secondId;
          fieldName = thirdId;
        } else {
          entityAlias = firstId;
          fieldName = secondId;
        }
      } else {
        fieldName = firstId;
      }
    } else {
      throw TtqlParseException('Expected column name or arrow function in orderBy');
    }

    String direction = 'ASC';
    if (_check(TtqlTokenType.punctuation) && _peek().value == ',') {
      final next = _peekNext();
      final valUpper = next.value.toUpperCase();
      if (valUpper == 'ASC' || valUpper == 'DESC') {
        _advance(); // consume ','
        final dirToken = _advance();
        final raw = dirToken.value;
        final resolved = _constantValues[raw]?.toString() ?? raw;
        direction = resolved.toUpperCase() == 'DESC' ? 'DESC' : 'ASC';
      }
    }

    return TtqlOrderByNode(
      fieldName: fieldName,
      direction: direction,
      entityAlias: entityAlias,
    );
  }

  _FluentJoinBuilder _parseFluentJoin(String primaryTable, Map<String, String> entityAliases) {
    final joinToken = _advance();
    final rawMethod = joinToken.value.toLowerCase();
    final String joinType;
    if (rawMethod == 'leftjoin') {
      joinType = 'leftJoin';
    } else if (rawMethod == 'rightjoin') {
      joinType = 'rightJoin';
    } else if (rawMethod == 'fullouterjoin') {
      joinType = 'fullOuterJoin';
    } else {
      joinType = 'innerJoin';
    }

    _consumePunctuation('(', 'Expected "(" after "$rawMethod"');
    final targetRef = _parseFluentTableRef();
    final targetTable = targetRef.tableName;

    entityAliases[targetTable] = targetTable;
    if (targetRef.connectionId != null) {
      entityAliases['${targetRef.connectionId}.$targetTable'] = targetTable;
      entityAliases[targetRef.connectionId!] = targetTable;
    }
    if (targetRef.alias != null) {
      entityAliases[targetRef.alias!] = targetTable;
    } else if (targetTable.isNotEmpty && !entityAliases.containsKey(targetTable[0].toLowerCase())) {
      entityAliases[targetTable[0].toLowerCase()] = targetTable;
    }

    _consumePunctuation(',', 'Expected "," before "on:" join condition');

    if ((_check(TtqlTokenType.keyword) || _check(TtqlTokenType.identifier)) && _peek().value.toLowerCase() == 'on') {
      _advance();
      if (_check(TtqlTokenType.punctuation) && _peek().value == ':') {
        _advance();
      }
    }

    TtqlComparisonExpression joinComparison;

    if (_check(TtqlTokenType.stringLiteral)) {
      final col = _advance().value;
      joinComparison = TtqlComparisonExpression(
        fieldName: col,
        operator: '=',
        rightOperand: col,
        isRightOperandFieldReference: true,
        rightFieldEntityAlias: primaryTable,
        entityAlias: targetTable,
      );
    } else if (_check(TtqlTokenType.identifier) &&
        (_peekNext().value == ')' || _peekNext().value == ',')) {
      final col = _advance().value;
      joinComparison = TtqlComparisonExpression(
        fieldName: col,
        operator: '=',
        rightOperand: col,
        isRightOperandFieldReference: true,
        rightFieldEntityAlias: primaryTable,
        entityAlias: targetTable,
      );
    } else {
      var comp = _parseComparison(
        targetTable,
        isJoinCondition: true,
        defaultRightEntity: primaryTable,
      );

      final leftQualifier = comp.entityAlias;
      final rightQualifier = comp.rightFieldEntityAlias;

      final isLeftTarget = leftQualifier != null &&
          (leftQualifier == targetTable ||
              leftQualifier == targetRef.alias ||
              entityAliases[leftQualifier] == targetTable);
      final isRightTarget = rightQualifier != null &&
          (rightQualifier == targetTable ||
              rightQualifier == targetRef.alias ||
              entityAliases[rightQualifier] == targetTable);

      if (isRightTarget && !isLeftTarget) {
        // e.g. on: c.customer_id == s.customer_id
        final localCol = comp.rightOperand.toString().split('.').last;
        final parentCol = comp.fieldName;
        final parentAlias = leftQualifier ?? primaryTable;
        comp = TtqlComparisonExpression(
          fieldName: localCol,
          operator: comp.operator,
          rightOperand: parentCol,
          isRightOperandFieldReference: true,
          rightFieldEntityAlias: parentAlias,
          entityAlias: targetRef.alias ?? targetTable,
        );
      } else if (isLeftTarget) {
        // e.g. on: s.customer_id == c.customer_id
        final localCol = comp.fieldName;
        final parentCol = comp.rightOperand.toString().split('.').last;
        final parentAlias = rightQualifier ?? primaryTable;
        comp = TtqlComparisonExpression(
          fieldName: localCol,
          operator: comp.operator,
          rightOperand: parentCol,
          isRightOperandFieldReference: true,
          rightFieldEntityAlias: parentAlias,
          entityAlias: targetRef.alias ?? targetTable,
        );
      } else {
        joinComparison = TtqlComparisonExpression(
          fieldName: comp.fieldName,
          operator: comp.operator,
          rightOperand: comp.rightOperand,
          isRightOperandFieldReference: true,
          rightFieldEntityAlias: comp.rightFieldEntityAlias ?? primaryTable,
          entityAlias: comp.entityAlias ?? targetTable,
        );
        comp = joinComparison;
      }
      joinComparison = comp;
    }

    _consumePunctuation(')', 'Expected ")" closing "$rawMethod"');

    final targetEngine = _resolveEngineForConnection(targetRef.connectionId);
    final resolvedParentAlias = joinComparison.rightFieldEntityAlias ?? primaryTable;

    return _FluentJoinBuilder(
      joinType: joinType,
      parentEntityAlias: resolvedParentAlias,
      engineType: targetEngine,
      connectionId: targetRef.connectionId ?? 'default',
      targetTable: targetTable,
      alias: targetRef.alias,
      joinCondition: joinComparison,
    );
  }

  void _routeWherePredicate(
    TtqlWherePredicateNode whereNode, {
    required String primaryTable,
    required Map<String, String> entityAliases,
    required int? currentJoinIndex,
    required List<_FluentJoinBuilder> joinBuilders,
    required void Function(TtqlExpression) onRouteRoot,
    required void Function(int joinIdx, TtqlExpression) onRouteJoin,
  }) {
    final terms = _extractAndTerms(whereNode.rootExpression);

    for (final term in terms) {
      final target = _resolveTermTargetTable(
        term,
        primaryTable: primaryTable,
        entityAliases: entityAliases,
        currentJoinIndex: currentJoinIndex,
        joinBuilders: joinBuilders,
      );

      if (target == null || target == primaryTable) {
        onRouteRoot(term);
      } else {
        int matchedJoin = -1;
        for (int i = 0; i < joinBuilders.length; i++) {
          if (joinBuilders[i].targetTable == target ||
              joinBuilders[i].alias == target) {
            matchedJoin = i;
            break;
          }
        }
        if (matchedJoin != -1) {
          onRouteJoin(matchedJoin, term);
        } else if (currentJoinIndex != null) {
          onRouteJoin(currentJoinIndex, term);
        } else {
          onRouteRoot(term);
        }
      }
    }
  }

  String? _resolveTermTargetTable(
    TtqlExpression expr, {
    required String primaryTable,
    required Map<String, String> entityAliases,
    required int? currentJoinIndex,
    required List<_FluentJoinBuilder> joinBuilders,
  }) {
    if (expr is TtqlComparisonExpression) {
      if (expr.entityAlias != null) {
        final resolved = entityAliases[expr.entityAlias!] ?? expr.entityAlias!;
        return resolved;
      }
      if (currentJoinIndex == null) {
        return primaryTable;
      }
      return joinBuilders[currentJoinIndex].targetTable;
    }
    return null;
  }

  static List<TtqlExpression> _extractAndTerms(TtqlExpression expr) {
    if (expr is TtqlBinaryLogicalExpression && expr.operator == 'AND') {
      return [..._extractAndTerms(expr.left), ..._extractAndTerms(expr.right)];
    }
    return [expr];
  }


  TtqlToken _peekNext() {
    if (_current + 1 < tokens.length) {
      return tokens[_current + 1];
    }
    return tokens.last;
  }
}

class _FluentTableRef {
  final String? connectionId;
  final String tableName;
  final String? alias;
  const _FluentTableRef({this.connectionId, required this.tableName, this.alias});
}

class _FluentJoinBuilder {
  final String joinType;
  final String parentEntityAlias;
  final DbEngineType engineType;
  final String connectionId;
  final String targetTable;
  String? alias;
  final TtqlExpression joinCondition;
  List<String> projectedColumns = [];
  TtqlExpression? filterCondition;

  _FluentJoinBuilder({
    required this.joinType,
    required this.parentEntityAlias,
    required this.engineType,
    required this.connectionId,
    required this.targetTable,
    this.alias,
    required this.joinCondition,
  });

  TtqlJoinNode build() {
    TtqlExpression root = joinCondition;
    if (filterCondition != null) {
      root = TtqlBinaryLogicalExpression(
        left: joinCondition,
        operator: 'AND',
        right: filterCondition!,
      );
    }

    return TtqlJoinNode(
      joinType: joinType,
      parentEntityAlias: parentEntityAlias,
      queryInvocation: TtqlQueryInvocationNode(
        engineType: engineType,
        connectionId: connectionId,
        targetTableOrCollection: targetTable,
        projectedColumns: projectedColumns,
        entityAlias: alias ?? targetTable,
        wherePredicate: TtqlWherePredicateNode(
          entityAlias: alias ?? targetTable,
          rootExpression: root,
        ),
      ),
    );
  }
}

/// Internal representation of a parsed `declare function` projection macro.
/// Stores the pre-parsed projection body and declared parameter names.
/// At call sites, the parser substitutes declared parameter aliases with caller aliases via [TtqlParser._rebindAliases].
class _TtqlProjectionMacro {
  final String name;
  final List<String> paramNames;
  final List<TtqlProjectionItem> body;

  const _TtqlProjectionMacro({
    required this.name,
    required this.paramNames,
    required this.body,
  });
}
