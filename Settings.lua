-- KeyChangeReminderSettings.lua
-- Default settings, SavedVariables helpers, and the Settings panel UI.
-- (Merged from Config.lua + Options.lua)

KeyChangeReminder = KeyChangeReminder or {}

-- ──────────────────────────────────────────────
-- Default settings & DB helpers
-- ──────────────────────────────────────────────

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

-- Color presets (label -> hex AARRGGBB)
KeyChangeReminder.COLOR_PRESETS = {
    RED    = "ffff3333",
    ORANGE = "ffff9900",
    YELLOW = "ffffff00",
    WHITE  = "ffffffff",
    CYAN   = "ff00ccff",
    GREEN  = "ff00ff88",
}

function KeyChangeReminder:InitDB()
    if not KeyChangeReminderDB then
        KeyChangeReminderDB = {}
    end
    for k, v in pairs(DEFAULTS) do
        if KeyChangeReminderDB[k] == nil then
            KeyChangeReminderDB[k] = v
        end
    end
    self.db = KeyChangeReminderDB
end

function KeyChangeReminder:Get(key)
    return self.db and self.db[key]
end

function KeyChangeReminder:Set(key, value)
    if self.db then
        self.db[key] = value
    end
end

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

    -- ── Debug ─────────────────────────────────────────────────────────────
    MakeHeader(content, "Debug", y)
    y = y - 26
    MakeLine(content, y)
    y = y - 14

    local btnTest = MakeButton(content, "Test Reminder", 190, y, 16)
    btnTest:SetScript("OnClick", function()
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

        -- [KCR_AUDIT: Patch F (debug panel) — prefer GetChallengeCompletionInfo (12.0.5
        --  name); fall back to GetCompletionInfo for safety.  Also prefer
        --  C_ChallengeMode.GetActiveKeystoneInfo (present in 12.0.5) over the old
        --  C_ChallengeMode.GetActiveKeystoneInfo from C_MythicPlus.]
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
