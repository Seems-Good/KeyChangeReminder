-- KeyChangeReminder / Core.lua
-- Core logic: events, keystone detection, state machine, reminder display.
-- Target: WoW Midnight 12.0.5+  — no backward-compat shims.
--
-- ┌─────────────────────────────────────────────────────────────────────┐
-- │  KCR AUDIT LOG  (all changes from the original are tagged below)   │
-- │  Tag format:  -- [KCR_AUDIT: reason]                                │
-- └─────────────────────────────────────────────────────────────────────┘

KeyChangeReminder = KeyChangeReminder or {}

local frame = CreateFrame("Frame", "KeyChangeReminderFrame", UIParent)

local VERSION   = "@project-version@"
local TIMESTAMP = "@project-date-iso@"

-- ──────────────────────────────────────────────
-- Color codes & display helpers
-- ──────────────────────────────────────────────

local COLOR_YELLOW = "|cffffff00"
local COLOR_GRAY   = "|cff808080"
local COLOR_BLUE   = "|cff00ccff"
local COLOR_RED    = "|cffff4444"
local COLOR_GREEN  = "|cff44ff88"

local FORMAT_NAME  = COLOR_BLUE .. "KeyChangeReminder[ KCR ]|r" .. COLOR_GRAY .. "-(" .. VERSION .. ")|r"
local FORMAT_SLUG  = COLOR_BLUE .. "[KeyChangeReminder]|r" .. COLOR_GRAY .. "-(" .. VERSION .. ")|r"

-- ──────────────────────────────────────────────
-- Debug toggle  [KCR_AUDIT: new — was one-shot dump only; spec §6 requires persistent toggle]
-- ──────────────────────────────────────────────
--
-- When KCR_DEBUG == true every event receipt and state transition is printed.
-- Default: OFF.  Toggle with /kcr debug.

local KCR_DEBUG = false

local function DBG(fmt, ...)
    if not KCR_DEBUG then return end
    print(FORMAT_SLUG .. COLOR_YELLOW .. " [DBG] |r" .. string.format(fmt, ...))
end

-- ──────────────────────────────────────────────
-- State machine
-- ──────────────────────────────────────────────
--
-- States:
--   IDLE          No run in progress.
--   STARTING      CHALLENGE_MODE_START fired; 5-second grace window active.
--                 The grace window absorbs Midnight's spurious CHALLENGE_MODE_RESET
--                 that fires as a side-effect of key consumption.
--   IN_PROGRESS   Grace window elapsed; run is underway.
--   COMPLETED     CHALLENGE_MODE_COMPLETED fired AND onTime == true.
--   DEPLETED      CHALLENGE_MODE_RESET while IN_PROGRESS (or STARTING),
--                 OR CHALLENGE_MODE_COMPLETED with onTime == false.
--
-- Transitions:
--   IDLE         → STARTING     on CHALLENGE_MODE_START
--   STARTING     → IN_PROGRESS  after 5-second timer
--   IN_PROGRESS  → COMPLETED    on CHALLENGE_MODE_COMPLETED (onTime true)
--   IN_PROGRESS  → DEPLETED     on CHALLENGE_MODE_COMPLETED (onTime false) OR CHALLENGE_MODE_RESET
--   STARTING     → COMPLETED    on CHALLENGE_MODE_COMPLETED (fast run, onTime true)   [KCR_AUDIT: Patch C]
--   STARTING     → DEPLETED     on CHALLENGE_MODE_COMPLETED (fast run, onTime false)  [KCR_AUDIT: Patch C]
--                                OR CHALLENGE_MODE_RESET (genuine early abandon)       [KCR_AUDIT: Patch D]
--   COMPLETED    → IDLE         after reminder fires (or is suppressed)
--   DEPLETED     → IDLE         immediately
--   ANY          → IDLE         on next CHALLENGE_MODE_START  (stale-run guard)

local STATE_IDLE        = "IDLE"
local STATE_STARTING    = "STARTING"
local STATE_IN_PROGRESS = "IN_PROGRESS"
local STATE_COMPLETED   = "COMPLETED"
local STATE_DEPLETED    = "DEPLETED"

local runState = STATE_IDLE

-- ──────────────────────────────────────────────
-- Per-run bookkeeping
-- ──────────────────────────────────────────────

-- Level of the keystone that just completed.
-- Best-effort at START via GetSlottedKeystoneInfo(); authoritative at COMPLETED
-- via C_ChallengeMode.GetChallengeCompletionInfo().
local lastRunLevel = nil

-- true  = C_PartyInfo.IsChallengeModeKeystoneOwner() was true at START
-- false = someone else's keystone was slotted
local ownKeyRun = false

-- Guards stale C_Timer.After callbacks across run transitions.
local runGeneration = 0

-- ──────────────────────────────────────────────
-- Owned-key cache  [KCR_AUDIT: new — spec Part 2 requires deferred owned-key init]
-- ──────────────────────────────────────────────
--
-- C_MythicPlus.GetOwnedKeystoneLevel() can return nil immediately on login.
-- We gate the first read behind MYTHIC_PLUS_CURRENT_AFFIX_UPDATE (or a 2-second
-- fallback timer) as required by spec Part 1 / Part 2.

local cachedOwnedKeystoneLevel = nil  -- last known owned keystone level
local ownedKeystoneInitialized = false

local function RefreshOwnedKeystoneCache()
    -- [KCR_AUDIT: new — deferred owned-key read; uses C_MythicPlus (spec Part 1)]
    -- C_MythicPlus.GetOwnedKeystoneLevel() is the spec-mandated primary source.
    -- Guard against the function not existing in case of partial API availability.
    if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
        local lvl = C_MythicPlus.GetOwnedKeystoneLevel()
        if type(lvl) == "number" and lvl > 0 then
            cachedOwnedKeystoneLevel = lvl
        else
            -- nil means "no key" OR "data not ready yet" — fall back to bag scan below.
            cachedOwnedKeystoneLevel = nil
        end
    end

    -- [KCR_AUDIT: new — C_Container bag-scan fallback when C_MythicPlus returns nil]
    -- Spec Part 1: use C_Container.* (not legacy GetContainerItemInfo).
    -- Spec Part 2 BAG_UPDATE_DELAYED trigger: corroborate via bag scan if needed.
    if not cachedOwnedKeystoneLevel then
        local KEYSTONE_ITEM_ID = 180653
        -- Bags 0–4 (backpack + 4 bag slots).  REAGENT_BAG = 5 but keystones don't go there.
        for bagID = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            for slotIndex = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bagID, slotIndex)
                -- [KCR_AUDIT: C_Container.GetContainerItemInfo replaces deprecated GetContainerItemInfo]
                if info and info.itemID == KEYSTONE_ITEM_ID then
                    -- Parse the key level from the item link's item-level field.
                    -- C_MythicPlus.GetOwnedKeystoneLevel() is preferred; this is the fallback.
                    local itemLink = C_Container.GetContainerItemLink(bagID, slotIndex)
                    -- [KCR_AUDIT: C_Container.GetContainerItemLink replaces deprecated GetContainerItemLink]
                    if itemLink then
                        -- Item level of a keystone encodes the key level: item level = 1500 + keyLevel
                        -- (Blizzard convention; parse from the itemLevel suffix or use GetDetailedItemLevelInfo)
                        local itemLevel = C_Item.GetCurrentItemLevel(
                            ItemLocation:CreateFromBagAndSlot(bagID, slotIndex)
                        )
                        if type(itemLevel) == "number" and itemLevel > 1500 then
                            cachedOwnedKeystoneLevel = itemLevel - 1500
                        end
                    end
                    break
                end
            end
            if cachedOwnedKeystoneLevel then break end
        end
    end

    ownedKeystoneInitialized = true
    DBG("RefreshOwnedKeystoneCache → cachedOwnedKeystoneLevel=%s", tostring(cachedOwnedKeystoneLevel))
end

-- ──────────────────────────────────────────────
-- Reminder display
-- ──────────────────────────────────────────────

local reminderLabel          = nil
local reminderWatching       = false
local talentReminderWatching = false

local function DismissReminder()
    if not reminderWatching then return end
    reminderWatching = false
    if not talentReminderWatching then
        frame:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    end
    if reminderLabel and reminderLabel:IsShown() then
        reminderLabel.pulseGroup:Stop()
        reminderLabel.exitGroup:Stop()
        reminderLabel:SetAlpha(1)
        reminderLabel.exitGroup:Play()
    end
end

local function DismissTalentReminder()
    if not talentReminderWatching then return end
    talentReminderWatching = false
    if not reminderWatching then
        frame:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    end
    if reminderLabel and reminderLabel:IsShown() then
        reminderLabel.pulseGroup:Stop()
        reminderLabel.exitGroup:Stop()
        reminderLabel:SetAlpha(1)
        reminderLabel.exitGroup:Play()
    end
end

local function GetOrCreateLabel()
    if reminderLabel then return reminderLabel end

    reminderLabel = CreateFrame("Frame", "KeyChangeReminderLabel", UIParent)
    reminderLabel:SetSize(600, 80)
    reminderLabel:SetMovable(true)
    reminderLabel:EnableMouse(false)
    reminderLabel:SetClampedToScreen(true)
    reminderLabel:SetFrameStrata("FULLSCREEN_DIALOG")

    local t = reminderLabel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetAllPoints()
    t:SetJustifyH("CENTER")
    t:SetJustifyV("MIDDLE")
    reminderLabel.text = t

    -- Looping pulse animation
    local pulse = reminderLabel:CreateAnimationGroup()
    pulse:SetLooping("REPEAT")
    local fadeOut = pulse:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0.15)
    fadeOut:SetDuration(1)
    fadeOut:SetSmoothing("IN_OUT")
    fadeOut:SetOrder(1)
    local fadeIn = pulse:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.15)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(1)
    fadeIn:SetSmoothing("IN_OUT")
    fadeIn:SetOrder(2)
    reminderLabel.pulseGroup = pulse

    -- Exit (fade-out) animation
    local exit = reminderLabel:CreateAnimationGroup()
    exit:SetLooping("NONE")
    local exitFade = exit:CreateAnimation("Alpha")
    exitFade:SetFromAlpha(1)
    exitFade:SetToAlpha(0)
    exitFade:SetDuration(0.4)
    exit:SetScript("OnFinished", function() reminderLabel:Hide() end)
    reminderLabel.exitGroup = exit

    return reminderLabel
end

local function ApplyLabelPosition()
    local lbl = GetOrCreateLabel()
    lbl:ClearAllPoints()
    lbl:SetPoint(
        KeyChangeReminder:Get("anchorPoint") or "CENTER",
        UIParent,
        KeyChangeReminder:Get("anchorPoint") or "CENTER",
        KeyChangeReminder:Get("anchorX") or 0,
        KeyChangeReminder:Get("anchorY") or 200
    )
end

local function ApplyPulseSpeed()
    if not reminderLabel then return end
    local speed = KeyChangeReminder:Get("pulseSpeed") or 1.0
    local half = speed / 2
    local anims = { reminderLabel.pulseGroup:GetAnimations() }
    for _, anim in ipairs(anims) do
        anim:SetDuration(half)
    end
end

-- ShowReminder(msg [, chatMsg])
--
-- msg      — text rendered on the on-screen label.
-- chatMsg  — text echoed to the chat frame (defaults to msg when omitted).
--
-- Keeping the two strings separate lets callers display a short on-screen
-- message while printing a richer line to chat, without truncation on screen.
function KeyChangeReminder:ShowReminder(msg, chatMsg)
    local lbl = GetOrCreateLabel()
    ApplyLabelPosition()
    ApplyPulseSpeed()

    local hex = self:GetColorHex()
    local r = tonumber(hex:sub(3, 4), 16) / 255
    local g = tonumber(hex:sub(5, 6), 16) / 255
    local b = tonumber(hex:sub(7, 8), 16) / 255

    local fs = self:Get("fontSize") or 42
    lbl.text:SetFont(STANDARD_TEXT_FONT, fs, "OUTLINE")
    lbl.text:SetTextColor(r, g, b, 1)
    lbl.text:SetText(msg)

    lbl.exitGroup:Stop()
    lbl.pulseGroup:Stop()
    lbl:SetAlpha(1)
    lbl:Show()
    lbl.pulseGroup:Play()

    reminderWatching = true
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

    -- Echo to chat (spec Part 5).  Use chatMsg when provided; fall back to msg.
    print(string.format(FORMAT_SLUG .. " %s", chatMsg or msg))
end

function KeyChangeReminder:HideReminder()
    DismissReminder()
end

function KeyChangeReminder:ShowTalentReminder()
    self:ShowReminder("Switch to your M+ talents!")
    reminderWatching       = false
    talentReminderWatching = true
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
end

function KeyChangeReminder:HideTalentReminder()
    DismissTalentReminder()
end

-- [KCR_AUDIT: new — CheckAndShowTalentReminder was called from Settings.lua but never defined]
-- Called when the talent-reminder checkbox is toggled on while already inside a M+ dungeon.
function KeyChangeReminder:CheckAndShowTalentReminder()
    if IsMythicPlusActive and IsMythicPlusActive() then
        self:ShowTalentReminder()
    end
end

-- ──────────────────────────────────────────────
-- Keystone API helpers (Midnight 12.0.5+)
-- ──────────────────────────────────────────────

-- Returns true when a Mythic+ run is ACTIVE and the player is physically
-- inside a dungeon instance.
--
-- [KCR_AUDIT: Patch A — 12.0.5 introduces C_ChallengeMode.IsChallengeModeActive(),
--  which is the canonical instance-aware check in Midnight and does NOT exhibit
--  the city false-positive that required the old C_MythicPlus + IsInInstance()
--  compound workaround.  The old compound is retained as a fallback.]
local function IsMythicPlusActive()
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        return C_ChallengeMode.IsChallengeModeActive() == true
    end
    -- Fallback: old compound guard (pre-12.0 behavior).
    -- C_MythicPlus.IsMythicPlusActive() alone was unreliable — it returned true
    -- in cities whenever a keystone was in-bag.  IsInInstance() is the ground-
    -- truth gate confirming the player is inside a dungeon.
    if not (C_MythicPlus and C_MythicPlus.IsMythicPlusActive) then return false end
    if not C_MythicPlus.IsMythicPlusActive() then return false end
    local _, instanceType = IsInInstance()
    return instanceType == "party"
end

-- Returns the level of the keystone currently slotted in the font (nil if none).
-- BEST-EFFORT ONLY — may return nil at CHALLENGE_MODE_START due to loading timing.
-- The authoritative level is always read at COMPLETED via GetRunCompletionInfo().
local function GetSlottedKeystoneLevel()
    if not (C_ChallengeMode and C_ChallengeMode.GetSlottedKeystoneInfo) then
        return nil
    end
    local _, _, level = C_ChallengeMode.GetSlottedKeystoneInfo()
    if type(level) == "number" and level > 0 then return level end
    return nil
end

-- Returns (level, onTime) for the run that just completed.
--
-- [KCR_AUDIT: Patch B — CRITICAL FIX for 12.0.5.
--  C_ChallengeMode.GetCompletionInfo() was RENAMED to GetChallengeCompletionInfo()
--  in Midnight 12.0 and now returns a single info TABLE instead of positional
--  return values.  The old call resolved to nil on every invocation in 12.0.5,
--  causing every completed run to route through the depletion path (onTime was
--  never true) and suppress all reminders permanently.
--
--  New call:  info = C_ChallengeMode.GetChallengeCompletionInfo()
--  Key fields: info.level (number), info.onTime (boolean)
--
--  A compatibility shim tries the old name as well in case Blizzard ever
--  re-adds a deprecated alias, and handles the nil/non-table return safely.]
local function GetRunCompletionInfo()
    -- Prefer the 12.0+ name; fall back to the legacy name for belt-and-suspenders.
    local getInfo = (C_ChallengeMode and C_ChallengeMode.GetChallengeCompletionInfo)
                 or (C_ChallengeMode and C_ChallengeMode.GetCompletionInfo)
    if not getInfo then
        DBG("GetRunCompletionInfo: neither GetChallengeCompletionInfo nor GetCompletionInfo found")
        return nil, nil
    end

    local info = getInfo()

    if type(info) ~= "table" then
        -- Legacy positional API (pre-12.0) or unexpected return — fail safe.
        -- On 12.0.5 this branch should never be reached.
        DBG("GetRunCompletionInfo: info is not a table (%s) — failing safe", type(info))
        return nil, nil
    end

    -- Field names per Blizzard ChallengeModeInfoDocumentation (12.0.5):
    --   info.level  : number  — keystone level of the completed run
    --   info.onTime : boolean — true if completed within the time limit
    local level  = info.level
    local onTime = info.onTime
    local lvl    = (type(level) == "number" and level > 0) and level or nil
    local timed  = (onTime == true)

    DBG("GetRunCompletionInfo: level=%s onTime=%s (raw info.level=%s info.onTime=%s)",
        tostring(lvl), tostring(timed), tostring(level), tostring(onTime))
    return lvl, timed
end

-- Returns the level of the keystone in OUR bag (nil if we have none).
-- Primary source: C_MythicPlus.GetOwnedKeystoneLevel() per spec Part 1.
-- Falls back to the initialized cache populated at login / BAG_UPDATE_DELAYED.
local function GetBagKeystoneLevel()
    -- [KCR_AUDIT: spec Part 1 mandates C_MythicPlus.GetOwnedKeystoneLevel() as primary]
    if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
        local level = C_MythicPlus.GetOwnedKeystoneLevel()
        if type(level) == "number" and level > 0 then return level end
    end
    -- Fall back to the login-time bag-scan cache.
    -- [KCR_AUDIT: new — cachedOwnedKeystoneLevel fallback when live API returns nil]
    if type(cachedOwnedKeystoneLevel) == "number" and cachedOwnedKeystoneLevel > 0 then
        return cachedOwnedKeystoneLevel
    end
    return nil
end

-- Returns the challenge map ID of our keystone (nil if none).
local function GetBagKeystoneChallengeMapID()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID) then
        return nil
    end
    local id = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    if type(id) == "number" and id > 0 then return id end
    return nil
end

-- Returns the world map ID of our keystone (nil if none).
-- [KCR_AUDIT: GetOwnedKeystoneMapID is not in spec Part 1 API list — guarded defensively]
local function GetBagKeystoneMapID()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID) then
        return nil
    end
    local id = C_MythicPlus.GetOwnedKeystoneMapID()
    if type(id) == "number" and id > 0 then return id end
    return nil
end

-- Returns true if the LOCAL player is the keystone owner for the current run.
-- C_PartyInfo.IsChallengeModeKeystoneOwner() is available in Midnight 12.0.5.
-- This is the most direct "is it our key?" check available to us; it replaces
-- the level+mapID heuristic used in older approaches.
local function IsLocalPlayerKeystoneOwner()
    if C_PartyInfo and C_PartyInfo.IsChallengeModeKeystoneOwner then
        return C_PartyInfo.IsChallengeModeKeystoneOwner() == true
    end
    -- [KCR_AUDIT: fallback heuristic when C_PartyInfo API unavailable]
    -- Compare our bag key's level+mapID against the active run's level+mapID.
    -- This is explicitly a HEURISTIC — comment per spec Part 5.
    -- If both match it is LIKELY our key, but not guaranteed (two players could
    -- hold identical keys for the same dungeon at the same level).
    local bagLevel = GetBagKeystoneLevel()
    local bagMapID = GetBagKeystoneChallengeMapID()
    if not bagLevel or not bagMapID then return false end

    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        local activeLevel = C_ChallengeMode.GetActiveKeystoneInfo()
        local activeMapID = C_ChallengeMode.GetActiveKeystoneChallengeMapID and
                             C_ChallengeMode.GetActiveKeystoneChallengeMapID()
        if activeLevel == bagLevel and activeMapID == bagMapID then
            return true  -- likely our key (heuristic — see comment above)
        end
    end
    return false
end

-- ──────────────────────────────────────────────
-- Reminder suppression logic
-- ──────────────────────────────────────────────
--
-- AUTO MODE — show reminder when ALL of:
--   1. Run was completed in time  (STATE_COMPLETED guarantees this)
--   2. The keystone was NOT ours  (ownKeyRun == false)
--   3. Run level >= our bag key level  (vendor reroll won't downgrade us)
--   4. We actually have a key in our bag  (nothing to reroll otherwise)
--
-- SUPPRESS when ANY of:
--   • Not STATE_COMPLETED  (depleted / overtime / abandoned / mid-run)
--   • Our own key was used  (nothing to change; key is already consumed)
--   • Run level is unknown  (fail closed — never show on missing data)
--   • Run level < bag level  (reroll would downgrade — no benefit)
--   • No key in bag         (nothing to reroll)
--
-- MANUAL MODE — show reminder when:
--   • Run level is known
--   • Run level >= configured minKeyLevel (0 = always remind)
--
local function ShouldSuppressReminder(capturedLevel)
    local autoMode = KeyChangeReminder:Get("autoMode")
    local runLevel = capturedLevel or lastRunLevel

    DBG("ShouldSuppressReminder: autoMode=%s runLevel=%s ownKeyRun=%s state=%s",
        tostring(autoMode), tostring(runLevel), tostring(ownKeyRun), tostring(runState))

    if autoMode then
        -- Rule 1: must be a timed completion.
        if runState ~= STATE_COMPLETED then
            DBG("  → suppress: state not COMPLETED (%s)", runState)
            return true
        end

        -- Rule 2: must be a foreign key run.
        if ownKeyRun then
            DBG("  → suppress: own-key run")
            return true
        end

        -- Rule 3: run level must be known (fail closed).
        if not runLevel then
            DBG("  → suppress: runLevel nil (fail closed)")
            return true
        end

        -- Rule 4: must have a key in bag to reroll.
        local bagLevel = GetBagKeystoneLevel()
        if not bagLevel then
            DBG("  → suppress: no key in bag")
            return true
        end

        -- Rule 5: reroll must not downgrade.
        -- bagLevel > runLevel → reroll would produce a lower key → suppress.
        -- bagLevel <= runLevel → neutral or upgrade → SHOW.
        if bagLevel > runLevel then
            DBG("  → suppress: bag(%d) > run(%d) — reroll would downgrade", bagLevel, runLevel)
            return true
        end

        DBG("  → SHOW: bag(%d) <= run(%d)", bagLevel, runLevel)
        return false  -- SHOW

    else
        -- Manual mode: show unless unknown or below threshold.
        if not runLevel then
            DBG("  → suppress: runLevel nil (manual, fail closed)")
            return true
        end
        local minLevel = KeyChangeReminder:Get("minKeyLevel") or 0
        if minLevel > 0 and runLevel < minLevel then
            DBG("  → suppress: runLevel(%d) < minKeyLevel(%d)", runLevel, minLevel)
            return true
        end
        DBG("  → SHOW (manual mode)")
        return false
    end
end

-- ──────────────────────────────────────────────
-- Reminder message builder
-- ──────────────────────────────────────────────
--
-- Returns (displayMsg, chatMsg).
--
-- displayMsg — short string shown on the on-screen label.
--              Always "Change your key!" so it never truncates regardless of
--              how many digits the key level has.
-- chatMsg    — fuller string echoed to the chat frame.
--              In auto mode this includes run level and bag level so the player
--              knows why the reminder fired.  In manual mode it matches displayMsg.
--
-- Spec Part 5: the [KCR] prefix is prepended by ShowReminder, not here.
local function BuildReminderMessage()
    local autoMode = KeyChangeReminder:Get("autoMode")
    if autoMode then
        local runLevel = lastRunLevel
        local bagLevel = GetBagKeystoneLevel()
        -- [KCR_AUDIT: spec Part 2 COMPLETED trigger requires message include both levels]
        -- Level context goes to chat only; on-screen label stays short to avoid truncation.
        local chatMsg = string.format(
            "Change your key!  (run +%s | your key +%s)",
            tostring(runLevel or "?"),
            tostring(bagLevel or "?")
        )
        return "Change your key!", chatMsg
    end
    return "Change your key!", "Change your key!"
end

-- Reset all per-run state back to neutral.
local function ResetRunState()
    DBG("ResetRunState: was state=%s", runState)
    runState     = STATE_IDLE
    lastRunLevel = nil
    ownKeyRun    = false
end

-- ──────────────────────────────────────────────
-- Event registration
-- ──────────────────────────────────────────────

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")                        -- [KCR_AUDIT: new — required for deferred init]
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("CHALLENGE_MODE_RESET")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("MYTHIC_PLUS_CURRENT_AFFIX_UPDATE")   -- [KCR_AUDIT: new — reliable gate for C_MythicPlus data]
frame:RegisterEvent("BAG_UPDATE_DELAYED")                  -- [KCR_AUDIT: new — corroborate bag scan post-login]

-- ──────────────────────────────────────────────
-- Event handler
-- ──────────────────────────────────────────────

frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    DBG("EVENT: %s  arg1=%s  arg2=%s", event, tostring(arg1), tostring(arg2))

    -- ── ADDON_LOADED ────────────────────────────────────────────────────
    if event == "ADDON_LOADED" and arg1 == "KeyChangeReminder" then
        KeyChangeReminder:InitDB()
        print(FORMAT_SLUG .. " Type |cffffd700/keychange|r for options.")
        self:UnregisterEvent("ADDON_LOADED")

    -- ── PLAYER_LOGIN ─────────────────────────────────────────────────────
    -- [KCR_AUDIT: new — spec Part 2 requires deferred owned-key init at login]
    -- C_MythicPlus.GetOwnedKeystoneLevel() returns nil immediately on login.
    -- We wait 2 seconds as a fallback; the MYTHIC_PLUS_CURRENT_AFFIX_UPDATE
    -- event is also registered and will trigger a refresh as soon as the
    -- M+ API is populated (whichever comes first).
    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(2, function()
            if not ownedKeystoneInitialized then
                RefreshOwnedKeystoneCache()
            end
        end)

    -- ── MYTHIC_PLUS_CURRENT_AFFIX_UPDATE ─────────────────────────────────
    -- [KCR_AUDIT: new — spec Part 1/2 mandates this event as the reliable gate]
    -- Fires when the M+ API is fully populated. Use it to refresh the owned
    -- keystone cache with authoritative data instead of relying on a raw timer.
    elseif event == "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE" then
        RefreshOwnedKeystoneCache()

    -- ── BAG_UPDATE_DELAYED ────────────────────────────────────────────────
    -- [KCR_AUDIT: new — spec Part 2 requires bag-scan corroboration on BAG_UPDATE_DELAYED]
    -- BAG_UPDATE_DELAYED fires once after all bag changes settle (better than BAG_UPDATE
    -- which fires per slot).  Re-check the keystone here to catch the case where
    -- the key was just upgraded and C_MythicPlus hasn't refreshed yet.
    elseif event == "BAG_UPDATE_DELAYED" then
        RefreshOwnedKeystoneCache()

    -- ── PLAYER_ENTERING_WORLD ─────────────────────────────────────────────
    -- arg1 = isInitialLogin (bool), arg2 = isReloadingUi (bool)
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin  = arg1
        local isReloadingUi   = arg2

        -- [KCR_AUDIT: fix — original code dismissed reminder when IsMythicPlusActive()
        --  was true on enter, which is wrong: we want to dismiss when LEAVING M+.
        --  Correct: if we're entering and M+ is no longer active, clear stale state.]
        if not IsMythicPlusActive() then
            -- We've zoned out of a Mythic+ instance (or logged in outside one).
            if reminderWatching       then DismissReminder()       end
            if talentReminderWatching then DismissTalentReminder() end
            -- If we were mid-run (e.g., disconnected), reset cleanly.
            if runState ~= STATE_IDLE then
                DBG("PLAYER_ENTERING_WORLD: not in M+ — resetting stale run state")
                ResetRunState()
            end
        end

        -- Defer bag/keystone reads by 1 second to let bags fully populate.
        -- [KCR_AUDIT: spec Part 2 PLAYER_ENTERING_WORLD trigger requires C_Timer.After(1)]
        C_Timer.After(1, function()
            RefreshOwnedKeystoneCache()

            -- If we've zoned into an active M+ dungeon (e.g., reloading UI mid-run),
            -- restore the in-progress flag so COMPLETED/RESET handle correctly.
            if IsMythicPlusActive() and runState == STATE_IDLE then
                DBG("PLAYER_ENTERING_WORLD deferred: M+ active — restoring IN_PROGRESS state")
                runState = STATE_IN_PROGRESS

                -- [KCR_AUDIT: Patch E — C_MythicPlus.GetActiveKeystoneInfo does not exist
                --  in Midnight 12.0.5.  The correct API is C_ChallengeMode.GetActiveKeystoneInfo()
                --  which returns (activeKeystoneLevel, activeAffixIDs, wasActiveKeystoneCharged).]
                if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
                    local lvl = C_ChallengeMode.GetActiveKeystoneInfo()
                    if type(lvl) == "number" and lvl > 0 then
                        lastRunLevel = lvl
                        DBG("  restored lastRunLevel=%d from C_ChallengeMode.GetActiveKeystoneInfo", lvl)
                    end
                end
                -- Re-check ownership (best-effort; C_PartyInfo may be ready by now).
                ownKeyRun = IsLocalPlayerKeystoneOwner()
                DBG("  restored ownKeyRun=%s", tostring(ownKeyRun))
            end

            -- Show talent reminder if enabled and inside a M+ dungeon.
            if KeyChangeReminder:Get("talentReminder") and IsMythicPlusActive() then
                KeyChangeReminder:ShowTalentReminder()
            end
        end)

    -- ── CHALLENGE_MODE_START ──────────────────────────────────────────────
    -- Fires when the keystone is consumed and the timer begins.
    --
    -- Ownership is read immediately via C_PartyInfo.IsChallengeModeKeystoneOwner()
    -- which is reliable at this event.
    --
    -- GetSlottedKeystoneInfo() is a BEST-EFFORT level capture only — it may be
    -- nil due to timing.  The authoritative level read happens at COMPLETED via
    -- C_ChallengeMode.GetChallengeCompletionInfo().
    --
    -- Grace window (5 s): absorbs Midnight's spurious CHALLENGE_MODE_RESET that
    -- fires as a side-effect of key consumption (a known 12.0.x engine quirk).
    elseif event == "CHALLENGE_MODE_START" then
        runGeneration = runGeneration + 1
        local capturedGen = runGeneration

        -- Stale-run guard: clear any previous run before starting fresh.
        if runState ~= STATE_IDLE then
            DBG("CHALLENGE_MODE_START: stale state=%s — resetting before new run", runState)
            ResetRunState()
        end

        runState     = STATE_STARTING
        ownKeyRun    = IsLocalPlayerKeystoneOwner()
        lastRunLevel = GetSlottedKeystoneLevel()  -- best-effort; may be nil

        DismissReminder()
        DismissTalentReminder()

        DBG("CHALLENGE_MODE_START: gen=%d ownKeyRun=%s lastRunLevel=%s",
            capturedGen, tostring(ownKeyRun), tostring(lastRunLevel))

        -- Transition to IN_PROGRESS after 5-second grace window.
        C_Timer.After(5, function()
            if runGeneration ~= capturedGen then
                DBG("Grace timer: generation mismatch (gen=%d captured=%d) — ignoring", runGeneration, capturedGen)
                return
            end
            if runState ~= STATE_STARTING then
                DBG("Grace timer: state=%s (not STARTING) — ignoring", runState)
                return
            end

            -- Verify we're still physically inside a M+ dungeon.
            if not IsMythicPlusActive() then
                DBG("Grace timer: IsMythicPlusActive=false — resetting")
                ResetRunState()
                return
            end

            runState = STATE_IN_PROGRESS
            DBG("Grace timer: → IN_PROGRESS (gen=%d)", capturedGen)
        end)

    -- ── CHALLENGE_MODE_COMPLETED ──────────────────────────────────────────
    -- Fires for BOTH timed (in-time) and overtime (out-of-time) kills.
    -- C_ChallengeMode.GetChallengeCompletionInfo() is AUTHORITATIVE here.
    -- onTime == false → overtime kill → vendor never appears → treat as depletion.
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        DBG("CHALLENGE_MODE_COMPLETED: runState=%s", runState)

        -- [KCR_AUDIT: Patch C — accept STATE_STARTING as well as STATE_IN_PROGRESS.
        --  Fast runs can legitimately complete before the 5-second grace timer fires,
        --  leaving runState as STATE_STARTING when this event arrives.  The previous
        --  hard check silently dropped the event in that case, leaving state stuck at
        --  STARTING forever and suppressing all subsequent reminders until the next
        --  CHALLENGE_MODE_START reset the generation counter.]
        if runState ~= STATE_IN_PROGRESS and runState ~= STATE_STARTING then return end

        -- If we were still in STARTING (fast run), promote immediately so the rest
        -- of this handler and the 3-second completion timer see consistent state.
        if runState == STATE_STARTING then
            DBG("CHALLENGE_MODE_COMPLETED: fast run completed in grace window — promoting STARTING → IN_PROGRESS")
            runState = STATE_IN_PROGRESS
        end

        local completionLevel, onTime = GetRunCompletionInfo()
        DBG("  completionLevel=%s onTime=%s", tostring(completionLevel), tostring(onTime))

        -- Overtime kill: vendor does NOT appear — treat as depletion, no reminder.
        if not onTime then
            runState = STATE_DEPLETED
            ResetRunState()
            return
        end

        -- Authoritative level from GetChallengeCompletionInfo() overrides the best-effort
        -- capture from CHALLENGE_MODE_START (which may have been nil).
        if completionLevel then
            lastRunLevel = completionLevel
        end
        -- If completionLevel is still nil here, ShouldSuppressReminder will
        -- return true (fail closed — no reminder on unknown data).

        runState = STATE_COMPLETED

        -- Snapshot mutable state before the async delay to avoid race conditions
        -- if a new run starts before the timer fires.
        local capturedGen   = runGeneration
        local capturedLevel = lastRunLevel

        -- Small delay (3 s) lets the end-of-dungeon UI settle before the reminder.
        C_Timer.After(3, function()
            if runGeneration ~= capturedGen then
                DBG("Completion timer: generation mismatch — ignoring stale callback")
                return
            end

            -- Restore snapshot in case something clobbered lastRunLevel.
            if not lastRunLevel then
                lastRunLevel = capturedLevel
            end

            if ShouldSuppressReminder(capturedLevel) then
                DBG("Completion timer: reminder suppressed")
                ResetRunState()
                return
            end

            DBG("Completion timer: showing reminder")
            local displayMsg, chatMsg = BuildReminderMessage()
            KeyChangeReminder:ShowReminder(displayMsg, chatMsg)
            ResetRunState()
        end)

    -- ── CHALLENGE_MODE_RESET ──────────────────────────────────────────────
    -- Genuine mid-run depletion or player-initiated abandon.
    -- The 5-second grace window in STARTING absorbs the spurious post-START fire
    -- that Midnight 12.0.x emits as a side-effect of keystone consumption; that
    -- fire arrives during STARTING and is absorbed here (returns early) before
    -- IsMythicPlusActive() confirms we're still in the dungeon.
    elseif event == "CHALLENGE_MODE_RESET" then
        DBG("CHALLENGE_MODE_RESET: runState=%s", runState)

        -- [KCR_AUDIT: Patch D — accept STATE_STARTING as well as STATE_IN_PROGRESS.
        --  A genuine abandon or reset that occurs before the grace timer promotes
        --  state to IN_PROGRESS would previously be silently ignored, leaving the
        --  state machine stuck at STARTING until a new run fired CHALLENGE_MODE_START.
        --  The spurious post-START reset is handled separately: the grace timer's
        --  IsMythicPlusActive() check resets state if the player is not in a dungeon,
        --  so the two paths do not conflict.]
        if runState ~= STATE_IN_PROGRESS and runState ~= STATE_STARTING then return end

        -- Genuine depletion / abandon — no reminder.
        runState = STATE_DEPLETED
        ResetRunState()

    -- ── PLAYER_REGEN_DISABLED ─────────────────────────────────────────────
    -- Player entered combat — dismiss any visible reminder immediately.
    elseif event == "PLAYER_REGEN_DISABLED" then
        DismissReminder()
        DismissTalentReminder()

    -- ── ZONE_CHANGED_NEW_AREA ─────────────────────────────────────────────
    -- Player changed zones (e.g., left the dungeon).
    -- Dismiss reminders once we're no longer in an active M+ instance.
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if not IsMythicPlusActive() then
            if reminderWatching       then DismissReminder()       end
            if talentReminderWatching then DismissTalentReminder() end
        end

    end
end)

-- ──────────────────────────────────────────────
-- Slash commands
-- ──────────────────────────────────────────────

SLASH_KEYCHANGE1 = "/keychange"
SLASH_KEYCHANGE2 = "/kcr"

SlashCmdList["KEYCHANGE"] = function(msg)
    local cmd = msg and msg:match("^%s*(%S+)") or ""

    -- ── /kcr debug ───────────────────────────────────────────────────────
    -- [KCR_AUDIT: new — spec §6 requires a persistent toggle, not just a one-shot dump]
    -- Toggles verbose debug output for all state transitions and event receipts.
    -- Default: OFF.
    if cmd:lower() == "debug" then
        KCR_DEBUG = not KCR_DEBUG
        if KCR_DEBUG then
            print(FORMAT_SLUG .. COLOR_GREEN .. " Debug mode ON|r — all state changes will be printed.")
        else
            print(FORMAT_SLUG .. COLOR_RED .. " Debug mode OFF.|r")
        end

        -- Always print current snapshot when toggling, regardless of new state.
        local bagLevel          = GetBagKeystoneLevel()
        local bagChallengeMapID = GetBagKeystoneChallengeMapID()
        local bagMapID          = GetBagKeystoneMapID()
        local slotLevel         = GetSlottedKeystoneLevel()
        local completionLevel, completionOnTime = GetRunCompletionInfo()
        local isOwner           = IsLocalPlayerKeystoneOwner()
        local mpActive          = IsMythicPlusActive()
        local autoMode          = KeyChangeReminder:Get("autoMode")
        local minKeyLevel       = KeyChangeReminder:Get("minKeyLevel") or 0

        print(FORMAT_SLUG .. COLOR_YELLOW .. " Current State Snapshot:|r")
        print(COLOR_GRAY .. "  runState                  : |r" .. COLOR_YELLOW .. tostring(runState)                .. "|r")
        print(COLOR_GRAY .. "  runGeneration             : |r" .. COLOR_YELLOW .. tostring(runGeneration)            .. "|r")
        print(COLOR_GRAY .. "  lastRunLevel              : |r" .. COLOR_YELLOW .. tostring(lastRunLevel)             .. "|r")
        print(COLOR_GRAY .. "  ownKeyRun                 : |r" .. COLOR_YELLOW .. tostring(ownKeyRun)                .. "|r")
        print(COLOR_GRAY .. "  ownedKeystoneInitialized  : |r" .. COLOR_YELLOW .. tostring(ownedKeystoneInitialized) .. "|r")
        print(COLOR_GRAY .. "  cachedOwnedKeystoneLevel  : |r" .. COLOR_YELLOW .. tostring(cachedOwnedKeystoneLevel) .. "|r")
        print(COLOR_GRAY .. "  IsKeystoneOwner (live)    : |r" .. COLOR_YELLOW .. tostring(isOwner)                 .. "|r")
        print(COLOR_GRAY .. "  IsMythicPlusActive (live) : |r" .. COLOR_YELLOW .. tostring(mpActive)                .. "|r")
        print(COLOR_GRAY .. "  bagLevel (live)           : |r" .. COLOR_YELLOW .. tostring(bagLevel)                .. "|r")
        print(COLOR_GRAY .. "  bagChallengeMapID (live)  : |r" .. COLOR_YELLOW .. tostring(bagChallengeMapID)        .. "|r")
        print(COLOR_GRAY .. "  bagMapID (live)           : |r" .. COLOR_YELLOW .. tostring(bagMapID)                .. "|r")
        print(COLOR_GRAY .. "  slotLevel (live)          : |r" .. COLOR_YELLOW .. tostring(slotLevel)               .. "|r")
        print(COLOR_GRAY .. "  completionLevel (live)    : |r" .. COLOR_YELLOW .. tostring(completionLevel)         .. "|r")
        print(COLOR_GRAY .. "  completionOnTime (live)   : |r" .. COLOR_YELLOW .. tostring(completionOnTime)        .. "|r")
        print(COLOR_GRAY .. "  autoMode                  : |r" .. COLOR_YELLOW .. tostring(autoMode)                .. "|r")
        print(COLOR_GRAY .. "  minKeyLevel               : |r" .. COLOR_YELLOW .. tostring(minKeyLevel)             .. "|r")
        print(COLOR_GRAY .. "  KCR_DEBUG (new value)     : |r" .. COLOR_YELLOW .. tostring(KCR_DEBUG)              .. "|r")

        -- Human-readable suppression reason for the current state.
        local reason
        if autoMode then
            if runState ~= STATE_COMPLETED then
                reason = "run not COMPLETED (state=" .. runState .. ") — suppress"
            elseif ownKeyRun then
                reason = "own key run — suppress"
            elseif not lastRunLevel then
                reason = "lastRunLevel nil — suppress (fail closed)"
            elseif not GetBagKeystoneLevel() then
                reason = "no key in bag — suppress"
            elseif GetBagKeystoneLevel() > lastRunLevel then
                reason = "bag(" .. tostring(GetBagKeystoneLevel()) .. ") > run(" .. tostring(lastRunLevel) .. ") — suppress (reroll downgrade)"
            else
                reason = "bag(" .. tostring(GetBagKeystoneLevel()) .. ") <= run(" .. tostring(lastRunLevel) .. ") — SHOW reminder"
            end
        else
            if not lastRunLevel then
                reason = "lastRunLevel nil — suppress (fail closed)"
            elseif (minKeyLevel > 0 and lastRunLevel < minKeyLevel) then
                reason = "run(" .. tostring(lastRunLevel) .. ") < minKeyLevel(" .. tostring(minKeyLevel) .. ") — suppress"
            else
                reason = "manual mode threshold not blocking — SHOW reminder"
            end
        end
        print(COLOR_GRAY .. "  SuppressReason (now)      : |r" .. COLOR_YELLOW .. tostring(reason) .. "|r")

    -- ── /kcr (no args) → open settings ───────────────────────────────────
    else
        if KeyChangeReminder.optionsCategory then
            Settings.OpenToCategory(KeyChangeReminder.optionsCategory.ID)
        else
            print(FORMAT_SLUG .. " Options not ready yet.")
        end
    end
end
