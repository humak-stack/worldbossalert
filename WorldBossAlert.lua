-------------------------------------------------------------------------------
-- WorldBossAlert.lua  –  TurtleWoW / WoW 1.12 client
-- Channels:
--   Boss alerts                : lnhpmzlovjlpqkexbiypxlwbat
--   Scout clock-in / clock-out : awIwiMWE4Paf542U1RG2rX
--   Raid roster log            : nSp45JAOzc1O7pi1sSt7pk
--   Raid loot log              : tkVfVD7lNviV321778G5W8
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- 1. CONSTANTS & CHANNEL IDs
-------------------------------------------------------------------------------
local WBA_ALERT_CHANNEL  = "lnhpmzlovjlpqkexbiypxlwbat"
local WBA_SCOUT_CHANNEL  = "awIwiMWE4Paf542U1RG2rX"
local WBA_ROSTER_CHANNEL = "nSp45JAOzc1O7pi1sSt7pk"
local WBA_LOOT_CHANNEL   = "tkVfVD7lNviV321778G5W8"

-------------------------------------------------------------------------------
-- 2. BOSS DEFINITIONS
--    Each entry:  [bossName] = { zones = {}, group = "GroupLabel", quite = bool, mention = "@tag" }
--    zones   – expected zone names (alert fires regardless, flagged if wrong zone)
--    group   – logical group label used for clock-in & alerts
--    quite   – if true use the quieter notify path (guild only, no mention)
--    mention – @tag appended to alert messages
-------------------------------------------------------------------------------
local WBA_BOSSES = {
    -- World Dragons (all share one logical group)
    ["Ysondre"] = {
        zones   = {"Duskwood"},
        group   = "Emerald Dragon",
        quite   = false,
        mention = "@4-Dragons",
    },
    ["Lethon"] = {
        zones   = {"Hinterlands"},
        group   = "Emerald Dragon",
        quite   = false,
        mention = "@4-Dragons",
    },
    ["Emeriss"] = {
        zones   = {"Feralas"},
        group   = "Emerald Dragon",
        quite   = false,
        mention = "@4-Dragons",
    },
    ["Taerar"] = {
        zones   = {"Ashenvale"},
        group   = "Emerald Dragon",
        quite   = false,
        mention = "@4-Dragons",
    },
    -- Open-world elites
    ["Azuregos"] = {
        zones      = {"Azshara"},
        group      = "Azuregos",
        quite      = false,
        mention    = "@Azuregos",
        checkTapped = true,
    },
    ["Lord Kazzak"] = {
        zones   = {"Blasted Lands"},
        group   = "Lord Kazzak",
        quite   = false,
        mention = "@Kazzak",
    },
    ["Dark Reaver of Karazhan"] = {
        zones   = {"Deadwind Pass"},
        group   = "Dark Reaver of Karazhan",
        quite   = false,
        mention = "@Reaver",
    },
    ["Concavious"] = {
        zones   = {"Shadowbreak Ravine"},
        group   = "Concavious",
        quite   = false,
        mention = "@Concavious",
    },
    -- Quiet / secondary targets (guild only, no mention)
    ["Admiral Barean Westwind"] = {
        zones  = {"Eastern Plaguelands"},
        group  = "Admiral Barean Westwind",
        quite  = true,
    },
    ["Narillasanz"] = {
        zones  = {"Burning Steppes"},
        group  = "Narillasanz",
        quite  = true,
    },
    ["Tarangos"] = {
        zones  = {"Feralas"},
        group  = "Tarangos",
        quite  = true,
    },
    ["Prince Nazjak"] = {
        zones  = {"Arathi Highlands"},
        group  = "Prince Nazjak",
        quite  = true,
    },
    -- Test mob
    ["Moo"] = {
        zones   = {"Moomoo Grove"},
        group   = "Moo",
        quite   = false,
        mention = "@Moo",
    },
}

-- Build a flat Set for quick lookup
local WBA_TARGET_SET = {}
for name in pairs(WBA_BOSSES) do
    WBA_TARGET_SET[name] = true
end

-------------------------------------------------------------------------------
-- ZG BOSS SET
-- Treated like world bosses for kill/loot logging when ZG mode is on.
-- No alerts are sent for these — kills and loot only.
-------------------------------------------------------------------------------
local WBA_ZG_BOSSES = {
    ["High Priest Venoxis"]    = true,
    ["High Priestess Jeklik"]  = true,
    ["High Priest Thekal"]     = true,
    ["High Priestess Arlokk"]  = true,
    ["High Priestess Mar'li"]  = true,
    ["Bloodlord Mandokir"]     = true,
    ["Gahz'ranka"]             = true,
    ["Edge of Madness"]        = true,
    ["Zanza the Restless"]     = true,
    ["Jin'do the Hexxer"]      = true,
    ["Hakkar"]                 = true,
}

-------------------------------------------------------------------------------
-- 3. RUNTIME STATE
-------------------------------------------------------------------------------
local wbaFrame       = CreateFrame("Frame")
local wbaScouting    = false       -- scout mode on/off
local wbaRaidMode    = false       -- raid mode on/off
local wbaZGMode      = false       -- ZG mode — log kills/loot for ZG bosses, no alerts
local wbaScoutBoss   = nil         -- boss name the scout clocked in for (nil = all)

-- scan timer
local wbaScanInterval = 30
local wbaScanTimer    = 0

-- heartbeat timer — "still watching" message every 30 minutes while scouting
local wbaHeartbeatInterval = 1800   -- 30 minutes in seconds
local wbaHeartbeatTimer    = 0

-- pending login clock-in — fires 30s after PLAYER_ENTERING_WORLD
local wbaLoginPending = false
local wbaLoginTimer   = 0
local wbaLoginDelay   = 30

-- per-boss alert cooldown (seconds)
local wbaScanCooldown = 900
local wbaScanLast     = {}

-- combat / death flags
local wbaBroadcasted  = false
local wbaPvp          = false
local wbaDeath        = false

-- raid mode kill tracking
local wbaLastKilledBoss = nil
local wbaLootWindowOpen = false  -- true after a kill, gates loot logging until next session

-- scout main name (optional display alias for alts)
local wbaMainName = nil

-- debug mode
local wbaDebugMode = false
local wbaDebugBoss = nil   -- fake boss name used for kill/loot testing in debug mode

-------------------------------------------------------------------------------
-- 4. UTILITY
-------------------------------------------------------------------------------
local function wbaPrint(msg)
    if msg then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[WBA]|r " .. msg, 255, 215, 0)
    end
end

local function wbaFlag(flag)
    if flag then return "|cFF00FF00ON|r" else return "|cFFFF4444OFF|r" end
end

local function wbaZone()
    local zone = GetZoneText() or ""
    local sub  = (GetSubZoneText and GetSubZoneText()) or ""
    if sub ~= "" and sub ~= zone then
        return zone .. " - " .. sub
    end
    return zone
end

-- Returns the display name for clock-in/out messages.
-- Always lowercased — main name if set, otherwise character name.
local function wbaScoutIdent()
    if wbaMainName and wbaMainName ~= "" then
        return string.lower(wbaMainName)
    end
    return string.lower(UnitName("player") or "unknown")
end

-- Check whether current zone matches a boss's expected zones.
-- Returns true (correct), false (wrong zone), or true (no zones defined = no check).
local function wbaZoneOk(bossName)
    local def = WBA_BOSSES[bossName]
    if not def or not def.zones or table.getn(def.zones) == 0 then return true end
    local current = GetZoneText() or ""
    for _, z in ipairs(def.zones) do
        if z == current then return true end
    end
    return false
end

-- Send to a custom channel by name.
-- force=true bypasses debug intercept (used for kill/loot logs which should always go out).
-- In debug mode without force, prints locally only.
local function wbaSendChannel(channelName, msg, force)
    if wbaDebugMode and not force then
        wbaPrint("|cFFFF8800[DEBUG]|r [" .. channelName .. "]: " .. msg)
        return true
    end
    local index = GetChannelName(channelName)
    if not index or index == 0 then
        wbaPrint("|cFFFF4444[WBA]|r Not in channel [" .. channelName .. "] -- message not sent.")
        return false
    end
    SendChatMessage(msg, "CHANNEL", nil, index)
    return true
end

-- Check channel access without sending (used as a gate before alerting)
local function wbaChannelReady(channelName)
    if wbaDebugMode then return true end
    local index = GetChannelName(channelName)
    return index and index > 0
end

-- Returns true if the player is level 1-4 and cannot use custom channels
local function wbaIsLowLevel()
    local level = UnitLevel("player") or 0
    return level > 0 and level < 5
end

-- Routes a scout channel message (clock-in, clock-out, heartbeat).
-- Low level (1-4): all scout messages -> GUILD
-- Normal: -> WBA_SCOUT_CHANNEL
local function wbaSendScout(msg)
    if wbaDebugMode then
        local dest = wbaIsLowLevel() and "GUILD(low)" or WBA_SCOUT_CHANNEL
        wbaPrint("|cFFFF8800[DEBUG]|r [" .. dest .. "]: " .. msg)
        return
    end
    if wbaIsLowLevel() then
        SendChatMessage(msg, "GUILD")
    else
        local index = GetChannelName(WBA_SCOUT_CHANNEL)
        if not index or index == 0 then
            wbaPrint("|cFFFF4444[WBA]|r Scout channel not joined -- message not sent.")
            return
        end
        SendChatMessage(msg, "CHANNEL", nil, index)
    end
end

-- Join any WBA channels that aren't already joined.
local function wbaEnsureChannels(scoutOnly)
    local channels = {}
    if scoutOnly then
        channels = {
            {name = WBA_ALERT_CHANNEL,  label = "Alert"},
            {name = WBA_SCOUT_CHANNEL,  label = "Scout"},
        }
    else
        channels = {
            {name = WBA_ALERT_CHANNEL,  label = "Alert"},
            {name = WBA_SCOUT_CHANNEL,  label = "Scout"},
            {name = WBA_ROSTER_CHANNEL, label = "Raid Roster"},
            {name = WBA_LOOT_CHANNEL,   label = "Raid Loot"},
        }
    end
    for _, ch in ipairs(channels) do
        local idx = GetChannelName(ch.name)
        if not idx or idx == 0 then
            JoinChannelByName(ch.name)
            wbaPrint("Joined channel: " .. ch.label)
        end
    end
end

-- Leave a set of channels (used when switching modes).
local function wbaLeaveChannels(channelList)
    for _, ch in ipairs(channelList) do
        local idx = GetChannelName(ch.name)
        if idx and idx > 0 then
            LeaveChannelByName(ch.name)
            wbaPrint("Left channel: " .. ch.label)
        end
    end
end

local WBA_RAID_CHANNELS = {
    {name = WBA_ROSTER_CHANNEL, label = "Raid Roster"},
    {name = WBA_LOOT_CHANNEL,   label = "Raid Loot"},
}
local WBA_SCOUT_CHANNELS = {
    {name = WBA_ALERT_CHANNEL,  label = "Alert"},
    {name = WBA_SCOUT_CHANNEL,  label = "Scout"},
}

-------------------------------------------------------------------------------
-- 5. NOTIFY FUNCTIONS
-------------------------------------------------------------------------------
-- Full alert (1x to alert channel, gated on channel access)
-- Low level scouts (1-4) send to OFFICER instead
local function wbaNotify(msg, mention)
    if not msg then return end
    local where   = wbaZone()
    local tag     = mention and (" " .. mention .. " @WorldBossEnjoyer") or " @WorldBossEnjoyer"
    local fullMsg = string.format("%s [%s]%s", msg, where, tag)
    if wbaDebugMode then
        wbaPrint("|cFFFF8800[DEBUG]|r [ALERT]: " .. fullMsg)
        return
    end
    if wbaIsLowLevel() then
        SendChatMessage(fullMsg, "OFFICER")
    else
        if not wbaChannelReady(WBA_ALERT_CHANNEL) then
            wbaPrint("|cFFFF4444[WBA]|r Alert channel not ready -- run /wba scout to rejoin.")
            return
        end
        wbaSendChannel(WBA_ALERT_CHANNEL, fullMsg)
    end
end

-- Quiet alert (1x, to guild only)
local function wbaNotifyQuite(msg)
    if not msg then return end
    local where   = wbaZone()
    local fullMsg = string.format("%s [%s]", msg, where)
    if wbaDebugMode then
        wbaPrint("|cFFFF8800[DEBUG]|r [GUILD]: " .. fullMsg)
    else
        SendChatMessage(fullMsg, "GUILD")
    end
end

-- Route to the right notify based on boss definition
local function wbaAlert(bossName, extraNote)
    local def    = WBA_BOSSES[bossName]
    local where  = wbaZone()

    -- Hard zone gate: if the boss has expected zones and we're not in one, abort and warn locally only
    if not wbaZoneOk(bossName) then
        local expected = (def and def.zones and table.getn(def.zones) > 0)
            and table.concat(def.zones, "/")
            or "unknown"
        wbaPrint(string.format(
            "|cFFFF4444Zone mismatch:|r %s expected in [%s] but you are in [%s]. No alert sent.",
            bossName, expected, where))
        return
    end

    local text = string.format("%s IS UP!!!", string.upper(bossName))
    if extraNote then
        text = text .. " " .. extraNote
    end

    local mention = def and def.mention or nil

    if def and def.quite then
        wbaNotifyQuite(text)
    else
        wbaNotify(text, mention)
    end
end

-------------------------------------------------------------------------------
-- 6. CLOCK-IN  (sent when scout enables scouting for a specific boss/group)
-------------------------------------------------------------------------------
-- 6. CLOCK-IN / CLOCK-OUT
-------------------------------------------------------------------------------
local function wbaClockIn(bossName)
    local def   = WBA_BOSSES[bossName]
    local group = def and def.group or bossName
    local where = wbaZone()

    -- Warn locally if parked in the wrong zone, but still send clock-in
    if not wbaZoneOk(bossName) then
        local expected = (def and def.zones and table.getn(def.zones) > 0)
            and table.concat(def.zones, "/") or "unknown"
        wbaPrint(string.format(
            "|cFFFF8800Zone warning:|r %s is expected in [%s] but you are in [%s].",
            group, expected, where))
    end

    local msg = string.format("Main: %s is now watching %s [%s]", wbaScoutIdent(), group, where)
    if wbaIsLowLevel() then
        wbaPrint("|cFFFF8800[Low level]|r Sending clock-in to OFFICER.")
    end
    wbaSendScout(msg)
    wbaPrint("Clocked in for: " .. group)
    wbaHeartbeatTimer = 0
end

local function wbaClockOut(group)
    local where = wbaZone()
    local msg   = string.format("Main: %s has stopped watching %s [%s]", wbaScoutIdent(), group or "All", where)
    wbaSendScout(msg)
    wbaPrint("Clocked out from: " .. (group or "All"))
end

-- Sends a "still watching" heartbeat to the scout channel every 30 minutes
-- Low level scouts send to GUILD instead
local function wbaHeartbeat()
    local where = wbaZone()
    local group = "All"
    if wbaScoutBoss then
        local def = WBA_BOSSES[wbaScoutBoss]
        group = def and def.group or wbaScoutBoss
    end
    local msg = string.format("Main: %s is still watching %s [%s]", wbaScoutIdent(), group, where)
    wbaSendScout(msg)
end

-------------------------------------------------------------------------------
-- 7. SCOUT SCANNING
-------------------------------------------------------------------------------
local function wbaScanAround()
    if UnitIsDead("player") or UnitAffectingCombat("player") then return end

    local oldTarget = UnitName("target")

    -- Determine which group we're scanning for (nil = all)
    local scoutGroup = nil
    if wbaScoutBoss then
        local def = WBA_BOSSES[wbaScoutBoss]
        scoutGroup = def and def.group or nil
    end

    for bossName in pairs(WBA_TARGET_SET) do
        local def = WBA_BOSSES[bossName]
        -- Include this boss if: no filter, OR boss belongs to the selected group
        local include = (not scoutGroup) or (def and def.group == scoutGroup)
        if include then
            TargetByName(bossName)
            if UnitName("target") == bossName then
                if UnitIsDead("target") or UnitIsCorpse("target") then
                    wbaPrint(bossName .. " found but is DEAD.")
                elseif UnitIsPlayer("target") or UnitPlayerControlled("target") then
                    wbaPrint(bossName .. " target is a player/pet, skipping.")
                else
                    -- For bosses with checkTapped, skip alert if already tagged by others
                    if def and def.checkTapped then
                        local tapped   = UnitIsTapped and UnitIsTapped("target")
                        local tappedMe = UnitIsTappedByPlayer and UnitIsTappedByPlayer("target")
                        if tapped and not tappedMe then
                            wbaPrint(bossName .. " is already tagged by another player -- no alert sent.")
                            break
                        end
                    end
                    local now = GetTime()
                    if not wbaScanLast[bossName] or (now - wbaScanLast[bossName]) > wbaScanCooldown then
                        wbaScanLast[bossName] = now
                        wbaAlert(bossName)
                    end
                end
                -- Only stop early when scanning all bosses (no group filter).
                -- When a specific group is selected, always scan all members.
                if not scoutGroup then
                    break
                end
            end
        end
    end

    if oldTarget then
        TargetByName(oldTarget)
    else
        ClearTarget()
    end
end

-------------------------------------------------------------------------------
-- 8. RAID MODE  –  ROSTER & LOOT LOGGING
-------------------------------------------------------------------------------

-- Build a comma-delimited list of online raid or party members
local function wbaGetRaidRoster()
    local members = {}
    local n = GetNumRaidMembers()
    if n > 0 then
        -- Raid group
        for i = 1, n do
            local name, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
            if name and online then
                members[table.getn(members) + 1] = name
            end
        end
    else
        -- Party group fallback (covers dungeon groups)
        local p = GetNumPartyMembers()
        -- Always include self
        members[table.getn(members) + 1] = UnitName("player") or "Unknown"
        for i = 1, p do
            local name = UnitName("party" .. i)
            if name then
                members[table.getn(members) + 1] = name
            end
        end
    end
    if table.getn(members) == 0 then
        return UnitName("player") or "Unknown"
    end
    return table.concat(members, ", ")
end

-- Called when we detect a world boss kill
local function wbaLogKill(bossName)
    if not wbaRaidMode and not wbaDebugMode and not wbaZGMode then return end
    local name   = (wbaDebugMode and wbaDebugBoss) or bossName
    local player = UnitName("player") or "Unknown"
    wbaLastKilledBoss = name
    wbaLootWindowOpen = true

    -- Build roster member list
    local members = {}
    local n = GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            local mName, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
            if mName and online then
                members[table.getn(members) + 1] = mName
            end
        end
    else
        members[1] = UnitName("player") or "Unknown"
        local p = GetNumPartyMembers()
        for i = 1, p do
            local mName = UnitName("party" .. i)
            if mName then members[table.getn(members) + 1] = mName end
        end
    end

    -- Prefix and suffix for each message chunk
    -- Part 1:  [WBA Kill] BossName :: Raid: Name1, Name2 ...
    -- Part 2+: [WBA Kill] BossName :: Raid (cont): Name3 ...
    -- Final chunk always ends with :: Reporter: PlayerName
    local prefix      = string.format("[WBA Kill] %s :: Raid: ", name)
    local prefixCont  = string.format("[WBA Kill] %s :: Raid (cont): ", name)
    local suffix      = string.format(" :: Reporter: %s", player)
    local limit       = 255

    local chunks  = {}
    local current = prefix
    local isFirst = true

    for i = 1, table.getn(members) do
        local entry = members[i]
        if i < table.getn(members) then entry = entry .. ", " end

        -- Check if adding this entry plus the suffix would exceed limit
        local testLine = current .. entry .. suffix
        if string.len(testLine) > limit and not isFirst then
            -- Flush current chunk without suffix, start new one
            chunks[table.getn(chunks) + 1] = current
            current = prefixCont .. entry
        else
            current = current .. entry
        end
        isFirst = false
    end

    -- Final chunk always gets the reporter suffix
    chunks[table.getn(chunks) + 1] = current .. suffix

    -- Send all chunks
    for i = 1, table.getn(chunks) do
        wbaSendChannel(WBA_ROSTER_CHANNEL, chunks[i], true)
    end

    local numChunks = table.getn(chunks)
    wbaPrint("Kill logged for: " .. name .. " (" .. numChunks .. " msg" .. (numChunks > 1 and "s" or "") .. ") -- loot window open")
end

-- Test kill log -- bypasses raid mode and boss validation, uses debug boss name or TEST
local function wbaLogKillTest()
    -- Temporarily set raidMode so wbaLogKill doesn't bail
    local prevRaid = wbaRaidMode
    local prevDebug = wbaDebugMode
    wbaRaidMode  = true
    wbaDebugMode = true
    wbaLogKill(wbaDebugBoss or "TEST")
    wbaRaidMode  = prevRaid
    wbaDebugMode = prevDebug
    wbaPrint("TEST kill log sent. Boss: " .. (wbaDebugBoss or "TEST"))
end

-- Called when we detect a world boss loot event
local function wbaLogLoot(looter, itemName)
    if not wbaRaidMode and not wbaDebugMode then return end
    if not wbaLootWindowOpen then
        if wbaDebugMode then
            wbaPrint("|cFFFF8800[DEBUG loot]|r Loot window not open -- kill a boss first.")
        end
        return
    end
    local boss = wbaLastKilledBoss or "Unknown Boss"
    local msg  = string.format("[WBA Loot] %s looted [%s] from %s", looter, itemName, boss)
    wbaSendChannel(WBA_LOOT_CHANNEL, msg, true)
    wbaPrint("Loot logged: " .. looter .. " - " .. itemName)
end

-------------------------------------------------------------------------------
-- 9. COMBAT EVENT HANDLER  (existing hit/miss detection kept intact)
-------------------------------------------------------------------------------
local function wbaCheck(attacker, evtType)
    if not attacker then return end
    if WBA_TARGET_SET[attacker] and not string.find(evtType, "HOSTILEPLAYER") then
        -- Only fire from combat events if scouting is on
        if wbaScouting then
            local now = GetTime()
            if not wbaScanLast[attacker] or (now - wbaScanLast[attacker]) > wbaScanCooldown then
                wbaScanLast[attacker] = now
                wbaAlert(attacker)
            end
        end
    elseif wbaPvp and string.find(evtType, "HOSTILEPLAYER") then
        local px, py = GetPlayerMapPosition("player")
        wbaSendChannel(WBA_SCOUT_CHANNEL,
            string.format("PvP attack by %s. [%s @ %.1f, %.1f]",
                attacker, GetZoneText(), px*100, py*100))
    end
end

-------------------------------------------------------------------------------
-- 10. MAIN EVENT HANDLER
-------------------------------------------------------------------------------
local function wbaOnEvent()
    -----------------------------------------------------------------------
    -- ADDON LOADED
    -----------------------------------------------------------------------
    if event == "ADDON_LOADED" and arg1 == "WorldBossAlert" then
        if not WorldBossAlertDB then
            WorldBossAlertDB = {
                scouting  = false,
                raidMode  = false,
                scoutBoss = nil,
                pvp       = false,
                death     = false,
                mainName  = nil,
                debugMode = false,
                zgMode    = false,
            }
        end

        -- Migrate old keys if upgrading from previous version
        if WorldBossAlertDB.wbScouting ~= nil and WorldBossAlertDB.scouting == nil then
            WorldBossAlertDB.scouting = WorldBossAlertDB.wbScouting
        end

        wbaScouting  = WorldBossAlertDB.scouting  or false
        wbaRaidMode  = WorldBossAlertDB.raidMode  or false
        wbaScoutBoss = WorldBossAlertDB.scoutBoss or nil
        wbaPvp       = WorldBossAlertDB.pvp       or false
        wbaDeath     = WorldBossAlertDB.death      or false
        wbaMainName  = WorldBossAlertDB.mainName  or nil
        wbaDebugMode = WorldBossAlertDB.debugMode or false
        wbaZGMode    = WorldBossAlertDB.zgMode    or false

        -- Register events based on saved state
        if wbaPvp then
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS")
            wbaFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
        end
        if wbaDeath then
            wbaFrame:RegisterEvent("PLAYER_DEAD")
        end
        if wbaRaidMode or wbaDebugMode or wbaZGMode then
            wbaFrame:RegisterEvent("CHAT_MSG_LOOT")
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
        end
        if wbaScouting then
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
            wbaHeartbeatTimer = 0
            wbaScanTimer      = 0
            -- Auto clock-in is deferred to PLAYER_ENTERING_WORLD so wbaZone() is valid
        end

        local level = UnitLevel("player") or 0
        local levelNote = ""
        if level > 0 and level < 5 then
            levelNote = " |cFFFF8800[Low level: alerts->OFFICER, scout msgs->GUILD]|r"
        end
        local statusMsg = "Scout: " .. wbaFlag(wbaScouting) .. "  Raid: " .. wbaFlag(wbaRaidMode)
        if wbaZGMode    then statusMsg = statusMsg .. "  ZG: " .. wbaFlag(wbaZGMode) end
        if wbaDebugMode then statusMsg = statusMsg .. "  Debug: " .. wbaFlag(wbaDebugMode) end
        statusMsg = statusMsg .. levelNote
        wbaPrint(statusMsg)
        if wbaScoutBoss then
            wbaPrint("Watching: " .. wbaScoutBoss)
        end
        if wbaMainName then
            wbaPrint("Main set to: " .. wbaMainName)
        end

    -----------------------------------------------------------------------
    -- PLAYER LOGOUT  –  save state only
    -----------------------------------------------------------------------
    elseif event == "PLAYER_LOGOUT" then
        WorldBossAlertDB.scouting  = wbaScouting
        WorldBossAlertDB.raidMode  = wbaRaidMode
        WorldBossAlertDB.scoutBoss = wbaScoutBoss
        WorldBossAlertDB.pvp       = wbaPvp
        WorldBossAlertDB.death     = wbaDeath
        WorldBossAlertDB.mainName  = wbaMainName
        WorldBossAlertDB.debugMode = wbaDebugMode
        WorldBossAlertDB.zgMode    = wbaZGMode

    -----------------------------------------------------------------------
    -- PLAYER ENTERING WORLD  –  start 30s login clock-in timer
    -----------------------------------------------------------------------
    elseif event == "PLAYER_ENTERING_WORLD" then
        if wbaScouting then
            wbaLoginPending = true
            wbaLoginTimer   = 0
        end

    -----------------------------------------------------------------------
    -- COMBAT EVENTS  –  creature hits/misses
    -----------------------------------------------------------------------
    elseif event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS"
        or event == "CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS"
        or event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES" then

        if wbaBroadcasted then return end
        local attacker = string.match(arg1, "(.+) hits you")
                      or string.match(arg1, "(.+) misses you")
                      or string.match(arg1, "(.+) attacks%. You dodge%.")
        wbaCheck(attacker, event)
        wbaBroadcasted = true

    elseif event == "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE" then
        if wbaBroadcasted then return end
        local attacker = string.match(arg1, "(.+)'s")
        if attacker then
            wbaCheck(attacker, event)
            wbaBroadcasted = true
        end

    -----------------------------------------------------------------------
    -- PLAYER DEAD
    -----------------------------------------------------------------------
    elseif event == "PLAYER_DEAD" then
        if wbaDeath then
            local px, py = GetPlayerMapPosition("player")
            wbaSendChannel(WBA_SCOUT_CHANNEL,
                string.format("Scout %s has died. [%s @ %.1f, %.1f]",
                    wbaScoutIdent(), GetZoneText(), px*100, py*100))
        end

    -----------------------------------------------------------------------
    -- COMBAT ENDS  –  reset broadcast flag
    -----------------------------------------------------------------------
    elseif event == "PLAYER_REGEN_ENABLED" then
        wbaBroadcasted = false

    -----------------------------------------------------------------------
    -- LOOT EVENT  –  raid loot logging
    -----------------------------------------------------------------------
    elseif event == "CHAT_MSG_LOOT" then
        -- In debug mode always process loot so we can test patterns
        -- In normal mode only process if raid mode is on
        if not wbaRaidMode and not wbaDebugMode then return end
        if wbaDebugMode then
            wbaPrint("|cFFFF8800[DEBUG loot raw]|r " .. (arg1 or "nil"))
        end
        local looter, item

        -- WoW loot messages contain full item hyperlinks:
        -- "You receive loot: |cFFxxxxxx|Hitem:...|h[ItemName]|h|r."
        -- We match the item name from inside |h[ItemName]|h
        if string.find(arg1, "You receive loot:") then
            item   = string.match(arg1, "|h%[(.-)%]|h")
            looter = UnitName("player")
        else
            -- "PlayerName receives loot: |cFF...|h[ItemName]|h|r."
            looter = string.match(arg1, "(.+) receives loot:")
            item   = string.match(arg1, "|h%[(.-)%]|h")
        end

        if wbaDebugMode then
            wbaPrint("|cFFFF8800[DEBUG loot match]|r looter=" .. tostring(looter) .. " item=" .. tostring(item))
        end

        -- Quality threshold — only log epic (purple) or higher in production
        -- Color codes: epic = a335ee, legendary = ff8000, artifact = e6cc80
        -- In debug mode skip this check and log everything
        if not wbaDebugMode then
            local epicOrAbove = string.find(arg1, "a335ee")   -- epic
                             or string.find(arg1, "ff8000")   -- legendary
                             or string.find(arg1, "e6cc80")   -- artifact
            if not epicOrAbove then
                return
            end
        end

        local bossReady = wbaLastKilledBoss or (wbaDebugMode and wbaDebugBoss)
        if looter and item and bossReady then
            wbaLogLoot(looter, item)
        elseif wbaDebugMode then
            wbaPrint("|cFFFF8800[DEBUG loot fail]|r bossReady=" .. tostring(bossReady))
        end

    -----------------------------------------------------------------------
    -- UNIT DIED  –  detect boss kill for raid logging
    -----------------------------------------------------------------------
    elseif event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        if wbaDebugMode then
            wbaPrint("|cFFFF8800[DEBUG death]|r " .. (arg1 or "nil") .. " raidMode=" .. tostring(wbaRaidMode) .. " debugMode=" .. tostring(wbaDebugMode))
        end
        if not wbaRaidMode and not wbaDebugMode then return end
        local bossName = string.match(arg1, "(.+) dies%.")
                      or string.match(arg1, "You have slain (.+)!")
        if bossName then
            local isMatch = (wbaDebugMode and wbaDebugBoss and bossName == wbaDebugBoss)
                         or (not wbaDebugMode and WBA_TARGET_SET[bossName])
                         or (wbaZGMode and WBA_ZG_BOSSES[bossName])
            if wbaDebugMode then
                wbaPrint("|cFFFF8800[DEBUG death check]|r bossName=" .. tostring(bossName) .. " debugBoss=" .. tostring(wbaDebugBoss) .. " isMatch=" .. tostring(isMatch) .. " windowOpen=" .. tostring(wbaLootWindowOpen))
            end
            if isMatch then
                if wbaLastKilledBoss ~= bossName then
                    wbaLootWindowOpen = false
                end
                if not wbaLootWindowOpen then
                    wbaLogKill(bossName)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- 11. ON UPDATE  –  periodic scan + heartbeat
-------------------------------------------------------------------------------
local function wbaOnUpdate()
    local elapsed = arg1 or 0

    -- Login clock-in timer — runs independently of scouting state
    if wbaLoginPending then
        wbaLoginTimer = wbaLoginTimer + elapsed
        if wbaLoginTimer >= wbaLoginDelay then
            wbaLoginPending = false
            wbaLoginTimer   = 0
            wbaEnsureChannels(true)
            if wbaScoutBoss then
                wbaClockIn(wbaScoutBoss)
            else
                local where = wbaZone()
                wbaSendChannel(WBA_SCOUT_CHANNEL,
                    string.format("Main: %s is now watching ALL bosses [%s]", wbaScoutIdent(), where))
            end
        end
    end

    if not wbaScouting then return end

    -- Boss scan every 30 seconds
    wbaScanTimer = wbaScanTimer + elapsed
    if wbaScanTimer >= wbaScanInterval then
        wbaScanTimer = 0
        wbaScanAround()
    end

    -- "Still watching" heartbeat every 30 minutes
    wbaHeartbeatTimer = wbaHeartbeatTimer + elapsed
    if wbaHeartbeatTimer >= wbaHeartbeatInterval then
        wbaHeartbeatTimer = 0
        wbaHeartbeat()
    end
end

-------------------------------------------------------------------------------
-- 12. MINIMAP BUTTON
-------------------------------------------------------------------------------
local wbaMinimapBtn = CreateFrame("Button", "WBAMinimapButton", Minimap)
wbaMinimapBtn:SetFrameStrata("MEDIUM")
wbaMinimapBtn:SetWidth(24)
wbaMinimapBtn:SetHeight(24)
wbaMinimapBtn:SetFrameLevel(8)
wbaMinimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local wbaMinimapIcon = wbaMinimapBtn:CreateTexture(nil, "BACKGROUND")
wbaMinimapIcon:SetTexture("Interface\\Icons\\Ability_Spy")   -- replace with your icon if desired
wbaMinimapIcon:SetWidth(20)
wbaMinimapIcon:SetHeight(20)
wbaMinimapIcon:SetPoint("CENTER", wbaMinimapBtn, "CENTER", 0, 0)

-- Position button around the minimap edge
local wbaMinimapAngle = 220  -- degrees
local function wbaUpdateMinimapPos()
    local rad = math.rad(wbaMinimapAngle)
    local x = 80 * math.cos(rad)
    local y = 80 * math.sin(rad)
    wbaMinimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end
wbaUpdateMinimapPos()

-- Allow dragging around the minimap
wbaMinimapBtn:EnableMouse(true)
wbaMinimapBtn:RegisterForDrag("LeftButton")
wbaMinimapBtn:SetScript("OnDragStart", function()
    this:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale  = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        wbaMinimapAngle = math.deg(math.atan2(cy - my, cx - mx))
        wbaUpdateMinimapPos()
    end)
end)
wbaMinimapBtn:SetScript("OnDragStop", function()
    this:SetScript("OnUpdate", nil)
end)

wbaMinimapBtn:SetScript("OnClick", function()
    if WBAPanel:IsShown() then
        WBAPanel:Hide()
    else
        WBAPanel:Show()
    end
end)

wbaMinimapBtn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:SetText("WorldBossAlert", 1, 1, 0)
    GameTooltip:AddLine("Click to toggle panel", 1, 1, 1)
    GameTooltip:Show()
end)
wbaMinimapBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-------------------------------------------------------------------------------
-- 13. MAIN GUI PANEL
-------------------------------------------------------------------------------
local WBAPanel = CreateFrame("Frame", "WBAPanel", UIParent)
WBAPanel:SetWidth(260)
WBAPanel:SetHeight(370)
WBAPanel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
WBAPanel:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
WBAPanel:SetBackdropColor(0, 0, 0, 0.85)
WBAPanel:EnableMouse(true)
WBAPanel:SetMovable(true)
WBAPanel:RegisterForDrag("LeftButton")
WBAPanel:SetScript("OnDragStart", function() this:StartMoving() end)
WBAPanel:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)
WBAPanel:Hide()

-- Title
local wbaTitleTex = WBAPanel:CreateTexture(nil, "ARTWORK")
wbaTitleTex:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
wbaTitleTex:SetWidth(256)
wbaTitleTex:SetHeight(64)
wbaTitleTex:SetPoint("TOP", WBAPanel, "TOP", 0, 12)

local wbaTitle = WBAPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
wbaTitle:SetPoint("TOP", WBAPanel, "TOP", 0, -5)
wbaTitle:SetText("WorldBossAlert")

-- Close button
local wbaCloseBtn = CreateFrame("Button", nil, WBAPanel, "UIPanelCloseButton")
wbaCloseBtn:SetPoint("TOPRIGHT", WBAPanel, "TOPRIGHT", -5, -5)

-- ── Section: SCOUT MODE ────────────────────────────────────────────────────
local wbaScoutLabel = WBAPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
wbaScoutLabel:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -45)
wbaScoutLabel:SetText("|cFFFFD700Scout Mode|r")

-- Scout toggle button
local wbaScoutBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaScoutBtn:SetWidth(100)
wbaScoutBtn:SetHeight(22)
wbaScoutBtn:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -68)

local function wbaRefreshScoutBtn()
    if wbaScouting then
        wbaScoutBtn:SetText("Scouting: ON")
    else
        wbaScoutBtn:SetText("Scouting: OFF")
    end
end

wbaScoutBtn:SetScript("OnClick", function()
    wbaScouting = not wbaScouting
    if wbaScouting then
        -- Leave raid channels, join scout channels
        wbaLeaveChannels(WBA_RAID_CHANNELS)
        wbaEnsureChannels(true)
        wbaHeartbeatTimer = 0
        wbaScanTimer      = 0
        wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
        wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
        -- Turn off raid mode if it was on
        if wbaRaidMode then
            wbaRaidMode = false
            wbaFrame:UnregisterEvent("CHAT_MSG_LOOT")
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
            wbaRefreshRaidBtn()
            wbaPrint("Raid mode disabled.")
        end
    else
        -- Clock out before clearing state
        if wbaScoutBoss then
            local def = WBA_BOSSES[wbaScoutBoss]
            wbaClockOut(def and def.group or wbaScoutBoss)
        else
            wbaClockOut("All")
        end
        wbaLeaveChannels(WBA_SCOUT_CHANNELS)
        wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
        wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
        wbaScoutBoss = nil
    end
    wbaRefreshScoutBtn()
    wbaPrint("Scouting " .. wbaFlag(wbaScouting))
end)

-- Boss selector label
local wbaBossSelLabel = WBAPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wbaBossSelLabel:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -96)
wbaBossSelLabel:SetText("Clock in for boss:")

-- Build a sorted, deduplicated list of boss groups for the dropdown
local wbaBossGroups = {}
local wbaSeenGroups = {}
for _, def in pairs(WBA_BOSSES) do
    if not def.quite and not wbaSeenGroups[def.group] then
        wbaSeenGroups[def.group] = true
        wbaBossGroups[table.getn(wbaBossGroups) + 1] = def.group
    end
end
table.sort(wbaBossGroups)

-- Simple scrollable button list (1.12 has no dropdown widget in vanilla Lua easily)
-- We create a small frame with buttons cycling through the list.
local wbaBossIndex = 1  -- index into wbaBossGroups

local wbaBossDisplay = WBAPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
wbaBossDisplay:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -113)
wbaBossDisplay:SetWidth(180)
wbaBossDisplay:SetJustifyH("LEFT")

local function wbaRefreshBossDisplay()
    local label = wbaBossGroups[wbaBossIndex] or "All Bosses"
    wbaBossDisplay:SetText("|cFF00CCFF" .. label .. "|r")
end

local wbaBossPrevBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaBossPrevBtn:SetWidth(24)
wbaBossPrevBtn:SetHeight(20)
wbaBossPrevBtn:SetText("<")
wbaBossPrevBtn:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -130)
wbaBossPrevBtn:SetScript("OnClick", function()
    wbaBossIndex = wbaBossIndex - 1
    if wbaBossIndex < 0 then wbaBossIndex = table.getn(wbaBossGroups) end
    wbaRefreshBossDisplay()
end)

local wbaBossNextBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaBossNextBtn:SetWidth(24)
wbaBossNextBtn:SetHeight(20)
wbaBossNextBtn:SetText(">")
wbaBossNextBtn:SetPoint("LEFT", wbaBossPrevBtn, "RIGHT", 4, 0)
wbaBossNextBtn:SetScript("OnClick", function()
    wbaBossIndex = wbaBossIndex + 1
    if wbaBossIndex > table.getn(wbaBossGroups) then wbaBossIndex = 0 end
    wbaRefreshBossDisplay()
end)

-- Clock-in button
local wbaClockInBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaClockInBtn:SetWidth(100)
wbaClockInBtn:SetHeight(22)
wbaClockInBtn:SetText("Clock In")
wbaClockInBtn:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -158)
wbaClockInBtn:SetScript("OnClick", function()
    -- Warn if no main name set
    if not wbaMainName or wbaMainName == "" then
        wbaPrint("|cFFFF8800Warning:|r No main name set. Use the main field or /wba main <name>.")
    end
    -- Auto-enable scouting if not already on
    if not wbaScouting then
        wbaScouting = true
        -- Mutual exclusion: disable raid mode and swap channels
        if wbaRaidMode then
            wbaRaidMode = false
            wbaFrame:UnregisterEvent("CHAT_MSG_LOOT")
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
            wbaLeaveChannels(WBA_RAID_CHANNELS)
            wbaPrint("Raid mode disabled.")
        end
        wbaEnsureChannels(true)
        wbaHeartbeatTimer = 0
        wbaScanTimer      = 0
        wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
        wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
        wbaRefreshScoutBtn()
        wbaPrint("Scouting enabled.")
    end
    -- Clock out from previous assignment if any
    if wbaScoutBoss then
        local prevDef = WBA_BOSSES[wbaScoutBoss]
        wbaClockOut(prevDef and prevDef.group or wbaScoutBoss)
    end
    local group = wbaBossGroups[wbaBossIndex]  -- nil = index 0 = "All"
    if group then
        for bossName, def in pairs(WBA_BOSSES) do
            if def.group == group then
                wbaScoutBoss = bossName
                wbaClockIn(bossName)
                break
            end
        end
    else
        wbaScoutBoss = nil
        local where = wbaZone()
        wbaSendChannel(WBA_SCOUT_CHANNEL,
            string.format("Main: %s is now watching ALL bosses [%s]", wbaScoutIdent(), where))
        wbaPrint("Clocked in for: All Bosses")
    end
end)

-- Clock-out button
local wbaClockOutBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaClockOutBtn:SetWidth(100)
wbaClockOutBtn:SetHeight(22)
wbaClockOutBtn:SetText("Clock Out")
wbaClockOutBtn:SetPoint("LEFT", wbaClockInBtn, "RIGHT", 6, 0)
wbaClockOutBtn:SetScript("OnClick", function()
    if not wbaScouting then
        wbaPrint("Not currently scouting.")
        return
    end
    if wbaScoutBoss then
        local def = WBA_BOSSES[wbaScoutBoss]
        wbaClockOut(def and def.group or wbaScoutBoss)
    else
        wbaClockOut("All")
    end
    wbaScoutBoss = nil
    wbaScouting  = false
    wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
    wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
    wbaRefreshScoutBtn()
end)

-- ── Section: RAID MODE ─────────────────────────────────────────────────────
local wbaRaidLabel = WBAPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
wbaRaidLabel:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -200)
wbaRaidLabel:SetText("|cFFFFD700Raid Mode|r")

local wbaRaidBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaRaidBtn:SetWidth(100)
wbaRaidBtn:SetHeight(22)
wbaRaidBtn:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -223)

local function wbaRefreshRaidBtn()
    if wbaRaidMode then
        wbaRaidBtn:SetText("Raid Mode: ON")
    else
        wbaRaidBtn:SetText("Raid Mode: OFF")
    end
end

wbaRaidBtn:SetScript("OnClick", function()
    wbaRaidMode = not wbaRaidMode
    if wbaRaidMode then
        -- Leave scout channels, join raid channels
        wbaLeaveChannels(WBA_SCOUT_CHANNELS)
        wbaEnsureChannels(false)
        wbaFrame:RegisterEvent("CHAT_MSG_LOOT")
        wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
        -- Turn off scouting if it was on
        if wbaScouting then
            if wbaScoutBoss then
                local def = WBA_BOSSES[wbaScoutBoss]
                wbaClockOut(def and def.group or wbaScoutBoss)
            else
                wbaClockOut("All")
            end
            wbaScouting = false
            wbaScoutBoss = nil
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
            wbaRefreshScoutBtn()
            wbaPrint("Scouting disabled.")
        end
        wbaPrint("Raid mode ON – logging kills & loot.")
    else
        wbaLeaveChannels(WBA_RAID_CHANNELS)
        if not wbaDebugMode and not wbaZGMode then
            wbaFrame:UnregisterEvent("CHAT_MSG_LOOT")
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
        end
        wbaPrint("Raid mode OFF.")
    end
    wbaRefreshRaidBtn()
end)

-- Manual kill trigger (in case auto-detection misses)
local wbaKillBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaKillBtn:SetWidth(120)
wbaKillBtn:SetHeight(22)
wbaKillBtn:SetText("Log Kill (Manual)")
wbaKillBtn:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -249)
wbaKillBtn:SetScript("OnClick", function()
    if not wbaRaidMode then
        wbaPrint("Enable Raid Mode first.")
        return
    end
    local target = UnitName("target")
    if target and WBA_TARGET_SET[target] then
        wbaLogKill(target)
    else
        wbaPrint("Target a world boss first.")
    end
end)


-- ── Main Name Input ────────────────────────────────────────────────────────
local wbaMainLabel = WBAPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wbaMainLabel:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -278)
wbaMainLabel:SetText("Your main (optional):")

local wbaMainInput = CreateFrame("EditBox", "WBAMainInput", WBAPanel, "InputBoxTemplate")
wbaMainInput:SetWidth(150)
wbaMainInput:SetHeight(20)
wbaMainInput:SetPoint("TOPLEFT", WBAPanel, "TOPLEFT", 20, -295)
wbaMainInput:SetAutoFocus(false)
wbaMainInput:SetMaxLetters(30)
wbaMainInput:SetScript("OnEnterPressed", function()
    local val = string.gsub(this:GetText() or "", "^%s*(.-)%s*$", "%1")  -- trim
    if val == "" then
        wbaMainName = nil
        wbaPrint("Main name cleared.")
    else
        wbaMainName = val
        wbaPrint("Main set to: " .. wbaMainName)
    end
    this:ClearFocus()
end)
wbaMainInput:SetScript("OnEscapePressed", function() this:ClearFocus() end)

local wbaMainClearBtn = CreateFrame("Button", nil, WBAPanel, "GameMenuButtonTemplate")
wbaMainClearBtn:SetWidth(50)
wbaMainClearBtn:SetHeight(20)
wbaMainClearBtn:SetText("Clear")
wbaMainClearBtn:SetPoint("LEFT", wbaMainInput, "RIGHT", 4, 0)
wbaMainClearBtn:SetScript("OnClick", function()
    wbaMainName = nil
    wbaMainInput:SetText("")
    wbaPrint("Main name cleared.")
end)

-- Status text at bottom
local wbaStatusText = WBAPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wbaStatusText:SetPoint("BOTTOMLEFT", WBAPanel, "BOTTOMLEFT", 20, 14)
wbaStatusText:SetWidth(220)
wbaStatusText:SetJustifyH("LEFT")

local function wbaRefreshStatus()
    local s = "Scout: " .. wbaFlag(wbaScouting)
    if wbaScoutBoss then
        local def = WBA_BOSSES[wbaScoutBoss]
        s = s .. "  |cFF00CCFF[" .. (def and def.group or wbaScoutBoss) .. "]|r"
    end
    s = s .. "   Raid: " .. wbaFlag(wbaRaidMode)
    if wbaMainName then
        s = s .. "\nMain: |cFF00CCFF" .. wbaMainName .. "|r"
    end
    wbaStatusText:SetText(s)
end

-- Hook all refresh calls into a single update
local wbaOrigScoutOnClick = wbaScoutBtn:GetScript("OnClick")
local wbaOrigRaidOnClick  = wbaRaidBtn:GetScript("OnClick")
local wbaOrigMainEnter    = wbaMainInput:GetScript("OnEnterPressed")
local wbaOrigMainClear    = wbaMainClearBtn:GetScript("OnClick")

wbaScoutBtn:SetScript("OnClick", function()
    wbaOrigScoutOnClick()
    wbaRefreshScoutBtn()
    wbaRefreshStatus()
end)
wbaRaidBtn:SetScript("OnClick", function()
    wbaOrigRaidOnClick()
    wbaRefreshRaidBtn()
    wbaRefreshStatus()
end)
-- ClockIn and ClockOut own their full logic directly so just append the status refresh
local wbaClockInBase  = wbaClockInBtn:GetScript("OnClick")
local wbaClockOutBase = wbaClockOutBtn:GetScript("OnClick")
wbaClockInBtn:SetScript("OnClick", function()
    wbaClockInBase()
    wbaRefreshRaidBtn()
    wbaRefreshStatus()
end)
wbaClockOutBtn:SetScript("OnClick", function()
    wbaClockOutBase()
    wbaRefreshStatus()
end)
wbaMainInput:SetScript("OnEnterPressed", function()
    wbaOrigMainEnter()
    wbaRefreshStatus()
end)
wbaMainClearBtn:SetScript("OnClick", function()
    wbaOrigMainClear()
    wbaMainInput:SetText("")
    wbaRefreshStatus()
end)

WBAPanel:SetScript("OnShow", function()
    wbaRefreshScoutBtn()
    wbaRefreshRaidBtn()
    wbaRefreshBossDisplay()
    wbaMainInput:SetText(wbaMainName or "")
    wbaRefreshStatus()
end)

-------------------------------------------------------------------------------
-- 14. SLASH COMMANDS  (slash commands remain as a power-user fallback)
-------------------------------------------------------------------------------
SLASH_WBALERT1 = "/wbalert"
SLASH_WBALERT2 = "/wba"

function SlashCmdList.WBALERT(msg)
    -- preserve original case for the main name, lowercase only for command matching
    local msgLower = string.lower(msg or "")

    if msgLower == "scout" then
        wbaScouting = not wbaScouting
        if wbaScouting then
            wbaLeaveChannels(WBA_RAID_CHANNELS)
            wbaEnsureChannels(true)
            wbaHeartbeatTimer = 0
            wbaScanTimer      = 0
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
            if wbaRaidMode then
                wbaRaidMode = false
                wbaFrame:UnregisterEvent("CHAT_MSG_LOOT")
                wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
                wbaPrint("Raid mode disabled.")
            end
        else
            if wbaScoutBoss then
                local def = WBA_BOSSES[wbaScoutBoss]
                wbaClockOut(def and def.group or wbaScoutBoss)
            else
                wbaClockOut("All")
            end
            wbaLeaveChannels(WBA_SCOUT_CHANNELS)
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
            wbaScoutBoss = nil
        end
        wbaPrint("Scouting " .. wbaFlag(wbaScouting))

    elseif string.sub(msgLower, 1, 5) == "main " then
        local name = string.gsub(string.sub(msg, 6), "^%s*(.-)%s*$", "%1")
        if name == "" then
            wbaMainName = nil
            wbaPrint("Main name cleared.")
        else
            wbaMainName = name
            wbaPrint("Main set to: " .. wbaMainName)
        end

    elseif msgLower == "main" then
        if wbaMainName then
            wbaPrint("Current main: " .. wbaMainName)
        else
            wbaPrint("No main set. Use: /wba main CharacterName")
        end

    elseif msgLower == "zg" then
        wbaZGMode = not wbaZGMode
        if wbaZGMode then
            wbaFrame:RegisterEvent("CHAT_MSG_LOOT")
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
        else
            if not wbaRaidMode and not wbaDebugMode then
                wbaFrame:UnregisterEvent("CHAT_MSG_LOOT")
                wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
            end
        end
        wbaPrint("ZG mode " .. wbaFlag(wbaZGMode))

    elseif msgLower == "raid" then
        wbaRaidMode = not wbaRaidMode
        if wbaRaidMode then
            wbaLeaveChannels(WBA_SCOUT_CHANNELS)
            wbaEnsureChannels(false)
            wbaFrame:RegisterEvent("CHAT_MSG_LOOT")
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
            if wbaScouting then
                if wbaScoutBoss then
                    local def = WBA_BOSSES[wbaScoutBoss]
                    wbaClockOut(def and def.group or wbaScoutBoss)
                else
                    wbaClockOut("All")
                end
                wbaScouting = false
                wbaScoutBoss = nil
                wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
                wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
                wbaPrint("Scouting disabled.")
            end
        else
            wbaLeaveChannels(WBA_RAID_CHANNELS)
            if not wbaDebugMode and not wbaZGMode then
                wbaFrame:UnregisterEvent("CHAT_MSG_LOOT")
                wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
            end
        end
        wbaPrint("Raid mode " .. wbaFlag(wbaRaidMode))

    elseif msgLower == "panel" then
        if WBAPanel:IsShown() then WBAPanel:Hide() else WBAPanel:Show() end

    elseif msgLower == "killtest" then
        wbaLogKillTest()

    elseif msgLower == "kill" then
        if not wbaRaidMode then wbaPrint("Raid mode is OFF.") return end
        local target = UnitName("target")
        if target and WBA_TARGET_SET[target] then
            wbaLogKill(target)
        else
            wbaPrint("Target a world boss first.")
        end

    elseif msgLower == "pvp" then
        wbaPvp = not wbaPvp
        if wbaPvp then
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS")
            wbaFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
        else
            wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS")
            wbaFrame:UnregisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
        end
        wbaPrint("PvP alerts " .. wbaFlag(wbaPvp))

    elseif msgLower == "death" then
        wbaDeath = not wbaDeath
        if wbaDeath then
            wbaFrame:RegisterEvent("PLAYER_DEAD")
        else
            wbaFrame:UnregisterEvent("PLAYER_DEAD")
        end
        wbaPrint("Death alerts " .. wbaFlag(wbaDeath))

    elseif msgLower == "debug" then
        wbaDebugMode = not wbaDebugMode
        wbaPrint("Debug mode " .. wbaFlag(wbaDebugMode))
        if wbaDebugMode then
            wbaFrame:RegisterEvent("CHAT_MSG_LOOT")
            wbaFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
            wbaPrint("Alerts print locally only. Set a boss: /wba debugboss MobName")
        else
            if not wbaRaidMode and not wbaZGMode then
                wbaFrame:UnregisterEvent("CHAT_MSG_LOOT")
                wbaFrame:UnregisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
            end
        end

    elseif string.sub(msgLower, 1, 10) == "debugboss " then
        local name = string.gsub(string.sub(msg, 11), "^%s*(.-)%s*$", "%1")
        if name == "" then
            wbaDebugBoss = nil
            wbaPrint("Debug boss cleared.")
        else
            wbaDebugBoss = name
            wbaPrint("Debug boss set to: " .. wbaDebugBoss)
        end

    elseif msgLower == "debugboss" then
        if wbaDebugBoss then
            wbaPrint("Debug boss: " .. wbaDebugBoss)
        else
            wbaPrint("No debug boss set. Use: /wba debugboss MobName")
        end

    elseif msgLower == "inspect" then
        local name = UnitName("target")
        if not name then
            wbaPrint("No target. Target a mob first.")
        else
            local class     = UnitClassification("target") or "nil"
            local level     = UnitLevel("target") or -1
            local creature  = UnitCreatureType("target") or "nil"
            local isElite   = (class == "elite" or class == "rareelite" or class == "worldboss")
            local isWB      = (class == "worldboss")
            local isSkull   = (level == -1)
            wbaPrint("Target: |cFF00CCFF" .. name .. "|r")
            wbaPrint("  Classification : " .. class)
            wbaPrint("  Creature type  : " .. creature)
            wbaPrint("  Level          : " .. (isSkull and "skull (-1)" or tostring(level)))
            wbaPrint("  Is worldboss   : " .. (isWB  and "|cFF00FF00yes|r" or "|cFFFF4444no|r"))
            wbaPrint("  Is elite+      : " .. (isElite and "|cFF00FF00yes|r" or "|cFFFF4444no|r"))
            wbaPrint("  In WBA targets : " .. (WBA_TARGET_SET[name] and "|cFF00FF00yes|r" or "|cFFFF4444no|r"))
        end

    else
        wbaPrint("WorldBossAlert -- /wba or /wbalert")
        wbaPrint("  scout          - toggle scout mode")
        wbaPrint("  main <n>       - set your main character name")
        wbaPrint("  main           - show current main name")
        wbaPrint("  raid           - toggle raid logging mode")
        wbaPrint("  zg             - toggle ZG mode (log ZG boss kills/loot, no alerts)")
        wbaPrint("  kill           - manually log kill (target boss first)")
        wbaPrint("  killtest       - send TEST kill log to verify channel")
        wbaPrint("  debug          - toggle debug mode (local only, no channel)")
        wbaPrint("  debugboss <n>  - set fake boss name for debug testing")
        wbaPrint("  inspect        - print target classification, level and type")
        wbaPrint("  pvp            - toggle PvP alerts")
        wbaPrint("  death          - toggle death notifications")
        wbaPrint("  panel          - show/hide GUI panel")
    end
end

-------------------------------------------------------------------------------
-- 15. FRAME WIRING
-------------------------------------------------------------------------------
wbaFrame:SetScript("OnEvent",   wbaOnEvent)
wbaFrame:SetScript("OnUpdate",  wbaOnUpdate)

wbaFrame:RegisterEvent("ADDON_LOADED")
wbaFrame:RegisterEvent("PLAYER_LOGOUT")
wbaFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
wbaFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Scouting combat events are registered dynamically via toggle
-- Raid events are registered dynamically via toggle

-------------------------------------------------------------------------------
-- 16. DEBUG EVENT SNIFFER
-- A separate frame that watches all known death-related events and prints
-- whatever fires when debug mode is on. Lets us figure out the exact event
-- name and message format TurtleWoW uses for mob deaths.
-------------------------------------------------------------------------------
local wbaSnifferFrame = CreateFrame("Frame")

local wbaDeathEvents = {
    "CHAT_MSG_COMBAT_HOSTILE_DEATH",
    "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS",
    "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS",
    "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS",
    "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE",
    "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE",
    "CHAT_MSG_LOOT",
    "UNIT_DIED",
    "UNIT_HEALTH",
}

for _, evt in ipairs(wbaDeathEvents) do
    wbaSnifferFrame:RegisterEvent(evt)
end

wbaSnifferFrame:SetScript("OnEvent", function()
    if not wbaDebugMode then return end
    if not wbaDebugBoss then return end
    local msg = arg1 or ""
    -- For UNIT_HEALTH only print when unit is near death to avoid spam
    if event == "UNIT_HEALTH" then
        local unit = arg1
        if unit and UnitExists(unit) then
            local hp = UnitHealth(unit)
            local name = UnitName(unit) or ""
            if name == wbaDebugBoss and hp <= 1 then
                wbaPrint("|cFF00FFFF[SNIFF:UNIT_HEALTH]|r " .. name .. " hp=" .. hp)
            end
        end
        return
    end
    -- For all other events print if message contains debug boss name OR it's a death/loot event
    local relevant = string.find(msg, wbaDebugBoss)
                  or event == "UNIT_DIED"
                  or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH"
                  or event == "CHAT_MSG_LOOT"
    if relevant then
        wbaPrint("|cFF00FFFF[SNIFF:" .. event .. "]|r " .. msg)
    end
end)