use "_private"
use "collections"

class ref PNCounter[A: (Integer[A] val & Unsigned) = U64]
  is (Comparable[PNCounter[A]] & Convergent[PNCounter[A]] & Replicated)
  """
  A mutable counter, which can be both increased and decreased.

  This data type tracks the state seen from each replica, thus the size of the
  state will grow proportionally with the number of total replicas. New replicas
  may be added as peers at any time, provided that they use unique ids.
  Read-only replicas which never change state and only observe need not use
  unique ids, and should use an id of zero, by convention.

  The counter is implemented as a pair of grow-only counters, with one counter
  representing growth in the positive direction, and the other counter
  representing growth in the negative direction, with the total value of the
  counter being calculated from the difference in magnitude.

  Because the data type is composed of a pair of eventually consistent CRDTs,
  the calculated value of the overall counter is also eventually consistent.

  All mutator methods accept and return a convergent delta-state.
  """
  var _id: ID
  embed _pos: Map[ID, A]
  embed _neg: Map[ID, A]
  let _checklist: (DotChecklist | None)

  new ref create(id': ID) =>
    """
    Instantiate the PNCounter under the given unique replica id.
    """
    _id        = id'
    _pos       = _pos.create()
    _neg       = _neg.create()
    _checklist = None

  new ref _create_in(ctx: DotContext) =>
    _id        = ctx.id()
    _pos       = _pos.create()
    _neg       = _neg.create()
    _checklist = DotChecklist(ctx)

  fun ref _checklist_write() =>
    match _checklist | let c: DotChecklist => c.write() end

  fun ref _converge_empty_in(ctx: DotContext box): Bool => // ignore the context
    false

  fun is_empty(): Bool =>
    """
    Return true if the data structure contains no information (bottom state).
    """
    (_pos.size() == 0) and (_neg.size() == 0)

  fun apply(): A =>
    """
    Return the current value of the counter (the difference in magnitude).
    """
    value()

  fun value(): A =>
    """
    Return the current value of the counter (the difference in magnitude).
    """
    var sum = A(0)
    for v in _pos.values() do sum = sum + v end
    for v in _neg.values() do sum = sum - v end
    sum

  fun ref _pos_update(id': ID, value': A) => _pos(id') = value'
  fun ref _neg_update(id': ID, value': A) => _neg(id') = value'

  fun ref increment[D: PNCounter[A] ref = PNCounter[A]](
    value': A = 1,
    delta': D = recover PNCounter[A](0) end)
  : D^ =>
    """
    Increment the counter by the given value.
    Accepts and returns a convergent delta-state.
    """
    let v' = _pos.upsert(_id, value', {(v: A, value': A): A => v + value' })
    _checklist_write()
    delta'._pos_update(_id, v')
    consume delta'

  fun ref decrement[D: PNCounter[A] ref = PNCounter[A]](
    value': A = 1,
    delta': D = recover PNCounter[A](0) end)
  : D^ =>
    """
    Decrement the counter by the given value.
    Accepts and returns a convergent delta-state.
    """
    let v' = _neg.upsert(_id, value', {(v: A, value': A): A => v + value' })
    _checklist_write()
    delta'._neg_update(_id, v')
    consume delta'

  fun ref converge(that: PNCounter[A] box): Bool =>
    """
    Converge from the given PNCounter into this one.
    We converge the positive and negative counters, pairwise.
    Returns true if the convergence added new information to the data structure.
    """
    var changed = false
    for (id, value') in that._pos.pairs() do
      // TODO: introduce a stateful upsert in ponyc Map?
      if try value' > _pos(id)? else true end then
        _pos(id) = value'
        changed = true
      end
    end
    for (id, value') in that._neg.pairs() do
      // TODO: introduce a stateful upsert in ponyc Map?
      if try value' > _neg(id)? else true end then
        _neg(id) = value'
        changed = true
      end
    end
    changed

  fun string(): String iso^ =>
    """
    Return a best effort at printing the register. If A is Stringable, use
    the string representation of the value; otherwise print as a question mark.
    """
    iftype A <: Stringable val then
      value().string()
    else
      "?".clone()
    end

  fun eq(that: PNCounter[A] box): Bool => value().eq(that.value())
  fun ne(that: PNCounter[A] box): Bool => value().ne(that.value())
  fun lt(that: PNCounter[A] box): Bool => value().lt(that.value())
  fun le(that: PNCounter[A] box): Bool => value().le(that.value())
  fun gt(that: PNCounter[A] box): Bool => value().gt(that.value())
  fun ge(that: PNCounter[A] box): Bool => value().ge(that.value())

  fun ref from_tokens(that: TokensIterator)? =>
    """
    Deserialize an instance of this data structure from a stream of tokens.
    """
    if that.next[USize]()? != 3 then error end

    _id = that.next[ID]()?

    var pos_count = that.next[USize]()?
    if (pos_count % 2) != 0 then error end
    pos_count = pos_count / 2

    // TODO: _pos.reserve(pos_count)
    while (pos_count = pos_count - 1) > 0 do
      _pos.update(that.next[ID]()?, that.next[A]()?)
    end

    var neg_count = that.next[USize]()?
    if (neg_count % 2) != 0 then error end
    neg_count = neg_count / 2

    // TODO: _neg.reserve(neg_count)
    while (neg_count = neg_count - 1) > 0 do
      _neg.update(that.next[ID]()?, that.next[A]()?)
    end

  fun ref each_token(tokens: Tokens) =>
    """
    Serialize the data structure, capturing each token into the given Tokens.
    """
    tokens.push(USize(3))

    tokens.push(_id)

    tokens.push(_pos.size() * 2)
    for (id, v) in _pos.pairs() do
      tokens.push(id)
      tokens.push(v)
    end

    tokens.push(_neg.size() * 2)
    for (id, v) in _neg.pairs() do
      tokens.push(id)
      tokens.push(v)
    end
