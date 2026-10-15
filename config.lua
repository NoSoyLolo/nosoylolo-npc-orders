Config = Config or {}

Config.Debug = true
Config.CustomerInterval = { min = 30, max = 60 }
Config.CustomerArrivalTimeout = 90
Config.OrderTimeout = 180
Config.ArrivalCheckInterval = 1000
Config.InteractionDistance = 2.0
Config.OrderDistance = 15.0
Config.DeliveryDistance = 8.0
Config.CustomerCleanupDelay = 12000
Config.CustomerModels = {
    'a_m_y_business_01',
    'a_f_y_business_02',
    'a_m_y_hipster_01',
    'a_f_y_tourist_01',
}

Config.Shops = {
        ['cafe_example'] = {
        label = 'Example Cafe',
        enabled = true,
        jobs = { 'unemployed' }, 
        target = vector4(-563.2656, 287.3626, 82.1764, 87.8149), 
        coords = vector4(-560.2925, 285.1763, 82.1764, 100.4613), 
        spawn = vector4(-577.8942, 273.9105, 82.7091, 264.0448), 
        route = {
            vector3(-564.8314, 273.2143, 83.0196),
            vector3(-564.3700, 277.7553, 83.1363),
            vector3(-560.5391, 277.1336, 82.9764),
        }, 
        payment = {
            type = 'player', 
            account = 'cash', 
            
            
        },
        menu = {
            {
                item = 'sandwich',
                label = 'Sandwich',
                quantity = { min = 1, max = 5 },
                reward = { min = 50, max = 75 }, 
            },
            {
                item = 'coffee',
                label = 'Coffee',
                quantity = { min = 1, max = 5 },
                reward = { min = 40, max = 60 }, 
            },
        },
    },
}
