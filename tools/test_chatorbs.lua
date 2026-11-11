--[[---------------------------------------------------------------------------
    Offline harness for ChatOrbs.lua.

    Mocks the parts of the WoW API the addon touches, loads the addon into that
    sandbox under Lua 5.1 (the version the game runs), then drives it: login,
    every slash command, clicks on every orb, the emote picker, hover and press
    transitions, dragging, and each state change the addon listens for.

    Any widget method the addon calls that the mock does not define raises an
    error, so a typo fails the run instead of passing silently.
-----------------------------------------------------------------------------]]

local ADDON_FILE = ...
local failures, checks = {}, 0

local function check(ok, what)
    checks = checks + 1
    if not ok then failures[#failures + 1] = what end
    return ok
end

local env = {}
local allFrames, allRegions = {}, {}

-- ---------------------------------------------------------------------------
-- Mock regions
-- ---------------------------------------------------------------------------
local function newRegion(kind, layer)
    local r = {
        kind = kind, layer = layer, points = {}, shown = true, alpha = 1,
        SetPoint = function(self, point, rel, relPoint, x, y)
            if type(rel) == "string" then rel, relPoint, x, y = nil, point, rel, relPoint end
            check(type(point) == "string", "region SetPoint point")
            self.points[point] = { rel = rel, relPoint = relPoint, x = x, y = y }
        end,
        ClearAllPoints = function(self) self.points = {} end,
        SetAllPoints = function(self) self.points.ALL = true end,
        SetWidth = function(self, w) self.width = w end,
        SetHeight = function(self, h) self.height = h end,
        GetWidth = function(self) return self.width or 0 end,
        GetHeight = function(self) return self.height or 0 end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        IsShown = function(self) return self.shown end,
        SetAlpha = function(self, a)
            check(type(a) == "number" and a >= 0 and a <= 1, "SetAlpha " .. tostring(a))
            self.alpha = a
        end,
        GetAlpha = function(self) return self.alpha end,
    }
    if kind == "Texture" then
        r.SetTexture = function(self, path) self.texture = path; return true end
        r.GetTexture = function(self) return self.texture end
        r.SetColorTexture = function(self, cr, cg, cb, ca)
            self.texture, self.colorTexture = nil, { cr, cg, cb, ca }
            -- The client folds the colour into the vertex colour, so a
            -- SetVertexColor made earlier is lost. The mock does the same,
            -- otherwise texture-free mode looks coloured here and white in
            -- the game.
            self.color = { cr, cg, cb }
        end
        r.SetBlendMode = function(self, mode) self.blend = mode end
        r.SetTexCoord = function(self, ...) self.coords = { ... } end
        r.SetVertexColor = function(self, cr, cg, cb)
            check(type(cr) == "number" and type(cg) == "number" and type(cb) == "number",
                  "SetVertexColor needs three numbers")
            self.color = { cr, cg, cb }
        end
    elseif kind == "FontString" then
        r.SetFont = function(self, path, size, flags)
            check(type(path) == "string" and path ~= "", "SetFont path")
            check(type(size) == "number" and size > 0, "SetFont size")
            self.font = { path, size, flags }
            return true
        end
        r.SetFontObject = function(self, o) self.fontObject = o end
        r.SetJustifyH = function(self, j) self.justify = j end
        r.SetWordWrap = function(self, v) self.wordWrap = v end
        r.SetTextColor = function(self, cr, cg, cb) self.color = { cr, cg, cb } end
        r.SetShadowColor = function(self, cr, cg, cb, ca)
            self.shadowColor = { cr, cg, cb, ca }
        end
        r.SetShadowOffset = function(self, x, y) self.shadowOffset = { x, y } end
        r.SetText = function(self, t) self.text = t end
        r.GetText = function(self) return self.text end
    end
    allRegions[#allRegions + 1] = r
    return r
end

-- ---------------------------------------------------------------------------
-- Mock frames
-- ---------------------------------------------------------------------------
local frameLevel = 10

local function newFrame(frameType, name, parent)
    frameLevel = frameLevel + 1
    local f
    f = {
        frameType = frameType, name = name, parent = parent, level = frameLevel,
        points = {}, scripts = {}, hooks = {}, events = {}, regions = {},
        shown = true, width = 0, height = 0, scale = 1, mouse = false,

        SetFrameStrata = function(self, s) self.strata = s end,
        SetFrameLevel = function(self, l) self.level = l end,
        GetFrameLevel = function(self) return self.level end,
        SetWidth = function(self, w) self.width = w end,
        SetHeight = function(self, h) self.height = h end,
        GetWidth = function(self) return self.width end,
        GetHeight = function(self) return self.height end,
        SetMovable = function(self, v) self.movable = v end,
        SetClampedToScreen = function() end,
        RegisterForDrag = function(self, ...) self.drag = { ... } end,
        RegisterForClicks = function(self, ...) self.clicks = { ... } end,
        EnableMouse = function(self, v) self.mouse = v end,
        EnableMouseWheel = function(self, v) self.wheel = v end,
        SetAutoFocus = function(self, v) self.autoFocus = v end,
        SetTextInsets = function() end,
        ClearFocus = function(self) self.focused = false end,
        SetFont = function(self, path, size)
            check(type(path) == "string" and path ~= "", "EditBox SetFont path")
            check(type(size) == "number" and size > 0, "EditBox SetFont size")
            return true
        end,
        SetFontObject = function(self, o) self.fontObject = o end,
        SetTextColor = function(self, cr, cg, cb) self.color = { cr, cg, cb } end,

        Show = function(self)
            self.shown = true
            if self.scripts.OnShow then self.scripts.OnShow(self) end
        end,
        Hide = function(self)
            local was = self.shown
            self.shown = false
            if was and self.scripts.OnHide then self.scripts.OnHide(self) end
        end,
        IsShown = function(self) return self.shown end,

        SetScript = function(self, script, fn) self.scripts[script] = fn end,
        GetScript = function(self, script) return self.scripts[script] end,
        HookScript = function(self, script, fn)
            self.hooks[script] = self.hooks[script] or {}
            table.insert(self.hooks[script], fn)
        end,

        RegisterEvent = function(self, e)
            check(type(e) == "string" and e ~= "", "RegisterEvent name")
            if env.KNOWN_EVENTS and not env.KNOWN_EVENTS[e] then
                error("unknown event: " .. e, 2)      -- mirrors modern clients
            end
            self.events[e] = true
        end,
        UnregisterEvent = function(self, e) self.events[e] = nil end,

        SetPoint = function(self, point, rel, relPoint, x, y)
            if type(rel) == "string" then rel, relPoint, x, y = nil, point, rel, relPoint end
            check(type(point) == "string", "frame SetPoint point")
            self.points[#self.points + 1] =
                { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
        end,
        ClearAllPoints = function(self) self.points = {} end,
        SetAllPoints = function(self) self.points.all = true end,
        GetPoint = function(self)
            local p = self.points[1]
            if not p then return nil end
            return p.point, p.rel, p.relPoint, p.x, p.y
        end,
        GetLeft = function(self) return self.simLeft or 100 end,
        GetBottom = function(self) return self.simBottom or 200 end,

        SetScale = function(self, s)
            check(type(s) == "number" and s > 0, "SetScale " .. tostring(s))
            self.scale = s
        end,
        GetScale = function(self) return self.scale end,
        GetEffectiveScale = function(self) return self.scale end,

        StartMoving = function(self) self.isMoving = true end,
        StopMovingOrSizing = function(self) self.isMoving = false end,

        CreateTexture = function(self, n, layer)
            local t = newRegion("Texture", layer)
            self.regions[#self.regions + 1] = t
            return t
        end,
        CreateFontString = function(self, n, layer)
            local t = newRegion("FontString", layer)
            self.regions[#self.regions + 1] = t
            return t
        end,
    }
    if frameType == "EditBox" then
        f.SetText = function(self, t)
            self.text = t
            if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end
        end
        f.GetText = function(self) return self.text end
        f.SetFocus = function(self) self.focused = true end
        f.HighlightText = function() end
        f.SetCursorPosition = function(self, p) self.cursor = p end
        f.GetNumLetters = function(self) return #(self.text or "") end
    end
    if name then env[name] = f end
    allFrames[#allFrames + 1] = f
    return f
end

env.KNOWN_EVENTS = {}
for _, e in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE",
    "PLAYER_GUILD_UPDATE", "CHANNEL_UI_UPDATE", "CHAT_MSG_CHANNEL_NOTICE",
    "UPDATE_CHAT_COLOR", "BN_CONNECTED", "BN_DISCONNECTED",
}) do env.KNOWN_EVENTS[e] = true end

-- ---------------------------------------------------------------------------
-- Mock globals
-- ---------------------------------------------------------------------------
env._G = env
env.CreateFrame = newFrame
for _, k in ipairs({ "type", "pairs", "ipairs", "select", "tonumber", "tostring",
                     "string", "table", "math", "pcall", "error", "setmetatable",
                     "rawget", "unpack", "print", "next", "assert" }) do
    env[k] = _G[k]
end

env.UIParent = newFrame("Frame", "UIParent")
env.UIParent.width, env.UIParent.height = 1024, 768
env.ChatFrame1 = newFrame("Frame", "ChatFrame1")
env.UISpecialFrames = {}

local editBox = newFrame("EditBox", "ChatFrame1EditBox")
editBox.attributes = {}
editBox.SetAttribute = function(self, k, v) self.attributes[k] = v end
editBox.GetAttribute = function(self, k) return self.attributes[k] end
editBox.SetText = function(self, t)
    self.text = t
    for _, fn in ipairs(self.hooks.OnTextChanged or {}) do fn(self) end
end
editBox.GetText = function(self) return self.text end
editBox.SetFocus = function(self) self.focused = true end
editBox.SetCursorPosition = function(self, p) self.cursor = p end
editBox.GetNumLetters = function(self) return #(self.text or "") end
editBox.shown = false
local baseShow, baseHide = editBox.Show, editBox.Hide
editBox.Show = function(self)
    baseShow(self)
    for _, fn in ipairs(self.hooks.OnShow or {}) do fn(self) end
end
editBox.Hide = function(self)
    baseHide(self)
    for _, fn in ipairs(self.hooks.OnHide or {}) do fn(self) end
end

local chatLog = {}
env.DEFAULT_CHAT_FRAME = {
    editBox = editBox,
    AddMessage = function(self, msg)
        check(type(msg) == "string", "AddMessage got a non-string")
        chatLog[#chatLog + 1] = msg
    end,
}

env.GameFontNormal = { GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end }
env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"

local tooltipLines = {}
env.GameTooltip = {
    SetOwner = function() end,
    SetText = function(self, t) tooltipLines = { t } end,
    AddLine = function(self, t) tooltipLines[#tooltipLines + 1] = t end,
    Show = function() end,
    Hide = function() end,
}

local timers = {}
env.C_Timer = { After = function(delay, fn) timers[#timers + 1] = fn end }
local function runTimers()
    local pending = timers
    timers = {}
    for _, fn in ipairs(pending) do fn() end
end

env.SlashCmdList = {}
env.GetLocale = function() return "ruRU" end
-- A 1080p screen: the interface grid is 768 units tall, so one unit covers
-- 1080/768 = 1.40625 pixels at scale 1 - not a whole number, which is exactly
-- the case the dock has to snap away from.
env.GetPhysicalScreenSize = function() return 1920, 1080 end

env.SAY, env.YELL, env.WHISPER, env.EMOTE = "Сказать", "Крик", "Шепот", "Эмоция"
env.PARTY, env.RAID, env.GUILD, env.OFFICER = "Группа", "Рейд", "Гильдия", "Офицерский"
env.INSTANCE_CHAT = "Подземелье"
env.SLASH_SAY1, env.SLASH_YELL1, env.SLASH_WHISPER1 = "/s", "/y", "/w"
env.SLASH_EMOTE1, env.SLASH_PARTY1, env.SLASH_RAID1 = "/e", "/p", "/raid"
env.SLASH_GUILD1, env.SLASH_OFFICER1 = "/g", "/o"
env.SLASH_INSTANCE_CHAT1, env.SLASH_BNWHISPER1 = "/i", "/bnwhisper"

-- ruRU emote globals laid out the way the client does. The real client knows
-- hundreds; the point of the fixture is that the addon reads them all rather
-- than carrying its own short list, which is how /sit went missing.
local EMOTE_FIXTURES = {
    { "HELLO", "/привет" }, { "BYE", "/пока" }, { "WAVE", "/помахать" },
    { "BOW", "/поклон" }, { "SALUTE", "/отдатьчесть" }, { "THANK", "/спасибо" },
    { "APPLAUD", "/аплодисменты" }, { "CHEER", "/ура" }, { "LAUGH", "/смех" },
    { "SMILE", "/улыбка" }, { "DANCE", "/танец" }, { "FLEX", "/мускулы" },
    { "KISS", "/поцелуй" }, { "HUG", "/обнять" }, { "SHRUG", "/пожатьплечами" },
    { "SORRY", "/извинить" }, { "CRY", "/плакать" }, { "ROAR", "/рычать" },
    { "SIT", "/сесть" }, { "KNEEL", "/наколени" }, { "LAYDOWN", "/лечь" },
    { "SLEEP", "/спать" }, { "POINT", "/указать" }, { "PRAY", "/молиться" },
    { "READ", "/читать" }, { "DRINK", "/пить" }, { "EAT", "/есть" },
    { "WELCOME", "/приветствовать" }, { "CONGRATULATE", "/поздравить" },
    { "RUDE", "/грубость" }, { "CHICKEN", "/курица" }, { "TRAIN", "/чухчух" },
    { "VICTORY", "/победа" }, { "NO", "/нет" },
    { "BLUSH", "/краснеть" }, { "SPIT", "/плюнуть" }, { "MOURN", "/скорбеть" },
    { "GIGGLE", "/хихикать" }, { "BECKON", "/поманить" }, { "CHARGE", "/вперёд" },
    { "ROFL", "/покатываться" },
}
for i, pair in ipairs(EMOTE_FIXTURES) do
    env["EMOTE" .. (i * 3) .. "_TOKEN"] = pair[1]
    env["EMOTE" .. (i * 3) .. "_CMD1"] = pair[2]
end
-- YES is listed with an English command first and a Russian one second, which
-- is what put a stray "Yes" in a Russian list.
env["EMOTE500_TOKEN"], env["EMOTE500_CMD1"], env["EMOTE500_CMD2"] =
    "YES", "/yes", "/да"
-- A token the client publishes no command for. DoEmote has nothing to play
-- for it, so it must not reach the list at all - a button that does nothing
-- when clicked is exactly what the player hit.
env["EMOTE900_TOKEN"] = "SERVERONLY"

local emotesPerformed = {}
local brokenEmotes = {}
env.DoEmote = function(token)
    if brokenEmotes[token] then
        error("the client refuses to play " .. token, 0)
    end
    emotesPerformed[#emotesPerformed + 1] = token
end

-- The second path: the addon types the emote's own command instead.
local slashRun = {}
env.ChatEdit_SendText = function(box, history)
    check(type(box) == "table", "ChatEdit_SendText got no edit box")
    slashRun[#slashRun + 1] = box:GetText()
end

env.ChatTypeInfo = {
    SAY = { r = 1, g = 1, b = 1 }, YELL = { r = 1, g = .25, b = .25 },
    WHISPER = { r = 1, g = .5, b = 1 }, BN_WHISPER = { r = 0, g = 1, b = .96 },
    EMOTE = { r = 1, g = .5, b = .25 }, PARTY = { r = .67, g = .67, b = 1 },
    RAID = { r = 1, g = .5, b = 0 }, GUILD = { r = .25, g = 1, b = .25 },
    OFFICER = { r = .25, g = .75, b = .25 }, CHANNEL = { r = 1, g = .75, b = .75 },
}

local world = {
    inGroup = false, inRaid = false, inGuild = false, instanceGroup = false,
    hasTarget = false,
    channels = { { 1, "Общий", false }, { 2, "Торговля", false },
                 { 3, "ОбщийПоискГруппы", false }, { 4, "Т-канал", false } },
}
env.IsInGroup = function(cat)
    if cat then return world.instanceGroup end
    return world.inGroup or world.inRaid
end
env.IsInRaid = function() return world.inRaid end
env.IsInGuild = function() return world.inGuild end
env.LE_PARTY_CATEGORY_INSTANCE = 2
env.BNSendWhisper = function() end
env.UnitExists = function(u) return u == "target" and world.hasTarget end
env.UnitIsPlayer = function() return world.hasTarget end
env.UnitCanAttack = function() return false end
env.GetUnitName = function() return "Ивелноу-Форевер" end
env.UnitName = function() return "Ивелноу" end
env.GetChannelList = function()
    local out = {}
    for _, c in ipairs(world.channels) do
        out[#out + 1] = c[1]; out[#out + 1] = c[2]; out[#out + 1] = c[3]
    end
    return unpack(out)
end

env.ChatEdit_ChooseBoxForSend = function() return editBox end
env.ChatEdit_ActivateChat = function(b) b:Show() end
env.ChatEdit_UpdateHeader = function() end
env.ChatEdit_ParseText = function() end

-- ---------------------------------------------------------------------------
-- Load and drive
-- ---------------------------------------------------------------------------
local source = assert(io.open(ADDON_FILE, "r"))
local code = source:read("*a")
source:close()

local chunk, err = loadstring(code, "@ChatOrbs.lua")
if not chunk then
    print("SYNTAX ERROR: " .. tostring(err))
    os.exit(1)
end
setfenv(chunk, env)
assert(pcall(chunk, "ChatOrbs"))

local eventFrame
for _, f in ipairs(allFrames) do
    if f.scripts.OnEvent then eventFrame = f end
end
check(eventFrame ~= nil, "no OnEvent handler was installed")

local function fire(event, ...)
    local ok, e = pcall(eventFrame.scripts.OnEvent, eventFrame, event, ...)
    check(ok, "event " .. event .. " errored: " .. tostring(e))
    runTimers()
end

env.ChatOrbsDB = nil
fire("ADDON_LOADED", "SomeOtherAddon")
check(env.ChatOrbsDB == nil, "ADDON_LOADED reacted to a foreign addon")
fire("ADDON_LOADED", "ChatOrbs")
check(type(env.ChatOrbsDB) == "table", "ChatOrbsDB was not created")
fire("PLAYER_LOGIN")

local dock = env.ChatOrbsFrame
check(dock ~= nil, "ChatOrbsFrame was not created")
check(dock.shown, "the dock is not visible after login")

local function buttons()
    local out, i = {}, 1
    while env["ChatOrbsButton" .. i] do
        local b = env["ChatOrbsButton" .. i]
        if not b.shown then break end
        out[#out + 1] = b
        i = i + 1
    end
    return out
end

local function captionOf(b)
    for _, r in ipairs(b.regions) do
        if r.kind == "FontString" then return r end
    end
end

local function captions()
    local out = {}
    for _, b in ipairs(buttons()) do out[#out + 1] = captionOf(b).text end
    return table.concat(out, " ")
end

-- Solo, guildless, four numbered channels: Say Yell Emote Whisper BnWhisper
-- plus the channel numbers. Party sits second whenever there is one, so the
-- solo row runs straight from Say to Yell.
local expected = "С К Э Ш Б 1 2 3 4"
check(captions() == expected,
      "captions were '" .. captions() .. "', expected '" .. expected .. "'")

-- Orb colours follow ChatTypeInfo; the glyph is a darkened version of it.
local function textureOf(b, layer)
    for _, r in ipairs(b.regions) do
        if r.kind == "Texture" and r.layer == layer then return r end
    end
end

local orb1 = textureOf(buttons()[1], "ARTWORK")
check(orb1.color and orb1.color[1] == 1 and orb1.color[2] == 1,
      "the Say orb is not white")
check(orb1.texture and orb1.texture:find("Orb%.blp$"), "the orb texture path is wrong")
local cap1 = captionOf(buttons()[1])
check(cap1.color and math.abs(cap1.color[1] - 0.20) < 1e-9,
      "the Say glyph is not a darkened white")

local sheen1 = textureOf(buttons()[1], "OVERLAY")
check(sheen1.texture and sheen1.texture:find("OrbSheen%.blp$"), "sheen texture path")
local glow1 = textureOf(buttons()[1], "BACKGROUND")
check(glow1.blend == "ADD", "the glow is not additive")
check(glow1.alpha == 0, "the glow is visible at rest")

-- The dock panel is a child frame holding a nine-slice of nine textures.
local function panelOf(parent)
    for _, f in ipairs(allFrames) do
        if f.parent == parent and #f.regions == 9 then return f end
    end
end
local dockPanel = panelOf(dock)
check(dockPanel ~= nil, "the dock has no nine-slice panel frame")
local panelPieces, corners = 0, 0
for _, r in ipairs(dockPanel.regions) do
    if r.kind == "Texture" and r.texture and r.texture:find("Panel%.blp$") then
        panelPieces = panelPieces + 1
        check(r.coords and #r.coords == 4, "a panel piece has no texcoords")
        -- Each of the four corners must sample a distinct corner of the atlas.
        if r.coords and (r.coords[1] == 0 or r.coords[2] == 1)
            and (r.coords[3] == 0 or r.coords[4] == 1) then
            corners = corners + 1
        end
    end
end
check(panelPieces == 9, "the dock panel has " .. panelPieces .. " pieces, expected 9")
check(corners == 4, "the nine-slice has " .. corners .. " corner pieces, expected 4")

-- Clicking switches the edit box and focuses it.
local function click(index, mouseButton)
    local b = buttons()[index]
    check(b ~= nil, "no button at index " .. index)
    local ok, e = pcall(b.scripts.OnClick, b, mouseButton or "LeftButton")
    check(ok, "click on button " .. index .. " errored: " .. tostring(e))
    return b
end

click(1)
check(editBox.attributes.chatType == "SAY", "Say click did not set chatType=SAY")
check(editBox.focused, "Say click did not focus the edit box")
click(2)
check(editBox.attributes.chatType == "YELL", "Yell click did not set chatType=YELL")

-- Channel clicks carry the live channel number.
click(7)
check(editBox.attributes.chatType == "CHANNEL", "channel click did not set chatType")
check(editBox.attributes.channelTarget == 2,
      "channel click targeted " .. tostring(editBox.attributes.channelTarget)
      .. ", expected 2")

-- The marker follows the active channel.
local marker
for _, r in ipairs(dock.regions) do
    if r.kind == "Texture" and r.texture and r.texture:find("Marker%.blp$") then marker = r end
end
check(marker ~= nil, "the active-channel marker was not created")
check(marker.shown, "the marker is hidden while a channel is active")
check(marker.color and math.abs(marker.color[2] - 0.75) < 1e-9,
      "the marker did not take the channel colour")
editBox:Hide()
check(not marker.shown, "the marker stayed visible after the edit box closed")
editBox:Show()

-- Whisper without a target falls back to the slash command; with one it uses
-- the attribute protocol.
editBox.text = nil
click(4)
check(editBox.text == "/w ", "whisper without a target did not fall back to '/w '")
world.hasTarget = true
click(4)
check(editBox.attributes.tellTarget == "Ивелноу-Форевер",
      "whisper with a target did not set tellTarget")
world.hasTarget = false

-- The emote orb opens the picker rather than the edit box.
check(buttons()[3].entry.isEmote, "button 3 is not the emote orb")
check(env.ChatOrbsEmotePicker == nil, "the picker exists before it was opened")
click(3)
local pickerFrame = env.ChatOrbsEmotePicker
check(pickerFrame ~= nil, "the emote picker was not created")
check(pickerFrame.shown, "the emote picker did not open")
check(env.UISpecialFrames[1] == "ChatOrbsEmotePicker",
      "the picker was not registered for Escape")
click(3)
check(not pickerFrame.shown, "clicking the emote orb again did not close the picker")

-- Emote cells are localised and perform the emote.
click(3)
local cells = {}
for _, f in ipairs(allFrames) do
    if f.parent == pickerFrame and f.scripts.OnClick then cells[#cells + 1] = f end
end
check(#cells == 24, "the picker has " .. #cells .. " cells, expected 24")

local function cellText(cell)
    for _, r in ipairs(cell.regions) do
        if r.kind == "FontString" then return r.text end
    end
end
local function visibleLabels()
    local out = {}
    for _, c in ipairs(cells) do
        if c.shown then out[#out + 1] = cellText(c) end
    end
    return out
end

local labels = visibleLabels()
-- The short list opens on the emotes worth having under the cursor, and
-- laughing is the whole first row.
check(#labels == 24, "the short list shows " .. #labels .. " emotes, expected 24")
check(labels[1] == "Смеяться", "first emote label is '" .. tostring(labels[1])
      .. "', expected 'Смеяться'")
check(labels[2] == "Валяться от смеха",
      "second emote label is '" .. tostring(labels[2]) .. "'")
check(labels[3] == "Хихикать", "third emote label is '" .. tostring(labels[3]) .. "'")
check(labels[7] == "Танцевать",
      "seventh emote label is '" .. tostring(labels[7]) .. "', expected 'Танцевать'")
check(pickerFrame.more.shown and pickerFrame.more.text == "остальные эмоции — через поиск",
      "the short list does not say where the other emotes are, it says '"
      .. tostring(pickerFrame.more.text) .. "'")
-- Short means short: there is nothing past the first screen to scroll to.
pcall(pickerFrame.scripts.OnMouseWheel, pickerFrame, -1)
check(visibleLabels()[1] == "Смеяться",
      "the short list scrolled to '" .. tostring(visibleLabels()[1])
      .. "', so it is not short at all")

-- The search box: the mock types into it the way a player would.
local search = pickerFrame.search
check(search ~= nil, "the picker has no search box")
check(search.autoFocus == false,
      "the search box grabs focus on open, which would eat the movement keys")

local function typeSearch(text)
    search.text = text
    local ok, e = pcall(search.scripts.OnTextChanged, search)
    check(ok, "typing '" .. text .. "' errored: " .. tostring(e))
end

-- /sit is the emote that was missing. It must be findable by its Russian name,
-- in any case, and by its English token.
typeSearch("сесть")
check(visibleLabels()[1] == "Сесть",
      "searching 'сесть' gave '" .. tostring(visibleLabels()[1]) .. "'")
typeSearch("СЕСТЬ")
check(visibleLabels()[1] == "Сесть", "the search is not case-blind for Cyrillic")
typeSearch("sit")
check(visibleLabels()[1] == "Сесть", "searching by the English token failed")
pcall(search.scripts.OnEnterPressed, search)
check(emotesPerformed[#emotesPerformed] == "SIT",
      "Enter in the search box performed '"
      .. tostring(emotesPerformed[#emotesPerformed]) .. "', expected SIT")
check(not pickerFrame.shown, "the picker stayed open after Enter")

click(3)
typeSearch("щщщ")
check(#visibleLabels() == 0, "a search with no matches still showed cells")
check(pickerFrame.empty.shown, "the empty-list notice did not appear")
typeSearch("")
check(#visibleLabels() == 24, "clearing the search did not restore the short list")
check(visibleLabels()[1] == "Смеяться", "clearing the search lost the short list")

-- An emote the client gives no command for never reaches the list.
typeSearch("serveronly")
check(#visibleLabels() == 0,
      "an emote with no slash command is in the list; clicking it would do nothing")
typeSearch("")

-- The full list is one command away, and holds everything the client knows.
pcall(env.SlashCmdList["CHATORBS"], "emotes all")
check(env.ChatOrbsDB.allEmotes == true, "'emotes all' did not switch the list")
check(#visibleLabels() == 24, "the full list did not fill the grid")
check(pickerFrame.more.text == "колесо — прокрутка",
      "the full list does not offer scrolling, it says '"
      .. tostring(pickerFrame.more.text) .. "'")
pcall(pickerFrame.scripts.OnMouseWheel, pickerFrame, -1)
check(visibleLabels()[1] ~= "Смеяться",
      "the full list did not scroll past the first row")
pcall(pickerFrame.scripts.OnMouseWheel, pickerFrame, 40)

-- Every emote the client knows is reachable in the full list, not just a
-- hardcoded handful.
local reachable = {}
for _ = 1, 40 do
    for _, label in ipairs(visibleLabels()) do reachable[label] = true end
    pcall(pickerFrame.scripts.OnMouseWheel, pickerFrame, -1)
end
local count = 0
for _ in pairs(reachable) do count = count + 1 end
check(count >= #EMOTE_FIXTURES,
      "only " .. count .. " emotes were reachable by scrolling, expected at least "
      .. #EMOTE_FIXTURES)
check(reachable["Кивнуть"] == true,
      "YES is not named in Russian")
check(reachable["Serveronly"] ~= true and reachable["SERVERONLY"] ~= true,
      "the command-less emote is reachable in the full list")
check(reachable["Yes"] ~= true, "a stray English 'Yes' is still in the list")
check(reachable["Да"] ~= true, "YES still shows the client's bare command")
-- The client writes its emote commands as one glued word. Those must not be
-- what the list shows.
check(reachable["Отдатьчесть"] ~= true, "'Отдатьчесть' is still in the list")
check(reachable["Отдать честь"] == true, "SALUTE is not named 'Отдать честь'")
check(reachable["Пожатьплечами"] ~= true, "'Пожатьплечами' is still in the list")
check(reachable["Пожать плечами"] == true, "SHRUG is not named 'Пожать плечами'")
check(reachable["Наколени"] ~= true, "'Наколени' is still in the list")

pcall(pickerFrame.scripts.OnMouseWheel, pickerFrame, 40)   -- back to the top
check(visibleLabels()[1] == "Смеяться", "scrolling back up did not restore the top")
pcall(env.SlashCmdList["CHATORBS"], "emotes short")
check(env.ChatOrbsDB.allEmotes == false, "'emotes short' did not switch back")
check(#visibleLabels() == 24, "the short list did not come back")

-- Renaming must not cost the player the word the client uses: searching by
-- the client's own command still finds the emote.
typeSearch("отдатьчесть")
check(visibleLabels()[1] == "Отдать честь",
      "searching by the client's own wording gave '"
      .. tostring(visibleLabels()[1]) .. "'")
typeSearch("salute")
check(visibleLabels()[1] == "Отдать честь", "searching by the English token failed")
typeSearch("")
-- Hovering a cell names the command it will run and the token behind it,
-- so an emote that misbehaves can be reported without guesswork.
pcall(cells[7].scripts.OnEnter, cells[7])
check(tooltipLines[1] == "Танцевать", "the cell tooltip does not name the emote")
check(tooltipLines[2] == "/танец",
      "the cell tooltip does not show the client's command")
check(tooltipLines[3] == "DANCE", "the cell tooltip does not show the token")
pcall(cells[7].scripts.OnLeave, cells[7])
pcall(cells[7].scripts.OnClick, cells[7])
check(emotesPerformed[#emotesPerformed] == "DANCE",
      "clicking an emote performed '"
      .. tostring(emotesPerformed[#emotesPerformed]) .. "'")
check(not pickerFrame.shown, "the picker stayed open after an emote was chosen")

-- An emote the client will not play must not fail in silence: the addon
-- falls back to the command and says what happened, once.
brokenEmotes["DANCE"] = true
local before = #chatLog
editBox:SetText("недописанная строка")
click(3)
pcall(cells[7].scripts.OnClick, cells[7])
check(slashRun[#slashRun] == "/танец",
      "a refused emote did not fall back to its command, ran '"
      .. tostring(slashRun[#slashRun]) .. "'")
-- The fallback borrows the edit box, so whatever was half-typed in it has
-- to be there afterwards.
check(editBox.text == "недописанная строка",
      "the fallback left '" .. tostring(editBox.text) .. "' in the edit box")
check(#chatLog == before + 1,
      "a refused emote produced " .. (#chatLog - before) .. " messages, expected 1")
check(chatLog[#chatLog]:find("DANCE", 1, true) ~= nil
      and chatLog[#chatLog]:find("танец", 1, true) ~= nil,
      "the message does not say which emote broke and what was run instead: "
      .. tostring(chatLog[#chatLog]))
click(3)
pcall(cells[7].scripts.OnClick, cells[7])
check(#chatLog == before + 1, "the same broken emote was reported twice")
check(slashRun[#slashRun] == "/танец", "the second click did not run the command")
brokenEmotes["DANCE"] = nil

-- Every Russian emote name, not just the ones the fixture covers: unique,
-- capitalised once at the front, no stray spaces, short enough for the cell.
local names = env.ChatOrbs and env.ChatOrbs.emoteNames
check(type(names) == "table", "the addon does not expose its emote names")

local function charCount(s)
    local count, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        i = i + ((b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1)
        count = count + 1
    end
    return count
end

local nameSeen, audited = {}, 0
for token, name in pairs(names or {}) do
    audited = audited + 1
    check(type(token) == "string" and token:match("^[A-Z][A-Z0-9_]*$") ~= nil,
          "emote token '" .. tostring(token) .. "' is not a bare token")
    check(type(name) == "string" and name ~= "",
          "emote " .. tostring(token) .. " has no name")
    if type(name) == "string" then
        check(not name:find("^%s") and not name:find("%s$") and not name:find("  "),
              "emote name '" .. name .. "' has a stray space")
        check(not nameSeen[name], "two emotes are both called '" .. name
              .. "' (" .. tostring(nameSeen[name]) .. ", " .. tostring(token) .. ")")
        nameSeen[name] = token
        local b1, b2 = name:byte(1), name:byte(2)
        check(b1 == 0xD0 and b2 and b2 >= 0x90 and b2 <= 0xAF,
              "emote name '" .. name .. "' does not start with a Cyrillic capital")
        local inner, i = false, 3
        while i <= #name do
            local c1, c2 = name:byte(i), name:byte(i + 1)
            if c1 == 0xD0 and c2 and c2 >= 0x90 and c2 <= 0xAF then inner = true end
            i = i + ((c1 >= 0xC0) and 2 or 1)
        end
        check(not inner, "emote name '" .. name .. "' has a capital letter inside")
        -- 17 characters is what a 144px column holds at this font size;
        -- anything longer was cut off mid-word in the list.
        check(charCount(name) <= 17,
              "emote name '" .. name .. "' is too long for the cell")
    end
end
check(audited >= 150, "only " .. audited .. " emote names are listed")

-- Right-clicking the emote orb opens the edit box instead.
editBox.text = nil
click(3, "RightButton")
check(editBox.attributes.chatType == "EMOTE",
      "right-click on the emote orb did not set chatType=EMOTE")

-- Hover and press transitions run and then detach their OnUpdate.
local function tweenFrame()
    for _, f in ipairs(allFrames) do
        if f.scripts.OnUpdate and f ~= env.ChatOrbsFrame then return f end
    end
end
local b1 = buttons()[1]
pcall(b1.scripts.OnEnter, b1)
local tf = tweenFrame()
check(tf ~= nil, "hovering did not start a transition")
for _ = 1, 20 do
    if tf.scripts.OnUpdate then tf.scripts.OnUpdate(tf, 0.016) end
end
check(tf.scripts.OnUpdate == nil, "the hover transition never detached its OnUpdate")
check(glow1.alpha > 0, "the glow did not fade in on hover")
check(orb1.width > 20, "the orb did not grow on hover")
pcall(b1.scripts.OnMouseDown, b1)
pcall(b1.scripts.OnMouseUp, b1)
pcall(b1.scripts.OnLeave, b1)
for _ = 1, 20 do
    if tf.scripts.OnUpdate then tf.scripts.OnUpdate(tf, 0.016) end
end
check(glow1.alpha == 0, "the glow did not fade out")
check(orb1.width == 20, "the orb did not return to its resting size")

-- Hover, press, drag and hide on every orb.
for index = 1, #buttons() do
    local b = buttons()[index]
    for _, script in ipairs({ "OnEnter", "OnMouseDown", "OnMouseUp", "OnLeave",
                              "OnDragStart", "OnDragStop", "OnHide" }) do
        local ok, e = pcall(b.scripts[script], b)
        check(ok, script .. " on button " .. index .. " errored: " .. tostring(e))
    end
end
check(#tooltipLines >= 2, "the tooltip has no body line")

-- Dragging persists a position.
dock.simLeft, dock.simBottom = 310, 420
pcall(dock.scripts.OnDragStart, dock)
pcall(dock.scripts.OnDragStop, dock)
check(env.ChatOrbsDB.x and math.abs(env.ChatOrbsDB.x - 310) < 1
      and env.ChatOrbsDB.y and math.abs(env.ChatOrbsDB.y - 420) < 1,
      "dragging saved " .. tostring(env.ChatOrbsDB.x) .. ","
      .. tostring(env.ChatOrbsDB.y) .. ", expected about 310,420")

-- State changes add and remove orbs.
world.inGroup = true; fire("GROUP_ROSTER_UPDATE")
check(captions() == "С Гр К Э Ш Б 1 2 3 4",
      "joining a party gave '" .. captions() .. "'")
-- Группа is second, right after Сказать, which is the order asked for.
check(buttons()[2].entry.key == "PARTY", "the party orb is not the second one")
check(buttons()[3].entry.key == "YELL", "Крик is not third once there is a party")
-- Two-character captions are drawn a point smaller so they fit the orb.
check(captionOf(buttons()[2]).font and captionOf(buttons()[2]).font[2] == 10,
      "the caption Гр is not drawn smaller than a single letter")
check(captionOf(buttons()[1]).font and captionOf(buttons()[1]).font[2] == 12,
      "the single-letter caption С changed size")
check(captionOf(buttons()[1]).shadowColor ~= nil,
      "the caption has no shadow, so a dark glyph has nothing to stand against")
world.inRaid = true; fire("GROUP_ROSTER_UPDATE")
check(captions() == "С Гр К Э Ш Б Р 1 2 3 4",
      "joining a raid gave '" .. captions() .. "'")
world.inGuild = true; fire("PLAYER_GUILD_UPDATE")
check(captions() == "С Гр К Э Ш Б Р Ги Оф 1 2 3 4",
      "joining a guild gave '" .. captions() .. "'")
-- No two orbs may read the same, or the row cannot be told apart at a glance.
local capSeen = {}
for _, b in ipairs(buttons()) do
    local text = captionOf(b).text
    check(not capSeen[text], "two orbs are both captioned '" .. tostring(text) .. "'")
    capSeen[text] = true
end
world.inGroup, world.inRaid, world.inGuild = false, false, false
fire("GROUP_ROSTER_UPDATE"); fire("PLAYER_GUILD_UPDATE")
check(captions() == expected, "leaving everything did not restore the base row")

-- No channels at all must not break anything.
local savedChannels = world.channels
world.channels = {}
fire("CHANNEL_UI_UPDATE")
check(captions() == "С К Э Ш Б", "with no channels the row was '" .. captions() .. "'")
click(1)
world.channels = savedChannels
fire("CHANNEL_UI_UPDATE")

-- Old-style GetChannelList returning (id, name) pairs still parses.
env.GetChannelList = function() return 1, "Общий", 2, "Торговля" end
fire("CHANNEL_UI_UPDATE")
check(captions() == "С К Э Ш Б 1 2", "pair-style channel list gave '" .. captions() .. "'")
env.GetChannelList = function()
    local out = {}
    for _, c in ipairs(world.channels) do
        out[#out + 1] = c[1]; out[#out + 1] = c[2]; out[#out + 1] = c[3]
    end
    return unpack(out)
end
fire("CHANNEL_UI_UPDATE")

-- Slash commands.
local slash = env.SlashCmdList["CHATORBS"]
check(env.SLASH_CHATORBS1 == "/chatorbs", "the slash command is not /chatorbs")
local function run(args)
    local ok, e = pcall(slash, args)
    check(ok, "'/chatorbs " .. args .. "' errored: " .. tostring(e))
end
run("")
run("lock");    check(env.ChatOrbsDB.locked == true, "lock did not set the flag")
check(dock.mouse == false, "a locked dock still captures the mouse")
pcall(dock.scripts.OnDragStart, dock)
check(dock.isMoving ~= true, "a locked dock still started moving")
run("unlock");  check(env.ChatOrbsDB.locked == false, "unlock did not clear the flag")
check(dock.mouse == true, "an unlocked dock does not capture the mouse")
run("hide");    check(dock.shown == false, "hide did not hide the dock")
run("show");    check(dock.shown == true, "show did not show the dock")
-- Scales snap to a whole or half pixel per unit, so the applied value is not
-- the requested one; what matters is that the result lands on the grid.
local function pixelsPerUnit(scale) return scale * 1080 / 768 end
run("scale 1.5")
check(math.abs(pixelsPerUnit(dock.scale) * 2 % 1) < 1e-6,
      "scale 1.5 snapped to " .. dock.scale .. " = "
      .. pixelsPerUnit(dock.scale) .. " px per unit, not a half-pixel step")
check(math.abs(dock.scale - 1.5) < 0.5, "the snap moved the scale too far")
local snapped = dock.scale
run("scale 9");   check(dock.scale == snapped, "an out-of-range scale was applied anyway")
run("scale");     check(dock.scale == snapped, "a bare scale query changed the scale")
run("reset")
check(math.abs(pixelsPerUnit(dock.scale) * 2 % 1) < 1e-6,
      "reset left the dock off the pixel grid at scale " .. dock.scale)
check(math.abs(dock.scale - 1) < 0.5, "reset moved the scale too far from 1")
check(env.ChatOrbsDB.scale == 1, "reset did not store scale 1")

-- The dock's corner is rounded onto a whole physical pixel too.
dock.simLeft, dock.simBottom = 310.37, 420.81
pcall(dock.scripts.OnDragStart, dock)
pcall(dock.scripts.OnDragStop, dock)
check(math.abs(env.ChatOrbsDB.x * dock.scale % 1) < 1e-6,
      "the saved x (" .. tostring(env.ChatOrbsDB.x) .. ") is not on a whole pixel")
check(math.abs(env.ChatOrbsDB.y * dock.scale % 1) < 1e-6,
      "the saved y (" .. tostring(env.ChatOrbsDB.y) .. ") is not on a whole pixel")
check(env.ChatOrbsDB.x ~= nil, "reset did not store a fresh position")
run("nonsense")

-- Sticky channel: write to the party, press Enter, and the edit box has to
-- come back to the party rather than to Say.
world.inGroup = true; fire("GROUP_ROSTER_UPDATE")
check(env.ChatOrbsDB.sticky == true, "the sticky option is not on by default")
check(env.ChatTypeInfo.PARTY.sticky == 1, "the party chat type was not made sticky")
check(env.ChatTypeInfo.SAY.sticky == 1, "say was not made sticky")
check(env.ChatTypeInfo.YELL.sticky ~= 1,
      "yell was made sticky, which is how a conversation ends up yelled")
check(env.ChatTypeInfo.EMOTE.sticky ~= 1, "emote was made sticky")

editBox.attributes.stickyType = nil
click(2)
check(editBox.attributes.chatType == "PARTY", "orb 2 is not Группа")
check(editBox.attributes.stickyType == "PARTY",
      "clicking Группа left stickyType at '"
      .. tostring(editBox.attributes.stickyType) .. "'")
click(3)
check(editBox.attributes.chatType == "YELL", "orb 3 is not Крик")
check(editBox.attributes.stickyType == "PARTY",
      "a yell overwrote the sticky channel")
click(7)
check(editBox.attributes.stickyType == "CHANNEL",
      "a numbered channel did not stick")

run("sticky off")
check(env.ChatOrbsDB.sticky == false, "'sticky off' did not clear the flag")
check(env.ChatTypeInfo.PARTY.sticky ~= 1,
      "turning the option off did not put the game's own flags back")
editBox.attributes.stickyType = nil
click(2)
check(editBox.attributes.stickyType == nil,
      "the option is off and the channel stuck anyway")
run("sticky")
check(env.ChatOrbsDB.sticky == true, "bare 'sticky' did not toggle back on")
check(env.ChatTypeInfo.PARTY.sticky == 1, "toggling back on did not set the flag")

-- The marker has to follow its own orb when the row is rebuilt under it.
world.inGroup = false; fire("GROUP_ROSTER_UPDATE")
click(7)                                    -- channel 2, seventh orb when solo
check(buttons()[7].entry.key == "CHANNEL2", "orb 7 is not channel 2")
world.inGroup = true; fire("GROUP_ROSTER_UPDATE")
check(buttons()[8].entry.key == "CHANNEL2",
      "channel 2 did not shift along when the party orb appeared")
check(marker.points.CENTER and marker.points.CENTER.rel == buttons()[8],
      "the marker stayed under the orb that moved out from under it")
world.inGroup = false; fire("GROUP_ROSTER_UPDATE")

-- Texture-free fallback mode.
run("flat")
check(env.ChatOrbsDB.flat == true, "flat did not set the flag")
-- Checked on Крик, not on Сказать: a white orb cannot tell a kept colour from
-- a lost one.
local orbAfter = textureOf(buttons()[2], "ARTWORK")
check(buttons()[2].entry.key == "YELL", "orb 2 is not Крик")
check(orbAfter.colorTexture ~= nil, "flat mode left a texture file on the orb")
check(orbAfter.color and math.abs(orbAfter.color[1] - 1) < 1e-9
      and math.abs(orbAfter.color[2] - 0.25) < 1e-9,
      "flat mode lost the channel colour")
click(1)
run("flat")
check(env.ChatOrbsDB.flat == false, "flat did not toggle back")
check(textureOf(buttons()[1], "ARTWORK").texture:find("Orb%.blp$"),
      "leaving flat mode did not restore the texture")

-- ruRU captions must not follow the client globals where those start with the
-- wrong letter. On the real client SAY reads as "Р..." and the Battle.net
-- whisper as "О...", which is what the in-game screenshot showed.
env.SAY = "Разговор"
env.BN_WHISPER = "Ответить через Battle.net"
fire("CHANNEL_UI_UPDATE")
check(captions() == expected,
      "odd ruRU globals leaked into the captions: '" .. captions() .. "'")
local sayTooltip
pcall(buttons()[1].scripts.OnEnter, buttons()[1])
sayTooltip = tooltipLines[1]
check(sayTooltip == "Сказать",
      "the Say tooltip reads '" .. tostring(sayTooltip) .. "', expected 'Сказать'")
pcall(buttons()[1].scripts.OnLeave, buttons()[1])

env.SAY = "Сказать"
env.BN_WHISPER = nil
fire("CHANNEL_UI_UPDATE")
-- Other locales still derive the letter from the client's own global. That
-- path cannot be exercised by switching GetLocale here, because the addon
-- reads the locale once at load, as the game does. It is covered by the
-- channel captions, which are always derived from the channel name.

-- Clicking with the chat helpers missing still reaches the slash fallback.
env.ChatEdit_UpdateHeader = nil
editBox.text = nil
click(1)
check(editBox.text == "/s ", "without ChatEdit_UpdateHeader the fallback did not fire")

-- ---------------------------------------------------------------------------
print(string.format("%d checks run", checks))
if #failures == 0 then
    print("ALL PASS")
else
    print(#failures .. " FAILURE(S):")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
