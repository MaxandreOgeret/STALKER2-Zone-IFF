-- Copyright (C) 2026 Maxandre Ogeret
-- SPDX-License-Identifier: GPL-3.0-or-later

-- Reads an NPC's faction SID from native memory (build 26123434):
--
--   Agent +0x648 IObjBase vtable (gate), +0x650 SObj
--   SObj +0x120 faction id, +0x140 personal id
--   registry exe+0xb0f4910: buckets, count (+8), next id (+0x18).
--   record = node - 0x80: +0x00 id, +0x18 FName SID, +0x30 parent
--
-- Reads point custom properties over the Tags array of a private, rooted
-- Actor at the address, read one element, then reset the array.

local Reader = {}

-- Same layout UCppMediator::GetGUID reads.
local OFF_OBJBASE = 0x648
local OFF_SOBJ = 0x650
local RVA_AGENT_OBJBASE_VTABLE = 0x8c00440
local OFF_FACTION_ID = 0x120
local OFF_PERSONAL_ID = 0x140
local RVA_REGISTRY = 0xb0f4910
local RVA_ACTOR_VTABLE = 0x85fcbb0
-- `mov rax,[rcx+0x140]; ret`. If these bytes moved, the offsets are stale.
local RVA_CHECK = 0x26821ba
local CHECK_BYTES = 0xC300000140818B48
local RVA_FNAME_TOSTRING = 0x1fee8d2
local MAX_CHAIN = 64
local MAX_BASE_ATTEMPTS = 5
-- PropertyTypes.ArrayProperty has size 0, which RegisterCustomProperty
-- rejects.
local ARRAY_TYPE = {
    Name = "ArrayProperty",
    Size = 16,
    FFieldClassPointer = PropertyTypes.ArrayProperty.FFieldClassPointer,
    StaticPointer = 0
}

local Scratch = nil
local Base = nil
local Disabled = false
local BaseAttempts = 0
local NameCache = {}
local Log = print

local function IsValid(Object)
    if not Object then
        return false
    end
    local ok, Valid = pcall(Object.IsValid, Object)
    return ok and Valid == true
end

-- Unaligned reads are fine on x64.
local function PlausibleAddress(Value)
    return math.type(Value) == "integer" and Value > 0x10000
        and Value < 0x7fffffffffff
end

-- Heap pointers are 8-byte aligned.
local function PlausiblePointer(Value)
    return PlausibleAddress(Value) and Value % 8 == 0
end

local function Register()
    local function Prop(Name, Type, Relative, Inner)
        local Info = {
            Name = Name,
            Type = Type,
            BelongsToClass = "/Script/Engine.Actor",
            OffsetInternal = { Property = "Tags", RelativeOffset = Relative }
        }
        if Inner then
            Info.ArrayProperty = { Type = Inner }
        end
        RegisterCustomProperty(Info)
    end
    Prop("FR_Ptr", PropertyTypes.Int64Property, 0)
    Prop("FR_Num", PropertyTypes.IntProperty, 8)
    Prop("FR_Max", PropertyTypes.IntProperty, 12)
    Prop("FR_I64", ARRAY_TYPE, 0, PropertyTypes.Int64Property)
    Prop("FR_Name", ARRAY_TYPE, 0, PropertyTypes.NameProperty)
end

local function GetScratch()
    if IsValid(Scratch) then
        return Scratch
    end
    local Class = StaticFindObject("/Script/Engine.Actor")
    local Outer = FindFirstOf("Stalker2GameEngine")
    if not IsValid(Outer) then
        Outer = FindFirstOf("GameEngine")
    end
    if not IsValid(Class) or not IsValid(Outer) then
        return nil
    end
    -- Rooted: GC must never free Tags while it points at game memory.
    local Object = StaticConstructObject(Class, Outer,
        FName("FactionReaderScratch"), EObjectFlags.RF_MarkAsRootSet)
    if not IsValid(Object) or Object.FR_Num ~= 0 or Object.FR_Ptr ~= 0 then
        return nil
    end
    Scratch = Object
    return Scratch
end

local function ReadAt(Address, ArrayName)
    if not PlausibleAddress(Address) then
        return nil
    end
    local Object = GetScratch()
    if not Object then
        return nil
    end
    Object.FR_Ptr = Address
    Object.FR_Max = 1
    Object.FR_Num = 1
    local ok, Value = pcall(function()
        local Element = Object[ArrayName][1]
        if ArrayName == "FR_Name" then
            return Element:ToString()
        end
        return Element
    end)
    -- Always reset, even after a failed set.
    pcall(function() Object.FR_Num = 0 end)
    pcall(function() Object.FR_Max = 0 end)
    pcall(function() Object.FR_Ptr = 0 end)
    if not ok then
        return nil
    end
    return Value
end

local function Read64(Address)
    return ReadAt(Address, "FR_I64")
end

local function ReadName(Address)
    return ReadAt(Address, "FR_Name")
end

local function IsGameBase(Candidate)
    if not PlausiblePointer(Candidate) or Candidate % 0x10000 ~= 0 then
        return false
    end
    local Header = Read64(Candidate)
    local Check = Read64(Candidate + RVA_CHECK)
    return Header ~= nil and Header & 0xFFFF == 0x5A4D
        and Check == CHECK_BYTES
end

-- Fallback: UE4SS logs "FName::ToString address: 0x...".
local function BaseFromLog()
    local File = io.open("ue4ss\\UE4SS.log", "r")
        or io.open("UE4SS.log", "r")
    if not File then
        return nil
    end
    local Found = nil
    for Line in File:lines() do
        local Hex = Line:match("FName::ToString address: 0x(%x+)")
        if Hex then
            Found = tonumber(Hex, 16) - RVA_FNAME_TOSTRING
            break
        end
    end
    File:close()
    return Found
end

local function FindBase()
    local Default = StaticFindObject("/Script/Engine.Default__Actor")
    if IsValid(Default) then
        local VTable = Read64(Default:GetAddress())
        if VTable and IsGameBase(VTable - RVA_ACTOR_VTABLE) then
            Log("base from Actor vtable")
            return VTable - RVA_ACTOR_VTABLE
        end
    end
    local Candidate = BaseFromLog()
    if Candidate and IsGameBase(Candidate) then
        Log("base from UE4SS.log")
        return Candidate
    end
    return nil
end

function Reader.Init(Logger)
    Log = Logger or Log
    local ok, Err = pcall(Register)
    if not ok then
        Disabled = true
        Log("faction reader disabled: " .. tostring(Err))
    end
end

local function EnsureBase()
    if Base then
        return true
    end
    Base = FindBase()
    if Base then
        Log(string.format("game base 0x%x", Base))
        return true
    end
    BaseAttempts = BaseAttempts + 1
    if BaseAttempts >= MAX_BASE_ATTEMPTS then
        Disabled = true
        Log("faction reader disabled: game base not found or offsets "
            .. "changed (game patched?)")
    end
    return false
end

-- Record for an id, or nil and a reason.
local function FindRecord(Id)
    if math.type(Id) ~= "integer" or Id <= 0 then
        return nil, string.format("id=%s", tostring(Id))
    end
    local Registry = Base + RVA_REGISTRY
    local Buckets = Read64(Registry)
    local Count = Read64(Registry + 8)
    local NextId = Read64(Registry + 0x18)
    if not PlausiblePointer(Buckets) or not Count or Count <= 0
    or Count > 1000000 or not NextId or Id >= NextId then
        return nil, string.format("registry id=%d buckets=%s count=%s next=%s",
            Id, tostring(Buckets), tostring(Count), tostring(NextId))
    end
    local Slot = Buckets + (Id % Count) * 8
    local Node = Read64(Slot)
    for _ = 1, MAX_CHAIN do
        if not PlausiblePointer(Node) or Node == Slot then
            return nil, string.format("not found id=%d", Id)
        end
        local Record = Node - 0x80
        if Read64(Record) == Id then
            return Record
        end
        Node = Read64(Node)
    end
    return nil, "chain"
end

-- The personal record must be a child of the faction record. This rejects
-- a wrong pointer.
local function FactionFromSObj(SObj)
    if not PlausiblePointer(SObj) then
        return nil, string.format("sobj=0x%x", SObj or 0)
    end
    local Faction, Detail = FindRecord(Read64(SObj + OFF_FACTION_ID))
    if not Faction then
        return nil, "faction " .. Detail
    end
    local Personal = FindRecord(Read64(SObj + OFF_PERSONAL_ID))
    if not Personal or Read64(Personal + 0x30) ~= Faction then
        return nil, "personal record not under faction "
            .. tostring(ReadName(Faction + 0x18))
    end
    local Id = Read64(Faction)
    if NameCache[Id] then
        return NameCache[Id], Id
    end
    local Name = ReadName(Faction + 0x18)
    if not Name or Name == "" or Name == "None" then
        return nil, string.format("name id=%d", Id)
    end
    NameCache[Id] = Name
    return Name, Id
end

-- Faction SID, or nil and a reason. Follows only pointers the game itself
-- follows. Never scan: Lua cannot catch an access violation.
function Reader.Faction(NPC)
    if Disabled then
        return nil, "disabled"
    end
    if not EnsureBase() then
        return nil, "no base"
    end
    local ActorAddress = NPC:GetAddress()
    local VTable = Read64(ActorAddress + OFF_OBJBASE)
    if VTable ~= Base + RVA_AGENT_OBJBASE_VTABLE then
        return nil, string.format("not an agent: vtable rva 0x%x",
            (VTable or 0) - Base)
    end
    local SObj = Read64(ActorAddress + OFF_SOBJ)
    if SObj == 0 then
        return nil, "no sobj (entity offline)"
    end
    return FactionFromSObj(SObj)
end

return Reader
