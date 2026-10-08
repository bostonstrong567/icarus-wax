#!/usr/bin/env python3
"""Tests for gameindex.py: python scripts\\test_gameindex.py"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gameindex  # noqa: E402

ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
LANGUAGE_SERVER = os.path.join(ROOT, "tools", "lua", "lua-language-server", "bin", "lua-language-server.exe")
SCRIPT = "00007FF600000001"

# One line of every shape the real dump has. Addresses are made up; the layout is the dump's own.
DUMP = r"""
[0000000000001000] Package /Script/CoreUObject [n: 1] [c: 00000000000000A0] [or: 0000000000000000]
[0000000000001100] Class /Script/CoreUObject.Object [n: 2] [c: 00000000000000B0] [or: 0000000000001000] [sps: 0000000000000000]
[0000000000001110] Function /Script/CoreUObject.Object:ExecuteUbergraph [n: 3] [c: 00000000000000C0] [or: 0000000000001100] [f: 00007FF600000001]
[0000000000001111] IntProperty /Script/CoreUObject.Object:ExecuteUbergraph:EntryPoint [o: 0] [n: 4] [c: 00007FF6000000D0] [owr: 0000000000001110]
[0000000000001120] Object /Script/CoreUObject.Default__Object [n: 5] [c: 0000000000001100] [or: 0000000000001000]
[0000000000001200] Class /Script/CoreUObject.Class [n: 6] [c: 00000000000000B0] [or: 0000000000001000] [sps: 0000000000001100]
[0000000000001300] ScriptStruct /Script/CoreUObject.Vector [n: 7] [c: 00000000000000E0] [or: 0000000000001000] [sps: 0000000000000000]
[0000000000001301] FloatProperty /Script/CoreUObject.Vector:X [o: 0] [n: 8] [c: 00007FF6000000D1] [owr: 0000000000001300]
[0000000000001302] FloatProperty /Script/CoreUObject.Vector:Y [o: 4] [n: 9] [c: 00007FF6000000D1] [owr: 0000000000001300]
[0000000000001303] FloatProperty /Script/CoreUObject.Vector:Z [o: 8] [n: A] [c: 00007FF6000000D1] [owr: 0000000000001300]
[0000000000001400] Enum /Script/CoreUObject.EAxis [n: B] [c: 00000000000000F0] [or: 0000000000001000]
[0000000000000000] EAxis::None [n: C] [v: 0]
[0000000000000000] EAxis::X [n: D] [v: 1]
[0000000000000000] EAxis::EAxis_MAX [n: E] [v: 2]
[0000000000001410] Enum /Script/CoreUObject.Default__Enum [n: F] [c: 00000000000000F0] [or: 0000000000001000]
[0000000000002000] Package /Script/Engine [n: 10] [c: 00000000000000A0] [or: 0000000000000000]
[0000000000002100] Class /Script/Engine.Actor [n: 11] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002101] BoolProperty /Script/Engine.Actor:bHidden [o: 58] [n: 12] [c: 00007FF6000000D2] [owr: 0000000000002100] [fm: 20] [bm: 20]
[0000000000002102] ByteProperty /Script/Engine.Actor:RemoteRole [o: 5F] [n: 13] [c: 00007FF6000000D3] [owr: 0000000000002100]
[0000000000002103] ArrayProperty /Script/Engine.Actor:Children [o: 120] [n: 14] [c: 00007FF6000000D4] [owr: 0000000000002100] [ai: 0000000000002104]
[0000000000002104] ObjectProperty Children./Script/Engine.Actor:Children [o: 0] [n: 14] [c: 00007FF6000000D5] [owr: 0000000000002103] [pc: 0000000000002100]
[0000000000002105] MulticastSparseDelegateProperty /Script/Engine.Actor:OnDestroyed [o: 180] [n: 15] [c: 00007FF6000000D6] [owr: 0000000000002100] [df: 0000000000002190]
[0000000000002110] Function /Script/Engine.Actor:GetActorBounds [n: 16] [c: 00000000000000C0] [or: 0000000000002100] [f: 00007FF600000100]
[0000000000002111] BoolProperty /Script/Engine.Actor:GetActorBounds:bOnlyCollidingComponents [o: 0] [n: 17] [c: 00007FF6000000D2] [owr: 0000000000002110]
[0000000000002112] StructProperty /Script/Engine.Actor:GetActorBounds:Origin [o: 4] [n: 18] [c: 00007FF6000000D7] [owr: 0000000000002110] [ss: 0000000000001300]
[0000000000002113] StructProperty /Script/Engine.Actor:GetActorBounds:BoxExtent [o: 10] [n: 19] [c: 00007FF6000000D7] [owr: 0000000000002110] [ss: 0000000000001300]
[0000000000002120] Function /Script/Engine.Actor:ReceiveBeginPlay [n: 1A] [c: 00000000000000C0] [or: 0000000000002100] [f: 00007FF600000001]
[0000000000002130] Function /Script/Engine.Actor:GetOwner [n: 1B] [c: 00000000000000C0] [or: 0000000000002100] [f: 00007FF600000101]
[0000000000002131] ObjectProperty /Script/Engine.Actor:GetOwner:ReturnValue [o: 0] [n: 1C] [c: 00007FF6000000D5] [owr: 0000000000002130] [pc: 0000000000002100]
[0000000000002140] Function /Script/Engine.Actor:GetParent [n: 1D] [c: 00000000000000C0] [or: 0000000000002100] [f: 00007FF600000102]
[0000000000002141] ObjectProperty /Script/Engine.Actor:GetParent:ReturnValue [o: 0] [n: 1C] [c: 00007FF6000000D5] [owr: 0000000000002140] [pc: 0000000000002100]
[0000000000002190] SparseDelegateFunction /Script/Engine.ActorDestroyedSignature__DelegateSignature [n: 1E] [c: 00000000000000C1] [or: 0000000000002000]
[0000000000002191] ObjectProperty /Script/Engine.ActorDestroyedSignature__DelegateSignature:DestroyedActor [o: 0] [n: 1F] [c: 00007FF6000000D5] [owr: 0000000000002190] [pc: 0000000000002100]
[0000000000002200] Class /Script/Engine.ActorComponent [n: 20] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002300] Class /Script/Engine.BlueprintFunctionLibrary [n: 21] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002400] Class /Script/Engine.Pawn [n: 22] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000002100]
[0000000000002500] Class /Script/Engine.Controller [n: 23] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000002100]
[0000000000002501] ObjectProperty /Script/Engine.Controller:Pawn [o: 250] [n: 24] [c: 00007FF6000000D5] [owr: 0000000000002500] [pc: 0000000000002400]
[0000000000002600] Class /Script/Engine.PlayerController [n: 25] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000002500]
[0000000000002700] Class /Script/Engine.Player [n: 26] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002701] ObjectProperty /Script/Engine.Player:PlayerController [o: 30] [n: 25] [c: 00007FF6000000D5] [owr: 0000000000002700] [pc: 0000000000002600]
[0000000000002710] Class /Script/Engine.LocalPlayer [n: 27] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000002700]
[0000000000002800] Class /Script/Engine.GameInstance [n: 28] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002801] ArrayProperty /Script/Engine.GameInstance:LocalPlayers [o: 38] [n: 29] [c: 00007FF6000000D4] [owr: 0000000000002800] [ai: 0000000000002802]
[0000000000002802] ObjectProperty LocalPlayers./Script/Engine.GameInstance:LocalPlayers [o: 0] [n: 29] [c: 00007FF6000000D5] [owr: 0000000000002801] [pc: 0000000000002710]
[0000000000002900] Class /Script/Engine.World [n: 2A] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002901] ObjectProperty /Script/Engine.World:GameState [o: 120] [n: 2B] [c: 00007FF6000000D5] [owr: 0000000000002900] [pc: 0000000000002A00]
[0000000000002902] ObjectProperty /Script/Engine.World:AuthorityGameMode [o: 118] [n: 2C] [c: 00007FF6000000D5] [owr: 0000000000002900] [pc: 0000000000002B00]
[0000000000002A00] Class /Script/Engine.GameStateBase [n: 2D] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000002100]
[0000000000002B00] Class /Script/Engine.GameModeBase [n: 2E] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000002100]
[0000000000002C00] Class /Script/Engine.GameViewportClient [n: 2F] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002C01] ObjectProperty /Script/Engine.GameViewportClient:World [o: 78] [n: 2A] [c: 00007FF6000000D5] [owr: 0000000000002C00] [pc: 0000000000002900]
[0000000000002C02] ObjectProperty /Script/Engine.GameViewportClient:GameInstance [o: 80] [n: 28] [c: 00007FF6000000D5] [owr: 0000000000002C00] [pc: 0000000000002800]
[0000000000002D00] Class /Script/Engine.Engine [n: 30] [c: 00000000000000B0] [or: 0000000000002000] [sps: 0000000000001100]
[0000000000002D01] ObjectProperty /Script/Engine.Engine:GameViewport [o: 780] [n: 31] [c: 00007FF6000000D5] [owr: 0000000000002D00] [pc: 0000000000002C00]
[0000000000002E00] ScriptStruct /Script/Engine.LatentActionInfo [n: 32] [c: 00000000000000E0] [or: 0000000000002000] [sps: 0000000000000000]
[0000000000002E01] IntProperty /Script/Engine.LatentActionInfo:Linkage [o: 0] [n: 33] [c: 00007FF6000000D0] [owr: 0000000000002E00]
[0000000000002F00] ScriptStruct /Script/Engine.PointerToUberGraphFrame [n: 34] [c: 00000000000000E0] [or: 0000000000002000] [sps: 0000000000000000]
[0000000000002F10] Enum /Script/Engine.ENetRole [n: 35] [c: 00000000000000F0] [or: 0000000000002000]
[0000000000000000] ROLE_None [n: 36] [v: 0]
[0000000000000000] ROLE_Authority [n: 37] [v: 3]
[0000000000000000] ROLE_MAX [n: 38] [v: 4]
[0000000000003000] Package /Script/Icarus [n: 40] [c: 00000000000000A0] [or: 0000000000000000]
[0000000000003100] Class /Script/Icarus.ActorState [n: 41] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002200]
[0000000000003101] IntProperty /Script/Icarus.ActorState:Health [o: 1D8] [n: 42] [c: 00007FF6000000D0] [owr: 0000000000003100]
[0000000000003102] IntProperty /Script/Icarus.ActorState:MaxHealth [o: 1DC] [n: 43] [c: 00007FF6000000D0] [owr: 0000000000003100]
[0000000000003103] EnumProperty /Script/Icarus.ActorState:CurrentAliveState [o: 1E0] [n: 44] [c: 00007FF6000000D8] [owr: 0000000000003100] [em: 0000000000003900]
[0000000000003104] StrProperty /Script/Icarus.ActorState:Label [o: 1E8] [n: 45] [c: 00007FF6000000D9] [owr: 0000000000003100]
[0000000000003105] NameProperty /Script/Icarus.ActorState:Tag [o: 1F8] [n: 46] [c: 00007FF6000000DA] [owr: 0000000000003100]
[0000000000003106] TextProperty /Script/Icarus.ActorState:Title [o: 200] [n: 47] [c: 00007FF6000000DB] [owr: 0000000000003100]
[0000000000003107] FloatProperty /Script/Icarus.ActorState:Shelter [o: 218] [n: 48] [c: 00007FF6000000D1] [owr: 0000000000003100]
[0000000000003108] MapProperty /Script/Icarus.ActorState:Costs [o: 220] [n: 49] [c: 00007FF6000000DC] [owr: 0000000000003100] [kp: 0000000000003109] [vp: 000000000000310A]
[0000000000003109] NameProperty Costs./Script/Icarus.ActorState:Costs_Key [o: 0] [n: 4A] [c: 00007FF6000000DA] [owr: 0000000000003108]
[000000000000310A] StructProperty Costs./Script/Icarus.ActorState:Costs [o: 8] [n: 49] [c: 00007FF6000000D7] [owr: 0000000000003108] [ss: 0000000000003800]
[000000000000310B] SetProperty /Script/Icarus.ActorState:Seen [o: 270] [n: 4B] [c: 00007FF6000000DD] [owr: 0000000000003100]
[000000000000310C] SoftObjectProperty /Script/Icarus.ActorState:Icon [o: 2C0] [n: 4C] [c: 00007FF6000000DE] [owr: 0000000000003100] [pc: 0000000000001100]
[000000000000310D] WeakObjectProperty /Script/Icarus.ActorState:Last [o: 2E8] [n: 4D] [c: 00007FF6000000DF] [owr: 0000000000003100] [pc: 0000000000002100]
[000000000000310E] ClassProperty /Script/Icarus.ActorState:Kind [o: 2F0] [n: 4E] [c: 00007FF6000000E0] [owr: 0000000000003100] [mc: 0000000000002100]
[000000000000310F] InterfaceProperty /Script/Icarus.ActorState:Target [o: 2F8] [n: 4F] [c: 00007FF6000000E1] [owr: 0000000000003100] [ic: 0000000000003600]
[0000000000003110] MulticastInlineDelegateProperty /Script/Icarus.ActorState:OnChanged [o: 308] [n: 50] [c: 00007FF6000000E2] [owr: 0000000000003100] [df: 0000000000003190]
[0000000000003111] DelegateProperty /Script/Icarus.ActorState:Query [o: 318] [n: 51] [c: 00007FF6000000E3] [owr: 0000000000003100] [df: 0000000000003190]
[0000000000003120] Function /Script/Icarus.ActorState:SetHealth [n: 52] [c: 00000000000000C0] [or: 0000000000003100] [f: 00007FF600000110]
[0000000000003121] IntProperty /Script/Icarus.ActorState:SetHealth:Amount [o: 0] [n: 53] [c: 00007FF6000000D0] [owr: 0000000000003120]
[0000000000003130] Function /Script/Icarus.ActorState:GetHealth [n: 54] [c: 00000000000000C0] [or: 0000000000003100] [f: 00007FF600000111]
[0000000000003131] IntProperty /Script/Icarus.ActorState:GetHealth:ReturnValue [o: 0] [n: 1C] [c: 00007FF6000000D0] [owr: 0000000000003130]
[0000000000003140] Function /Script/Icarus.ActorState:IsAlive [n: 55] [c: 00000000000000C0] [or: 0000000000003100] [f: 00007FF600000112]
[0000000000003141] BoolProperty /Script/Icarus.ActorState:IsAlive:ReturnValue [o: 0] [n: 1C] [c: 00007FF6000000D2] [owr: 0000000000003140]
[0000000000003150] Function /Script/Icarus.ActorState:BigCall [n: 56] [c: 00000000000000C0] [or: 0000000000003100] [f: 00007FF600000113]
[0000000000003151] StructProperty /Script/Icarus.ActorState:BigCall:Packet [o: 0] [n: 57] [c: 00007FF6000000D7] [owr: 0000000000003150] [ss: 0000000000003800]
[0000000000003152] IntProperty /Script/Icarus.ActorState:BigCall:Tail [o: 200] [n: 58] [c: 00007FF6000000D0] [owr: 0000000000003150]
[0000000000003160] Function /Script/Icarus.ActorState:Wait [n: 59] [c: 00000000000000C0] [or: 0000000000003100] [f: 00007FF600000114]
[0000000000003161] StructProperty /Script/Icarus.ActorState:Wait:LatentInfo [o: 0] [n: 5A] [c: 00007FF6000000D7] [owr: 0000000000003160] [ss: 0000000000002E00]
[0000000000003190] DelegateFunction /Script/Icarus.ActorState:OnChanged__DelegateSignature [n: 5B] [c: 00000000000000C2] [or: 0000000000003100]
[0000000000003191] IntProperty /Script/Icarus.ActorState:OnChanged__DelegateSignature:NewHealth [o: 0] [n: 5C] [c: 00007FF6000000D0] [owr: 0000000000003190]
[0000000000003200] Class /Script/Icarus.CharacterState [n: 5D] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000003100]
[0000000000003201] IntProperty /Script/Icarus.CharacterState:Stamina [o: 320] [n: 5E] [c: 00007FF6000000D0] [owr: 0000000000003200]
[0000000000003300] Class /Script/Icarus.IcarusCharacter [n: 5F] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002400]
[0000000000003301] ObjectProperty /Script/Icarus.IcarusCharacter:ActorState [o: 5A8] [n: 41] [c: 00007FF6000000D5] [owr: 0000000000003300] [pc: 0000000000003200]
[0000000000003400] Class /Script/Icarus.IcarusPlayerController [n: 60] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002600]
[0000000000003401] ObjectProperty /Script/Icarus.IcarusPlayerController:IcarusCharacter [o: 5A0] [n: 5F] [c: 00007FF6000000D5] [owr: 0000000000003400] [pc: 0000000000003300]
[0000000000003500] Class /Script/Icarus.UMGFunctionLibrary [n: 61] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002300]
[0000000000003510] Function /Script/Icarus.UMGFunctionLibrary:CopyToClipboard [n: 62] [c: 00000000000000C0] [or: 0000000000003500] [f: 00007FF600000120]
[0000000000003511] StrProperty /Script/Icarus.UMGFunctionLibrary:CopyToClipboard:Text [o: 0] [n: 63] [c: 00007FF6000000D9] [owr: 0000000000003510]
[0000000000003600] Class /Script/Icarus.Usable [n: 64] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000001100]
[0000000000003700] Class /Script/Icarus.IcarusGameEngine [n: 65] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002D00]
[0000000000003710] IcarusGameEngine /Engine/Transient.IcarusGameEngine_2147482616 [n: 65] [c: 0000000000003700] [or: 0000000000005000]
[0000000000003800] ScriptStruct /Script/Icarus.DamagePacket [n: 66] [c: 00000000000000E0] [or: 0000000000003000] [sps: 0000000000000000]
[0000000000003801] IntProperty /Script/Icarus.DamagePacket:Amount [o: 0] [n: 53] [c: 00007FF6000000D0] [owr: 0000000000003800]
[0000000000003802] ObjectProperty /Script/Icarus.DamagePacket:Causer [o: 8] [n: 67] [c: 00007FF6000000D5] [owr: 0000000000003800] [pc: 0000000000002100]
[0000000000003810] ScriptStruct /Script/Icarus.BigDamagePacket [n: 68] [c: 00000000000000E0] [or: 0000000000003000] [sps: 0000000000003800]
[0000000000003811] FloatProperty /Script/Icarus.BigDamagePacket:Scale [o: 10] [n: 69] [c: 00007FF6000000D1] [owr: 0000000000003810]
[0000000000003A10] Class /Script/Icarus.IcarusSpectatorPawn [n: 92] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002400]
[0000000000003A20] Class /Script/Icarus.IcarusTitlePlayerController [n: 93] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002600]
[0000000000003A30] Class /Script/Icarus.IcarusGameStateBase [n: 94] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000002A00]
[0000000000003900] Enum /Script/Icarus.EAliveState [n: 6A] [c: 00000000000000F0] [or: 0000000000003000]
[0000000000000000] EAliveState::Alive [n: 6B] [v: 0]
[0000000000000000] EAliveState::Dead [n: 6C] [v: 1]
[0000000000000000] EAliveState::EAliveState_MAX [n: 6D] [v: 2]
[0000000000004000] Package /Game/Mods/BP_Thing [n: 70] [c: 00000000000000A0] [or: 0000000000000000]
[0000000000004100] BlueprintGeneratedClass /Game/Mods/BP_Thing.BP_Thing_C [n: 71] [c: 00000000000000B1] [or: 0000000000004000] [sps: 0000000000003300]
[0000000000004101] StructProperty /Game/Mods/BP_Thing.BP_Thing_C:UberGraphFrame [o: 600] [n: 72] [c: 00007FF6000000D7] [owr: 0000000000004100] [ss: 0000000000002F00]
[0000000000004102] BoolProperty /Game/Mods/BP_Thing.BP_Thing_C:Use Sun [o: 608] [n: 73] [c: 00007FF6000000D2] [owr: 0000000000004100]
[0000000000004103] ByteProperty /Game/Mods/BP_Thing.BP_Thing_C:Mode [o: 609] [n: 74] [c: 00007FF6000000D3] [owr: 0000000000004100]
[0000000000004104] SetProperty /Game/Mods/BP_Thing.BP_Thing_C:Seen [o: 610] [n: 4B] [c: 00007FF6000000DD] [owr: 0000000000004100]
[0000000000004105] StrProperty /Game/Mods/BP_Thing.BP_Thing_C:Name [o: 660] [n: 75] [c: 00007FF6000000D9] [owr: 0000000000004100]
[0000000000004110] Function /Game/Mods/BP_Thing.BP_Thing_C:ExecuteUbergraph_BP_Thing [n: 76] [c: 00000000000000C0] [or: 0000000000004100] [f: 00007FF600000001]
[0000000000004111] IntProperty /Game/Mods/BP_Thing.BP_Thing_C:ExecuteUbergraph_BP_Thing:EntryPoint [o: 0] [n: 4] [c: 00007FF6000000D0] [owr: 0000000000004110]
[0000000000004112] BoolProperty /Game/Mods/BP_Thing.BP_Thing_C:ExecuteUbergraph_BP_Thing:K2Node_Event_bValue [o: 4] [n: 77] [c: 00007FF6000000D2] [owr: 0000000000004110]
[0000000000004120] Function /Game/Mods/BP_Thing.BP_Thing_C:Get Fog Scale [n: 78] [c: 00000000000000C0] [or: 0000000000004100] [f: 00007FF600000001]
[0000000000004121] StructProperty /Game/Mods/BP_Thing.BP_Thing_C:Get Fog Scale:Scale Out [o: 0] [n: 79] [c: 00007FF6000000D7] [owr: 0000000000004120] [ss: 0000000000001300]
[0000000000004122] FloatProperty /Game/Mods/BP_Thing.BP_Thing_C:Get Fog Scale:Working [o: C] [n: 7A] [c: 00007FF6000000D1] [owr: 0000000000004120]
[0000000000004123] IntProperty /Game/Mods/BP_Thing.BP_Thing_C:Get Fog Scale:Temp_int_Variable [o: 10] [n: 7B] [c: 00007FF6000000D0] [owr: 0000000000004120]
[0000000000004130] Function /Game/Mods/BP_Thing.BP_Thing_C:UseItem [n: 7C] [c: 00000000000000C0] [or: 0000000000004100] [f: 00007FF600000001]
[0000000000004131] ObjectProperty /Game/Mods/BP_Thing.BP_Thing_C:UseItem:Target [o: 0] [n: 4F] [c: 00007FF6000000D5] [owr: 0000000000004130] [pc: 0000000000002100]
[0000000000004132] BoolProperty /Game/Mods/BP_Thing.BP_Thing_C:UseItem:ReturnValue [o: 8] [n: 1C] [c: 00007FF6000000D2] [owr: 0000000000004130]
[0000000000004133] IntProperty /Game/Mods/BP_Thing.BP_Thing_C:UseItem:Count [o: C] [n: 7D] [c: 00007FF6000000D0] [owr: 0000000000004130]
[0000000000004140] Function /Game/Mods/BP_Thing.BP_Thing_C:ReceiveBeginPlay [n: 1A] [c: 00000000000000C0] [or: 0000000000004100] [f: 00007FF600000001]
[0000000000004150] Function /Game/Mods/BP_Thing.BP_Thing_C:GetActorBounds [n: 16] [c: 00000000000000C0] [or: 0000000000004100] [f: 00007FF600000001]
[0000000000004151] BoolProperty /Game/Mods/BP_Thing.BP_Thing_C:GetActorBounds:bOnlyCollidingComponents [o: 0] [n: 17] [c: 00007FF6000000D2] [owr: 0000000000004150]
[0000000000004152] StructProperty /Game/Mods/BP_Thing.BP_Thing_C:GetActorBounds:Origin [o: 4] [n: 18] [c: 00007FF6000000D7] [owr: 0000000000004150] [ss: 0000000000001300]
[0000000000004153] StructProperty /Game/Mods/BP_Thing.BP_Thing_C:GetActorBounds:BoxExtent [o: 10] [n: 19] [c: 00007FF6000000D7] [owr: 0000000000004150] [ss: 0000000000001300]
[0000000000004154] FloatProperty /Game/Mods/BP_Thing.BP_Thing_C:GetActorBounds:Extra [o: 1C] [n: 7E] [c: 00007FF6000000D1] [owr: 0000000000004150]
[0000000000004160] BP_Thing_C /Game/Maps/Title.Title:PersistentLevel.BP_Thing_C_2147482500 [n: 7F] [c: 0000000000004100] [or: 0000000000005100]
[0000000000004170] BP_Thing_C /Game/Mods/BP_Thing.Default__BP_Thing_C [n: 80] [c: 0000000000004100] [or: 0000000000004000]
[0000000000004200] UserDefinedStruct /Game/Mods/S_Row.S_Row [n: 81] [c: 00000000000000E1] [or: 0000000000004001]
[0000000000004201] IntProperty /Game/Mods/S_Row.S_Row:Count_2_0123456789ABCDEF0123456789ABCDEF [o: 0] [n: 82] [c: 00007FF6000000D0] [owr: 0000000000004200]
[0000000000004300] UserDefinedEnum /Game/Mods/E_Mode.E_Mode [n: 83] [c: 00000000000000F1] [or: 0000000000004002]
[0000000000000000] E_Mode::NewEnumerator0 [n: 84] [v: 0]
[0000000000000000] E_Mode::NewEnumerator1 [n: 85] [v: 1]
[0000000000000000] E_Mode::E_MAX [n: 86] [v: 2]
[0000000000004400] ControlRigBlueprintGeneratedClass /Game/Mods/Rig.Rig_C [n: 87] [c: 00000000000000B2] [or: 0000000000004003]
[0000000000004401] FloatProperty /Game/Mods/Rig.Rig_C:Blend [o: 0] [n: 88] [c: 00007FF6000000D1] [owr: 0000000000004400]
[0000000000004500] WidgetBlueprintGeneratedClass /Game/Mods/UI/1ST-Widget.1ST-Widget_C [n: 89] [c: 00000000000000B3] [or: 0000000000004004] [sps: 0000000000001100]
[0000000000004501] ObjectProperty /Game/Mods/UI/1ST-Widget.1ST-Widget_C:Owner [o: 30] [n: 8A] [c: 00007FF6000000D5] [owr: 0000000000004500] [pc: 0000000000004100]
[0000000000004600] Texture2D /Game/Mods/T_Icon.T_Icon [n: 8B] [c: 00000000000000B4] [or: 0000000000004005]
a line that is not an object
""".lstrip("\n")

# What UE4SS writes beside the dump for the blueprint above.
UE4SS_TYPES = """---@meta

---@class ABP_Thing_C : AIcarusCharacter
---@field UberGraphFrame FPointerToUberGraphFrame
---@field Mode E_Mode::Type
---@field Seen TSet<AActor>
local ABP_Thing_C = {}

---@param EntryPoint int32
function ABP_Thing_C:ExecuteUbergraph_BP_Thing(EntryPoint) end
---@param Scale_Out FVector
ABP_Thing_C['Get Fog Scale'] = function(self, Scale_Out) end
---@param Target AActor
---@return boolean
function ABP_Thing_C:UseItem(Target) end
function ABP_Thing_C:ReceiveBeginPlay() end
---@param bOnlyCollidingComponents boolean
---@param Origin FVector
---@param BoxExtent FVector
function ABP_Thing_C:GetActorBounds(bOnlyCollidingComponents, Origin, BoxExtent) end
"""

WAX_GAME = """---@meta _

---An engine object.
---@class WaxInstance
---@field Name string The object's name.
---@field Parent WaxInstance? What GetParent() returns.
---@field [string] any
local Instance = {}

---@return WaxInstance?
function Instance:GetParent() end

---@return WaxInstance[]
function Instance:GetChildren() end

---@class WaxGame
---@field Character WaxInstance?
game = {}
"""


# A list shaped like wax\runtime\data\needs.lua, over the dump above.
NEEDS = """-- what two made-up parts use
return {
    {
        id = "state", name = "Actor state", without = "Nothing shows health.",
        classes = {
            { class = "/Script/Icarus.CharacterState", properties = { "Health", "Stamina" }, functions = { "IsAlive" } },
            { class = "/Game/Mods/BP_Thing.BP_Thing_C", properties = { "Use Sun" }, functions = { "Get Fog Scale" } },
        },
        structs = { { struct = "/Script/Icarus.BigDamagePacket", fields = { "Amount", "Scale" } } },
        enums = { { enum = "/Script/Icarus.EAliveState", values = { Alive = 0, Dead = 1 } } },
        tables = {
            { table = "D_Damage", fields = { "Amount", "Scale", "Causer" }, meta = { "Level.RowName" } },
            { table = "D_Loose", fields = { "Hits.At.X", "Hits.Never.Filled" } },
        },
    },
    { id = "screens", name = 'Screens', classes = { { class = "/Game/UI/UMG_Late.UMG_Late_C", late = true, properties = { "List" } } } },
}
"""
NEEDS_CHANGES = (
    ('"/Script/Icarus.CharacterState", properties = { "Health", "Stamina" }, functions = { "IsAlive" }',
     '"/Script/Icarus.CharacterState", properties = { "Healt", "IsAlive" }, functions = { "GetHealthy" }'),
    ("/Game/Mods/BP_Thing.BP_Thing_C", "/Game/Other/BP_Thing.BP_Thing_C"),
    ('fields = { "Amount", "Scale" }', 'fields = { "Amount", "Scales" }'),
    ("values = { Alive = 0, Dead = 1 }", "values = { Alive = 1, Deceased = 1, Gone = 9 }"),
    ('fields = { "Amount", "Scale", "Causer" }, meta = { "Level.RowName" }',
     'fields = { "Amounts", "Amount.More", "Causer" }, meta = { "Level.RowName" }'),
    ('{ table = "D_Loose",', '{ table = "D_Lose", fields = { "A" } }, { table = "D_Loose",'),
    ('functions = { "Get Fog Scale" } },', 'functions = { "Get Fog Scale" } }, { class = "/Script/Icarus.ActorStates" },'),
)
TABLES = {
    "Traits/D_Damage.json": {"RowStruct": "/Script/Icarus.BigDamagePacket", "Defaults": {"Amount": 0, "Scale": 1, "Causer": None},
                             "Rows": [{"Name": "Small", "Amount": 2, "Metadata": {"Level": {"RowName": "One"}}}, {"Name": "Big"}]},
    "D_Loose.json": {"RowStruct": "/Script/Icarus.NotInTheDump", "Defaults": {"Hits": []},
                     "Rows": [{"Name": "One", "Hits": [{"At": {"X": 1}}]}]},
    "DataTableMetadata.json": {"LoadingPhases": {}},
}


class Scratch(unittest.TestCase):
    """A folder under build that is removed when the tests of the class are done."""

    @classmethod
    def setUpClass(cls):
        os.makedirs(BUILD, exist_ok=True)
        cls.dir = tempfile.mkdtemp(prefix=".gameindex-test-", dir=BUILD)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    @classmethod
    def put(cls, name, text):
        path = os.path.join(cls.dir, *name.split("/"))
        gameindex.write_text(path, text)
        return path


def by_name(items):
    return {item["name"]: item for item in items}


class HandWrittenDump(Scratch):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.dump = cls.put("plain/ObjectDump.txt", DUMP)
        cls.index = gameindex.build_index(cls.dump)
        cls.put("with-types/ObjectDump.txt", DUMP)
        cls.put("with-types/types/BP_Thing.lua", UE4SS_TYPES)
        cls.typed = gameindex.build_index(os.path.join(cls.dir, "with-types", "ObjectDump.txt"))
        cls.wax = os.path.join(cls.dir, "wax-types")
        cls.put("wax-types/game.lua", WAX_GAME)
        cls.classes = by_name(cls.index["classes"])
        cls.structs = by_name(cls.index["structs"])
        cls.enums = by_name(cls.index["enums"])

    def functions(self, owner, index=None):
        return by_name((by_name((index or self.index)["classes"])[owner])["functions"])

    def properties(self, owner, index=None):
        return by_name((by_name((index or self.index)["classes"])[owner])["properties"])

    def test_counts_and_nothing_left_over(self):
        counts, source = self.index["counts"], self.index["source"]
        self.assertEqual((counts["classes"], counts["native_classes"], counts["blueprint_classes"]), (29, 26, 3))
        self.assertEqual((counts["structs"], counts["enums"], counts["enum_values"]), (6, 4, 12))
        self.assertEqual(source["properties_without_owner"], 0)
        self.assertEqual(source["unresolved_references"], 0)
        self.assertFalse(source["ue4ss_types"])
        self.assertTrue(self.typed["source"]["ue4ss_types"])

    def test_classes_know_their_parent_and_origin(self):
        state = self.classes["ActorState"]
        self.assertEqual(state["path"], "/Script/Icarus.ActorState")
        self.assertEqual(state["parent"], "/Script/Engine.ActorComponent")
        self.assertEqual((state["package"], state["native"], state["kind"]), ("/Script/Icarus", True, "Class"))
        self.assertNotIn("parent", self.classes["Object"])
        thing = self.classes["BP_Thing_C"]
        self.assertEqual((thing["package"], thing["native"], thing["kind"]), ("/Game/Mods/BP_Thing", False, "BlueprintGeneratedClass"))
        self.assertEqual(thing["parent"], "/Script/Icarus.IcarusCharacter")
        self.assertEqual(thing["instances"], 1)
        self.assertEqual(self.classes["IcarusGameEngine"]["instances"], 1)
        self.assertEqual(self.classes["1ST-Widget_C"]["kind"], "WidgetBlueprintGeneratedClass")

    def test_a_class_kind_without_a_parent_tag_is_still_a_class(self):
        rig = self.classes["Rig_C"]
        self.assertEqual(rig["kind"], "ControlRigBlueprintGeneratedClass")
        self.assertEqual([p["name"] for p in rig["properties"]], ["Blend"])

    def test_default_objects_and_other_objects_are_not_classes(self):
        for name in ("Default__Object", "Default__Enum", "Default__BP_Thing_C", "T_Icon", "IcarusGameEngine_2147482616"):
            self.assertNotIn(name, self.classes)
            self.assertNotIn(name, self.enums)

    def test_property_types_and_what_they_refer_to(self):
        properties = self.properties("ActorState")
        self.assertEqual(list(properties)[:3], ["Health", "MaxHealth", "CurrentAliveState"])
        self.assertEqual(properties["Health"], {"name": "Health", "type": "Int", "offset": 0x1D8})
        self.assertEqual(properties["CurrentAliveState"]["ref"], "/Script/Icarus.EAliveState")
        self.assertEqual([properties[n]["type"] for n in ("Label", "Tag", "Title", "Shelter")], ["Str", "Name", "Text", "Float"])
        self.assertEqual(properties["Costs"]["key"], {"type": "Name"})
        self.assertEqual(properties["Costs"]["value"], {"type": "Struct", "ref": "/Script/Icarus.DamagePacket"})
        self.assertEqual(properties["Seen"]["type"], "Set")
        self.assertNotIn("inner", properties["Seen"])
        self.assertEqual((properties["Icon"]["type"], properties["Icon"]["ref"]), ("SoftObject", "/Script/CoreUObject.Object"))
        self.assertEqual((properties["Last"]["type"], properties["Last"]["ref"]), ("WeakObject", "/Script/Engine.Actor"))
        self.assertEqual((properties["Kind"]["type"], properties["Kind"]["ref"]), ("Class", "/Script/Engine.Actor"))
        self.assertEqual((properties["Target"]["type"], properties["Target"]["ref"]), ("Interface", "/Script/Icarus.Usable"))
        self.assertEqual(properties["OnChanged"]["ref"], "/Script/Icarus.ActorState:OnChanged__DelegateSignature")
        self.assertEqual(properties["Query"]["type"], "Delegate")
        actor = self.properties("Actor")
        self.assertEqual(actor["bHidden"]["mask"], 0x20)
        self.assertEqual(actor["Children"]["inner"], {"type": "Object", "ref": "/Script/Engine.Actor"})
        self.assertEqual(actor["OnDestroyed"]["ref"], "/Script/Engine.ActorDestroyedSignature__DelegateSignature")
        self.assertEqual(self.properties("IcarusCharacter")["ActorState"]["ref"], "/Script/Icarus.CharacterState")

    def test_names_with_spaces(self):
        self.assertIn("Use Sun", self.properties("BP_Thing_C"))
        self.assertIn("Get Fog Scale", self.functions("BP_Thing_C"))
        self.assertEqual(self.functions("BP_Thing_C", self.typed)["Get Fog Scale"]["params"][0]["name"], "Scale Out")

    def test_structs_and_their_parents(self):
        self.assertEqual([f["name"] for f in self.structs["Vector"]["fields"]], ["X", "Y", "Z"])
        self.assertEqual(self.structs["BigDamagePacket"]["parent"], "/Script/Icarus.DamagePacket")
        self.assertEqual(self.structs["DamagePacket"]["fields"][1]["ref"], "/Script/Engine.Actor")
        row = self.structs["S_Row"]
        self.assertFalse(row["native"])
        self.assertEqual(row["fields"][0]["name"], "Count_2_0123456789ABCDEF0123456789ABCDEF")

    def test_enum_values(self):
        self.assertEqual(self.enums["EAliveState"]["values"], [["Alive", 0], ["Dead", 1], ["EAliveState_MAX", 2]])
        self.assertEqual(self.enums["ENetRole"]["values"], [["ROLE_None", 0], ["ROLE_Authority", 3], ["ROLE_MAX", 4]])
        self.assertEqual(self.enums["E_Mode"]["values"][0], ["NewEnumerator0", 0])
        self.assertFalse(self.enums["E_Mode"]["native"])

    def test_function_parameters_in_order_and_return_value(self):
        functions = self.functions("ActorState")
        self.assertEqual(functions["SetHealth"], {"name": "SetHealth", "params": [{"name": "Amount", "type": "Int"}], "flags": ["native"]})
        self.assertEqual(functions["GetHealth"]["returns"], {"type": "Int"})
        self.assertEqual(functions["GetHealth"]["params"], [])
        self.assertEqual(functions["IsAlive"]["returns"], {"type": "Bool"})
        bounds = self.functions("Actor")["GetActorBounds"]
        self.assertEqual([p["name"] for p in bounds["params"]], ["bOnlyCollidingComponents", "Origin", "BoxExtent"])
        self.assertEqual(bounds["params"][1], {"name": "Origin", "type": "Struct", "ref": "/Script/CoreUObject.Vector"})
        self.assertNotIn("returns", bounds)
        self.assertEqual(self.functions("Actor")["GetOwner"]["returns"], {"type": "Object", "ref": "/Script/Engine.Actor"})

    def test_function_flags(self):
        self.assertEqual(self.functions("UMGFunctionLibrary")["CopyToClipboard"]["flags"], ["native", "static"])
        self.assertEqual(self.functions("Actor")["ReceiveBeginPlay"]["flags"], ["event"])
        self.assertEqual(self.functions("ActorState")["OnChanged__DelegateSignature"]["flags"], ["delegate"])
        self.assertEqual(self.functions("ActorState")["Wait"]["flags"], ["native", "latent"])
        big = self.functions("ActorState")["BigCall"]
        self.assertIn("oversized", big["flags"])
        self.assertEqual(big["frame"], 0x204)
        graph = self.functions("BP_Thing_C")["ExecuteUbergraph_BP_Thing"]
        self.assertEqual(graph["flags"], ["blueprint", "internal"])
        self.assertEqual(([p["name"] for p in graph["params"]], graph["locals"]), (["EntryPoint"], 1))

    def test_delegate_signatures_outside_a_class(self):
        signature = by_name(self.index["delegates"])["ActorDestroyedSignature__DelegateSignature"]
        self.assertEqual(signature["path"], "/Script/Engine.ActorDestroyedSignature__DelegateSignature")
        self.assertEqual(signature["params"], [{"name": "DestroyedActor", "type": "Object", "ref": "/Script/Engine.Actor"}])
        self.assertEqual(signature["flags"], ["delegate"])

    def test_blueprint_parameters_without_the_types_folder(self):
        functions = self.functions("BP_Thing_C")
        use = functions["UseItem"]
        self.assertEqual(([p["name"] for p in use["params"]], use["returns"], use["locals"]), (["Target"], {"type": "Bool"}, 1))
        bounds = functions["GetActorBounds"]
        self.assertEqual(([p["name"] for p in bounds["params"]], bounds["locals"]), (["bOnlyCollidingComponents", "Origin", "BoxExtent"], 1))
        fog = functions["Get Fog Scale"]
        self.assertEqual([p["name"] for p in fog["params"]], ["Scale Out", "Working"])
        self.assertIn("unsure", fog["flags"])
        self.assertEqual(self.index["source"]["parameter_sources"], {"dump": 14, "entry": 1, "guess": 1, "inherited": 1, "return": 1})

    def test_the_types_folder_settles_parameters_byte_enums_and_sets(self):
        fog = self.functions("BP_Thing_C", self.typed)["Get Fog Scale"]
        self.assertEqual(([p["name"] for p in fog["params"]], fog["locals"]), (["Scale Out"], 2))
        self.assertNotIn("unsure", fog["flags"])
        use = self.functions("BP_Thing_C", self.typed)["UseItem"]
        self.assertEqual(([p["name"] for p in use["params"]], use["returns"]), (["Target"], {"type": "Bool"}))
        properties = self.properties("BP_Thing_C", self.typed)
        self.assertEqual(properties["Mode"]["enum"], "/Game/Mods/E_Mode.E_Mode")
        self.assertEqual(properties["Seen"]["inner"], {"type": "Object", "ref": "/Script/Engine.Actor"})
        self.assertNotIn("enum", self.properties("BP_Thing_C")["Mode"])

    def test_index_file_round_trip(self):
        path = os.path.join(self.dir, "out", "index.json")
        gameindex.write_index(self.index, path)
        self.assertEqual(gameindex.load_index(path), json.loads(json.dumps(self.index)))
        with open(path, encoding="utf-8") as file:
            self.assertGreater(len(file.read().splitlines()), len(self.index["classes"]))

    def types(self, **options):
        return gameindex.make_types(self.typed, self.wax, **options)

    def test_types_files(self):
        files, summary = self.types()
        self.assertEqual(summary["root"], "WaxInstance")
        for name, text in files.items():
            self.assertTrue(text.startswith("---@meta") or name == "classes.txt", name)
            self.assertLessEqual(len(text.encode("utf-8")), gameindex.TYPES_FILE_LIMIT, name)
        self.assertEqual(sorted(files), ["base.lua", "classes.txt", "content/Game.lua", "script/CoreUObject.lua",
                                         "script/Engine.lua", "script/Icarus.lua"])
        icarus = files["script/Icarus.lua"]
        self.assertIn("---@class ActorState : ActorComponent\n", icarus)
        self.assertIn("---@class CharacterState : ActorState\n---@field Stamina integer\n", icarus)
        for line in ("---@field Health integer", "---@field CurrentAliveState EAliveState", "---@field Label string",
                     "---@field Tag string", "---@field Title string", "---@field Shelter number",
                     "---@field Costs table<string, DamagePacket>", "---@field Seen any[]", "---@field Icon Object",
                     "---@field Last Actor", "---@field Kind Class", "---@field Target Usable", "---@field OnChanged GameDelegate",
                     "---@field SetHealth fun(self: ActorState, Amount: integer)", "---@field GetHealth fun(self: ActorState): integer",
                     "---@field IsAlive fun(self: ActorState): boolean",
                     "---@field BigCall fun(self: ActorState, Packet: DamagePacket|{}, Tail: integer) Do not call from Lua: "
                     "it needs 516 bytes and the call buffer holds 512.",
                     "---@class DamagePacket\n---@field Amount integer\n---@field Causer Actor", "---@alias EAliveState\n---| 0 # Alive\n---| 1 # Dead\n---| integer",
                     "---@field CopyToClipboard fun(self: UMGFunctionLibrary, Text: string)",
                     "---@field ActorState CharacterState"):
            self.assertIn(line + "\n", icarus)
        self.assertNotIn("OnChanged__DelegateSignature", icarus)
        self.assertNotIn("BigDamagePacket", icarus)
        engine = files["script/Engine.lua"]
        self.assertIn("---@field Children Actor[]\n", engine)
        self.assertIn("---@field bHidden boolean\n", engine)
        self.assertIn("---@field RemoteRole integer\n", engine)
        self.assertIn("---@field GetOwner fun(self: Actor): Actor\n", engine)
        self.assertIn("---@field GetActorBounds fun(self: Actor, bOnlyCollidingComponents: boolean, Origin: Vector|{}, BoxExtent: Vector|{})\n", engine)
        self.assertIn("---@class Object : WaxInstance\n", files["script/CoreUObject.lua"])
        self.assertIn("---@class Vector\n---@field X number\n", files["script/CoreUObject.lua"])

    def test_types_for_blueprints_and_odd_names(self):
        files, _ = self.types()
        mods = files["content/Game.lua"]
        self.assertIn("---@class BP_Thing_C : IcarusCharacter\n", mods)
        self.assertIn('---@field ["Use Sun"] boolean\n', mods)
        self.assertIn('---@field ["Get Fog Scale"] fun(self: BP_Thing_C, Scale_Out: Vector|{})\n', mods)
        self.assertIn("---@field UseItem fun(self: BP_Thing_C, Target: Actor?): boolean\n", mods)
        self.assertIn("---@field Mode E_Mode\n", mods)
        self.assertIn("---@field Seen Actor[]\n", mods)
        self.assertIn("---@class _1ST_Widget_C : Object\n---@field Owner BP_Thing_C\n", mods)
        self.assertIn("---@alias E_Mode\n---| 0 # NewEnumerator0\n---| 1 # NewEnumerator1\n---| integer\n", mods)
        self.assertNotIn("UberGraphFrame", mods)
        self.assertNotIn("ExecuteUbergraph", mods)
        self.assertNotIn("S_Row", mods)

    def test_members_wax_already_names_are_left_to_wax(self):
        files, _ = self.types()
        self.assertNotIn("---@field Name string", files["content/Game.lua"])
        self.assertNotIn("GetParent", files["script/Engine.lua"])
        base = files["base.lua"]
        self.assertNotIn("WaxInstance", base)
        self.assertNotIn("WaxGame", base)
        self.assertIn("---@class GameDelegate\n", base)

    def test_function_libraries_are_listed_with_the_object_their_functions_are_called_on(self):
        libraries = self.types()[1]["libraries"]
        self.assertEqual(libraries, {"UMGFunctionLibrary": "/Script/Icarus.Default__UMGFunctionLibrary"})
        self.assertEqual(gameindex.default_object("/Game/Mods/BP_Lib.BP_Lib_C"), "/Game/Mods/BP_Lib.Default__BP_Lib_C")
        text = gameindex.libraries_text({"UMGFunctionLibrary": "/Script/Icarus.Default__UMGFunctionLibrary", "end": "/Script/X.Default__end"})
        self.assertIn('    UMGFunctionLibrary = "/Script/Icarus.Default__UMGFunctionLibrary",\n', text)
        self.assertIn('    ["end"] = "/Script/X.Default__end",\n', text)
        self.assertTrue(text.startswith(gameindex.GENERATED + "\nreturn {\n") and text.endswith("}\n"))

    def test_the_class_list_names_classes_only(self):
        names = self.types()[0]["classes.txt"].split()
        self.assertEqual(names, sorted(names))
        for name in ("Object", "Actor", "ActorState", "BP_Thing_C", "_1ST_Widget_C"):
            self.assertIn(name, names)
        for name in ("Vector", "DamagePacket", "EAliveState", "E_Mode"):
            self.assertNotIn(name, names)

    def test_everything_adds_what_a_compiler_made(self):
        files, summary = self.types(everything=True)
        mods = files["content/Game.lua"]
        self.assertIn("---@field UberGraphFrame PointerToUberGraphFrame\n", mods)
        self.assertIn("---@field ExecuteUbergraph_BP_Thing fun(self: BP_Thing_C, EntryPoint: integer)\n", mods)
        self.assertIn("---@class S_Row\n---@field Count_2_0123456789ABCDEF0123456789ABCDEF integer\n", mods)
        self.assertIn("---@class BigDamagePacket : DamagePacket\n---@field Scale number\n", files["script/Icarus.lua"])
        self.assertIn("---@field OnChanged__DelegateSignature fun(self: ActorState, NewHealth: integer)\n", files["script/Icarus.lua"])
        self.assertEqual((self.types()[1]["structs"], summary["structs"]), (3, 6))

    def test_entry_points(self):
        summary = self.types()[1]
        found = {member: (text, note) for member, text, note in summary["entry_points"]}
        self.assertEqual(found["Engine"], ("IcarusGameEngine", "Wax finds it as an Engine. The dump holds one, an IcarusGameEngine."))
        self.assertEqual(found["Viewport"], ("GameViewportClient", "Engine.GameViewport is declared as GameViewportClient."))
        self.assertEqual(found["World"][0], "World")
        self.assertEqual(found["GameState"], ("IcarusGameStateBase", "World.GameState is declared as GameStateBase. "
                                              "The game's own classes for it derive from IcarusGameStateBase."))
        self.assertEqual(found["GameMode"], ("GameModeBase?", "World.AuthorityGameMode is declared as GameModeBase."))
        self.assertEqual(found["LocalPlayer"], ("IcarusPlayerController", "LocalPlayer.PlayerController is declared as "
                                                "PlayerController. IcarusPlayerController is the game's controller that has a character."))
        self.assertEqual(found["Character"], ("IcarusCharacter?", "PlayerController.Pawn is declared as Pawn. "
                                              "IcarusPlayerController declares its character as IcarusCharacter."))

    def test_what_wax_declares_for_game_is_compared_with_the_dump(self):
        differ = {member: (declared, found) for member, declared, found, _ in self.types()[1]["entry_points_differ"]}
        self.assertEqual(differ["Character"], ("WaxInstance?", "IcarusCharacter?"))
        self.assertEqual(differ["World"], (None, "World"))
        self.put("agreeing-wax/game.lua", WAX_GAME.replace("---@field Character WaxInstance?", "---@field Character IcarusCharacter?"))
        differ = [row[0] for row in gameindex.make_types(self.typed, os.path.join(self.dir, "agreeing-wax"))[1]["entry_points_differ"]]
        self.assertNotIn("Character", differ)

    def test_large_output_is_split_by_folder_then_letter(self):
        files, _ = gameindex.make_types(self.typed, self.wax, limit=500)
        names = sorted(files)
        for name in ("script/Icarus-A.lua", "script/Icarus-I.lua", "script/Engine-G.lua", "content/Game.Mods.UI.lua",
                     "content/Game.Mods-B.lua", "content/Game.Mods-R.lua"):
            self.assertIn(name, names)
        self.assertNotIn("script/Icarus.lua", names)
        self.assertIn("---@class IcarusCharacter : Pawn\n", files["script/Icarus-I.lua"])
        self.assertIn("---@class IcarusPlayerController : PlayerController\n", files["script/Icarus-I.lua"])
        self.assertIn("---@class _1ST_Widget_C : Object\n", files["content/Game.Mods.UI.lua"])
        self.assertTrue(all(text.startswith("---@meta") for name, text in files.items() if name.endswith(".lua")))
        whole = "".join(self.types()[0].values())
        for text in files.values():
            for block in text.split("\n\n")[1:]:
                self.assertIn(block.strip("\n"), whole)
        again, _ = gameindex.make_types(self.typed, self.wax, limit=500)
        self.assertEqual(files, again)

    def test_two_types_of_one_name_get_different_names(self):
        index = json.loads(json.dumps(self.index))
        twin = dict(by_name(index["structs"])["DamagePacket"], path="/Game/Mods/Other/DamagePacket.DamagePacket",
                    package="/Game/Mods/Other/DamagePacket", native=False)
        index["structs"].append(twin)
        names = gameindex.Names(gameindex.Game(index))
        self.assertEqual(names.of["/Script/Icarus.DamagePacket"], "DamagePacket")
        self.assertEqual(names.of["/Game/Mods/Other/DamagePacket.DamagePacket"], "DamagePacket__Other")
        self.assertEqual(names.of["/Game/Mods/UI/1ST-Widget.1ST-Widget_C"], "_1ST_Widget_C")

    def test_writing_removes_files_from_an_earlier_run(self):
        out = os.path.join(self.dir, "gametypes")
        files, _ = gameindex.make_types(self.typed, self.wax, limit=500)
        gameindex.write_tree(out, files, gameindex.GENERATED)
        kept = self.put("gametypes/notes.txt", "mine")
        files, _ = self.types()
        gameindex.write_tree(out, files, gameindex.GENERATED)
        found = sorted(os.path.relpath(os.path.join(folder, name), out).replace(os.sep, "/")
                       for folder, _dirs, names in os.walk(out) for name in names)
        self.assertEqual(found, sorted(list(files) + ["notes.txt"]))
        self.assertTrue(os.path.isfile(kept))

    def test_site_data(self):
        files, manifest = gameindex.make_site(self.typed, self.wax)
        self.assertEqual(manifest["counts"]["chunks"], len(manifest["chunks"]))
        search = json.loads(files["search.json"])
        members = json.loads(files["members.json"])["members"]
        chunks = {c["id"]: json.loads(files[c["file"]]) for c in manifest["chunks"]}
        for chunk in manifest["chunks"]:
            self.assertLessEqual(chunk["bytes"], gameindex.SITE_CHUNK_LIMIT)
            self.assertEqual(chunk["bytes"], len(files[chunk["file"]].encode("utf-8")))
        self.assertEqual(search["chunks"], [c["id"] for c in manifest["chunks"]])
        listed = {name: (search["chunks"][chunk], kind) for name, chunk, kind in search["types"]}
        self.assertEqual(listed["ActorState"], ("script.Icarus", "c"))
        self.assertEqual(listed["Vector"], ("script.CoreUObject", "s"))
        self.assertEqual(listed["EAliveState"], ("script.Icarus", "e"))
        self.assertEqual([search["types"][i][0] for i in members["Health"]], ["ActorState"])
        self.assertEqual(sorted(search["types"][i][0] for i in members["GetActorBounds"]), ["Actor", "BP_Thing_C"])
        types = by_name(chunks["script.Icarus"]["types"])
        state = types["ActorState"]
        self.assertEqual((state["kind"], state["parent"], state["from"], state["origin"]),
                         ("class", "ActorComponent", "/Script/Icarus.ActorState", "native"))
        self.assertIn(["Health", "integer", "print(obj.Health)"], state["props"])
        self.assertIn(["OnChanged", "delegate(NewHealth: integer)", "print(obj.OnChanged)"], state["props"])
        self.assertIn(["SetHealth", [["Amount", "integer"]], "", "obj:SetHealth(1)"], state["funcs"])
        self.assertIn(["GetHealth", [], "integer", "local result = obj:GetHealth()"], state["funcs"])
        self.assertIn(["BigCall", [["Packet", "DamagePacket"], ["Tail", "integer"]], "", "obj:BigCall({}, 1)", ["oversized"]], state["funcs"])
        self.assertEqual(types["EAliveState"]["values"][1], ["Dead", 1])
        self.assertIn(["CopyToClipboard", [["Text", "string"]], "", 'obj:CopyToClipboard("text")', ["static"]],
                      types["UMGFunctionLibrary"]["funcs"])
        thing = by_name(chunks["content.Game"]["types"])["BP_Thing_C"]
        self.assertEqual(thing["origin"], "blueprint")
        self.assertIn(["Use Sun", "boolean", 'print(obj:Get("Use Sun"))'], thing["props"])
        self.assertIn(["Name", "string", 'print(obj:Get("Name"))'], thing["props"])
        self.assertIn(["Get Fog Scale", [["Scale_Out", "Vector"]], "", 'obj:Call("Get Fog Scale", { X = 0, Y = 0, Z = 0 })'], thing["funcs"])
        self.assertIn(["UseItem", [["Target", "Actor"]], "boolean", "local result = obj:UseItem(target)"], thing["funcs"])
        actor = by_name(chunks["script.Engine"]["types"])["Actor"]
        self.assertIn(["GetParent", [], "Actor", 'local result = obj:Call("GetParent")'], actor["funcs"])
        self.assertIn(["X", "number", "print(value.X)"], by_name(chunks["script.CoreUObject"]["types"])["Vector"]["props"])
        # whole lists every type of the index, without what a compiler made; the default is the editor's narrower choice.
        self.assertEqual(manifest["scope"], "what a mod meets")
        self.assertNotIn("EAxis", listed)
        whole, whole_manifest = gameindex.make_site(self.typed, self.wax, whole=True)
        every = {name for name, _chunk, _kind in json.loads(whole["search.json"])["types"]}
        self.assertEqual(whole_manifest["scope"], "every type")
        self.assertTrue({"EAxis", "BigDamagePacket"} <= every and set(listed) <= every, sorted(every))
        self.assertNotIn("UberGraphFrame", whole["chunks/content.Game.json"])
        everything, everything_manifest = gameindex.make_site(self.typed, self.wax, everything=True)
        self.assertEqual(everything_manifest["scope"], "everything")
        self.assertIn("UberGraphFrame", everything["chunks/content.Game.json"])

    def test_site_chunks_stay_under_their_limit(self):
        files, manifest = gameindex.make_site(self.typed, self.wax, limit=3000)
        self.assertGreater(len(manifest["chunks"]), 4)
        for chunk in manifest["chunks"]:
            self.assertLessEqual(chunk["bytes"], 3000, chunk["id"])
            json.loads(files[chunk["file"]])

    def changed_index(self):
        text = DUMP
        for old, new in (
            ("/Script/Icarus.ActorState:MaxHealth ", "/Script/Icarus.ActorState:HealthMax "),
            ("FloatProperty /Script/Icarus.ActorState:Shelter ", "IntProperty /Script/Icarus.ActorState:Shelter "),
            ("/Script/Icarus.ActorState:SetHealth:Amount ", "/Script/Icarus.ActorState:SetHealth:NewHealth "),
            ("/Script/Icarus.Usable ", "/Script/Icarus.Useable "),
            ("EAliveState::Dead ", "EAliveState::Deceased "),
            ("[0000000000000000] EAliveState::EAliveState_MAX [n: 6D] [v: 2]",
             "[0000000000000000] EAliveState::Downed [n: 6E] [v: 2]\n[0000000000000000] EAliveState::EAliveState_MAX [n: 6D] [v: 3]"),
        ):
            self.assertIn(old, text)
            text = text.replace(old, new)
        lines = [line for line in text.splitlines() if "ActorState:IsAlive" not in line and "/Game/Mods/Rig" not in line]
        lines.append("[0000000000003170] IntProperty /Script/Icarus.ActorState:Shield [o: 330] [n: 90] [c: 00007FF6000000D0] [owr: 0000000000003100]")
        lines.append("[0000000000003A00] Class /Script/Icarus.Brand [n: 91] [c: 00000000000000B0] [or: 0000000000003000] [sps: 0000000000001100]")
        return gameindex.build_index(self.put("changed/ObjectDump.txt", "\n".join(lines) + "\n"))

    def test_diff(self):
        new = self.changed_index()
        result = gameindex.diff_indexes(self.index, new)
        classes = result["classes"]
        self.assertEqual(classes["added"], ["/Script/Icarus.Brand"])
        self.assertEqual(classes["removed"], ["/Game/Mods/Rig.Rig_C"])
        self.assertEqual(classes["renamed"], [["/Script/Icarus.Usable", "/Script/Icarus.Useable"]])
        self.assertEqual(list(classes["changed"]), ["/Script/Icarus.ActorState"])
        state = classes["changed"]["/Script/Icarus.ActorState"]
        self.assertEqual(state["properties"]["added"], [{"name": "Shield", "type": "Int"}])
        self.assertEqual(state["properties"]["renamed"], [{"old": "MaxHealth", "new": "HealthMax", "type": "Int", "why": "same position"}])
        self.assertEqual(state["properties"]["changed"], [{"name": "Shelter", "old": "Float", "new": "Int"}])
        self.assertEqual(state["functions"]["removed"], [{"name": "IsAlive", "type": "(): Bool"}])
        self.assertEqual(state["functions"]["changed"], [{"name": "SetHealth", "old": "(Amount: Int)", "new": "(NewHealth: Int)"}])
        values = result["enums"]["changed"]["/Script/Icarus.EAliveState"]["values"]
        self.assertEqual(values["added"], [{"name": "Downed", "type": "2"}])
        self.assertEqual(values["renamed"], [{"old": "Dead", "new": "Deceased", "type": "1", "why": "same value"}])
        self.assertEqual(values["changed"], [{"name": "EAliveState_MAX", "old": "2", "new": "3"}])
        self.assertEqual(result["structs"], {"added": [], "removed": [], "renamed": [], "changed": {}})
        lines = gameindex.diff_lines(result, new)
        for line in ("Classes: 1 added, 1 removed, 1 renamed, 1 changed",
                     "+ class /Script/Icarus.Brand : Object",
                     "- class /Game/Mods/Rig.Rig_C",
                     "> class /Script/Icarus.Usable -> /Script/Icarus.Useable",
                     "~ class /Script/Icarus.ActorState",
                     "    + property Shield: Int",
                     "    > property MaxHealth -> HealthMax: Int (same position)",
                     "    ~ property Shelter: Float -> Int",
                     "    - function IsAlive(): Bool",
                     "    ~ function SetHealth(Amount: Int) -> (NewHealth: Int)",
                     "    + value Downed = 2",
                     "    > value Dead -> Deceased = 1 (same value)",
                     "    ~ value EAliveState_MAX = 2 -> 3"):
            self.assertIn(line, lines)
        json.dumps(result)

    def test_a_rename_is_found_by_a_similar_name_too(self):
        old = {"A": {"text": "Int", "at": 8}, "MaxStamina": {"text": "Int", "at": 16}, "Gone": {"text": "Float", "at": 24}}
        new = {"A": {"text": "Int", "at": 8}, "MaximumStamina": {"text": "Int", "at": 40}, "Fresh": {"text": "Bool", "at": 24}}
        found = gameindex.diff_members(old, new)
        self.assertEqual(found["renamed"], [{"old": "MaxStamina", "new": "MaximumStamina", "type": "Int", "why": "similar name"}])
        self.assertEqual(found["removed"], [{"name": "Gone", "type": "Float"}])
        self.assertEqual(found["added"], [{"name": "Fresh", "type": "Bool"}])

    def test_no_difference_with_itself(self):
        result = gameindex.diff_indexes(self.index, self.index)
        for group in ("classes", "structs", "enums"):
            self.assertEqual(result[group], {"added": [], "removed": [], "renamed": [], "changed": {}})

    def test_find(self):
        rows, total = gameindex.find(self.index, "health", 20)
        shown = [row[3] for row in rows]
        self.assertEqual(shown[0], "ActorState.Health: integer")
        self.assertIn("ActorState.MaxHealth: integer", shown)
        self.assertIn("ActorState:SetHealth(Amount: integer)", shown)
        self.assertIn("ActorState:GetHealth(): integer", shown)
        self.assertEqual(total, len(rows))
        self.assertEqual(rows[0][4], "/Script/Icarus.ActorState")
        rows, _ = gameindex.find(self.index, "actorstate", 20)
        self.assertEqual(rows[0][3], "class ActorState : ActorComponent")
        self.assertEqual(gameindex.find(self.index, "dead", 20)[0][0][3], "EAliveState.Dead = 1")
        self.assertEqual(gameindex.find(self.index, "nothing like this", 20), ([], 0))
        self.assertEqual(len(gameindex.find(self.index, "e", 5)[0]), 5)

    def test_lua_data(self):
        read = gameindex.read_lua_data
        self.assertEqual(read('return { "a", \'b\', 3, -4, 1.5, true, false }'), ["a", "b", 3, -4, 1.5, True, False])
        self.assertEqual(read('{ id = "x", ["a key"] = { 1, 2 }, nested = { deep = {} } } -- the end'),
                         {"id": "x", "a key": [1, 2], "nested": {"deep": []}})
        self.assertEqual(read('{ "first", name = "n", "second" }'), {"name": "n", 1: "first", 2: "second"})
        self.assertEqual(read('{ "a \\"quoted\\" word", "back\\\\slash", "-- not a comment" } -- a comment'),
                         ['a "quoted" word', "back\\slash", "-- not a comment"])
        for text in ('return { a = function() end }', "{ 1, 2", "{ 1 } 2", "{ a + 1 }"):
            with self.assertRaises(SystemExit, msg=text):
                read(text)

    def needs(self, text=NEEDS):
        folder = os.path.join(self.dir, "tables")
        for name, data in TABLES.items():
            self.put("tables/" + name, json.dumps(data))
        return gameindex.check_needs(gameindex.read_needs(self.put("needs/needs.lua", text)), self.index, gameindex.TableFiles(folder))

    def test_what_wax_uses_is_found_in_the_index_and_the_tables(self):
        state, screens = self.needs()
        self.assertEqual((state["id"], state["name"], state["missing"]), ("state", "Actor state", []))
        self.assertEqual(state["checked"], 21)
        self.assertEqual([item["name"] for item in state["unknown"]], ["D_Loose:Hits.Never.Filled"])
        self.assertEqual(screens["missing"], [])
        self.assertEqual([(item["kind"], item["name"]) for item in screens["unknown"]], [("class", "/Game/UI/UMG_Late.UMG_Late_C")])
        self.assertIn("not in this dump", screens["unknown"][0]["why"])
        lines = gameindex.needs_lines([state, screens])
        self.assertIn("Actor state (state): fine, 21 names, 1 could not be checked", lines)
        self.assertIn("Screens (screens): fine, 2 names, 1 could not be checked", lines)
        self.assertEqual(lines[-1], "All 2 parts are fine (23 names).")

    def test_what_is_gone_is_named_with_the_closest_name(self):
        text = NEEDS
        for old, new in NEEDS_CHANGES:
            self.assertIn(old, text)
            text = text.replace(old, new)
        state, screens = self.needs(text)
        found = {item["name"]: (item["kind"], item["hint"], item["note"]) for item in state["missing"]}
        self.assertEqual(found, {
            "/Script/Icarus.CharacterState:Healt": ("property", "Health", None),
            "/Script/Icarus.CharacterState:IsAlive": ("property", None, "it is a function now"),
            "/Script/Icarus.CharacterState:GetHealthy": ("function", "GetHealth", None),
            "/Game/Other/BP_Thing.BP_Thing_C": ("class", "/Game/Mods/BP_Thing.BP_Thing_C", "it is at another path"),
            "/Script/Icarus.BigDamagePacket:Scales": ("field", "Scale", None),
            "/Script/Icarus.EAliveState:Alive": ("value", None, "it is 0 now and Wax expects 1"),
            "/Script/Icarus.EAliveState:Deceased": ("value", None, "Dead has its number, 1"),
            "/Script/Icarus.EAliveState:Gone": ("value", None, None),
            "D_Damage:Amounts": ("field", "Amount", "not in BigDamagePacket"),
            "D_Damage:Amount.More": ("field", None, "Amount has no fields"),
            "D_Lose": ("table", "D_Loose", None),
            "/Script/Icarus.ActorStates": ("class", "/Script/Icarus.ActorState", None),
        })
        self.assertEqual(screens["missing"], [])
        lines = gameindex.needs_lines([state, screens])
        self.assertIn("Actor state (state): 12 of 25 names are gone, 1 could not be checked", lines)
        self.assertIn("    - property /Script/Icarus.CharacterState:Healt  (closest: Health)", lines)
        self.assertIn("    - field D_Damage:Amounts  (not in BigDamagePacket, closest: Amount)", lines)
        self.assertEqual(lines[-1], "1 of 2 parts use names the game no longer has: Actor state.")

    def test_a_field_the_table_lost_is_gone_whatever_the_dump_says(self):
        tables = dict(TABLES)
        try:
            TABLES["Traits/D_Damage.json"] = {"RowStruct": "/Script/Icarus.BigDamagePacket", "Defaults": {"Amount": 0}, "Rows": []}
            state, _ = self.needs()
        finally:
            TABLES.update(tables)
        found = {item["name"]: item["note"] for item in state["missing"]}
        self.assertEqual(found, {"D_Damage:Scale": "not among the table's fields", "D_Damage:Causer": "not among the table's fields"})
        self.assertEqual(sorted(item["name"] for item in state["unknown"]),
                         ["D_Damage (its meta table):Level.RowName", "D_Loose:Hits.Never.Filled"])

    def test_a_name_in_another_letter_case_is_found_whatever_made_the_index(self):
        # As the engine finds it, and as Wax's own check in the game does: the mirror of the case in needs_test.lua.
        text = NEEDS
        for old, new in (('"/Script/Icarus.CharacterState", properties = { "Health", "Stamina" }, functions = { "IsAlive" }',
                          '"/script/icarus.characterstate", properties = { "health", "STAMINA" }, functions = { "isalive" }'),
                         ('struct = "/Script/Icarus.BigDamagePacket", fields = { "Amount", "Scale" }',
                          'struct = "/Script/Icarus.bigdamagepacket", fields = { "amount", "SCALE" }'),
                         ('enum = "/Script/Icarus.EAliveState", values = { Alive = 0, Dead = 1 }',
                          'enum = "/Script/Icarus.ealivestate", values = { alive = 0, DEAD = 1 }'),
                         ('fields = { "Amount", "Scale", "Causer" }, meta = { "Level.RowName" }',
                          'fields = { "amount", "scale", "CAUSER" }, meta = { "level.rowname" }'),
                         ('fields = { "Hits.At.X", "Hits.Never.Filled" }', 'fields = { "hits.at.x", "Hits.Never.Filled" }')):
            self.assertIn(old, text)
            text = text.replace(old, new)
        folder = os.path.join(self.dir, "tables")
        for name, data in TABLES.items():
            self.put("tables/" + name, json.dumps(data))
        parts = gameindex.read_needs(self.put("needs/cased.lua", text))
        for source in ({"dump": "ObjectDump.txt"}, {"model": "abc-1"}):
            with self.subTest(source):
                state = gameindex.check_needs(parts, dict(self.index, source=source), gameindex.TableFiles(folder))[0]
                self.assertEqual(state["missing"], [])
                self.assertEqual([item["name"] for item in state["unknown"]], ["D_Loose:Hits.Never.Filled"])
        # A name that is really another one is still gone, with the right one offered.
        gone = gameindex.read_needs(self.put("needs/typo.lua", text.replace('"health"', '"healt"')))
        missing = gameindex.check_needs(gone, self.index, gameindex.TableFiles(folder))[0]["missing"]
        self.assertEqual([(item["name"], item["hint"]) for item in missing], [("/Script/Icarus.CharacterState:healt", "Health")])

    def test_a_function_wax_refuses_says_so_in_the_editor(self):
        # The list Wax's runtime goes by, in the files' spelling or the running game's: the editor says what the game will do.
        listed = self.put("refused/oversized_functions.lua", "-- a list\nreturn {\n"
                          '  ["/Script/Icarus.ActorState:sethealth "] = 14880,\n  ["/Script/Icarus.ActorState:SetHealth"] = 700,\n'
                          '  ["/Script/Icarus.ActorState:BigCall"] = 9000,\n  ["/Game/Mods/BP_Thing.BP_Thing_C:Get Fog Scale"] = 600,\n'
                          '  ["/Script/Icarus.Gone:Nothing"] = 600,\n}\n')
        refused = gameindex.refused_calls(listed)
        self.assertEqual(refused, {"/script/icarus.actorstate:sethealth": 14880, "/script/icarus.actorstate:bigcall": 9000,
                                   "/game/mods/bp_thing.bp_thing_c:get fog scale": 600, "/script/icarus.gone:nothing": 600})
        self.assertEqual(gameindex.refused_calls(os.path.join(self.dir, "refused", "none.lua")), {})
        files, summary = self.types(refused=refused)
        icarus = files["script/Icarus.lua"]
        # No figure: the list's number was measured with local variables, which do not count.
        self.assertIn("---@field SetHealth fun(self: ActorState, Amount: integer) Wax refuses this call from Lua.\n", icarus)
        self.assertIn("---@field BigCall fun(self: ActorState, Packet: DamagePacket|{}, Tail: integer) Do not call from Lua: "
                      "it needs 516 bytes and the call buffer holds 512.\n", icarus)
        self.assertIn("---@field GetHealth fun(self: ActorState): integer\n", icarus)
        self.assertIn('---@field ["Get Fog Scale"] fun(self: BP_Thing_C, Scale_Out: Vector|{}) Wax refuses this call from Lua.\n',
                      files["content/Game.lua"])
        self.assertEqual((summary["refused"], summary["do_not_call"]), (2, 1))
        self.assertEqual(sorted(summary["refused_written"]), [("ActorState", "BigCall"), ("ActorState", "SetHealth"), ("BP_Thing_C", "Get Fog Scale")])
        self.assertEqual(self.types()[1]["refused"], 0)
        site, _manifest = gameindex.make_site(self.typed, self.wax, refused=refused)
        state = next(entry for name, text in site.items() if name.startswith("chunks/") for entry in json.loads(text)["types"]
                     if entry["name"] == "ActorState")
        flags = {row[0]: (row[4] if len(row) > 4 else []) for row in state["funcs"]}
        self.assertEqual((flags["SetHealth"], flags["BigCall"], flags["GetHealth"]), (["oversized"], ["oversized"], []))
        self.assertEqual(gameindex.call_note({"flags": ["blueprint", "unsized"]}),
                         "Do not call from Lua: the size of its parameters is not known for this build of the game.")
        self.assertEqual(gameindex.call_note({"flags": ["blueprint"]}, True), "Wax refuses this call from Lua.")

    def model_made(self):
        """The fixture as a model would give it: names as the game's files spell them, not as the running game does."""
        index = json.loads(json.dumps(self.typed))
        index["source"] = {"model": "abc-1"}
        classes = {record["path"]: record for record in index["classes"]}
        state, thing = classes["/Script/Icarus.ActorState"], classes["/Game/Mods/BP_Thing.BP_Thing_C"]
        by_name(state["properties"])["Health"]["name"] = "health"
        by_name(state["functions"])["GetHealth"]["name"] = "Gethealth"
        thing["name"] = "bp_thing_c"
        state["properties"].append({"name": "seen_12", "type": "Int", "offset": 800})
        index["classes"].append({"name": "BP_Late_C", "path": "/Game/Mods/BP_Late.BP_Late_C", "package": "/Game/Mods/BP_Late",
                                 "native": False, "kind": "BlueprintGeneratedClass", "parent": "/Script/Icarus.IcarusCharacter",
                                 "properties": [{"name": "maxhealth", "type": "Int", "offset": 1}, {"name": "Unheard", "type": "Int", "offset": 5}],
                                 "functions": []})
        return index

    def test_names_take_the_running_games_spelling_when_a_dump_is_there(self):
        dumped = json.loads(json.dumps(self.typed))
        by_name(by_name(dumped["classes"])["BP_Thing_C"]["functions"])["UseItem"]["name"] = "UseItem "
        spelling = gameindex.Spelling(dumped)
        self.assertEqual((spelling.name("health"), spelling.name("SEEN_12"), spelling.name("Unheard_3"), spelling.name("bp_thing_c")),
                         ("Health", "Seen_12", "Unheard_3", "BP_Thing_C"))
        self.assertEqual(spelling.member("/game/mods/bp_thing.BP_THING_C", "useitem"), "UseItem ")
        self.assertEqual(spelling.member("/Script/Icarus.ActorState", "UseItem"), "UseItem", "the space belongs to that class's member")
        self.assertTrue(spelling.holds("/script/icarus.ACTORSTATE") and not spelling.holds("/Game/Mods/BP_Late.BP_Late_C"))
        index = self.model_made()
        plain = "".join(gameindex.make_types(index, self.wax)[0].values())
        self.assertIn("---@field health integer\n", plain)
        self.assertIn("---@class bp_thing_c : IcarusCharacter\n", plain)
        files, summary = gameindex.make_types(index, self.wax, spelling=spelling)
        text = "".join(files.values())
        for line in ("---@field Health integer", "---@field GetHealth fun(self: ActorState): integer", "---@field Seen_12 integer",
                     "---@class BP_Thing_C : IcarusCharacter", '---@field ["UseItem "] fun(self: BP_Thing_C, Target: Actor?): boolean',
                     "---@class BP_Late_C : IcarusCharacter\n---@field MaxHealth integer\n---@field Unheard integer"):
            self.assertIn(line + "\n", text)
        self.assertNotIn("---@field health ", text)
        self.assertEqual(summary["respelled_by"], dumped["source"]["written"])
        self.assertIn("BP_Thing_C", files["classes.txt"].split())
        self.assertEqual(by_name(index["classes"])["ActorState"]["properties"][0]["name"], "health", "the index handed in is not changed")
        # An index made from a dump already spells as the running game did, and no dump means no respelling.
        self.assertIs(gameindex.respelled(self.typed, spelling), self.typed)
        self.assertIs(gameindex.respelled(index, None), index)
        site, _ = gameindex.make_site(index, self.wax, spelling=spelling)
        self.assertIn('"UseItem "', "".join(site.values()))
        gameindex.write_index(self.typed, os.path.join(self.dir, "spelling", gameindex.DUMP_INDEX))
        gameindex.write_index(index, os.path.join(self.dir, "spelling", "index.json"))
        self.assertEqual(gameindex.dump_spelling(os.path.join(self.dir, "spelling", "index.json")).name("health"), "Health")
        self.assertIsNone(gameindex.dump_spelling(os.path.join(self.dir, "no-such", "index.json")))

    def test_two_classes_of_one_name_and_the_one_that_keeps_it(self):
        index = json.loads(json.dumps(self.typed))
        thing = by_name(index["classes"])["BP_Thing_C"]
        index["classes"].append(dict(thing, path="/Game/Alpha/Proto/BP_Thing.BP_Thing_C", package="/Game/Alpha/Proto/BP_Thing"))
        index["classes"].append(dict(thing, name="BP_thing_C", path="/Game/Mods/Low/BP_thing.BP_thing_C", package="/Game/Mods/Low/BP_thing"))
        game = gameindex.Game(index)
        names = gameindex.Names(game)
        # By path the prototype comes first and takes the plain name; a name in another letter case is the same name.
        self.assertEqual((names.of["/Game/Alpha/Proto/BP_Thing.BP_Thing_C"], names.of["/Game/Mods/BP_Thing.BP_Thing_C"],
                          names.of["/Game/Mods/Low/BP_thing.BP_thing_C"]), ("BP_Thing_C", "BP_Thing_C__Mods", "BP_thing_C__Low"))
        self.assertEqual(len({name.lower() for name in names.of.values()}), len(names.of))
        summary = gameindex.make_types(index, self.wax)[1]
        self.assertEqual(summary["same_named"], [("BP_Thing_C", "/Game/Alpha/Proto/BP_Thing.BP_Thing_C",
                                                  ["/Game/Mods/BP_Thing.BP_Thing_C", "/Game/Mods/Low/BP_thing.BP_thing_C"])])
        self.assertTrue(any(line.startswith("3 blueprint classes are called BP_Thing_C: /Game/Alpha/Proto/BP_Thing.BP_Thing_C keeps the name")
                            and line.endswith("PLAIN_NAMES of scripts\\gameindex.py.") for line in gameindex.check_lines(summary)))
        # A pair that is settled in the table: the listed class keeps the name, in the spelling given, and nothing is asked.
        self.addCleanup(gameindex.PLAIN_NAMES.pop, "/game/mods/bp_thing.bp_thing_c", None)
        gameindex.PLAIN_NAMES["/game/mods/bp_thing.bp_thing_c"] = "BP_Thing_C"
        names = gameindex.Names(gameindex.Game(index))
        self.assertEqual((names.of["/Game/Mods/BP_Thing.BP_Thing_C"], names.of["/Game/Alpha/Proto/BP_Thing.BP_Thing_C"]),
                         ("BP_Thing_C", "BP_Thing_C__Proto"))
        self.assertEqual(gameindex.make_types(index, self.wax)[1]["same_named"], [])
        self.assertEqual(gameindex.make_types(self.typed, self.wax)[1]["same_named"], [])

    def wax_with(self, name, **files):
        folder = os.path.join(self.dir, name)
        self.put(name + "/game.lua", WAX_GAME)
        for file, text in files.items():
            self.put("%s/%s.lua" % (name, file), text)
        return folder

    def test_what_wax_declares_is_read_from_every_types_file(self):
        folder = self.wax_with("wax-read", character="\n".join([
            "---@meta _", "", "---What Wax adds.", "---@class IcarusCharacter", "---@field Alive boolean? False once it is dead.",
            '---@field ["Odd Name"] integer', "---@field private hidden integer", "---@field [string] any", "local Character = {}", "",
            "---@param amount integer", "function Character:Heal(amount) end", "function Character.Kill() end", "",
            "---@class WaxOptions: WaxBase, IcarusCharacter", "---@field like string", "", "---@class WaxSignal<F>", "",
            "---@alias WaxColorName \"red\"|\"blue\"", "---@enum WaxMode", "local Other = {}", "function Other:NotAMember() end", ""]))
        api = gameindex.WaxApi(folder)
        character = api.classes["IcarusCharacter"]
        self.assertEqual((character["file"], character["parents"]), ("character.lua", []))
        self.assertEqual(sorted(character["members"]), ["Alive", "Heal", "Kill", "Odd Name", "hidden"])
        self.assertEqual((api.classes["WaxOptions"]["parents"], sorted(api.classes["WaxOptions"]["members"])), (["WaxBase", "IcarusCharacter"], ["like"]))
        self.assertEqual(api.classes["WaxSignal"]["members"], {})
        self.assertEqual(api.other, {"WaxColorName", "WaxMode"})
        self.assertEqual(api.instance_members(), {"Name", "Parent", "GetParent", "GetChildren"})
        self.assertEqual(gameindex.instance_api(folder), api.instance_members())
        self.assertEqual(api.above("WaxOptions"), ["WaxOptions", "IcarusCharacter"])
        self.assertEqual(gameindex.instance_api(os.path.join(self.dir, "no-wax")), set(gameindex.INSTANCE_MEMBERS))
        self.assertEqual(gameindex.declared_names(folder), {"WaxInstance", "WaxGame", "IcarusCharacter", "WaxOptions", "WaxSignal",
                                                            "WaxColorName", "WaxMode"})

    def test_a_types_file_that_adds_to_a_game_class_does_not_rename_it(self):
        plain_files, plain = self.types()
        folder = self.wax_with("wax-adds", character="---@meta _\n\n---@class IcarusCharacter\n---@field Alive boolean\n"
                               "---@field Health integer\nlocal Character = {}\n\nfunction Character:Heal(amount) end\n",
                               other="---@meta _\n\n---@alias Vector table\n\n---@class DamagePacket\n---@field Wax integer\n")
        files, summary = gameindex.make_types(self.typed, folder)
        self.assertIn("---@class IcarusCharacter : Pawn\n", files["script/Icarus.lua"])
        self.assertEqual(files["classes.txt"], plain_files["classes.txt"])
        self.assertIn("---@class BP_Thing_C : IcarusCharacter\n", files["content/Game.lua"])
        self.assertEqual(summary["wax_adds_to"], {"IcarusCharacter": "/Script/Icarus.IcarusCharacter"})
        self.assertEqual(plain["wax_adds_to"], {})
        # An alias, and a class Wax declares where the game has a struct of that name, stay Wax's: the game's is told apart.
        self.assertIn("---@class Vector__CoreUObject\n", files["script/CoreUObject.lua"])
        self.assertIn("---@class DamagePacket__Icarus\n", files["script/Icarus.lua"])
        self.assertNotIn("---@class DamagePacket\n", files["script/Icarus.lua"])

    def test_a_wax_name_in_front_of_a_reflected_member_is_a_check_line(self):
        index = json.loads(json.dumps(self.typed))
        classes = by_name(index["classes"])
        classes["Actor"]["properties"].append({"name": "Owner", "type": "Object", "ref": "/Script/Engine.Actor", "offset": 8})
        classes["Pawn"]["functions"].append({"name": "heal", "params": [], "flags": ["native"]})
        classes["BP_Thing_C"]["properties"].append({"name": "Health", "type": "Int", "offset": 4})
        classes["ActorState"]["properties"].append({"name": "Owner", "type": "Int", "offset": 4})
        folder = self.wax_with("wax-clash", character="---@meta _\n\n---@class IcarusCharacter\n---@field Alive boolean\n"
                               "---@field Health integer\n---@field Owner WaxInstance\nlocal Character = {}\n\n"
                               "function Character:Heal(amount) end\n",
                               me="---@meta _\n\n---@class WaxExtra\n---@field Mode integer\n---@field Free integer\n\n"
                                  "---@class WaxMe : BP_Thing_C, WaxExtra\n---@field Seen integer\n\n"
                                  "---@class WaxLoose\n---@field Health integer\n")
        files, summary = gameindex.make_types(index, folder)
        thing, actor, pawn = "/Game/Mods/BP_Thing.BP_Thing_C", "/Script/Engine.Actor", "/Script/Engine.Pawn"
        own = [row for row in summary["wax_clashes"] if row[1] != "WaxInstance"]
        self.assertEqual(own, [
            # above the class, with another letter case, and in a class built on it
            ("character.lua", "IcarusCharacter", "Heal", pawn, "heal"),
            ("character.lua", "IcarusCharacter", "Health", thing, "Health"),
            ("character.lua", "IcarusCharacter", "Owner", actor, "Owner"),
            # a Wax class built on a game class, itself and the Wax classes above it
            ("me.lua", "WaxExtra", "Mode", thing, "Mode"),
            ("me.lua", "WaxMe", "Seen", thing, "Seen"),
        ])
        every = [row[2:] for row in summary["wax_clashes"] if row[1] == "WaxInstance"]
        self.assertIn(("GetParent", actor, "GetParent"), every)
        self.assertIn(("Name", "/Game/Mods/BP_Thing.BP_Thing_C", "Name"), every)
        # Name and Parent are the ruling's two; every other clash is open until it is on the list of accepted ones.
        self.assertEqual(sorted(row[2] for row in summary["wax_clashes_open"]), ["GetParent", "Heal", "Health", "Mode", "Owner", "Seen"])
        lines = gameindex.check_lines(summary)
        self.assertIn("wax\\types\\character.lua: IcarusCharacter.Owner replaces the game's Actor.Owner (reach the game's with :Call / :Get)", lines)
        self.assertIn("wax\\types\\game.lua: WaxInstance.GetParent replaces the game's Actor.GetParent (reach the game's with :Call / :Get)", lines)
        self.assertFalse([line for line in lines if ".Name replaces" in line or "ActorState.Owner" in line])
        self.addCleanup(gameindex.ACCEPTED_CLASHES.discard, ("IcarusCharacter", "Owner", actor))
        gameindex.ACCEPTED_CLASHES.add(("IcarusCharacter", "Owner", actor))
        again = gameindex.make_types(index, folder)[1]
        self.assertNotIn("Owner", [row[2] for row in again["wax_clashes_open"]])
        self.assertIn("wax\\types\\character.lua: IcarusCharacter.Owner replaces the game's Actor.Owner (reach the game's with :Call / :Get)",
                      gameindex.check_lines(again), "an accepted clash is still said")
        # What Wax answers on a class is not declared again on that class or on one built on it; elsewhere it stays.
        mods = files["content/Game.lua"]
        block = mods[mods.index("---@class BP_Thing_C : IcarusCharacter\n"):]
        block = block[:block.index("\n\n")] if "\n\n" in block else block
        self.assertNotIn("---@field Health ", block)
        self.assertIn("---@field Mode E_Mode\n", block)
        self.assertIn("---@field Health integer\n", files["script/Icarus.lua"])
        self.assertIn("---@field Owner integer\n", files["script/Icarus.lua"])
        # A class above keeps its own member: there Wax answers nothing, and below it Wax's declaration comes first.
        self.assertIn("---@field Owner Actor\n", files["script/Engine.lua"].split("---@class Actor ")[1].split("---@class ")[0])

    def test_a_game_class_also_extends_the_wax_class_that_lists_what_wax_gives_it(self):
        thing, pawn = "/Game/Mods/BP_Thing.BP_Thing_C", "/Script/Engine.Pawn"
        character, spectator = "/Script/Icarus.IcarusCharacter", "/Script/Icarus.IcarusSpectatorPawn"
        gone, controller = "/Script/Icarus.Gone", "/Script/Engine.Controller"
        # With the table as shipped and no Wax class of those names, nothing is added and it is said.
        plain = self.types()[1]
        self.assertEqual(plain["also_extends"], {})
        self.assertIn((character, "WaxCharacter", "wax\\types declares no such class"), plain["also_extends_unwritten"])
        self.assertIn(("/Script/Icarus.Inventory", "WaxInventory", "the index has no such class"), plain["also_extends_unwritten"])
        index = json.loads(json.dumps(self.typed))
        classes = by_name(index["classes"])
        classes["Pawn"]["functions"].append({"name": "getstat", "params": [], "flags": ["native"]})
        classes["BP_Thing_C"]["properties"].append({"name": "Health", "type": "Int", "offset": 4})
        classes["IcarusSpectatorPawn"]["properties"].append({"name": "Backpack", "type": "Int", "offset": 4})
        folder = self.wax_with("wax-also", character="\n".join([
            "---@meta _", "", "---@class WaxCharacterStats", "---@field Stats table<string, integer>?", "local Stats = {}", "",
            "function Stats:GetStat(name) end", "", "---@class WaxCharacter : WaxCharacterStats", "---@field Health integer?",
            "---@field Level integer?", "", "---@class WaxPlayerItems", "---@field Backpack WaxInstance?", "",
            "---@class WaxPlayerCharacter : WaxCharacter, WaxPlayerItems", "---@field Food integer?", "",
            "---@class WaxMe : BP_Thing_C, WaxPlayerCharacter", "---@field Exists boolean", ""]))
        table = dict(gameindex.ALSO_EXTENDS)
        self.addCleanup(lambda: (gameindex.ALSO_EXTENDS.clear(), gameindex.ALSO_EXTENDS.update(table)))
        gameindex.ALSO_EXTENDS.clear()
        gameindex.ALSO_EXTENDS.update({character: ("WaxPlayerCharacter", "WaxPlayerItems"), spectator: ("WaxPlayerItems", "WaxNotThere"),
                                       gone: ("WaxCharacter",), controller: ("WaxMe",)})
        files, summary = gameindex.make_types(index, folder)
        # Wax's class comes before the game's parent; one that is reached through another listed one is not repeated.
        self.assertIn("---@class IcarusCharacter : WaxPlayerCharacter, Pawn\n", files["script/Icarus.lua"])
        self.assertIn("---@class IcarusSpectatorPawn : WaxPlayerItems, Pawn\n", files["script/Icarus.lua"])
        self.assertIn("---@class BP_Thing_C : IcarusCharacter\n", files["content/Game.lua"])
        self.assertIn("---@class Controller : Actor\n", files["script/Engine.lua"])
        self.assertEqual(summary["also_extends"], {"IcarusCharacter": ["WaxPlayerCharacter"], "IcarusSpectatorPawn": ["WaxPlayerItems"]})
        self.assertEqual(summary["also_extends_unwritten"], [
            (spectator, "WaxNotThere", "wax\\types declares no such class"), (gone, "WaxCharacter", "the index has no such class"),
            (controller, "WaxMe", "it is built on a game class itself")])
        lines = gameindex.check_lines(summary)
        self.assertIn("scripts\\gameindex.py: ALSO_EXTENDS gives Controller what WaxMe lists, and that was not written: "
                      "it is built on a game class itself.", lines)
        # A reflected member named like one of those: in a class built on it, above it in another letter case, on the class itself.
        own = [row for row in summary["wax_clashes"] if row[1] != "WaxInstance"]
        self.assertEqual(own, [
            ("character.lua", "WaxCharacter", "Health", thing, "Health"),
            ("character.lua", "WaxCharacterStats", "GetStat", pawn, "getstat"),
            ("character.lua", "WaxPlayerItems", "Backpack", spectator, "Backpack"),
        ])
        self.assertEqual([row for row in own if row not in summary["wax_clashes_open"]], [])
        self.assertIn("wax\\types\\character.lua: WaxCharacter.Health replaces the game's BP_Thing_C.Health "
                      "(reach the game's with :Call / :Get)", lines)
        # What Wax answers there is not declared again, so the editor finds Wax's; a class that is not under it keeps its own.
        mods = files["content/Game.lua"]
        block = mods[mods.index("---@class BP_Thing_C : IcarusCharacter\n"):].split("\n\n")[0]
        self.assertNotIn("---@field Health ", block)
        self.assertIn("---@field Mode E_Mode\n", block + "\n")
        icarus = files["script/Icarus.lua"]
        self.assertNotIn("---@field Backpack ", icarus[icarus.index("---@class IcarusSpectatorPawn "):].split("\n\n")[0])
        self.assertIn("---@field Health integer\n", icarus[icarus.index("---@class ActorState "):].split("\n\n")[0] + "\n")
        self.assertIn("---@field getstat fun(self: Pawn)\n", files["script/Engine.lua"])
        # The game browser's example reaches the game's own member the long way, as it does for every name Wax answers.
        site, manifest = gameindex.make_site(index, folder)
        chunks = {c["id"]: json.loads(site[c["file"]]) for c in manifest["chunks"]}
        self.assertIn(["Health", "integer", 'print(obj:Get("Health"))'], by_name(chunks["content.Game"]["types"])["BP_Thing_C"]["props"])
        self.assertIn(["Health", "integer", "print(obj.Health)"], by_name(chunks["script.Icarus"]["types"])["ActorState"]["props"])

    def test_a_member_of_game_that_could_not_be_compared_is_said(self):
        self.assertEqual(self.types()[1]["entry_points_unread"], [])
        index = json.loads(json.dumps(self.typed))
        engine = by_name(index["classes"])["Engine"]
        engine["properties"][0]["name"] = "gameviewport"
        cased = gameindex.make_types(index, self.wax)[1]
        self.assertEqual((cased["entry_points_unread"], len(cased["entry_points"])), ([], 8))
        engine["properties"] = []
        summary = gameindex.make_types(index, self.wax)[1]
        self.assertEqual(summary["entry_points_unread"], ["Viewport", "World", "GameInstance", "GameState", "GameMode", "LocalPlayer", "Character"])
        self.assertEqual([row[0] for row in summary["entry_points"]], ["Engine"])
        self.assertIn("wax\\types\\game.lua: game.Character was not compared, the index does not hold the properties Wax reads to reach it.",
                      gameindex.check_lines(summary))
        game = gameindex.Game(self.typed)
        self.assertEqual(game.property("/Script/Icarus.CharacterState", "health")["name"], "Health")
        twins = json.loads(json.dumps(self.typed))
        by_name(twins["classes"])["CharacterState"]["properties"].append({"name": "health", "type": "Float", "offset": 2})
        self.assertEqual(gameindex.Game(twins).property("/Script/Icarus.CharacterState", "Health")["type"], "Int", "the exact name first")

    def test_help_says_what_the_index_is_made_from(self):
        done = subprocess.run([sys.executable, os.path.join(HERE, "gameindex.py"), "--help"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        said = " ".join(done.stdout.split())
        self.assertIn("written from the model of the game (scripts\\gamemodel) or from a UE4SS object dump", said)
        self.assertNotIn("read from the UE4SS object dump", said)
        self.assertEqual(gameindex.__doc__.splitlines()[0][:27], "Index of the game's classes")

    def test_needs_command_line(self):
        script = os.path.join(HERE, "gameindex.py")
        index = os.path.join(self.dir, "needs-cli", "index.json")
        gameindex.write_index(self.index, index)
        for name, data in TABLES.items():
            self.put("tables/" + name, json.dumps(data))
        broken = NEEDS.replace('"Stamina"', '"Stamna"')

        def run(text, *more):
            return subprocess.run([sys.executable, script, "needs", "--index", index, "--tables", os.path.join(self.dir, "tables"),
                                   "--needs", self.put("needs-cli/needs.lua", text), *more], capture_output=True, text=True)

        fine = run(NEEDS)
        self.assertEqual(fine.returncode, 0, fine.stdout + fine.stderr)
        self.assertIn("All 2 parts are fine (23 names).", fine.stdout)
        gone = run(broken)
        self.assertEqual(gone.returncode, 1, gone.stdout + gone.stderr)
        self.assertIn("    - property /Script/Icarus.CharacterState:Stamna  (closest: Stamina)", gone.stdout)
        self.assertEqual(json.loads(run(broken, "--json").stdout)[0]["missing"][0]["hint"], "Stamina")
        self.assertNotEqual(run("return { { name = 'no id' } }").returncode, 0)

    def test_command_line(self):
        out = os.path.join(self.dir, "cli")
        script = os.path.join(HERE, "gameindex.py")

        def run(*arguments):
            done = subprocess.run([sys.executable, script, *arguments], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            return done.stdout

        self.assertIn("29 classes (26 native, 3 blueprint), 6 structs, 4 enums", run("build", "--dump", self.dump, "--out", out))
        index = os.path.join(out, "index.json")
        self.assertIn("files", run("types", "--index", index, "--out", os.path.join(out, "types"), "--wax-types", self.wax))
        self.assertTrue(os.path.isfile(os.path.join(out, "types", "script", "Icarus.lua")))
        self.assertIn("(what a mod meets)", run("site", "--met", "--index", index, "--out", os.path.join(out, "site"), "--wax-types", self.wax))
        site = run("site", "--index", index, "--out", os.path.join(out, "site"), "--wax-types", self.wax)
        self.assertIn("chunks", site)
        self.assertIn("(every type)", site)
        self.assertTrue(os.path.isfile(os.path.join(out, "site", "manifest.json")))
        self.assertIn("ActorState.Health: integer", run("find", "Health", "--index", index))
        self.assertIn("0 changed", run("diff", index, index))
        self.assertEqual(json.loads(run("diff", index, index, "--json"))["classes"]["changed"], {})
        missing = subprocess.run([sys.executable, script, "find", "x", "--index", os.path.join(out, "none.json")],
                                 capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("Run: python scripts\\gameindex.py build", missing.stderr)


@unittest.skipUnless(os.path.isfile(gameindex.DUMP), f"the object dump is not at {gameindex.DUMP}")
class RealDump(Scratch):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.index = gameindex.build_index(gameindex.DUMP)
        cls.game = gameindex.Game(cls.index)

    def owner(self, path):
        record = self.game.classes[path]
        return by_name(record["properties"]), by_name(record["functions"])

    def test_everything_in_the_dump_was_placed(self):
        source = self.index["source"]
        self.assertEqual(source["properties_without_owner"], 0)
        self.assertEqual(source["unresolved_references"], 0)
        self.assertGreater(self.index["counts"]["classes"], 5000)
        self.assertGreater(self.index["counts"]["enum_values"], 5000)

    def test_actor_state(self):
        properties, functions = self.owner("/Script/Icarus.ActorState")
        for name in ("Health", "MaxHealth", "Armor"):
            self.assertEqual(properties[name]["type"], "Int", name)
        for name in ("GetHealth", "GetMaxHealth", "IsAlive", "SetHealth", "AddHealth"):
            self.assertIn(name, functions)
        self.assertEqual(functions["GetHealth"]["returns"], {"type": "Int"})
        self.assertEqual(functions["IsAlive"]["returns"], {"type": "Bool"})
        self.assertEqual([p["type"] for p in functions["SetHealth"]["params"]], ["Int"])
        self.assertEqual([p["type"] for p in functions["AddHealth"]["params"]], ["Int"])

    def test_character_state_is_a_subclass_with_stamina(self):
        self.assertEqual(self.game.classes["/Script/Icarus.CharacterState"]["parent"], "/Script/Icarus.ActorState")
        properties, _ = self.owner("/Script/Icarus.CharacterState")
        self.assertIn("Stamina", properties)
        self.assertIn("MaxStamina", properties)

    def test_the_character_holds_a_character_state(self):
        properties, _ = self.owner("/Script/Icarus.IcarusCharacter")
        self.assertEqual((properties["ActorState"]["type"], properties["ActorState"]["ref"]), ("Object", "/Script/Icarus.CharacterState"))

    def test_copy_to_clipboard(self):
        _, functions = self.owner("/Script/Icarus.UMGFunctionLibrary")
        copy = functions["CopyToClipboard"]
        self.assertEqual(copy["params"], [{"name": "Text", "type": "Str"}])
        self.assertIn("static", copy["flags"])

    def test_scroll_box(self):
        _, functions = self.owner("/Script/UMG.ScrollBox")
        self.assertEqual(functions["SetScrollbarPadding"]["params"],
                         [{"name": "NewScrollbarPadding", "type": "Struct", "ref": "/Script/SlateCore.Margin"}])
        self.assertEqual(functions["GetViewOffsetFraction"]["returns"], {"type": "Float"})
        self.assertEqual(functions["GetViewOffsetFraction"]["params"], [])

    def test_a_function_parameter_belongs_to_its_function(self):
        _, functions = self.owner("/Script/Icarus.IcarusPlayerController")
        push = functions["PushUIInput"]
        self.assertEqual([(p["name"], p["type"]) for p in push["params"]],
                         [("WidgetToFocus", "Object"), ("bAllowGameInput", "Bool"), ("bShowMouse", "Bool")])

    def test_blueprint_classes(self):
        character = self.game.classes["/Game/BP/Player/BP_IcarusPlayerCharacterSurvival.BP_IcarusPlayerCharacterSurvival_C"]
        self.assertFalse(character["native"])
        self.assertTrue(self.game.inherits(character["path"], "/Script/Icarus.IcarusCharacter"))

    def test_generated_types_and_site_stay_within_their_limits(self):
        files, summary = gameindex.make_types(self.index)
        self.assertLessEqual(summary["largest"], gameindex.TYPES_FILE_LIMIT)
        self.assertGreater(summary["classes"], 4000)
        text = "".join(files.values())
        self.assertIn("---@class ActorState : ActorComponent\n", text)
        self.assertIn("---@field ActorState CharacterState\n", text)
        self.assertIn("---@field SetScrollbarPadding fun(self: ScrollBox, NewScrollbarPadding: Margin|{})\n", text)
        self.assertIn(("Character", "IcarusPlayerCharacter?"), [row[:2] for row in summary["entry_points"]])
        self.assertEqual(summary["entry_points_differ"], [], "wax\\types\\game.lua and the dump disagree about a member of game")
        self.assertEqual(summary["entry_points_unread"], [], "a member of game was not compared: the dump does not hold the "
                         "properties Wax reads to reach it")
        site, manifest = gameindex.make_site(self.index)
        self.assertLessEqual(max(c["bytes"] for c in manifest["chunks"]), gameindex.SITE_CHUNK_LIMIT)
        self.assertLess(manifest["search"]["bytes"], 400 * 1024)

    def test_the_game_still_has_what_wax_uses(self):
        if not os.path.isdir(gameindex.TABLES_DIR):
            self.skipTest(f"the game's tables are not at {gameindex.TABLES_DIR} (scripts\\Export-GameData.ps1)")
        parts = gameindex.read_needs(gameindex.NEEDS)
        results = gameindex.check_needs(parts, self.index, gameindex.TableFiles(gameindex.TABLES_DIR))
        gone = [line for line in gameindex.needs_lines(results) if line.startswith("    - ")]
        self.assertEqual(gone, [], "wax\\runtime\\data\\needs.lua names what the game no longer has (python scripts\\gameindex.py needs)")
        self.assertGreater(sum(result["checked"] for result in results), 400)
        for part in parts:
            self.assertTrue(part.get("without", "").endswith("."), f"{part['id']} says what stops working without it")

    @unittest.skipUnless(os.path.isfile(LANGUAGE_SERVER), "the Lua language server is not installed (scripts\\Get-Tools.ps1)")
    def test_the_language_server_knows_the_members_and_their_types(self):
        files, _ = gameindex.make_types(self.index)
        # Wax's own definitions and the classes made here, laid out as wax\\types is
        types = os.path.join(self.dir, "types")
        os.makedirs(types, exist_ok=True)
        for name in os.listdir(gameindex.WAX_TYPES):
            if name.endswith(".lua"):
                shutil.copy(os.path.join(gameindex.WAX_TYPES, name), types)
        gameindex.write_tree(os.path.join(types, "icarus"), files, gameindex.GENERATED)
        library = [types.replace(os.sep, "/")]
        settings = {"runtime.version": "Lua 5.4", "runtime.builtin": {"basic": "disable"}, "workspace.library": library,
                    "workspace.checkThirdParty": "Disable", "diagnostics.disable": ["lowercase-global"]}
        self.put("mod/.luarc.json", json.dumps(settings, indent=4))
        self.put("mod/init.lua", "\n".join([
            "local character = assert(game.Character)",
            "local state = character.ActorState",
            "print(state.Health + state.MaxHealth + state.Stamina, state:IsAlive(), state.Name, #state:GetChildren())",
            "state:SetHealth(state:GetMaxHealth())",
            "local chained = game.Character and game.Character.ActorState.Health",
            "print(chained)",
            "",
        ]))

        def check():
            done = subprocess.run([LANGUAGE_SERVER, "--check", os.path.join(self.dir, "mod"), "--checklevel=Warning",
                                   "--logpath=" + os.path.join(self.dir, "log"), "--metapath=" + os.path.join(self.dir, "meta")],
                                  capture_output=True, text=True, encoding="utf-8", errors="replace")
            return done.stdout

        self.assertIn("no problems found", check())
        # a member the list does not have is let through, as the object may be of a class that adds it
        self.put("mod/wrong.lua", "\n".join([
            "local character = assert(game.Character)",
            "print(character.ActorState.NotListed)",
            'character.ActorState:SetHealth("full")',
            "---@type string",
            "local health = character.ActorState.Health",
            "print(health)",
            # what Wax gives a character and a creature has its own type too, not the `any` of an unlisted member
            "---@type string",
            "local given = character.Health",
            "---@type integer",
            "local kind = assert(game.Creatures:GetNearest()).Kind",
            "print(given, kind)",
            "",
        ]))
        found = check()
        self.assertIn("4 problems found", found)
        self.assertIn("SetHealth", found)
        self.assertNotIn("NotListed`", found)


def stored_model():
    """The model of the installed build, when scripts\\gamemodel is here and has made one: (its folder's name, its file)."""
    try:
        from gamemodel import model
    except ImportError:
        return None
    path = model.find()
    return (os.path.basename(os.path.dirname(path)), path) if path else None


FIELD_LINE = re.compile(r'^---@field (?:\["((?:[^"\\]|\\.)*)"\]|(\w+)) (.*)$')


def written_classes(files):
    """{editor type name: {member name: the rest of its line}} of the generated definitions."""
    found, current = {}, None
    for name, text in files.items():
        if not name.endswith(".lua"):
            continue
        for line in text.splitlines():
            if line.startswith("---@class "):
                current = found.setdefault(line.split()[1], {})
            elif line.startswith("---@alias "):
                current = None
            elif current is not None:
                field = FIELD_LINE.match(line)
                if field:
                    current[field.group(1).replace('\\"', '"').replace("\\\\", "\\") if field.group(1) is not None else field.group(2)] = field.group(3)
    return found


@unittest.skipUnless(os.path.isfile(gameindex.INDEX), f"no index at {gameindex.INDEX} (python scripts\\gameindex.py build)")
class Stored(unittest.TestCase):
    """What is on disk: the index, the editor's definitions made from it, and the lists Wax's runtime reads."""

    @classmethod
    def setUpClass(cls):
        cls.index = gameindex.load_index(gameindex.INDEX)
        cls.files, cls.summary = gameindex.types_of()

    def test_the_definitions_on_disk_are_the_ones_the_index_gives(self):
        changed = []
        for name, text in self.files.items():
            path = os.path.join(gameindex.TYPES_DIR, *name.split("/"))
            if not os.path.isfile(path):
                changed.append(name + " is not there")
                continue
            with open(path, encoding="utf-8", newline="") as file:
                if file.read() != text:
                    changed.append(name + " differs")
        self.assertEqual(changed[:5], [], "%d of %d files of wax\\types\\icarus are not what the index gives. Run: "
                         "python scripts\\gameindex.py types" % (len(changed), len(self.files)))
        kept = {os.path.normcase(os.path.join(gameindex.TYPES_DIR, *name.split("/"))) for name in self.files}
        extra = []
        for folder, _folders, names in os.walk(gameindex.TYPES_DIR):
            for name in names:
                path = os.path.join(folder, name)
                with open(path, encoding="utf-8", errors="replace") as file:
                    if os.path.normcase(path) not in kept and gameindex.GENERATED_BY in file.read(400):
                        extra.append(path)
        self.assertEqual(extra, [], "generated files of an earlier run are still there")

    def test_the_library_list_on_disk_is_the_one_the_index_gives(self):
        with open(gameindex.LIBRARY_LIST, encoding="utf-8", newline="") as file:
            self.assertEqual(file.read(), gameindex.libraries_text(self.summary["libraries"]),
                             "wax\\runtime\\data\\libraries.lua is not what the index gives. Run: python scripts\\gameindex.py types")
        self.assertGreater(len(self.summary["libraries"]), 400)

    def test_the_index_is_made_from_the_model_of_the_installed_build(self):
        model = stored_model()
        if model is None:
            self.skipTest("no model of the installed build to compare with")
        # Get-GameSdk.ps1 brings the index the server made from the newest build, and notes which one beside it.
        try:
            with open(os.path.join(gameindex.INDEX_DIR, "sdk.json"), encoding="utf-8-sig") as file:
                if json.load(file).get("build_id") == self.index["source"].get("model"):
                    return
        except (OSError, ValueError):
            pass
        self.assertEqual(self.index["source"].get("model"), model[0], "the index was made from a dump, or from the model of "
                         "another build, while a model of the installed build is there. Run: python scripts\\gameindex.py build")

    def test_every_function_wax_refuses_carries_a_note(self):
        refused = gameindex.refused_calls()
        if not refused:
            self.skipTest("no list at %s" % gameindex.REFUSED_LIST)
        classes = written_classes(self.files)
        self.assertGreater(len(self.summary["refused_written"]), 900)
        bare = [(own, name) for own, name in self.summary["refused_written"]
                if "Do not call from Lua" not in classes[own][name] and not classes[own][name].endswith(gameindex.REFUSED_NOTE)]
        self.assertEqual(bare, [], "functions Wax's runtime refuses are written as plain callable ones")
        self.assertEqual(self.summary["do_not_call"] + self.summary["refused"],
                         sum(1 for members in classes.values() for text in members.values()
                             if "Do not call from Lua:" in text or text.endswith(gameindex.REFUSED_NOTE)))

    def test_no_name_differs_from_the_running_games_spelling_by_case_or_an_end_space(self):
        path = os.path.join(gameindex.INDEX_DIR, gameindex.DUMP_INDEX)
        if not os.path.isfile(path) or "dump" in self.index["source"]:
            self.skipTest("no index made from an object dump beside one made from the model")
        with open(path, encoding="utf-8") as file:
            dumped = json.load(file)
        game = gameindex.Game(gameindex.respelled(self.index, gameindex.dump_spelling(gameindex.INDEX)))
        names = gameindex.names_for(game, gameindex.WaxApi(gameindex.WAX_TYPES))
        mine = {found.lower(): name for found, name in names.of.items()}
        classes = written_classes(self.files)
        wrong, compared = [], 0
        for group, keys in (("classes", ("properties", "functions")), ("structs", ("fields",))):
            for record in dumped[group]:
                written = classes.get(mine.get(record["path"].lower()))
                if written is None:
                    continue
                folded = {name.strip().lower(): name for name in written}
                for key in keys:
                    for item in record[key]:
                        found = folded.get(item["name"].strip().lower())
                        if found is not None:
                            compared += 1
                            if found != item["name"]:
                                wrong.append("%s: %r is %r in the running game" % (record["path"], found, item["name"]))
        self.assertGreater(compared, 50000)
        self.assertEqual(wrong[:5], [], "%d names in wax\\types\\icarus are spelled otherwise than the running game spells them, "
                         "and Wax looks members up by the running game's spelling" % len(wrong))
        for one in ("UMG_InventoryItem_C", "UMG_MainMenu_C"):
            self.assertTrue(any(name.endswith(" ") for name in classes[one]), one + " has a member whose name ends in a space")

    def test_no_wax_name_stands_in_front_of_a_reflected_member_unseen(self):
        # The ruling: no Wax name replaces a reflected member of the game, beyond Name and Parent.
        self.assertEqual(self.summary["wax_clashes_open"], [], "a Wax name replaces a reflected member of the game. Rename it, "
                         "or put it on ACCEPTED_CLASHES in scripts\\gameindex.py with the owner's word")
        found = {(name, member, path) for _file, name, member, path, _theirs in self.summary["wax_clashes"]}
        self.assertEqual(sorted(gameindex.ACCEPTED_CLASHES - found), [], "accepted clashes that are no longer clashes: take them off the list")

    def test_what_types_would_ask_a_person_to_look_at(self):
        self.assertEqual(self.summary["same_named"], [], "blueprint classes share a name and PLAIN_NAMES does not say which keeps it")
        self.assertEqual(self.summary["entry_points_unread"], [])
        self.assertEqual(self.summary["entry_points_differ"], [])
        self.assertEqual(self.summary["also_extends_unwritten"], [], "a game class does not extend the Wax class that lists "
                         "what Wax gives it: see ALSO_EXTENDS in scripts\\gameindex.py")
        names = written_classes(self.files)
        self.assertIn("TempBrush", names["UMG_PlayerName_C"], "the HUD's name tag, not the space station prototype's")
        self.assertIn("UMG_Spawnblocker_C", names)
        self.assertNotIn("UMG_SpawnBlocker_C", names, "a spelling the running game never shows")


if __name__ == "__main__":
    unittest.main()
