-- TacoCrafts.lua
-- Exports a character's learned recipes + on-hand materials to a SavedVariables
-- table that an out-of-game converter turns into JSON for a web page.
--
-- Data model cribbed from TradeSkillMaster's verified Forever calls:
--   C_TradeSkillUI.*       -> profession + recipes (Retail tier, confirmed on build 50504)
--   C_Container.*          -> bag/bank contents
-- This addon writes ONLY state to disk (no networking) and calls SaveVariables()
-- after each scan for mid-session freshness.

local frame = CreateFrame("Frame")

-- SavedVariablesPerCharacter: <global> TacoCraftsDB. The global MUST hold the table or
-- SaveVariables() persists nil. `db` is resolved lazily — see ensureDB().
local db

-- Point db at the global, creating it if needed, and always keep the global non-nil
-- so SaveVariables() has a table to write. Safe to call any time after login.
local function ensureDB()
    if not db then db = TacoCraftsDB or {} end
    TacoCraftsDB = db
    return db
end

-- tiny helper: safely peel a display name out of an item/recipe link like
-- "|cffa335ee|Hitem:123:...:0:0:..|h[Flask of Something]|h|r"
local function linkName(link)
    if not link then return nil end
    return strmatch(link, "%|h%[([^%]]+)%]")
end

-- Resolve an item's display name. TSM uses C_Item.GetItemInfo (modern table API, name is
-- the first return); the legacy global GetItemInfo(itemID) returns nil on Forever.
local function itemName(itemID)
    if C_Item and C_Item.GetItemInfo then
        local name = C_Item.GetItemInfo(itemID)
        if name and type(name) == "string" then return name end
    end
    if GetItemInfo then
        local name = GetItemInfo(itemID)
        if type(name) == "string" then return name end
    end
    return nil
end

-- Normalise a texture reference to a bare lowercase icon filename (e.g.
-- "inv_potion_17") so the web page can render it via the Zamimg CDN
-- (https://wow.zamimg.com/images/wow/icons/large/<name>.jpg). Texture APIs
-- return a path like "Interface\\ICONS\\INV_Potion_17"; strip down to the
-- basename, drop any extension, lowercase it. A numeric fileDataID has no
-- Zamimg filename — return nil so callers can fall back instead.
local function normalizeIcon(icon)
    if not icon then return nil end
    if type(icon) == "number" then return nil end
    if type(icon) ~= "string" then return nil end
    icon = icon:gsub("\\", "/")
    local base = icon:match("([^/]+)$") or icon
    base = base:gsub("%.[^.]+$", "")
    if base == "" then return nil end
    return strlower(base)
end

-- Resolve an item's ICON FILENAME (e.g. "inv_potion_17") so the web page can render it
-- via the public Blizzard/Wowhead CDN. GetItemIcon normally returns a path like
-- "Interface\\ICONS\\INV_Potion_17"; strip down to the bare filename.
local function itemIcon(itemID)
    local ok, icon = pcall(GetItemIcon, itemID)
    if not ok or not icon then return nil end
    return normalizeIcon(icon)
end

-- Resolve a RECIPE's own icon (the one the profession UI shows for the spell).
-- Prefer the legacy GetSpellTexture, which returns a texture path string;
-- C_Spell.GetSpellTexture on retail builds returns a numeric fileDataID,
-- which has no Zamimg filename, so a string result from it is used and a
-- numeric one is ignored (caller falls back to the crafted item's icon).
local function spellIcon(spellId)
    local ok, tex = pcall(GetSpellTexture, spellId)
    if ok and type(tex) == "string" then
        local name = normalizeIcon(tex)
        if name then return name end
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok2, tex2 = pcall(C_Spell.GetSpellTexture, spellId)
        if ok2 and type(tex2) == "string" then return normalizeIcon(tex2) end
    end
    return nil
end

-- bag ranges (mirrors TSM Container.lua exactly: read live constants when available,
-- fall back to classic defaults):
--   bags:  BACKPACK_CONTAINER .. numBags   (numBags = NUM_BAG_SLOTS + reagent bags on retail/Forever)
--   bank:  bank tabs, scanned only while the bank frame is open
local InventoryConstants = Constants and Constants.InventoryConstants
local NUM_BAG_SLOTS       = NUM_BAG_SLOTS       or 4
local NUM_REAGENT_BAGS    = (InventoryConstants and InventoryConstants.NumReagentBagSlots) or 0
local NUM_BANK_BAGS       = (InventoryConstants and InventoryConstants.NumCharacterBankSlots) or NUM_BANKBAGSLOTS or 7
local MAX_BANK_SLOTS      = MAX_BANK_SLOTS_PER_TAB or 98   -- retail bank tabs are flat; guard against huge per-tab iteration
local BACKPACK            = BACKPACK_CONTAINER     -- 0

-- -----------------------------------------------------------------------------
-- Recipe scanning (profession window must be open)
-- -----------------------------------------------------------------------------
local function scanProfession()
    ensureDB()
    -- diagnostics: record why a scan bails so the user can report it precisely
    db.lastScan = { reason = nil, at = time(), n = nil }
    local function bail(reason)
        db.lastScan.reason = reason
        return false
    end

    if not C_TradeSkillUI then return bail("no C_TradeSkillUI") end
    local ok, base = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if not ok then return bail("GetBaseProfessionInfo error: " .. tostring(base)) end
    if not base then return bail("GetBaseProfessionInfo nil") end
    if not base.profession then return bail("base.profession nil") end
    if not (C_TradeSkillUI.IsTradeSkillReady and C_TradeSkillUI.IsTradeSkillReady()) then
        return bail("profession not ready")
    end

    -- Only learned recipes: clear any "show unlearned" filter (TSM ClearFilters pattern)
    if C_TradeSkillUI.SetShowLearned then C_TradeSkillUI.SetShowLearned(true) end
    if C_TradeSkillUI.SetShowUnlearned then C_TradeSkillUI.SetShowUnlearned(false) end
    if C_TradeSkillUI.SetOnlyShowMakeableRecipes then C_TradeSkillUI.SetOnlyShowMakeableRecipes(false) end

    local okRecipes, recipeIDs = pcall(function()
        -- TSM calls this with a reusable context table; mirror the verified convention
        local ctx = {}
        C_TradeSkillUI.GetFilteredRecipeIDs(ctx)
        return ctx
    end)
    if not okRecipes then return bail("GetFilteredRecipeIDs error: " .. tostring(recipeIDs)) end
    if not recipeIDs then return bail("GetFilteredRecipeIDs nil") end
    if #recipeIDs == 0 then return bail("recipe list empty") end

    local profession = {
        name = base.professionName or base.parentProfessionName or "Unknown",
        skillId = base.profession,
        level = nil, maxLevel = nil,
        isSecondary = false,
        recipes = {},
    }

    -- skill rank: read ALL professions' skill via GetProfessions()/GetProfessionInfo()
    -- (TSM's PlayerProfessions.lua verified pattern). TSM records every profession
    -- independently — do the same, then match to this one by name in the converter.
    -- GetProfessions() returns VARARGS (one scalar id per profession); pack first.
    db.professionSkill = {}
    local profIDs = { GetProfessions() }
    for _, profID in ipairs(profIDs) do
        local pname, _, level, maxLevel, _, _, skillId = GetProfessionInfo(profID)
        if pname and level then
            db.professionSkill[pname] = { level = level, maxLevel = maxLevel }
            if pname == profession.name then
                profession.level = level
                profession.maxLevel = maxLevel
            end
        end
    end

    for _, spellIdRaw in ipairs(recipeIDs) do
        local spellId = tonumber(spellIdRaw)
        if spellId then
            local recipe = {
                spellId = spellId,
                name = nil,
                icon = nil,
                reagents = {},
            }
            -- recipe name from the crafted-item link (what a guildmate reads)
            local okLink, itemLink = pcall(C_TradeSkillUI.GetRecipeItemLink, spellId)
            if okLink and itemLink then
                recipe.name = linkName(itemLink)
            end
            if not recipe.name then
                -- some recipes (salvage/chants) expose a recipe link instead
                local okRl, recipeLink = pcall(C_TradeSkillUI.GetRecipeLink, spellId)
                if okRl and recipeLink then recipe.name = linkName(recipeLink) end
            end

            -- recipe icon for the web page: the profession UI's own spell icon
            -- first, then the crafted item's icon (for potions/elixirs that is
            -- the same potion icon). Either way it is a Zamimg filename like
            -- "inv_potion_17"; nil here means the page falls back to its
            -- spellId map, then to the category flask.
            recipe.icon = spellIcon(spellId)
            if not recipe.icon and okLink and itemLink then
                local craftedItemID = tonumber(strmatch(itemLink, "item:(%d+)"))
                if craftedItemID then recipe.icon = itemIcon(craftedItemID) end
            end

            -- reagents from the schematic
            local okSch, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, spellId, false, nil)
            if okSch and sch and sch.reagentSlotSchematics then
                for _, slot in ipairs(sch.reagentSlotSchematics) do
                    -- keep only REQUIRED basic reagents (skip quality/finishing/optional),
                    -- mirroring TSM's private.IsRegularMat
                    local isBasic = slot.reagentType and slot.reagentType == Enum.CraftingReagentType.Basic
                    local isReqSlot = slot.dataSlotType and (
                        slot.dataSlotType == Enum.TradeskillSlotDataType.Reagent
                        or slot.dataSlotType == Enum.TradeskillSlotDataType.ModifiedReagent)
                    if isBasic and isReqSlot and slot.reagents and slot.reagents[1] and slot.reagents[1].itemID then
                        local itemID = slot.reagents[1].itemID
                        local reagent = { itemId = itemID, name = nil, icon = itemIcon(itemID), count = slot.quantityRequired or 1 }
                        reagent.name = itemName(itemID)
                        if not reagent.name then
                            -- fallback: pull from a reagent item link if present
                            local rItem = slot.reagents[1]
                            if rItem.itemLink then reagent.name = linkName(rItem.itemLink) end
                        end
                        tinsert(recipe.reagents, reagent)
                    end
                end
            end
            -- recipe always included even if schematic unavailable (name may still resolve)
            tinsert(profession.recipes, recipe)
        end
    end

    db.profession = profession
    db.lastScan.n = #profession.recipes
    db.lastScan.reason = nil
    return true
end

-- -----------------------------------------------------------------------------
-- Material scanning (bags always; bank only while bank frame is open)
-- -----------------------------------------------------------------------------
local function scanMaterials()
    ensureDB()
    local mats = {}

    -- Resolve an item's display name: the container's item link embeds it (same reliable
    -- source the recipe scanner uses). GetItemInfo(itemID) by itself often returns nil.
    local function matName(bag, slot, itemID)
        if C_Container.GetContainerItemLink then
            local link = C_Container.GetContainerItemLink(bag, slot)
            local name = linkName(link)
            if name then return name end
        end
        return itemName(itemID)
    end

    -- enumerate all bags (0 = backpack, then bags 1..NUM_BAG_SLOTS, then reagent bags)
    local numBags = BACKPACK + NUM_BAG_SLOTS + NUM_REAGENT_BAGS
    for bag = BACKPACK, numBags do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                -- bank tab items are one-per-slot (stack 1); reagent/haggle bags are normal stacks
                local count = info and info.stackCount or 1
                if count <= 0 then count = 1 end
                local entry = mats[itemID]
                if entry then
                    entry.count = entry.count + count
                else
                    mats[itemID] = { itemId = itemID, name = matName(bag, slot, itemID), icon = itemIcon(itemID), count = count }
                end
            end
        end
    end

    -- bank tabs (retail: one bag index per tab, flat slots), only while the bank frame is open
    local bankOpen = BankFrame and BankFrame:IsShown() or false
    if bankOpen then
        local firstBankBag = BACKPACK + NUM_BAG_SLOTS + NUM_REAGENT_BAGS + 1
        for bag = firstBankBag, firstBankBag + NUM_BANK_BAGS - 1 do
            local numSlots = math.min(C_Container.GetContainerNumSlots(bag), MAX_BANK_SLOTS)
            for slot = 1, numSlots do
                local itemID = C_Container.GetContainerItemID(bag, slot)
                if itemID then
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    local count = info and info.stackCount or 1
                    if count <= 0 then count = 1 end
                    local entry = mats[itemID]
                    if entry then
                        entry.count = entry.count + count
                    else
                        mats[itemID] = { itemId = itemID, name = matName(bag, slot, itemID), icon = itemIcon(itemID), count = count }
                    end
                end
            end
        end
    end

    db.materials = mats
end

-- -----------------------------------------------------------------------------
-- Meta
-- -----------------------------------------------------------------------------
local function buildMeta()
    ensureDB()
    db.meta = {
        updated = time(),
        character = UnitName("player"),
        realm = GetRealmName(),
        faction = UnitFactionGroup and UnitFactionGroup("player") or nil,
        classKey = UnitClass and select(2, UnitClass("player")) or nil,
    }
    -- convert materials hash -> array for clean JSON output
    db.materialsList = {}
    if db.materials then
        for itemID, m in pairs(db.materials) do
            tinsert(db.materialsList, { itemId = itemID, name = m.name, icon = m.icon, count = m.count })
        end
        -- deterministic order: species name, then itemId
        sort(db.materialsList, function(a, b)
            if a.name ~= b.name then return (a.name or "") < (b.name or "") end
            return a.itemId < b.itemId
        end)
    end
end

-- -----------------------------------------------------------------------------
-- Missing-name recovery (0.3): item info loads asynchronously after a reload.
-- A scan taken on a cold cache gets nil names from C_Item.GetItemInfo /
-- GetItemInfo for most items (only recently-touched items are cached), and
-- the SavedVariables then ship nameless reagents/materials to the web page.
-- So after every scan: ask the client to load the missing items, and
-- re-resolve names when they arrive (ITEM_INFO_RECEIVED) plus on a short
-- delay, saving whenever anything was fixed. Names already present are
-- never touched, so a warm-cache scan costs nothing here.
-- -----------------------------------------------------------------------------
local function resolveMissingNames()
    ensureDB()
    local fixed = false
    local function fix(entry)
        if entry and not entry.name and entry.itemId then
            local name = itemName(entry.itemId)
            if name then entry.name = name; fixed = true end
        end
    end
    if db.profession and db.profession.recipes then
        for _, r in ipairs(db.profession.recipes) do
            if r.reagents then for _, g in ipairs(r.reagents) do fix(g) end end
        end
    end
    if db.materials then for _, m in pairs(db.materials) do fix(m) end end
    if fixed then
        pcall(buildMeta)
        pcall(SaveVariables)
    end
    return fixed
end

local function requestMissingNames()
    ensureDB()
    local function req(entry)
        if entry and not entry.name and entry.itemId and C_Item and C_Item.RequestLoadItemDataByID then
            pcall(C_Item.RequestLoadItemDataByID, entry.itemId)
        end
    end
    if db.profession and db.profession.recipes then
        for _, r in ipairs(db.profession.recipes) do
            if r.reagents then for _, g in ipairs(r.reagents) do req(g) end end
        end
    end
    if db.materials then for _, m in pairs(db.materials) do req(m) end end
end

-- After a scan, give the item cache a moment to warm up, then fill in any
-- names that were nil at scan time (and request loads for the rest).
local function scheduleNameRecovery()
    requestMissingNames()
    C_Timer.After(2, function() pcall(resolveMissingNames) end)
    C_Timer.After(6, function() pcall(resolveMissingNames) end)
end

function TacoCraftsDebug()
    pcall(buildMeta)
    local out = {}
    tinsert(out, string.format("TacoCrafts | class=%s char=%s realm=%s",
        (db.meta and db.meta.classKey) or "?",
        (db.meta and db.meta.character) or "?",
        (db.meta and db.meta.realm) or "?"))
    tinsert(out, string.format("profession=%s skill=%s/%s isSecondary=%s",
        (db.profession and db.profession.name) or "none",
        (db.profession and tostring(db.profession.level)) or "?",
        (db.profession and tostring(db.profession.maxLevel)) or "?",
        (db.profession and tostring(db.profession.isSecondary)) or "?"))
    if db.professionSkill then
        for pn, info in pairs(db.professionSkill) do
            tinsert(out, string.format("  skill(%s)=%s/%s", pn, tostring(info.level), tostring(info.maxLevel)))
        end
    end
    if db.profession and db.profession.recipes then
        tinsert(out, string.format("recipes=%d", #db.profession.recipes))
        for i = 1, math.min(#db.profession.recipes, 5) do
            local r = db.profession.recipes[i]
            tinsert(out, string.format("  #%d id=%d name=%s", i, r.spellId, tostring(r.name)))
        end
    end
    tinsert(out, string.format("materials=%d", db.materials and table_size(db.materials) or 0))
    if db.lastScan then
        if db.lastScan.reason then
            tinsert(out, string.format("LAST SCAN BAILED: %s", db.lastScan.reason))
        elseif db.lastScan.n then
            tinsert(out, string.format("last scan OK: %d recipes", db.lastScan.n))
        else
            tinsert(out, "last scan: attempted, no result recorded")
        end
    else
        tinsert(out, "last scan: never ran (event/hook didn't fire)")
    end
    print(table.concat(out, "\n"))
    return true -- return value (not nil) so /run macros don't error
end

SLASH_TACOCRAFTS1 = "/tacocrafts"
SlashCmdList["TACOCRAFTS"] = function(msg)
    local key = strlower(strtrim(msg))
    if key == "debug" then
        TacoCraftsDebug()
    elseif key == "scan" then
        -- run synchronously so we get a definitive answer about the scan path
        local profOk = pcall(scanProfession)
        local matsOk = pcall(scanMaterials)
        pcall(buildMeta)
        pcall(SaveVariables)
        -- item info may still be loading after a reload; fill in any names
        -- that came back nil once the cache warms up
        pcall(scheduleNameRecovery)
        print("TacoCrafts: scan ran. profOk=" .. tostring(profOk) .. " matsOk=" .. tostring(matsOk))
        if db.lastScan and db.lastScan.reason then
            print("TacoCrafts: scan bail reason: " .. db.lastScan.reason)
        end
        print("TacoCrafts: run /tacocrafts debug to see captured data.")
    else
        print("TacoCrafts: /tacocrafts scan | debug")
    end
end

-- -----------------------------------------------------------------------------
-- Events
-- -----------------------------------------------------------------------------
-- Forever (confirmed by TSM's Scanner.lua lines 120-125) fires TRADE_SKILL_LIST_UPDATE,
-- NOT the classic TRADE_SKILL_SHOW / TRADE_SKILL_UPDATE. Register the Forever event,
-- plus a fallback on TRADE_SKILL_SHOW and a ProfessionsFrame hook to catch the book opening.
frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("TRADE_SKILL_UPDATE")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("ITEM_INFO_RECEIVED")

-- Ensure the Professions-book OnShow hook is attached. The frame doesn't exist until
-- Blizzard_ProfessionsBook is loaded, and that only happens when you open the book —
-- so LoadAddOn it (TSM's pattern) and retry until the frame appears.
local hookAttached = false
local function ensureProfessionsHook()
    if hookAttached then return end
    if C_AddOns and not C_AddOns.IsAddOnLoaded("Blizzard_ProfessionsBook") then
        pcall(C_AddOns.LoadAddOn, "Blizzard_ProfessionsBook")
    end
    if ProfessionsFrame then
        hookAttached = true
        ProfessionsFrame:HookScript("OnShow", function()
            if tradeSkillDebounce then tradeSkillDebounce:Cancel() end
            tradeSkillDebounce = C_Timer.After(0.3, function()
                pcall(scanProfession)
                pcall(buildMeta)
                pcall(SaveVariables)
            end)
        end)
    else
        -- frame not up yet; try again shortly
        C_Timer.After(2, ensureProfessionsHook)
    end
end

local tradeSkillDebounce = nil
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "TacoCrafts" then
        -- saved vars load after this file runs; ensureDB points db at the global
        ensureDB()
        pcall(buildMeta)
        ensureProfessionsHook()
        return
    end

    if event == "ITEM_INFO_RECEIVED" then
        -- an item we asked the client to load is ready; fill in any names
        -- that were nil at scan time and persist if anything changed
        pcall(resolveMissingNames)
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_LIST_UPDATE" then
        -- debounce: scanning costs frame time, avoid doing it on every partial refresh
        if tradeSkillDebounce then tradeSkillDebounce:Cancel() end
        tradeSkillDebounce = C_Timer.After(0.3, function()
            pcall(scanProfession)
            pcall(buildMeta)
            pcall(SaveVariables)
            pcall(scheduleNameRecovery)
        end)
    elseif event == "BANKFRAME_OPENED" then
        pcall(scanMaterials)
        pcall(buildMeta)
        pcall(SaveVariables)
    elseif event == "PLAYER_LOGOUT" then
        -- final guaranteed snapshot on logout
        pcall(scanMaterials)
        pcall(buildMeta)
        pcall(SaveVariables)
    end
end)
