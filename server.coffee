fieldsToProjection = (fields) ->
  projection =
    _id: 1 # In the case we want only id, that is, detect deletions
  for field in fields
    if _.isString field
      projection[field] = 1
    else
      _.extend projection, field
  projection

Document._TargetedFieldsObservingField = class extends Document._TargetedFieldsObservingField
  setupTargetObservers: =>
    referenceFields = fieldsToProjection @fields
    @targetCollection.find({}, fields: referenceFields).observeChanges
      added: (id, fields) =>
        @updateSource id, fields

      changed: (id, fields) =>
        @updateSource id, fields

      removed: (id) =>
        @removeSource id

# Have to refresh with new methods from TargetedFieldsObservingField
_.extend Document._ReferenceField.prototype,
  _.omit(Document._TargetedFieldsObservingField.prototype, 'constructor'),
  _.omit(Document._ReferenceField.prototype, 'constructor')
_.extend Document._GeneratedField.prototype,
  _.omit(Document._TargetedFieldsObservingField.prototype, 'constructor'),
  _.omit(Document._GeneratedField.prototype, 'constructor')

Document._ReferenceField = class extends Document._ReferenceField
  updateSource: (id, fields) =>
    # Just to be sure
    return if _.isEmpty fields

    selector = {}
    selector["#{ @sourcePath }._id"] = id

    update = {}
    for field, value of fields
      if @ancestorArray and @sourcePath is @ancestorArray
        path = "#{ @sourcePath }.$.#{ field }"
      else
        path = "#{ @sourcePath }.#{ field }"
      if _.isUndefined value
        update['$unset'] ?= {}
        update['$unset'][path] = ''
      else
        update['$set'] ?= {}
        update['$set'][path] = value

    @sourceCollection.update selector, update, multi: true

  removeSource: (id) =>
    selector = {}
    selector["#{ @sourcePath }._id"] = id

    # If it is an array, we remove references
    if @ancestorArray and @sourcePath is @ancestorArray
      path = "#{ @sourcePath }.$"
      update =
        $unset: {}
      update['$unset'][path] = ''

      # MongoDB supports removal of array elements only in two steps
      # First, we set all removed references to null
      @sourceCollection.update selector, update, multi: true

      # Then we remove all null elements
      selector = {}
      selector[@sourcePath] = null
      update =
        $pull: {}
      update['$pull'][@sourcePath] = null

      @sourceCollection.update selector, update, multi: true

    # If it is an optional reference, we set it to null
    else if not @required
      update =
        $set: {}
      update['$set'][@sourcePath] = null

      @sourceCollection.update selector, update, multi: true

    # Else, we remove the whole document
    else
      @sourceCollection.remove selector

  updatedWithValue: (id, value) =>
    unless _.isObject(value) and _.isString(value._id)
      # Special case: when elements are being deleted from the array they are temporary set to null value, so we are ignoring this
      return if _.isNull(value) and @ancestorArray and @sourcePath is @ancestorArray

      # Optional field
      return if _.isNull(value) and not @required

      # TODO: This is not triggered if required field simply do not exist or is set to undefined (does MongoDB support undefined value?)
      Log.warn "Document's '#{ id }' field '#{ @sourcePath }' was updated with invalid value: #{ util.inspect value }"
      return

    # Only _id is requested, we do not have to do anything
    return if _.isEmpty @fields

    referenceFields = fieldsToProjection @fields
    target = @targetCollection.findOne value._id,
      fields: referenceFields
      transform: null

    unless target
      Log.warn "Document's '#{ id }' field '#{ @sourcePath }' is referencing nonexistent document '#{ value._id }'"
      # TODO: Should we call reference.removeSource here?
      return

    # We omit _id because that field cannot be changed, or even $set to the same value, but is in target
    @updateSource target._id, _.omit target, '_id'

Document._GeneratedField = class extends Document._GeneratedField
  updateSource: (id, fields) =>
    if _.isEmpty fields
      fields._id = id
    # TODO: Not completely correct when @fields contain multiple fields from same subdocument or objects with projections (they will be counted only once) - because Meteor always passed whole subdocuments we could count only top-level fields in @fields, merged with objects?
    else if _.size(fields) isnt @fields.length
      targetFields = fieldsToProjection @fields
      fields = @targetCollection.findOne id,
        fields: targetFields
        transform: null

      # There is a slight race condition here, document could be deleted in meantime
      unless fields
        fields =
          _id: id
    else
      fields._id = id

    [selector, sourceValue] = @generator fields

    return unless selector

    update = {}
    if _.isUndefined sourceValue
      update['$unset'] = {}
      update['$unset'][@sourcePath] = ''
    else
      update['$set'] = {}
      update['$set'][@sourcePath] = sourceValue

    @sourceCollection.update selector, update, multi: true

  removeSource: (id) =>
    @updateSource id, {}

  updatedWithValue: (id, value) =>
    # Do nothing. Code should not be updating generated field by itself anyway.

Document = class extends Document
  @_sourceFieldUpdated: (id, name, value, field) ->
    # TODO: Should we check if field still exists but just value is undefined, so that it is the same as null? Or can this happen only when removing the field?
    return if _.isUndefined value

    field = field or @Meta.fields[name]

    # We should be subscribed only to those updates which are defined in @Meta.fields
    assert field

    if field instanceof Document._ObservingField
      if field.ancestorArray and name is field.ancestorArray
        unless _.isArray value
          Log.warn "Document's '#{ id }' field '#{ name }' was updated with non-array value: #{ util.inspect value }"
          return
      else
        value = [value]

      for v in value
        field.updatedWithValue id, v

    else if field not instanceof Document._Field
      for n, f of field
        @_sourceFieldUpdated id, "#{ name }.#{ n }", value[n], f

  @_sourceUpdated: (id, fields) ->
    for name, value of fields
      @_sourceFieldUpdated id, name, value

  @setupSourceObservers: ->
    return if _.isEmpty @Meta.fields

    sourceFields =
      _id: 1 # To make sure we do not pass empty set of fields

    sourceFieldsWalker = (obj) ->
      for name, field of obj
        if field instanceof Document._ObservingField
          sourceFields[field.sourcePath] = 1
        else if field not instanceof Document._Field
          sourceFieldsWalker field

    sourceFieldsWalker @Meta.fields

    @Meta.collection.find({}, fields: sourceFields).observeChanges
      added: (id, fields) =>
        @_sourceUpdated id, fields

      changed: (id, fields) =>
        @_sourceUpdated id, fields

setupObservers = ->
  setupTargetObservers = (fields) ->
    for name, field of fields
      # There are no arrays anymore here, just objects (for subdocuments) or fields
      if field instanceof Document._ObservingField
        field.setupTargetObservers()
      else if field not instanceof Document._Field
        setupTargetObservers field

  for document in Document.Meta.list
    setupTargetObservers document.Meta.fields
    document.setupSourceObservers()

Meteor.startup ->
  # To try delayed references one last time, this time we throw any exceptions
  # (Otherwise setupObservers would trigger strange exceptions anyway)
  Document._retryDelayed true

  setupObservers()
