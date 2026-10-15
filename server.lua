local Orders = {}
local ShopCooldowns = {}
local Shifts = {}
local OrderSequence = 0
local InvalidShopWarnings = {}

local function Debug(message)
    if Config.Debug == true then
        print(('[nosoylolo-npc-orders][server][DEBUG] %s'):format(message))
    end
end

local function GetMinimumCustomerDelay()
    local interval = Config.CustomerInterval
    if type(interval) ~= 'table' then return 30 end

    local minimum = math.max(1, math.floor(tonumber(interval.min) or 30))
    return minimum
end

local function GetShop(shopId)
    local shop = Config.Shops[shopId]
    if type(shop) ~= 'table' or shop.enabled ~= true then return nil end

    local coords = shop.coords
    local spawn = shop.spawn
    local target = shop.target
    local validCoords = coords
        and type(coords.x) == 'number'
        and type(coords.y) == 'number'
        and type(coords.z) == 'number'
        and type(coords.w) == 'number'
    local validSpawn = spawn
        and type(spawn.x) == 'number'
        and type(spawn.y) == 'number'
        and type(spawn.z) == 'number'
        and type(spawn.w) == 'number'
    local validTarget = target
        and type(target.x) == 'number'
        and type(target.y) == 'number'
        and type(target.z) == 'number'
        and type(target.w) == 'number'

    if not validCoords
        or not validSpawn
        or not validTarget
        or type(shop.menu) ~= 'table'
        or (shop.route ~= nil and type(shop.route) ~= 'table')
        or (shop.exitRoute ~= nil and type(shop.exitRoute) ~= 'table')
        or type(shop.label) ~= 'string'
        or shop.label == '' then
        if not InvalidShopWarnings[shopId] then
            print(('[nosoylolo-npc-orders] Enabled shop "%s" has invalid target, coords, spawn, or menu configuration.'):format(tostring(shopId)))
            InvalidShopWarnings[shopId] = true
        end
        return nil
    end
    return shop
end

local function GetDistanceFromShop(playerId, shop)
    local ped = GetPlayerPed(playerId)
    if ped == 0 then return math.huge end

    local playerCoords = GetEntityCoords(ped)
    local shopCoords = vector3(shop.coords.x, shop.coords.y, shop.coords.z)
    return #(playerCoords - shopCoords)
end

local function GetRangeValue(value, defaultValue)
    if type(value) == 'number' then
        return math.floor(value)
    end
    if type(value) ~= 'table' then
        return defaultValue
    end

    local minimum = math.floor(tonumber(value.min) or defaultValue)
    local maximum = math.floor(tonumber(value.max) or minimum)
    if maximum < minimum then
        maximum = minimum
    end
    return math.random(minimum, maximum)
end

local function IsValidRange(value, minimum, maximum)
    if type(value) == 'number' then
        return value % 1 == 0 and value >= minimum and value <= maximum
    end
    if type(value) ~= 'table' then return false end

    local minValue = tonumber(value.min)
    local maxValue = tonumber(value.max)
    return minValue ~= nil
        and maxValue ~= nil
        and minValue % 1 == 0
        and maxValue % 1 == 0
        and minValue >= minimum
        and maxValue <= maximum
        and minValue <= maxValue
end

local function GetAvailableMenu(shop, items)
    local available = {}
    for _, product in ipairs(shop.menu or {}) do
        if type(product) == 'table' then
            local item = type(product.item) == 'string'
                and product.item ~= ''
                and items[product.item]
            local quantity = IsValidRange(product.quantity or 1, 1, 50)
            local reward = IsValidRange(product.reward, 1, 1000000)

            if item and quantity and reward then
                available[#available + 1] = product
            else
                print(('[nosoylolo-npc-orders] Skipping invalid product "%s" in shop "%s". Check its item name and reward config.'):format(
                    tostring(product.item),
                    tostring(shop.label or 'unknown')
                ))
            end
        else
            print(('[nosoylolo-npc-orders] Skipping a non-table product in shop "%s".'):format(tostring(shop.label or 'unknown')))
        end
    end
    return available
end

local function IsAllowedJob(Player, shop)
    if not shop.jobs then return true end
    if type(shop.jobs) ~= 'table' then return false end

    local jobName = Player.PlayerData.job and Player.PlayerData.job.name
    for _, allowedJob in ipairs(shop.jobs) do
        if type(allowedJob) == 'string' and allowedJob == jobName then
            return true
        end
    end
    return false
end

local function SendOrderResult(src, shopId, orderId, success, message, finished)
    TriggerClientEvent(
        'nosoylolo-npc-orders:client:OrderResult',
        src,
        shopId,
        orderId,
        success,
        message,
        finished
    )
end

RegisterNetEvent('nosoylolo-npc-orders:server:SetShift', function(shopId, enabled)
    local src = source
    local shop = GetShop(shopId)
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player or not shop then
        Debug(('Shift request denied for player %s at shop "%s": player or shop unavailable.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:ShiftDenied', src, shopId, 'Este local no está disponible.')
        return
    end

    if enabled ~= true then
        if Shifts[src] then
            Shifts[src][shopId] = nil
            if not next(Shifts[src]) then
                Shifts[src] = nil
            end
        end
        if Orders[src] and Orders[src].shopId == shopId then
            Orders[src] = nil
        end
        Debug(('Shift stopped for player %s at shop "%s".'):format(src, tostring(shopId)))
        return
    end

    if not IsAllowedJob(Player, shop) then
        Debug(('Shift request denied for player %s at shop "%s": job not allowed.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:ShiftDenied', src, shopId, 'No tienes el trabajo requerido para este local.')
        return
    end

    local target = shop.target
    local playerPed = GetPlayerPed(src)
    if not target or playerPed == 0
        or #(GetEntityCoords(playerPed) - vector3(target.x, target.y, target.z)) > 3.0 then
        Debug(('Shift request denied for player %s at shop "%s": too far from target.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:ShiftDenied', src, shopId, 'Debes estar en el mostrador para empezar el turno.')
        return
    end

    Shifts[src] = Shifts[src] or {}
    Shifts[src][shopId] = true
    Debug(('Shift started for player %s at shop "%s".'):format(src, tostring(shopId)))
    TriggerClientEvent('nosoylolo-npc-orders:client:ShiftStarted', src, shopId)
end)

RegisterNetEvent('nosoylolo-npc-orders:server:RequestOrder', function(shopId)
    local src = source
    local shop = GetShop(shopId)
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player or not shop then
        Debug(('Order request ignored for player %s at shop "%s": player or shop unavailable.'):format(src, tostring(shopId)))
        return
    end

    if not Shifts[src] or not Shifts[src][shopId] then
        Debug(('Order request denied for player %s at shop "%s": no active shift.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'Debes empezar tu turno para atender pedidos.')
        return
    end

    if not IsAllowedJob(Player, shop) then
        Debug(('Order request denied for player %s at shop "%s": job not allowed.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'No tienes el trabajo requerido para este local.')
        return
    end

    if Orders[src] and os.time() > Orders[src].expiresAt then
        Orders[src] = nil
    end
    if Orders[src] then
        Debug(('Order request denied for player %s at shop "%s": another order is pending.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'Ya tienes un pedido pendiente.')
        return
    end

    local shopCooldowns = ShopCooldowns[src] or {}
    ShopCooldowns[src] = shopCooldowns
    if os.time() < (shopCooldowns[shopId] or 0) then
        Debug(('Order request denied for player %s at shop "%s": cooldown active.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'Espera un momento antes del próximo cliente.')
        return
    end

    if GetDistanceFromShop(src, shop) > Config.OrderDistance then
        Debug(('Order request denied for player %s at shop "%s": too far from counter.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'Acércate al mostrador para tomar el pedido.')
        return
    end

    local items = exports['qs-inventory']:GetItemList()
    local menu = GetAvailableMenu(shop, items)
    if #menu == 0 then
        Debug(('Order request denied for player %s at shop "%s": no valid menu products.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'Este local no tiene productos válidos configurados.')
        return
    end

    local product = menu[math.random(1, #menu)]
    local amount = GetRangeValue(product.quantity or 1, 1)
    local unitReward = GetRangeValue(product.reward, 1)

    local payment = shop.payment or {}
    if type(payment) ~= 'table' then
        Debug(('Order request denied for player %s at shop "%s": payment config is not a table.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'El pago de este local está mal configurado.')
        return
    end
    local paymentType = payment.type or 'player'
    local paymentAccount = payment.account or 'cash'
    if paymentType ~= 'player' and paymentType ~= 'item' and paymentType ~= 'society' then
        Debug(('Order request denied for player %s at shop "%s": unsupported payment type "%s".'):format(
            src,
            tostring(shopId),
            tostring(paymentType)
        ))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'El pago debe ser player, item o society.')
        return
    end
    if paymentAccount ~= 'cash' and paymentAccount ~= 'bank' then
        Debug(('Order request denied for player %s at shop "%s": unsupported account "%s".'):format(
            src,
            tostring(shopId),
            tostring(paymentAccount)
        ))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'El método de pago de este local debe ser cash o bank.')
        return
    end
    if paymentType == 'item'
        and (type(payment.item) ~= 'string'
            or payment.item == ''
            or not items[payment.item]) then
        Debug(('Order request denied for player %s at shop "%s": invalid payment item.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'Configura un item de pago válido en payment.item.')
        return
    end
    if paymentType == 'society' and (type(payment.society) ~= 'string' or payment.society == '') then
        Debug(('Order request denied for player %s at shop "%s": society is not configured.'):format(src, tostring(shopId)))
        TriggerClientEvent('nosoylolo-npc-orders:client:OrderFailed', src, shopId, 'Configura payment.society para este local.')
        return
    end

    OrderSequence = OrderSequence + 1
    local orderId = ('%s:%s:%s'):format(src, os.time(), OrderSequence)
    local itemInfo = items[product.item]
    local order = {
        id = orderId,
        shopId = shopId,
        item = product.item,
        label = product.label or itemInfo.label or product.item,
        amount = amount,
        unitReward = unitReward,
        total = amount * unitReward,
        account = paymentAccount,
        paymentType = paymentType,
        paymentItem = payment.item,
        society = payment.society,
        expiresAt = os.time() + Config.OrderTimeout,
    }

    Orders[src] = order
    shopCooldowns[shopId] = os.time() + GetMinimumCustomerDelay()
    Debug(('Created order "%s" for player %s at shop "%s": %sx %s, total $%s (%s payment).'):format(
        order.id,
        src,
        tostring(shopId),
        order.amount,
        order.label,
        order.total,
        order.paymentType
    ))
    TriggerClientEvent('nosoylolo-npc-orders:client:OrderCreated', src, shopId, {
        id = order.id,
        label = order.label,
        amount = order.amount,
        total = order.total,
    })
end)

RegisterNetEvent('nosoylolo-npc-orders:server:CompleteOrder', function(shopId, orderId)
    local src = source
    local order = Orders[src]
    local shop = GetShop(shopId)
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player or not shop or not order or order.id ~= orderId or order.shopId ~= shopId
        or not Shifts[src] or not Shifts[src][shopId] then
        Debug(('Order completion rejected for player %s at shop "%s" (order: %s): order, shop, player, or shift invalid.'):format(
            src,
            tostring(shopId),
            tostring(orderId)
        ))
        SendOrderResult(src, shopId, orderId, false, 'El pedido ya no está disponible.', true)
        return
    end

    if not IsAllowedJob(Player, shop) then
        Debug(('Order "%s" rejected for player %s: job no longer allowed.'):format(tostring(orderId), src))
        SendOrderResult(src, shopId, orderId, false, 'No tienes el trabajo requerido para este local.', true)
        return
    end

    if os.time() > order.expiresAt then
        Orders[src] = nil
        Debug(('Order "%s" expired for player %s.'):format(tostring(orderId), src))
        SendOrderResult(src, shopId, orderId, false, 'El pedido venció.', true)
        return
    end

    if GetDistanceFromShop(src, shop) > Config.DeliveryDistance then
        Debug(('Order "%s" delivery rejected for player %s: too far from shop "%s".'):format(
            tostring(orderId),
            src,
            tostring(shopId)
        ))
        SendOrderResult(src, shopId, orderId, false, 'Debes entregar el pedido en el local.', false)
        return
    end

    local itemCount = exports['qs-inventory']:GetItemTotalAmount(src, order.item)
    if (tonumber(itemCount) or 0) < order.amount then
        Debug(('Order "%s" delivery rejected for player %s: has %s/%s %s.'):format(
            tostring(orderId),
            src,
            tostring(itemCount or 0),
            order.amount,
            order.item
        ))
        SendOrderResult(src, shopId, orderId, false, ('Te falta %sx %s.'):format(order.amount, order.label), false)
        return
    end

    if not exports['qs-inventory']:RemoveItem(src, order.item, order.amount) then
        Debug(('Could not remove %sx %s from player %s for order "%s".'):format(
            order.amount,
            order.item,
            src,
            tostring(orderId)
        ))
        SendOrderResult(src, shopId, orderId, false, 'No se pudo retirar el producto de tu inventario.', false)
        return
    end

    local paid = false
    if order.paymentType == 'society' then
        if type(order.society) ~= 'string' or order.society == '' then
            SendOrderResult(src, shopId, orderId, false, 'El pago a la sociedad de este local no está configurado.', false)
            return
        end

        if GetResourceState('qb-management') == 'started' then
            local ok, result = pcall(function()
                return exports['qb-management']:AddMoney(order.society, order.total)
            end)
            paid = ok and result ~= false
            if not ok then
                print(('[nosoylolo-npc-orders] Society payment failed for "%s": %s'):format(order.society, result))
            end
        end
    elseif order.paymentType == 'item' then
        paid = exports['qs-inventory']:AddItem(src, order.paymentItem, order.total)
    else
        local ok, result = pcall(function()
            return Player.Functions.AddMoney(order.account, order.total, 'business-npc-order')
        end)
        paid = ok and result ~= false
        if not ok then
            print(('[nosoylolo-npc-orders] Player payment failed for %s: %s'):format(src, result))
        end
    end

    if not paid then
        Debug(('Payment failed for order "%s" (type: %s) for player %s.'):format(
            tostring(orderId),
            order.paymentType,
            src
        ))
        local restored = exports['qs-inventory']:AddItem(src, order.item, order.amount)
        if restored then
            Debug(('Payment failed for order "%s"; restored %sx %s to player %s.'):format(
                tostring(orderId),
                order.amount,
                order.item,
                src
            ))
            local paymentError = order.paymentType == 'society'
                and 'No se pudo pagar a la sociedad; se devolvió el producto.'
                or 'No se pudo entregar el pago; se devolvió el producto.'
            SendOrderResult(src, shopId, orderId, false, paymentError, false)
        else
            Orders[src] = nil
            print(('[nosoylolo-npc-orders] Failed to pay or restore %sx %s for player %s.'):format(
                order.amount,
                order.item,
                src
            ))
            SendOrderResult(src, shopId, orderId, false, 'Hubo un error al procesar el pago. Contacta a un administrador.', true)
        end
        return
    end

    Orders[src] = nil
    Debug(('Order "%s" completed for player %s; paid $%s.'):format(tostring(orderId), src, order.total))
    SendOrderResult(
        src,
        shopId,
        orderId,
        true,
        ('Pedido entregado: recibiste $%s.'):format(order.total),
        true
    )
end)

RegisterNetEvent('nosoylolo-npc-orders:server:CancelOrder', function(shopId, orderId)
    local src = source
    local order = Orders[src]
    if order and order.shopId == shopId and order.id == orderId then
        Orders[src] = nil
        Debug(('Order "%s" cancelled by player %s at shop "%s".'):format(tostring(orderId), src, tostring(shopId)))
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    Debug(('Cleared active state for disconnected player %s.'):format(src))
    Orders[src] = nil
    ShopCooldowns[src] = nil
    Shifts[src] = nil
end)

Debug('Server initialized.')
