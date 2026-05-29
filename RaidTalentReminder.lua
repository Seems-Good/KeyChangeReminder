-- RaidTalentReminder.lua
-- Isolated module: warns the player on a raid READY_CHECK if their current
-- talent LOADOUT NAME does not match any of the saved "raid loadout" names.
--
-- Design constraints:
--   • Zero coupling to Core.lua or Settings.lua runtime logic paths.
--   • Off by default (raidTalentReminder = false in charDb).
--   • Reminder auto-dismisses after 5 seconds.
--   • Matching is by loadout NAME (locale-safe), not by configID or import
--     string, so the check survives UI reloads and spec changes cleanly.
--   • No talent tree node walking — one API call to get the current loadout
--     name, one table lookup against the saved list.  Cheap and reliable.
--   • Saved loadout names are PER-CHARACTER (KeyChangeReminderCharDB) because
--     every class/spec has a completely different set of loadout names.
--
-- ┌─────────────────────────────────────────────────────────────────────┐
-- │  KCR AUDIT LOG                                                      │
-- │  [KCR_RTR_AUDIT: refactor — loadout-name check replaces per-talent  │
-- │   node-walk.  Node walking was unreliable (0 results when a loadout  │
-- │   is selected) and unnecessarily complex.  Loadout name is the       │
-- │   natural user-facing identity for a build and is a single API call. │
-- │  [KCR_RTR_AUDIT: raidTalentReminder and raidTalentNames moved from  │
-- │   account-wide KeyChangeReminderDB to per-character                  │
-- │   KeyChangeReminderCharDB.  All reads/writes use GetChar/SetChar.]   │
-- └─────────────────────────────────────────────────────────────────────┘

KeyChangeReminder = KeyChangeReminder or {}

-- ──────────────────────────────────────────────
-- Module namespace
-- ──────────────────────────────────────────────

local RTR = {}
KeyChangeReminder.RaidTalentReminder = RTR

-- ──────────────────────────────────────────────
-- Color / format helpers (mirrors Core.lua palette)
-- ──────────────────────────────────────────────

local COLOR_YELLOW = "|cffffff00"
local COLOR_GRAY   = "|cff808080"
local COLOR_BLUE   = "|cff00ccff"
local COLOR_RED    = "|cffff4444"
local COLOR_GREEN  = "|cff44ff88"
local COLOR_ORANGE = "|cffff9900"

local FORMAT_SLUG  = COLOR_BLUE .. "[KCR-Raid]|r" .. COLOR_GRAY .. " »|r"

-- ──────────────────────────────────────────────
-- Internal state
-- ──────────────────────────────────────────────

local dismissTimer = nil   -- handle returned by C_Timer.NewTimer (cancelable)

-- ──────────────────────────────────────────────
-- DB helpers
-- ──────────────────────────────────────────────

-- [KCR_RTR_AUDIT: IsEnabled reads from the per-character charDb via GetChar.
--  Each character independently enables or disables the raid reminder.]
local function IsEnabled()
    return KeyChangeReminder:GetChar("raidTalentReminder") == true
end

-- [KCR_RTR_AUDIT: GetSavedLoadoutNames reads/writes the per-character charDb
--  via GetChar/SetChar.  DB key kept as "raidTalentNames" for clarity; the
--  scope change (account → character) is handled by the DB layer, not the key.]
local function GetSavedLoadoutNames()
    -- Always return a table, never nil.
    local t = KeyChangeReminder:GetChar("raidTalentNames")
    if type(t) ~= "table" then
        t = {}
        KeyChangeReminder:SetChar("raidTalentNames", t)
    end
    return t
end

-- ──────────────────────────────────────────────
-- Current loadout name  (the ONLY talent API we call)
-- ──────────────────────────────────────────────
--
-- Confirmed working via in-game /run:
--
--   -- All loadouts for current spec, with active flag:
--   /run for i,id in ipairs(C_ClassTalents.GetConfigIDsBySpecID()) do
--           local c=C_Traits.GetConfigInfo(id)
--           if c then print(i,id,c.name,c.active) end
--         end
--
--   -- Current displayed loadout name:
--   /run local s=PlayerUtil.GetCurrentSpecID()
--           local i=C_ClassTalents.GetLastSelectedSavedConfigID(s)
--                    or C_ClassTalents.GetActiveConfigID()
--           local c=C_Traits.GetConfigInfo(i)
--           print(c and c.name or "none")
--
-- Resolution order (most-specific → least-specific):
--
--   1. GetLastSelectedSavedConfigID(specID)
--        → the loadout currently SHOWN in the talent UI, even with pending
--          unapplied changes.  This is what the player considers "active".
--
--   2. GetActiveConfigID()
--        → the last COMMITTED loadout.  Fallback when no saved loadout is
--          explicitly selected (e.g. the player is using the default config).
--
--   3. Scan GetConfigIDsBySpecID() for info.active == true
--        → last-resort: iterate all saved loadouts and return the one
--          Blizzard marks as committed.  Handles edge cases where both
--          APIs above return nil.
--
-- Returns the loadout display name string, or nil if it cannot be determined.

local function GetCurrentLoadoutName()
    -- Require the minimum API surface we will use.
    if not (C_ClassTalents and C_Traits and C_Traits.GetConfigInfo) then
        return nil
    end

    local configID

    -- ── Level 1: displayed / last-selected loadout ─────────────────────────
    if PlayerUtil and PlayerUtil.GetCurrentSpecID
       and C_ClassTalents.GetLastSelectedSavedConfigID then
        local specID = PlayerUtil.GetCurrentSpecID()
        if type(specID) == "number" and specID > 0 then
            configID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
        end
    end

    -- ── Level 2: last committed config ────────────────────────────────────
    if not configID and C_ClassTalents.GetActiveConfigID then
        configID = C_ClassTalents.GetActiveConfigID()
    end

    -- ── Level 3: scan all loadouts for active == true ──────────────────────
    if not configID and C_ClassTalents.GetConfigIDsBySpecID then
        local specID_scan
        if PlayerUtil and PlayerUtil.GetCurrentSpecID then
            specID_scan = PlayerUtil.GetCurrentSpecID()
        end
        local ids = specID_scan
                    and C_ClassTalents.GetConfigIDsBySpecID(specID_scan)
                     or C_ClassTalents.GetConfigIDsBySpecID()
        if type(ids) == "table" then
            for _, id in ipairs(ids) do
                local info = C_Traits.GetConfigInfo(id)
                if type(info) == "table" and info.active == true then
                    configID = id
                    break
                end
            end
        end
    end

    if not configID then return nil end

    -- Resolve the name from the configID.
    local configInfo = C_Traits.GetConfigInfo(configID)
    if type(configInfo) == "table"
       and type(configInfo.name) == "string"
       and configInfo.name ~= "" then
        return configInfo.name
    end

    return nil
end

-- ──────────────────────────────────────────────
-- Raid-group detection
-- ──────────────────────────────────────────────
--
-- [KCR_RTR_AUDIT: IsInRaid() returns 1 (truthy) or nil (falsy) in WoW —
--  it is NOT a boolean and comparing with == true always evaluates false.
--  Use truthiness instead: IsInRaid() and true or false.]
local function IsInRaidGroup()
    return IsInRaid() and true or false
end

-- ──────────────────────────────────────────────
-- Loadout mismatch check
-- ──────────────────────────────────────────────
--
-- Returns (hasMismatch, currentName, savedList)
--   hasMismatch  — true when currentName does NOT match any saved loadout name
--   currentName  — the resolved loadout name (may be nil if API unavailable)
--   savedList    — the full saved list (for display in messages)

local function CheckLoadoutMismatch()
    local saved = GetSavedLoadoutNames()
    if #saved == 0 then
        -- No loadouts configured — nothing to warn about.
        return false, GetCurrentLoadoutName(), saved
    end

    local currentName = GetCurrentLoadoutName()
    if not currentName then
        -- Can't determine current loadout — fail open (no false alarm).
        return false, nil, saved
    end

    local currentLower = currentName:lower()
    for _, name in ipairs(saved) do
        if name:lower() == currentLower then
            return false, currentName, saved  -- match found — all good
        end
    end

    return true, currentName, saved  -- no match — warn
end

-- ──────────────────────────────────────────────
-- Reminder display / dismiss
-- ──────────────────────────────────────────────

local function CancelDismissTimer()
    if dismissTimer then
        dismissTimer:Cancel()
        dismissTimer = nil
    end
end

-- [KCR_RTR_AUDIT: removed the FORMAT_SLUG prefix from the chatMsg argument
--  passed to ShowReminder.  ShowReminder (Core.lua) already prepends FORMAT_SLUG
--  when it prints to chat, so passing it here caused the slug to appear twice:
--    "[KCR-Raid] » [KCR-Raid] » Check your raid talents! ..."
--  Correct behaviour: pass only the message body; ShowReminder handles the prefix.]
local function ShowRaidTalentWarning(currentName, savedList)
    CancelDismissTimer()

    local displayMsg = "Check your raid talents!"

    -- Chat line: show what loadout is active vs. what is expected.
    local currentPart = currentName
                        and (COLOR_RED .. " [" .. currentName .. "]|r")
                         or (COLOR_RED .. " [unknown loadout]|r")
    local expectedPart = COLOR_GRAY .. " Expected: " .. table.concat(savedList, " or ") .. "|r"
    local chatMsg = "Check your raid talents!" .. currentPart .. expectedPart

    -- Pass chatMsg without the FORMAT_SLUG prefix — ShowReminder adds it.
    KeyChangeReminder:ShowReminder(displayMsg, chatMsg)

    -- Auto-dismiss after 5 seconds.
    dismissTimer = C_Timer.NewTimer(5, function()
        dismissTimer = nil
        KeyChangeReminder:HideReminder()
    end)
end

-- ──────────────────────────────────────────────
-- Public API used by Settings.lua panel
-- ──────────────────────────────────────────────

-- Add a loadout name to the saved list (deduplicates, case-insensitive).
-- Returns true if added, false if already present.
-- [KCR_RTR_AUDIT: persists via SetChar — per-character storage]
function RTR:AddLoadoutName(name)
    if type(name) ~= "string" or name:match("^%s*$") then return false end
    name = name:match("^%s*(.-)%s*$")  -- trim whitespace

    local saved = GetSavedLoadoutNames()
    local lower = name:lower()
    for _, existing in ipairs(saved) do
        if existing:lower() == lower then
            return false  -- duplicate
        end
    end
    saved[#saved + 1] = name
    KeyChangeReminder:SetChar("raidTalentNames", saved)
    return true
end

-- Keep old name as an alias so any external callers are not broken.
function RTR:AddTalentName(name)
    return self:AddLoadoutName(name)
end

-- Remove a saved loadout name by index (1-based).  Returns true on success.
-- [KCR_RTR_AUDIT: persists via SetChar — per-character storage]
function RTR:RemoveTalentByIndex(idx)
    local saved = GetSavedLoadoutNames()
    if not saved[idx] then return false end
    table.remove(saved, idx)
    KeyChangeReminder:SetChar("raidTalentNames", saved)
    return true
end

-- Returns the current loadout name as a single-element array, or empty array.
-- Used by Settings.lua "Add Current Loadout" button.
function RTR.GetActiveTalentNames()
    local name = GetCurrentLoadoutName()
    if name then
        return { name }
    end
    return {}
end

-- Returns the current saved list as a copy (safe for iteration during edits).
function RTR:GetTalentList()
    local saved = GetSavedLoadoutNames()
    local copy  = {}
    for i, v in ipairs(saved) do copy[i] = v end
    return copy
end

-- Manually trigger the check (called from slash command / test button).
-- Works regardless of raid group membership or feature enable flag so it
-- can be used to verify setup at any time.
function RTR:ManualCheck()
    local hasMismatch, currentName, savedList = CheckLoadoutMismatch()
    local currentDisplay = currentName
                           and (COLOR_GRAY .. " [" .. currentName .. "]|r")
                            or (COLOR_RED  .. " [could not read loadout name]|r")

    if not IsEnabled() then
        -- Still run the check so the player can test, but prefix with a note.
        print(FORMAT_SLUG .. COLOR_YELLOW .. " (reminder is disabled — test only)|r")
    end

    if #savedList == 0 then
        print(FORMAT_SLUG .. COLOR_YELLOW .. " No raid loadouts saved.  Use /kcr raid add <name> or the settings panel.|r")
        return
    end

    if not currentName then
        print(FORMAT_SLUG .. COLOR_RED .. " Could not read current loadout name — talent API unavailable.|r")
        return
    end

    if hasMismatch then
        print(FORMAT_SLUG .. COLOR_RED .. " MISMATCH" .. currentDisplay
            .. COLOR_GRAY .. "  Expected: " .. table.concat(savedList, " or ") .. "|r")
        ShowRaidTalentWarning(currentName, savedList)
    else
        print(FORMAT_SLUG .. COLOR_GREEN .. " Loadout OK" .. currentDisplay .. "|r")
    end
end

-- ──────────────────────────────────────────────
-- Event frame
-- ──────────────────────────────────────────────
--
-- READY_CHECK fires when the raid leader initiates a ready check.
-- IsInRaid() returns 1 (truthy) when the player is in a raid group, nil otherwise.
-- GROUP_ROSTER_UPDATE fires whenever the group composition changes — used to
-- cancel a pending auto-dismiss timer if the player leaves the raid.

local rtrFrame = CreateFrame("Frame", "KCRRaidTalentReminderFrame", UIParent)
rtrFrame:RegisterEvent("ADDON_LOADED")

rtrFrame:SetScript("OnEvent", function(self, event, arg1)

    if event == "ADDON_LOADED" and arg1 == "KeyChangeReminder" then
        self:UnregisterEvent("ADDON_LOADED")
        -- Register the events we care about for the lifetime of the session.
        -- READY_CHECK  — fires when raid leader starts a ready check.
        -- GROUP_ROSTER_UPDATE — fires on group composition changes (join/leave raid).
        -- PLAYER_TALENT_UPDATE — kept for future caching hooks; no-op for now.
        self:RegisterEvent("READY_CHECK")
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        self:RegisterEvent("PLAYER_TALENT_UPDATE")

    elseif event == "READY_CHECK" then
        -- [KCR_RTR_AUDIT: Guard order:
        --   1. Feature must be enabled (per-character setting).
        --   2. Player must be in a raid group — IsInRaid() returns 1 or nil,
        --      so we use IsInRaidGroup() which normalises to true/false.
        --      Ready checks can technically fire outside raids (party leader
        --      uses it) so this guard ensures we only act in raid context.]
        if not IsEnabled() then return end
        if not IsInRaidGroup() then return end

        local hasMismatch, currentName, savedList = CheckLoadoutMismatch()
        if hasMismatch then
            ShowRaidTalentWarning(currentName, savedList)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Cancel the auto-dismiss timer if the player has left the raid.
        -- Leaving mid-warning would otherwise leave the dismiss timer running.
        if not IsInRaidGroup() then
            CancelDismissTimer()
        end

    elseif event == "PLAYER_TALENT_UPDATE" then
        -- Intentionally empty — GetCurrentLoadoutName() is called fresh each time.

    end
end)

-- ──────────────────────────────────────────────
-- Extend /kcr slash command
-- ──────────────────────────────────────────────
--
-- /kcr raid check              — manual mismatch check
-- /kcr raid add <LoadoutName>  — save a loadout name as a raid loadout
-- /kcr raid addcurrent         — save the currently active loadout name
-- /kcr raid remove <index>     — remove by list index
-- /kcr raid list               — print current saved names
-- /kcr raid clear              — remove all saved names
-- /kcr raid debug              — print API resolution trace

local _originalSlash = SlashCmdList["KEYCHANGE"]

SlashCmdList["KEYCHANGE"] = function(msg)
    local rest = msg or ""
    local first, remainder = rest:match("^%s*(%S+)%s*(.*)")
    first = first and first:lower() or ""

    if first == "raid" then
        local sub, tail = remainder:match("^%s*(%S+)%s*(.*)")
        sub  = sub  and sub:lower() or ""
        tail = tail or ""

        if sub == "check" then
            RTR:ManualCheck()

        elseif sub == "addcurrent" then
            local name = GetCurrentLoadoutName()
            if not name then
                print(FORMAT_SLUG .. COLOR_RED .. " Could not read current loadout name — talent API unavailable.|r")
                return
            end
            local added = RTR:AddLoadoutName(name)
            if added then
                print(FORMAT_SLUG .. COLOR_GREEN .. " Added raid loadout: \"" .. name .. "\".|r")
            else
                print(FORMAT_SLUG .. COLOR_YELLOW .. " \"" .. name .. "\" is already in your raid loadout list.|r")
            end

        elseif sub == "add" then
            local name = tail:match("^%s*(.-)%s*$")
            if name == "" then
                print(FORMAT_SLUG .. COLOR_RED .. " Usage: /kcr raid add <Loadout Name>|r")
                return
            end
            local currentName = GetCurrentLoadoutName()
            local added = RTR:AddLoadoutName(name)
            if not added then
                print(FORMAT_SLUG .. COLOR_YELLOW .. " \"" .. name .. "\" is already in your raid loadout list.|r")
                return
            end
            -- Warn if the name doesn't match the current loadout (likely a typo).
            if currentName and currentName:lower() ~= name:lower() then
                print(FORMAT_SLUG .. COLOR_ORANGE
                    .. " Saved \"" .. name .. "\", but your current loadout is \""
                    .. currentName .. "\".|r"
                    .. COLOR_GRAY .. "  (Use /kcr raid addcurrent to add the active one.)|r")
            else
                print(FORMAT_SLUG .. COLOR_GREEN .. " Added raid loadout: \"" .. name .. "\".|r")
            end

        elseif sub == "remove" then
            local idx = tonumber(tail:match("^%s*(%d+)"))
            if not idx then
                print(FORMAT_SLUG .. COLOR_RED .. " Usage: /kcr raid remove <number>|r  (see /kcr raid list)")
                return
            end
            local list = RTR:GetTalentList()
            local name = list[idx]
            if RTR:RemoveTalentByIndex(idx) then
                print(FORMAT_SLUG .. COLOR_GREEN .. " Removed raid loadout #" .. idx .. ": \"" .. (name or "?") .. "\".|r")
            else
                print(FORMAT_SLUG .. COLOR_RED .. " No entry at index " .. idx .. ".|r")
            end

        elseif sub == "list" then
            local list = RTR:GetTalentList()
            if #list == 0 then
                print(FORMAT_SLUG .. COLOR_YELLOW .. " No raid loadouts saved.  Use /kcr raid addcurrent to add the active one.|r")
            else
                local currentName = GetCurrentLoadoutName()
                local currentPart = currentName
                                    and (COLOR_GRAY .. " current: [" .. currentName .. "]|r")
                                     or (COLOR_RED  .. " [could not read loadout]|r")
                print(FORMAT_SLUG .. COLOR_YELLOW .. " Saved raid loadouts (" .. #list .. ") " .. currentPart)
                for i, name in ipairs(list) do
                    local match = currentName and (name:lower() == currentName:lower())
                    local status = match
                                   and (COLOR_GREEN .. " ✓ active|r")
                                   or  (COLOR_GRAY  .. " (not current)|r")
                    print(COLOR_GRAY .. "  [" .. i .. "] |r" .. name .. " " .. status)
                end
            end

        elseif sub == "clear" then
            -- [KCR_RTR_AUDIT: SetChar — per-character storage]
            KeyChangeReminder:SetChar("raidTalentNames", {})
            print(FORMAT_SLUG .. COLOR_YELLOW .. " All saved raid loadouts cleared.|r")

        elseif sub == "debug" then
            print(FORMAT_SLUG .. COLOR_YELLOW .. " Raid Loadout Debug:|r")

            -- Level 1: GetLastSelectedSavedConfigID
            local l1id, l1name
            if PlayerUtil and PlayerUtil.GetCurrentSpecID
               and C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID
               and C_Traits and C_Traits.GetConfigInfo then
                local s = PlayerUtil.GetCurrentSpecID()
                l1id = C_ClassTalents.GetLastSelectedSavedConfigID(s)
                if l1id then
                    local info = C_Traits.GetConfigInfo(l1id)
                    l1name = info and info.name or COLOR_RED .. "(GetConfigInfo returned nil)|r"
                end
            end
            print(COLOR_GRAY .. "  L1 GetLastSelectedSavedConfigID → |r"
                .. (l1id and tostring(l1id) or COLOR_RED .. "nil|r")
                .. (l1name and (COLOR_GRAY .. "  name=|r" .. l1name) or ""))

            -- Level 2: GetActiveConfigID
            local l2id, l2name
            if C_ClassTalents and C_ClassTalents.GetActiveConfigID
               and C_Traits and C_Traits.GetConfigInfo then
                l2id = C_ClassTalents.GetActiveConfigID()
                if l2id then
                    local info = C_Traits.GetConfigInfo(l2id)
                    l2name = info and info.name or COLOR_RED .. "(GetConfigInfo returned nil)|r"
                end
            end
            print(COLOR_GRAY .. "  L2 GetActiveConfigID            → |r"
                .. (l2id and tostring(l2id) or COLOR_RED .. "nil|r")
                .. (l2name and (COLOR_GRAY .. "  name=|r" .. l2name) or ""))

            -- Level 3: scan GetConfigIDsBySpecID for active==true
            if C_ClassTalents and C_ClassTalents.GetConfigIDsBySpecID
               and C_Traits and C_Traits.GetConfigInfo then
                local specID_dbg
                if PlayerUtil and PlayerUtil.GetCurrentSpecID then
                    specID_dbg = PlayerUtil.GetCurrentSpecID()
                end
                local ids = specID_dbg and C_ClassTalents.GetConfigIDsBySpecID(specID_dbg)
                                        or C_ClassTalents.GetConfigIDsBySpecID()
                print(COLOR_GRAY .. "  L3 GetConfigIDsBySpecID (" .. (ids and #ids or 0) .. " loadouts):|r")
                if type(ids) == "table" then
                    for i, id in ipairs(ids) do
                        local info = C_Traits.GetConfigInfo(id)
                        if info then
                            local flag = info.active and (COLOR_GREEN .. " [ACTIVE]|r") or ""
                            print(COLOR_GRAY .. "    [" .. i .. "] id=" .. id
                                .. "  name=" .. tostring(info.name) .. flag)
                        end
                    end
                end
            end

            -- Final resolved name
            local resolved = GetCurrentLoadoutName()
            print(COLOR_GRAY .. "  GetCurrentLoadoutName() → |r"
                .. (resolved and (COLOR_GREEN .. resolved .. "|r")
                              or  (COLOR_RED   .. "nil|r")))

            -- Mismatch summary
            local saved = GetSavedLoadoutNames()
            print(COLOR_GRAY .. "  Saved raid loadouts: |r" .. #saved
                .. COLOR_GRAY .. "  (this character)|r")
            if #saved > 0 then
                local hasMismatch, currentName2 = CheckLoadoutMismatch()
                if hasMismatch then
                    print(COLOR_RED .. "  MISMATCH — \"" .. (currentName2 or "?")
                        .. "\" not in saved list|r")
                else
                    print(COLOR_GREEN .. "  OK — current loadout matches saved list|r")
                end
            end

            -- Show whether the feature is enabled for this character.
            print(COLOR_GRAY .. "  raidTalentReminder (this char): |r"
                .. (IsEnabled() and (COLOR_GREEN .. "enabled|r") or (COLOR_RED .. "disabled|r")))

        else
            print(FORMAT_SLUG .. COLOR_YELLOW .. " Raid Talent Reminder commands:|r")
            print(COLOR_GRAY .. "  /kcr raid check            |r— test right now")
            print(COLOR_GRAY .. "  /kcr raid addcurrent       |r— save the current loadout name")
            print(COLOR_GRAY .. "  /kcr raid add <Name>       |r— save a loadout name manually")
            print(COLOR_GRAY .. "  /kcr raid remove <#>       |r— remove by list number")
            print(COLOR_GRAY .. "  /kcr raid list             |r— show saved loadouts")
            print(COLOR_GRAY .. "  /kcr raid clear            |r— remove all saved loadouts")
            print(COLOR_GRAY .. "  /kcr raid debug            |r— print API resolution trace")
        end

    else
        _originalSlash(msg)
    end
end
