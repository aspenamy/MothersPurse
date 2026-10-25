-------------------------------------------------------------------------------
-- BetterBags support
--
-- BetterBags has no plugin API for any of this, so Mother's Purse reaches into its
-- internals, which can change with any BetterBags update. Everything here
-- runs behind the safety switch in Hookups.lua.
--
-- Drawing: BetterBags draws each item on a "decoration" frame that sits just
-- under an invisible click button, and announces every draw with an
-- item/Updated message. The marks are drawn on the decoration, lifted above
-- the click button so they show.
--
-- Merged stacks: BetterBags can show several identical items as one button.
-- Gear is marked per copy, so marking that button marks every copy in it.
--
-- Selling: every sale BetterBags makes (Auto Sell, its vendor dock, selling a
-- category) checks each item with Seller:StillThere just before selling it,
-- and its automation lists what it would sell or destroy with a
-- BlockedReason. Mother's Purse adds favorites to both, so BetterBags never
-- sells or destroys one and says why in its own window. Going the other way,
-- junk marked in Mother's Purse is sold through BetterBags' seller, which
-- paces sales so the vendor doesn't answer "That object is busy."
-------------------------------------------------------------------------------

local _, ns = ...

local hookup = ns.NewHookup("betterbags", "BetterBags",
  "BetterBags can sell your favorites and won't show marks")

ns.On("Loaded", function()
  local AceAddon = LibStub and LibStub("AceAddon-3.0", true)
  local addon = AceAddon and AceAddon:GetAddon("BetterBags", true)
  if not (addon and hookup:Start("BetterBags")) then return end

  local painted = setmetatable({}, { __mode = "k" })   -- decorations seen so far

  local function Module(name)
    local found, module = pcall(addon.GetModule, addon, name, true)
    return found and module or nil
  end
  local events, items, database = Module("Events"), Module("Items"), Module("Database")
  local seller, automation = Module("Seller"), Module("Automation")

  local function IsFunction(fn) return type(fn) == "function" end
  if not hookup:Require({
    { "Events:RegisterMessage", events and IsFunction(events.RegisterMessage) },
    { "Items:GetSlotKeyFromBagAndSlot", items and IsFunction(items.GetSlotKeyFromBagAndSlot) },
    { "Items:GetItemDataFromSlotKey", items and IsFunction(items.GetItemDataFromSlotKey) },
    { "Database:GetStackingOptions", database and IsFunction(database.GetStackingOptions) },
  }) then return end

  -- The seller and its automation only came with BetterBags 0.8.0. Older
  -- versions don't sell anything, so there's nothing to protect or hand junk to.
  local canSell = seller and IsFunction(seller.StillThere) and IsFunction(seller.Sell)
    and automation and IsFunction(automation.BlockedReason)

  hookup:OnTurnOff(function()
    ns.externalSeller = nil
    for decoration in pairs(painted) do ns.PaintButton(decoration, nil, nil) end
  end)

  -----------------------------------------------------------------------------
  -- Drawing
  -----------------------------------------------------------------------------

  local function Paint(decoration)
    local item = decoration.MothersPurseItem
    local data = item and item.GetItemData and item:GetItemData() or decoration._itemData
    if data and not data.isItemEmpty and data.bagid and data.slotid then
      ns.PaintButton(decoration, data.bagid, data.slotid)
    else
      ns.PaintButton(decoration, nil, nil)
    end
  end

  events:RegisterMessage("item/Updated", function(_, item, decoration)
    if not decoration then return end
    hookup:Safely(function()
      painted[decoration] = true
      decoration.MothersPurseItem = item
      decoration.MothersPurseAbove = item and item.button
      Paint(decoration)
    end)
  end)

  events:RegisterMessage("item/Clearing", function(_, _, decoration)
    if decoration then hookup:Safely(ns.PaintButton, decoration, nil, nil) end
  end)

  local function Refresh()
    hookup:Safely(function()
      for decoration in pairs(painted) do
        if decoration:IsVisible() then Paint(decoration) end
      end
    end)
  end
  ns.On("MarksChanged", Refresh)
  ns.On("SettingsChanged", Refresh)

  -----------------------------------------------------------------------------
  -- Merged stacks
  -----------------------------------------------------------------------------

  -- The other bag slots BetterBags shows on the same button as bag/slot, when
  -- it merges identical unstackable items. Stackable items don't need this:
  -- they're marked by item ID, so every stack of them shares one mark.
  local function MergedSlots(bag, slot)
    local slotkey = items:GetSlotKeyFromBagAndSlot(bag, slot)
    local data = slotkey and items:GetItemDataFromSlotKey(slotkey)
    if not (data and data.itemHash) then return nil end
    for kind, slotInfo in pairs(items.slotInfo or {}) do
      local stackInfo = slotInfo.stacks and slotInfo.stacks:GetStackInfo(data.itemHash)
      if stackInfo and (stackInfo.rootItem == slotkey or stackInfo.slotkeys[slotkey]) then
        local opts = database:GetStackingOptions(kind)
        if not (opts and opts.mergeUnstackable) then return nil end
        local slots = {}
        for key in pairs(stackInfo.slotkeys) do
          local other = items:GetItemDataFromSlotKey(key)
          if other and other.bagid and other.slotid then
            table.insert(slots, { other.bagid, other.slotid })
          end
        end
        return slots
      end
    end
  end

  ns.AddSlotLinker(function(bag, slot)
    local ok, slots = hookup:Safely(MergedSlots, bag, slot)
    return ok and slots or nil
  end)

  -----------------------------------------------------------------------------
  -- Selling
  -----------------------------------------------------------------------------

  if not canSell then return end

  -- Every sale item and automation entry BetterBags has carries a bag and slot.
  -- One that doesn't means BetterBags changed, so it errors and the switch flips.
  local function IsFavorite(data)
    local bag, slot = data.bagid or data.bag, data.slotid or data.slot
    if not (bag and slot) then error("a BetterBags item without a bag and slot") end
    return ns.MarkToShow(bag, slot) == ns.FAVORITE
  end

  local StillThere = seller.StillThere
  seller.StillThere = function(self, data, ...)
    if not hookup.off and type(data) == "table" then
      local ok, favorite = hookup:Safely(IsFavorite, data)
      -- An item that couldn't be checked isn't sold this time either.
      if not ok or favorite then return nil end
    end
    return StillThere(self, data, ...)
  end

  local BlockedReason = automation.BlockedReason
  automation.BlockedReason = function(self, data, ...)
    if not hookup.off and type(data) == "table" then
      local ok, favorite = hookup:Safely(IsFavorite, data)
      if not ok or favorite then return "Marked as a favorite in Mother's Purse." end
    end
    return BlockedReason(self, data, ...)
  end

  -- Returns true when BetterBags took the sale.
  ns.externalSeller = function(queue, onDone)
    -- BetterBags checks each item's GUID before selling it, so a slot that
    -- changed in the meantime is skipped instead of selling the wrong item.
    local list = {}
    for _, item in ipairs(queue) do
      table.insert(list, { bagid = item.bag, slotid = item.slot, mothersPurseItem = item,
        itemInfo = { itemGUID = item.guid, sellPrice = item.price } })
    end
    return (hookup:Safely(seller.Sell, seller, list, {
      stillOpen = function() return MerchantFrame:IsShown() end,
      onDone = function(job)
        hookup:Safely(function()
          local sold = {}
          for _, entry in ipairs(job.sold or {}) do
            local item = entry.data and entry.data.mothersPurseItem
            if item then
              item.count = entry.count or item.count
              table.insert(sold, item)
            end
          end
          onDone(sold)
        end)
      end,
    }))
  end
end)
