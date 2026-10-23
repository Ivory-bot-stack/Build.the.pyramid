--[[
    KLZE Hub — Construa a Pirâmide! (123720558354386)
    Auto pickup + auto place (turbo, respeita capacity do servidor)
]]

if typeof(getgenv) == "function" then
    getgenv().KLZE_UI_NO_PREVIEW = true
end

local MAIN_PLACE_ID = 123720558354386
local HALLOWEEN_PLACE_ID = 95412364107708
local PLACE_ID = MAIN_PLACE_ID
if game.PlaceId ~= MAIN_PLACE_ID and game.PlaceId ~= HALLOWEEN_PLACE_ID then
    warn("[KLZE] PlaceId mismatch:", game.PlaceId, "expected", MAIN_PLACE_ID, "or", HALLOWEEN_PLACE_ID)
end

local API_URL = (typeof(getgenv) == "function" and getgenv().KLZE_API_URL)
    or "https://klze-hub.pages.dev"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")

local DEFAULT_DISCORD = "https://discord.gg/wQRybxxHdX"
local DEFAULT_SITE = "https://klze-hub.pages.dev"

local function copyToClipboard(text)
    text = tostring(text or "")
    if text == "" then
        return false
    end
    if typeof(setclipboard) == "function" then
        setclipboard(text)
        return true
    end
    if typeof(toclipboard) == "function" then
        toclipboard(text)
        return true
    end
    if syn and typeof(syn.write_clipboard) == "function" then
        syn.write_clipboard(text)
        return true
    end
    return false
end

local function getExecutorName()
    if typeof(identifyexecutor) == "function" then
        local ok, name = pcall(identifyexecutor)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return "Unknown"
end

-- Turbo default; throttling only in strict layer-endgame (see isStrictLayerEndgame)
local BURST_PICK = 28
local BURST_PLACE = 28
local BURST_QUARRY = 14
local MAX_QUARRY_IN_FLIGHT = 6
local MAX_PLACE_DRAIN_PASSES = 5
local TP_COOLDOWN = 0.45
local FARM_TP_COOLDOWN = 0.06
local FARM_PLACE_COOLDOWN = 0.02
local FARM_LAYER_ENDGAME_COOLDOWN = 0.32
local FARM_REFRESH_MIN_INTERVAL = 0.35
local FARM_PILE_IDLE = 1.15
local FARM_NUDGE_COOLDOWN = 2.25

local Farm = {
    enabled = false,
    conn = nil,
    hbConn = nil,
    quarryInFlight = 0,
    capacityOverride = nil,
    placingRun = false,
    placeStuckTicks = 0,
    lastNoSlotNotify = 0,
    nextPlaceAttempt = 0,
    lastPlacementRefresh = 0,
    lastGhostSync = 0,
    lastPruneSync = 0,
    lastNavSlotAt = 0,
    cachedNavSlot = nil,
    strictLayerEndgame = false,
    lastTp = 0,
    lastProgressAt = 0,
    lastCarriedSeen = -1,
    lastNudgeAt = 0,
    nextPileCheck = 0,
    speed = 10,
}

local AutoUpgrade = {
    picks = {
        bulkPickup = false,
        bulkPlace = false,
        placementRange = false,
    },
    currencyMode = "Auto",
    conn = nil,
    lastTick = 0,
    cachedCoins = nil,
    cachedCandyCorn = nil,
    coinObserverBound = false,
}

local AntiLag = {
    isNormal = game.PlaceId == MAIN_PLACE_ID,
    enabled = true,
    renderConns = {},
    renderSaved = nil,
    hookedCoinVfx = false,
    origCoinFire = nil,
    savedSettings = {},
    origUpdateGhost = nil,
    origPlayPlacementJuice = nil,
    origPlayPickupJuice = nil,
    hookedRuntime = nil,
}

local AutoPet = {
    hatchEnabled = false,
    selectedEggId = "AutoBest",
    hatchAmountMode = "Auto",
    autoTpToEgg = true,
    instantHatch = true,
    autoEquipBest = false,
    autoDeleteRarities = {},
    conn = nil,
    hatchedConn = nil,
    lastHatchAt = 0,
    lastEquipBestAt = 0,
    lastAutoDeleteSyncAt = 0,
    inFlight = false,
    eggMap = {},
    eggLabels = {},
}

local AUTO_UPGRADE_ORDER = { "bulkPickup", "bulkPlace", "placementRange" }

local AUTO_UPGRADE_INTERVAL = 0.4

local AutoTrain = {
    speed = false,
    strength = false,
    conn = nil,
    lastTick = 0,
    lastTp = 0,
}

local AutoHill = {
    enabled = false,
    conn = nil,
    lastTp = 0,
    lastTick = 0,
    onHill = false,
    lastCompletions = nil,
    waiting = false,
    waitSince = 0,
    remaining = 0,
}

local TRAIN_TICK_INTERVAL = 0.35
local TRAIN_TP_COOLDOWN = 0.45

local function farmSpeedN()
    return math.clamp(math.floor(tonumber(Farm.speed) or 10), 1, 10)
end

local function farmSpeedT()
    return (farmSpeedN() - 1) / 9
end

local function scaledFarmBurst(base)
    local mult = 0.12 + 0.88 * farmSpeedT()
    return math.max(1, math.floor(base * mult + 0.5))
end

local function scaledFarmDrainPasses()
    local mult = 0.15 + 0.85 * farmSpeedT()
    return math.max(1, math.floor(MAX_PLACE_DRAIN_PASSES * mult + 0.5))
end

local function getFarmTpCooldown()
    return FARM_TP_COOLDOWN + (1 - farmSpeedT()) * 0.4
end

local function farmHeartbeatTurboEnabled()
    return farmSpeedN() >= 7
end

local klzePyramidUnload

local PlayerMods = {
    fly = false,
    flySpeed = 200,
    walkSpeed = 48,
    infJump = false,
    jumpHeight = 90,
    flyConn = nil,
    jumpConn = nil,
    charConn = nil,
}

local function stripBom(source)
    if type(source) ~= "string" then
        return source
    end
    if source:sub(1, 3) == "\239\187\191" then
        return source:sub(4)
    end
    return source
end

local function isLikelyLua(source)
    source = stripBom(source)
    if type(source) ~= "string" or #source < 80 then
        return false
    end
    local head = source:sub(1, 512):lower()
    if head:find("<!doctype", 1, true) or head:find("<html", 1, true) or head:find("<head", 1, true) then
        return false
    end
    local first = source:match("^%s*(%S)")
    if first == "<" or first == "{" then
        return false
    end
    if source:find("^%-%- Failed", 1, true) or source:find("^%-%- Game not", 1, true) then
        return false
    end
    return true
end

local function runSource(source, chunkName)
    source = stripBom(source)
    if not isLikelyLua(source) then
        error("[KLZE] HttpGet returned HTML/JSON, not Lua")
    end
    local fn, err = loadstring(source, chunkName or "chunk")
    if not fn then
        error(tostring(err))
    end
    if setfenv and typeof(getgenv) == "function" then
        setfenv(fn, getgenv())
    end
    return fn()
end

local function runSourceSafe(source, chunkName)
    local ok, result = pcall(runSource, source, chunkName)
    if ok then
        return result
    end
    return nil
end

local OBSIDIAN_REPO = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"

local function validHub(mod)
    return type(mod) == "table"
        and type(mod.create) == "function"
        and type(mod.complete) == "function"
        and type(mod.addHomeTab) == "function"
end

local function httpGetText(url)
    for attempt = 1, 2 do
        local ok, body = pcall(function()
            return game:HttpGet(url, true)
        end)
        if ok and type(body) == "string" and isLikelyLua(body) then
            return body
        end
        if attempt == 1 then
            task.wait(0.35)
        end
    end
    return nil
end

local function httpGetHubWindow(url)
    local body = httpGetText(url)
    if not body then
        return nil
    end
    local hub = runSourceSafe(body, "HubWindow")
    if validHub(hub) then
        return hub
    end
    return nil
end

local function buildInlineHub()
    local Hub = {}
    Hub._afkConn = nil
    Hub._presenceRunning = false

    local function hubApiBase()
        if typeof(getgenv) == "function" and type(getgenv().KLZE_API_URL) == "string" then
            local api = (getgenv().KLZE_API_URL):gsub("/+$", "")
            if api ~= "" then
                return api
            end
        end
        return "https://klze-hub.pages.dev"
    end

    local function hubHeartbeatBase()
        if typeof(getgenv) == "function" and type(getgenv().KLZE_HEARTBEAT_URL) == "string" then
            local api = (getgenv().KLZE_HEARTBEAT_URL):gsub("/+$", "")
            if api ~= "" then
                return api
            end
        end
        return "https://hub-script-api.guicolucce1.workers.dev"
    end

    local function hubSendHeartbeat(meta, extraQuery)
        meta = meta or {}
        local lp = Players.LocalPlayer
        if not lp then
            return
        end
        local HttpService = game:GetService("HttpService")
        local fields = {
            robloxUserId = tostring(lp.UserId),
            robloxName = lp.Name,
            displayName = lp.DisplayName,
            placeId = tostring(game.PlaceId),
            universeId = tostring(game.GameId),
            placeName = meta.gameTitle or "Game",
            executor = getExecutorName(),
            hwid = tostring(lp.UserId),
            loaderVersion = meta.version and ("v" .. tostring(meta.version):gsub("^v", "")) or nil,
        }
        local parts = {}
        for key, value in pairs(fields) do
            if value ~= nil then
                table.insert(parts, key .. "=" .. HttpService:UrlEncode(tostring(value)))
            end
        end
        if extraQuery then
            table.insert(parts, extraQuery)
        end
        pcall(function()
            return game:HttpGet(hubHeartbeatBase() .. "/heartbeat?" .. table.concat(parts, "&"), true)
        end)
    end

    function Hub.startPresence(meta)
        if Hub._presenceRunning then
            return
        end
        if typeof(getgenv) == "function" and getgenv().__KLZE_PRESENCE_LOOP then
            return
        end
        Hub._presenceRunning = true
        if typeof(getgenv) == "function" then
            getgenv().__KLZE_PRESENCE_LOOP = true
        end
        local left = false
        local function leave()
            if left then
                return
            end
            left = true
            Hub._presenceRunning = false
            hubSendHeartbeat(meta, "offline=1")
        end
        task.spawn(function()
            hubSendHeartbeat(meta, "fresh=1")
            while Hub._presenceRunning do
                task.wait(30)
                if not Hub._presenceRunning then
                    break
                end
                hubSendHeartbeat(meta)
            end
        end)
        Players.PlayerRemoving:Connect(function(player)
            if player == Players.LocalPlayer then
                leave()
            end
        end)
    end

    local function httpGetObsidian(path)
        local body = httpGetText(OBSIDIAN_REPO .. path)
        if not body then
            error("[KLZE] Obsidian download failed: " .. path)
        end
        local lib = runSourceSafe(body, path)
        if not lib then
            error("[KLZE] Obsidian load failed: " .. path)
        end
        return lib
    end

    function Hub.setAntiAfk(enabled)
        if Hub._afkConn then
            Hub._afkConn:Disconnect()
            Hub._afkConn = nil
        end
        if Hub._afkKnitThread then
            task.cancel(Hub._afkKnitThread)
            Hub._afkKnitThread = nil
        end
        if not enabled then
            return
        end
        local vu = game:GetService("VirtualUser")
        Hub._afkConn = RunService.Heartbeat:Connect(function()
            pcall(function()
                vu:CaptureController()
                vu:ClickButton2(Vector2.new(0, 0))
            end)
        end)
        Hub._afkKnitThread = task.spawn(function()
            while true do
                pcall(function()
                    local KnitPkg = ReplicatedStorage:FindFirstChild("Packages")
                    local Knit = KnitPkg and KnitPkg:FindFirstChild("Knit") and require(KnitPkg.Knit)
                    if Knit and Knit.GetService then
                        local afkSvc = Knit.GetService("AFKService")
                        if afkSvc and afkSvc.Activity and afkSvc.Activity.Fire then
                            afkSvc.Activity:Fire()
                        end
                    end
                end)
                task.wait(15)
            end
        end)
    end

    function Hub.notify(Library, text, duration)
        if Library and Library.Notify then
            pcall(function()
                Library:Notify(tostring(text), duration or 4)
            end)
        end
    end

    function Hub.loadObsidian()
        if typeof(getgenv) == "function" and getgenv().KLZE_OBSIDIAN_READY then
            local Library = getgenv().KLZE_OBSIDIAN_LIBRARY
            local SaveManager = getgenv().KLZE_OBSIDIAN_SAVE
            local ThemeManager = getgenv().KLZE_OBSIDIAN_THEME
            if SaveManager and SaveManager.SetIgnoreIndexes then
                SaveManager:SetIgnoreIndexes({
                    "MenuKeybind",
                    "klze_auto_farm",
                    "klze_fly",
                    "klze_inf_jump",
                })
            end
            return Library, SaveManager, ThemeManager
        end
        local Library = httpGetObsidian("Library.lua")
        local ThemeManager = httpGetObsidian("addons/ThemeManager.lua")
        local SaveManager = httpGetObsidian("addons/SaveManager.lua")
        ThemeManager:SetLibrary(Library)
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({
            "MenuKeybind",
            "klze_auto_farm",
            "klze_fly",
            "klze_inf_jump",
        })
        Library.ShowToggleFrameInKeybinds = true
        Library.ShowCustomCursor = false
        Library.NotifySide = "Right"
        if typeof(getgenv) == "function" then
            getgenv().KLZE_OBSIDIAN_LIBRARY = Library
            getgenv().KLZE_OBSIDIAN_SAVE = SaveManager
            getgenv().KLZE_OBSIDIAN_THEME = ThemeManager
            getgenv().KLZE_OBSIDIAN_READY = true
            getgenv().KLZE_HUB_WINDOW = Hub
        end
        return Library, SaveManager, ThemeManager
    end

    function Hub.create(options)
        options = options or {}
        local Library, SaveManager, ThemeManager = Hub.loadObsidian()
        local gameTitle = options.Game or "KLZE Hub"
        local version = tostring(options.Version or "1"):gsub("^v", "")
        local placeId = tostring(game.PlaceId)
        local folderRoot = "klze_hub"
        ThemeManager:SetFolder(folderRoot)
        SaveManager:SetFolder(folderRoot .. "/place_" .. placeId)
        local Window = Library:CreateWindow({
            Title = "KLZE Hub",
            Footer = "v" .. version .. " · klze-hub",
            Center = true,
            AutoShow = true,
            Resizable = true,
            MobileButtonsSide = "Left",
            ShowCustomCursor = false,
            NotifySide = "Right",
            Icon = 95816097006870,
            DisableSearch = true,
        })
        Library:OnUnload(function()
        Hub.setAntiAfk(false)
        Hub._presenceRunning = false
            local clean = typeof(getgenv) == "function" and getgenv().KLZE_PYRAMID_CLEANUP
            if type(clean) == "function" then
                pcall(clean)
            end
        end)
        if options.ShowHomeTab ~= false then
            Hub.addHomeTab(Window, Library, options)
        end
        return Window, Library, SaveManager, ThemeManager, {
            placeId = placeId,
            gameTitle = gameTitle,
            version = version,
        }
    end

    function Hub.addHomeTab(Window, Library, options)
        options = options or {}
        local lp = Players.LocalPlayer
        local gameTitle = options.Game or "Roblox"
        local discord = options.DiscordInvite or DEFAULT_DISCORD
        local site = options.SiteUrl or DEFAULT_SITE
        local version = tostring(options.Version or "1"):gsub("^v", "")
        local blurb = options.HubBlurb
            or "Keyless KLZE Hub — many game scripts, no key system. Paste once and play."

        local tab = Window:AddTab("Home", "house")
        local userBox = tab:AddLeftGroupbox("User", "user")

        local display = lp and (lp.DisplayName ~= lp.Name and (lp.DisplayName .. " @" .. lp.Name) or lp.Name) or "?"
        userBox:AddLabel("User: " .. display)
        userBox:AddLabel("UserId: " .. tostring(lp and lp.UserId or "?"))
        userBox:AddLabel("Executor: " .. getExecutorName())

        userBox:AddButton("Copy username", function()
            if lp and copyToClipboard(lp.Name) then
                Hub.notify(Library, "Username copied", 2)
            end
        end)

        userBox:AddButton("Copy profile link", function()
            if lp and copyToClipboard("https://www.roblox.com/users/" .. lp.UserId .. "/profile") then
                Hub.notify(Library, "Profile URL copied", 2)
            end
        end)

        local sessionBox = tab:AddRightGroupbox("Session", "globe")
        sessionBox:AddLabel("Game: " .. gameTitle)
        sessionBox:AddLabel("PlaceId: " .. tostring(game.PlaceId))
        sessionBox:AddLabel("Players: " .. tostring(#Players:GetPlayers()))
        sessionBox:AddLabel("JobId: " .. string.sub(tostring(game.JobId), 1, 18))

        sessionBox:AddButton("Copy JobId", function()
            if copyToClipboard(game.JobId) then
                Hub.notify(Library, "JobId copied", 2)
            end
        end)

        sessionBox:AddButton("Rejoin server", function()
            if lp then
                TeleportService:Teleport(game.PlaceId, lp)
            end
        end)

        local klzeBox = tab:AddLeftGroupbox("KLZE Hub", "sparkles")
        klzeBox:AddLabel(blurb)
        klzeBox:AddLabel("More scripts on the site — all keyless.")
        klzeBox:AddLabel("Version: v" .. version)
        klzeBox:AddLabel("Site: " .. site)

        klzeBox:AddButton("Copy Discord invite", function()
            if copyToClipboard(discord) then
                Hub.notify(Library, "Discord invite copied", 3)
            end
        end)

        klzeBox:AddButton("Copy website URL", function()
            if copyToClipboard(site) then
                Hub.notify(Library, "Website URL copied", 2)
            end
        end)

        return tab
    end

    function Hub.complete(Window, Library, SaveManager, ThemeManager, options)
        options = options or {}
        local discord = options.DiscordInvite or DEFAULT_DISCORD
        local site = options.SiteUrl or DEFAULT_SITE
        local uiTab = Window:AddTab("UI Settings", "settings")
        local menuBox = uiTab:AddLeftGroupbox("Menu", "wrench")
        menuBox:AddToggle("KlzeAntiAfk", {
            Text = "Anti-AFK",
            Default = true,
            Callback = function(v)
                Hub.setAntiAfk(v)
            end,
        })
        menuBox:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
            Default = options.ToggleKeybind or "RightControl",
            NoUI = true,
            Text = "Menu keybind",
            ChangedCallback = function()
                Library.ToggleKeybind = Library.Options.MenuKeybind
            end,
        })
        menuBox:AddDivider()
        menuBox:AddLabel("Discord: " .. discord)
        menuBox:AddLabel("Website: " .. site)
        menuBox:AddButton("Copy Discord invite", function()
            if copyToClipboard(discord) then
                Hub.notify(Library, "Discord invite copied", 3)
            end
        end)
        menuBox:AddButton("Copy website URL", function()
            if copyToClipboard(site) then
                Hub.notify(Library, "Website URL copied", 2)
            end
        end)
        menuBox:AddDivider()
        menuBox:AddButton("Unload script", function()
            if typeof(getgenv) == "function" and type(getgenv().KLZE_PYRAMID_UNLOAD) == "function" then
                getgenv().KLZE_PYRAMID_UNLOAD()
            elseif Library.Unload then
                Library:Unload()
            end
        end)
        ThemeManager:ApplyToTab(uiTab)
        SaveManager:BuildConfigSection(uiTab)
        SaveManager:LoadAutoloadConfig()
        Library.ToggleKeybind = Library.Options.MenuKeybind or Enum.KeyCode.RightControl
        task.defer(function()
            Hub.setAntiAfk(true)
            if options.Heartbeat ~= false then
                Hub.startPresence({
                    gameTitle = options.Game or options.GameTitle,
                    version = options.Version,
                })
            end
            if Library.Toggle and Library.Unloaded ~= true then
                Library:Toggle(true)
            end
        end)
        return uiTab
    end

    return Hub
end

local function loadHub()
    if typeof(getgenv) == "function" then
        local cached = getgenv().KLZE_HUB_WINDOW
        if validHub(cached) then
            return cached
        end
        getgenv().KLZE_HUB_WINDOW = nil
    end

    local inline = buildInlineHub()
    if typeof(getgenv) == "function" then
        getgenv().KLZE_HUB_WINDOW = inline
    end

    local useApi = typeof(getgenv) == "function" and getgenv().KLZE_USE_API_HUB_WINDOW == true
    if not useApi then
        return inline
    end

    local urls = { API_URL .. "/hub-window?k=1", "https://klze-hub.pages.dev/hub-window?k=1" }
    for _, url in ipairs(urls) do
        local hub = httpGetHubWindow(url)
        if hub then
            if typeof(getgenv) == "function" then
                getgenv().KLZE_HUB_WINDOW = hub
            end
            return hub
        end
    end

    return inline
end

local function waitForInteraction()
    local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
    pcall(function()
        if Knit.OnStart then
            Knit.OnStart():await()
        end
    end)
    local deadline = os.clock() + 90
    while os.clock() < deadline do
        local ok, ctrl = pcall(function()
            return Knit.GetController("InteractionController")
        end)
        if ok and type(ctrl) == "table" and ctrl._runtime then
            return ctrl, ctrl._runtime
        end
        task.wait(0.25)
    end
    return nil, nil
end

local function getInteractionRuntimeModule()
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    if not ps then
        return nil
    end
    local utils = ps:FindFirstChild("Utils")
    if not utils then
        return nil
    end
    local interaction = utils:FindFirstChild("Interaction")
    if not interaction then
        return nil
    end
    local mod = interaction:FindFirstChild("InteractionRuntime")
    if not mod then
        return nil
    end
    local ok, lib = pcall(require, mod)
    if ok then
        return lib
    end
    return nil
end

local function readCanonicalCarryCount()
    local ok, cnt = pcall(function()
        local CarryState = require(ReplicatedStorage.Shared.CarryState)
        return CarryState.readCount(LocalPlayer)
    end)
    if ok and type(cnt) == "number" then
        return cnt
    end
    local raw = LocalPlayer:GetAttribute("CarryState")
    if type(raw) == "string" then
        local _, c = string.match(raw, "^(%d+):(%d+)")
        if c then
            return tonumber(c)
        end
    end
    local legacy = LocalPlayer:GetAttribute("CarriedCount")
    if type(legacy) == "number" then
        return legacy
    end
    return nil
end

local function getCarriedCount()
    local IR = getInteractionRuntimeModule()
    if IR and type(IR.getLogicalCarriedCount) == "function" then
        local ok, n = pcall(IR.getLogicalCarriedCount, LocalPlayer)
        if ok and type(n) == "number" then
            return n
        end
    end
    return readCanonicalCarryCount() or 0
end

local function getCapacitySnapshot()
    local IR = getInteractionRuntimeModule()
    if not IR then
        local carried = readCanonicalCarryCount() or 0
        local capText = "?"
        if Farm.capacityOverride and Farm.capacityOverride > 0 then
            capText = tostring(Farm.capacityOverride)
        end
        return tonumber(carried) or 0, nil, capText
    end
    local policy = IR.getCarryCapacityPolicy(LocalPlayer)
    local carried = getCarriedCount()
    local capText
    if Farm.capacityOverride and Farm.capacityOverride > 0 then
        capText = tostring(Farm.capacityOverride)
        if not policy.isUnlimited and policy.capacity then
            capText = capText .. " (game " .. tostring(policy.capacity) .. ")"
        end
    elseif policy.isUnlimited then
        capText = "∞"
    else
        capText = tostring(policy.capacity)
    end
    return carried, policy.capacity, capText
end

local function getHumanoid()
    local char = LocalPlayer.Character
    if not char then
        return nil
    end
    return char:FindFirstChildOfClass("Humanoid")
end

local function getHRP()
    local char = LocalPlayer.Character
    if not char then
        return nil
    end
    return char:FindFirstChild("HumanoidRootPart")
end

local function getActiveRuntime()
    if typeof(getgenv) ~= "function" then
        return nil
    end
    local ctrl = getgenv().KLZE_PYRAMID_CTRL
    if type(ctrl) == "table" and ctrl._runtime then
        return ctrl._runtime
    end
    return nil
end

-- Contagem real do jogo (inclui pickup in-flight), não só o atributo.
local function getRuntimePickupCount(runtime)
    runtime = runtime or getActiveRuntime()
    if runtime and type(runtime._getPickupCount) == "function" then
        local ok, n = pcall(function()
            return runtime:_getPickupCount()
        end)
        if ok and type(n) == "number" then
            return math.max(0, math.floor(n))
        end
    end
    return getCarriedCount()
end

local function getRuntimeInventoryCount(runtime)
    runtime = runtime or getActiveRuntime()
    if runtime and type(runtime._getInventoryCount) == "function" then
        local ok, n = pcall(function()
            return runtime:_getInventoryCount()
        end)
        if ok and type(n) == "number" then
            return math.max(0, math.floor(n))
        end
    end
    return getCarriedCount()
end

local function hasBlocksToPlace(runtime)
    runtime = runtime or getActiveRuntime()
    if runtime and type(runtime._canPlaceWithCount) == "function" then
        local ok, canPlace = pcall(function()
            return runtime:_canPlaceWithCount()
        end)
        if ok and canPlace == true then
            return true
        end
    end
    return getRuntimeInventoryCount(runtime) > 0
end

local function getRegionRegistry()
    return require(ReplicatedStorage.Shared.RegionRegistry)
end

local function regionFocusCFrame(regionId)
    local ok, cf = pcall(function()
        local RR = getRegionRegistry()
        local target = RR.getPart(regionId)
        if not target then
            return nil
        end
        if target:IsA("BasePart") then
            return target.CFrame + Vector3.new(0, 5, 0)
        end
        if target:IsA("Model") then
            local pivot = target:GetPivot()
            return pivot + Vector3.new(0, 5, 0)
        end
        return nil
    end)
    if ok then
        return cf
    end
    return nil
end

local function isInRegion(regionId)
    local hrp = getHRP()
    if not hrp then
        return false
    end
    local ok, inside = pcall(function()
        return getRegionRegistry().isWithin(regionId, hrp.Position, Workspace)
    end)
    return ok and inside == true
end

local function teleportToRegion(regionId)
    local now = os.clock()
    if now - Farm.lastTp < getFarmTpCooldown() then
        return false
    end
    local hrp = getHRP()
    local cf = regionFocusCFrame(regionId)
    if not hrp or not cf then
        return false
    end
    Farm.lastTp = now
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = cf
    end)
    return true
end

local function getOutstandingPlaceCount(runtime)
    if not runtime or type(runtime._outstandingPlaceCount) ~= "function" then
        return 0
    end
    local ok, n = pcall(function()
        return runtime:_outstandingPlaceCount()
    end)
    if ok and type(n) == "number" then
        return math.max(0, math.floor(n))
    end
    return 0
end

local function getPlaceRangeForPlayer()
    local PlacementRange = require(ReplicatedStorage.Shared.Placement.PlacementRange)
    local PyramidConfig = require(ReplicatedStorage.Shared.Config.PyramidConfig)
    return PlacementRange.forPlayer(LocalPlayer, PyramidConfig.PlaceDistance)
end

local function pyramidReservedFn(runtime)
    return function(layer, slotIndex)
        return runtime:_isSlotReserved(layer, slotIndex)
    end
end

local function reconcilePyramidSlot(runtime, expandedSearch)
    if not runtime then
        return nil
    end

    pcall(function()
        if runtime._pruneFilledReservations then
            runtime:_pruneFilledReservations()
        end
    end)

    local slot
    pcall(function()
        if runtime._findFreePyramidSlot then
            slot = runtime:_findFreePyramidSlot()
        end
    end)
    if slot and slot.position then
        return slot
    end

    pcall(function()
        if runtime._updatePyramidGhost and runtime._getTopHeldItem then
            runtime:_updatePyramidGhost(runtime:_getTopHeldItem())
        elseif runtime._updatePyramidGhost then
            runtime:_updatePyramidGhost(nil)
        end
    end)

    local cached = runtime._pyramidSlot
    if type(cached) == "table" and cached.position then
        return cached
    end

    local PyramidRuntime = require(ReplicatedStorage.Shared.Placement.PyramidRuntime)
    local PyramidConfig = require(ReplicatedStorage.Shared.Config.PyramidConfig)
    local placeRange = getPlaceRangeForPlayer()
    local blockSize = math.max(tonumber(PyramidConfig.BlockSize) or 4, 1)
    local baseRing = tonumber(PyramidConfig.FreeSlotSearchRadius)
        or (math.ceil(placeRange / blockSize) + 8)
    local ringRadius = expandedSearch and math.min(baseRing + 20, 56) or baseRing
    local reservedFn = pyramidReservedFn(runtime)

    local origins = {}
    local hrp = getHRP()
    if hrp then
        table.insert(origins, hrp.Position)
    end
    local ctx = PyramidRuntime.getContext(Workspace)
    if ctx and ctx.model then
        table.insert(origins, ctx.model:GetPivot().Position)
    end

    for _, origin in origins do
        local ok, found = pcall(function()
            return PyramidRuntime.resolveNearestSlot(origin, Workspace, reservedFn, ringRadius)
        end)
        if ok and found and found.position then
            return found
        end
    end

    return nil
end

local function getNavigationRingRadius(ctx)
    local PyramidConfig = require(ReplicatedStorage.Shared.Config.PyramidConfig)
    local model = ctx.model
    local layer = model:GetAttribute(PyramidConfig.CurrentLayerAttribute)
    if layer == nil or not ctx.geometry.isLayer(layer) then
        return tonumber(PyramidConfig.FreeSlotSearchRadius) or 48
    end
    local side = ctx.geometry.getLayerSide(layer)
    return math.min(math.ceil(side * 0.55) + 6, 96)
end

-- Free slot anywhere on the current layer (from pyramid pivot). For TP only, not place-range limited.
local function findNavigationPyramidSlot(runtime, expanded)
    if not runtime then
        return nil
    end

    local now = os.clock()
    if not expanded and Farm.cachedNavSlot and Farm.cachedNavSlot.position and (now - Farm.lastNavSlotAt) < 0.08 then
        local s = Farm.cachedNavSlot
        local reserved = false
        pcall(function()
            if runtime._isSlotReserved and s.layer and s.slotIndex then
                reserved = runtime:_isSlotReserved(s.layer, s.slotIndex)
            end
        end)
        if not reserved then
            return s
        end
    end

    if now - Farm.lastPruneSync >= 0.12 then
        Farm.lastPruneSync = now
        pcall(function()
            if runtime._pruneFilledReservations then
                runtime:_pruneFilledReservations()
            end
        end)
    end

    local PyramidRuntime = require(ReplicatedStorage.Shared.Placement.PyramidRuntime)
    local ctx = PyramidRuntime.getContext(Workspace)
    if not ctx or not ctx.model then
        return nil
    end

    local ring = getNavigationRingRadius(ctx)
    if expanded then
        ring = math.min(ring + 24, 120)
    end

    local reservedFn = pyramidReservedFn(runtime)
    local pivot = ctx.model:GetPivot().Position

    local function query(origin)
        local ok, found = pcall(function()
            return PyramidRuntime.resolveNearestSlot(origin, Workspace, reservedFn, ring)
        end)
        if ok and found and found.position then
            return found
        end
        return nil
    end

    local hrp = getHRP()
    if hrp then
        local near = query(hrp.Position)
        if near then
            Farm.cachedNavSlot = near
            Farm.lastNavSlotAt = now
            return near
        end
    end

    local found = query(pivot)
    if found then
        Farm.cachedNavSlot = found
        Farm.lastNavSlotAt = now
    end
    return found
end

local function findPyramidPlaceSlotLight(runtime)
    if not runtime then
        return nil
    end
    return reconcilePyramidSlot(runtime, false)
end

local function isStrictLayerEndgame(runtime)
    local gentle = (10 - farmSpeedN()) / 9
    local stuckHigh = math.max(2, math.ceil(6 - 4 * gentle))
    local stuckMed = math.max(2, math.ceil(4 - 2 * gentle))
    local stuckLow = math.max(2, math.ceil(5 - 3 * gentle))
    local outstandingHigh = math.max(4, math.ceil(14 - 10 * gentle))
    local outstandingMed = math.max(3, math.ceil(8 - 4 * gentle))

    local outstanding = getOutstandingPlaceCount(runtime)
    if Farm.placeStuckTicks >= stuckHigh then
        return true
    end
    if Farm.placeStuckTicks >= stuckMed and outstanding >= outstandingMed then
        return true
    end
    if outstanding >= outstandingHigh then
        return true
    end
    if Farm.placeStuckTicks >= stuckLow and not findPyramidPlaceSlotLight(runtime) then
        return true
    end
    return false
end

local function getPlaceBurstLimit(runtime)
    if isStrictLayerEndgame(runtime) then
        return AntiLag.isNormal and 3 or 1
    end
    return scaledFarmBurst(BURST_PLACE)
end

local function getPlaceRetryDelay(runtime)
    if not isStrictLayerEndgame(runtime) then
        return FARM_PLACE_COOLDOWN
    end
    local outstanding = getOutstandingPlaceCount(runtime)
    if outstanding >= (AntiLag.isNormal and 16 or 12) then
        return AntiLag.isNormal and 0.3 or 0.5
    end
    if Farm.placeStuckTicks >= 6 then
        return AntiLag.isNormal and 0.2 or FARM_LAYER_ENDGAME_COOLDOWN
    end
    return AntiLag.isNormal and 0.07 or 0.14
end

local FARM_GHOST_SYNC_INTERVAL = 0.22
local FARM_PRUNE_SYNC_INTERVAL = 0.14

local function syncGamePyramidTarget(runtime, forceGhost)
    if not runtime then
        return
    end
    local now = os.clock()
    if forceGhost or now - Farm.lastPruneSync >= FARM_PRUNE_SYNC_INTERVAL then
        Farm.lastPruneSync = now
        pcall(function()
            if runtime._pruneFilledReservations then
                runtime:_pruneFilledReservations()
            end
        end)
    end
    if forceGhost or now - Farm.lastGhostSync >= FARM_GHOST_SYNC_INTERVAL then
        Farm.lastGhostSync = now
        pcall(function()
            if runtime._updatePyramidGhost then
                local top
                if runtime._getTopHeldItem then
                    top = runtime:_getTopHeldItem()
                end
                runtime:_updatePyramidGhost(top)
            end
        end)
    end
end

local function refreshPyramidPlacementState(runtime, forceGhost)
    syncGamePyramidTarget(runtime, forceGhost == true)
end

local function findPyramidPlaceSlot(runtime)
    if not runtime then
        return nil, nil
    end

    local expanded = Farm.placeStuckTicks >= 2
    local slot = reconcilePyramidSlot(runtime, expanded)
    local placeRange = getPlaceRangeForPlayer()
    return slot, placeRange
end

local function isWithinPlaceRange(slot, placeRange)
    local hrp = getHRP()
    if not hrp or not slot or not slot.position then
        return false
    end
    return (hrp.Position - slot.position).Magnitude <= placeRange * 0.98
end

local heldItemTagCached

local function getHeldItemTag()
    if heldItemTagCached then
        return heldItemTagCached
    end
    local ok, tagNames = pcall(function()
        return require(ReplicatedStorage.Shared.Constants.TagNames)
    end)
    if ok and type(tagNames) == "table" and type(tagNames.HeldItem) == "string" then
        heldItemTagCached = tagNames.HeldItem
    else
        heldItemTagCached = "HeldItem"
    end
    return heldItemTagCached
end

local function isBookPilePart(inst)
    if not inst or inst == Workspace then
        return false
    end
    local tag = getHeldItemTag()
    local cur = inst
    for _ = 1, 8 do
        if not cur or cur == Workspace then
            break
        end
        local tagged = false
        pcall(function()
            tagged = CollectionService:HasTag(cur, tag)
        end)
        if tagged then
            return true
        end
        local carriedBy
        pcall(function()
            carriedBy = cur:GetAttribute("CarriedBy")
        end)
        if carriedBy ~= nil then
            return true
        end
        local n = string.lower(tostring(cur.Name))
        if string.find(n, "book", 1, true) or string.find(n, "helditem", 1, true) then
            return true
        end
        cur = cur.Parent
    end
    return false
end

local function collectHeldItemIgnore()
    local ignore = {}
    local char = LocalPlayer.Character
    if char then
        table.insert(ignore, char)
    end
    pcall(function()
        for _, inst in CollectionService:GetTagged(getHeldItemTag()) do
            table.insert(ignore, inst)
        end
    end)
    return ignore
end

local function raycastStandPosition(planarPos, hrp)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = collectHeldItemIgnore()

    local hip = 3
    if hrp then
        hip = hrp.Size.Y * 0.5 + 0.35
    end

    local rayHigh = math.max(planarPos.Y + 6, 8)
    local origin = Vector3.new(planarPos.X, rayHigh + 20, planarPos.Z)
    local hit = Workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
    if hit then
        return Vector3.new(planarPos.X, hit.Position.Y + hip, planarPos.Z)
    end
    return Vector3.new(planarPos.X, planarPos.Y + hip, planarPos.Z)
end

local function teleportToPlaceSlot(slot, placeRange)
    if not slot or not slot.position or not placeRange then
        return false
    end
    if isWithinPlaceRange(slot, placeRange) then
        return true
    end

    local now = os.clock()
    if now - Farm.lastTp < getFarmTpCooldown() then
        return false
    end

    local hrp = getHRP()
    if not hrp then
        return false
    end

    local slotPos = slot.position
    local PyramidRuntime = require(ReplicatedStorage.Shared.Placement.PyramidRuntime)
    local model = PyramidRuntime.getModel(Workspace)
    local center = model and model:GetPivot().Position or slotPos

    local outward = Vector3.new(slotPos.X - center.X, 0, slotPos.Z - center.Z)
    if outward.Magnitude < 1 then
        outward = Vector3.new(1, 0, 0)
    else
        outward = outward.Unit
    end

    -- Perto o bastante pro PlaceDistance, em pé na superfície (sem cair do céu).
-- MODIFICADO: pararse en el centro si el slot alcanza; si no, lo mínimo hacia el slot
local toSlot = Vector3.new(slotPos.X - center.X, 0, slotPos.Z - center.Z)
local reach = placeRange * 0.85
local centerFlat = Vector3.new(center.X, slotPos.Y, center.Z)
local planar
if toSlot.Magnitude <= reach then
    planar = centerFlat
else
    planar = centerFlat + outward * (toSlot.Magnitude - reach)
end
local stand = raycastStandPosition(planar, hrp)

Farm.lastTp = now
pcall(function()
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    hrp.CFrame = CFrame.lookAt(stand, Vector3.new(slotPos.X, stand.Y, slotPos.Z))
end)
    return true
end

local function teleportToPyramidSlotForFarm(runtime)
    local placeRange = getPlaceRangeForPlayer()
    local slot = findNavigationPyramidSlot(runtime, true)
    if not slot then
        slot = reconcilePyramidSlot(runtime, true)
    end
    if not slot then
        return false
    end
    return teleportToPlaceSlot(slot, placeRange)
end

local function markFarmProgressIfChanged(runtime)
    local carried = getRuntimePickupCount(runtime)
    if carried ~= Farm.lastCarriedSeen then
        Farm.lastCarriedSeen = carried
        Farm.lastProgressAt = os.clock()
        return true
    end
    return false
end

local function playerHorizIdle()
    local hrp = getHRP()
    if not hrp then
        return false
    end
    local v = hrp.AssemblyLinearVelocity
    return Vector3.new(v.X, 0, v.Z).Magnitude < 1.35
end

local function isPerchedOnBlockPile()
    local hrp = getHRP()
    if not hrp then
        return false
    end
    local charIgnore = {}
    if LocalPlayer.Character then
        table.insert(charIgnore, LocalPlayer.Character)
    end
    local paramsOn = RaycastParams.new()
    paramsOn.FilterType = Enum.RaycastFilterType.Exclude
    paramsOn.FilterDescendantsInstances = charIgnore
    local onPile = Workspace:Raycast(hrp.Position, Vector3.new(0, -14, 0), paramsOn)
    if onPile and isBookPilePart(onPile.Instance) then
        return true
    end
    local paramsFloor = RaycastParams.new()
    paramsFloor.FilterType = Enum.RaycastFilterType.Exclude
    paramsFloor.FilterDescendantsInstances = collectHeldItemIgnore()
    local floor = Workspace:Raycast(hrp.Position, Vector3.new(0, -40, 0), paramsFloor)
    if onPile and floor then
        return (floor.Position.Y - onPile.Position.Y) > 2.2
    end
    return false
end

local function planarLook(hrp)
    local look = hrp.CFrame.LookVector
    local planar = Vector3.new(look.X, 0, look.Z)
    if planar.Magnitude < 0.15 then
        return Vector3.new(1, 0, 0)
    end
    return planar.Unit
end

local function nudgeOffBlockPile()
    local now = os.clock()
    if now - Farm.lastNudgeAt < FARM_NUDGE_COOLDOWN then
        return false
    end
    local hrp = getHRP()
    if not hrp then
        return false
    end
    local look = planarLook(hrp)
    local right = Vector3.new(-look.Z, 0, look.X)
    local offsets = {
        look * 5.5,
        -look * 5.5,
        right * 5.5,
        -right * 5.5,
        (look + right).Unit * 6,
        (look - right).Unit * 6,
    }
    for _, offset in offsets do
        local probe = hrp.Position + offset
        local stand = raycastStandPosition(probe, hrp)
        if stand and math.abs(stand.Y - hrp.Position.Y) < 18 then
            Farm.lastNudgeAt = now
            pcall(function()
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
                hrp.CFrame = CFrame.lookAt(stand, stand + look)
            end)
            local hum = getHumanoid()
            if hum then
                pcall(function()
                    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                end)
            end
            return true
        end
    end
    Farm.lastNudgeAt = now
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = hrp.CFrame + look * 4.5 + Vector3.new(0, 1.25, 0)
    end)
    return true
end

local function maybeUnstickFarmPile(runtime)
    if not Farm.enabled or PlayerMods.fly then
        return
    end
    local now = os.clock()
    if now - Farm.lastNudgeAt < FARM_NUDGE_COOLDOWN then
        return
    end
    markFarmProgressIfChanged(runtime)
    if now - Farm.lastProgressAt < FARM_PILE_IDLE then
        return
    end
    if not playerHorizIdle() then
        return
    end
    if now < Farm.nextPileCheck then
        return
    end
    Farm.nextPileCheck = now + 0.2
    if not isPerchedOnBlockPile() then
        return
    end
    nudgeOffBlockPile()
end

local function applyWalkAndJump()
    local hum = getHumanoid()
    if not hum then
        return
    end
    pcall(function()
        hum.WalkSpeed = PlayerMods.walkSpeed
        if hum.UseJumpPower then
            hum.JumpPower = PlayerMods.jumpHeight
        else
            hum.JumpHeight = PlayerMods.jumpHeight
        end
    end)
end

local function stopPlayerMods()
    if PlayerMods.flyConn then
        PlayerMods.flyConn:Disconnect()
        PlayerMods.flyConn = nil
    end
    if PlayerMods.jumpConn then
        PlayerMods.jumpConn:Disconnect()
        PlayerMods.jumpConn = nil
    end
    if PlayerMods.charConn then
        PlayerMods.charConn:Disconnect()
        PlayerMods.charConn = nil
    end
end

local function bindCharacter()
    applyWalkAndJump()
    local hum = getHumanoid()
    if hum and PlayerMods.infJump and not PlayerMods.jumpConn then
        PlayerMods.jumpConn = UserInputService.JumpRequest:Connect(function()
            if not PlayerMods.infJump then
                return
            end
            pcall(function()
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end)
        end)
    end
end

local function startPlayerMods()
    stopPlayerMods()
    bindCharacter()
    PlayerMods.charConn = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.2)
        bindCharacter()
    end)

    if PlayerMods.flyConn then
        PlayerMods.flyConn:Disconnect()
    end
    PlayerMods.flyConn = RunService.RenderStepped:Connect(function(dt)
        if not PlayerMods.fly then
            return
        end
        local hrp = getHRP()
        local hum = getHumanoid()
        local cam = Workspace.CurrentCamera
        if not hrp or not hum or not cam then
            return
        end
        hum.PlatformStand = true
        local move = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then
            move += cam.CFrame.LookVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then
            move -= cam.CFrame.LookVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then
            move -= cam.CFrame.RightVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then
            move += cam.CFrame.RightVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            move += Vector3.yAxis
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
            move -= Vector3.yAxis
        end
        if move.Magnitude > 0 then
            move = move.Unit
        end
        local speed = PlayerMods.flySpeed
        hrp.AssemblyLinearVelocity = move * speed
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
end

local function setFly(on)
    PlayerMods.fly = on == true
    local hum = getHumanoid()
    if hum then
        hum.PlatformStand = PlayerMods.fly
        if not PlayerMods.fly then
            hum.PlatformStand = false
            applyWalkAndJump()
            local hrp = getHRP()
            if hrp then
                hrp.AssemblyLinearVelocity = Vector3.zero
            end
        end
    end
end

local function getTargetCapacity()
    local override = Farm.capacityOverride
    if type(override) == "number" and override > 0 then
        return math.floor(override)
    end
    local IR = getInteractionRuntimeModule()
    if not IR then
        return nil
    end
    local policy = IR.getCarryCapacityPolicy(LocalPlayer)
    if policy.isUnlimited then
        return nil
    end
    if type(policy.capacity) == "number" and policy.capacity > 0 then
        return policy.capacity
    end
    return nil
end

local function canPickupMore()
    local runtime = getActiveRuntime()
    local carried = getRuntimePickupCount(runtime)
    local target = getTargetCapacity()
    if type(target) == "number" then
        return carried < target
    end
    local IR = getInteractionRuntimeModule()
    if not IR then
        return true
    end
    local CarryCapacityPolicy = require(
        LocalPlayer.PlayerScripts.Utils.CarryCapacityPolicy
    )
    local policy = IR.getCarryCapacityPolicy(LocalPlayer)
    if policy.isUnlimited then
        return true
    end
    return CarryCapacityPolicy.canPickup(policy, carried)
end

local function shouldDrainToPyramid(runtime)
    if Farm.placingRun then
        return hasBlocksToPlace(runtime)
    end
    local carried = getRuntimePickupCount(runtime)
    if carried <= 0 then
        return false
    end
    local target = getTargetCapacity()
    if type(target) == "number" and carried >= target then
        return true
    end
    return not canPickupMore()
end

local function tryQuarryGrant()
    if Farm.quarryInFlight >= MAX_QUARRY_IN_FLIGHT or not canPickupMore() then
        return false
    end
    local runtime = getActiveRuntime()
    if runtime and runtime._gameplayBlocked then
        return false
    end
    local ok, result = pcall(function()
        local RegionRegistry = require(ReplicatedStorage.Shared.RegionRegistry)
        local KnitClientServices = require(ReplicatedStorage.Shared.KnitClientServices)
        local part = RegionRegistry.getPart(RegionRegistry.Ids.Quarry)
        local services = KnitClientServices.get()
        local blockService = services and (services.BlockService or services.BookService)
        if not blockService then
            local okKnit, svc = pcall(function()
                local Knit = require(ReplicatedStorage.Packages.Knit)
                return Knit.GetService("BlockService")
            end)
            if okKnit and svc then
                blockService = svc
            end
        end
        if not part or not blockService then
            return false
        end
        Farm.quarryInFlight += 1
        local released = false
        local function releaseQuarrySlot()
            if released then
                return
            end
            released = true
            Farm.quarryInFlight = math.max(0, Farm.quarryInFlight - 1)
        end
        local function onPickupResolved(okGrant, receipt)
            if okGrant and type(receipt) == "string" then
                pcall(function()
                    local CarryState = require(ReplicatedStorage.Shared.CarryState)
                    CarryState.observe(LocalPlayer, receipt)
                end)
                local rt = getActiveRuntime()
                if rt and type(rt._adoptCarryReceipt) == "function" then
                    pcall(rt._adoptCarryReceipt, rt, receipt)
                end
            end
            releaseQuarrySlot()
        end
        local req = blockService:Pickup(part)
        if req and type(req.andThen) == "function" then
            req:andThen(onPickupResolved):catch(releaseQuarrySlot)
        elseif req and type(req.finally) == "function" then
            req:finally(releaseQuarrySlot)
        else
            releaseQuarrySlot()
        end
        return true
    end)
    return ok and result == true
end

local function stopFarmLoop()
    if Farm.conn then
        Farm.conn:Disconnect()
        Farm.conn = nil
    end
    if Farm.hbConn then
        Farm.hbConn:Disconnect()
        Farm.hbConn = nil
    end
    Farm.quarryInFlight = 0
end

local function bindCoinStatObserver()
    if AutoUpgrade.coinObserverBound then
        return
    end
    AutoUpgrade.coinObserverBound = true
    task.spawn(function()
        local Knit = require(ReplicatedStorage.Packages.Knit)
        local ready = false
        pcall(function()
            Knit.OnStart():andThen(function()
                ready = true
            end)
        end)
        local deadline = os.clock() + 45
        while not ready and os.clock() < deadline do
            task.wait(0.25)
        end
        local ok, dataService = pcall(function()
            return Knit.GetService("DataService")
        end)
        if not ok or not dataService then
            return
        end
        if dataService.StatValues then
            pcall(function()
                dataService.StatValues:Observe(function(values)
                    if type(values) == "table" then
                        if values.Coins ~= nil then
                            AutoUpgrade.cachedCoins = values.Coins
                        end
                        if values.CandyCorn ~= nil then
                            AutoUpgrade.cachedCandyCorn = values.CandyCorn
                        end
                    end
                end)
            end)
        end
        pcall(function()
            if dataService.GetCoins then
                dataService:GetCoins():andThen(function(c)
                    if c ~= nil then
                        AutoUpgrade.cachedCoins = c
                    end
                end)
            end
            if dataService.CoinsUpdated then
                dataService.CoinsUpdated:Connect(function(c)
                    if c ~= nil then
                        AutoUpgrade.cachedCoins = c
                    end
                end)
            end
            if dataService.GetCandyCorn then
                dataService:GetCandyCorn():andThen(function(cc)
                    if cc ~= nil then
                        AutoUpgrade.cachedCandyCorn = cc
                    end
                end)
            end
            if dataService.CandyCornUpdated then
                dataService.CandyCornUpdated:Connect(function(cc)
                    if cc ~= nil then
                        AutoUpgrade.cachedCandyCorn = cc
                    end
                end)
            end
        end)
    end)
end

local function getSpendableCoins()
    local StatProgression = require(ReplicatedStorage.Shared.Stats.StatProgression)
    local StatValue = require(ReplicatedStorage.Shared.Stats.StatValue)
    local CoinCreditQueue = require(ReplicatedStorage.Shared.UI.State.CoinCreditQueue)

    local raw = AutoUpgrade.cachedCoins
    if raw == nil then
        pcall(function()
            local PetState = require(ReplicatedStorage.Shared.UI.State.PetState)
            raw = PetState.coins()
        end)
    end
    if raw == nil then
        return nil
    end

    local coins = StatProgression.normalizeValue(raw)
    local pending = CoinCreditQueue.pending()
    if type(pending) == "number" and pending > 0 then
        coins = StatValue.subtractInteger(coins, pending) or coins
    end
    return coins
end

local function getSpendableCandyCorn()
    local StatProgression = require(ReplicatedStorage.Shared.Stats.StatProgression)
    local raw = AutoUpgrade.cachedCandyCorn
    if raw == nil then
        pcall(function()
            local PetState = require(ReplicatedStorage.Shared.UI.State.PetState)
            raw = PetState.candyCorn()
        end)
    end
    if raw == nil then
        return nil
    end
    return StatProgression.normalizeValue(raw)
end

local function canAffordCoinCost(balance, cost)
    if balance == nil or type(cost) ~= "number" or cost <= 0 then
        return false
    end
    local StatValue = require(ReplicatedStorage.Shared.Stats.StatValue)
    return StatValue.compare(balance, cost) >= 0
end

local function isUpgradePurchasePending()
    local ok, pending = pcall(function()
        local UpgradeMenuState = require(ReplicatedStorage.Shared.UI.State.UpgradeMenuState)
        local src = UpgradeMenuState.pending()
        if type(src) == "function" then
            return src()
        end
        return nil
    end)
    return ok and pending ~= nil
end

local function autoUpgradeAnyEnabled()
    for _, upgradeId in AUTO_UPGRADE_ORDER do
        if AutoUpgrade.picks[upgradeId] then
            return true
        end
    end
    return false
end

local function getCandidateUpgradeCurrencies()
    local isHalloween = (game.PlaceId == HALLOWEEN_PLACE_ID)
    local mode = AutoUpgrade.currencyMode or "Auto"
    if mode == "Coins" then
        return { "Coins" }
    elseif mode == "CandyCorn" then
        return isHalloween and { "CandyCorn" } or { "Coins" }
    elseif mode == "Both" then
        return isHalloween and { "CandyCorn", "Coins" } or { "Coins" }
    else
        return isHalloween and { "CandyCorn", "Coins" } or { "Coins" }
    end
end

local function tryPurchaseAffordableUpgrade()
    if not autoUpgradeAnyEnabled() or isUpgradePurchasePending() then
        return false
    end

    local UpgradeLevels = require(ReplicatedStorage.Shared.Upgrades.UpgradeLevels)
    local UpgradeMenuState = require(ReplicatedStorage.Shared.UI.State.UpgradeMenuState)

    pcall(function()
        UpgradeMenuState.start()
    end)

    local currencies = getCandidateUpgradeCurrencies()
    for _, curr in ipairs(currencies) do
        local balance = (curr == "CandyCorn") and getSpendableCandyCorn() or getSpendableCoins()
        if balance ~= nil then
            for _, upgradeId in ipairs(AUTO_UPGRADE_ORDER) do
                if AutoUpgrade.picks[upgradeId] then
                    local level = UpgradeLevels.fromPlayer(LocalPlayer, upgradeId)
                    if not UpgradeLevels.isMaxed(upgradeId, level) then
                        local cost = UpgradeLevels.costToNext(upgradeId, level, curr)
                        if canAffordCoinCost(balance, cost) then
                            pcall(function()
                                if UpgradeMenuState.setCurrency then
                                    UpgradeMenuState.setCurrency(curr)
                                end
                            end)
                            UpgradeMenuState.purchase(upgradeId)
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

local function tickAutoUpgrade()
    if not autoUpgradeAnyEnabled() then
        return
    end
    local now = os.clock()
    if now - AutoUpgrade.lastTick < AUTO_UPGRADE_INTERVAL then
        return
    end
    AutoUpgrade.lastTick = now
    bindCoinStatObserver()
    tryPurchaseAffordableUpgrade()
end

local function stopAutoUpgradeLoop()
    if AutoUpgrade.conn then
        AutoUpgrade.conn:Disconnect()
        AutoUpgrade.conn = nil
    end
end

local function startAutoUpgradeLoop()
    stopAutoUpgradeLoop()
    bindCoinStatObserver()
    AutoUpgrade.conn = RunService.Heartbeat:Connect(tickAutoUpgrade)
    tickAutoUpgrade()
end

local function syncAutoUpgradeLoop()
    if autoUpgradeAnyEnabled() then
        startAutoUpgradeLoop()
    else
        stopAutoUpgradeLoop()
    end
end

local function setAutoUpgradePick(upgradeId, on)
    if AutoUpgrade.picks[upgradeId] == nil then
        return
    end
    AutoUpgrade.picks[upgradeId] = on == true
    syncAutoUpgradeLoop()
end

local function refreshAutoUpgradeFromSavedToggles()
    local toggles = rawget(_G, "Toggles")
    if type(toggles) ~= "table" then
        syncAutoUpgradeLoop()
        return
    end
    local map = {
        klze_auto_upgrade_bulk_pickup = "bulkPickup",
        klze_auto_upgrade_bulk_place = "bulkPlace",
        klze_auto_upgrade_placement_range = "placementRange",
    }
    for toggleKey, upgradeId in pairs(map) do
        local toggle = toggles[toggleKey]
        if toggle and toggle.Value == true then
            AutoUpgrade.picks[upgradeId] = true
        end
    end
    syncAutoUpgradeLoop()
end

local function getPyramidCompletions()
    local ok, n = pcall(function()
        local ClientContracts = require(ReplicatedStorage.Shared.Contracts.ClientContracts)
        local attr = ClientContracts.Attributes.Player.Pyramids
        local v = LocalPlayer:GetAttribute(attr)
        if type(v) == "number" and v >= 0 and v % 1 == 0 then
            return v
        end
        v = LocalPlayer:GetAttribute("Pyramids")
        if type(v) == "number" and v >= 0 and v % 1 == 0 then
            return v
        end
        return 0
    end)
    if ok and type(n) == "number" then
        return n
    end
    return 0
end

local function localHasGymFolderAccess(gymFolderId)
    local ok, allowed = pcall(function()
        local GymConfig = require(ReplicatedStorage.Shared.Config.GymConfig)
        local GymAccess = require(ReplicatedStorage.Shared.Gym.GymAccess)
        local access = GymConfig.Access[gymFolderId]
        if not access then
            return false
        end
        local unlocks = LocalPlayer:GetAttribute(GymConfig.GymUnlocksAttribute)
        local purchased = GymAccess.purchasedFromAttribute(unlocks, gymFolderId)
            or GymAccess.ownsGamePass(LocalPlayer, access.ProductKey)
        return GymAccess.hasAccess(access, getPyramidCompletions(), purchased)
    end)
    return ok and allowed == true
end

local function findBestGymFolder(stationList)
    local ok, bestFolder = pcall(function()
        local GymConfig = require(ReplicatedStorage.Shared.Config.GymConfig)
        local bestReq = -1
        local bestId = nil
        for _, station in ipairs(stationList) do
            local folderId = station.GymFolder
            if type(folderId) == "string" and localHasGymFolderAccess(folderId) then
                local access = GymConfig.Access[folderId]
                local req = access and access.CompletionsRequired or 0
                if type(req) ~= "number" then
                    req = 0
                end
                if req >= bestReq then
                    bestReq = req
                    bestId = folderId
                end
            end
        end
        return bestId
    end)
    if ok then
        return bestFolder
    end
    return nil
end

local function getGymRoot()
    local GymConfig = require(ReplicatedStorage.Shared.Config.GymConfig)
    local gym = Workspace:FindFirstChild(GymConfig.GymFolderName)
    return gym, GymConfig
end

local function getTreadmillHitbox(gymFolderId)
    local gym, GymConfig = getGymRoot()
    if not gym or not gymFolderId then
        return nil
    end
    local zone = gym:FindFirstChild(gymFolderId)
    if not zone then
        return nil
    end
    local model = zone:FindFirstChild(GymConfig.TreadmillModelName)
    if not model then
        return nil
    end
    local hitbox = model:FindFirstChild(GymConfig.HitboxName)
    if hitbox and hitbox:IsA("BasePart") then
        return hitbox
    end
    return nil
end

local function getBenchAlignPart(gymFolderId)
    local gym, GymConfig = getGymRoot()
    if not gym or not gymFolderId then
        return nil, nil
    end
    local zone = gym:FindFirstChild(gymFolderId)
    if not zone then
        return nil, GymConfig
    end
    local model = zone:FindFirstChild(GymConfig.BenchpressModelName)
    if not model then
        return nil, GymConfig
    end
    local align = model:FindFirstChild(GymConfig.AlignPartName)
    if align and align:IsA("BasePart") then
        return align, GymConfig
    end
    return nil, GymConfig
end

local function getBenchPrompt(gymFolderId)
    local gym, GymConfig = getGymRoot()
    if not gym or not gymFolderId then
        return nil
    end
    local zone = gym:FindFirstChild(gymFolderId)
    local model = zone and zone:FindFirstChild(GymConfig.BenchpressModelName)
    local promptPart = model and model:FindFirstChild(GymConfig.PromptPartName)
    if not promptPart then
        return nil
    end
    return promptPart:FindFirstChildOfClass("ProximityPrompt")
end

local function isLocalBenchTraining()
    local ok, onBench = pcall(function()
        local GymConfig = require(ReplicatedStorage.Shared.Config.GymConfig)
        local attr = LocalPlayer:GetAttribute(GymConfig.BenchStationAttribute)
        return type(attr) == "string" and attr ~= ""
    end)
    return ok and onBench == true
end

local function isLocalOnTreadmillHitbox(gymFolderId)
    local char = LocalPlayer.Character
    local hrp = getHRP()
    local hitbox = getTreadmillHitbox(gymFolderId)
    if not char or not hrp or not hitbox then
        return false
    end
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { char }
    local parts = Workspace:GetPartBoundsInBox(hitbox.CFrame, hitbox.Size, params)
    return #parts > 0
end

local function isLocalOnAnyUnlockedTreadmill()
    local ok, on = pcall(function()
        local GymConfig = require(ReplicatedStorage.Shared.Config.GymConfig)
        for _, station in ipairs(GymConfig.TreadmillStations) do
            local folderId = station.GymFolder
            if type(folderId) == "string" and localHasGymFolderAccess(folderId) then
                if isLocalOnTreadmillHitbox(folderId) then
                    return true
                end
            end
        end
        return false
    end)
    return ok and on == true
end

local function triggerProximityPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then
        return false
    end
    if typeof(fireproximityprompt) == "function" then
        local ok = pcall(function()
            fireproximityprompt(prompt, 1)
        end)
        if ok then
            return true
        end
    end
    return pcall(function()
        prompt:InputHoldBegin()
        task.wait(0.06)
        prompt:InputHoldEnd()
    end)
end

local function teleportToTrainPart(part)
    if not part or not part:IsA("BasePart") then
        return false
    end
    local now = os.clock()
    if now - AutoTrain.lastTp < TRAIN_TP_COOLDOWN then
        return false
    end
    local hrp = getHRP()
    if not hrp then
        return false
    end
    AutoTrain.lastTp = now
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = part.CFrame + Vector3.new(0, 3, 0)
    end)
    return true
end

local function shouldPauseAutoTrainForFarm()
    if AutoHill.enabled and AutoHill.onHill then
        return true
    end
    if not Farm.enabled then
        return false
    end
    if Farm.placingRun then
        return true
    end
    return getRuntimePickupCount(getActiveRuntime()) > 0
end

local function tryStopLocalBench()
    if not isLocalBenchTraining() then
        return
    end
    pcall(function()
        local Knit = require(ReplicatedStorage.Packages.Knit)
        Knit.OnStart():andThen(function()
            Knit.GetService("GymService"):StopBench():catch(function() end)
        end)
    end)
end

local function getPyramidCompletionConfig()
    local ok, cfg = pcall(function()
        return require(ReplicatedStorage.Shared.Config.PyramidCompletionConfig)
    end)
    if ok and type(cfg) == "table" then
        return cfg
    end
    return {}
end

local function isHillCinematicActive()
    local cfg = getPyramidCompletionConfig()
    local attr = cfg.CinematicActiveAttribute or "CinematicActive"
    return LocalPlayer:GetAttribute(attr) == true
end

local CutscenePref = {
    saved = nil,
    lastSkip = 0,
}

local function suppressCompletionCutsceneSetting()
    pcall(function()
        local SettingsState = require(ReplicatedStorage.Shared.UI.State.SettingsState)
        if CutscenePref.saved == nil then
            CutscenePref.saved = SettingsState.get("completionCutscene")
        end
        SettingsState.set("completionCutscene", false)
    end)
end

local function restoreCompletionCutsceneSetting()
    pcall(function()
        if CutscenePref.saved == nil then
            return
        end
        local SettingsState = require(ReplicatedStorage.Shared.UI.State.SettingsState)
        SettingsState.set("completionCutscene", CutscenePref.saved)
        CutscenePref.saved = nil
    end)
end

local function skipPlayingCompletionCinematic()
    local now = os.clock()
    if now - CutscenePref.lastSkip < 0.3 then
        return
    end
    CutscenePref.lastSkip = now
    pcall(function()
        local Knit = require(ReplicatedStorage.Packages.Knit)
        local function stopIt()
            local ctrl = Knit.GetController("CompletionCinematicController")
            if ctrl and ctrl._playing and type(ctrl.Stop) == "function" then
                ctrl:Stop()
            end
        end
        if Knit.OnStart then
            Knit.OnStart():andThen(stopIt)
        else
            stopIt()
        end
    end)
    pcall(function()
        local cam = Workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
        local vim = game:GetService("VirtualInputManager")
        vim:SendMouseButtonEvent(vp.X * 0.5, vp.Y * 0.5, 0, true, game, 1)
        vim:SendMouseButtonEvent(vp.X * 0.5, vp.Y * 0.5, 0, false, game, 1)
    end)
end

local function syncCutsceneSuppress()
    if AutoHill.enabled or Farm.enabled then
        suppressCompletionCutsceneSetting()
        if isHillCinematicActive() then
            skipPlayingCompletionCinematic()
        end
    else
        restoreCompletionCutsceneSetting()
    end
end

local function pickHillPart(root, hitboxName)
    if not root then
        return nil
    end
    if type(hitboxName) == "string" and hitboxName ~= "" then
        local named = root:FindFirstChild(hitboxName) or root:FindFirstChild(hitboxName, true)
        if named and named:IsA("BasePart") then
            return named
        end
    end
    for _, name in ipairs({ "PoolHitbox", "Hitbox", "HillHitbox", "TrainHitbox", "Hill" }) do
        local named = root:FindFirstChild(name, true)
        if named and named:IsA("BasePart") then
            return named
        end
    end
    if root:IsA("BasePart") then
        return root
    end
    if root:IsA("Model") and root.PrimaryPart then
        return root.PrimaryPart
    end
    return root:FindFirstChildWhichIsA("BasePart", true)
end

local function findCompletedHillHitbox()
    local cfg = getPyramidCompletionConfig()
    local displayName = cfg.CompletedDisplayName
    local hitboxName = cfg.PoolHitboxName
    local display = nil
    if type(displayName) == "string" and displayName ~= "" then
        display = Workspace:FindFirstChild(displayName) or Workspace:FindFirstChild(displayName, true)
    end
    if not display then
        for _, name in ipairs({
            "CompletedPyramid",
            "CompletedDisplay",
            "SpiritualPool",
            "FinishedPyramid",
            "PyramidComplete",
        }) do
            display = Workspace:FindFirstChild(name) or Workspace:FindFirstChild(name, true)
            if display then
                break
            end
        end
    end
    local hitbox = pickHillPart(display, hitboxName)
    if hitbox then
        return hitbox
    end
    if type(hitboxName) == "string" and hitboxName ~= "" then
        for _, child in ipairs(Workspace:GetChildren()) do
            local nested = child:FindFirstChild(hitboxName, true)
            if nested and nested:IsA("BasePart") then
                return nested
            end
        end
    end
    return nil
end

local function isLocalOnHillHitbox(hitbox)
    local char = LocalPlayer.Character
    local hrp = getHRP()
    if not char or not hrp or not hitbox or not hitbox:IsA("BasePart") then
        return false
    end
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { char }
    local parts = Workspace:GetPartBoundsInBox(hitbox.CFrame, hitbox.Size, params)
    if #parts > 0 then
        return true
    end
    return (hrp.Position - hitbox.Position).Magnitude <= math.max(hitbox.Size.Magnitude * 0.55, 8)
end

local function teleportToHillHitbox(hitbox)
    if not hitbox or not hitbox:IsA("BasePart") then
        return false
    end
    local now = os.clock()
    if now - AutoHill.lastTp < TRAIN_TP_COOLDOWN then
        return false
    end
    local hrp = getHRP()
    if not hrp then
        return false
    end
    AutoHill.lastTp = now
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = hitbox.CFrame + Vector3.new(0, 3, 0)
    end)
    return true
end

local function getCompletionWindow()
    local ok, result = pcall(function()
        local PyramidRuntime = require(ReplicatedStorage.Shared.Placement.PyramidRuntime)
        local PyramidConfig = require(ReplicatedStorage.Shared.Config.PyramidConfig)
        local cfg = getPyramidCompletionConfig()
        local model = PyramidRuntime.getModel(Workspace)
        if not model then
            return { complete = false, remaining = 0, endsAt = 0 }
        end
        if model:GetAttribute(PyramidConfig.CompleteAttribute) ~= true then
            return { complete = false, remaining = 0, endsAt = 0 }
        end
        if model:GetAttribute(cfg.CompletionPausedAttribute) == true then
            local rem = tonumber(model:GetAttribute(cfg.CompletionPausedRemainingAttribute)) or 0
            return { complete = true, remaining = math.max(0, rem), endsAt = 0, paused = true }
        end
        local endsAt = tonumber(model:GetAttribute(cfg.CompletionEndsAtAttribute)) or 0
        local remaining = 0
        if endsAt > 1e12 then
            remaining = endsAt / 1000 - os.time()
        elseif endsAt > 1e10 then
            remaining = endsAt / 1000 - os.time()
        elseif endsAt > 0 then
            remaining = endsAt - os.time()
        end
        return { complete = true, remaining = remaining, endsAt = endsAt }
    end)
    if ok and type(result) == "table" then
        return result
    end
    return { complete = false, remaining = 0, endsAt = 0 }
end

local function stayOnCompletedHill()
    if not AutoHill.enabled then
        AutoHill.onHill = false
        AutoHill.waiting = false
        AutoHill.remaining = 0
        return false
    end
    local n = getPyramidCompletions()
    if AutoHill.lastCompletions == nil then
        AutoHill.lastCompletions = n
    elseif n > AutoHill.lastCompletions then
        AutoHill.waiting = true
        AutoHill.waitSince = os.clock()
    end
    AutoHill.lastCompletions = n
    if isHillCinematicActive() then
        skipPlayingCompletionCinematic()
        AutoHill.waiting = true
        if AutoHill.waitSince == 0 then
            AutoHill.waitSince = os.clock()
        end
        AutoHill.onHill = false
        AutoHill.remaining = 0
        return true
    end
    local window = getCompletionWindow()
    local hitbox = findCompletedHillHitbox()
    local remaining = tonumber(window.remaining) or 0
    AutoHill.remaining = math.max(0, remaining)
    local windowOpen = remaining > 0.5
    if window.complete and (window.endsAt or 0) == 0 and not window.paused then
        if hitbox or (AutoHill.waiting and os.clock() - (AutoHill.waitSince or 0) < 25) then
            windowOpen = true
        end
    elseif AutoHill.waiting and not window.complete and os.clock() - (AutoHill.waitSince or 0) < 25 then
        windowOpen = true
    end
    if not windowOpen then
        AutoHill.onHill = false
        AutoHill.waiting = false
        AutoHill.waitSince = 0
        AutoHill.remaining = 0
        return false
    end
    AutoHill.waiting = true
    if not hitbox then
        AutoHill.onHill = false
        return true
    end
    AutoHill.onHill = true
    tryStopLocalBench()
    if not isLocalOnHillHitbox(hitbox) then
        teleportToHillHitbox(hitbox)
    end
    return true
end

local function tickAutoHill()
    if not AutoHill.enabled then
        AutoHill.onHill = false
        return
    end
    local now = os.clock()
    if now - AutoHill.lastTick < TRAIN_TICK_INTERVAL then
        return
    end
    AutoHill.lastTick = now
    stayOnCompletedHill()
end

local function stopAutoHillLoop()
    if AutoHill.conn then
        AutoHill.conn:Disconnect()
        AutoHill.conn = nil
    end
    AutoHill.onHill = false
end

local function syncAutoHillLoop()
    if AutoHill.enabled then
        if not AutoHill.conn then
            AutoHill.conn = RunService.Heartbeat:Connect(tickAutoHill)
        end
        tickAutoHill()
    else
        stopAutoHillLoop()
    end
end

local function setAutoHill(on)
    AutoHill.enabled = on == true
    syncCutsceneSuppress()
    syncAutoHillLoop()
end

local function refreshAutoHillFromSavedToggles()
    local toggles = rawget(_G, "Toggles")
    if type(toggles) ~= "table" then
        syncAutoHillLoop()
        return
    end
    if toggles.klze_auto_hill and toggles.klze_auto_hill.Value then
        AutoHill.enabled = true
    end
    syncCutsceneSuppress()
    syncAutoHillLoop()
end

local function runAutoTrainSpeed()
    if not AutoTrain.speed or shouldPauseAutoTrainForFarm() then
        return
    end
    if isLocalBenchTraining() then
        return
    end
    local GymConfig = require(ReplicatedStorage.Shared.Config.GymConfig)
    local folderId = findBestGymFolder(GymConfig.TreadmillStations)
    if not folderId then
        return
    end
    if isLocalOnTreadmillHitbox(folderId) then
        return
    end
    local hitbox = getTreadmillHitbox(folderId)
    if hitbox then
        teleportToTrainPart(hitbox)
    end
end

local function runAutoTrainStrength()
    if not AutoTrain.strength or shouldPauseAutoTrainForFarm() then
        return
    end
    if AutoTrain.speed and isLocalOnAnyUnlockedTreadmill() then
        return
    end
    local GymConfig = require(ReplicatedStorage.Shared.Config.GymConfig)
    local folderId = findBestGymFolder(GymConfig.BenchpressStations)
    if not folderId then
        return
    end
    if isLocalBenchTraining() then
        local attr = LocalPlayer:GetAttribute(GymConfig.BenchStationAttribute)
        if attr == folderId then
            return
        end
        tryStopLocalBench()
        return
    end
    local align = getBenchAlignPart(folderId)
    if align and not isLocalOnTreadmillHitbox(folderId) then
        local hrp = getHRP()
        if hrp and (hrp.Position - align.Position).Magnitude > 6 then
            teleportToTrainPart(align)
            return
        end
    end
    local prompt = getBenchPrompt(folderId)
    if prompt and prompt.MaxActivationDistance > 0 then
        triggerProximityPrompt(prompt)
    end
end

local function tickAutoTrain()
    if stayOnCompletedHill() then
        return
    end
    if not AutoTrain.speed and not AutoTrain.strength then
        return
    end
    local now = os.clock()
    if now - AutoTrain.lastTick < TRAIN_TICK_INTERVAL then
        return
    end
    AutoTrain.lastTick = now
    if AutoTrain.speed then
        runAutoTrainSpeed()
    end
    if AutoTrain.strength then
        runAutoTrainStrength()
    end
end

local function stopAutoTrainLoop()
    if AutoTrain.conn then
        AutoTrain.conn:Disconnect()
        AutoTrain.conn = nil
    end
end

local function syncAutoTrainLoop()
    if AutoTrain.speed or AutoTrain.strength then
        if not AutoTrain.conn then
            AutoTrain.conn = RunService.Heartbeat:Connect(tickAutoTrain)
        end
        tickAutoTrain()
    else
        stopAutoTrainLoop()
    end
end

local function setAutoTrainMode(mode, on)
    if mode == "speed" then
        AutoTrain.speed = on == true
        if not on then
            -- treadmill stops when you step off; no server stop needed
        end
    elseif mode == "strength" then
        AutoTrain.strength = on == true
        if not on then
            tryStopLocalBench()
        end
    end
    syncAutoTrainLoop()
end

local function refreshAutoTrainFromSavedToggles()
    local toggles = rawget(_G, "Toggles")
    if type(toggles) ~= "table" then
        syncAutoTrainLoop()
        return
    end
    if toggles.klze_auto_train_speed and toggles.klze_auto_train_speed.Value then
        AutoTrain.speed = true
    end
    if toggles.klze_auto_train_strength and toggles.klze_auto_train_strength.Value then
        AutoTrain.strength = true
    end
    syncAutoTrainLoop()
end

function AntiLag.apply()
    local runtime = getActiveRuntime()
    if AntiLag.enabled then
        AntiLag.renderLiteOn()
    else
        AntiLag.renderLiteOff()
    end
    pcall(function()
        local CoinSpawnRequest = require(ReplicatedStorage.Shared.Placement.CoinSpawnRequest)
        if not AntiLag.hookedCoinVfx and type(CoinSpawnRequest.fire) == "function" then
            AntiLag.origCoinFire = CoinSpawnRequest.fire
            AntiLag.hookedCoinVfx = true
            CoinSpawnRequest.fire = function(...)
                if AntiLag.enabled then
                    return
                end
                return AntiLag.origCoinFire(...)
            end
        end
    end)

    pcall(function()
        local SettingsState = require(ReplicatedStorage.Shared.UI.State.SettingsState)
        if AntiLag.enabled then
            for _, k in ipairs({ "statPopups", "purchaseEffects", "levelUpEffects" }) do
                if AntiLag.savedSettings[k] == nil then
                    AntiLag.savedSettings[k] = SettingsState.get(k)
                end
                SettingsState.set(k, false)
            end
            if AntiLag.savedSettings.hatchAnimations == nil then
                AntiLag.savedSettings.hatchAnimations = SettingsState.get("hatchAnimations")
            end
            SettingsState.set("hatchAnimations", "off")
        else
            for k, val in pairs(AntiLag.savedSettings) do
                SettingsState.set(k, val)
            end
            table.clear(AntiLag.savedSettings)
        end
    end)

    if runtime and AntiLag.hookedRuntime ~= runtime then
        AntiLag.hookedRuntime = runtime
        AntiLag.origUpdateGhost = runtime._updatePyramidGhost
        AntiLag.origPlayPlacementJuice = runtime._playPlacementJuice
        AntiLag.origPlayPickupJuice = runtime._playPickupJuice

        if type(AntiLag.origPlayPlacementJuice) == "function" then
            runtime._playPlacementJuice = function(self, ...)
                if AntiLag.enabled then
                    return
                end
                return AntiLag.origPlayPlacementJuice(self, ...)
            end
        end

        if type(AntiLag.origPlayPickupJuice) == "function" then
            runtime._playPickupJuice = function(self, ...)
                if AntiLag.enabled then
                    return
                end
                return AntiLag.origPlayPickupJuice(self, ...)
            end
        end

        if type(AntiLag.origUpdateGhost) == "function" then
            runtime._updatePyramidGhost = function(self, ...)
                if AntiLag.enabled and Farm.enabled then
                    self._pyramidSlot = nil
                    if self._ghostPart then
                        pcall(function()
                            self._ghostPart.Parent = nil
                        end)
                    end
                    return
                end
                return AntiLag.origUpdateGhost(self, ...)
            end
        end
    end
end

AntiLag.liteClasses = {
    ParticleEmitter = true, Trail = true, Beam = true, Smoke = true,
    Fire = true, Sparkles = true, PointLight = true, SpotLight = true, SurfaceLight = true,
}
AntiLag.litePost = {
    BloomEffect = true, BlurEffect = true, SunRaysEffect = true,
    DepthOfFieldEffect = true, ColorCorrectionEffect = false,
}

function AntiLag.renderLiteOn()
    if not AntiLag.isNormal or AntiLag.renderSaved then
        return
    end
    local Lighting = game:GetService("Lighting")
    local saved = { shadows = Lighting.GlobalShadows, disabled = {}, quality = nil }
    AntiLag.renderSaved = saved
    pcall(function()
        Lighting.GlobalShadows = false
    end)
    pcall(function()
        saved.quality = settings().Rendering.QualityLevel
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)
    local function handle(inst)
        local cls = inst.ClassName
        if AntiLag.liteClasses[cls] or AntiLag.litePost[cls] then
            local ok, was = pcall(function()
                return inst.Enabled
            end)
            if ok and was then
                saved.disabled[#saved.disabled + 1] = inst
                pcall(function()
                    inst.Enabled = false
                end)
            end
        end
    end
    task.spawn(function()
        local n = 0
        for _, d in ipairs(Workspace:GetDescendants()) do
            handle(d)
            n += 1
            if n % 400 == 0 then
                task.wait()
            end
        end
        for _, d in ipairs(Lighting:GetChildren()) do
            handle(d)
        end
    end)
    AntiLag.renderConns[#AntiLag.renderConns + 1] = Workspace.DescendantAdded:Connect(function(d)
        if AntiLag.liteClasses[d.ClassName] then
            handle(d)
        end
    end)
end

function AntiLag.renderLiteOff()
    for _, c in ipairs(AntiLag.renderConns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(AntiLag.renderConns)
    local saved = AntiLag.renderSaved
    AntiLag.renderSaved = nil
    if not saved then
        return
    end
    pcall(function()
        game:GetService("Lighting").GlobalShadows = saved.shadows
    end)
    pcall(function()
        if saved.quality then
            settings().Rendering.QualityLevel = saved.quality
        end
    end)
    for _, inst in ipairs(saved.disabled) do
        pcall(function()
            inst.Enabled = true
        end)
    end
end

function AntiLag.restore()
    AntiLag.renderLiteOff()
    pcall(function()
        if AntiLag.hookedCoinVfx and AntiLag.origCoinFire then
            local CoinSpawnRequest = require(ReplicatedStorage.Shared.Placement.CoinSpawnRequest)
            CoinSpawnRequest.fire = AntiLag.origCoinFire
            AntiLag.hookedCoinVfx = false
        end
    end)
    pcall(function()
        local SettingsState = require(ReplicatedStorage.Shared.UI.State.SettingsState)
        for k, val in pairs(AntiLag.savedSettings) do
            SettingsState.set(k, val)
        end
        table.clear(AntiLag.savedSettings)
    end)
    local rt = AntiLag.hookedRuntime
    if rt then
        if AntiLag.origUpdateGhost then
            rt._updatePyramidGhost = AntiLag.origUpdateGhost
        end
        if AntiLag.origPlayPlacementJuice then
            rt._playPlacementJuice = AntiLag.origPlayPlacementJuice
        end
        if AntiLag.origPlayPickupJuice then
            rt._playPickupJuice = AntiLag.origPlayPickupJuice
        end
        AntiLag.hookedRuntime = nil
    end
end

function AntiLag.set(on)
    AntiLag.enabled = on == true
    AntiLag.apply()
end

-- ==========================================
-- AUTO PETS (Normal & Halloween Worlds)
-- ==========================================
function AutoPet.getEggConfig()
    local ok, cfg = pcall(function()
        return require(ReplicatedStorage.Shared.Config.EggConfig)
    end)
    return ok and cfg or nil
end

function AutoPet.getPetConfig()
    local ok, cfg = pcall(function()
        return require(ReplicatedStorage.Shared.Config.PetConfig)
    end)
    return ok and cfg or nil
end

function AutoPet.getPetState()
    local ok, st = pcall(function()
        return require(ReplicatedStorage.Shared.UI.State.PetState)
    end)
    return ok and st or nil
end

function AutoPet.getEggBuyPart(eggId)
    local EggConfig = AutoPet.getEggConfig()
    if not EggConfig or not EggConfig.ById then
        return nil
    end
    local def = EggConfig.ById[eggId]
    if not def then
        return nil
    end
    local folderName = EggConfig.WorldFolderName or "Eggs"
    local folder = Workspace:FindFirstChild(folderName)
    if not folder then
        return nil
    end
    local model = folder:FindFirstChild(def.DisplayModel or eggId) or folder:FindFirstChild(eggId)
    if not model then
        return nil
    end
    local buyPart = model:FindFirstChild("BuyPart", true)
    if buyPart and buyPart:IsA("BasePart") then
        return buyPart
    end
    if model:IsA("BasePart") then
        return model
    end
    return model:FindFirstChildWhichIsA("BasePart", true)
end

function AutoPet.buildEggDropdownOptions()
    local labels = { "Auto (Best Affordable in World)" }
    local map = {
        ["Auto (Best Affordable in World)"] = "AutoBest",
    }
    local EggConfig = AutoPet.getEggConfig()
    if EggConfig and type(EggConfig.Order) == "table" and type(EggConfig.ById) == "table" then
        for _, eggId in ipairs(EggConfig.Order) do
            local def = EggConfig.ById[eggId]
            if def then
                local isHalloweenEgg = (def.Currency == "CandyCorn")
                local worldTag = isHalloweenEgg and "[Halloween]" or "[Normal]"
                local currLabel = isHalloweenEgg and "Candy" or "Coins"
                local inWorld = AutoPet.getEggBuyPart(eggId) ~= nil
                local suffix = inWorld and "" or " [Other World]"
                local label = string.format(
                    "%s %s (%s %s)%s",
                    worldTag,
                    tostring(def.DisplayName or eggId),
                    tostring(def.Price or 0),
                    currLabel,
                    suffix
                )
                table.insert(labels, label)
                map[label] = eggId
            end
        end
    end
    AutoPet.eggLabels = labels
    AutoPet.eggMap = map
    return labels, map
end

function AutoPet.canAffordEgg(eggId, count)
    count = count or 1
    local EggConfig = AutoPet.getEggConfig()
    if not EggConfig or not EggConfig.ById or not EggConfig.ById[eggId] then
        return false
    end
    local def = EggConfig.ById[eggId]
    local totalCost = (tonumber(def.Price) or 0) * count
    if totalCost <= 0 then
        return true
    end
    local balance = (def.Currency == "CandyCorn") and getSpendableCandyCorn() or getSpendableCoins()
    if balance == nil then
        local PetState = AutoPet.getPetState()
        if PetState and type(PetState.balanceFor) == "function" then
            local ok, bal = pcall(PetState.balanceFor, def.Currency)
            if ok and bal ~= nil then
                local StatProgression = require(ReplicatedStorage.Shared.Stats.StatProgression)
                balance = StatProgression.normalizeValue(bal)
            end
        end
    end
    if balance == nil then
        return false
    end
    return canAffordCoinCost(balance, totalCost)
end

function AutoPet.resolveTargetEggId()
    local EggConfig = AutoPet.getEggConfig()
    if not EggConfig or type(EggConfig.Order) ~= "table" then
        return nil
    end
    local sel = AutoPet.selectedEggId
    if sel and sel ~= "AutoBest" and EggConfig.ById[sel] then
        return sel
    end
    local bestId = nil
    local bestPrice = -1
    for _, eggId in ipairs(EggConfig.Order) do
        local def = EggConfig.ById[eggId]
        if def and AutoPet.getEggBuyPart(eggId) ~= nil and AutoPet.canAffordEgg(eggId, 1) then
            local price = tonumber(def.Price) or 0
            if price >= bestPrice then
                bestPrice = price
                bestId = eggId
            end
        end
    end
    return bestId
end

function AutoPet.resolveHatchAmount(eggId)
    local mode = AutoPet.hatchAmountMode or "Auto"
    if mode == "1x" then
        return 1
    elseif mode == "3x" then
        return AutoPet.canAffordEgg(eggId, 3) and 3 or 1
    end
    local ownsTriple = LocalPlayer:GetAttribute("OwnsPass_petTripleOpen") == true
    if not ownsTriple then
        local PetState = AutoPet.getPetState()
        if PetState and type(PetState.inventory) == "function" then
            local inv = PetState.inventory()
            if type(inv) == "table" and type(inv.Access) == "table" and inv.Access.Triple == true then
                ownsTriple = true
            end
        end
    end
    if ownsTriple and AutoPet.canAffordEgg(eggId, 3) then
        return 3
    end
    return 1
end

function AutoPet.skipActivePetHatchReveal()
    if not AutoPet.instantHatch then
        return
    end
    pcall(function()
        local PetState = AutoPet.getPetState()
        if not PetState or type(PetState.reveal) ~= "function" then
            return
        end
        local currentReveal = PetState.reveal()
        if currentReveal ~= nil then
            local Knit = require(ReplicatedStorage.Packages.Knit)
            local okCtrl, petCtrl = pcall(function()
                return Knit.GetController("PetController")
            end)
            if okCtrl and petCtrl and type(petCtrl._finishHatch) == "function" then
                pcall(petCtrl._finishHatch, petCtrl, currentReveal)
            end
            PetState.reveal(nil)
            local UIManager = require(ReplicatedStorage.Shared.UI.Runtime.UIManager)
            if UIManager and type(UIManager.ReleaseLock) == "function" then
                pcall(UIManager.ReleaseLock, UIManager, "PetHatch")
            end
        end
    end)
end

function AutoPet.syncAutoDeletePets()
    local hasAnyRarity = false
    for _, enabled in pairs(AutoPet.autoDeleteRarities) do
        if enabled then
            hasAnyRarity = true
            break
        end
    end
    if not hasAnyRarity then
        return
    end
    pcall(function()
        local PetState = AutoPet.getPetState()
        local PetConfig = AutoPet.getPetConfig()
        if not PetState or not PetConfig or type(PetState.inventory) ~= "function" then
            return
        end
        local inv = PetState.inventory()
        if type(inv) ~= "table" or type(inv.Owned) ~= "table" then
            return
        end
        local equippedSet = {}
        if type(inv.Equipped) == "table" then
            for _, uid in ipairs(inv.Equipped) do
                equippedSet[uid] = true
            end
        end
        local toDelete = {}
        for uid, petData in pairs(inv.Owned) do
            if not equippedSet[uid] and type(petData) == "table" and petData.Locked ~= true then
                local def = PetConfig.ById and PetConfig.ById[petData.PetId]
                if def and def.Rarity and AutoPet.autoDeleteRarities[def.Rarity] == true then
                    table.insert(toDelete, uid)
                end
            end
        end
        if #toDelete > 0 then
            local Knit = require(ReplicatedStorage.Packages.Knit)
            local petService = Knit.GetService("PetService")
            if petService and petService.DeletePets then
                petService:DeletePets(toDelete):catch(function() end)
            end
        end
    end)
end

function AutoPet.runAutoEquipBest()
    pcall(function()
        local Knit = require(ReplicatedStorage.Packages.Knit)
        local petService = Knit.GetService("PetService")
        if petService and petService.EquipBest then
            petService:EquipBest():catch(function() end)
        end
    end)
end

function AutoPet.tickAutoPet()
    if AutoPet.instantHatch then
        AutoPet.skipActivePetHatchReveal()
    end

    local now = os.clock()
    if AutoPet.autoEquipBest and (now - AutoPet.lastEquipBestAt) >= 4.0 then
        AutoPet.lastEquipBestAt = now
        AutoPet.runAutoEquipBest()
    end

    if (now - AutoPet.lastAutoDeleteSyncAt) >= 3.5 then
        AutoPet.lastAutoDeleteSyncAt = now
        AutoPet.syncAutoDeletePets()
    end

    if not AutoPet.hatchEnabled or AutoPet.inFlight then
        return
    end

    local EggConfig = AutoPet.getEggConfig()
    local cooldown = (EggConfig and tonumber(EggConfig.HatchCooldownSeconds)) or 1.2
    local minInterval = AutoPet.instantHatch and math.max(0.35, cooldown * 0.45) or cooldown
    if (now - AutoPet.lastHatchAt) < minInterval then
        return
    end

    local eggId = AutoPet.resolveTargetEggId()
    if not eggId then
        return
    end

    local buyPart = AutoPet.getEggBuyPart(eggId)
    if not buyPart or not AutoPet.canAffordEgg(eggId, 1) then
        return
    end

    local PetState = AutoPet.getPetState()
    if PetState and type(PetState.inventory) == "function" then
        local inv = PetState.inventory()
        if type(inv) == "table" and type(inv.Owned) == "table" and type(inv.MaxStorage) == "number" then
            local count = 0
            for _ in pairs(inv.Owned) do
                count += 1
            end
            if count >= inv.MaxStorage then
                AutoPet.syncAutoDeletePets()
                return
            end
        end
    end

    local hrp = getHRP()
    if not hrp then
        return
    end

    local maxDist = (EggConfig and tonumber(EggConfig.MaxHatchDistance)) or 18
    local dist = (hrp.Position - buyPart.Position).Magnitude
    if dist > (maxDist - 2.5) then
        if not AutoPet.autoTpToEgg then
            return
        end
        pcall(function()
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
            hrp.CFrame = buyPart.CFrame * CFrame.new(0, 3, 3.5)
        end)
    end

    local amount = AutoPet.resolveHatchAmount(eggId)
    AutoPet.inFlight = true
    AutoPet.lastHatchAt = now

    pcall(function()
        local Knit = require(ReplicatedStorage.Packages.Knit)
        local petService = Knit.GetService("PetService")
        local req = petService:Hatch(eggId, amount)
        local function done()
            AutoPet.inFlight = false
            if AutoPet.instantHatch then
                task.defer(AutoPet.skipActivePetHatchReveal)
            end
            if AutoPet.autoEquipBest then
                task.delay(0.2, AutoPet.runAutoEquipBest)
            end
        end
        if req and type(req.andThen) == "function" then
            req:andThen(done):catch(done)
        else
            done()
        end
    end)
end

function AutoPet.stopAutoPetLoop()
    if AutoPet.conn then
        AutoPet.conn:Disconnect()
        AutoPet.conn = nil
    end
    AutoPet.inFlight = false
end

function AutoPet.anyAutoPetFeatureActive()
    if AutoPet.hatchEnabled or AutoPet.autoEquipBest or AutoPet.instantHatch then
        return true
    end
    for _, v in pairs(AutoPet.autoDeleteRarities) do
        if v then
            return true
        end
    end
    return false
end

function AutoPet.syncAutoPetLoop()
    if AutoPet.anyAutoPetFeatureActive() then
        if not AutoPet.conn then
            AutoPet.conn = RunService.Heartbeat:Connect(AutoPet.tickAutoPet)
        end
    else
        AutoPet.stopAutoPetLoop()
    end
end

function AutoPet.teleportToWorld(targetPlaceId)
    if game.PlaceId == targetPlaceId then
        local lib = typeof(getgenv) == "function" and getgenv().KLZE_PYRAMID_LIBRARY
        if lib and lib.Notify then
            pcall(function()
                lib:Notify("Already in this world!", 3)
            end)
        end
        return
    end
    pcall(function()
        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("ProximityPrompt") and (desc.Name == "PortalPrompt" or string.find(string.lower(desc.ObjectText or ""), "world")) then
                local parentPart = desc.Parent
                local hrp = getHRP()
                if hrp and parentPart and parentPart:IsA("BasePart") then
                    hrp.CFrame = parentPart.CFrame + Vector3.new(0, 3, 0)
                    task.wait(0.15)
                    triggerProximityPrompt(desc)
                    return
                end
            end
        end
        TeleportService:Teleport(targetPlaceId, LocalPlayer)
    end)
end

function AutoPet.claimFreeGiftReward()
    pcall(function()
        local Knit = require(ReplicatedStorage.Packages.Knit)
        Knit.OnStart():andThen(function()
            local svc = Knit.GetService("FreeGiftService")
            if svc and svc.Claim then
                svc:Claim():andThen(function(res)
                    local lib = typeof(getgenv) == "function" and getgenv().KLZE_PYRAMID_LIBRARY
                    if lib and lib.Notify then
                        if type(res) == "table" and res.ok then
                            lib:Notify("Free Gift claimed!", 4)
                        elseif type(res) == "table" and res.reason then
                            lib:Notify("Free Gift: " .. tostring(res.reason), 4)
                        end
                    end
                end):catch(function() end)
            end
        end)
    end)
end

local function runFarmPlacePhase(runtime, RR, allowTeleport)
    local now = os.clock()
    local strict = isStrictLayerEndgame(runtime)
    Farm.strictLayerEndgame = strict

    if strict and now < Farm.nextPlaceAttempt then
        return
    end

    if strict then
        local outstanding = getOutstandingPlaceCount(runtime)
        if outstanding >= (AntiLag.isNormal and 16 or 12) then
            Farm.nextPlaceAttempt = now + getPlaceRetryDelay(runtime)
            syncGamePyramidTarget(runtime, false)
            return
        end
        syncGamePyramidTarget(runtime, false)
    elseif Farm.placeStuckTicks >= 2 then
        syncGamePyramidTarget(runtime, true)
    end

    local placeRange = getPlaceRangeForPlayer()
    local slot = findNavigationPyramidSlot(runtime, Farm.placeStuckTicks >= 1)
    if not slot then
        slot = reconcilePyramidSlot(runtime, Farm.placeStuckTicks >= 2)
    end

    if allowTeleport then
        if slot and not isWithinPlaceRange(slot, placeRange) then
            teleportToPlaceSlot(slot, placeRange)
        elseif not slot then
            teleportToPyramidSlotForFarm(runtime)
        end
    end

    local placeBurst = getPlaceBurstLimit(runtime)
    local maxDrain = strict and 1 or scaledFarmDrainPasses()
    local placedThisTick = false
    local drainPasses = 0
    while hasBlocksToPlace(runtime) and drainPasses < maxDrain do
        drainPasses += 1
        local placedAny = false
        for _ = 1, placeBurst do
            if not hasBlocksToPlace(runtime) then
                break
            end
            if strict and getOutstandingPlaceCount(runtime) >= (AntiLag.isNormal and 14 or 10) then
                break
            end
            if runtime:tryPlacePyramid() then
                placedAny = true
                placedThisTick = true
            else
                break
            end
        end
        if not placedAny then
            Farm.placeStuckTicks += 1
            if strict then
                Farm.nextPlaceAttempt = now + getPlaceRetryDelay(runtime)
            end
            break
        end
        if strict then
            Farm.nextPlaceAttempt = os.clock() + getPlaceRetryDelay(runtime)
            break
        end
    end

    if placedThisTick then
        Farm.placeStuckTicks = 0
        Farm.lastProgressAt = os.clock()
    elseif not strict then
        Farm.placeStuckTicks = math.min(Farm.placeStuckTicks + 1, 8)
    end

    Farm.strictLayerEndgame = isStrictLayerEndgame(runtime)

    if not hasBlocksToPlace(runtime) then
        Farm.placingRun = false
        Farm.placeStuckTicks = 0
        Farm.strictLayerEndgame = false
        return
    end

    if Farm.strictLayerEndgame and Farm.placeStuckTicks >= 6 and not slot then
        if now - Farm.lastNoSlotNotify > 12 then
            Farm.lastNoSlotNotify = now
            local lib = typeof(getgenv) == "function" and getgenv().KLZE_PYRAMID_LIBRARY
            if lib and lib.Notify then
                pcall(function()
                    lib:Notify("Layer almost full — slowing down to avoid lag…", 4)
                end)
            end
        end
        Farm.nextPlaceAttempt = now + FARM_LAYER_ENDGAME_COOLDOWN
    end
end

local function runFarmPickPhase(interactionCtrl, RR, allowTeleport)
    if allowTeleport and not isInRegion(RR.Ids.Quarry) then
        teleportToRegion(RR.Ids.Quarry)
    end
    for _ = 1, scaledFarmBurst(BURST_PICK) do
        if not canPickupMore() then
            break
        end
        if not interactionCtrl:tryPickup() then
            break
        end
    end
    if canPickupMore() then
        for _ = 1, scaledFarmBurst(BURST_QUARRY) do
            if not canPickupMore() then
                break
            end
            if not tryQuarryGrant() then
                break
            end
        end
    end
end

local function runFarmTick(interactionCtrl, allowTeleport)
    if AutoHill.enabled and stayOnCompletedHill() then
        return
    end
    if not Farm.enabled or not interactionCtrl or not interactionCtrl._runtime then
        return
    end
    local runtime = interactionCtrl._runtime
    if runtime._gameplayBlocked then
        return
    end
    local RR = getRegionRegistry()

    if shouldDrainToPyramid(runtime) then
        Farm.placingRun = true
        runFarmPlacePhase(runtime, RR, allowTeleport)
        if allowTeleport then
            maybeUnstickFarmPile(runtime)
        end
        return
    end

    Farm.placingRun = false

    if canPickupMore() then
        runFarmPickPhase(interactionCtrl, RR, allowTeleport)
    end
    if allowTeleport then
        maybeUnstickFarmPile(runtime)
    end
end

local function startFarmLoop(interactionCtrl)
    stopFarmLoop()
    Farm.strictLayerEndgame = false
    Farm.lastProgressAt = os.clock()
    Farm.lastCarriedSeen = -1
    Farm.lastNudgeAt = 0
    Farm.nextPileCheck = 0
    AntiLag.apply()
    Farm.conn = RunService.Heartbeat:Connect(function()
        runFarmTick(interactionCtrl, true)
    end)
end

local function stopLegacyFarmState(farm)
    if type(farm) ~= "table" then
        return
    end
    farm.enabled = false
    if farm.conn then
        pcall(function()
            farm.conn:Disconnect()
        end)
        farm.conn = nil
    end
    if farm.hbConn then
        pcall(function()
            farm.hbConn:Disconnect()
        end)
        farm.hbConn = nil
    end
    farm.quarryInFlight = 0
    farm.placingRun = false
end

local function stopLegacyPlayerState(player)
    if type(player) ~= "table" then
        return
    end
    player.fly = false
    player.infJump = false
    if player.flyConn then
        pcall(function()
            player.flyConn:Disconnect()
        end)
        player.flyConn = nil
    end
    if player.jumpConn then
        pcall(function()
            player.jumpConn:Disconnect()
        end)
        player.jumpConn = nil
    end
    if player.charConn then
        pcall(function()
            player.charConn:Disconnect()
        end)
        player.charConn = nil
    end
end

local function stopLegacyPyramidSession()
    if typeof(getgenv) ~= "function" then
        return
    end
    stopLegacyFarmState(getgenv().KLZE_PYRAMID_FARM)
    stopLegacyPlayerState(getgenv().KLZE_PYRAMID_PLAYER)
    pcall(function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            hum.PlatformStand = false
        end
    end)
end

local FEATURE_TOGGLE_IDS = { "klze_auto_farm", "klze_auto_hatch", "klze_fly", "klze_inf_jump" }

local function syncFeatureTogglesOff()
    local toggles = rawget(_G, "Toggles")
    if type(toggles) ~= "table" then
        return
    end
    for _, id in FEATURE_TOGGLE_IDS do
        local toggle = toggles[id]
        if toggle and type(toggle.SetValue) == "function" and toggle.Value == true then
            pcall(function()
                toggle:SetValue(false)
            end)
        end
    end
end

local function resetFeatureStatesOff()
    Farm.enabled = false
    Farm.placingRun = false
    Farm.strictLayerEndgame = false
    Farm.placeStuckTicks = 0
    AutoPet.hatchEnabled = false
    AutoPet.autoEquipBest = false
    AutoPet.stopAutoPetLoop()
    stopAutoUpgradeLoop()
    stopAutoTrainLoop()
    stopAutoHillLoop()
    restoreCompletionCutsceneSetting()
    AntiLag.restore()
    PlayerMods.fly = false
    PlayerMods.infJump = false
    setFly(false)
    stopPlayerMods()
    applyWalkAndJump()
    syncFeatureTogglesOff()
end

local function pyramidCleanup()
    stopLegacyPyramidSession()
    stopFarmLoop()
    resetFeatureStatesOff()
end

local function destroyObsidianLibrary(lib)
    if not lib or lib.Unloaded == true then
        return
    end
    if type(lib.UnloadSignals) == "table" then
        table.clear(lib.UnloadSignals)
    end
    pcall(function()
        if type(lib.Unload) == "function" then
            lib:Unload()
        end
    end)
end

local function disposePreviousSession()
    if typeof(getgenv) ~= "function" then
        return
    end
    getgenv().KLZE_PYRAMID_CLEANUP = pyramidCleanup
    pcall(pyramidCleanup)
    pcall(function()
        local Hub = getgenv().KLZE_HUB_WINDOW
        if Hub and Hub.setAntiAfk then
            Hub.setAntiAfk(false)
        end
    end)
    destroyObsidianLibrary(getgenv().KLZE_PYRAMID_LIBRARY)
    destroyObsidianLibrary(getgenv().KLZE_OBSIDIAN_LIBRARY)
    getgenv().KLZE_PYRAMID_LIBRARY = nil
    getgenv().KLZE_PYRAMID_CTRL = nil
    getgenv().KLZE_PYRAMID_FARM = nil
    getgenv().KLZE_PYRAMID_PLAYER = nil
    getgenv().KLZE_PYRAMID_UNLOAD = nil
    getgenv().KLZE_PYRAMID_CLEANUP = nil
    getgenv().KLZE_OBSIDIAN_READY = nil
    getgenv().KLZE_OBSIDIAN_LIBRARY = nil
    getgenv().KLZE_OBSIDIAN_SAVE = nil
    getgenv().KLZE_OBSIDIAN_THEME = nil
    getgenv().KLZE_HUB_WINDOW = nil
end

klzePyramidUnload = function()
    pyramidCleanup()
    pcall(function()
        if typeof(getgenv) == "function" then
            local Hub = getgenv().KLZE_HUB_WINDOW
            if Hub and Hub.setAntiAfk then
                Hub.setAntiAfk(false)
            end
        end
    end)

    if typeof(getgenv) == "function" then
        destroyObsidianLibrary(getgenv().KLZE_PYRAMID_LIBRARY)
        destroyObsidianLibrary(getgenv().KLZE_OBSIDIAN_LIBRARY)
        getgenv().KLZE_PYRAMID_LIBRARY = nil
        getgenv().KLZE_PYRAMID_CTRL = nil
        getgenv().KLZE_PYRAMID_FARM = nil
        getgenv().KLZE_PYRAMID_PLAYER = nil
        getgenv().KLZE_PYRAMID_UNLOAD = nil
        getgenv().KLZE_PYRAMID_CLEANUP = nil
        getgenv().KLZE_OBSIDIAN_READY = nil
        getgenv().KLZE_OBSIDIAN_LIBRARY = nil
        getgenv().KLZE_OBSIDIAN_SAVE = nil
        getgenv().KLZE_OBSIDIAN_THEME = nil
        getgenv().KLZE_HUB_WINDOW = nil
    end
end

if typeof(getgenv) == "function" then
    getgenv().KLZE_PYRAMID_CLEANUP = pyramidCleanup
end

if typeof(getgenv) == "function" and (getgenv().KLZE_PYRAMID_LIBRARY or getgenv().KLZE_OBSIDIAN_LIBRARY) then
    pcall(disposePreviousSession)
end

if typeof(getgenv) == "function" then
    getgenv().KLZE_PYRAMID_CLEANUP = pyramidCleanup
end

local Hub = loadHub()
if not validHub(Hub) then
    error("[KLZE] UI module failed to load (Hub.create missing)")
end

local gameName = "Construa a Pirâmide!"
pcall(function()
    gameName = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
end)

local hubUiOptions = {
    Game = gameName,
    Version = "1.1.0",
    DiscordInvite = DEFAULT_DISCORD,
    SiteUrl = DEFAULT_SITE,
    HubBlurb = "Keyless KLZE Hub — Normal & Halloween Worlds supported.",
}

local Window, Library, SaveManager, ThemeManager, meta = Hub.create(hubUiOptions)

local GameTab = Window:AddTab("Game", "gamepad-2")
local farmBox = GameTab:AddLeftGroupbox("Auto farm", "zap")

farmBox:AddToggle("klze_auto_farm", {
    Text = "Auto farm",
    Default = false,
    Tooltip = "Quarry TP → fill carry cap → pyramid TP → place all blocks → repeat. Off after each inject until you enable it.",
    Callback = function(v)
        Farm.enabled = v == true
        if Farm.enabled then
            Farm.lastProgressAt = os.clock()
            Farm.lastCarriedSeen = -1
            Farm.lastNudgeAt = 0
        end
        AntiLag.apply()
        syncCutsceneSuppress()
    end,
})

farmBox:AddToggle("klze_anti_lag", {
    Text = "Anti-Lag / Fast Farm (No VFX)",
    Default = true,
    Tooltip = "Disables flying 3D/2D coin VFX spam, placement shake, popups, and redundant ghost recalculations while farming.",
    Callback = function(v)
        AntiLag.set(v)
    end,
})

farmBox:AddToggle("klze_auto_hill", {
    Text = "Hill after pyramid",
    Default = false,
    Tooltip = "When the pyramid finishes, pause farm and train on that hill until the game timer ends, then farm the next one. Loop forever with Auto farm.",
    Callback = function(v)
        setAutoHill(v)
    end,
})

farmBox:AddSlider("klze_farm_speed", {
    Text = "Farm speed",
    Default = 10,
    Min = 1,
    Max = 10,
    Rounding = 0,
    Tooltip = "1 = slowest, gentler when the layer is almost full. 10 = max turbo (default).",
    Callback = function(v)
        Farm.speed = math.clamp(math.floor(v), 1, 10)
    end,
})

farmBox:AddInput("klze_max_capacity", {
    Text = "Max capacity",
    Default = "",
    Placeholder = "Auto (game)",
    Numeric = true,
    Finished = true,
    AllowEmpty = true,
    Tooltip = "Optional number if the game cap display is wrong (e.g. 71). Leave empty to use game capacity.",
    Callback = function(value)
        local n = tonumber(value)
        if n and n > 0 then
            Farm.capacityOverride = math.floor(n)
        else
            Farm.capacityOverride = nil
        end
    end,
})

local trainBox = GameTab:AddLeftGroupbox("Auto train", "dumbbell")

trainBox:AddToggle("klze_auto_train_speed", {
    Text = "Auto train speed",
    Default = false,
    Tooltip = "Uses the best treadmill you unlocked (by pyramid count). Pauses while auto farm is carrying blocks.",
    Callback = function(v)
        setAutoTrainMode("speed", v)
    end,
})

trainBox:AddToggle("klze_auto_train_strength", {
    Text = "Auto train strength",
    Default = false,
    Tooltip = "Uses the best bench you unlocked (by pyramid count). Pauses while auto farm is carrying blocks.",
    Callback = function(v)
        setAutoTrainMode("strength", v)
    end,
})

local upgradeBox = GameTab:AddRightGroupbox("Upgrades (Normal & Halloween)", "trending-up")

upgradeBox:AddDropdown("klze_upgrade_currency", {
    Values = { "Auto", "Coins", "CandyCorn", "Both" },
    Default = 1,
    Multi = false,
    Text = "Upgrade Currency",
    Tooltip = "Auto/Both uses Candy Corn (50% cheaper!) & Coins in Halloween World, or Coins in Normal World.",
    Callback = function(v)
        AutoUpgrade.currencyMode = tostring(v or "Auto")
    end,
})

upgradeBox:AddToggle("klze_auto_upgrade_bulk_pickup", {
    Text = "Auto Bulk Pickup (Max 24)",
    Default = false,
    Tooltip = "Automatically upgrades Bulk Pickup when you can afford the next level.",
    Callback = function(v)
        setAutoUpgradePick("bulkPickup", v)
    end,
})

upgradeBox:AddToggle("klze_auto_upgrade_bulk_place", {
    Text = "Auto Bulk Place (Max 24)",
    Default = false,
    Tooltip = "Automatically upgrades Bulk Place when you can afford the next level.",
    Callback = function(v)
        setAutoUpgradePick("bulkPlace", v)
    end,
})

upgradeBox:AddToggle("klze_auto_upgrade_placement_range", {
    Text = "Auto Placement Range (Max 24)",
    Default = false,
    Tooltip = "Automatically upgrades Placement Range when you can afford the next level.",
    Callback = function(v)
        setAutoUpgradePick("placementRange", v)
    end,
})

do local worldBox = GameTab:AddRightGroupbox("Worlds & Rewards", "globe")

worldBox:AddButton({
    Text = "TP to Halloween World",
    Func = function()
        AutoPet.teleportToWorld(HALLOWEEN_PLACE_ID)
    end,
    Tooltip = "Teleports to Halloween World (95412364107708).",
})

worldBox:AddButton({
    Text = "TP to Normal World",
    Func = function()
        AutoPet.teleportToWorld(MAIN_PLACE_ID)
    end,
    Tooltip = "Teleports to Main / Normal World (123720558354386).",
})

worldBox:AddButton({
    Text = "Claim Free Gift (+Speed/Strength)",
    Func = function()
        AutoPet.claimFreeGiftReward()
    end,
    Tooltip = "Claims the Free Gift reward via FreeGiftService.",
})

end
local capLabel = farmBox:AddLabel("Carrying: …")
local statusLabel = farmBox:AddLabel("Status: …")
local rateLabel = farmBox:AddLabel("Recogida: …")

task.spawn(function()
    local lastCount, lastT = nil, os.clock()
    local cycleStart, cycleStartCount = nil, 0
    local liveRate, peakRate = 0, 0
    local lastCycleText = "sin ciclos aún"

    while typeof(getgenv) == "function" and getgenv().KLZE_PYRAMID_LIBRARY == Library do
        task.wait(1)
        local now = os.clock()
        local n = getRuntimePickupCount(getActiveRuntime())

        if Farm.enabled and not Farm.placingRun then
            -- fase de recogida
            if cycleStart == nil then
                cycleStart, cycleStartCount = now, n
            end
            if lastCount ~= nil and n >= lastCount then
                liveRate = (n - lastCount) / math.max(now - lastT, 0.001)
                peakRate = math.max(peakRate, liveRate)
            end
        elseif cycleStart ~= nil then
            -- acaba de empezar la fase de colocación: cerrar el ciclo
            local got = n - cycleStartCount
            local dur = now - cycleStart
            if got > 0 then
                lastCycleText = string.format("%d bloques en %.1fs (%.1f/s)", got, dur, got / dur)
            end
            cycleStart = nil
            liveRate = 0
        end

        lastCount, lastT = n, now
        pcall(function()
            rateLabel:SetText(string.format(
                "Recogida: %.1f/s (pico %.1f) · último ciclo: %s",
                liveRate, peakRate, lastCycleText
            ))
        end)
    end
end)
do local PetsTab = Window:AddTab("Pets", "star")
local hatchBox = PetsTab:AddLeftGroupbox("Auto Hatch (Normal & Halloween)", "egg")

local initialEggLabels = AutoPet.buildEggDropdownOptions()

AutoPet.eggDropdown = hatchBox:AddDropdown("klze_pet_egg", {
    Values = initialEggLabels,
    Default = 1,
    Multi = false,
    Text = "Select Egg",
    Tooltip = "Choose 'Auto (Best Affordable in World)' or pick any Normal (Coins) or Halloween (Candy Corn) egg.",
    Callback = function(v)
        local id = AutoPet.eggMap[tostring(v)] or "AutoBest"
        AutoPet.selectedEggId = id
    end,
})

hatchBox:AddDropdown("klze_pet_hatch_amount", {
    Values = { "Auto", "1x", "3x" },
    Default = 1,
    Multi = false,
    Text = "Hatch Amount",
    Tooltip = "Auto uses 3x if you own Triple Hatch and can afford 3, otherwise 1x.",
    Callback = function(v)
        AutoPet.hatchAmountMode = tostring(v or "Auto")
    end,
})

hatchBox:AddToggle("klze_auto_hatch", {
    Text = "Auto Hatch Egg",
    Default = false,
    Tooltip = "Automatically hatches the selected egg in Normal or Halloween World.",
    Callback = function(v)
        AutoPet.hatchEnabled = v == true
        bindCoinStatObserver()
        AutoPet.syncAutoPetLoop()
    end,
})

hatchBox:AddToggle("klze_auto_tp_egg", {
    Text = "Auto TP to Egg",
    Default = true,
    Tooltip = "Automatically teleports to the egg's BuyPart when hatching.",
    Callback = function(v)
        AutoPet.autoTpToEgg = v == true
    end,
})

hatchBox:AddToggle("klze_instant_hatch", {
    Text = "Instant Hatch (Skip Animation)",
    Default = true,
    Tooltip = "Immediately skips the 3D egg hatch animation and unlocks the UI.",
    Callback = function(v)
        AutoPet.instantHatch = v == true
        AutoPet.syncAutoPetLoop()
    end,
})

hatchBox:AddButton({
    Text = "Refresh Egg List",
    Func = function()
        local labels = AutoPet.buildEggDropdownOptions()
        pcall(function()
            if AutoPet.eggDropdown and type(AutoPet.eggDropdown.SetValues) == "function" then
                AutoPet.eggDropdown:SetValues(labels)
            end
        end)
    end,
    Tooltip = "Refreshes the egg list from EggConfig.",
})

local petManageBox = PetsTab:AddRightGroupbox("Pet Management", "heart")

petManageBox:AddToggle("klze_auto_equip_best", {
    Text = "Auto Equip Best Pets",
    Default = false,
    Tooltip = "Automatically equips your best pets every few seconds and after hatching.",
    Callback = function(v)
        AutoPet.autoEquipBest = v == true
        if AutoPet.autoEquipBest then
            AutoPet.runAutoEquipBest()
        end
        AutoPet.syncAutoPetLoop()
    end,
})

petManageBox:AddButton({
    Text = "Equip Best Pets Now",
    Func = function()
        AutoPet.runAutoEquipBest()
    end,
    Tooltip = "Calls PetService:EquipBest() immediately.",
})

petManageBox:AddDropdown("klze_auto_delete_rarities", {
    Values = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" },
    Default = 0,
    Multi = true,
    Text = "Auto Delete Rarities",
    Tooltip = "Automatically deletes unequipped, unlocked pets of the selected rarities.",
    Callback = function(v)
        if type(v) == "table" then
            AutoPet.autoDeleteRarities = table.clone(v)
        end
        AutoPet.syncAutoDeletePets()
        AutoPet.syncAutoPetLoop()
    end,
})

petManageBox:AddButton({
    Text = "Delete Selected Rarities Now",
    Func = function()
        AutoPet.syncAutoDeletePets()
    end,
    Tooltip = "Immediately deletes unequipped, unlocked pets matching your selected rarities.",
})

end
local PlayerTab = Window:AddTab("Player", "user")
local moveBox = PlayerTab:AddLeftGroupbox("Movement", "footprints")

moveBox:AddToggle("klze_fly", {
    Text = "Fly",
    Default = false,
    Tooltip = "Hold WASD + Space/Ctrl to move through the air.",
    Callback = function(v)
        setFly(v)
    end,
})

moveBox:AddSlider("klze_fly_speed", {
    Text = "Fly speed",
    Default = 200,
    Min = 16,
    Max = 200,
    Rounding = 0,
    Tooltip = "Fly movement speed.",
    Callback = function(v)
        PlayerMods.flySpeed = math.clamp(math.floor(v), 16, 200)
    end,
})

moveBox:AddSlider("klze_walk_speed", {
    Text = "WalkSpeed",
    Default = 48,
    Min = 16,
    Max = 200,
    Rounding = 0,
    Tooltip = "Local WalkSpeed on your character.",
    Callback = function(v)
        PlayerMods.walkSpeed = math.clamp(math.floor(v), 16, 200)
        applyWalkAndJump()
    end,
})

moveBox:AddToggle("klze_inf_jump", {
    Text = "Infinite jump",
    Default = false,
    Tooltip = "Jump again while in the air.",
    Callback = function(v)
        PlayerMods.infJump = v
        if PlayerMods.jumpConn then
            PlayerMods.jumpConn:Disconnect()
            PlayerMods.jumpConn = nil
        end
        if v then
            bindCharacter()
        end
    end,
})

moveBox:AddSlider("klze_jump_height", {
    Text = "Jump height / power",
    Default = 90,
    Min = 7,
    Max = 200,
    Rounding = 0,
    Tooltip = "JumpPower or JumpHeight depending on game.",
    Callback = function(v)
        PlayerMods.jumpHeight = math.clamp(math.floor(v), 7, 200)
        applyWalkAndJump()
    end,
})

Hub.complete(Window, Library, SaveManager, ThemeManager, {
    ToggleKeybind = "RightControl",
    DiscordInvite = DEFAULT_DISCORD,
    SiteUrl = DEFAULT_SITE,
})

task.defer(function()
    resetFeatureStatesOff()
    startPlayerMods()
    AutoPet.syncAutoPetLoop()
    if Library.Toggle and Library.Unloaded ~= true then
        Library:Toggle(true)
    end
end)

if typeof(getgenv) == "function" then
    getgenv().KLZE_PYRAMID_UNLOAD = klzePyramidUnload
    getgenv().KLZE_PYRAMID_CLEANUP = pyramidCleanup
    getgenv().KLZE_PYRAMID_LIBRARY = Library
    getgenv().KLZE_PYRAMID_FARM = Farm
    getgenv().KLZE_PYRAMID_PLAYER = PlayerMods
end

Hub.notify(Library, "KLZE · " .. meta.gameTitle, 5)

task.spawn(function()
    local interactionCtrl = select(1, waitForInteraction())
    if not interactionCtrl then
        Hub.notify(Library, "KLZE", "InteractionController failed — join the map and re-run.", 8)
        return
    end
    if typeof(getgenv) == "function" then
        getgenv().KLZE_PYRAMID_CTRL = interactionCtrl
    end
    bindCoinStatObserver()
    startFarmLoop(interactionCtrl)
    if Farm.enabled then
        Hub.notify(Library, "KLZE", "Auto farm enabled.", 4)
    end
    refreshAutoUpgradeFromSavedToggles()
    refreshAutoTrainFromSavedToggles()
    refreshAutoHillFromSavedToggles()
    pcall(function()
        local labels = AutoPet.buildEggDropdownOptions()
        if AutoPet.eggDropdown and type(AutoPet.eggDropdown.SetValues) == "function" then
            AutoPet.eggDropdown:SetValues(labels)
        end
    end)
end)

task.spawn(function()
    while typeof(getgenv) == "function" and getgenv().KLZE_PYRAMID_LIBRARY == Library do
        local runtime = getActiveRuntime()
        local carried = getRuntimePickupCount(runtime)
        local _, _, capText = getCapacitySnapshot()
        local line = string.format("Carrying: %s / %s", tostring(carried), tostring(capText))
        pcall(function()
            capLabel:SetText(line)
        end)
        local RR = getRegionRegistry()
        local q = isInRegion(RR.Ids.Quarry) and "yes" or "no"
        local p = isInRegion(RR.Ids.Pyramid) and "yes" or "no"
        local farmState = Farm.enabled and "on" or "off"
        local phase = (AutoHill.onHill and AutoHill.remaining > 0 and string.format("hill %ds", math.floor(AutoHill.remaining)))
            or (AutoHill.onHill and "hill")
            or (AutoHill.waiting and "hill wait")
            or (Farm.placingRun and "place")
            or (Farm.enabled and "farm")
            or "idle"
        pcall(function()
            statusLabel:SetText(string.format("Farm: %s (%s) · Quarry: %s · Pyramid: %s", farmState, phase, q, p))
        end)
        task.wait(0.5)
    end
end)
