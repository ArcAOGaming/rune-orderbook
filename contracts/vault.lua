--- vault.lua -- custody at the edge of the venue, and the factory's registry.
--- ORDERBOOK.md §16.
---
--- ONE file, TWO deployments, and the only difference is how value is FUNDED:
---
---   Vault-Funding = "token"   value arrives as `Credit-Notice` from a listed token
---                       and leaves as `Transfer` back to the wallet;
---   Vault-Funding = "game"    value arrives as `Venue.Credit` from the game and
---                       leaves as `Venue.Return` to it -- exactly the protocol
---                       the game already speaks to a venue, so the game does
---                       not change at all.
---
--- Everything past the edge is identical. The vault holds what has not been
--- allocated to a pair, moves it to and from pairs over the same numbered links
--- the pairs use between themselves, and keeps the REGISTRY of pairs: which
--- processes are ours, and what each trades. Registering a pair tells every
--- pair about every other one, which is what lets them move value directly
--- without coming back through here.
---
--- Funding is read off the signed process definition and cannot change. A
--- token vault has no verb the game can reach and a game vault has no verb a
--- token can reach, so a bug on one side cannot move the other's value.
---
--- ALL state lives in the one global `VaultState`.
---
--- Luerl-safe: no goto, no table.move, narrow every number through `int`.

local int, asString = Custody.int, Custody.asString
local tag, word, validId = Custody.tag, Custody.word, Custody.validId
local reply, fail = Custody.reply, Custody.fail

VaultState = VaultState or nil

local Touched = {}
local Dirty = {}
local StateIdle = false
local ForceCheckpoint = false

local function S() return VaultState end
local function markState() Dirty.state = true end
local function markSupply() Dirty.supply, Dirty.links = true, true; markState() end

-- State ---------------------------------------------------------------------------

local function ensureState()
  VaultState = type(VaultState) == "table" and VaultState or {}
  local s = VaultState
  s.revision = int(s.revision, 0)
  for _, key in ipairs({ "ledger", "pools", "links", "assets", "assetByProcess",
      "pairs", "pairByProcess", "deposits", "withdrawals", "backing" }) do
    s[key] = type(s[key]) == "table" and s[key] or {}
  end
  s.withdrawSeq = int(s.withdrawSeq, 0)
  s.emergency = type(s.emergency) == "table" and s.emergency
    or { paused = false, reason = "", scope = "trading", at = 0 }
  return s
end

local function configure(base)
  local s = S()
  if s.configured then return nil end
  s.owner = Custody.spawner(base)
  local funding = word(Custody.definitionTag(base, "Vault-Funding"))
  if funding ~= "token" and funding ~= "game" then
    return "The definition must name Vault-Funding = token or game"
  end
  if funding == "game" then
    local game = Custody.definitionTag(base, "Vault-Game")
    if not validId(game) then return "A game vault's definition must name its Vault-Game" end
    s.game = game
  end
  s.funding = funding
  s.name = tostring(Custody.definitionTag(base, "Vault-Name") or ("TEST-Venue Vault (" .. funding .. ")"))
  s.configured = true
  Dirty.info = true
  markState()
  return nil
end

--- Game assets carry a denomination that IS the custody scale: the game moves
--- whole units and a pair trades hundredths of them. Tokens arrive atomic.
local function assetScale(asset)
  if S().funding ~= "game" then return 1 end
  local row = S().assets[asset]
  local denomination = math.max(0, math.min(12, int(row and row.denomination, 0)))
  local scale = 1
  for _ = 1, denomination do scale = scale * 10 end
  return scale
end

-- Views -----------------------------------------------------------------------------

local function pairsView()
  local out = {}
  for id, row in pairs(S().pairs) do
    out[id] = { process = row.process, base = row.base, quote = row.quote }
  end
  return out
end

local function infoView()
  local s = S()
  local assets = {}
  for id, row in pairs(s.assets) do
    assets[id] = { id = id, name = row.name, kind = row.kind, process = row.process,
      ticker = row.ticker, denomination = asString(row.denomination) }
  end
  return {
    Name = s.name or "", Owner = s.owner or "", Funding = s.funding or "",
    Game = s.game or "", Sealed = s.sealed == true, Assets = assets,
    Paused = s.emergency.paused, PauseScope = word(s.emergency.scope, "trading"),
  }
end

--- The reconciliation, restated as numbers anybody can check:
---
---   backing   what came in from outside, less what went back out;
---   free      what accounts hold here, unallocated;
---   allocated sent to pairs less received from them, i.e. what the pairs hold
---             plus what is in flight between us.
---
--- `backing == free + allocated`, always. The other half -- that `allocated`
--- is what the pairs actually hold -- is each pair's own `pairsupply` plus the
--- link totals in flight, all published.
local function supplyView()
  local s, out = S(), {}
  for asset in pairs(s.assets) do
    local allocated = 0
    for _, row in pairs(s.links) do
      allocated = allocated + int(row.sent and row.sent[asset], 0)
        - int(row.received and row.received[asset], 0)
    end
    local free = int(Custody.pool(s, asset).player, 0)
    out[asset] = {
      backing = asString(s.backing[asset]), free = asString(free),
      allocated = asString(allocated), scale = asString(assetScale(asset)),
      balanced = int(s.backing[asset], 0) == free + allocated,
    }
  end
  return out
end

local function accountView(account)
  local free = {}
  for asset, amount in pairs(S().ledger[account] or {}) do free[asset] = asString(amount) end
  return { account = account, vault = true, free = free }
end

-- Moving value ----------------------------------------------------------------------

local function withdrawalsStopped()
  local e = S().emergency
  if not e.paused or word(e.scope, "trading") ~= "all" then return nil end
  return tostring(e.reason ~= "" and e.reason or "emergency pause")
end

local function stepAmount(account, asset, value)
  if word(tostring(value or "")) == "all" then
    local n = Custody.balanceOf(S(), account, asset)
    if n <= 0 then return nil, "Nothing free to move" end
    return n
  end
  return Custody.quantity(value)
end

--- Allocate to a pair: out of the vault's free balance, onto the link.
local function moveToPair(outbox, account, asset, amount, to, thenOps, hops)
  local s = S()
  if hops > Custody.MAX_HOPS then return nil, "A batch may cross at most "
    .. asString(Custody.MAX_HOPS) .. " processes" end
  local name = tostring(to or "")
  local pair = s.pairs[name]
  if not pair and s.pairByProcess[name] then
    name = s.pairByProcess[name]
    pair = s.pairs[name]
  end
  if not pair then return nil, "No such pair: " .. name end
  if pair.base ~= asset and pair.quote ~= asset then
    return nil, name .. " does not trade " .. asset
  end
  if thenOps ~= nil and (type(thenOps) ~= "table" or #thenOps > Custody.MAX_OPS) then
    return nil, "`then` must be a list of at most " .. asString(Custody.MAX_OPS) .. " steps"
  end
  if not Custody.release(s, Touched, account, asset, amount) then
    return nil, "You hold " .. asString(Custody.balanceOf(s, account, asset))
      .. " free " .. asset .. " at the vault"
  end
  local seq = Custody.linkSend(s, pair.process, asset, amount)
  outbox["transfer-" .. asString(seq) .. "-" .. name] =
    Custody.transferMessage(pair.process, seq, account, asset, amount, thenOps, hops)
  markSupply()
  return { moved = asString(amount), asset = asset, to = name, seq = asString(seq) }
end

--- Out of the venue altogether. The debit happens HERE, before the far side is
--- asked, and the row is `pending` until it confirms: the other way round, a
--- payout that landed while the reply was lost would pay twice.
local function withdraw(outbox, account, asset, amount)
  local s = S()
  local stopped = withdrawalsStopped()
  if stopped then return nil, "Withdrawals are paused: " .. stopped end
  local row = s.assets[asset]
  if not row then return nil, "This vault does not list " .. asset end
  local scale = assetScale(asset)
  if amount % scale ~= 0 then
    return nil, "The game takes back whole " .. tostring(row.name or asset)
      .. "; leave the fraction here until it reaches one"
  end
  local backingAmount = amount // scale
  if not Custody.release(s, Touched, account, asset, amount) then
    return nil, "You hold " .. asString(Custody.balanceOf(s, account, asset))
      .. " free " .. asset .. " at the vault"
  end
  s.backing[asset] = int(s.backing[asset], 0) - amount
  s.withdrawSeq = s.withdrawSeq + 1
  local id = "w" .. asString(s.withdrawSeq)
  s.withdrawals[id] = {
    id = id, account = account, asset = asset, amount = asString(amount),
    backingAmount = asString(backingAmount), status = "pending",
  }
  if s.funding == "token" then
    outbox["withdraw-" .. id] = {
      target = row.process, Action = "Transfer",
      Recipient = account, Quantity = asString(amount),
      ["X-Reference"] = id, ["X-Venue-Withdrawal"] = id,
    }
  else
    outbox["withdraw-" .. id] = {
      target = s.game, Action = "Venue.Return",
      Account = account, PlayerId = account,
      Asset = asset, Item = asset, Quantity = asString(backingAmount),
      Reference = id, ["Withdrawal-Id"] = id,
    }
  end
  markSupply()
  return { withdrawal = id, asset = asset, amount = asString(amount) }
end

local KNOWN = { move = true, withdraw = true }

local function runStep(account, op, outbox, hops)
  local asset = tostring(op.asset or "")
  if not S().assets[asset] then return nil, "This vault does not list " .. asset end
  local amount, why = stepAmount(account, asset, op.quantity)
  if not amount then return nil, why end
  if op.op == "withdraw" then return withdraw(outbox, account, asset, amount) end
  return moveToPair(outbox, account, asset, amount, op.to, op["then"], hops)
end

local function runBatch(account, ops, hops)
  local ordered, problem = Custody.orderOps(ops, KNOWN)
  if not ordered then return nil, problem end
  local results, refused, rolledBack, outbox = Custody.runAtomic("VaultState", ordered,
    function(op, out) return runStep(account, op, out, hops) end)
  if not results then return nil, refused, nil, rolledBack end
  return results, nil, outbox
end

--- Value has landed here for `account`; run what rode along, best effort.
local function continueWith(account, thenOps, hops)
  if type(thenOps) ~= "table" or #thenOps == 0 then return nil, nil end
  local results, problem, outbox = runBatch(account, thenOps, hops + 1)
  if results then return { ["then"] = results }, outbox end
  return { thenRefused = problem }, nil
end

-- Handlers --------------------------------------------------------------------------

local H = {}

H["Info"] = function(base) return reply(base, infoView()) end
H["Pairs"] = function(base) return reply(base, pairsView()) end
H["Supply"] = function(base)
  return reply(base, { supply = supplyView(), links = Custody.linkView(S()) })
end
H["Balance"] = function(base, msg)
  local account = tag(msg, "Account", "Recipient") or Custody.provenSigner(msg)
  if not validId(account) then return fail(base, "No address") end
  return reply(base, accountView(account))
end

local function signedBatch(base, msg, timestamp, b, ops)
  local who = Custody.actor(msg, b)
  if not validId(who) then return fail(base, "Unsigned messages cannot move value") end
  local actionId = tag(msg, "ActionId")
  local seen = Custody.receipt(S(), who, actionId)
  if seen then
    StateIdle = true
    return reply(base, { replayed = true, summary = seen.summary, account = accountView(who) })
  end
  local results, problem, outbox, rolledBack = runBatch(who, ops, 1)
  if not results then
    if rolledBack then Touched, Dirty, StateIdle = {}, {}, true end
    return fail(base, problem)
  end
  Custody.remember(S(), who, actionId, timestamp, { steps = asString(#results) })
  markState()
  return reply(base, { results = results, account = accountView(who) },
    next(outbox) and outbox or nil)
end

H["Batch"] = function(base, msg, timestamp, b)
  local ops, problem = Custody.decodeOps(tag(msg, "Ops", "Steps") or msg.Data or msg.data)
  if not ops then return fail(base, problem) end
  return signedBatch(base, msg, timestamp, b, ops)
end

H["Move"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b, { {
    op = "move", asset = tag(msg, "Asset"), quantity = tag(msg, "Quantity"),
    to = tag(msg, "To", "Pair"),
  } })
end

H["Withdraw"] = function(base, msg, timestamp, b)
  return signedBatch(base, msg, timestamp, b,
    { { op = "withdraw", asset = tag(msg, "Asset"), quantity = tag(msg, "Quantity") } })
end

-- Funding in ------------------------------------------------------------------------

--- Credit a deposit exactly once, keyed on the funder's own reference. Anything
--- uncreditable is QUARANTINED, never refused: the value has already moved.
--- If the depositor named a pair, the deposit goes straight on to it in the
--- same slot -- deposit-and-trade is one message from the wallet's side.
local function settleDeposit(base, key, account, asset, amount, backingAmount, forward)
  local s = S()
  local seen = s.deposits[key]
  if seen then
    StateIdle = true
    return reply(base, { deposit = seen, unchanged = true }), false
  end
  local function quarantine(why)
    s.deposits[key] = { account = account, asset = asset, amount = asString(amount),
      backingAmount = asString(backingAmount), status = "unresolved", reason = why }
    markState()
    return reply(base, { deposit = s.deposits[key] }), false
  end
  if not validId(account) then return quarantine("The deposit names no account") end
  if not s.assets[asset] then return quarantine("This vault does not list that asset") end
  if amount <= 0 then return quarantine("A deposit must be a positive whole amount") end

  Custody.admit(s, Touched, account, asset, amount)
  s.backing[asset] = int(s.backing[asset], 0) + amount
  s.deposits[key] = { status = "credited" }
  markSupply()

  local out, outbox = { deposit = { status = "credited", account = account,
    asset = asset, amount = asString(amount) } }, nil
  if forward and forward.pair then
    local results, problem
    results, problem, outbox = runBatch(account, { {
      op = "move", asset = asset, quantity = asString(amount),
      to = forward.pair, ["then"] = forward.thenOps,
    } }, 1)
    if results then out.forwarded = results else out.forwardRefused = problem end
  end
  out.account = accountView(account)
  return reply(base, out, outbox), true
end

local function forwardOf(msg)
  local pair = tag(msg, "X-Pair", "Pair")
  if not pair then return nil end
  local rawThen = tag(msg, "X-Then", "Then")
  return { pair = pair, thenOps = rawThen and Custody.decodeOps(rawThen) or nil }
end

--- TOKEN: a listed token telling us somebody paid us. The depositor is the
--- notice's `Sender`; the signer of a delivery is the scheduler.
H["Credit-Notice"] = function(base, msg, _, b)
  local s = S()
  if s.funding ~= "token" then return fail(base, "This is a game vault") end
  local from = Custody.sourceProcess(msg, b)
  local asset = from and s.assetByProcess[from] or nil
  if not asset then return fail(base, "Not authorised") end
  local reference = tag(msg, "Reference", "X-Reference")
  if type(reference) ~= "string" or reference == "" then
    reference = tostring(msg.Id or msg.id or "")
  end
  if reference == "" then return fail(base, "A credit notice must carry a Reference") end
  local amount = int(tag(msg, "Quantity"), 0)
  local result = settleDeposit(base, from .. ":" .. reference, tag(msg, "Sender", "From"),
    asset, amount, amount, forwardOf(msg))
  return result
end

--- GAME: the game telling us a player handed assets over, acknowledged with
--- `Venue.Credited` only in the message that actually credited.
H["Venue.Credit"] = function(base, msg, _, b)
  local s = S()
  if s.funding ~= "game" then return fail(base, "This is a token vault") end
  local from = Custody.sourceProcess(msg, b)
  if not from or from ~= s.game then return fail(base, "Not authorised") end
  local reference = tag(msg, "Reference", "DepositId")
  if type(reference) ~= "string" or reference == "" then
    return fail(base, "A venue credit must carry a Reference")
  end
  local asset = tostring(tag(msg, "Asset", "Item") or "")
  local backingAmount = int(tag(msg, "Quantity"), 0)
  local amount = math.tointeger(backingAmount * assetScale(asset)) or 0
  local result, credited = settleDeposit(base, from .. ":" .. reference,
    tag(msg, "Account", "PlayerId"), asset, amount, backingAmount, forwardOf(msg))
  if credited then
    result.results.outbox = result.results.outbox or {}
    result.results.outbox["venue-credited"] = {
      target = s.game, Action = "Venue.Credited",
      Reference = reference, ["Deposit-Id"] = reference,
    }
  end
  return result
end

--- The far side confirming a withdrawal landed. Settles a row; moves nothing.
local function settleWithdrawal(base, from, id)
  local s = S()
  local w = s.withdrawals[type(id) == "string" and id or ""]
  if not w then return fail(base, "No such withdrawal") end
  if w.status ~= "pending" then
    StateIdle = true
    return reply(base, { withdrawal = w, unchanged = true })
  end
  local expected = s.funding == "token" and (s.assets[w.asset] or {}).process or s.game
  if not from or from ~= expected then return fail(base, "Not authorised") end
  s.withdrawals[id] = { status = "settled" }
  markState()
  return reply(base, { withdrawal = { id = id, status = "settled" } })
end

H["Debit-Notice"] = function(base, msg, _, b)
  if S().funding ~= "token" then return fail(base, "This is a game vault") end
  return settleWithdrawal(base, Custody.sourceProcess(msg, b),
    tag(msg, "X-Reference", "Reference", "X-Venue-Withdrawal"))
end

H["Venue.Returned"] = function(base, msg, _, b)
  if S().funding ~= "game" then return fail(base, "This is a token vault") end
  return settleWithdrawal(base, Custody.sourceProcess(msg, b),
    tag(msg, "Reference", "Withdrawal-Id"))
end

-- From our own pairs ---------------------------------------------------------------

--- Value coming back from a registered pair, and whatever rode along with it
--- -- usually `withdraw`, which is how a trader leaves in one signature.
H["Custody.Transfer"] = function(base, msg, _, b)
  local s = S()
  local from = Custody.sourceProcess(msg, b)
  if not from or not s.pairByProcess[from] then return fail(base, "Not authorised") end
  local seq = int(tag(msg, "Seq"), 0)
  if seq <= 0 then return fail(base, "A transfer must carry its Seq") end
  if Custody.linkSeen(s, from, seq) then
    StateIdle = true
    return reply(base, { unchanged = true, from = from, seq = asString(seq) })
  end
  local account = tag(msg, "Account", "PlayerId")
  local asset = tostring(tag(msg, "Asset") or "")
  local amount = int(tag(msg, "Quantity"), 0)
  -- A registered pair only sends what it validated; if one ever sends nonsense
  -- the link number is still consumed so the gap does not look like a loss,
  -- and the value is parked with the owner as the account of record.
  if not validId(account) or not s.assets[asset] or amount <= 0 then
    account = s.owner
  end
  if not Custody.linkAccept(s, from, seq, asset, amount) then
    return fail(base, "That transfer number is out of range")
  end
  Custody.admit(s, Touched, account, asset, amount)
  markSupply()
  local rawThen = tag(msg, "Then")
  local continued, outbox = continueWith(account,
    rawThen and Custody.decodeOps(rawThen) or nil, int(tag(msg, "Hops"), 1))
  return reply(base, { landed = { from = from, seq = asString(seq), asset = asset,
    amount = asString(amount) }, continued = continued, account = accountView(account) },
    outbox)
end

-- Admin: the registry, and the factory's half of it ---------------------------------

local function requireOwner(base, msg, b)
  local who = Custody.provenSigner(msg)
  if not S().owner or who ~= S().owner or Custody.sourceProcess(msg, b) then
    return fail(base, "Not authorised")
  end
  return nil
end

--- List an asset. A token vault names the token process; a game vault may name
--- a denomination, which is the custody scale applied at the bridge.
H["Admin.ListAsset"] = function(base, msg, _, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  local s = S()
  if s.sealed then return fail(base, "This vault is sealed") end
  local id = tostring(tag(msg, "Asset", "Id") or "")
  if not Custody.validSlug(id) then return fail(base, "An asset id is 1-32 characters of a-z, 0-9 and _") end
  local denomination = int(tag(msg, "Denomination"), 0)
  if denomination < 0 or denomination > (s.funding == "token" and 18 or 12) then
    return fail(base, "Denomination is out of range")
  end
  local row = { id = id, name = tostring(tag(msg, "Name") or id), denomination = denomination }
  if s.funding == "token" then
    local token = tag(msg, "Process", "Token")
    if not validId(token) then return fail(base, "A token asset needs its token process") end
    local already = s.assetByProcess[token]
    if already and already ~= id then return fail(base, "That token is already listed as " .. already) end
    row.kind, row.process, row.ticker = "token", token, tostring(tag(msg, "Ticker") or "")
    s.assetByProcess[token] = id
  else
    row.kind = "game"
  end
  s.assets[id] = row
  Custody.pool(s, id)
  Dirty.info = true
  markSupply()
  return reply(base, infoView())
end

--- Freeze what backs the vault. Pairs stay registrable after sealing.
H["Admin.Seal"] = function(base, msg, _, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  S().sealed = true
  Dirty.info = true
  markState()
  return reply(base, infoView())
end

--- Every pair, told about every other. One message per pair; admin-time only.
local function announcePeers()
  local s, listed, outbox = S(), pairsView(), {}
  local encoded = encode(listed)
  for id, row in pairs(s.pairs) do
    outbox["peers-" .. id] = { target = row.process, Action = "Custody.Peers", Peers = encoded }
  end
  return outbox
end

--- Register a pair the admin spawned. THIS is where "permissioned by the admin
--- deployer" is enforced: a pair is ours because this signature said so, and
--- only then does any other pair accept value from it.
---
--- The pair's own definition already names this vault and its assets; the
--- registry repeats them so a mismatch is refused here rather than discovered
--- as a quarantined transfer later.
H["Admin.RegisterPair"] = function(base, msg, _, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  local s = S()
  local id = tostring(tag(msg, "Pair", "PairId") or "")
  local process = tag(msg, "Process")
  local baseAsset = tostring(tag(msg, "Base") or "")
  local quoteAsset = tostring(tag(msg, "Quote") or "")
  if not Custody.validSlug(id) then return fail(base, "A pair id is a slug") end
  if not validId(process) then return fail(base, "Name the pair's Process") end
  if not s.assets[baseAsset] or not s.assets[quoteAsset] or baseAsset == quoteAsset then
    return fail(base, "Both assets must be listed here, and different")
  end
  if s.pairs[id] and s.pairs[id].process ~= process then
    return fail(base, "Pair " .. id .. " is already registered to another process")
  end
  if s.pairByProcess[process] and s.pairByProcess[process] ~= id then
    return fail(base, "That process is already registered as " .. s.pairByProcess[process])
  end
  s.pairs[id] = { process = process, base = baseAsset, quote = quoteAsset }
  s.pairByProcess[process] = id
  Dirty.pairs = true
  markState()
  return reply(base, { pairs = pairsView() }, announcePeers())
end

--- Re-send the peer list, e.g. after a lost push. Changes nothing here.
H["Admin.AnnouncePeers"] = function(base, msg, _, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  StateIdle = true
  return reply(base, { pairs = pairsView() }, announcePeers())
end

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

--- Resolve a quarantined deposit by hand: credit it, or write it off.
H["Admin.SettleDeposit"] = function(base, msg, _, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  local s = S()
  local key = tostring(tag(msg, "Reference", "DepositId") or "")
  local row = s.deposits[key]
  if not row then return fail(base, "No such deposit") end
  if row.status ~= "unresolved" then return reply(base, { deposit = row, unchanged = true }) end
  if word(tag(msg, "Resolution"), "credit") == "writeoff" then
    s.deposits[key] = { status = "written-off" }
    markState()
    return reply(base, { deposit = s.deposits[key] })
  end
  local account = tag(msg, "Account") or row.account
  local asset = tostring(tag(msg, "Asset") or row.asset or "")
  local amount = int(tag(msg, "Quantity"), int(row.amount, 0))
  if not validId(account) then return fail(base, "Name the account to credit") end
  if not s.assets[asset] then return fail(base, "This vault does not list that asset") end
  if amount <= 0 then return fail(base, "Name a positive quantity") end
  Custody.admit(s, Touched, account, asset, amount)
  s.backing[asset] = int(s.backing[asset], 0) + amount
  s.deposits[key] = { status = "credited" }
  markSupply()
  local outbox = nil
  local prefix = (s.game or "") .. ":"
  if s.funding == "game" and key:sub(1, #prefix) == prefix then
    local reference = key:sub(#prefix + 1)
    outbox = { ["venue-credited"] = { target = s.game, Action = "Venue.Credited",
      Reference = reference, ["Deposit-Id"] = reference } }
  end
  return reply(base, { deposit = s.deposits[key], account = accountView(account) }, outbox)
end

--- A withdrawal whose confirmation never came: settle it, or REFUND it. A
--- refund is safe only when the payout definitely did not land, which no
--- process can see for itself -- so this is the owner's call, on evidence.
H["Admin.SettleWithdrawal"] = function(base, msg, _, b)
  local refusal = requireOwner(base, msg, b)
  if refusal then return refusal end
  local s = S()
  local id = tostring(tag(msg, "Reference", "WithdrawalId") or "")
  local w = s.withdrawals[id]
  if not w then return fail(base, "No such withdrawal") end
  if w.status ~= "pending" then return reply(base, { withdrawal = w, unchanged = true }) end
  if word(tag(msg, "Resolution"), "settle") == "refund" then
    Custody.admit(s, Touched, w.account, w.asset, int(w.amount, 0))
    s.backing[w.asset] = int(s.backing[w.asset], 0) + int(w.amount, 0)
    s.withdrawals[id] = { status = "refunded" }
    markSupply()
  else
    s.withdrawals[id] = { status = "settled" }
    markState()
  end
  return reply(base, { withdrawal = s.withdrawals[id] })
end

-- Dispatch --------------------------------------------------------------------------

local RESOLVED = nil
local function resolveHandler(action)
  if not RESOLVED then
    RESOLVED = {}
    for name, handler in pairs(H) do RESOLVED[word(name)] = handler end
  end
  return RESOLVED[word(tostring(action or ""))]
end

function VaultCompute(base, req)
  base = type(base) == "table" and base or {}
  local msg = (req and req.body) or {}
  local timestamp = int((req and (req.timestamp or req.Timestamp))
    or msg.Timestamp or msg.timestamp, 0)
  Touched, Dirty, StateIdle, ForceCheckpoint = {}, {}, false, false

  local restored, restoreProblem = Custody.restore("VaultState", base, "vaultcommit", "vaultstate")
  if not restored then return fail(base, restoreProblem) end
  local initial = base.vaultcommit == nil
  ensureState()
  local configProblem = configure(base)

  local action = tag(msg, "Action") or "none"
  local handler = resolveHandler(action)
  local result
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

  local s = S()
  if Dirty.state and not StateIdle then s.revision = int(s.revision, 0) + 1 end
  local patchMode = Lua53bPatchMode == true
  local checkpoint = initial or ForceCheckpoint
    or (Dirty.state and not StateIdle and (not patchMode or s.revision % 50 == 0))

  if initial or Dirty.info then
    result.vaultinfo = encode(infoView())
    result.paused = s.emergency.paused and "1" or "0"
  end
  -- The directory a client reads to find every pair's process.
  if initial or Dirty.pairs then result.vaultpairs = encode(pairsView()) end
  if initial or Dirty.supply then result.vaultsupply = encode(supplyView()) end
  if initial or Dirty.links then result.vaultlinks = encode(Custody.linkView(s)) end
  if checkpoint then result.vaultstate = encode(s) end
  if initial or Dirty.state or ForceCheckpoint then
    result.vaultcommit = encode({ revision = s.revision })
  end
  for address in pairs(Touched) do
    result["balance-" .. address] = encode(accountView(address))
  end

  collectgarbage("collect")
  return result
end

compute = VaultCompute
