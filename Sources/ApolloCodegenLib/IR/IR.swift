import OrderedCollections
import CryptoKit

final class IR {

  let compilationResult: CompilationResult

  let schema: Schema

  let fieldCollector = FieldCollector()

  var builtFragments: [String: NamedFragment] = [:]

  init(compilationResult: CompilationResult) {
    self.compilationResult = compilationResult
    self.schema = Schema(
      referencedTypes: .init(compilationResult.referencedTypes),
      documentation: compilationResult.schemaDocumentation
    )
    self.processRootTypes()
  }
  
  private func processRootTypes() {
    let rootTypes = compilationResult.rootTypes
    let typeList = [rootTypes.queryType.name, rootTypes.mutationType?.name, rootTypes.subscriptionType?.name].compactMap { $0 }
    
    compilationResult.operations.forEach { op in
      op.rootType.isRootFieldType = typeList.contains(op.rootType.name)
    }
    
    compilationResult.fragments.forEach { fragment in
      fragment.type.isRootFieldType = typeList.contains(fragment.type.name)
    }
  }

  /// A top level GraphQL definition, which can be an operation or a named fragment.
  enum Definition {
    case operation(IR.Operation)
    case namedFragment(IR.NamedFragment)

    var name: String {
      switch self {
      case  let .operation(operation):
        return operation.definition.name
      case let .namedFragment(fragment):
        return fragment.definition.name
      }
    }

    var rootField: IR.EntityField {
      switch self {
      case  let .operation(operation):
        return operation.rootField
      case let .namedFragment(fragment):
        return fragment.rootField
      }
    }
  }

  // TODO: Documentation for this to be completed in issue #3141
  enum IsDeferred: Hashable, ExpressibleByBooleanLiteral {
    case value(Bool)
    case `if`(_ variable: String)

    init(booleanLiteral value: BooleanLiteralType) {
      switch value {
      case true:
        self = .value(true)
      case false:
        self = .value(false)
      }
    }

    var definitionDirectiveDescription: String {
      switch self {
      case .value(false): return ""
      case .value(true): return " @defer"
      case let .if(variable):
        return " @defer(if: \(variable))"
      }
    }
  }

  /// Represents a concrete entity in an operation or fragment that fields are selected upon.
  ///
  /// Multiple `SelectionSet`s may select fields on the same `Entity`. All `SelectionSet`s that will
  /// be selected on the same object share the same `Entity`.
  final class Entity {

    /// Represents the location within a GraphQL definition (operation or fragment) of an `Entity`.
    struct Location: Hashable {
      enum SourceDefinition: Hashable {
        case operation(CompilationResult.OperationDefinition)
        case namedFragment(CompilationResult.FragmentDefinition)

        var rootType: GraphQLCompositeType {
          switch self {
          case let .operation(definition): return definition.rootType
          case let .namedFragment(definition): return definition.type
          }
        }
      }

      struct FieldComponent: Hashable {
        let name: String
        let type: GraphQLType
      }

      typealias FieldPath = LinkedList<FieldComponent>

      /// The operation or fragment definition that the entity belongs to.
      let source: SourceDefinition

      /// The path of fields from the root of the ``source`` definition to the entity.
      ///
      /// Example:
      /// For an operation:
      /// ```graphql
      /// query MyQuery {
      ///   allAnimals {
      ///     predators {
      ///       height {
      ///         ...
      ///       }
      ///     }
      ///   }
      /// }
      /// ```
      /// The `Height` entity would have a field path of [allAnimals, predators, height].
      let fieldPath: FieldPath?

      func appending(_ fieldComponent: FieldComponent) -> Location {
        let fieldPath = self.fieldPath?.appending(fieldComponent) ?? LinkedList(fieldComponent)
        return Location(source: self.source, fieldPath: fieldPath)
      }

      func appending<C: Collection<FieldComponent>>(_ fieldComponents: C) -> Location {
        let fieldPath = self.fieldPath?.appending(fieldComponents) ?? LinkedList(fieldComponents)
        return Location(source: self.source, fieldPath: fieldPath)
      }

      static func +(lhs: IR.Entity.Location, rhs: FieldComponent) -> Location {
        lhs.appending(rhs)
      }
    }

    /// The selections that are selected for the entity across all type scopes in the operation.
    /// Represented as a tree.
    let selectionTree: EntitySelectionTree
    
    /// The location within a GraphQL definition (operation or fragment) where the `Entity` is
    /// located.
    let location: Location

    var rootTypePath: LinkedList<GraphQLCompositeType> { selectionTree.rootTypePath }

    var rootType: GraphQLCompositeType { rootTypePath.last.value }

    init(source: Location.SourceDefinition) {
      self.location = .init(source: source, fieldPath: nil)
      self.selectionTree = EntitySelectionTree(rootTypePath: LinkedList(source.rootType))
    }

    init(
      location: Location,
      rootTypePath: LinkedList<GraphQLCompositeType>
    ) {
      self.location = location
      self.selectionTree = EntitySelectionTree(rootTypePath: rootTypePath)
    }
  }

  final class Operation {
    let definition: CompilationResult.OperationDefinition

    /// The root field of the operation. This field must be the root query, mutation, or
    /// subscription field of the schema.
    let rootField: EntityField

    /// All of the fragments that are referenced by this operation's selection set.
    let referencedFragments: OrderedSet<NamedFragment>

    lazy var operationIdentifier: String = {
      if #available(macOS 10.15, *) {
        var hasher = SHA256()
        func updateHash(with source: inout String) {
          source.withUTF8({ buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
          })
        }
        var definitionSource = definition.source.convertedToSingleLine()
        updateHash(with: &definitionSource)

        var newline: String
        for fragment in referencedFragments {
          newline = "\n"
          updateHash(with: &newline)
          var fragmentSource = fragment.definition.source.convertedToSingleLine()
          updateHash(with: &fragmentSource)
        }

        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()

      } else {
        fatalError("Code Generation must be run on macOS 10.15+.")
      }
    }()

    init(
      definition: CompilationResult.OperationDefinition,
      rootField: EntityField,
      referencedFragments: OrderedSet<NamedFragment>
    ) {
      self.definition = definition
      self.rootField = rootField
      self.referencedFragments = referencedFragments
    }
  }

  final class NamedFragment: Hashable, CustomDebugStringConvertible {
    let definition: CompilationResult.FragmentDefinition
    let rootField: EntityField

    /// All of the fragments that are referenced by this fragment's selection set.
    let referencedFragments: OrderedSet<NamedFragment>

    /// All of the Entities that exist in the fragment's selection set,
    /// keyed by their relative location (ie. path) within the fragment.
    ///
    /// - Note: The FieldPath for an entity within a fragment will begin with a path component
    /// with the fragment's name and type.
    let entities: [IR.Entity.Location: IR.Entity]

    var name: String { definition.name }
    var type: GraphQLCompositeType { definition.type }

    init(
      definition: CompilationResult.FragmentDefinition,
      rootField: EntityField,
      referencedFragments: OrderedSet<NamedFragment>,
      entities: [IR.Entity.Location: IR.Entity]
    ) {
      self.definition = definition
      self.rootField = rootField
      self.referencedFragments = referencedFragments
      self.entities = entities
    }

    static func == (lhs: IR.NamedFragment, rhs: IR.NamedFragment) -> Bool {
      lhs.definition == rhs.definition &&
      lhs.rootField === rhs.rootField
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(definition)
      hasher.combine(ObjectIdentifier(rootField))
    }

    var debugDescription: String {
      definition.debugDescription
    }
  }

  /// Represents an Inline Fragment that has been "spread into" another SelectionSet using the
  /// spread operator (`...`).
  final class InlineFragmentSpread: Hashable, CustomDebugStringConvertible {
    /// The `SelectionSet` representing the inline fragment that has been "spread into" its
    /// enclosing operation/fragment.
    let selectionSet: SelectionSet

    let isDeferred: IsDeferred

    /// Indicates the location where the inline fragment has been "spread into" its enclosing
    /// operation/fragment.
    var typeInfo: SelectionSet.TypeInfo { selectionSet.typeInfo }

    var inclusionConditions: InclusionConditions? { selectionSet.inclusionConditions }

    init(
      selectionSet: SelectionSet,
      isDeferred: IsDeferred
    ) {
      self.selectionSet = selectionSet
      self.isDeferred = isDeferred
    }

    static func == (lhs: IR.InlineFragmentSpread, rhs: IR.InlineFragmentSpread) -> Bool {
      lhs.selectionSet == rhs.selectionSet &&
      lhs.isDeferred == rhs.isDeferred
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(selectionSet)
      hasher.combine(isDeferred)
    }

    var debugDescription: String {
      var string = typeInfo.parentType.debugDescription
      if let conditions = typeInfo.inclusionConditions {
        string += " \(conditions.debugDescription)"
      }
      string += isDeferred.definitionDirectiveDescription
      return string
    }
  }

  /// Represents a Named Fragment that has been "spread into" another SelectionSet using the
  /// spread operator (`...`).
  ///
  /// While a `NamedFragment` can be shared between operations, a `NamedFragmentSpread` represents a
  /// `NamedFragment` included in a specific operation.
  final class NamedFragmentSpread: Hashable, CustomDebugStringConvertible {

    /// The `NamedFragment` that this fragment refers to.
    ///
    /// This is a fragment that has already been built. To "spread" the fragment in, it's entity
    /// selection trees are merged into the entity selection trees of the operation/fragment it is
    /// being spread into. This allows merged field calculations to include the fields merged in
    /// from the fragment.
    let fragment: NamedFragment
    
    /// Indicates the location where the fragment has been "spread into" its enclosing
    /// operation/fragment. It's `scopePath` and `entity` reference are scoped to the operation it
    /// belongs to.
    let typeInfo: SelectionSet.TypeInfo

    var inclusionConditions: AnyOf<InclusionConditions>?

    let isDeferred: IsDeferred

    var definition: CompilationResult.FragmentDefinition { fragment.definition }

    init(
      fragment: NamedFragment,
      typeInfo: SelectionSet.TypeInfo,
      inclusionConditions: AnyOf<InclusionConditions>?,
      isDeferred: IsDeferred
    ) {
      self.fragment = fragment
      self.typeInfo = typeInfo
      self.inclusionConditions = inclusionConditions
      self.isDeferred = isDeferred
    }

    static func == (lhs: IR.NamedFragmentSpread, rhs: IR.NamedFragmentSpread) -> Bool {
      lhs.fragment === rhs.fragment &&
      lhs.typeInfo == rhs.typeInfo &&
      lhs.inclusionConditions == rhs.inclusionConditions &&
      lhs.isDeferred == rhs.isDeferred
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(fragment))
      hasher.combine(typeInfo)
      hasher.combine(inclusionConditions)
      hasher.combine(isDeferred)
    }
    
    var debugDescription: String {
      var description = fragment.debugDescription
      if let inclusionConditions = inclusionConditions {
        description += " \(inclusionConditions.debugDescription)"
      }
      description += isDeferred.definitionDirectiveDescription
      return description
    }
  }
  
}
