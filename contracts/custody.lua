--- custody.lua -- what a pair process and a vault process both have to get right.
---
--- ORDERBOOK.md §16. The sharded venue is two kinds of process:
---
---   * a PAIR holds one market and the free balances traded on it;
---   * a VAULT holds everything that has not been allocated to a pair, is the
---     only process that talks to the outside (a token, or the game), and keeps
---     the registry of pairs -- the factory's half of the job.
---
--- Both are custody, so both need the same identity rules, the same exactly-once
--- transfer protocol between them, and the same all-or-nothing batch. That is
--- this module. It holds NO state of its own: every function takes the state
--- table it works on, because a test runs several processes in one Lua VM by
--- swapping that table, and a module-level cache would leak between them.
---
--- Luerl-safe: no goto, no table.move, narrow every number through `int`.

local json = require(".json")

local M = {}

-- Numbers ----------------------------------------------------------------------

--- Luerl's `tonumber` returns a float and every tag arrives as a string, so an
--- unnarrowed conversion turns 25 into 25.0 and stores it that way forever.
function M.int(v, default)
  local narrowed = math.tointeger(tonumber(v))
  if narrowed == nil then return default or 0 end
  return narrowed
end
local int = M.int

function M.asString(n) return string.format("%d", int(n, 0)) end

--- A quantity that is safe to move: positive, whole, and nothing else.
function M.quantity(v)
  if v == nil or v == "" then return nil, "Quantity is required" end
  local n = tonumber(v)
  if not n then return nil, "Quantity must be a number" end
  if n ~= math.floor(n) then return nil, "Quantity must be a whole atomic amount" end
  n = math.tointeger(n)
  if not n then return nil, "Quantity is out of range" end
  if n <= 0 then return nil, "Quantity must be positive" end
  return n
end

local ADDRESS = "^[A-Za-z0-9_-]+$"
function M.validId(v)
  return type(v) == "string" and #v == 43 and v:match(ADDRESS) ~= nil
end
local validId = M.validId

--- An asset or pair id: a slug we chose, never an address.
function M.validSlug(v)
  return type(v) == "string" and #v >= 1 and #v <= 32
    and v:match("^[a-z0-9_]+$") ~= nil
end

-- Tags -------------------------------------------------------------------------

--- Separators do not survive the trip (CLAUDE.md): strip them before comparing.
function M.word(value, fallback)
  if type(value) ~= "string" then return fallback end
  local plain = string.gsub(string.lower(value), "[%-%_%s]", "")
  if plain == "" then return fallback end
  return plain
end
local word = M.word

--- A tag by any of its spellings.
function M.tag(msg, ...)
  for _, name in ipairs({ ... }) do
    local want = word(name)
    for key, value in pairs(msg) do
      if word(tostring(key)) == want and value ~= nil and value ~= "" then
        return value
      end
    end
  end
  return nil
end
local tag = M.tag

-- Identity ---------------------------------------------------------------------

--- Only a real signature names anybody, read from `type` OR `alg` (a live node
--- writes one, the harness the other). Two different signature committers
--- identify nobody. Same rule, same reasons, as `venue.lua` and `game.lua`.
local SIGNATURE_ALGS = { ["rsa-pss-sha512"] = true, ["rsa-pss-sha256"] = true }

function M.provenSigner(msg)
  local c = msg.commitments or msg.Commitments
  if type(c) ~= "table" then
    -- In-process harness only; a scheduler will not accept such a message.
    return msg.Address or msg.From
  end
  local found = nil
  for _, commitment in pairs(c) do
    if type(commitment) == "table" and commitment.committer
       and SIGNATURE_ALGS[commitment.type or commitment.alg] then
      if found and found ~= commitment.committer then return nil end
      found = commitment.committer
    end
  end
  return found
end
local provenSigner = M.provenSigner

local function schedulerAddress(base)
  if type(base) ~= "table" then return nil end
  local found = base["scheduler-location"] or base.SchedulerLocation
    or base["scheduler_location"]
  if validId(found) then return found end
  local p = base.process or base.Process
  if type(p) == "table" then
    local nested = p["scheduler-location"] or p.SchedulerLocation
      or p["scheduler_location"]
    if validId(nested) then return nested end
  end
  return nil
end

--- The PROCESS a message came from, believed only when this process's own
--- scheduler signed the delivery. See `venue.lua` for the full argument.
function M.sourceProcess(msg, base)
  local signed = provenSigner(msg)
  local fromProcess = msg["from-process"] or msg.FromProcess
  local commitments = msg.commitments or msg.Commitments
  local hasCommitments = type(commitments) == "table" and next(commitments) ~= nil
  if not signed then
    if hasCommitments then return nil end
    return fromProcess
  end
  local scheduler = schedulerAddress(base)
  if fromProcess and scheduler and signed == scheduler then return fromProcess end
  return nil
end
local sourceProcess = M.sourceProcess

--- The wallet acting. A process delivery is never a wallet action.
function M.actor(msg, base)
  if sourceProcess(msg, base) then return nil end
  return provenSigner(msg)
end

--- The spawner, read off the process definition's own signature commitment.
--- No fallback to "the first wallet that spoke": on custody that would mean
--- whoever got there first owns the money.
function M.spawner(base)
  local p = base and (base.process or base.Process)
  if type(p) ~= "table" then return nil end
  local c = p.commitments or p.Commitments
  if type(c) ~= "table" then return nil end
  for _, commitment in pairs(c) do
    if type(commitment) == "table" and commitment.committer
       and SIGNATURE_ALGS[commitment.type or commitment.alg] then
      return commitment.committer
    end
  end
  return nil
end

--- A tag on the process DEFINITION. The definition is signed by the spawner,
--- so what it says is exactly as trustworthy as the owner -- which is how a
--- factory-spawned pair learns its vault and market without an admin message.
function M.definitionTag(base, ...)
  local p = base and (base.process or base.Process)
  if type(p) ~= "table" then return nil end
  return tag(p, ...)
end

-- Replies ----------------------------------------------------------------------

function M.reply(base, value, outbox)
  base.results = {
    output = { data = type(value) == "string" and value or encode(value) },
    outbox = outbox,
  }
  return base
end

function M.fail(base, message)
  base.results = { output = { data = encode({ error = message }) } }
  return base
end

-- Tables -----------------------------------------------------------------------

function M.copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, child in pairs(value) do out[key] = M.copy(child) end
  return out
end

function M.decodedTable(value)
  if type(value) == "table" then return value end
  if type(value) ~= "string" or value == "" or value == "null" then return nil end
  local ok, decoded = pcall(json.decode, value)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

--- json decodes every number as a float; custody may only hold integers.
function M.narrowNumbers(value)
  if type(value) == "number" then return math.tointeger(value) or value end
  if type(value) ~= "table" then return value end
  for key, child in pairs(value) do value[key] = M.narrowNumbers(child) end
  return value
end

-- The ledger -------------------------------------------------------------------
--
-- `state.ledger` is account -> asset -> FREE balance, and `state.pools` is
-- asset -> { player, escrow, locked }: the same shape `orderbook.lua` moves
-- value between. An account with nothing is DELETED, so the ledger is the list
-- of people who hold something rather than everyone who ever did.

function M.pool(state, asset)
  state.pools = type(state.pools) == "table" and state.pools or {}
  local row = state.pools[asset]
  if not row then
    row = { player = 0, escrow = 0, locked = 0 }
    state.pools[asset] = row
  end
  return row
end

function M.balanceOf(state, account, asset)
  local held = state.ledger[account]
  return int(held and held[asset], 0)
end

--- Move an account's free balance. `touched` collects every address whose
--- balance moved, which is exactly the set whose published key is rewritten.
function M.creditFree(state, touched, account, asset, amount)
  amount = int(amount, 0)
  if amount == 0 then return end
  if validId(account) and touched then touched[account] = true end
  local held = state.ledger[account]
  if not held then
    held = {}
    state.ledger[account] = held
  end
  local after = int(held[asset], 0) + amount
  if after > 0 then held[asset] = after else held[asset] = nil end
  if next(held) == nil then state.ledger[account] = nil end
end

function M.debitFree(state, touched, account, asset, amount)
  amount = int(amount, 0)
  if amount <= 0 then return true end
  if M.balanceOf(state, account, asset) < amount then return false end
  M.creditFree(state, touched, account, asset, -amount)
  return true
end

--- Value ENTERING this process's custody: free balance and the pool together.
function M.admit(state, touched, account, asset, amount)
  M.creditFree(state, touched, account, asset, amount)
  local row = M.pool(state, asset)
  row.player = int(row.player, 0) + int(amount, 0)
end

--- Value LEAVING this process's custody. False, and nothing moved, when short.
function M.release(state, touched, account, asset, amount)
  if not M.debitFree(state, touched, account, asset, amount) then return false end
  local row = M.pool(state, asset)
  row.player = math.max(0, int(row.player, 0) - int(amount, 0))
  return true
end

-- Links: exactly-once value between our own processes --------------------------
--
-- Every pair of processes that move value to each other share a LINK, and each
-- direction of it is a sequence. The sender numbers every transfer 1, 2, 3...
-- and keeps cumulative totals per asset; the receiver credits a number once,
-- keeps a watermark (every number at or below it has landed) plus the few
-- numbers above it that arrived early, and keeps its own cumulative totals.
--
-- That replaces a reference ledger that can never be trimmed and an
-- acknowledgement message per transfer:
--
--   * a duplicate is `seq <= mark` or already in `ahead` -- O(1) to recognise;
--   * the guard's size is O(links) plus whatever is out of order right now,
--     not O(transfers ever);
--   * value in flight is `sender.sent - receiver.received`, per asset, read
--     from the two processes' published state. No message has to say it.
--
-- Credits commute, so the receiver applies a transfer the moment it arrives
-- whatever its number; ordering only matters to the watermark.
--
-- A transfer that never arrives is healed by pushing the SENDER's slot again,
-- never by refunding: its outbox is part of that slot's result, and a late
-- delivery after a refund would pay twice.

local AHEAD_LIMIT = 256

local function link(state, process)
  state.links = type(state.links) == "table" and state.links or {}
  local row = state.links[process]
  if not row then
    row = { seq = 0, sent = {}, mark = 0, ahead = {}, received = {} }
    state.links[process] = row
  end
  row.sent = type(row.sent) == "table" and row.sent or {}
  row.ahead = type(row.ahead) == "table" and row.ahead or {}
  row.received = type(row.received) == "table" and row.received or {}
  return row
end
M.link = link

--- Number the next outgoing transfer on a link and count it as sent.
function M.linkSend(state, process, asset, amount)
  local row = link(state, process)
  row.seq = int(row.seq, 0) + 1
  row.sent[asset] = int(row.sent[asset], 0) + int(amount, 0)
  return row.seq
end

--- Has this incoming number already landed?
function M.linkSeen(state, process, seq)
  local row = link(state, process)
  seq = int(seq, 0)
  if seq <= int(row.mark, 0) then return true end
  return row.ahead[M.asString(seq)] == true
end

--- Record an incoming number as landed. False when it cannot be recorded --
--- a number more than AHEAD_LIMIT beyond the watermark, which only a sender
--- that skipped numbers could produce -- and then NOTHING may be credited.
function M.linkAccept(state, process, seq, asset, amount)
  local row = link(state, process)
  seq = int(seq, 0)
  local mark = int(row.mark, 0)
  if seq <= mark or seq > mark + AHEAD_LIMIT then return false end
  local key = M.asString(seq)
  if row.ahead[key] then return false end
  row.ahead[key] = true
  while row.ahead[M.asString(mark + 1)] do
    row.ahead[M.asString(mark + 1)] = nil
    mark = mark + 1
  end
  row.mark = mark
  row.received[asset] = int(row.received[asset], 0) + int(amount, 0)
  return true
end

--- The published form: integers as strings, `ahead` as a count.
function M.linkView(state)
  local out = {}
  for process, row in pairs(state.links or {}) do
    local sent, received = {}, {}
    for asset, n in pairs(row.sent or {}) do sent[asset] = M.asString(n) end
    for asset, n in pairs(row.received or {}) do received[asset] = M.asString(n) end
    local ahead = 0
    for _ in pairs(row.ahead or {}) do ahead = ahead + 1 end
    out[process] = {
      seq = M.asString(row.seq), mark = M.asString(row.mark),
      ahead = M.asString(ahead), sent = sent, received = received,
    }
  end
  return out
end

--- The one message that carries value between our own processes.
---
--- `Then` is the rest of the trader's batch, to be run by the receiver as that
--- trader once the value has landed. `Hops` counts how far the chain has come,
--- so no batch can bounce value round the ring forever.
function M.transferMessage(target, seq, account, asset, amount, thenOps, hops)
  local out = {
    target = target, Action = "Custody.Transfer",
    Seq = M.asString(seq), Account = account, PlayerId = account,
    Asset = asset, Quantity = M.asString(amount),
    Hops = M.asString(hops or 1),
  }
  if type(thenOps) == "table" and #thenOps > 0 then out.Then = encode(thenOps) end
  return out
end

-- Batches ----------------------------------------------------------------------

M.MAX_OPS = 16
M.MAX_HOPS = 4

--- A batch's steps, from `Data` or an `Ops` tag, as a JSON array of objects.
function M.decodeOps(value)
  if type(value) == "table" then return value end
  if type(value) ~= "string" or value == "" then return nil, "A batch needs its steps" end
  local ok, decoded = pcall(json.decode, value)
  if not ok or type(decoded) ~= "table" then return nil, "Batch steps are not a JSON list" end
  return decoded
end

--- Validate and ORDER a batch. Cancels run first, everything else in the order
--- given -- the same rule Hyperliquid applies inside a block (non-order actions,
--- then cancels, then orders), narrowed to what one trader's batch can express:
--- a batch that closes and reopens can never trade against its own stale order.
function M.orderOps(ops, known)
  if type(ops) ~= "table" or #ops == 0 then return nil, "A batch needs at least one step" end
  if #ops > M.MAX_OPS then
    return nil, "A batch is at most " .. M.asString(M.MAX_OPS) .. " steps"
  end
  local cancels, rest = {}, {}
  for i, op in ipairs(ops) do
    if type(op) ~= "table" then return nil, "Step " .. M.asString(i) .. " is not an object" end
    local kind = word(op.op or op.Op or op.action)
    if not kind or not known[kind] then
      return nil, "Step " .. M.asString(i) .. " is not a known step: " .. tostring(op.op)
    end
    op.op = kind
    op.index = i
    if kind == "cancel" or kind == "cancelall" then
      cancels[#cancels + 1] = op
    else
      rest[#rest + 1] = op
    end
  end
  for _, op in ipairs(rest) do cancels[#cancels + 1] = op end
  return cancels
end

--- Run a batch all-or-nothing against the global named `stateName`.
---
--- Each step either succeeds or names why it could not, and on the first
--- refusal the whole state table is put back exactly as it was: no balance, no
--- order, no link number and no receipt from the steps before it survives. The
--- copy is the price of that, and it is paid only when there is more than one
--- step to undo -- a single step is already atomic in `orderbook.lua`.
---
--- `step(op, outbox)` returns a result or nil, problem. It may add outgoing
--- messages to `outbox`; they are discarded with everything else on refusal.
---
--- On refusal the third return says whether the state was put back, so the
--- caller knows there is nothing to publish.
function M.runAtomic(stateName, ops, step)
  local snapshot = #ops > 1 and M.copy(_G[stateName]) or nil
  local results, outbox = {}, {}
  for _, op in ipairs(ops) do
    local ok, result, problem = pcall(step, op, outbox)
    if not ok then result, problem = nil, tostring(result) end
    if result == nil then
      if snapshot then _G[stateName] = snapshot end
      return nil, "Step " .. M.asString(op.index) .. " (" .. tostring(op.op) .. "): "
        .. tostring(problem or "refused"), snapshot ~= nil
    end
    results[#results + 1] = { step = op.index, op = op.op, result = result }
  end
  return results, nil, nil, outbox
end

-- Receipts ---------------------------------------------------------------------
--
-- A signed batch carries an `ActionId`; a retry of the same id answers the
-- first result instead of doing it twice. Bounded at insertion: a TTL and a
-- hard cap, oldest first.

local RECEIPT_TTL = 24 * 3600 * 1000
local RECEIPT_LIMIT = 500

function M.receipt(state, account, actionId)
  if type(actionId) ~= "string" or actionId == "" then return nil end
  local rows = state.receipts or {}
  return rows[account .. ":" .. actionId]
end

function M.remember(state, account, actionId, timestamp, summary)
  if type(actionId) ~= "string" or actionId == "" then return end
  if #actionId > 64 then return end
  state.receipts = type(state.receipts) == "table" and state.receipts or {}
  state.receiptOrder = type(state.receiptOrder) == "table" and state.receiptOrder or {}
  local key = account .. ":" .. actionId
  if state.receipts[key] == nil then
    state.receiptOrder[#state.receiptOrder + 1] = key
  end
  state.receipts[key] = { at = int(timestamp, 0), summary = summary }
  local order = state.receiptOrder
  local drop = 0
  for i = 1, #order do
    local row = state.receipts[order[i]]
    local stale = row == nil or int(row.at, 0) < int(timestamp, 0) - RECEIPT_TTL
    if stale or (#order - drop) > RECEIPT_LIMIT then
      state.receipts[order[i]] = nil
      drop = i
    else
      break
    end
  end
  if drop > 0 then
    local kept = {}
    for i = drop + 1, #order do kept[#kept + 1] = order[i] end
    state.receiptOrder = kept
  end
end

-- Checkpoints ------------------------------------------------------------------
--
-- HyperBEAM can lose a process's Luerl globals while its published map
-- survives, and custody cannot tolerate waking up empty. Each process keeps ALL
-- of its state in one global table so a checkpoint is one encode, and publishes
-- a small commit (the revision) on every write. A cold slot restores from the
-- checkpoint only when it is at least as new as the commit; otherwise it
-- refuses, because acting on stale custody pays somebody twice.

function M.restore(stateName, base, commitKey, stateKey)
  local meta = M.decodedTable(base and base[commitKey])
  if not meta then return true end
  local live = _G[stateName]
  local published = int(meta.revision, 0)
  if type(live) == "table" and int(live.revision, 0) >= published then return true end
  local saved = M.decodedTable(base[stateKey])
  if not saved then return nil, "Checkpoint is missing" end
  saved = M.narrowNumbers(saved)
  if int(saved.revision, 0) < published then
    return nil, "Checkpoint is stale: revision " .. M.asString(saved.revision)
      .. " is behind " .. M.asString(published)
  end
  _G[stateName] = saved
  return true
end

return M
