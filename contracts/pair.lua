--- pair.lua -- ONE market, in its own process. ORDERBOOK.md §16.
---
--- A pair holds the free balances traded on its market and runs the shared
--- `orderbook.lua` over them. It never talks to a token or to the game: value
--- arrives from its VAULT or from a PEER pair as `Custody.Transfer`, and leaves
--- the same way. So one file serves both sides of the venue -- whether the
--- vault behind it is funded by tokens or by the game is not something a pair
--- can see.
---
--- Everything a pair is comes from its process DEFINITION, which the spawner
--- signed: `Pair-Vault`, `Pair-Base`, `Pair-Quote`, the market's limits
--- (`Pair-Tick`, ...), and its own `Pair-Id`. There is no configure verb to get
--- wrong and nothing to seal. Every name is prefixed because a definition is
--- shared with HyperBEAM and the spawner (`name`, `type`, `device` are theirs).
---
--- One signature, many steps: `Batch` runs up to sixteen steps all-or-nothing
--- in one slot. A `move` step sends the rest of the batch along with the value,
--- so "cancel here, move the Gold, buy there" is one signature and one hop.
--- The value is exactly-once; the steps that follow it are best effort, and a
--- refused continuation leaves the value as free balance where it landed.
---
--- ALL state lives in the one global `PairState`, so a checkpoint is one
--- encode and a test can run several pairs in one VM by swapping it.
---
--- Luerl-safe: no goto, no table.move, narrow every number through `int`.

local int, asString = Custody.int, Custody.asString
local tag, word, validId = Custody.tag, Custody.word, Custody.validId
local reply, fail = Custody.reply, Custody.fail

PairState = PairState or nil

-- Per-message scratch. Reset at the top of every compute.
local Touched = {}
local Dirty = {}
local StateIdle = false
local ForceCheckpoint = false

local function S() return PairState end

local function markState() Dirty.state = true end
local function markBook(traded)
  Dirty.book, Dirty.supply = true, true
  if traded then Dirty.trade = true end
  markState()
end

-- The book's host ---------------------------------------------------------------

local function tradingStopped()
  local e = S().emergency
  if not e.paused then return nil end
  return tostring(e.reason ~= "" and e.reason or "emergency pause")
end

local function movesStopped()
  local e = S().emergency
  if not e.paused or word(e.scope, "trading") ~= "all" then return nil end
  return tostring(e.reason ~= "" and e.reason or "emergency pause")
end

--- Built once; every closure reads `PairState` when it is CALLED, because a
--- refused batch replaces that table wholesale.
local cachedHost
local function host()
  if cachedHost then return cachedHost end
  cachedHost = OrderBook.custodyHost({
    ensure = function(state) return state end,
    ledger = {
      kind = "pair",
      exists = function(account) return validId(account) end,
      record = function() return nil end,
      balance = function(account, asset) return Custody.balanceOf(S(), account, asset) end,
      debit = function(account, asset, amount)
        return Custody.debitFree(S(), Touched, account, asset, amount)
      end,
      credit = function(account, asset, amount)
        return Custody.creditFree(S(), Touched, account, asset, amount)
      end,
    },
    pool = function(_, asset) return Custody.pool(S(), asset) end,
    fee = function(_, asset, amount)
      local fees = S().fees
      fees[asset] = int(fees[asset], 0) + int(amount, 0)
    end,
    tradable = function(_, asset) return asset == S().base or asset == S().quote end,
    pauseReason = function() return tradingStopped() end,
    orderChanged = function() markBook(false) end,
  })
  return cachedHost
end

-- State ---------------------------------------------------------------------------

local function newBook()
  return {
    markets = {},
    orders = {}, orderSeq = 0, orderHistory = {},
    fills = {}, fillSeq = 0,
    marketDaily = {}, marketIntraday = {},
    actionReceipts = {}, actionReceiptOrder = {},
    rejected = {},
  }
end

local function ensureState()
  PairState = type(PairState) == "table" and PairState or {}
  local s = PairState
  s.revision = int(s.revision, 0)
  s.ledger = type(s.ledger) == "table" and s.ledger or {}
  s.pools = type(s.pools) == "table" and s.pools or {}
  s.fees = type(s.fees) == "table" and s.fees or {}
  s.links = type(s.links) == "table" and s.links or {}
  s.peers = type(s.peers) == "table" and s.peers or {}
  s.quarantine = type(s.quarantine) == "table" and s.quarantine or {}
  s.emergency = type(s.emergency) == "table" and s.emergency
    or { paused = false, reason = "", scope = "trading", at = 0 }
  s.book = type(s.book) == "table" and s.book or newBook()
  for key, value in pairs(newBook()) do
    if s.book[key] == nil then s.book[key] = value end
  end
  OrderBook.normaliseMarketIntraday(s.book)
  OrderBook.ensureIndex(s.book)
  return s
end

--- Read the market off the signed definition, once. A pair whose definition
--- does not name a vault and two listed assets stays unconfigured, and every
--- verb that could move value refuses.
local MARKET_LIMITS = {
  { "Pair-Tick", "tick", 1 }, { "Pair-Lot", "lot", 1 },
  { "Pair-MinValue", "minValue", 0 }, { "Pair-MaxPrice", "maxPrice", 1 },
  { "Pair-MaxQuantity", "maxQuantity", 1 },
  { "Pair-TakerBps", "takerBps", 0, 1000 }, { "Pair-BandBps", "bandBps", 0, 10000 },
  { "Pair-CreationCost", "creationCost", 0 },
}

local function configure(base)
  local s = S()
  if s.configured then return nil end
  s.owner = Custody.spawner(base)
  local vault = Custody.definitionTag(base, "Pair-Vault")
  local baseAsset = Custody.definitionTag(base, "Pair-Base")
  local quoteAsset = Custody.definitionTag(base, "Pair-Quote")
  if not validId(vault) then return "The definition names no Pair-Vault" end
  if not Custody.validSlug(baseAsset) or not Custody.validSlug(quoteAsset)
     or baseAsset == quoteAsset then
    return "The definition must name two different assets as Pair-Base and Pair-Quote"
  end
  local overrides = { status = "closed" }
  for _, row in ipairs(MARKET_LIMITS) do
    local given = Custody.definitionTag(base, row[1])
    if given ~= nil then
      local n = int(given, -1)
      if n < row[3] or (row[4] and n > row[4]) then
        return row[1] .. " is out of range"
      end
      overrides[row[2]] = n
    end
  end
  local id = Custody.definitionTag(base, "Pair-Id")
  if id ~= nil and not Custody.validSlug(id) then return "Pair-Id must be a slug" end
  s.id = id or (baseAsset .. "_" .. quoteAsset)
  s.name = tostring(Custody.definitionTag(base, "Pair-Name") or ("TEST-" .. s.id))
  s.vault, s.base, s.quote = vault, baseAsset, quoteAsset
  s.market = OrderBook.marketId(baseAsset, quoteAsset)
  s.book.markets[s.market] = OrderBook.newMarket(baseAsset, quoteAsset, overrides)
  -- There is no desk here to quote into the ladder.
  s.book.markets[s.market].houseQuotes = false
  Custody.pool(s, baseAsset)
  Custody.pool(s, quoteAsset)
  s.configured = true
  Dirty.info, Dirty.book, Dirty.supply = true, true, true
  markState()
  return nil
end

-- Views -----------------------------------------------------------------------------

local function marketRow()
  return S().book.markets[S().market]
end

local function infoView()
  local s, market = S(), marketRow() or {}
  local peers = {}
  for id, row in pairs(s.peers) do peers[id] = row.process end
  return {
    Pair = s.id or "", Name = s.name or "", Owner = s.owner or "",
    Vault = s.vault or "", Base = s.base or "", Quote = s.quote or "",
    Market = s.market or "", Status = market.status or "unconfigured",
    Tick = int(market.tick, 1), Lot = int(market.lot, 1),
    MinValue = int(market.minValue, 0), MaxPrice = int(market.maxPrice, 0),
    MaxQuantity = int(market.maxQuantity, 0), TakerBps = int(market.takerBps, 0),
    BandBps = int(market.bandBps, 0), CreationCost = int(market.creationCost, 0),
    Paused = s.emergency.paused, PauseScope = word(s.emergency.scope, "trading"),
    Peers = peers,
  }
end

local function bookView(timestamp)
  local s = S()
  if not s.configured then return {} end
  local market = marketRow()
  local levels = OrderBook.p2pLadder(s.book, timestamp, s.base)
  return {
    id = s.market, base = s.base, quote = s.quote, status = market.status,
    tick = int(market.tick, 1), lot = int(market.lot, 1),
    bestBid = levels.bestBid, bestAsk = levels.bestAsk,
    depth = { bids = levels.bids, asks = levels.asks },
    band = OrderBook.bandView(host(), s.book, s.base, timestamp),
    candles = OrderBook.candleView(s.book, timestamp, s.base),
  }
end

--- What this pair owes, per asset. `held + fees` is what the vault's books
--- must find here once in-flight transfers are counted.
local function supplyView()
  local s, out = S(), {}
  for asset, row in pairs(s.pools) do
    local free, escrow, locked = int(row.player, 0), int(row.escrow, 0), int(row.locked, 0)
    out[asset] = {
      free = asString(free), escrow = asString(escrow), locked = asString(locked),
      fees = asString(s.fees[asset]), held = asString(free + escrow + locked),
    }
  end
  return out
end

local function accountView(account, timestamp)
  local free = {}
  for asset, amount in pairs(S().ledger[account] or {}) do free[asset] = asString(amount) end
  return {
    account = account, pair = S().id, free = free,
    orders = OrderBook.accountOrders(host(), S().book, account, timestamp),
    fills = OrderBook.accountFills(host(), S().book, account, 20),
  }
end

-- Moving value --------------------------------------------------------------------

--- Where a move may go: this pair's vault, or a peer the vault told us about
--- that LISTS the asset. Checked here so a move can never be sent somewhere
--- that would have to quarantine it.
local function destination(to, asset)
  local s = S()
  local name = tostring(to or "")
  if word(name) == "vault" or name == s.vault then return s.vault, "vault" end
  local peer = s.peers[name]
  if not peer then
    for id, row in pairs(s.peers) do
      if row.process == name then peer, name = row, id end
    end
  end
  if not peer then return nil, "No such pair: " .. name end
  if peer.base ~= asset and peer.quote ~= asset then
    return nil, name .. " does not trade " .. asset
  end
  return peer.process, name
end

--- Take `amount` of `asset` out of here and send it on, with `thenOps` riding
--- along to run as the same account on arrival. One link number, one message.
local function send(outbox, account, asset, amount, to, thenOps, hops)
  local s = S()
  if hops > Custody.MAX_HOPS then
    return nil, "A batch may cross at most " .. asString(Custody.MAX_HOPS) .. " processes"
  end
  local target, name = destination(to, asset)
  if not target then return nil, name end
  if thenOps ~= nil and (type(thenOps) ~= "table" or #thenOps > Custody.MAX_OPS) then
    return nil, "`then` must be a list of at most " .. asString(Custody.MAX_OPS) .. " steps"
  end
  if not Custody.release(s, Touched, account, asset, amount) then
    return nil, "You hold " .. asString(Custody.balanceOf(s, account, asset))
      .. " free " .. asset .. "; cancel an order to free more"
  end
  local seq = Custody.linkSend(s, target, asset, amount)
  outbox["transfer-" .. asString(seq) .. "-" .. name] =
    Custody.transferMessage(target, seq, account, asset, amount, thenOps, hops)
  Dirty.supply, Dirty.links = true, true
  markState()
  return { moved = asString(amount), asset = asset, to = name, seq = asString(seq) }
end

--- A quantity step, where "all" means everything free after the steps before.
local function stepAmount(account, asset, value)
  if word(tostring(value or "")) == "all" then
    local n = Custody.balanceOf(S(), account, asset)
    if n <= 0 then return nil, "Nothing free to move" end
    return n
  end
  return Custody.quantity(value)
end

-- Steps -----------------------------------------------------------------------------

local KNOWN = {
  place = true, amend = true, cancel = true, cancelall = true,
  move = true, withdraw = true,
}

--- One step as `account`. `hops` is how many processes the batch has crossed.
local function runStep(account, op, outbox, timestamp, hops)
  local s = S()
  if op.op == "place" then
    local placed, problem = OrderBook.placeOrder(host(), s.book, account,
      tostring(op.side or ""), s.base, int(op.price, 0), int(op.quantity, 0),
      timestamp, nil, { tif = op.tif, stp = op.stp, expiresIn = op.expiresIn })
    if not placed then return nil, problem end
    markBook(#(placed.fills or {}) > 0)
    return placed
  elseif op.op == "amend" then
    local amended, problem = OrderBook.amendOrder(host(), s.book, account,
      tostring(op.order or op.orderId or ""),
      op.price ~= nil and int(op.price, 0) or nil,
      op.quantity ~= nil and int(op.quantity, 0) or nil,
      timestamp, nil, { tif = op.tif, stp = op.stp })
    if not amended then return nil, problem end
    markBook(#(amended.fills or {}) > 0)
    return amended
  elseif op.op == "cancel" then
    local cancelled, problem = OrderBook.cancelOrder(host(), s.book, account,
      tostring(op.order or op.orderId or ""), timestamp, nil)
    if not cancelled then return nil, problem end
    markBook(false)
    return cancelled
  elseif op.op == "cancelall" then
    local cancelled, problem = OrderBook.cancelOrders(host(), s.book, account,
      {}, timestamp, nil)
    if not cancelled then return nil, problem end
    markBook(false)
    return cancelled
  end

  -- move / withdraw
  local stopped = movesStopped()
  if stopped then return nil, "Moves are paused: " .. stopped end
  local asset = tostring(op.asset or "")
  if asset ~= s.base and asset ~= s.quote then return nil, "This pair does not hold " .. asset end
  local amount, why = stepAmount(account, asset, op.quantity)
  if not amount then return nil, why end
  if op.op == "withdraw" then
    -- Out through the vault: the vault's own `withdraw` step pays the exact
    -- amount that arrived, never "all" of whatever is there by then.
    return send(outbox, account, asset, amount, "vault",
      { { op = "withdraw", asset = asset, quantity = asString(amount) } }, hops)
  end
  return send(outbox, account, asset, amount, op.to, op["then"], hops)
end

--- Run `ops` as `account`, all-or-nothing.
local function runBatch(account, ops, timestamp, hops)
  local ordered, problem = Custody.orderOps(ops, KNOWN)
  if not ordered then return nil, problem end
  local results, refused, rolledBack, outbox = Custody.runAtomic("PairState", ordered,
    function(op, out) return runStep(account, op, out, timestamp, hops) end)
  if not results then return nil, refused, nil, rolledBack end
  return results, nil, outbox
end

-- Handlers --------------------------------------------------------------------------

local H = {}

local function requireConfigured(base)
  if not S().configured then return fail(base, "This pair is not configured") end
  return nil
end

H["Info"] = function(base) return reply(base, infoView()) end
H["Book"] = function(base, _, timestamp) return reply(base, bookView(timestamp)) end
H["Supply"] = function(base)
  return reply(base, { supply = supplyView(), links = Custody.linkView(S()) })
end
H["Balance"] = function(base, msg, timestamp)
  local account = tag(msg, "Account", "Recipient") or Custody.provenSigner(msg)
  if not validId(account) then return fail(base, "No address") end
  return reply(base, accountView(account, timestamp))
end

--- THE verb. Everything a trader signs is a batch; the single-step verbs
--- below are batches of one, kept so a simple client stays simple.
local function signedBatch(base, msg, timestamp, b, ops)
  local refusal = requireConfigured(base)
  if refusal then return refusal end
  local who = Custody.actor(msg, b)
  if not validId(who) then return fail(base, "Unsigned messages cannot trade") end
  local actionId = tag(msg, "ActionId")
  local seen = Custody.receipt(S(), who, actionId)
  if seen then
    StateIdle = true
    return reply(base, { replayed = true, summary = seen.summary,
      account = accountView(who, timestamp) })
  end
  local results, problem, outbox, rolledBack = runBatch(who, ops, timestamp, 1)
  if not results then
    -- Put back wholesale, so nothing it touched is republished either.
    if rolledBack then Touched, Dirty, StateIdle = {}, {}, true end
    return fail(base, problem)
  end
  Custody.remember(S(), who, actionId, timestamp, { steps = asString(#results) })
  Touched[who] = true
  markState()
  return reply(base, { results = results, account = accountView(who, timestamp) },
    next(outbox) and outbox or nil)
end

H["Batch"] = function(base, msg, timestamp, b)
  local ops, problem = Custody.decodeOps(tag(msg, "Ops", "Steps") or msg.Data or msg.data)
  if not ops then return fail(base, problem) end
  return signedBatch(base, msg, timestamp, b, ops)
end

H["Order.Place"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b, { {
    op = "place", side = tag(msg, "Side"), price = tag(msg, "Price"),
    quantity = tag(msg, "Quantity"), tif = tag(msg, "Tif", "TimeInForce"),
    stp = tag(msg, "Stp", "SelfTrade"), expiresIn = tag(msg, "ExpiresIn"),
  } })
end

H["Order.Amend"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b, { {
    op = "amend", order = tag(msg, "OrderId", "Order"),
    price = tag(msg, "Price"), quantity = tag(msg, "Quantity"),
    tif = tag(msg, "Tif", "TimeInForce"), stp = tag(msg, "Stp", "SelfTrade"),
  } })
end

H["Order.Cancel"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b,
    { { op = "cancel", order = tag(msg, "OrderId", "Order") } })
end

H["Order.CancelAll"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b, { { op = "cancelall" } })
end

H["Move"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b, { {
    op = "move", asset = tag(msg, "Asset"), quantity = tag(msg, "Quantity"),
    to = tag(msg, "To", "Destination"),
  } })
end

H["Withdraw"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b,
    { { op = "withdraw", asset = tag(msg, "Asset"), quantity = tag(msg, "Quantity") } })
end

--- Release the escrow of orders the clock has retired. Anyone may call it; one
--- that released nothing declares itself idle and skips the state rewrite.
H["Order.Maintain"] = function(base, msg, timestamp)
  local refusal = requireConfigured(base)
  if refusal then return refusal end
  local expired = OrderBook.maintain(host(), S().book, timestamp, int(tag(msg, "Limit"), 25))
  StateIdle = int(expired, 0) == 0
  if not StateIdle then markBook(false) end
  return reply(base, { expired = expired })
end

-- Custody ---------------------------------------------------------------------------

local QUARANTINE_LIMIT = 64

--- Credit a transfer that is known to be good, then run what rode along.
local function land(base, from, seq, account, asset, amount, thenOps, hops, timestamp)
  local s = S()
  if not Custody.linkAccept(s, from, seq, asset, amount) then return nil end
  Custody.admit(s, Touched, account, asset, amount)
  Dirty.supply, Dirty.links = true, true
  markState()
  local landed = { from = from, seq = asString(seq), asset = asset, amount = asString(amount) }
  if type(thenOps) ~= "table" or #thenOps == 0 then return landed end
  local results, problem, outbox = runBatch(account, thenOps, timestamp, hops + 1)
  if results then
    landed["then"] = results
    return landed, outbox
  end
  -- Best effort, and said so: the value stays here as free balance.
  landed.thenRefused = problem
  return landed
end

--- Value from our vault or a peer pair. Anything uncreditable is QUARANTINED,
--- never refused: the sender already debited, so a refusal would lose it.
H["Custody.Transfer"] = function(base, msg, timestamp, b)
  local s = S()
  local from = Custody.sourceProcess(msg, b)
  if not validId(from) then return fail(base, "Not authorised") end
  local seq = int(tag(msg, "Seq"), 0)
  local account = tag(msg, "Account", "PlayerId")
  local asset = tostring(tag(msg, "Asset") or "")
  local amount = int(tag(msg, "Quantity"), 0)
  local hops = int(tag(msg, "Hops"), 1)
  if seq <= 0 then return fail(base, "A transfer must carry its Seq") end
  if Custody.linkSeen(s, from, seq) then
    StateIdle = true
    return reply(base, { unchanged = true, from = from, seq = asString(seq) })
  end

  local known = s.configured and (from == s.vault or s.peerByProcess and s.peerByProcess[from])
  local good = known and validId(account) and amount > 0
    and (asset == s.base or asset == s.quote)
  if not good then
    local key = from .. ":" .. asString(seq)
    if s.quarantine[key] then
      StateIdle = true
      return reply(base, { quarantined = s.quarantine[key], unchanged = true })
    end
    local count = 0
    for _ in pairs(s.quarantine) do count = count + 1 end
    if count >= QUARANTINE_LIMIT then return fail(base, "Quarantine is full") end
    s.quarantine[key] = {
      from = from, seq = asString(seq), account = account, asset = asset,
      amount = asString(amount), at = timestamp,
    }
    markState()
    return reply(base, { quarantined = s.quarantine[key] })
  end

  local thenOps = nil
  local rawThen = tag(msg, "Then")
  if rawThen then thenOps = Custody.decodeOps(rawThen) end
  local landed, outbox = land(base, from, seq, account, asset, amount, thenOps, hops, timestamp)
  if not landed then return fail(base, "That transfer number is out of range") end
  return reply(base, { landed = landed, account = accountView(account, timestamp) }, outbox)
end

--- Release quarantined transfers whose sender and asset are now recognised.
local function retryQuarantine(timestamp)
  local s = S()
  local released = {}
  for key, row in pairs(s.quarantine) do
    local known = row.from == s.vault or (s.peerByProcess and s.peerByProcess[row.from])
    if known and validId(row.account) and int(row.amount, 0) > 0
       and (row.asset == s.base or row.asset == s.quote) then
      if land(nil, row.from, int(row.seq, 0), row.account, row.asset,
          int(row.amount, 0), nil, 1, timestamp) then
        released[#released + 1] = key
      end
      s.quarantine[key] = nil
    end
  end
  return released
end

--- The vault telling this pair who its peers are. Replaces the whole list.
H["Custody.Peers"] = function(base, msg, timestamp, b)
  local s = S()
  local from = Custody.sourceProcess(msg, b)
  if not s.configured or from ~= s.vault then return fail(base, "Not authorised") end
  local listed = Custody.decodedTable(tag(msg, "Peers") or msg.Data or msg.data)
  if type(listed) ~= "table" then return fail(base, "Peers must be a JSON object") end
  local peers, byProcess = {}, {}
  for id, row in pairs(listed) do
    if type(row) == "table" and Custody.validSlug(id) and validId(row.process)
       and row.process ~= s.vault and id ~= s.id then
      peers[id] = { process = row.process, base = tostring(row.base or ""),
        quote = tostring(row.quote or "") }
      byProcess[row.process] = id
    end
  end
  s.peers, s.peerByProcess = peers, byProcess
  local released = retryQuarantine(timestamp)
  Dirty.info = true
  markState()
  return reply(base, { peers = infoView().Peers, released = released })
end

-- Admin -----------------------------------------------------------------------------

local function requireOwner(base, msg, b)
  local who = Custody.provenSigner(msg)
  if not S().owner or who ~= S().owner or Custody.sourceProcess(msg, b) then
    return fail(base, "Not authorised")
  end
  return requireConfigured(base)
end

local function setStatus(base, msg, b, status)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  marketRow().status = status
  Dirty.info, Dirty.book = true, true
  markState()
  return reply(base, infoView())
end

--- Markets open CLOSED; launching is a separate, deliberate act.
H["Admin.Launch"] = function(base, msg, _, b) return setStatus(base, msg, b, "open") end
--- Suspended, not cancelled: resting orders stay and can still be cancelled.
H["Admin.Suspend"] = function(base, msg, _, b) return setStatus(base, msg, b, "suspended") end

--- `Scope = "trading"` stops the book and leaves moves open; `all` stops both.
H["Admin.Pause"] = function(base, msg, timestamp, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  local scope = word(tag(msg, "Scope"), "trading")
  if scope ~= "trading" and scope ~= "all" then return fail(base, "Scope is trading or all") end
  S().emergency = { paused = true, reason = tostring(tag(msg, "Reason") or "emergency pause"),
    scope = scope, at = timestamp }
  Dirty.info = true
  markState()
  return reply(base, infoView())
end

H["Admin.Resume"] = function(base, msg, timestamp, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  S().emergency = { paused = false, reason = "", scope = "trading", at = timestamp }
  Dirty.info = true
  markState()
  return reply(base, infoView())
end

H["Admin.Checkpoint"] = function(base, msg, _, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  ForceCheckpoint = true
  return reply(base, { revision = asString(S().revision), checkpoint = true })
end

-- Publication -----------------------------------------------------------------------

--- The checkpoint, minus everything derivable. The index is rebuilt by
--- `ensureIndex`, intraday bars come back from `paircandles` (published once,
--- never twice), and the rest is a log or telemetry.
local DROPPED = {
  bookIndex = true, orderHistory = true, rejected = true,
  actionReceiptOrder = true, marketIntraday = true,
  marketIntradayVersion = true, marketDailyNormalized = true,
}

local function checkpointView()
  local out = {}
  for key, value in pairs(S()) do out[key] = value end
  local book = {}
  for key, value in pairs(S().book) do
    if not DROPPED[key] then book[key] = value end
  end
  out.book = book
  return out
end

local function restoreIntraday(base)
  local s = S()
  if not s.configured or next(s.book.marketIntraday or {}) ~= nil then return end
  local published = Custody.decodedTable(base and base.paircandles)
  if not published then return end
  local restored = {}
  for seconds, rows in pairs(published) do
    if type(rows) == "table" then restored[seconds] = { [s.base] = rows } end
  end
  s.book.marketIntraday = restored
  s.book.marketIntradayVersion = nil
  OrderBook.normaliseMarketIntraday(s.book)
end

local RESOLVED = nil
local function resolveHandler(action)
  if not RESOLVED then
    RESOLVED = {}
    for name, handler in pairs(H) do RESOLVED[word(name)] = handler end
  end
  return RESOLVED[word(tostring(action or ""))]
end

function PairCompute(base, req)
  base = type(base) == "table" and base or {}
  local msg = (req and req.body) or {}
  -- The scheduler's assignment, never the body: a wallet must not set the clock.
  local timestamp = int((req and (req.timestamp or req.Timestamp))
    or msg.Timestamp or msg.timestamp, 0)
  Touched, Dirty, StateIdle, ForceCheckpoint = {}, {}, false, false

  local restored, restoreProblem = Custody.restore("PairState", base, "paircommit", "pairstate")
  local initial = base.paircommit == nil
  local result
  if not restored then
    result = fail(base, restoreProblem)
  else
    ensureState()
    restoreIntraday(base)
    local configProblem = configure(base)
    local action = tag(msg, "Action") or "none"
    local handler = resolveHandler(action)
    if not handler then
      local names = {}
      for name in pairs(H) do names[#names + 1] = name end
      table.sort(names)
      result = fail(base, "unknown action '" .. tostring(action) .. "'. known: "
        .. table.concat(names, ", "))
    elseif configProblem and word(action) ~= "info" then
      result = fail(base, configProblem)
    else
      local ok, out = pcall(function() return handler(base, msg, timestamp, base) end)
      result = ok and out or fail(base, tostring(out))
    end
  end
  if not restored then return result end

  local s = S()
  if Dirty.state and not StateIdle then s.revision = int(s.revision, 0) + 1 end
  local patchMode = Lua53bPatchMode == true
  local checkpoint = initial or ForceCheckpoint
    or (Dirty.state and not StateIdle and (not patchMode or s.revision % 50 == 0))

  -- Published state. Never `info` (the device answers it); never the orders or
  -- fills in full (every message would pay for every resting order).
  if initial or Dirty.info then
    result.pairinfo = encode(infoView())
    result.paused = s.emergency.paused and "1" or "0"
  end
  if initial or Dirty.book then result.pairbook = encode(bookView(timestamp)) end
  if (initial or Dirty.trade) and s.configured then
    result.paircandles = encode(OrderBook.intradayView(s.book, timestamp, s.base))
    result.pairtape = encode(OrderBook.tapeView(s.book)[s.market] or {})
  end
  if initial or Dirty.supply then result.pairsupply = encode(supplyView()) end
  if initial or Dirty.links then result.pairlinks = encode(Custody.linkView(s)) end
  if checkpoint then result.pairstate = encode(checkpointView()) end
  if initial or Dirty.state or ForceCheckpoint then
    result.paircommit = encode({ revision = s.revision })
  end
  for address in pairs(Touched) do
    result["balance-" .. address] = encode(accountView(address, timestamp))
  end

  -- A full collect as a bare statement, never inside a pcall (see venue.lua).
  collectgarbage("collect")
  return result
end

compute = PairCompute
