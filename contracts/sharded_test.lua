--- sharded_test.lua -- vaults and pairs as a NETWORK, driven through `compute`.
---
--- ORDERBOOK.md §16. Both vaults, three pairs, a fake token and a fake game run
--- in one Lua VM. Each process keeps its whole state in one global
--- (`PairState`, `VaultState`), so the harness swaps that global per call --
--- Luerl ignores `load`'s environment argument, so there is no other way to
--- run several processes in one VM on a live node.
---
--- Every outbox entry is DELIVERED the way `push@1.0` delivers it: signed by
--- the scheduler, carrying `from-process`, with every tag name lowercased the
--- way HTTP lowercases headers. So each test sends exactly the spelling a real
--- process emits -- CLAUDE.md's rule, learned the expensive way.
---
--- Run with `npm run test:sharded` (a live node; free, unsigned).

local function run()
  local out = {}
  local passed, failed = 0, 0
  local function ok(label, cond, extra)
    if cond then passed = passed + 1 else failed = failed + 1 end
    out[#out + 1] = (cond and "PASS  " or "FAIL  ") .. label ..
      (extra ~= nil and ("  <- " .. tostring(extra)) or "")
  end

  local json = require(".json")
  local T = 1700000000000

  local OWNER   = "OWNERoooooooooooooooooooooooooooooooooooooo"
  local SCHED   = "SCHEDulerrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"
  local ALICE   = "ALICEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local BOB     = "BOBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local MALLORY = "MALLORYmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm"
  local RUNE    = "RUNEtokennnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn"
  local QUOTE   = "QUOTEtokennnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn"
  local GAME    = "GAMEggggggggggggggggggggggggggggggggggggggg"
  local VT      = "VAULTtokennnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn"
  local VG      = "VAULTgameeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  local PRQ     = "PAIRrunequoteeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  local PFG     = "PAIRfiregoldddddddddddddddddddddddddddddddd"
  local PSG     = "PAIRscrollgoldddddddddddddddddddddddddddddd"
  local ROGUE   = "ROGUEpairrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"

  local function num(s) return math.tointeger(tonumber(s or "0")) or 0 end
  local function sig(who) return { sig1 = { committer = who, alg = "rsa-pss-sha512" } } end

  -- The network ---------------------------------------------------------------

  local net = {}
  local deliveries = {}

  local function definition(tags)
    local def = { commitments = sig(OWNER), ["scheduler-location"] = SCHED }
    for k, v in pairs(tags) do def[k] = v end
    return def
  end

  local function addProcess(pid, kind, tags, handle)
    net[pid] = {
      pid = pid, kind = kind, handle = handle,
      base = { process = definition(tags or {}), ["scheduler-location"] = SCHED },
    }
    return net[pid]
  end

  local function call(inst, body)
    T = T + 1000
    local req = { body = body, timestamp = T }
    if inst.kind == "pair" then
      PairState = inst.state
      local res = PairCompute(inst.base, req)
      inst.state = PairState
      return res
    elseif inst.kind == "vault" then
      VaultState = inst.state
      local res = VaultCompute(inst.base, req)
      inst.state = VaultState
      return res
    end
    return inst.handle(body)
  end

  local function decoded(res)
    local data = res and res.results and res.results.output and res.results.output.data
    local okd, value = pcall(json.decode, data or "null")
    return okd and value or nil, data
  end

  --- A push delivery: the scheduler signs, `from-process` names the sender,
  --- and every tag name arrives lowercased.
  local function delivery(from, msg)
    local body = { commitments = sig(SCHED), ["from-process"] = from }
    for k, v in pairs(msg) do
      if k ~= "target" then body[string.lower(k)] = v end
    end
    return body
  end

  --- Deliver every outbox entry, and every entry those produce, in order.
  --- Returns how many messages crossed a process boundary.
  local function pump(from, res)
    local queue = {}
    local function enqueue(sender, r)
      local outbox = r and r.results and r.results.outbox
      if type(outbox) ~= "table" then return end
      local keys = {}
      for key in pairs(outbox) do keys[#keys + 1] = key end
      table.sort(keys)
      for _, key in ipairs(keys) do queue[#queue + 1] = { from = sender, msg = outbox[key] } end
    end
    enqueue(from, res)
    local i, hops = 1, 0
    while i <= #queue do
      local item = queue[i]
      i = i + 1
      local target = net[item.msg.target]
      if target then
        local r = call(target, delivery(item.from, item.msg))
        hops = hops + 1
        deliveries[#deliveries + 1] = { to = target.pid, action = item.msg.Action,
          reply = (decoded(r)) }
        enqueue(target.pid, r)
      end
    end
    return hops
  end

  --- A wallet signs a message to a process, and the network runs to rest.
  local function send(who, pid, tags, noPump)
    local body = { commitments = sig(who) }
    for k, v in pairs(tags) do body[k] = v end
    deliveries = {}
    local res = call(net[pid], body)
    local r, raw = decoded(res)
    local hops = noPump and 0 or pump(pid, res)
    return r, hops, res, raw
  end

  --- A process (fake token or game) sends to one of ours.
  local function deliverFrom(from, pid, tags)
    deliveries = {}
    local res = call(net[pid], delivery(from, tags))
    local r, raw = decoded(res)
    local hops = pump(pid, res)
    return r, hops, res, raw
  end

  local function published(pid, key)
    local value = net[pid].base[key]
    if type(value) ~= "string" then return nil end
    local okd, v = pcall(json.decode, value)
    return okd and v or nil
  end

  local function freeAt(pid, account, asset)
    local view = published(pid, "balance-" .. account)
    return num(view and view.free and view.free[asset])
  end

  local function batch(ops) return json.encode(ops) end

  -- Fake token: pays a vault's Transfer out and answers with a Debit-Notice.
  local tokenPaid = {}
  local function tokenHandle(pid)
    return function(body)
      if body.action == "Transfer" then
        tokenPaid[#tokenPaid + 1] = { token = pid, to = body.recipient, qty = body.quantity }
        return { results = { output = { data = "{}" }, outbox = { ["debit"] = {
          target = body["from-process"], Action = "Debit-Notice",
          ["X-Reference"] = body["x-reference"], Quantity = body.quantity,
        } } } }
      end
      return { results = { output = { data = "{}" } } }
    end
  end

  -- Fake game: takes a Venue.Return and acknowledges it.
  local gameReturns, gameCredited = {}, {}
  local function gameHandle(body)
    if body.action == "Venue.Return" then
      gameReturns[#gameReturns + 1] = { account = body.account, asset = body.asset,
        qty = body.quantity, ref = body.reference }
      return { results = { output = { data = "{}" }, outbox = { ["returned"] = {
        target = body["from-process"], Action = "Venue.Returned", Reference = body.reference,
      } } } }
    elseif body.action == "Venue.Credited" then
      gameCredited[#gameCredited + 1] = body.reference
    end
    return { results = { output = { data = "{}" } } }
  end

  addProcess(RUNE, "token", nil, tokenHandle(RUNE))
  addProcess(QUOTE, "token", nil, tokenHandle(QUOTE))
  addProcess(GAME, "game", nil, gameHandle)
  -- Definition tags arrive lowercased, like every other tag.
  addProcess(VT, "vault", { ["vault-funding"] = "token", ["vault-name"] = "TEST-Vault (token)" })
  addProcess(VG, "vault", { ["vault-funding"] = "game", ["vault-game"] = GAME })
  local limits = { ["pair-creationcost"] = "0", ["pair-bandbps"] = "0",
    ["pair-minvalue"] = "1", ["pair-takerbps"] = "0" }
  local function pairTags(vault, id, baseAsset, quoteAsset)
    local t = { ["pair-vault"] = vault, ["pair-id"] = id,
      ["pair-base"] = baseAsset, ["pair-quote"] = quoteAsset }
    for k, v in pairs(limits) do t[k] = v end
    return t
  end
  addProcess(PRQ, "pair", pairTags(VT, "rune_quote", "rune", "quote"))
  addProcess(PFG, "pair", pairTags(VG, "fire_berry_gold", "fire_berry", "gold"))
  addProcess(PSG, "pair", pairTags(VG, "scroll_gold", "scroll", "gold"))
  addProcess(ROGUE, "pair", pairTags(VG, "rogue_gold", "scroll", "gold"))

  -- 1. Configuration comes from the signed definition ------------------------

  local r = send(ALICE, PRQ, { Action = "Info" })
  ok("a pair reads its market off its definition",
    r and r.Base == "rune" and r.Quote == "quote" and r.Vault == VT, json.encode(r))
  ok("and opens CLOSED", r and r.Status == "closed", r and r.Status)
  ok("and its owner is the spawner", r and r.Owner == OWNER, r and r.Owner)

  addProcess("PAIRbrokennnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn", "pair",
    { ["pair-base"] = "a", ["pair-quote"] = "b" })
  r = send(ALICE, "PAIRbrokennnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn",
    { Action = "Order.Place", Side = "buy", Price = "1", Quantity = "1" })
  ok("a pair whose definition names no vault refuses to trade",
    r and r.error and r.error:find("Pair%-Vault") ~= nil, json.encode(r))

  r = send(ALICE, VT, { Action = "Info" })
  ok("a vault reads its funding off its definition", r and r.Funding == "token", json.encode(r))

  -- 2. The registry --------------------------------------------------------------

  r = send(OWNER, VT, { Action = "Admin.ListAsset", Asset = "rune", Process = RUNE, Ticker = "TEST-RUNE" })
  ok("the owner lists a token", r and r.Assets and r.Assets.rune ~= nil, json.encode(r))
  send(OWNER, VT, { Action = "Admin.ListAsset", Asset = "quote", Process = QUOTE, Ticker = "TEST-QUOTE" })
  r = send(MALLORY, VT, { Action = "Admin.ListAsset", Asset = "evil", Process = MALLORY })
  ok("a stranger cannot list an asset", r and r.error == "Not authorised", json.encode(r))

  local hops
  r, hops = send(OWNER, VT, { Action = "Admin.RegisterPair", Pair = "rune_quote",
    Process = PRQ, Base = "rune", Quote = "quote" })
  ok("registering a pair announces the peer list to it", hops == 1, hops)
  r = published(PRQ, "pairinfo")
  ok("the pair accepted the announcement from its vault",
    r and r.Peers ~= nil, json.encode(r))

  r = deliverFrom(MALLORY, PRQ, { Action = "Custody.Peers", Peers = "{}" })
  ok("only the pair's own vault may tell it who its peers are",
    r and r.error == "Not authorised", json.encode(r))

  send(OWNER, VG, { Action = "Admin.ListAsset", Asset = "gold", Denomination = "2" })
  send(OWNER, VG, { Action = "Admin.ListAsset", Asset = "fire_berry" })
  send(OWNER, VG, { Action = "Admin.ListAsset", Asset = "scroll" })
  send(OWNER, VG, { Action = "Admin.RegisterPair", Pair = "fire_berry_gold",
    Process = PFG, Base = "fire_berry", Quote = "gold" })
  r, hops = send(OWNER, VG, { Action = "Admin.RegisterPair", Pair = "scroll_gold",
    Process = PSG, Base = "scroll", Quote = "gold" })
  ok("registering a second pair re-announces to both", hops == 2, tostring(hops) .. " " .. json.encode(r))
  r = published(PFG, "pairinfo")
  ok("the first pair now knows the second", r and r.Peers and r.Peers.scroll_gold == PSG,
    json.encode(r))
  r = send(OWNER, VG, { Action = "Admin.RegisterPair", Pair = "fire_berry_gold",
    Process = ROGUE, Base = "fire_berry", Quote = "gold" })
  ok("a pair id cannot be re-pointed at another process",
    r and r.error and r.error:find("already registered") ~= nil, json.encode(r))

  -- Held in a local on purpose: `compute` ends with a full collect, and Luerl
  -- frees a table that only a for-loop's hidden iterator state refers to.
  local launch = { PRQ, PFG, PSG }
  for _, pid in ipairs(launch) do
    r = send(OWNER, pid, { Action = "Admin.Launch" })
    ok("the owner launches " .. tostring(r and r.Pair), r and r.Status == "open", json.encode(r))
  end
  r = send(MALLORY, PFG, { Action = "Admin.Launch" })
  ok("a stranger cannot launch a pair", r and r.error == "Not authorised", json.encode(r))

  -- 3. Token funding -----------------------------------------------------------

  r = deliverFrom(RUNE, VT, { Action = "Credit-Notice", Sender = ALICE, Quantity = "1000",
    Reference = "dep-1" })
  ok("a token deposit credits the vault", freeAt(VT, ALICE, "rune") == 1000,
    freeAt(VT, ALICE, "rune"))
  r = deliverFrom(RUNE, VT, { Action = "Credit-Notice", Sender = ALICE, Quantity = "1000",
    Reference = "dep-1" })
  ok("the same notice twice credits once", r and r.unchanged == true
    and freeAt(VT, ALICE, "rune") == 1000, json.encode(r))

  local forged = { commitments = sig(MALLORY), ["from-process"] = RUNE,
    action = "Credit-Notice", sender = MALLORY, quantity = "999999", reference = "x" }
  r = decoded(call(net[VT], forged))
  ok("a wallet claiming to be the token credits nothing",
    r and r.error == "Not authorised", json.encode(r))

  r = deliverFrom(QUOTE, VG, { Action = "Credit-Notice", Sender = MALLORY, Quantity = "5",
    Reference = "q" })
  ok("a game vault has no token deposit verb", r and r.error == "This is a game vault",
    json.encode(r))

  -- Deposit and allocate in ONE message from the depositor's side.
  r, hops = deliverFrom(QUOTE, VT, { Action = "Credit-Notice", Sender = BOB,
    Quantity = "5000", Reference = "dep-2", ["X-Pair"] = "rune_quote" })
  ok("a deposit naming a pair goes straight on to it", hops == 1
    and freeAt(PRQ, BOB, "quote") == 5000 and freeAt(VT, BOB, "quote") == 0,
    tostring(hops) .. " " .. freeAt(PRQ, BOB, "quote"))

  local s = published(VT, "vaultsupply")
  ok("the vault balances: backing = free + allocated",
    s and s.quote and s.quote.balanced == true and num(s.quote.allocated) == 5000,
    json.encode(s and s.quote))

  -- 4. Trading on a pair --------------------------------------------------------

  r, hops = send(ALICE, VT, { Action = "Move", Asset = "rune", Quantity = "600", To = "rune_quote" })
  ok("allocating to a pair is one hop", hops == 1 and freeAt(PRQ, ALICE, "rune") == 600, hops)

  r = send(ALICE, PRQ, { Action = "Order.Place", Side = "sell", Price = "5", Quantity = "100" })
  local askId = r and r.results and r.results[1] and r.results[1].result
    and r.results[1].result.order and r.results[1].result.order.id
  ok("a sell rests on the pair", askId ~= nil, json.encode(r))
  r = send(BOB, PRQ, { Action = "Order.Place", Side = "buy", Price = "5", Quantity = "40" })
  ok("a buy crosses it", freeAt(PRQ, BOB, "rune") == 40 and freeAt(PRQ, BOB, "quote") == 4800,
    freeAt(PRQ, BOB, "rune") .. " " .. freeAt(PRQ, BOB, "quote"))
  ok("the maker is paid without sending anything", freeAt(PRQ, ALICE, "quote") == 200,
    freeAt(PRQ, ALICE, "quote"))

  -- 5. All or nothing -------------------------------------------------------------

  local before = net[PRQ].base["balance-" .. BOB]
  local revBefore = num(published(PRQ, "paircommit").revision)
  r = send(BOB, PRQ, { Action = "Batch", Data = batch({
    { op = "place", side = "buy", price = "4", quantity = "10" },
    { op = "place", side = "buy", price = "4", quantity = "999999" },
  }) })
  ok("a batch with one bad step is refused, naming the step",
    r and r.error and r.error:find("Step 2") ~= nil, json.encode(r))
  local after = send(BOB, PRQ, { Action = "Balance" })
  ok("and the good step before it did not happen",
    after and (after.orders == nil or #after.orders == 0) and num(after.free.quote) == 4800,
    json.encode(after))
  ok("nothing was republished for it", net[PRQ].base["balance-" .. BOB] == before)
  ok("the revision did not move for it", num(published(PRQ, "paircommit").revision) == revBefore)

  -- Cancels run first, whatever order they were written in.
  r = send(ALICE, PRQ, { Action = "Batch", Data = batch({
    { op = "place", side = "sell", price = "6", quantity = "60" },
    { op = "cancel", order = askId },
  }) })
  ok("a batch runs its cancels first", r and r.results and r.results[1].op == "cancel"
    and r.results[2].op == "place", json.encode(r and r.results))

  r = send(ALICE, PRQ, { Action = "Batch", ActionId = "a-1", Data = batch({
    { op = "place", side = "sell", price = "7", quantity = "10" } }) })
  local r2 = send(ALICE, PRQ, { Action = "Batch", ActionId = "a-1", Data = batch({
    { op = "place", side = "sell", price = "7", quantity = "10" } }) })
  local mine = send(ALICE, PRQ, { Action = "Balance" })
  ok("a retried ActionId answers the first result and does nothing twice",
    r2 and r2.replayed == true and mine and #mine.orders == 2, json.encode(mine and mine.orders))

  -- 6. Game funding, with a custody scale ---------------------------------------

  r, hops = deliverFrom(GAME, VG, { Action = "Venue.Credit", Account = ALICE, PlayerId = ALICE,
    Asset = "gold", Item = "gold", Quantity = "50", Reference = "v1", ["Deposit-Id"] = "v1" })
  ok("a game credit lands scaled by the denomination", freeAt(VG, ALICE, "gold") == 5000,
    freeAt(VG, ALICE, "gold"))
  ok("and is acknowledged to the game in the same slot",
    hops == 1 and gameCredited[#gameCredited] == "v1", hops)
  r = deliverFrom(GAME, VG, { Action = "Venue.Credit", Account = ALICE, Asset = "gold",
    Quantity = "50", Reference = "v1" })
  ok("a repeated game credit is neither credited nor acknowledged again",
    r and r.unchanged == true and freeAt(VG, ALICE, "gold") == 5000 and #gameCredited == 1,
    json.encode(r))
  deliverFrom(GAME, VG, { Action = "Venue.Credit", Account = BOB, Asset = "fire_berry",
    Quantity = "30", Reference = "v2" })
  r = deliverFrom(RUNE, VG, { Action = "Venue.Credit", Account = BOB, Asset = "gold",
    Quantity = "1", Reference = "v3" })
  ok("only the game may credit a game vault", r and r.error == "Not authorised", json.encode(r))
  r = deliverFrom(GAME, VT, { Action = "Venue.Credit", Account = BOB, Asset = "rune",
    Quantity = "1", Reference = "v9" })
  ok("a token vault has no game credit verb", r and r.error == "This is a token vault",
    json.encode(r))

  -- 7. One signature across pairs ---------------------------------------------------

  send(ALICE, VG, { Action = "Move", Asset = "gold", Quantity = "3000", To = "fire_berry_gold" })
  send(BOB, VG, { Action = "Move", Asset = "fire_berry", Quantity = "30", To = "fire_berry_gold" })
  r = send(ALICE, PFG, { Action = "Order.Place", Side = "buy", Price = "100", Quantity = "20" })
  local bidId = r and r.results and r.results[1].result.order and r.results[1].result.order.id
  ok("Alice rests a berry bid holding 2000 centigold", bidId ~= nil
    and freeAt(PFG, ALICE, "gold") == 1000, json.encode(r))

  -- Bob sells a scroll on the other pair so Alice has something to buy there.
  deliverFrom(GAME, VG, { Action = "Venue.Credit", Account = BOB, Asset = "scroll",
    Quantity = "2", Reference = "v4" })
  send(BOB, VG, { Action = "Move", Asset = "scroll", Quantity = "2", To = "scroll_gold" })
  send(BOB, PSG, { Action = "Order.Place", Side = "sell", Price = "1500", Quantity = "2" })

  -- THE case: cancel here, move everything freed, buy there. One signature.
  r, hops = send(ALICE, PFG, { Action = "Batch", Data = batch({
    { op = "move", asset = "gold", quantity = "all", to = "scroll_gold",
      ["then"] = { { op = "place", side = "buy", price = "1500", quantity = "2" } } },
    { op = "cancel", order = bidId },
  }) })
  ok("cancel + move + buy on another pair is one signature and ONE hop",
    r and r.results and #r.results == 2 and hops == 1, tostring(hops) .. " " .. json.encode(r))
  ok("the cancel ran first, so 'all' moved the released escrow too",
    freeAt(PFG, ALICE, "gold") == 0, freeAt(PFG, ALICE, "gold"))
  ok("and the buy filled on the other pair", freeAt(PSG, ALICE, "scroll") == 2
    and freeAt(PSG, ALICE, "gold") == 0 and freeAt(PSG, BOB, "gold") == 3000,
    freeAt(PSG, ALICE, "scroll") .. " " .. freeAt(PSG, ALICE, "gold"))

  -- A continuation that cannot run leaves the value where it landed.
  send(ALICE, VG, { Action = "Move", Asset = "gold", Quantity = "1000", To = "fire_berry_gold" })
  r, hops = send(ALICE, PFG, { Action = "Batch", Data = batch({
    { op = "move", asset = "gold", quantity = "1000", to = "scroll_gold",
      ["then"] = { { op = "place", side = "buy", price = "1500", quantity = "9" } } },
  }) })
  local landed = deliveries[1] and deliveries[1].reply and deliveries[1].reply.landed
  ok("a refused continuation says so", landed and landed.thenRefused ~= nil,
    json.encode(deliveries[1] and deliveries[1].reply))
  ok("and the value stays free where it landed", freeAt(PSG, ALICE, "gold") == 1000,
    freeAt(PSG, ALICE, "gold"))

  r = send(ALICE, PFG, { Action = "Move", Asset = "gold", Quantity = "1", To = "rune_quote" })
  ok("a move to a pair outside the ring is refused before anything leaves",
    r and r.error and r.error:find("No such pair") ~= nil, json.encode(r))
  r = send(ALICE, PSG, { Action = "Move", Asset = "scroll", Quantity = "1", To = "fire_berry_gold" })
  ok("a move of an asset the destination does not trade is refused",
    r and r.error and r.error:find("does not trade") ~= nil, json.encode(r))

  -- 8. Exactly-once on the links ----------------------------------------------------

  -- PFG has really sent PSG two transfers by now; replay the first one.
  r = deliverFrom(PFG, PSG, { Action = "Custody.Transfer", Seq = "1", Account = MALLORY,
    Asset = "gold", Quantity = "1000000" })
  ok("a link number that already landed is recognised and ignored",
    r and r.unchanged == true and freeAt(PSG, MALLORY, "gold") == 0, json.encode(r))

  -- Two real moves, delivered in the reverse of the order they were sent.
  local function outboxOf(res)
    local copied = {}
    for k, v in pairs(res.results.outbox or {}) do copied[k] = v end
    return { results = { outbox = copied } }
  end
  local startGold = freeAt(PFG, ALICE, "gold")
  local _, _, first = send(ALICE, PSG, { Action = "Move", Asset = "gold", Quantity = "3",
    To = "fire_berry_gold" }, true)
  first = outboxOf(first)
  local _, _, second = send(ALICE, PSG, { Action = "Move", Asset = "gold", Quantity = "7",
    To = "fire_berry_gold" }, true)
  second = outboxOf(second)
  pump(PSG, second)
  local midway = published(PFG, "pairlinks")[PSG]
  ok("a number that arrives early is credited at once and held above the watermark",
    freeAt(PFG, ALICE, "gold") == startGold + 7 and num(midway.ahead) == 1,
    json.encode(midway))
  pump(PSG, first)
  local inbound = published(PFG, "pairlinks")[PSG]
  ok("the late one lands and the watermark closes over both",
    freeAt(PFG, ALICE, "gold") == startGold + 10 and num(inbound.mark) == 2
      and num(inbound.ahead) == 0, json.encode(inbound))
  pump(PSG, first)
  ok("a redelivered move credits nothing", freeAt(PFG, ALICE, "gold") == startGold + 10,
    freeAt(PFG, ALICE, "gold"))

  r = deliverFrom(ROGUE, PFG, { Action = "Custody.Transfer", Seq = "1", Account = MALLORY,
    Asset = "gold", Quantity = "500" })
  ok("value from a process nobody registered is quarantined, not credited",
    r and r.quarantined ~= nil and freeAt(PFG, MALLORY, "gold") == 0, json.encode(r))

  -- 9. Out through the vault, in one signature ----------------------------------------

  r, hops = send(BOB, PRQ, { Action = "Withdraw", Asset = "rune", Quantity = "40" })
  ok("withdrawing from a pair is pair -> vault -> token -> vault",
    hops == 3 and tokenPaid[#tokenPaid].to == BOB and tokenPaid[#tokenPaid].qty == "40",
    hops)
  s = published(VT, "vaultsupply")
  ok("the payout left the vault's backing and it still balances",
    s and s.rune and num(s.rune.backing) == 960 and s.rune.balanced == true,
    json.encode(s and s.rune))
  local w = published(VT, "vaultstate").withdrawals.w1
  ok("and the token's Debit-Notice settled the withdrawal", w and w.status == "settled",
    json.encode(w))

  local atVault = freeAt(VG, ALICE, "gold")
  r = send(ALICE, PSG, { Action = "Withdraw", Asset = "gold", Quantity = "100" })
  local lastReturn = gameReturns[#gameReturns]
  ok("a game withdrawal returns whole units to the game",
    lastReturn and lastReturn.qty == "1" and lastReturn.asset == "gold"
      and freeAt(VG, ALICE, "gold") == atVault, json.encode(lastReturn))
  s = published(VG, "vaultsupply")
  ok("the game vault balances", s and s.gold and s.gold.balanced == true, json.encode(s and s.gold))

  local returnsBefore = #gameReturns
  send(ALICE, PSG, { Action = "Withdraw", Asset = "gold", Quantity = "50" })
  ok("a fraction the game cannot take back stays at the vault, not lost",
    #gameReturns == returnsBefore and freeAt(VG, ALICE, "gold") == atVault + 50,
    freeAt(VG, ALICE, "gold"))

  -- 10. Bounds ----------------------------------------------------------------------

  local deep = { { op = "place", side = "buy", price = "1", quantity = "1" } }
  for _ = 1, 5 do
    deep = { { op = "move", asset = "gold", quantity = "1", to = "fire_berry_gold",
      ["then"] = { { op = "move", asset = "gold", quantity = "1", to = "scroll_gold",
        ["then"] = deep } } } }
  end
  send(ALICE, PSG, { Action = "Batch", Data = batch(deep) })
  local refusedHop = false
  for _, d in ipairs(deliveries) do
    local l = d.reply and d.reply.landed
    if l and l.thenRefused and l.thenRefused:find("at most") then refusedHop = true end
  end
  ok("a chain cannot bounce between pairs forever", refusedHop, #deliveries)

  local many = {}
  for i = 1, 17 do many[i] = { op = "cancelall" } end
  r = send(ALICE, PSG, { Action = "Batch", Data = batch(many) })
  ok("a batch is at most sixteen steps", r and r.error and r.error:find("at most") ~= nil,
    json.encode(r))

  -- The whole ring reconciles: every pair's holdings are the vault's allocation.
  local function held(pid, asset)
    local row = (published(pid, "pairsupply") or {})[asset]
    return row and (num(row.held) + num(row.fees)) or 0
  end
  local allocated = num(published(VG, "vaultsupply").gold.allocated)
  local ring = held(PFG, "gold") + held(PSG, "gold")
  ok("sum of what the pairs hold = what the vault allocated (nothing in flight)",
    ring == allocated and allocated > 0, ring .. " vs " .. allocated)

  -- 11. Integers, in the raw text ---------------------------------------------------

  local raw = net[PSG].base.pairsupply .. net[VG].base.vaultsupply .. net[PFG].base.pairlinks
  ok("published custody numbers carry no float", raw:find("%d%.%d") == nil, raw)

  -- 12. A cold slot restores from its checkpoint ------------------------------------

  local keep = freeAt(PSG, ALICE, "scroll")
  net[PSG].state = nil
  r = send(ALICE, PSG, { Action = "Balance" })
  ok("a pair that lost its globals restores its balances from the checkpoint",
    r and num(r.free and r.free.scroll) == keep and keep == 2, json.encode(r))
  local vaultGold = freeAt(VG, ALICE, "gold")
  net[VG].state = nil
  r = send(ALICE, VG, { Action = "Balance" })
  ok("so does a vault", r and num(r.free and r.free.gold) == vaultGold and vaultGold > 0,
    json.encode(r))

  out[#out + 1] = ""
  out[#out + 1] = string.format("%d passed, %d failed", passed, failed)
  return table.concat(out, "\n")
end

--- The live node calls the global this path segment names; the offline runner
--- calls what the chunk returns. Both must work.
function shardedtest()
  return run()
end

return run
