local PlayerData = exports.qbx_core:GetPlayerData() or {}
local Shifts = {}
local PendingShifts = {}
local Customers = {}
local DepartingPeds = {}
local ShopZones = {}
local SpawnGeneration = {}
local ResourceStopping = false
local SpawnCustomer

local function Debug(message)
    if Config.Debug == true then
        print(('[nosoylolo-npc-orders][client][DEBUG] %s'):format(message))
    end
end

local function Notify(description, notificationType)
    lib.notify({
        title = 'Pedidos del local',
        description = description,
        type = notificationType or 'inform',
    })
end

local function GetCustomerDelay()
    local interval = Config.CustomerInterval
    if type(interval) ~= 'table' then return 30 end

    local minimum = math.max(1, math.floor(tonumber(interval.min) or 30))
    local maximum = math.max(minimum, math.floor(tonumber(interval.max) or minimum))
    return math.random(minimum, maximum)
end

local function IsEmployee(shop)
    if not shop.jobs then return true end
    if type(shop.jobs) ~= 'table' then return false end
    local jobName = PlayerData.job and PlayerData.job.name
    if not jobName then return false end

    for _, allowedJob in ipairs(shop.jobs) do
        if allowedJob == jobName then
            return true
        end
    end
    return false
end

local function GetVectorDistance(first, second)
    return #(vector3(first.x, first.y, first.z) - vector3(second.x, second.y, second.z))
end

local function LoadPedModel(modelName)
    local model = type(modelName) == 'number' and modelName or GetHashKey(modelName)
    if not IsModelInCdimage(model) or not IsModelValid(model) then
        print(('[nosoylolo-npc-orders] Invalid customer model "%s".'):format(tostring(modelName)))
        return nil
    end

    RequestModel(model)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(model) and GetGameTimer() < timeout do
        Wait(50)
    end

    if not HasModelLoaded(model) then
        print(('[nosoylolo-npc-orders] Timed out loading customer model "%s".'):format(tostring(modelName)))
        return nil
    end
    return model
end

local function RemoveCustomerTarget(customer)
    if customer.targetAdded and customer.ped and DoesEntityExist(customer.ped) then
        exports.ox_target:removeLocalEntity(customer.ped, {
            customer.targetOption,
            customer.targetOption .. '_decline',
        })
        customer.targetAdded = false
    end
end

local function CancelServerOrder(shopId, customer)
    if customer.order and not customer.orderCompleted then
        TriggerServerEvent('nosoylolo-npc-orders:server:CancelOrder', shopId, customer.order.id)
    end
end

local function ScheduleNextCustomer(shopId, afterDelay)
    if ResourceStopping or not Shifts[shopId] then return end

    local delay
    if afterDelay then
        delay = math.max(0, afterDelay)
    else
        delay = GetCustomerDelay()
    end
    local generation = SpawnGeneration[shopId] or 0
    Debug(('Next customer for shop "%s" scheduled in %s seconds.'):format(shopId, delay))
    SetTimeout(delay * 1000, function()
        if not ResourceStopping
            and Shifts[shopId]
            and (SpawnGeneration[shopId] or 0) == generation then
            SpawnCustomer(shopId)
        end
    end)
end

local function LeaveCustomer(shopId, customer, immediate)
    if Customers[shopId] ~= customer then return end

    Debug(('Customer leaving shop "%s" (immediate: %s).'):format(shopId, tostring(immediate)))
    Customers[shopId] = nil
    RemoveCustomerTarget(customer)
    CancelServerOrder(shopId, customer)

    local ped = customer.ped
    if ped and DoesEntityExist(ped) then
        FreezeEntityPosition(ped, false)
        SetEntityInvincible(ped, false)
        ClearPedTasks(ped)

        if immediate then
            DeleteEntity(ped)
        else
            DepartingPeds[ped] = true
            CreateThread(function()
                local exitRoute = {}
                if customer.shop.exitRoute then
                    for _, waypoint in ipairs(customer.shop.exitRoute) do
                        exitRoute[#exitRoute + 1] = waypoint
                    end
                else
                    for index = #(customer.shop.route or {}), 1, -1 do
                        exitRoute[#exitRoute + 1] = customer.shop.route[index]
                    end
                end
                exitRoute[#exitRoute + 1] = customer.shop.spawn

                local deadline = GetGameTimer() + Config.CustomerArrivalTimeout * 1000
                for _, waypoint in ipairs(exitRoute) do
                    if not waypoint
                        or type(waypoint.x) ~= 'number'
                        or type(waypoint.y) ~= 'number'
                        or type(waypoint.z) ~= 'number' then
                        print(('[nosoylolo-npc-orders] Invalid exit route waypoint in shop "%s".'):format(shopId))
                        break
                    end

                    TaskGoStraightToCoord(
                        ped,
                        waypoint.x,
                        waypoint.y,
                        waypoint.z,
                        1.0,
                        -1,
                        customer.shop.spawn.w,
                        0.0
                    )
                    while DoesEntityExist(ped)
                        and GetVectorDistance(GetEntityCoords(ped), waypoint) > 1.0
                        and GetGameTimer() < deadline do
                        Wait(Config.ArrivalCheckInterval)
                    end

                    if not DoesEntityExist(ped) then break end
                    if GetGameTimer() >= deadline
                        and GetVectorDistance(GetEntityCoords(ped), waypoint) > 1.0 then
                        Debug(('Customer exit route timed out at shop "%s".'):format(shopId))
                        break
                    end
                end

                if DoesEntityExist(ped) then
                    Wait(Config.CustomerCleanupDelay)
                    if DoesEntityExist(ped) then
                        DeleteEntity(ped)
                    end
                end
                DepartingPeds[ped] = nil
            end)
        end
    end

    if Shifts[shopId] then
        ScheduleNextCustomer(shopId)
    end
end

local function FinishShift(shopId)
    if not Shifts[shopId] then return end
    SpawnGeneration[shopId] = (SpawnGeneration[shopId] or 0) + 1
    Debug(('Finishing shift at shop "%s".'):format(shopId))
    Shifts[shopId] = nil
    TriggerServerEvent('nosoylolo-npc-orders:server:SetShift', shopId, false)
    local customer = Customers[shopId]
    if customer then
        LeaveCustomer(shopId, customer, true)
    end
    Notify(('Finalizaste el turno en %s.'):format(Config.Shops[shopId].label), 'inform')
end

local function AddOrderTarget(shopId, customer)
    local order = customer.order
    customer.targetOption = ('business_order_%s_%s'):format(shopId, order.id)
    customer.targetAdded = true

    exports.ox_target:addLocalEntity(customer.ped, {
        {
            name = customer.targetOption,
            icon = 'fa-solid fa-bag-shopping',
            label = ('Entregar %sx %s ($%s)'):format(order.amount, order.label, order.total),
            distance = Config.InteractionDistance,
            canInteract = function(entity)
                return Customers[shopId] == customer
                    and entity == customer.ped
                    and DoesEntityExist(entity)
                    and not IsEntityDead(entity)
            end,
            onSelect = function()
                if customer.submitting or Customers[shopId] ~= customer then return end
                customer.submitting = true
                Debug(('Submitting order "%s" at shop "%s".'):format(order.id, shopId))
                TriggerServerEvent('nosoylolo-npc-orders:server:CompleteOrder', shopId, order.id)
            end,
        },
        {
            name = customer.targetOption .. '_decline',
            icon = 'fa-solid fa-xmark',
            label = 'Rechazar pedido',
            distance = Config.InteractionDistance,
            canInteract = function(entity)
                return Customers[shopId] == customer
                    and entity == customer.ped
                    and DoesEntityExist(entity)
                    and not IsEntityDead(entity)
            end,
            onSelect = function()
                if Customers[shopId] ~= customer then return end
                Debug(('Declining order "%s" at shop "%s".'):format(order.id, shopId))
                TriggerServerEvent('nosoylolo-npc-orders:server:CancelOrder', shopId, order.id)
                Notify('Rechazaste el pedido.', 'inform')
                LeaveCustomer(shopId, customer, false)
            end,
        },
    })
end

SpawnCustomer = function(shopId)
    local shop = Config.Shops[shopId]
    if ResourceStopping or not Shifts[shopId] or Customers[shopId] or not shop or shop.enabled ~= true then
        return
    end

    if not IsEmployee(shop) then
        FinishShift(shopId)
        Notify('Ya no tienes el trabajo requerido para este local.', 'error')
        return
    end

    if type(Config.CustomerModels) ~= 'table' or #Config.CustomerModels == 0 then
        print('[nosoylolo-npc-orders] Config.CustomerModels must contain at least one ped model.')
        return
    end

    local customer = {
        shop = shop,
        order = nil,
        requestingOrder = false,
        orderCompleted = false,
        targetAdded = false,
    }
    Customers[shopId] = customer
    Debug(('Spawning customer for shop "%s".'):format(shopId))

    CreateThread(function()
        local modelName = Config.CustomerModels[math.random(1, #Config.CustomerModels)]
        local model = LoadPedModel(modelName)
        if not model then
            if Customers[shopId] == customer then
                Customers[shopId] = nil
                ScheduleNextCustomer(shopId)
            end
            return
        end

        if ResourceStopping or Customers[shopId] ~= customer or not Shifts[shopId] then
            SetModelAsNoLongerNeeded(model)
            return
        end

        local ped = CreatePed(4, model, shop.spawn.x, shop.spawn.y, shop.spawn.z, shop.spawn.w, false, false)
        SetModelAsNoLongerNeeded(model)
        if not DoesEntityExist(ped) then
            print(('[nosoylolo-npc-orders] Could not spawn a customer for shop "%s".'):format(shopId))
            if Customers[shopId] == customer then
                Customers[shopId] = nil
                ScheduleNextCustomer(shopId)
            end
            return
        end

        customer.ped = ped
        Debug(('Customer ped created for shop "%s" (model: %s).'):format(shopId, tostring(modelName)))
        SetEntityAsMissionEntity(ped, true, true)
        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        SetPedFleeAttributes(ped, 0, false)
        SetPedCanRagdoll(ped, false)

        local deadline = GetGameTimer() + Config.CustomerArrivalTimeout * 1000
        local route = {}
        for _, waypoint in ipairs(shop.route or {}) do
            route[#route + 1] = waypoint
        end
        route[#route + 1] = shop.coords

        local reachedCounter = true
        for _, waypoint in ipairs(route) do
            if not waypoint
                or type(waypoint.x) ~= 'number'
                or type(waypoint.y) ~= 'number'
                or type(waypoint.z) ~= 'number' then
                print(('[nosoylolo-npc-orders] Invalid route waypoint in shop "%s".'):format(shopId))
                reachedCounter = false
                break
            end

            TaskGoStraightToCoord(ped, waypoint.x, waypoint.y, waypoint.z, 1.0, -1, shop.coords.w, 0.0)
            while Customers[shopId] == customer
                and Shifts[shopId]
                and DoesEntityExist(ped)
                and GetVectorDistance(GetEntityCoords(ped), waypoint) > 1.0
                and GetGameTimer() < deadline do
                Wait(Config.ArrivalCheckInterval)
            end

            if Customers[shopId] ~= customer or not Shifts[shopId] or not DoesEntityExist(ped) then
                return
            end
            if GetGameTimer() >= deadline and GetVectorDistance(GetEntityCoords(ped), waypoint) > 1.0 then
                reachedCounter = false
                break
            end
        end

        if Customers[shopId] ~= customer or not Shifts[shopId] then return end
        if not reachedCounter or not DoesEntityExist(ped)
            or GetVectorDistance(GetEntityCoords(ped), shop.coords) > 2.0 then
            Debug(('Customer failed to reach the counter at shop "%s".'):format(shopId))
            Notify('El cliente no pudo llegar al mostrador.', 'error')
            LeaveCustomer(shopId, customer, true)
            return
        end

        Debug(('Customer reached the counter at shop "%s"; requesting an order.'):format(shopId))
        SetEntityInvincible(ped, false)
        TaskTurnPedToFaceEntity(ped, PlayerPedId(), 2000)
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT_UPRIGHT', 0, true)
        customer.requestingOrder = true
        TriggerServerEvent('nosoylolo-npc-orders:server:RequestOrder', shopId)

        customer.orderDeadline = GetGameTimer() + Config.OrderTimeout * 1000
        SetTimeout(Config.OrderTimeout * 1000, function()
            if Customers[shopId] == customer and not customer.orderCompleted then
                Notify('El cliente se fue porque el pedido venció.', 'error')
                LeaveCustomer(shopId, customer, false)
            end
        end)
    end)
end

local function StartShift(shopId)
    if Shifts[shopId] or PendingShifts[shopId] then return end
    local shop = Config.Shops[shopId]
    if not shop or shop.enabled ~= true or not IsEmployee(shop) then
        Notify('No tienes permiso para atender este local.', 'error')
        return
    end

    PendingShifts[shopId] = true
    SpawnGeneration[shopId] = (SpawnGeneration[shopId] or 0) + 1
    Debug(('Requesting shift start at shop "%s".'):format(shopId))
    TriggerServerEvent('nosoylolo-npc-orders:server:SetShift', shopId, true)
end

local function AddShopZone(shopId, shop)
    local target = shop.target
    if not target
        or type(shop.label) ~= 'string'
        or shop.label == ''
        or type(target.x) ~= 'number'
        or type(target.y) ~= 'number'
        or type(target.z) ~= 'number'
        or type(target.w) ~= 'number'
        or not shop.coords
        or type(shop.coords.x) ~= 'number'
        or type(shop.coords.y) ~= 'number'
        or type(shop.coords.z) ~= 'number'
        or type(shop.coords.w) ~= 'number'
        or not shop.spawn
        or type(shop.spawn.x) ~= 'number'
        or type(shop.spawn.y) ~= 'number'
        or type(shop.spawn.z) ~= 'number'
        or type(shop.spawn.w) ~= 'number'
        or type(shop.menu) ~= 'table'
        or (shop.route ~= nil and type(shop.route) ~= 'table') then
        print(('[nosoylolo-npc-orders] Enabled shop "%s" must define vector4 target, coords, spawn, a menu, and an optional route table.'):format(shopId))
        return
    end
    if shop.exitRoute ~= nil and type(shop.exitRoute) ~= 'table' then
        print(('[nosoylolo-npc-orders] Enabled shop "%s" must define exitRoute as a waypoint table when provided.'):format(shopId))
        return
    end

    ShopZones[shopId] = exports.ox_target:addBoxZone({
        coords = vector3(target.x, target.y, target.z),
        size = shop.targetSize or vec3(1.5, 1.5, 2.0),
        rotation = target.w,
        debug = shop.debug == true,
        options = {
            {
                name = ('business_shift_start_%s'):format(shopId),
                icon = 'fa-solid fa-user-clock',
                label = ('Empezar turno - %s'):format(shop.label),
                canInteract = function()
                    return not Shifts[shopId] and not PendingShifts[shopId] and IsEmployee(shop)
                end,
                onSelect = function()
                    StartShift(shopId)
                end,
            },
            {
                name = ('business_shift_stop_%s'):format(shopId),
                icon = 'fa-solid fa-stop',
                label = ('Finalizar turno - %s'):format(shop.label),
                canInteract = function()
                    return Shifts[shopId] == true
                end,
                onSelect = function()
                    FinishShift(shopId)
                end,
            },
        },
    })
    Debug(('Registered shift interaction for shop "%s" (zone: %s).'):format(shopId, tostring(ShopZones[shopId])))
end

for shopId, shop in pairs(Config.Shops) do
    if type(shop) == 'table' and shop.enabled == true then
        AddShopZone(shopId, shop)
    end
end
Debug('Client initialized.')

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = exports.qbx_core:GetPlayerData() or {}
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    PlayerData.job = job
    for shopId in pairs(Shifts) do
        if not IsEmployee(Config.Shops[shopId]) then
            FinishShift(shopId)
        end
    end
end)

RegisterNetEvent('qbx_core:client:playerLoggedOut', function()
    local activeShops = {}
    for shopId in pairs(Shifts) do
        activeShops[#activeShops + 1] = shopId
    end
    for _, shopId in ipairs(activeShops) do
        FinishShift(shopId)
    end
    PendingShifts = {}
    PlayerData = {}
end)

RegisterNetEvent('nosoylolo-npc-orders:client:ShiftStarted', function(shopId)
    if not PendingShifts[shopId] then
        TriggerServerEvent('nosoylolo-npc-orders:server:SetShift', shopId, false)
        return
    end
    PendingShifts[shopId] = nil

    local shop = Config.Shops[shopId]
    if not shop or not IsEmployee(shop) then
        TriggerServerEvent('nosoylolo-npc-orders:server:SetShift', shopId, false)
        return
    end

    Shifts[shopId] = true
    Debug(('Shift started at shop "%s".'):format(shopId))
    Notify(('Empezaste tu turno en %s.'):format(shop.label), 'success')
    ScheduleNextCustomer(shopId, 50)
end)

RegisterNetEvent('nosoylolo-npc-orders:client:ShiftDenied', function(shopId, message)
    PendingShifts[shopId] = nil
    Debug(('Shift denied at shop "%s": %s'):format(tostring(shopId), tostring(message)))
    Notify(message, 'error')
end)

RegisterNetEvent('nosoylolo-npc-orders:client:OrderCreated', function(shopId, order)
    local customer = Customers[shopId]
    if not customer or not customer.requestingOrder or not order then
        Debug(('Received an unexpected order response for shop "%s"; cancelling it.'):format(tostring(shopId)))
        if order then
            TriggerServerEvent('nosoylolo-npc-orders:server:CancelOrder', shopId, order.id)
        end
        return
    end

    customer.requestingOrder = false
    customer.order = order
    Debug(('Order "%s" received at shop "%s": %sx %s, total $%s.'):format(
        tostring(order.id),
        shopId,
        tostring(order.amount),
        tostring(order.label),
        tostring(order.total)
    ))
    AddOrderTarget(shopId, customer)
end)

RegisterNetEvent('nosoylolo-npc-orders:client:OrderFailed', function(shopId, message)
    local customer = Customers[shopId]
    if not customer then return end

    Debug(('Order request failed at shop "%s": %s'):format(tostring(shopId), tostring(message)))
    Notify(message, 'error')
    LeaveCustomer(shopId, customer, false)
end)

RegisterNetEvent('nosoylolo-npc-orders:client:OrderResult', function(shopId, orderId, success, message, finished)
    Debug(('Order "%s" at shop "%s" completed: %s (finished: %s): %s'):format(
        tostring(orderId),
        tostring(shopId),
        tostring(success),
        tostring(finished),
        tostring(message)
    ))
    Notify(message, success and 'success' or 'error')
    local customer = Customers[shopId]
    if not customer or not customer.order or customer.order.id ~= orderId then return end

    customer.submitting = false
    if finished then
        customer.orderCompleted = success
        if success and customer.ped and DoesEntityExist(customer.ped) then
            RemoveCustomerTarget(customer)
            ClearPedTasks(customer.ped)
            TaskStartScenarioInPlace(customer.ped, 'WORLD_HUMAN_CHEERING', 0, true)
            SetTimeout(1200, function()
                if Customers[shopId] == customer then
                    LeaveCustomer(shopId, customer, false)
                end
            end)
        else
            LeaveCustomer(shopId, customer, false)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ResourceStopping = true
    for shopId, customer in pairs(Customers) do
        CancelServerOrder(shopId, customer)
        RemoveCustomerTarget(customer)
        if customer.ped and DoesEntityExist(customer.ped) then
            DeleteEntity(customer.ped)
        end
    end
    for ped in pairs(DepartingPeds) do
        if DoesEntityExist(ped) then
            DeleteEntity(ped)
        end
    end
    DepartingPeds = {}
    for shopId in pairs(Shifts) do
        TriggerServerEvent('nosoylolo-npc-orders:server:SetShift', shopId, false)
    end

    for _, zoneId in pairs(ShopZones) do
        exports.ox_target:removeZone(zoneId)
    end
end)
