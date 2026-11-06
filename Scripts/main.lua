-- Zone IFF: faction and foe marker for the NPC under the crosshair.
-- Copyright (C) 2026 Maxandre Ogeret
-- SPDX-License-Identifier: GPL-3.0-or-later

-- Everything runs in one game thread loop: widgets and engine calls are not
-- thread safe. The game has no per-frame Blueprint function to hook.

local VERSION = "1.2.0"

local UEHelpers = require("UEHelpers")
local FactionReader = require("FactionReader")
local okConfig, Config = pcall(require, "ZoneIFFConfig")
-- Only an explicit false disables a key.
local function Enabled(Key)
    return not (okConfig and type(Config) == "table" and Config[Key] == false)
end
local FOE_MARKER = Enabled("FoeMarker")
local LABEL = Enabled("Label")
local CROSSHAIR_COLOR = Enabled("CrosshairColor")

local GetPlayerController = UEHelpers.GetPlayerController
local GetKismetSystemLibrary = UEHelpers.GetKismetSystemLibrary

local TICK_MS = 8
-- Seconds between HUD checks.
local HUD_CHECK_INTERVAL = 0.5
-- Seconds between faction lookups.
local LOOKUP_INTERVAL = 0.06
local MARKER_SCALE = 0.5
local LABEL_SCALE = 0.75
-- HUD units below the X.
local LABEL_OFFSET_Y = 26.0
-- Aim point distance (cm). The weapon is off the camera axis, so a
-- nearer point drifts.
local AIM_DISTANCE = 10000.0
local TRACE_DISTANCE = 50000.0

-- ERelationLevel
local RELATION_ENEMY = 0
local NO_TARGET = 5

local RelationColors = {
    [0] = { R = 1.00, G = 0.10, B = 0.10, A = 1.0 },
    [1] = { R = 1.00, G = 0.50, B = 0.10, A = 1.0 },
    [2] = { R = 1.00, G = 0.82, B = 0.10, A = 1.0 },
    [3] = { R = 0.20, G = 1.00, B = 0.20, A = 1.0 }
}
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
-- Image properties of a crosshair variant. Some variants lack some.
local CROSSHAIR_IMAGES = { "Point", "circle", "DownLine", "LeftLine",
    "RightLine", "UpLine" }

-- Faction SID to in-game name. Unknown SIDs show raw.
local FactionNames = {
    Neutrals = "Loners",
    Varta = "Ward",
    IkarVarta = "Ward",
    EnemyVarta = "Ward",
    Duty = "Duty",
    Freedom = "Freedom",
    Monolith = "Monolith",
    Noon = "Noon",
    Spark = "Spark",
    Corpus = "Corps",
    Bandits = "Bandits",
    SultanBandits = "Bandits",
    NeutralBandits = "Bandits",
    Militaries = "IPSF",
    NeutralMSOP = "IPSF",
    Mercenaries = "Mercenaries",
    Diggers = "Scavengers",
    Scientists = "Scientists",
    SIRCAA_Scientist = "Scientists",
    MALACHITE_Scientist = "Scientists"
}

local VIS_SHOWN = 0 -- ESlateVisibility::Visible
local VIS_HIDDEN = 2 -- ESlateVisibility::Hidden
local MARKER_FILE = "FoeMarker.png"
-- Max log lines.
local LOG_LIMIT = 300

local Marker = nil
local Label = nil
local WidgetHUD = nil
local MarkerShown = false
local LabelShown = false
local Offset = { X = 0.0, Y = 0.0 }
local LastHUDCheck = -1.0
local LastLookup = -1.0
-- Cleared when the relation changes, so a new target never shows the old name.
local LabelText = nil
local LastRelation = nil
-- Last values sent to the label.
local DrawnText = nil
local DrawnRelation = nil
local LoggedNPCs = {}
local ShowCount = 0
local LoggedErrors = {}
local LogCount = 0
-- Looked up again only when invalid.
local CachedController = nil
local Layout = nil
local AgentClass = nil
-- Images of the active crosshair variant, keyed on its address.
local CrosshairVariant = nil
local CrosshairImages = {}

local function Log(Text)
    if LogCount < LOG_LIMIT then
        LogCount = LogCount + 1
        print("[ZoneIFF] " .. Text .. "\n")
    end
end

local function LogOnce(Key, Text)
    if not LoggedErrors[Key] then
        LoggedErrors[Key] = true
        Log(Text)
    end
end

-- Result of Fn, or nil if it raised.
local function Try(Fn, ...)
    local ok, Result = pcall(Fn, ...)
    return ok and Result or nil
end

local function IsValid(Object)
    return Object and Try(Object.IsValid, Object) == true or false
end

local function FullName(Object)
    return tostring(Try(Object.GetFullName, Object) or "")
end

local function Address(Object)
    return Try(Object.GetAddress, Object)
end

local function SetVisible(Widget, Shown)
    pcall(function()
        Widget:SetVisibility(Shown and VIS_SHOWN or VIS_HIDDEN)
    end)
end

local function ScriptDirectory()
    local Path = nil
    if debug and type(debug.getinfo) == "function" then
        local Source = debug.getinfo(1, "S").source
        if Source and Source:sub(1, 1) == "@" then
            Path = Source:sub(2)
        end
    end
    -- Fallback: next to this script.
    if not Path and package and type(package.searchpath) == "function" then
        Path = package.searchpath("FactionReader", package.path)
    end
    return Path and Path:match("^(.*[/\\])") or nil
end

-- Last W_GameHUD_C on screen. HUDs from earlier loads can still exist.
local function FindActiveHUD()
    local Active = nil
    for _, HUD in ipairs(Try(FindAllOf, "W_GameHUD_C") or {}) do
        if IsValid(HUD) and Try(HUD.IsInViewport, HUD) then
            Active = HUD
        end
    end
    return Active
end

-- The HUD root is an Overlay: center the widget in its slot.
local function AddCentered(Root, Widget)
    local Slot = Root:AddChild(Widget)
    Slot:SetHorizontalAlignment(2) -- HAlign_Center
    Slot:SetVerticalAlignment(2) -- VAlign_Center
end

-- Texture import is not thread safe: call from the game thread.
local function CreateWidgets(HUD)
    local Tree = HUD.WidgetTree
    if not IsValid(Tree) then
        return nil
    end
    local Root = Tree.RootWidget
    local ImageClass = StaticFindObject("/Script/UMG.Image")
    local TextClass = StaticFindObject("/Script/UMG.TextBlock")
    local Rendering = StaticFindObject(
        "/Script/Engine.Default__KismetRenderingLibrary")
    local Directory = ScriptDirectory()
    if not IsValid(Root) or not IsValid(ImageClass) or not IsValid(TextClass)
    or not IsValid(Rendering) or not Directory then
        Log("create failed: root/classes/RenderingLibrary/script dir missing, dir="
            .. tostring(Directory))
        return nil
    end

    local Texture = Rendering:ImportFileAsTexture2D(HUD,
        Directory .. MARKER_FILE)
    if not IsValid(Texture) then
        Log("create failed: texture import from " .. Directory .. MARKER_FILE)
        return nil
    end

    local Image = StaticConstructObject(ImageClass, Tree)
    local Text = StaticConstructObject(TextClass, Tree)
    if not IsValid(Image) or not IsValid(Text) then
        return nil
    end
    -- Native size, 28 px.
    Image:SetBrushFromTexture(Texture, true)
    Image:SetVisibility(VIS_HIDDEN)
    Image:SetRenderScale({ X = MARKER_SCALE, Y = MARKER_SCALE })
    Text:SetText(FText(""))
    Text:SetJustification(1)
    Text:SetVisibility(VIS_HIDDEN)
    Text:SetRenderScale({ X = LABEL_SCALE, Y = LABEL_SCALE })
    pcall(function()
        Text:SetShadowOffset({ X = 1.0, Y = 1.0 })
        Text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 })
    end)
    AddCentered(Root, Image)
    AddCentered(Root, Text)
    Log("widgets created on " .. FullName(Root))
    return Image, Text
end

local Ticks = 0

local function Now()
    if os and os.clock then
        return os.clock()
    end
    -- No clock: use the loop period.
    Ticks = Ticks + 1
    return Ticks * TICK_MS / 1000.0
end

local function EnsureWidgets(Time)
    local Ready = IsValid(Marker) and IsValid(Label) and IsValid(WidgetHUD)
    if Ready and Time - LastHUDCheck < HUD_CHECK_INTERVAL then
        return true
    end
    LastHUDCheck = Time
    -- FindAllOf stalls the game thread: scan only once our HUD is gone.
    if Ready and Try(WidgetHUD.IsInViewport, WidgetHUD) then
        return true
    end

    local HUD = FindActiveHUD()
    if not HUD then
        Marker, Label, WidgetHUD = nil, nil, nil
        return false
    end
    if IsValid(Marker) and IsValid(Label) and IsValid(WidgetHUD)
    and Address(HUD) == Address(WidgetHUD) then
        return true
    end

    Marker, Label, WidgetHUD = nil, nil, nil
    local ok, Image, Text = pcall(CreateWidgets, HUD)
    if not ok then
        LogOnce("create", "create error: " .. tostring(Image))
    elseif Image then
        Marker, Label, WidgetHUD = Image, Text, HUD
        CachedController = Try(HUD.GetOwningPlayer, HUD)
        MarkerShown, LabelShown = false, false
        DrawnText, DrawnRelation = nil, nil
        CrosshairVariant, CrosshairImages = nil, {}
    end
    return false
end

-- Set from the HUD's owner on each new HUD: a map load can free the old
-- controller without it ever reading as invalid. UEHelpers runs FindAllOf.
local function PlayerController()
    if not IsValid(CachedController) then
        CachedController = GetPlayerController()
    end
    return CachedController
end

-- Screen offset of the weapon aim point. Follows sway when aiming down
-- sights.
local function AimOffset(Controller, Pawn)
    if not IsValid(Layout) then
        Layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        if not IsValid(Layout) then
            return nil
        end
    end
    local Aim = Pawn:GetAimTransform(true)
    local T, Q = Aim.Translation, Aim.Rotation
    -- Quaternion forward (X) axis.
    local FX = 1.0 - 2.0 * (Q.Y * Q.Y + Q.Z * Q.Z)
    local FY = 2.0 * (Q.X * Q.Y + Q.W * Q.Z)
    local FZ = 2.0 * (Q.X * Q.Z - Q.W * Q.Y)
    local Target = {
        X = T.X + FX * AIM_DISTANCE,
        Y = T.Y + FY * AIM_DISTANCE,
        Z = T.Z + FZ * AIM_DISTANCE
    }
    local Position = {}
    if not Layout:ProjectWorldLocationToWidgetPosition(
        Controller, Target, Position, true) then
        return nil
    end
    local Size = Layout:GetViewportSize(Controller)
    local Scale = Layout:GetViewportScale(Controller)
    if not Scale or Scale <= 0 then
        return nil
    end
    -- DPI scaled, relative to the viewport center.
    return {
        X = Position.X - Size.X / Scale / 2.0,
        Y = Position.Y - Size.Y / Scale / 2.0
    }
end

-- Unit vector for a rotator, in degrees.
local function Direction(Rotation)
    local Pitch, Yaw = math.rad(Rotation.Pitch), math.rad(Rotation.Yaw)
    return {
        X = math.cos(Pitch) * math.cos(Yaw),
        Y = math.cos(Pitch) * math.sin(Yaw),
        Z = math.sin(Pitch)
    }
end

-- The hit component's owner chain, up to the first Agent. A held weapon is
-- owned by the NPC holding it.
local function OwningAgent(Component)
    if not IsValid(AgentClass) then
        AgentClass = StaticFindObject("/Script/Stalker2.Agent")
    end
    local Object = Component
    for _ = 1, 3 do
        Object = IsValid(Object) and Try(Object.GetOwner, Object)
        if not IsValid(Object) then
            return nil
        end
        if Try(Object.IsA, Object, AgentClass) then
            return Object
        end
    end
    return nil
end

-- NPC under the camera center.
local function TraceNPC(Controller, Pawn)
    local System = GetKismetSystemLibrary()
    local Camera = Controller.PlayerCameraManager
    if not IsValid(System) or not IsValid(Camera) then
        return nil
    end
    local From = Camera:GetCameraLocation()
    local Dir = Direction(Camera:GetCameraRotation())
    local To = {
        X = From.X + Dir.X * TRACE_DISTANCE,
        Y = From.Y + Dir.Y * TRACE_DISTANCE,
        Z = From.Z + Dir.Z * TRACE_DISTANCE
    }
    local Hit = {}
    local Clear = { R = 0, G = 0, B = 0, A = 0 }
    -- Visibility channel, simple collision, no debug draw, ignore the player.
    if not System:LineTraceSingle(Pawn, From, To, 0, false, {}, 0, Hit,
        true, Clear, Clear, 0.0) then
        return nil
    end
    return OwningAgent(Try(function() return Hit.Component:Get() end))
end

local function LookupFaction(Relation)
    local Controller = PlayerController()
    if not IsValid(Controller) or not IsValid(Controller.Pawn) then
        return
    end
    local NPC = TraceNPC(Controller, Controller.Pawn)
    if not NPC then
        return
    end
    local SID, Detail = FactionReader.Faction(NPC)
    -- A failed read clears the label.
    LabelText = SID and (FactionNames[SID] or SID) or nil
    local Key = Address(NPC)
    if Key and not LoggedNPCs[Key] then
        LoggedNPCs[Key] = true
        -- Keep the class and the last path segment.
        local Full = FullName(NPC)
        local Name = (Full:match("^(%S+)") or "?") .. " "
            .. (Full:match("([^.:]+)$") or "?")
        Log(string.format("npc=%s relation=%s faction=%s detail=%s",
            Name, tostring(Relation), tostring(SID), tostring(Detail)))
    end
end

local function Tick(Time)
    local Controller = PlayerController()
    if not IsValid(Controller) then
        return false, false
    end
    local Pawn = Controller.Pawn
    if not IsValid(Pawn) then
        return false, false
    end
    local Relation = tonumber(Pawn:GetLastCrosshairRelation())
    if Relation ~= LastRelation then
        LastRelation = Relation
        LabelText = nil
        LastLookup = -1.0
    end
    if Relation == nil or Relation == NO_TARGET then
        return false, false
    end

    local ok, Result = pcall(AimOffset, Controller, Pawn)
    if ok and Result then
        Offset = Result
    elseif not ok then
        LogOnce("aim", "aim error: " .. tostring(Result))
    end
    pcall(function()
        Marker:SetRenderTranslation(Offset)
        Label:SetRenderTranslation({ X = Offset.X,
            Y = Offset.Y + LABEL_OFFSET_Y })
    end)

    local Text = LabelText
    if Text and (Text ~= DrawnText or Relation ~= DrawnRelation) then
        DrawnText, DrawnRelation = Text, Relation
        pcall(function()
            Label:SetText(FText(Text))
            Label:SetColorAndOpacity({
                SpecifiedColor = RelationColors[Relation]
                    or RelationColors[2],
                ColorUseRule = 0
            })
        end)
    end
    return FOE_MARKER and Relation == RELATION_ENEMY, Text ~= nil
end

-- Colors the game's crosshair. Writes every frame: the game can reset it.
local function ColorCrosshair(Relation)
    local Variant = WidgetHUD.Crosshair.CurrCrosshairWidget
    if not IsValid(Variant) then
        return
    end
    local Key = Address(Variant)
    local Stale = Key ~= CrosshairVariant
    if not Stale then
        for _, Image in ipairs(CrosshairImages) do
            if not IsValid(Image) then
                Stale = true
                break
            end
        end
    end
    if Stale then
        CrosshairVariant, CrosshairImages = Key, {}
        for _, Name in ipairs(CROSSHAIR_IMAGES) do
            local Image = Try(function() return Variant[Name] end)
            if IsValid(Image) then
                table.insert(CrosshairImages, Image)
            end
        end
    end
    local Color = RelationColors[Relation] or WHITE
    for _, Image in ipairs(CrosshairImages) do
        pcall(function() Image:SetColorAndOpacity(Color) end)
    end
end

local function Update()
    local Time = Now()
    local okWidgets, Ready = pcall(EnsureWidgets, Time)
    if not okWidgets or not Ready then
        return
    end
    local ok, ShowMarker, ShowLabel = pcall(Tick, Time)
    if not ok then
        LogOnce("tick", "tick error: " .. tostring(ShowMarker))
        ShowMarker, ShowLabel = false, false
    end
    if ShowMarker ~= MarkerShown then
        SetVisible(Marker, ShowMarker)
        MarkerShown = ShowMarker
        if ShowMarker and ShowCount < 10 then
            ShowCount = ShowCount + 1
            Log(string.format("X shown at offset %.0f,%.0f", Offset.X, Offset.Y))
        end
    end
    if ShowLabel ~= LabelShown then
        SetVisible(Label, ShowLabel)
        LabelShown = ShowLabel
    end
    if CROSSHAIR_COLOR then
        local okColor, Err = pcall(ColorCrosshair, LastRelation)
        if not okColor then
            LogOnce("crosshair", "crosshair error: " .. tostring(Err))
        end
    end
    -- The trace is slow: run it after the widget update, every
    -- LOOKUP_INTERVAL. It only feeds the label.
    if LABEL and LastRelation ~= nil and LastRelation ~= NO_TARGET
    and Time - LastLookup >= LOOKUP_INTERVAL then
        LastLookup = Time
        local okLookup, Err = pcall(LookupFaction, LastRelation)
        if not okLookup then
            LogOnce("lookup", "lookup error: " .. tostring(Err))
        end
    end
end

FactionReader.Init(Log)

print("[ZoneIFF] " .. VERSION .. " loaded (built for game build 26123434, update 2.1)\n")

local function Step()
    local ok, Err = pcall(Update)
    if not ok then
        LogOnce("update", "update error: " .. tostring(Err))
    end
end

-- Widgets and engine calls are only safe on the game thread, so there is no
-- LoopAsync fallback.
if EngineTickAvailable and pcall(LoopInGameThreadAfterFrames, 1, Step) then
    Log("loop: game thread, every frame")
elseif pcall(LoopInGameThreadWithDelay, TICK_MS, Step) then
    Log("loop: game thread, every " .. TICK_MS .. " ms")
else
    Log("not started: this UE4SS build has no LoopInGameThreadWithDelay")
end
