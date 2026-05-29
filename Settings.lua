-- KeyChangeReminderSettings.lua
-- Default settings, SavedVariables helpers, and the Settings panel UI.
-- (Merged from Config.lua + Options.lua)

KeyChangeReminder = KeyChangeReminder or {}

-- ──────────────────────────────────────────────
-- Default settings & DB helpers
-- ──────────────────────────────────────────────

-- Account-wide defaults (NOT raid talent keys — those are per-character)
local DEFAULTS = {
    enabled        = true,
    minKeyLevel    = 0,          -- 0 = always remind regardless of key level
    autoMode       = false,      -- Auto mode off by default
    color          = "CYAN",     -- preset name
    anchorPoint    = "CENTER",   -- WoW anchor point
    anchorX        = 0,
    anchorY        = 200,
    fontSize       = 42,
    pulseSpeed     = 1.0,        -- seconds per half-cycle (0.3 = fast, 2.0 = slow)
    talentReminder = false,      -- off by default
}

-- Per-character defaults (raid talent reminder — each class/spec has its own loadouts)
-- [KCR_RTR_AUDIT: moved raidTalentReminder and raidTalentNames from account-wide DEFAULTS
--  to CHAR_DEFAULTS so each character maintains its own independent list of saved raid
--  loadout names.  Stored in KeyChangeReminderCharDB via SavedVariablesPerCharacter.]
local CHAR_DEFAULTS = {
    raidTalentReminder = false,  -- master toggle for raid loadout check
    raidTalentNames    = {},     -- list of loadout names to require in raid
}

-- Color presets (label -> hex AARRGGBB)
KeyChangeReminder.COLOR_PRESETS = {
    RED    = "ffff3333",
    ORANGE = "ffff9900",
    YELLOW = "ffffff00",
    WHITE  = "ffffffff",
    CYAN   = "ff00ccff",
    GREEN  = "ff00ff88",
}

-- ── Account-wide DB ────────────────────────────────────────────────────────

function KeyChangeReminder:InitDB()
    if not KeyChangeReminderDB then
        KeyChangeReminderDB = {}
    end
    for k, v in pairs(DEFAULTS) do
        if KeyChangeReminderDB[k] == nil then
            if type(v) == "table" then
                local copy = {}
                for k2, v2 in pairs(v) do copy[k2] = v2 end
                KeyChangeReminderDB[k] = copy
            else
                KeyChangeReminderDB[k] = v
            end
        end
    end
    self.db = KeyChangeReminderDB

    -- Always initialise the per-character DB at the same time.
    self:InitCharDB()
end

function KeyChangeReminder:Get(key)
    return self.db and self.db[key]
end

function KeyChangeReminder:Set(key, value)
    if self.db then
        self.db[key] = value
    end
end

-- ── Per-character DB ───────────────────────────────────────────────────────
-- [KCR_RTR_AUDIT: new — raid talent settings are per-character because every
--  class/spec has different talent loadout names.  Uses a separate
--  SavedVariablesPerCharacter table (KeyChangeReminderCharDB) declared in the
--  TOC so WoW automatically scopes it to the logged-in character.]

function KeyChangeReminder:InitCharDB()
    if not KeyChangeReminderCharDB then
        KeyChangeReminderCharDB = {}
    end
    for k, v in pairs(CHAR_DEFAULTS) do
        if KeyChangeReminderCharDB[k] == nil then
            if type(v) == "table" then
                local copy = {}
                for k2, v2 in pairs(v) do copy[k2] = v2 end
                KeyChangeReminderCharDB[k] = copy
            else
                KeyChangeReminderCharDB[k] = v
            end
        end
    end
    self.charDb = KeyChangeReminderCharDB
end

function KeyChangeReminder:GetChar(key)
    return self.charDb and self.charDb[key]
end

function KeyChangeReminder:SetChar(key, value)
    if self.charDb then
        self.charDb[key] = value
    end
end

-- ──────────────────────────────────────────────

function KeyChangeReminder:GetColorHex()
    local preset = self:Get("color") or "CYAN"
    return KeyChangeReminder.COLOR_PRESETS[preset] or KeyChangeReminder.COLOR_PRESETS["CYAN"]
end

-- ──────────────────────────────────────────────
-- Settings panel UI helpers
-- ──────────────────────────────────────────────

local function MakeHeader(parent, text, yOffset)
    local f = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    f:SetPoint("TOPLEFT", 16, yOffset)
    f:SetText(text)
    f:SetTextColor(1, 0.82, 0, 1)  -- WoW gold
    return f
end

local function MakeLine(parent, yOffset)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetSize(560, 1)
    t:SetPoint("TOPLEFT", 16, yOffset)
    t:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    return t
end

local function MakeLabel(parent, text, yOffset, xOffset)
    local f = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f:SetPoint("TOPLEFT", xOffset or 16, yOffset)
    f:SetText(text)
    return f
end

local function MakeButton(parent, label, width, yOffset, xOffset)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 160, 26)
    btn:SetPoint("TOPLEFT", xOffset or 16, yOffset)
    btn:SetText(label)
    return btn
end

-- ──────────────────────────────────────────────
-- Build the panel
-- ──────────────────────────────────────────────

local function BuildPanel(panel)
    local scrollFrame = CreateFrame("ScrollFrame", "KeyChangeReminderScrollFrame", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0,   0)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(560)
    scrollFrame:SetScrollChild(content)

    local y = -10  -- running Y cursor (negative = downward)

    -- ── Position ──────────────────────────────────────────────────────────
    MakeHeader(content, "Position", y)
    y = y - 26
    MakeLine(content, y)
    y = y - 14

    local btnShowWarning = MakeButton(content, "Show Warning", 190, y, 16)
    btnShowWarning:SetScript("OnClick", function()
        KeyChangeReminder:ShowReminder("Change your key!")
    end)

    local btnHideWarning = MakeButton(content, "Hide Warning", 190, y, 220)
    btnHideWarning:SetScript("OnClick", function()
        KeyChangeReminder:HideReminder()
    end)

    y = y - 34

    local dragging = false
    local btnDrag = MakeButton(content, "Drag to Reposition", 190, y, 16)
    btnDrag:SetScript("OnClick", function()
        local lbl = KeyChangeReminderLabel
        if not lbl then
            KeyChangeReminder:ShowReminder("Drag me!")
            lbl = KeyChangeReminderLabel
        end
        if not dragging then
            lbl:EnableMouse(true)
            lbl:SetMovable(true)
            lbl:RegisterForDrag("LeftButton")
            lbl:SetScript("OnDragStart", function(self) self:StartMoving() end)
            lbl:SetScript("OnDragStop", function(self)
                self:StopMovingOrSizing()
                local point, _, _, x, y2 = self:GetPoint()
                KeyChangeReminder:Set("anchorPoint", point)
                KeyChangeReminder:Set("anchorX", math.floor(x + 0.5))
                KeyChangeReminder:Set("anchorY", math.floor(y2 + 0.5))
            end)
            btnDrag:SetText("Stop Dragging")
            dragging = true
        else
            lbl:EnableMouse(false)
            lbl:SetScript("OnDragStart", nil)
            lbl:SetScript("OnDragStop", nil)
            btnDrag:SetText("Drag to Reposition")
            dragging = false
        end
    end)

    local btnReset = MakeButton(content, "Reset Position", 190, y, 220)
    btnReset:SetScript("OnClick", function()
        KeyChangeReminder:Set("anchorPoint", "CENTER")
        KeyChangeReminder:Set("anchorX", 0)
        KeyChangeReminder:Set("anchorY", 200)
        if KeyChangeReminderLabel then
            KeyChangeReminderLabel:ClearAllPoints()
            KeyChangeReminderLabel:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        end
    end)

    y = y - 44

    -- ── Font Size ─────────────────────────────────────────────────────────
    MakeHeader(content, "Font Size", y)
    y = y - 20
    MakeLine(content, y)
    y = y - 10

    local sizeLabel = MakeLabel(content, tostring(KeyChangeReminder:Get("fontSize") or 42) .. "pt", y, 300)

    local fontSlider = CreateFrame("Slider", "KeyChangeReminderFontSlider", content, "OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT", 16, y - 8)
    fontSlider:SetSize(270, 16)
    fontSlider:SetMinMaxValues(18, 96)
    fontSlider:SetValueStep(2)
    fontSlider:SetObeyStepOnDrag(true)
    fontSlider:SetValue(KeyChangeReminder:Get("fontSize") or 42)
    _G[fontSlider:GetName() .. "Low"]:SetText("18pt")
    _G[fontSlider:GetName() .. "High"]:SetText("96pt")
    _G[fontSlider:GetName() .. "Text"]:SetText("")
    fontSlider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val)
        KeyChangeReminder:Set("fontSize", val)
        sizeLabel:SetText(val .. "pt")
        if KeyChangeReminderLabel and KeyChangeReminderLabel:IsShown() then
            KeyChangeReminderLabel.text:SetFont(STANDARD_TEXT_FONT, val, "OUTLINE")
        end
    end)

    y = y - 44

    -- ── Pulse Speed ───────────────────────────────────────────────────────
    MakeHeader(content, "Pulse Speed", y)
    y = y - 20
    MakeLine(content, y)
    y = y - 10

    local pulseVal = KeyChangeReminder:Get("pulseSpeed") or 1.0
    local function pulseLabel(v)
        if v <= 0.4 then return "Fast"
        elseif v >= 1.8 then return "Slow"
        else return "Medium" end
    end
    local speedLabel = MakeLabel(content, pulseLabel(pulseVal), y, 300)

    local pulseSlider = CreateFrame("Slider", "KeyChangeReminderPulseSlider", content, "OptionsSliderTemplate")
    pulseSlider:SetPoint("TOPLEFT", 16, y - 1)
    pulseSlider:SetSize(270, 16)
    pulseSlider:SetMinMaxValues(0.3, 2.0)
    pulseSlider:SetValueStep(0.1)
    pulseSlider:SetObeyStepOnDrag(true)
    pulseSlider:SetValue(KeyChangeReminder:Get("pulseSpeed") or 1.0)
    _G[pulseSlider:GetName() .. "Low"]:SetText("Fast")
    _G[pulseSlider:GetName() .. "High"]:SetText("Slow")
    _G[pulseSlider:GetName() .. "Text"]:SetText("")
    pulseSlider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val * 10 + 0.5) / 10
        KeyChangeReminder:Set("pulseSpeed", val)
        speedLabel:SetText(pulseLabel(val))
        if KeyChangeReminderLabel then
            local speed = val
            local half = speed / 2
            local anims = { KeyChangeReminderLabel.pulseGroup:GetAnimations() }
            for _, anim in ipairs(anims) do
                anim:SetDuration(half)
            end
        end
    end)

    y = y - 44

    -- ── Color ─────────────────────────────────────────────────────────────
    MakeHeader(content, "Color", y)
    y = y - 26
    MakeLine(content, y)
    y = y - 14

    local COLOR_LAYOUT = {
        { name = "RED",    label = "Red",    col = {1, 0.2, 0.2} },
        { name = "ORANGE", label = "Orange", col = {1, 0.6, 0} },
        { name = "YELLOW", label = "Yellow", col = {1, 1, 0} },
        { name = "WHITE",  label = "White",  col = {1, 1, 1} },
        { name = "CYAN",   label = "Cyan",   col = {0, 0.8, 1} },
        { name = "GREEN",  label = "Green",  col = {0, 1, 0.53} },
    }

    local BTN_W, BTN_H, GAP = 178, 26, 8
    for i, info in ipairs(COLOR_LAYOUT) do
        local col = (i - 1) % 3
        local row = math.floor((i - 1) / 3)
        local bx = 16 + col * (BTN_W + GAP)
        local by = y - row * (BTN_H + GAP)

        local cb = MakeButton(content, info.label, BTN_W, by, bx)
        cb:GetFontString():SetTextColor(info.col[1], info.col[2], info.col[3])
        cb:SetScript("OnClick", function()
            KeyChangeReminder:Set("color", info.name)
            if KeyChangeReminderLabel and KeyChangeReminderLabel:IsShown() then
                local hex = KeyChangeReminder:GetColorHex()
                local r = tonumber(hex:sub(3,4), 16) / 255
                local g = tonumber(hex:sub(5,6), 16) / 255
                local b = tonumber(hex:sub(7,8), 16) / 255
                KeyChangeReminderLabel.text:SetTextColor(r, g, b, 1)
            end
        end)
    end

    y = y - 72

    -- ── Minimum Key Level / Auto Mode ────────────────────────────────────
    MakeHeader(content, "Minimum Key Level", y)
    y = y - 26
    MakeLine(content, y)
    y = y - 10

    MakeLabel(content,
        "Only remind me when the key is at or above this level.\nSet to 0 to always remind.",
        y, 16)
    y = y - 38

    local minKeyLabel
    local minKeySlider
    local btnAuto

    local function RefreshAutoState()
        local isAuto = KeyChangeReminder:Get("autoMode") or false
        if isAuto then
            minKeySlider:SetEnabled(false)
            minKeySlider:SetAlpha(0.4)
            minKeyLabel:SetText("Auto")
            btnAuto:SetText("Auto: On")
        else
            minKeySlider:SetEnabled(true)
            minKeySlider:SetAlpha(1.0)
            local val = KeyChangeReminder:Get("minKeyLevel") or 0
            minKeyLabel:SetText("Level: " .. val .. (val == 0 and " (Always remind)" or ""))
            btnAuto:SetText("Auto: Off")
        end
    end

    minKeyLabel = MakeLabel(content,
        "Level: " .. (KeyChangeReminder:Get("minKeyLevel") or 0) ..
        ((KeyChangeReminder:Get("minKeyLevel") or 0) == 0 and " (Always remind)" or ""),
        y, 300)

    minKeySlider = CreateFrame("Slider", "KeyChangeReminderMinKeySlider", content, "OptionsSliderTemplate")
    minKeySlider:SetPoint("TOPLEFT", 16, y - 8)
    minKeySlider:SetSize(270, 16)
    minKeySlider:SetMinMaxValues(0, 30)
    minKeySlider:SetValueStep(1)
    minKeySlider:SetObeyStepOnDrag(true)
    minKeySlider:SetValue(KeyChangeReminder:Get("minKeyLevel") or 0)
    _G[minKeySlider:GetName() .. "Low"]:SetText("0")
    _G[minKeySlider:GetName() .. "High"]:SetText("30")
    _G[minKeySlider:GetName() .. "Text"]:SetText("")
    minKeySlider:SetScript("OnValueChanged", function(self, val)
        if KeyChangeReminder:Get("autoMode") then return end
        val = math.floor(val)
        KeyChangeReminder:Set("minKeyLevel", val)
        minKeyLabel:SetText("Level: " .. val .. (val == 0 and " (Always remind)" or ""))
    end)

    y = y - 32

    btnAuto = MakeButton(content, "Auto: Off", 110, y, 16)
    btnAuto:SetScript("OnClick", function()
        local nowAuto = not (KeyChangeReminder:Get("autoMode") or false)
        KeyChangeReminder:Set("autoMode", nowAuto)
        if not nowAuto then
            KeyChangeReminder:Set("minKeyLevel", math.floor(minKeySlider:GetValue()))
        end
        RefreshAutoState()
    end)

    -- Tooltip explaining what Auto mode does
    btnAuto:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Auto Mode")
        GameTooltip:AddLine(
            "Only reminds you on foreign-key timed runs where the vendor " ..
            "offers a worthwhile reroll (your bag key level is at or below the completed " ..
            "key level). Own-key runs, depletions, and abandons are silenced.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    btnAuto:SetScript("OnLeave", function() GameTooltip:Hide() end)

    RefreshAutoState()

    y = y - 32

    -- ── Talent Reminder ───────────────────────────────────────────────────
    MakeHeader(content, "Talent Reminder", y)
    y = y - 26
    MakeLine(content, y)
    y = y - 18

    MakeLabel(content, "Show a reminder to switch to your M+ talents when entering a dungeon.", y, 16)
    y = y - 28

    -- [KCR_AUDIT: Patch F — InterfaceOptionsCheckButtonTemplate was removed in Midnight
    --  12.0.  UICheckButtonTemplate is the supported replacement for standalone
    --  checkboxes outside the old InterfaceOptions panel system.]
    local talentCB = CreateFrame("CheckButton", "KeyChangeReminderTalentCB", content, "UICheckButtonTemplate")
    talentCB:SetPoint("TOPLEFT", 16, y)
    _G[talentCB:GetName() .. "Text"]:SetText("Enable talent reminder")
    talentCB:SetChecked(KeyChangeReminder:Get("talentReminder") or false)
    talentCB:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()
        KeyChangeReminder:Set("talentReminder", enabled)
        if enabled then
            KeyChangeReminder:CheckAndShowTalentReminder()
        else
            KeyChangeReminder:HideTalentReminder()
        end
    end)

    y = y - 34

    -- ── Raid Talent Reminder ──────────────────────────────────────────────
    -- [KCR_RTR_AUDIT: raid talent settings are now per-character (GetChar/SetChar)
    --  because every class/spec has different loadout names.  All Get/Set calls
    --  for raidTalentReminder and raidTalentNames route through charDb.]

    MakeHeader(content, "Raid Talent Reminder", y)
    y = y - 26
    MakeLine(content, y)
    y = y - 18

    MakeLabel(content,
        "Warn you on a raid ready check if your current talent loadout name\n"
        .. "does not match any loadout you have saved below.  Auto-dismisses after 5 seconds.",
        y, 16)
    y = y - 36

    -- Master enable checkbox
    -- [KCR_RTR_AUDIT: uses GetChar/SetChar — setting is per-character]
    local raidTalentCB = CreateFrame("CheckButton", "KCRRaidTalentCB", content, "UICheckButtonTemplate")
    raidTalentCB:SetPoint("TOPLEFT", 16, y)
    _G[raidTalentCB:GetName() .. "Text"]:SetText("Enable raid talent reminder")
    raidTalentCB:SetChecked(KeyChangeReminder:GetChar("raidTalentReminder") or false)
    raidTalentCB:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()
        -- [KCR_RTR_AUDIT: SetChar — per-character]
        KeyChangeReminder:SetChar("raidTalentReminder", enabled)
        if enabled then
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r Raid talent reminder |cff44ff88enabled|r.")
        else
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r Raid talent reminder |cffff4444disabled|r.")
        end
    end)

    y = y - 36

    -- ── Saved loadout list display ────────────────────────────────────────
    MakeLabel(content, "Saved raid loadout names (checked on ready check):", y, 16)
    y = y - 24

    local listHeight = 110
    local listFrame  = CreateFrame("Frame", "KCRRaidTalentListFrame", content)
    listFrame:SetSize(528, listHeight)
    listFrame:SetPoint("TOPLEFT", 16, y)

    local bg = listFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.35)

    local MAX_VISIBLE_ROWS = 6
    local ROW_H            = 18
    local listRows         = {}

    for i = 1, MAX_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, listFrame)
        row:SetSize(528, ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)

        local nameLbl = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        nameLbl:SetPoint("LEFT", 6, 0)
        nameLbl:SetWidth(440)
        nameLbl:SetJustifyH("LEFT")
        row.nameLbl = nameLbl

        local removeBtn = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        removeBtn:SetSize(16, 16)
        removeBtn:SetPoint("RIGHT", -4, 0)
        removeBtn:Hide()
        row.removeBtn = removeBtn

        row:Hide()
        listRows[i] = row
    end

    local scrollOffset = 0
    local RefreshTalentList  -- forward declaration

    -- Helper: get the current loadout name via the RTR module's public wrapper.
    local function GetCurrentLoadoutNameForUI()
        local RTR = KeyChangeReminder.RaidTalentReminder
        if not RTR then return nil end
        local names = RTR.GetActiveTalentNames and RTR.GetActiveTalentNames() or {}
        return names[1]
    end

    RefreshTalentList = function()
        local RTR  = KeyChangeReminder.RaidTalentReminder
        local list = RTR and RTR:GetTalentList() or {}
        local currentName = GetCurrentLoadoutNameForUI()

        local totalEntries = #list
        scrollOffset = math.max(0, math.min(scrollOffset, totalEntries - MAX_VISIBLE_ROWS))

        for i = 1, MAX_VISIBLE_ROWS do
            local entryIdx = scrollOffset + i
            local row      = listRows[i]

            if entryIdx <= totalEntries then
                local name = list[entryIdx]

                -- [KCR_RTR_AUDIT: replaced unicode ✓ with a WoW inline texture tag.
                --  Unicode checkmarks do not exist in WoW's default font atlas and
                --  render as empty boxes.  Interface\RaidFrame\ReadyCheck-Ready is
                --  the canonical green checkmark texture used by Blizzard's own
                --  ready-check UI, so it is always present and thematically fitting.
                --  |T path:height:width:xOffset:yOffset|t syntax; 12×12 aligns
                --  cleanly with GameFontNormalSmall's line height.]
                local isActive = currentName and (name:lower() == currentName:lower())
                local prefix   = isActive
                                 and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0|t "
                                 or  "  "

                row.nameLbl:SetText("|cffffd700" .. entryIdx .. ".|r " .. prefix .. name)
                row.removeBtn:Show()
                local capturedIdx = entryIdx
                row.removeBtn:SetScript("OnClick", function()
                    if RTR then
                        local removed = RTR:RemoveTalentByIndex(capturedIdx)
                        if removed then
                            print("|cff00ccff[KCR-Raid]|r |cff808080»|r Removed raid loadout #"
                                .. capturedIdx .. ": \"" .. name .. "\".")
                        end
                    end
                    RefreshTalentList()
                end)
                row:Show()
            else
                row.nameLbl:SetText("")
                row.removeBtn:Hide()
                row.removeBtn:SetScript("OnClick", nil)
                row:Hide()
            end
        end

        -- Empty-state hint
        if totalEntries == 0 then
            listRows[1].nameLbl:SetText("|cff808080No raid loadouts saved.  Use 'Add Current Loadout' below.|r")
            listRows[1].removeBtn:Hide()
            listRows[1]:Show()
        end
    end

    y = y - listHeight - 4

    -- Scroll buttons (only matter when > MAX_VISIBLE_ROWS entries exist)
    -- [KCR_RTR_AUDIT: WoW native arrow textures — unicode arrows do not render]
    local scrollUp = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    scrollUp:SetSize(30, 22)
    scrollUp:SetPoint("TOPLEFT", 16, y)
    scrollUp:SetText("")
    local arrowUpTex = scrollUp:CreateTexture(nil, "OVERLAY")
    arrowUpTex:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
    arrowUpTex:SetSize(16, 16)
    arrowUpTex:SetPoint("CENTER", 0, 0)
    scrollUp:SetScript("OnClick", function()
        if scrollOffset > 0 then
            scrollOffset = scrollOffset - 1
            RefreshTalentList()
        end
    end)

    local scrollDown = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    scrollDown:SetSize(30, 22)
    scrollDown:SetPoint("TOPLEFT", 50, y)
    scrollDown:SetText("")
    local arrowDownTex = scrollDown:CreateTexture(nil, "OVERLAY")
    arrowDownTex:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrowDownTex:SetSize(16, 16)
    arrowDownTex:SetPoint("CENTER", 0, 0)
    scrollDown:SetScript("OnClick", function()
        local RTR  = KeyChangeReminder.RaidTalentReminder
        local list = RTR and RTR:GetTalentList() or {}
        if scrollOffset + MAX_VISIBLE_ROWS < #list then
            scrollOffset = scrollOffset + 1
            RefreshTalentList()
        end
    end)

    -- ── Add loadout by name (manual text entry) ───────────────────────────
    local addLabel = MakeLabel(content, "Add by name:", y, 96)

    local addBox = CreateFrame("EditBox", "KCRRaidTalentAddBox", content, "InputBoxTemplate")
    addBox:SetSize(300, 22)
    addBox:SetPoint("TOPLEFT", 200, y + 1)
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(64)
    addBox:SetText("")

    local addBtn = MakeButton(content, "Add", 60, y, 510)
    addBtn:SetScript("OnClick", function()
        local name = addBox:GetText():match("^%s*(.-)%s*$")
        addBox:SetText("")
        if name == "" then return end

        local RTR = KeyChangeReminder.RaidTalentReminder
        if not RTR then
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r |cffff4444Raid module not loaded yet — try again.|r")
            return
        end

        local added = RTR:AddLoadoutName(name)
        if added then
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r Added raid loadout: \"|cffffd700" .. name .. "|r\".")
        else
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r |cffffff00\"" .. name .. "\" is already in your list.|r")
        end
        scrollOffset = 0
        RefreshTalentList()
    end)

    addBox:SetScript("OnEnterPressed", function(self)
        addBtn:Click()
        self:ClearFocus()
    end)
    addBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    y = y - 32

    -- ── Add Current Loadout button ────────────────────────────────────────
    local btnAddActive = MakeButton(content, "Add Current Loadout", 220, y, 16)
    btnAddActive:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Add Current Loadout")
        GameTooltip:AddLine(
            "Reads your currently-active talent loadout name and saves it "
            .. "as a raid loadout.  Switch to your raid spec/loadout first, "
            .. "then click this button.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    btnAddActive:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btnAddActive:SetScript("OnClick", function()
        local RTR = KeyChangeReminder.RaidTalentReminder
        if not RTR then
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r |cffff4444Raid module not loaded yet — try again.|r")
            return
        end

        local names = RTR.GetActiveTalentNames and RTR.GetActiveTalentNames() or {}
        local name  = names[1]

        if not name then
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r "
                .. "|cffff4444Could not read loadout name — is a loadout selected in the talent UI?|r")
            return
        end

        local added = RTR:AddLoadoutName(name)
        scrollOffset = 0
        RefreshTalentList()

        if added then
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r "
                .. "Added raid loadout: \"|cffffd700" .. name .. "|r\".")
        else
            print("|cff00ccff[KCR-Raid]|r |cff808080»|r "
                .. "|cffffff00\"" .. name .. "\" is already in your list.|r")
        end
    end)

    -- ── Test / Clear buttons ──────────────────────────────────────────────
    local btnTest = MakeButton(content, "Test Check Now", 190, y, 250)
    btnTest:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Test Raid Loadout Check")
        GameTooltip:AddLine(
            "Runs the loadout check immediately regardless of raid group or ready check state.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    btnTest:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btnTest:SetScript("OnClick", function()
        local RTR = KeyChangeReminder.RaidTalentReminder
        if RTR then RTR:ManualCheck() end
    end)

    -- [KCR_RTR_AUDIT: Clear All routes through SetChar — per-character]
    local btnClear = MakeButton(content, "Clear All", 100, y, 450)
    btnClear:SetScript("OnClick", function()
        KeyChangeReminder:SetChar("raidTalentNames", {})
        scrollOffset = 0
        RefreshTalentList()
        print("|cff00ccff[KCR-Raid]|r |cff808080»|r All saved raid loadouts cleared.")
    end)

    y = y - 36

    -- ── Debug ─────────────────────────────────────────────────────────────
    MakeHeader(content, "Debug", y)
    y = y - 26
    MakeLine(content, y)
    y = y - 14

    local btnTest2 = MakeButton(content, "Test Reminder", 190, y, 16)
    btnTest2:SetScript("OnClick", function()
        KeyChangeReminder:ShowReminder("Test — Change your key!")
    end)

    local btnPrintKey = MakeButton(content, "Print Key Info", 190, y, 220)
    btnPrintKey:SetScript("OnClick", function()
        print("|cff00ccff[KeyChangeReminder]|r ── Key Info Debug ──")

        local function dumpVal(v)
            if type(v) == "table" then
                local parts = {}
                for k2, v2 in pairs(v) do
                    parts[#parts+1] = tostring(k2) .. "=" .. tostring(v2)
                end
                return "{" .. table.concat(parts, ", ") .. "}"
            end
            return tostring(v)
        end

        if C_ChallengeMode and (C_ChallengeMode.GetChallengeCompletionInfo or C_ChallengeMode.GetCompletionInfo) then
            local fn = C_ChallengeMode.GetChallengeCompletionInfo or C_ChallengeMode.GetCompletionInfo
            local info = fn()
            print("  GetChallengeCompletionInfo: " .. dumpVal(info))
        else
            print("  GetChallengeCompletionInfo: NOT AVAILABLE")
        end

        if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
            local a, b, c = C_ChallengeMode.GetActiveKeystoneInfo()
            print("  C_ChallengeMode.GetActiveKeystoneInfo: " .. dumpVal(a) .. " | " .. dumpVal(b) .. " | " .. dumpVal(c))
        else
            print("  C_ChallengeMode.GetActiveKeystoneInfo: NOT AVAILABLE")
        end

        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID then
            local a = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
            print("  GetOwnedKeystoneChallengeMapID: " .. dumpVal(a))
        else
            print("  GetOwnedKeystoneChallengeMapID: NOT AVAILABLE")
        end

        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
            local lvl = C_MythicPlus.GetOwnedKeystoneLevel()
            print("  GetOwnedKeystoneLevel: " .. dumpVal(lvl))
        else
            print("  GetOwnedKeystoneLevel: NOT AVAILABLE")
        end

        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID then
            local a = C_MythicPlus.GetOwnedKeystoneMapID()
            print("  GetOwnedKeystoneMapID: " .. dumpVal(a))
        else
            print("  GetOwnedKeystoneMapID: NOT AVAILABLE")
        end

        print("|cff00ccff[KeyChangeReminder]|r ────────────────────")
    end)

    -- Initial population of the loadout list in the UI.
    -- [KCR_RTR_AUDIT: deferred 0.1 s so RaidTalentReminder.lua's ADDON_LOADED
    --  handler has time to run and set up KeyChangeReminder.RaidTalentReminder
    --  before we call GetTalentList() here.]
    C_Timer.After(0.1, RefreshTalentList)

    content:SetHeight(math.abs(y) + 20)
end

-- ──────────────────────────────────────────────
-- Register with the Settings system
-- ──────────────────────────────────────────────

local optFrame = CreateFrame("Frame")
optFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "KeyChangeReminder" then
        C_Timer.After(0, function()
            local panel = CreateFrame("Frame")
            panel.name  = "KeyChangeReminder"
            panel:Hide()

            BuildPanel(panel)

            local category = Settings.RegisterCanvasLayoutCategory(panel, "KeyChangeReminder")
            Settings.RegisterAddOnCategory(category)
            KeyChangeReminder.optionsCategory = category
            KeyChangeReminder.settingsCategory = category
        end)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
optFrame:RegisterEvent("ADDON_LOADED")
