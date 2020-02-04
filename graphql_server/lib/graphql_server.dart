import 'dart:async';
import 'package:gql/ast.dart';
import 'package:gql/language.dart' as gql;
import 'package:graphql_schema/graphql_schema.dart';
import 'package:source_span/source_span.dart';
import 'introspection.dart';

/// Transforms any [Map] into `Map<String, dynamic>`.
Map<String, dynamic> foldToStringDynamic(Map map) {
  return map == null
      ? null
      : map.keys.fold<Map<String, dynamic>>(
          <String, dynamic>{}, (out, k) => out..[k.toString()] = map[k]);
}

/// A Dart implementation of a GraphQL server.
class GraphQL {
  /// Any custom types to include in introspection information.
  final List<GraphQLType> customTypes = [];

  /// An optional callback that can be used to resolve fields from objects that are not [Map]s,
  /// when the related field has no resolver.
  final FutureOr<T> Function<T>(T, String, Map<String, dynamic>)
      defaultFieldResolver;

  GraphQLSchema _schema;

  GraphQL(GraphQLSchema schema,
      {bool introspect = true,
      this.defaultFieldResolver,
      List<GraphQLType> customTypes = const <GraphQLType>[]})
      : _schema = schema {
    if (customTypes?.isNotEmpty == true) {
      this.customTypes.addAll(customTypes);
    }

    if (introspect) {
      var allTypes = fetchAllTypes(schema, this.customTypes);

      _schema = reflectSchema(_schema, allTypes);

      for (var type in allTypes.toSet()) {
        if (!this.customTypes.contains(type)) {
          this.customTypes.add(type);
        }
      }
    }

    if (_schema.queryType != null) this.customTypes.add(_schema.queryType);
    if (_schema.mutationType != null) {
      this.customTypes.add(_schema.mutationType);
    }
    if (_schema.subscriptionType != null) {
      this.customTypes.add(_schema.subscriptionType);
    }
  }

  Object computeValue(GraphQLType targetType, ValueNode node,
          Map<String, dynamic> values) =>
      node.accept(GraphQLValueComputer(targetType, values));

  GraphQLType convertType(TypeNode node) {
    if (node is ListTypeNode) {
      return GraphQLListType(convertType(node.type));
    } else if (node is NamedTypeNode) {
      switch (node.name.value) {
        case 'Int':
          return graphQLInt;
        case 'Float':
          return graphQLFloat;
        case 'String':
          return graphQLString;
        case 'Boolean':
          return graphQLBoolean;
        case 'ID':
          return graphQLId;
        case 'Date':
        case 'DateTime':
          return graphQLDate;
        default:
          return customTypes.firstWhere((t) => t.name == node.name.value,
              orElse: () => throw ArgumentError(
                  'Unknown GraphQL type: "${node.name.value}"'));
      }
    } else {
      throw ArgumentError('Invalid GraphQL type: "${node.span.text}"');
    }
  }

  Future parseAndExecute(String text,
      {String operationName,
      sourceUrl,
      Map<String, dynamic> variableValues = const {},
      initialValue,
      Map<String, dynamic> globalVariables}) {
    var errors = <GraphQLExceptionError>[];
    DocumentNode document;

    try {
      document = gql.parseString(text, url: sourceUrl);
    } on SourceSpanException catch (e) {
      errors.add(GraphQLExceptionError(e.message, locations: [
        GraphExceptionErrorLocation.fromSourceLocation(e.span.start),
      ]));
    }

    if (errors.isNotEmpty) {
      throw GraphQLException(errors);
    }

    return executeRequest(
      _schema,
      document,
      operationName: operationName,
      initialValue: initialValue,
      variableValues: variableValues,
      globalVariables: globalVariables,
    );
  }

  Future executeRequest(GraphQLSchema schema, DocumentNode document,
      {String operationName,
      Map<String, dynamic> variableValues = const <String, dynamic>{},
      initialValue,
      Map<String, dynamic> globalVariables = const <String, dynamic>{}}) async {
    var operation = getOperation(document, operationName);
    var coercedVariableValues = coerceVariableValues(
        schema, operation, variableValues ?? <String, dynamic>{});
    if (operation.type == OperationType.query) {
      return await executeQuery(document, operation, schema,
          coercedVariableValues, initialValue, globalVariables);
    } else if (operation.type == OperationType.subscription) {
      return await subscribe(document, operation, schema, coercedVariableValues,
          globalVariables, initialValue);
    } else {
      return executeMutation(document, operation, schema, coercedVariableValues,
          initialValue, globalVariables);
    }
  }

  OperationDefinitionNode getOperation(
      DocumentNode document, String operationName) {
    var ops = document.definitions.whereType<OperationDefinitionNode>();

    if (operationName == null) {
      return ops.length == 1
          ? ops.first
          : throw GraphQLException.fromMessage(
              'This document does not define any operations.');
    } else {
      return ops.firstWhere((d) => d.name.value == operationName,
          orElse: () => throw GraphQLException.fromMessage(
              'Missing required operation "$operationName".'));
    }
  }

  Map<String, dynamic> coerceVariableValues(GraphQLSchema schema,
      OperationDefinitionNode operation, Map<String, dynamic> variableValues) {
    var coercedValues = <String, dynamic>{};
    var variableDefinitions = operation.variableDefinitions ?? [];

    for (var variableDefinition in variableDefinitions) {
      var variableName = variableDefinition.variable.name.value;
      var variableType = variableDefinition.type;
      var defaultValue = variableDefinition.defaultValue;
      var value = variableValues[variableName];

      if (value == null) {
        if (defaultValue != null) {
          coercedValues[variableName] = computeValue(
              convertType(variableType), defaultValue.value, variableValues);
        } else if (variableType.isNonNull) {
          throw GraphQLException.fromSourceSpan(
              'Missing required variable "$variableName".',
              variableDefinition.span);
        }
      } else {
        var type = convertType(variableType);
        var validation = type.validate(variableName, value);

        if (!validation.successful) {
          throw GraphQLException(validation.errors
              .map((e) => GraphQLExceptionError(e, locations: [
                    GraphExceptionErrorLocation.fromSourceLocation(
                        variableDefinition.span.start)
                  ]))
              .toList());
        } else {
          coercedValues[variableName] = type.deserialize(value);
        }
      }
    }

    return coercedValues;
  }

  Future<Map<String, dynamic>> executeQuery(
      DocumentNode document,
      OperationDefinitionNode query,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      initialValue,
      Map<String, dynamic> globalVariables) async {
    var queryType = schema.queryType;
    var selectionSet = query.selectionSet;
    return await executeSelectionSet(document, selectionSet, queryType,
        initialValue, variableValues, globalVariables);
  }

  Future<Map<String, dynamic>> executeMutation(
      DocumentNode document,
      OperationDefinitionNode mutation,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      initialValue,
      Map<String, dynamic> globalVariables) async {
    var mutationType = schema.mutationType;

    if (mutationType == null) {
      throw GraphQLException.fromMessage(
          'The schema does not define a mutation type.');
    }

    var selectionSet = mutation.selectionSet;
    return await executeSelectionSet(document, selectionSet, mutationType,
        initialValue, variableValues, globalVariables);
  }

  Future<Stream<Map<String, dynamic>>> subscribe(
      DocumentNode document,
      OperationDefinitionNode subscription,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables,
      initialValue) async {
    var sourceStream = await createSourceEventStream(
        document, subscription, schema, variableValues, initialValue);
    return mapSourceToResponseEvent(sourceStream, subscription, schema,
        document, initialValue, variableValues, globalVariables);
  }

  Future<Stream> createSourceEventStream(
      DocumentNode document,
      OperationDefinitionNode subscription,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      initialValue) {
    var selectionSet = subscription.selectionSet;
    var subscriptionType = schema.subscriptionType;
    if (subscriptionType == null) {
      throw GraphQLException.fromSourceSpan(
          'The schema does not define a subscription type.', subscription.span);
    }
    var groupedFieldSet =
        collectFields(document, subscriptionType, selectionSet, variableValues);
    if (groupedFieldSet.length != 1) {
      throw GraphQLException.fromSourceSpan(
          'The grouped field set from this query must have exactly one entry.',
          selectionSet.span);
    }
    var fields = groupedFieldSet.entries.first.value;
    var fieldNode = fields.first;
    var fieldName = fieldNode.alias?.value ?? fieldNode.name.value;
    var argumentValues =
        coerceArgumentValues(subscriptionType, fieldNode, variableValues);
    return resolveFieldEventStream(
        subscriptionType, initialValue, fieldName, argumentValues);
  }

  Stream<Map<String, dynamic>> mapSourceToResponseEvent(
    Stream sourceStream,
    OperationDefinitionNode subscription,
    GraphQLSchema schema,
    DocumentNode document,
    initialValue,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables,
  ) async* {
    await for (var event in sourceStream) {
      yield await executeSubscriptionEvent(document, subscription, schema,
          event, variableValues, globalVariables);
    }
  }

  Future<Map<String, dynamic>> executeSubscriptionEvent(
      DocumentNode document,
      OperationDefinitionNode subscription,
      GraphQLSchema schema,
      initialValue,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    var selectionSet = subscription.selectionSet;
    var subscriptionType = schema.subscriptionType;
    if (subscriptionType == null) {
      throw GraphQLException.fromSourceSpan(
          'The schema does not define a subscription type.', subscription.span);
    }
    try {
      var data = await executeSelectionSet(document, selectionSet,
          subscriptionType, initialValue, variableValues, globalVariables);
      return {'data': data};
    } on GraphQLException catch (e) {
      return {
        'data': null,
        'errors': [e.errors.map((e) => e.toJson()).toList()]
      };
    }
  }

  Future<Stream> resolveFieldEventStream(GraphQLObjectType subscriptionType,
      rootValue, String fieldName, Map<String, dynamic> argumentValues) async {
    var field = subscriptionType.fields.firstWhere((f) => f.name == fieldName,
        orElse: () {
      throw GraphQLException.fromMessage(
          'No subscription field named "$fieldName" is defined.');
    });
    var resolver = field.resolve;
    var result = await resolver(rootValue, argumentValues);
    if (result is Stream) {
      return result;
    } else {
      return Stream.fromIterable([result]);
    }
  }

  Future<Map<String, dynamic>> executeSelectionSet(
      DocumentNode document,
      SelectionSetNode selectionSet,
      GraphQLObjectType objectType,
      objectValue,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    var groupedFieldSet =
        collectFields(document, objectType, selectionSet, variableValues);
    var resultMap = <String, dynamic>{};
    var futureResultMap = <String, FutureOr<dynamic>>{};

    for (var responseKey in groupedFieldSet.keys) {
      var fields = groupedFieldSet[responseKey];
      for (var field in fields) {
        var fieldNode = field;
        var fieldName = fieldNode.alias?.value ?? fieldNode.name.value;
        FutureOr<dynamic> futureResponseValue;

        if (fieldName == '__typename') {
          futureResponseValue = objectType.name;
        } else {
          var fieldType = objectType.fields
              .firstWhere((f) => f.name == fieldName, orElse: () => null)
              ?.type;
          if (fieldType == null) continue;
          futureResponseValue = executeField(
              document,
              fieldName,
              objectType,
              objectValue,
              fields,
              fieldType,
              Map<String, dynamic>.from(globalVariables ?? <String, dynamic>{})
                ..addAll(variableValues),
              globalVariables);
        }

        futureResultMap[responseKey] = futureResponseValue;
      }
    }
    for (var f in futureResultMap.keys) {
      resultMap[f] = await futureResultMap[f];
    }
    return resultMap;
  }

  Future executeField(
      DocumentNode document,
      String fieldName,
      GraphQLObjectType objectType,
      objectValue,
      List<FieldNode> fields,
      GraphQLType fieldType,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    var field = fields[0];
    var argumentValues =
        coerceArgumentValues(objectType, field, variableValues);
    var resolvedValue = await resolveFieldValue(
        objectType,
        objectValue,
        fieldName,
        Map<String, dynamic>.from(globalVariables ?? {})
          ..addAll(argumentValues ?? {}));
    return completeValue(document, fieldName, fieldType, fields, resolvedValue,
        variableValues, globalVariables);
  }

  Map<String, dynamic> coerceArgumentValues(GraphQLObjectType objectType,
      FieldNode field, Map<String, dynamic> variableValues) {
    var coercedValues = <String, dynamic>{};
    var argumentValues = field.arguments;
    var fieldName = field.alias?.value ?? field.name.value;
    var desiredField = objectType.fields.firstWhere((f) => f.name == fieldName,
        orElse: () => throw FormatException(
            '${objectType.name} has no field named "$fieldName".'));
    var argumentDefinitions = desiredField.inputs;

    for (var argumentDefinition in argumentDefinitions) {
      var argumentName = argumentDefinition.name;
      var argumentType = argumentDefinition.type;
      var defaultValue = argumentDefinition.defaultValue;

      var argumentValue = argumentValues
          .firstWhere((a) => a.name.value == argumentName, orElse: () => null);

      if (argumentValue == null) {
        if (defaultValue != null || argumentDefinition.defaultsToNull) {
          coercedValues[argumentName] = defaultValue;
        } else if (argumentType is GraphQLNonNullableType) {
          throw GraphQLException.fromMessage(
              'Missing value for argument "$argumentName" of field "$fieldName".');
        } else {
          continue;
        }
      } else {
        try {
          var validation = argumentType.validate(argumentName,
              computeValue(argumentType, argumentValue.value, variableValues));

          if (!validation.successful) {
            var errors = <GraphQLExceptionError>[
              GraphQLExceptionError(
                'Type coercion error for value of argument "$argumentName" of field "$fieldName".',
                locations: [
                  GraphExceptionErrorLocation.fromSourceLocation(
                      argumentValue.value.span.start)
                ],
              )
            ];

            for (var error in validation.errors) {
              errors.add(
                GraphQLExceptionError(
                  error,
                  locations: [
                    GraphExceptionErrorLocation.fromSourceLocation(
                        argumentValue.value.span.start)
                  ],
                ),
              );
            }

            throw GraphQLException(errors);
          } else {
            var coercedValue = validation.value;
            coercedValues[argumentName] = coercedValue;
          }
        } on TypeError catch (e) {
          throw GraphQLException(<GraphQLExceptionError>[
            GraphQLExceptionError(
              'Type coercion error for value of argument "$argumentName" of field "$fieldName".',
              locations: [
                GraphExceptionErrorLocation.fromSourceLocation(
                    argumentValue.value.span.start)
              ],
            ),
            GraphQLExceptionError(
              e.message.toString(),
              locations: [
                GraphExceptionErrorLocation.fromSourceLocation(
                    argumentValue.value.span.start)
              ],
            ),
          ]);
        }
      }
    }

    return coercedValues;
  }

  Future<T> resolveFieldValue<T>(GraphQLObjectType objectType, T objectValue,
      String fieldName, Map<String, dynamic> argumentValues) async {
    var field = objectType.fields.firstWhere((f) => f.name == fieldName);

    if (objectValue is Map) {
      return objectValue[fieldName] as T;
    } else if (field.resolve == null) {
      if (defaultFieldResolver != null) {
        return await defaultFieldResolver(
            objectValue, fieldName, argumentValues);
      }

      return null;
    } else {
      return await field.resolve(objectValue, argumentValues) as T;
    }
  }

  Future completeValue(
      DocumentNode document,
      String fieldName,
      GraphQLType fieldType,
      List<SelectionNode> fields,
      result,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    if (fieldType is GraphQLNonNullableType) {
      var innerType = fieldType.ofType;
      var completedResult = await completeValue(document, fieldName, innerType,
          fields, result, variableValues, globalVariables);

      if (completedResult == null) {
        throw GraphQLException.fromMessage(
            'Null value provided for non-nullable field "$fieldName".');
      } else {
        return completedResult;
      }
    }

    if (result == null) {
      return null;
    }

    if (fieldType is GraphQLListType) {
      if (result is! Iterable) {
        throw GraphQLException.fromMessage(
            'Value of field "$fieldName" must be a list or iterable, got $result instead.');
      }

      var innerType = fieldType.ofType;
      var futureOut = [];

      for (var resultItem in (result as Iterable)) {
        futureOut.add(completeValue(document, '(item in "$fieldName")',
            innerType, fields, resultItem, variableValues, globalVariables));
      }

      var out = [];
      for (var f in futureOut) {
        out.add(await f);
      }

      return out;
    }

    if (fieldType is GraphQLScalarType) {
      try {
        var validation = fieldType.validate(fieldName, result);

        if (!validation.successful) {
          return null;
        } else {
          return validation.value;
        }
      } on TypeError {
        throw GraphQLException.fromMessage(
            'Value of field "$fieldName" must be ${fieldType.valueType}, got $result instead.');
      }
    }

    if (fieldType is GraphQLObjectType || fieldType is GraphQLUnionType) {
      GraphQLObjectType objectType;

      if (fieldType is GraphQLObjectType && !fieldType.isInterface) {
        objectType = fieldType;
      } else {
        objectType = resolveAbstractType(fieldName, fieldType, result);
      }

      var subSelectionSet = mergeSelectionSets(fields);
      return await executeSelectionSet(document, subSelectionSet, objectType,
          result, variableValues, globalVariables);
    }

    throw UnsupportedError('Unsupported type: $fieldType');
  }

  GraphQLObjectType resolveAbstractType(
      String fieldName, GraphQLType type, result) {
    List<GraphQLObjectType> possibleTypes;

    if (type is GraphQLObjectType) {
      if (type.isInterface) {
        possibleTypes = type.possibleTypes;
      } else {
        return type;
      }
    } else if (type is GraphQLUnionType) {
      possibleTypes = type.possibleTypes;
    } else {
      throw ArgumentError();
    }

    var errors = <GraphQLExceptionError>[];

    for (var t in possibleTypes) {
      try {
        var validation =
            t.validate(fieldName, foldToStringDynamic(result as Map));

        if (validation.successful) {
          return t;
        }

        errors.addAll(validation.errors.map((m) => GraphQLExceptionError(m)));
      } on GraphQLException catch (e) {
        errors.addAll(e.errors);
      }
    }

    errors.insert(0,
        GraphQLExceptionError('Cannot convert value $result to type $type.'));

    throw GraphQLException(errors);
  }

  SelectionSetNode mergeSelectionSets(List<SelectionNode> fields) {
    var selections = <SelectionNode>[];

    for (var field in fields) {
      if (field is FieldNode && field.selectionSet != null) {
        selections.addAll(field.selectionSet.selections);
      } else if (field is InlineFragmentNode && field.selectionSet != null) {
        selections.addAll(field.selectionSet.selections);
      }
    }

    return SelectionSetNode(selections: selections);
  }

  Map<String, List<FieldNode>> collectFields(
      DocumentNode document,
      GraphQLObjectType objectType,
      SelectionSetNode selectionSet,
      Map<String, dynamic> variableValues,
      {List visitedFragments}) {
    var groupedFields = <String, List<FieldNode>>{};
    visitedFragments ??= [];

    for (var selection in selectionSet.selections) {
      if (getDirectiveValue('skip', 'if', selection, variableValues) == true) {
        continue;
      }
      if (getDirectiveValue('include', 'if', selection, variableValues) ==
          false) {
        continue;
      }

      if (selection is FieldNode) {
        var responseKey = selection.alias?.value ?? selection.name.value;
        var groupForResponseKey =
            groupedFields.putIfAbsent(responseKey, () => []);
        groupForResponseKey.add(selection);
      } else if (selection is FragmentSpreadNode) {
        var fragmentSpreadName = selection.name.value;
        if (visitedFragments.contains(fragmentSpreadName)) continue;
        visitedFragments.add(fragmentSpreadName);
        var fragment = document.definitions
            .whereType<FragmentDefinitionNode>()
            .firstWhere((f) => f.name.value == fragmentSpreadName,
                orElse: () => null);

        if (fragment == null) continue;
        var fragmentType = fragment.typeCondition;
        if (!doesFragmentTypeApply(objectType, fragmentType)) continue;
        var fragmentSelectionSet = fragment.selectionSet;
        var fragmentGroupFieldSet = collectFields(
            document, objectType, fragmentSelectionSet, variableValues);

        for (var responseKey in fragmentGroupFieldSet.keys) {
          var fragmentGroup = fragmentGroupFieldSet[responseKey];
          var groupForResponseKey =
              groupedFields.putIfAbsent(responseKey, () => []);
          groupForResponseKey.addAll(fragmentGroup);
        }
      } else if (selection is InlineFragmentNode) {
        var fragmentType = selection.typeCondition;
        if (fragmentType != null &&
            !doesFragmentTypeApply(objectType, fragmentType)) continue;
        var fragmentSelectionSet = selection.selectionSet;
        var fragmentGroupFieldSet = collectFields(
            document, objectType, fragmentSelectionSet, variableValues);

        for (var responseKey in fragmentGroupFieldSet.keys) {
          var fragmentGroup = fragmentGroupFieldSet[responseKey];
          var groupForResponseKey =
              groupedFields.putIfAbsent(responseKey, () => []);
          groupForResponseKey.addAll(fragmentGroup);
        }
      }
    }

    return groupedFields;
  }

  getDirectiveValue(String name, String argumentName, SelectionNode selection,
      Map<String, dynamic> variableValues) {
    if (selection is! FieldNode) return null;
    var directive = (selection as FieldNode).directives.firstWhere((d) {
      if (d.arguments.isEmpty) return false;
      var vv = d.arguments[0].value;
      if (vv is VariableNode) {
        return vv.name.value == name;
      } else {
        return computeValue(null, vv, variableValues) == name;
      }
    }, orElse: () => null);

    if (directive == null) return null;
    if (directive.arguments[0].name.value != argumentName) return null;

    var vv = directive.arguments[0].value;
    if (vv is VariableNode) {
      var vname = vv.name;
      if (!variableValues.containsKey(vname)) {
        throw GraphQLException.fromSourceSpan(
            'Unknown variable: "$vname"', vv.span);
      }
      return variableValues[vname];
    }
    return computeValue(null, vv, variableValues);
  }

  bool doesFragmentTypeApply(
      GraphQLObjectType objectType, TypeConditionNode fragmentType) {
    var typeNode = NamedTypeNode(
        name: fragmentType.on.name,
        span: fragmentType.on.span,
        isNonNull: fragmentType.on.isNonNull);
    var type = convertType(typeNode);
    if (type is GraphQLObjectType && !type.isInterface) {
      for (var field in type.fields) {
        if (!objectType.fields.any((f) => f.name == field.name)) return false;
      }
      return true;
    } else if (type is GraphQLObjectType && type.isInterface) {
      return objectType.isImplementationOf(type);
    } else if (type is GraphQLUnionType) {
      return type.possibleTypes.any((t) => objectType.isImplementationOf(t));
    }

    return false;
  }
}

class GraphQLValueComputer extends SimpleVisitor {
  final GraphQLType targetType;
  final Map<String, dynamic> variableValues;

  GraphQLValueComputer(this.targetType, this.variableValues);

  @override
  visitBooleanValueNode(BooleanValueNode node) => node.value;

  @override
  visitEnumValueNode(EnumValueNode node) {
    if (targetType == null) {
      throw GraphQLException.fromSourceSpan(
          'An enum value was given, but in this context, its type cannot be deduced.',
          node.span);
    } else if (targetType is! GraphQLEnumType) {
      throw GraphQLException.fromSourceSpan(
          'An enum value was given, but the type "${targetType.name}" is not an enum.',
          node.span);
    } else {
      var enumType = targetType as GraphQLEnumType;
      var matchingValue = enumType.values
          .firstWhere((v) => v.name == node.name.value, orElse: () => null);
      if (matchingValue == null) {
        throw GraphQLException.fromSourceSpan(
            'The enum "${targetType.name}" has no member named "${node.name.value}".',
            node.span);
      } else {
        return matchingValue.value;
      }
    }
  }

  @override
  visitFloatValueNode(FloatValueNode node) => node.value;

  @override
  visitIntValueNode(IntValueNode node) => node.value;

  @override
  visitListValueNode(ListValueNode node) {
    return node.values.map((v) => v.accept(this)).toList();
  }

  @override
  visitObjectValueNode(ObjectValueNode node) {
    return Map.fromEntries(node.fields.map((f) {
      return MapEntry(f.name.value, f.value.accept(this));
    }));
  }

  @override
  visitNullValueNode(NullValueNode node) => null;

  @override
  visitStringValueNode(StringValueNode node) => node.value;

  @override
  visitVariableNode(VariableNode node) => variableValues[node.name.value];
}
