-- AntiCheatScript
-- Location: ServerScriptService

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")

-- Configuration (can be expanded)
local MAX_ALLOWED_WALKSPEED = 16 -- Default Roblox WalkSpeed
local SPEED_CHECK_INTERVAL = 0.5 -- Seconds, though Heartbeat is per frame
local POSITION_BUFFER_PERCENTAGE = 0.15 -- 15% buffer for speed checks to reduce false positives

-- Consequence Configuration
local SPEED_HACK_WARN_THRESHOLD = 3 -- Number of warnings before kick for speed hacks
local KICK_MESSAGE_SPEED = "You have been kicked for unsporting behavior (Code: S)."
local KICK_MESSAGE_WALLHACK = "You have been kicked for unsporting behavior (Code: W)." -- Not used for kicking yet
local LOG_WALLHACKS = true -- Enable detailed logging for wallhacks
local LOG_AIMBOTS = true   -- Enable detailed logging for aimbots (currently placeholder)

-- DataStore and Enhanced Sanction Configuration
local DATASTORE_NAME = "AntiCheatPlayerSanctions" -- Name of the DataStore to save sanction data
local MAX_KICKS_BEFORE_BAN = 3 -- Number of kicks (for any reason) before escalating to a ban
local BAN_DURATION_HOURS = 0 -- Hours for a temporary ban. Use 0 or nil for a permanent ban. (Note: Timed ban logic for offline expiry is complex and not fully implemented in this basic script)
local KICK_MESSAGE_WARNING = "Please remove your hacks to continue playing. Further violations may result in a ban. (Code: K)" -- Generic warning kick message
local BAN_MESSAGE = "You are banned from this game due to repeated anti-cheat violations." -- Message shown to player on ban
local BAN_REASON_ESCALATION = "Automated ban due to repeated cheat detections." -- Reason logged for the ban (server-side)

local sanctionDataStore -- Will be initialized by initSanctionDataStore

local function initSanctionDataStore()
    local success, result = pcall(function()
        return DataStoreService:GetDataStore(DATASTORE_NAME)
    end)
    if success then
        sanctionDataStore = result
        print("AntiCheat: Successfully connected to DataStore: " .. DATASTORE_NAME)
    else
        warn("AntiCheat: CRITICAL ERROR - Failed to connect to DataStore: " .. DATASTORE_NAME .. ". Error: " .. tostring(result))
        -- Might want to disable features or kick all players if datastore is essential and fails to init
    end
end
-- Call initialization
initSanctionDataStore()

local function getPlayerSanctionData(userId)
    if not sanctionDataStore then
        warn("AntiCheat: DataStore not initialized. Cannot get sanction data for " .. userId)
        return {kicks = 0, isBanned = false, banReason = nil, banTimestamp = nil, banExpiresTimestamp = nil, lastKickTimestamp = nil} -- Default structure
    end

    local userKey = tostring(userId)
    local success, dataOrError = pcall(function()
        return sanctionDataStore:GetAsync(userKey)
    end)

    if success then
        if dataOrError then
            -- Data found, return it. Add default fields if they are missing from older data structures.
            local defaultData = {kicks = 0, isBanned = false, banReason = nil, banTimestamp = nil, banExpiresTimestamp = nil, lastKickTimestamp = nil}
            for key, value in pairs(defaultData) do
                if dataOrError[key] == nil then
                    dataOrError[key] = value
                end
            end
            return dataOrError
        else
            -- No data found (new player for sanctions), return default structure
            return {kicks = 0, isBanned = false, banReason = nil, banTimestamp = nil, banExpiresTimestamp = nil, lastKickTimestamp = nil}
        end
    else
        warn("AntiCheat: Error getting sanction data for " .. userId .. ". Error: " .. tostring(dataOrError))
        -- Return default structure on error to prevent breaking other logic
        return {kicks = 0, isBanned = false, banReason = nil, banTimestamp = nil, banExpiresTimestamp = nil, lastKickTimestamp = nil}
    end
end

local function savePlayerSanctionData(userId, data)
    if not sanctionDataStore then
        warn("AntiCheat: DataStore not initialized. Cannot save sanction data for " .. userId)
        return false
    end

    local userKey = tostring(userId)
    local success, errorMessage = pcall(function()
        sanctionDataStore:SetAsync(userKey, data)
    end)

    if success then
        print("AntiCheat: Successfully saved sanction data for " .. userId)
        return true
    else
        warn("AntiCheat: Error saving sanction data for " .. userId .. ". Error: " .. tostring(errorMessage))
        return false
    end
end

local playerLastPositions = {}
local playerSpeedHackWarnings = {}

--[[
    @class AntiCheatSystem
    @server
    The main module for handling anti-cheat logic.
--]]
local AntiCheatSystem = {}

--[[
    Validates a player's movement to detect potential speed hacking.
    @param player Player The player object to check.
    @param currentPosition Vector3 The player's current position.
    @param lastPosition Vector3 The player's last known position.
    @param deltaTime number The time elapsed since the last position check.
    @return boolean True if suspicious movement is detected, false otherwise.
--]]
function AntiCheatSystem.checkSpeedHack(player, currentPosition, lastPosition, deltaTime)
    if not player or not player.Character or not player.Character:FindFirstChildOfClass("Humanoid") then
        return false
    end

    local humanoid = player.Character.Humanoid
    local currentWalkSpeed = humanoid.WalkSpeed -- This is what the client *reports* or what's set

    -- More reliable: Positional validation based on server-known max speed or character's current WalkSpeed property
    -- We'll use the character's current WalkSpeed as the basis, assuming it's managed server-side for game mechanics
    if lastPosition and deltaTime > 0 then -- deltaTime can be 0 in some edge cases, avoid division by zero
        local distanceCovered = (currentPosition - lastPosition).Magnitude
        -- Use the character's current WalkSpeed for calculation, assuming it can be legitimately changed by the game.
        -- If WalkSpeed is meant to be static, use MAX_ALLOWED_WALKSPEED.
        local maxExpectedDistance = currentWalkSpeed * deltaTime * (1 + POSITION_BUFFER_PERCENTAGE)

        -- Add a small flat buffer as well to prevent issues with very low walkspeeds
        local flatBuffer = 0.1
        maxExpectedDistance = maxExpectedDistance + flatBuffer

        if distanceCovered > maxExpectedDistance and distanceCovered > 0.5 then -- Ignore very small discrepancies / stationary players
            -- print(player.Name .. " moved suspiciously fast! Dist: " .. string.format("%.2f", distanceCovered) .. ", Expected Max: " .. string.format("%.2f", maxExpectedDistance) .. ", WalkSpeed: " .. string.format("%.2f", currentWalkSpeed) .. ", DeltaTime: " .. string.format("%.3f", deltaTime))
            return true
        end
    end
    return false
end

--[[
    Validates an action requiring line-of-sight to detect potential wallhacks.
    @param player Player The player performing the action.
    @param targetPosition Vector3 The position of the target of the action.
    -- @param actionType string A descriptor of the action (e.g., "ShootWeapon", "DamagePlayer").
    @return boolean True if the action is obstructed (suspicious), false otherwise.
--]]
function AntiCheatSystem.checkWallHack(player, targetPosition)
    if not player or not player.Character or not player.Character:FindFirstChild("Head") then
        return false -- Cannot perform check
    end

    local playerHead = player.Character.Head
    local origin = playerHead.Position

    -- Ensure targetPosition is a Vector3
    if typeof(targetPosition) ~= "Vector3" then
        warn("AntiCheatSystem.checkWallHack: targetPosition is not a Vector3. Got: ".. typeof(targetPosition))
        return false -- Invalid target position
    end

    local direction = (targetPosition - origin).Unit
    local distance = (targetPosition - origin).Magnitude

    if distance < 0.1 then return false end -- Negligible distance, likely self-target or very close

    local raycastParams = RaycastParams.new()
    raycastParams.FilterDescendantsInstances = {player.Character}
    raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
    -- For better accuracy, define a collision group for "Environment" or "Walls"
    -- and set raycastParams.CollisionGroup = "EnvironmentCollisionGroup"
    -- This ensures the ray only checks against things that should obstruct view.

    local raycastResult = workspace:Raycast(origin, direction * distance, raycastParams)

    if raycastResult and raycastResult.Instance then
        -- An instance was hit. Now, we need to determine if this instance is part of the intended target
        -- or if it's an obstructing object (like a wall).
        -- This part is crucial and game-specific. For a generic check:
        -- If the hit instance is not a descendant of any player character AND not explicitly tagged as "ignore_los_check",
        -- it's considered an obstruction.
        -- For this basic version, we'll assume if anything is hit, it's an obstruction unless it's part of another character.
        local hitModel = raycastResult.Instance:FindFirstAncestorWhichIsA("Model")
        if hitModel and Players:GetPlayerFromCharacter(hitModel) then
            -- Hit another player, potentially the target. This is NOT an obstruction for this check.
            return false
        end

        -- If it's not another player, consider it an obstruction.
        -- print(player.Name .. " action towards " .. tostring(targetPosition) .. " obstructed by " .. raycastResult.Instance.Name)
        return true -- Suspicious, something was hit that wasn't the target player.
    end

    return false -- No obstruction found
end

--[[
    Analyzes player behavior for patterns indicative of aimbotting. (Placeholder)
    @param player Player The player to check.
    @param target Player The target player (if applicable).
    @param hitDetails table Information about the hit (e.g., hit part, accuracy).
    @return boolean True if aimbot behavior is suspected, false otherwise.
--]]
function AntiCheatSystem.checkAimbot(player, target, hitDetails)
    -- This remains a placeholder due to its complexity and high risk of false positives.
    -- Effective aimbot detection often requires significant data analysis and understanding
    -- of game-specific mechanics (weapon spread, recoil, projectile speed etc).
    -- print("Aimbot check for " .. player.Name .. " - Not implemented.")
    return false
end

--[[
    Handles actions to be taken when a cheat is detected.
    @param player Player The player who triggered the detection.
    @param cheatType string The type of cheat detected.
    @param details string Additional details about the detection.
--]]
function AntiCheatSystem.handleDetection(player, cheatType, details)
    local userId = player.UserId
    local sanctionData = getPlayerSanctionData(userId) -- Get current persistent data

    local timestamp = os.date("!*t")
    local logMessage = string.format("[%04d-%02d-%02d %02d:%02d:%02dZ] CHEAT DETECTED: Player=%s (%d), Type=%s, Details: %s. Current Kicks: %d, Banned: %s",
        timestamp.year, timestamp.month, timestamp.day,
        timestamp.hour, timestamp.min, timestamp.sec,
        player.Name, userId, cheatType, details, sanctionData.kicks or 0, tostring(sanctionData.isBanned))

    print(logMessage) -- Standardized logging

    -- If already banned, no further action needed here as PlayerAdded should handle it.
    -- However, if a banned player is somehow still in game and triggers this, ensure they are kicked.
    if sanctionData.isBanned then
        local banReason = sanctionData.banReason or BAN_REASON_ESCALATION
        local finalBanMsg = BAN_MESSAGE .. " Reason: " .. banReason
        if sanctionData.banTimestamp then
            finalBanMsg = finalBanMsg .. " (Issued: " .. os.date("%Y-%m-%d %H:%M:%S UTC", sanctionData.banTimestamp) .. ")"
        end
        player:Kick(finalBanMsg)
        return
    end

    if cheatType == "SpeedHack" then
        playerSpeedHackWarnings[player] = (playerSpeedHackWarnings[player] or 0) + 1

        -- Check if session warnings meet the threshold for a persistent kick record
        if playerSpeedHackWarnings[player] >= SPEED_HACK_WARN_THRESHOLD then
            sanctionData.kicks = (sanctionData.kicks or 0) + 1
            sanctionData.lastKickTimestamp = os.time()
            -- More specific reason can be stored if desired, e.g., in a kickHistory array
            -- For now, just incrementing general kicks count

            print("AntiCheat: Player " .. player.Name .. " ("..userId..") reached kick threshold for SpeedHack. Total persistent kicks: " .. sanctionData.kicks)

            if sanctionData.kicks >= MAX_KICKS_BEFORE_BAN then
                -- BAN THE PLAYER
                sanctionData.isBanned = true
                sanctionData.banReason = BAN_REASON_ESCALATION .. " (Last offense: " .. cheatType .. ")"
                sanctionData.banTimestamp = os.time()

                if BAN_DURATION_HOURS and BAN_DURATION_HOURS > 0 then
                    sanctionData.banExpiresTimestamp = os.time() + (BAN_DURATION_HOURS * 60 * 60)
                else
                    sanctionData.banExpiresTimestamp = nil -- Permanent
                end

                local saved = savePlayerSanctionData(userId, sanctionData)
                if saved then
                    print("AntiCheat: Player " .. player.Name .. " ("..userId..") BANNED. Reason: " .. sanctionData.banReason .. ". Total kicks: " .. sanctionData.kicks)
                else
                    print("AntiCheat: FAILED TO SAVE BAN DATA for player " .. player.Name .. " ("..userId..") but proceeding with kick.")
                end

                local finalBanMsg = BAN_MESSAGE .. " Reason: " .. sanctionData.banReason
                if sanctionData.banTimestamp then
                    finalBanMsg = finalBanMsg .. " (Issued: " .. os.date("%Y-%m-%d %H:%M:%S UTC", sanctionData.banTimestamp) .. ")"
                end
                player:Kick(finalBanMsg)

            else
                -- KICK THE PLAYER (Warning Kick)
                local saved = savePlayerSanctionData(userId, sanctionData)
                if saved then
                     print("AntiCheat: Player " .. player.Name .. " ("..userId..") KICKED (warning). Reason: " .. cheatType .. ". Persistent kicks: " .. sanctionData.kicks .. "/" .. MAX_KICKS_BEFORE_BAN)
                else
                    print("AntiCheat: FAILED TO SAVE KICK DATA for player " .. player.Name .. " ("..userId..") but proceeding with kick.")
                end
                player:Kick(KICK_MESSAGE_WARNING .. " (Offense: " .. cheatType .. ". Kick " .. sanctionData.kicks .. " of " .. MAX_KICKS_BEFORE_BAN .. " before ban.)")
            end

            playerSpeedHackWarnings[player] = 0 -- Reset session warnings after a persistent action (kick/ban)
        else
            -- Just a session warning, not yet a persistent kick
            print("AntiCheat: Player " .. player.Name .. " ("..userId..") SpeedHack session warning " .. playerSpeedHackWarnings[player] .. "/" .. SPEED_HACK_WARN_THRESHOLD)
        end

    elseif cheatType == "WallHack" then
        if LOG_WALLHACKS then
            print("AntiCheat: WallHack specific log: Player " .. player.Name .. " triggered wallhack detection. Details: " .. details)
            -- Future: Could increment a different counter or add to kickHistory in sanctionData
            -- For now, only SpeedHack escalates to kicks/bans in this script.
        end
    elseif cheatType == "Aimbot" then
        if LOG_AIMBOTS then
            print("AntiCheat: Aimbot specific log: Player " .. player.Name .. " triggered aimbot detection (placeholder). Details: " .. details)
        end
    end
    -- Note: No explicit savePlayerSanctionData(userId, sanctionData) here for WallHack/Aimbot
    -- because they are not modifying sanctionData in this iteration.
    -- If they were to modify it (e.g. sanctionData.wallhack_warnings +=1), a save would be needed.
end


-- PlayerAdded Connection
Players.PlayerAdded:Connect(function(player)
    -- Wait for DataStore to be ready if it's still initializing (should be quick usually)
    while not sanctionDataStore do
        warn("AntiCheat: Waiting for DataStore to initialize before processing player " .. player.Name)
        task.wait(1)
    end

    local userId = player.UserId
    local sanctionData = getPlayerSanctionData(userId)

    print("AntiCheat: Player " .. player.Name .. " ("..userId..") joining. Sanction data: Kicks=" .. (sanctionData.kicks or 0) .. ", Banned=" .. tostring(sanctionData.isBanned))

    if sanctionData.isBanned then
        local banReason = sanctionData.banReason or BAN_REASON_ESCALATION
        local banTimestamp = sanctionData.banTimestamp
        local banExpires = sanctionData.banExpiresTimestamp -- Currently not implementing auto-expiry in this iteration

        -- Basic check for permanent bans (banExpires is nil or 0)
        -- Timed ban expiry logic would be more complex here, potentially requiring os.time() comparison
        -- For now, if isBanned is true, we assume it's an active ban.
        -- Manual unbanning would involve an admin setting isBanned to false in the DataStore.

        local finalBanMessage = BAN_MESSAGE
        if banReason and string.len(banReason) > 0 then
            finalBanMessage = BAN_MESSAGE .. " Reason: " .. banReason
        end
        if banTimestamp then
             finalBanMessage = finalBanMessage .. " (Issued: " .. os.date("%Y-%m-%d %H:%M:%S UTC", banTimestamp) .. ")"
        end

        player:Kick(finalBanMessage)
        print("AntiCheat: Kicked banned player " .. player.Name .. " ("..userId.."). Reason: " .. banReason)
        return -- Stop further processing for this banned player
    end

    -- If not banned, proceed with normal initialization
    print("AntiCheat: Player " .. player.Name .. " ("..userId..") is not banned. Initializing anti-cheat checks.")
    playerLastPositions[player] = nil
    playerSpeedHackWarnings[player] = 0 -- Reset session warnings

    player.CharacterAdded:Connect(function(character)
        task.wait(0.5) -- Wait for character to be parented and parts to exist
        if character and character.PrimaryPart then
            playerLastPositions[player] = character.PrimaryPart.Position
        else
            playerLastPositions[player] = nil
        end
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    print("Player " .. player.Name .. " ("..player.UserId..") removing. Cleaning up anti-cheat data.")
    playerLastPositions[player] = nil
    playerSpeedHackWarnings[player] = nil
end)


-- Main server loop for periodic checks
RunService.Heartbeat:Connect(function(deltaTime)
    for _, player in ipairs(Players:GetPlayers()) do
        if player and player.Character and player.Character.PrimaryPart and player:HasAppearanceLoaded() then
            local currentPosition = player.Character.PrimaryPart.Position
            local lastPosition = playerLastPositions[player]

            if lastPosition then
                if AntiCheatSystem.checkSpeedHack(player, currentPosition, lastPosition, deltaTime) then
                    AntiCheatSystem.handleDetection(player, "SpeedHack", "Exceeded expected travel distance.")
                end
            end
            -- Always update position if character exists, even if lastPosition was nil (for the first check)
            playerLastPositions[player] = currentPosition
        else
            -- If no character or primary part, ensure last position is nil to avoid issues on respawn/load
            if playerLastPositions[player] ~= nil then
                 playerLastPositions[player] = nil
            end
        end
    end
end)

-- Example of how to integrate wallhack check with a RemoteEvent
-- This should be in the actual server script handling the RemoteEvent for firing.
-- For demonstration, it's included here but commented out.
--[[
local FireWeaponEvent = Instance.new("RemoteEvent")
FireWeaponEvent.Name = "FireWeaponEvent"
FireWeaponEvent.Parent = ServerScriptService -- Or ReplicatedStorage if client needs to find it

FireWeaponEvent.OnServerEvent:Connect(function(player, targetPosition, weaponName)
    -- 1. Basic Sanity Checks (e.g., is targetPosition a Vector3? does player have weaponName?)
    if typeof(targetPosition) ~= "Vector3" then
        player:Kick("Invalid target data.")
        return
    end

    -- 2. Anti-Cheat Line-of-Sight (Wallhack) Check
    if AntiCheatSystem.checkWallHack(player, targetPosition) then
        AntiCheatSystem.handleDetection(player, "WallHack", "Weapon fire attempt obstructed: " .. weaponName)
        -- Optionally, provide vague feedback to the client, or no feedback.
        -- Do NOT tell them "wallhack detected".
        return -- Stop processing this event
    end

    -- 3. Proceed with normal weapon firing logic (damage, effects, etc.)
    print(player.Name .. " fired " .. weaponName .. " at " .. tostring(targetPosition) .. ". LOS clear.")
    -- ... game logic for firing ...
end)
--]]

print("AntiCheatScript.lua (Server-Side) Loaded.")

-- If other server scripts need to call these functions, you might return AntiCheatSystem.
-- However, for a self-contained system, this is not strictly necessary.
-- return AntiCheatSystem
