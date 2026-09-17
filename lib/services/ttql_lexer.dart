import 'package:ttql/constants/ttql_constants.dart';
import 'package:ttql/models/ttql_exceptions.dart';
import 'package:ttql/models/ttql_token.dart';

/// Lexical analyzer that scans TTQL source scripts into a sequence of [TtqlToken]s.
class TtqlLexer {
  final String source;
  int _cursor = 0;
  int _line = 1;
  int _column = 1;

  TtqlLexer(this.source);

  /// Scans the entire source into a list of tokens ending with [TtqlTokenType.eof].
  List<TtqlToken> tokenize() {
    final List<TtqlToken> tokens = [];
    while (!_isAtEnd()) {
      _skipWhitespaceAndComments();
      if (_isAtEnd()) break;

      final startLine = _line;
      final startCol = _column;
      final startOffset = _cursor;
      final char = _advance();

      switch (char) {
        case '(':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: '(', line: startLine, column: startCol, offset: startOffset));
          break;
        case ')':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: ')', line: startLine, column: startCol, offset: startOffset));
          break;
        case '{':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: '{', line: startLine, column: startCol, offset: startOffset));
          break;
        case '}':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: '}', line: startLine, column: startCol, offset: startOffset));
          break;
        case '[':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: '[', line: startLine, column: startCol, offset: startOffset));
          break;
        case ']':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: ']', line: startLine, column: startCol, offset: startOffset));
          break;
        case ',':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: ',', line: startLine, column: startCol, offset: startOffset));
          break;
        case '.':
          if (_peek() == '.' && _cursor + 1 < source.length && source[_cursor + 1] == '.') {
            _advance();
            _advance();
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '...', line: startLine, column: startCol, offset: startOffset));
          } else {
            tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: '.', line: startLine, column: startCol, offset: startOffset));
          }
          break;
        case ';':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: ';', line: startLine, column: startCol, offset: startOffset));
          break;
        case ':':
          tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: ':', line: startLine, column: startCol, offset: startOffset));
          break;
        case '=':
          if (_match('>')) {
            tokens.add(TtqlToken(type: TtqlTokenType.punctuation, value: '=>', line: startLine, column: startCol, offset: startOffset));
          } else if (_match('=')) {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '==', line: startLine, column: startCol, offset: startOffset));
          } else {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '=', line: startLine, column: startCol, offset: startOffset));
          }
          break;
        case '<':
          if (_match('=')) {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '<=', line: startLine, column: startCol, offset: startOffset));
          } else if (_match('>')) {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '<>', line: startLine, column: startCol, offset: startOffset));
          } else {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '<', line: startLine, column: startCol, offset: startOffset));
          }
          break;
        case '>':
          if (_match('=')) {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '>=', line: startLine, column: startCol, offset: startOffset));
          } else {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '>', line: startLine, column: startCol, offset: startOffset));
          }
          break;
        case '!':
          if (_match('=')) {
            tokens.add(TtqlToken(type: TtqlTokenType.operator, value: '!=', line: startLine, column: startCol, offset: startOffset));
          } else {
            tokens.add(TtqlToken(type: TtqlTokenType.keyword, value: 'NOT', line: startLine, column: startCol, offset: startOffset));
          }
          break;
        case '&':
          if (_match('&')) {
            tokens.add(TtqlToken(type: TtqlTokenType.keyword, value: 'AND', line: startLine, column: startCol, offset: startOffset));
            break;
          }
          throw TtqlParseException('Unexpected character "&"', line: startLine, column: startCol);
        case '|':
          if (_match('|')) {
            tokens.add(TtqlToken(type: TtqlTokenType.keyword, value: 'OR', line: startLine, column: startCol, offset: startOffset));
            break;
          }
          throw TtqlParseException('Unexpected character "|"', line: startLine, column: startCol);
        case '\'':
        case '"':
          tokens.add(_scanString(char, startLine, startCol, startOffset));
          break;
        default:
          if (_isDigit(char)) {
            tokens.add(_scanNumber(char, startLine, startCol, startOffset));
          } else if (_isAlpha(char)) {
            tokens.add(_scanIdentifierOrKeyword(char, startLine, startCol, startOffset));
          } else {
            throw TtqlParseException(
              'Unexpected character "$char"',
              line: startLine,
              column: startCol,
            );
          }
      }
    }

    tokens.add(TtqlToken(
      type: TtqlTokenType.eof,
      value: '',
      line: _line,
      column: _column,
      offset: _cursor,
    ));
    return tokens;
  }

  TtqlToken _scanString(String quoteChar, int startLine, int startCol, int startOffset) {
    final buffer = StringBuffer();
    while (!_isAtEnd() && _peek() != quoteChar) {
      if (_peek() == '\n') {
        _line++;
        _column = 1;
      }
      if (_peek() == '\\' && _cursor + 1 < source.length) {
        _advance();
        final escaped = _advance();
        buffer.write(escaped);
      } else {
        buffer.write(_advance());
      }
    }

    if (_isAtEnd()) {
      throw TtqlParseException('Unterminated string literal', line: startLine, column: startCol);
    }

    _advance(); // Consume closing quote
    return TtqlToken(
      type: TtqlTokenType.stringLiteral,
      value: buffer.toString(),
      line: startLine,
      column: startCol,
      offset: startOffset,
    );
  }

  TtqlToken _scanNumber(String firstChar, int startLine, int startCol, int startOffset) {
    final buffer = StringBuffer(firstChar);
    while (!_isAtEnd() && (_isDigit(_peek()) || _peek() == '.')) {
      buffer.write(_advance());
    }
    return TtqlToken(
      type: TtqlTokenType.numberLiteral,
      value: buffer.toString(),
      line: startLine,
      column: startCol,
      offset: startOffset,
    );
  }

  TtqlToken _scanIdentifierOrKeyword(String firstChar, int startLine, int startCol, int startOffset) {
    final buffer = StringBuffer(firstChar);
    while (!_isAtEnd() && _isAlphaNumericOrUnderscore(_peek())) {
      buffer.write(_advance());
    }
    final text = buffer.toString();

    // Check for forbidden mutations
    if (TtqlConstants.forbiddenMutationKeywords.contains(text.toUpperCase())) {
      throw TtqlSecurityException(
        'Mutation operation "$text" is forbidden. TTQL is strictly read-only.',
        keyword: text,
      );
    }

    final lower = text.toLowerCase();
    final upper = text.toUpperCase();

    if (lower == TtqlConstants.keywordFrom.toLowerCase() ||
        lower == TtqlConstants.keywordOn.toLowerCase() ||
        lower == TtqlConstants.keywordJoin.toLowerCase() ||
        lower == TtqlConstants.keywordSelect.toLowerCase() ||
        lower == TtqlConstants.keywordWhere.toLowerCase() ||
        lower == TtqlConstants.keywordInnerJoin.toLowerCase() ||
        lower == TtqlConstants.keywordLeftJoin.toLowerCase() ||
        lower == TtqlConstants.keywordRightJoin.toLowerCase() ||
        lower == TtqlConstants.keywordFullOuterJoin.toLowerCase() ||
        lower == TtqlConstants.keywordConst.toLowerCase() ||
        lower == TtqlConstants.keywordIs.toLowerCase() ||
        lower == TtqlConstants.keywordOrderBy.toLowerCase() ||
        lower == TtqlConstants.keywordLimit.toLowerCase() ||
        lower == TtqlConstants.keywordOffset.toLowerCase() ||
        lower == TtqlConstants.keywordSkip.toLowerCase() ||
        lower == TtqlConstants.keywordGroupBy.toLowerCase() ||
        lower == TtqlConstants.keywordHaving.toLowerCase() ||
        lower == TtqlConstants.keywordAs.toLowerCase() ||
        upper == TtqlConstants.keywordAnd ||
        upper == TtqlConstants.keywordOr ||
        upper == TtqlConstants.keywordNot ||
        upper == TtqlConstants.keywordLike ||
        upper == TtqlConstants.keywordIn) {
      return TtqlToken(
        type: TtqlTokenType.keyword,
        value: text,
        line: startLine,
        column: startCol,
        offset: startOffset,
      );
    }

    if (lower == 'true' || lower == 'false') {
      return TtqlToken(
        type: TtqlTokenType.booleanLiteral,
        value: text,
        line: startLine,
        column: startCol,
        offset: startOffset,
      );
    }

    return TtqlToken(
      type: TtqlTokenType.identifier,
      value: text,
      line: startLine,
      column: startCol,
      offset: startOffset,
    );
  }

  void _skipWhitespaceAndComments() {
    while (!_isAtEnd()) {
      final char = _peek();
      if (char == ' ' || char == '\r' || char == '\t') {
        _advance();
      } else if (char == '\n') {
        _line++;
        _column = 0;
        _advance();
      } else if (char == '/' && _cursor + 1 < source.length && source[_cursor + 1] == '/') {
        // Line comment
        while (!_isAtEnd() && _peek() != '\n') {
          _advance();
        }
      } else if (char == '/' && _cursor + 1 < source.length && source[_cursor + 1] == '*') {
        // Block comment
        _advance(); // '/'
        _advance(); // '*'
        while (!_isAtEnd()) {
          if (_peek() == '*' && _cursor + 1 < source.length && source[_cursor + 1] == '/') {
            _advance(); // '*'
            _advance(); // '/'
            break;
          }
          if (_peek() == '\n') {
            _line++;
            _column = 0;
          }
          _advance();
        }
      } else {
        break;
      }
    }
  }

  bool _isAtEnd() => _cursor >= source.length;

  String _advance() {
    final char = source[_cursor++];
    _column++;
    return char;
  }

  String _peek() => _isAtEnd() ? '\x00' : source[_cursor];

  bool _match(String expected) {
    if (_isAtEnd() || source[_cursor] != expected) return false;
    _cursor++;
    _column++;
    return true;
  }

  bool _isDigit(String char) => char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;

  bool _isAlpha(String char) {
    final code = char.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95 || code == 36; // A-Z, a-z, _, $
  }

  bool _isAlphaNumericOrUnderscore(String char) => _isAlpha(char) || _isDigit(char);
}
