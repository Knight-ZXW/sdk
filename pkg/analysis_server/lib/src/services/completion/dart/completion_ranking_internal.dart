// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart';
import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analysis_server/src/provisional/completion/dart/completion_dart.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

/// Constructs a [CompletionSuggestion] object.
CompletionSuggestion createCompletionSuggestion(
    String completion, FeatureSet featureSet, int relevance) {
  final tokens = TokenUtils.getTokens(completion, featureSet);
  final token = tokens.isNotEmpty ? tokens[0] : null;
  final completionKind = token != null && token.isKeyword
      ? CompletionSuggestionKind.KEYWORD
      : CompletionSuggestionKind.IDENTIFIER;
  if (isLiteral(completion) &&
      (completion.startsWith('"package:') ||
          completion.startsWith('\'package:'))) {
    completion = completion.replaceAll('\'', '').replaceAll('\"', '');
  }
  return CompletionSuggestion(completionKind, relevance, completion,
      completion.length, 0, false, false);
}

/// Finds the token at which completion was requested.
Token getCursorToken(DartCompletionRequest request) {
  final entity = request.target.entity;
  if (entity is AstNode) {
    return entity.endToken;
  }
  return entity is Token ? entity : null;
}

/// Fuzzy matching between static analysis and model-predicted lexemes
/// that considers pairs like "main" and "main()" to be equal.
bool areCompletionsEquivalent(String dasCompletion, String modelCompletion) {
  if (dasCompletion == null || modelCompletion == null) {
    return false;
  }
  if (dasCompletion == modelCompletion) {
    return true;
  }

  final index = dasCompletion.indexOf(new RegExp(r'[^0-9A-Za-z_]'));
  // Disallow '.' since this gives all methods under a model-predicted token
  // the same probability.
  if (index == -1 || dasCompletion[index] == '.') {
    return false;
  }

  // Checks that the strings are equal until the first non-alphanumeric token.
  return dasCompletion.substring(0, index) == modelCompletion;
}

/// Step to previous token until we are at the first token before where the
/// cursor is located.
bool isStopToken(Token token, int cursorOffset) {
  if (token == null) {
    return true;
  }
  if (token.isSynthetic && !token.isEof) {
    return false;
  }
  final position = token.offset + token.length;
  if (position == cursorOffset) {
    // If we are at the end of some token, step to previous only if the
    // token is NOT an identifier, keyword, or literal. The rationale is that
    // we want to keep moving if we have a situation like
    // FooBar foo^ since foo is not a previous token to pass to the model.
    return token.lexeme[token.lexeme.length - 1]
        .contains(new RegExp(r'[0-9A-Za-z_]'));
  }
  // Stop if the token's location is strictly before the cursor, continue
  // if the token's location is strictly after.
  return position < cursorOffset;
}

bool isStringLiteral(String lexeme) {
  if (lexeme == null || lexeme.isEmpty) {
    return false;
  }
  return (lexeme.length > 1 && lexeme[0] == "'") ||
      (lexeme.length > 2 && lexeme[0] == 'r' && lexeme[1] == "'");
}

bool isLiteral(String lexeme) {
  if (lexeme == null || lexeme.isEmpty) {
    return false;
  }
  if (new RegExp(r'^[0-9]+$').hasMatch(lexeme)) {
    // Check for number lexeme.
    return true;
  }
  return isStringLiteral(lexeme);
}

bool isNotWhitespace(String lexeme) {
  return lexeme
      .replaceAll("'", '')
      .split('')
      .any((String chr) => !new RegExp(r'\s').hasMatch(chr));
}

Token getCurrentToken(DartCompletionRequest request) {
  var token = getCursorToken(request);
  while (!isStopToken(token.previous, request.offset)) {
    token = token.previous;
  }
  return token;
}

bool testInsideQuotes(DartCompletionRequest request) {
  final token = getCurrentToken(request);
  if (token.isSynthetic) {
    return false;
  }

  final cursorOffset = request.offset;
  if (cursorOffset == token.offset ||
      cursorOffset == token.offset + token.length) {
    // We are not inside the current token, quoted or otherwise.
    return false;
  }

  final lexeme = token.lexeme;
  if (lexeme.length > 2 && lexeme[0] == 'r') {
    return lexeme[1] == "'" || lexeme[1] == '"';
  }

  return lexeme.length > 1 && (lexeme[0] == "'" || lexeme[0] == '"');
}

bool isTokenDot(Token token) {
  return !token.isSynthetic && token.lexeme.endsWith('.');
}

bool testFollowingDot(DartCompletionRequest request) {
  final token = getCurrentToken(request);
  return isTokenDot(token) || isTokenDot(token.previous);
}

/// Finds the previous n tokens occurring before the cursor.
List<String> constructQuery(DartCompletionRequest request, int n) {
  var token = getCursorToken(request);
  if (request.offset == null) {
    return null;
  }

  while (!isStopToken(token, request.offset)) {
    token = token.previous;
  }

  if (token?.offset == null || token?.type == null) {
    return null;
  }

  final result = List<String>();
  for (var size = 0; size < n && !token.isEof; token = token.previous) {
    if (!token.isSynthetic) {
      result.add(token.lexeme);
      size += 1;
    }
  }

  return result.reversed.toList(growable: false);
}

/// Maps included relevance tags formatted as
/// '${element.librarySource.uri}::${element.name}' to element.name.
String elementNameFromRelevanceTag(String tag) {
  final index = tag.lastIndexOf('::');
  if (index == -1) {
    return null;
  }

  return tag.substring(index + 2);
}
