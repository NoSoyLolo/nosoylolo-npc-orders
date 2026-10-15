# nosoylolo-npc-orders

Standalone on-demand NPC customers and configurable orders for Qbox businesses.
No dependency on a particular job or business script.

## Dependencies

- `qbx_core`
- `ox_lib`
- `ox_target`
- `qs-inventory`
- Optional: `qb-management` for society payouts

Start dependencies first, then add to `server.cfg`:

```cfg
ensure nosoylolo-npc-orders
```

Configure locations in `config.lua` and restart this resource for changes to
take effect. This resource uses QBX APIs directly and does not require the
`qbx:enableBridge` compatibility convar.

Set `Config.Debug = true` in `config.lua` to print client and server flow
messages to the respective game/server consoles while testing. Set it to
`false` to disable those debug messages.

After starting a shift, the first customer arrives after 50 seconds. Later
customers use the delay configured by `CustomerInterval`.

## Add a business location

Copy this entry into `Config.Shops`. Replace coordinates and item IDs with the
ones used by your server:

```lua
['my_cafe'] = {
    label = 'My Cafe',
    enabled = true,
    jobs = { 'cafe' }, -- Optional; omit to let any job serve.
    target = vector4(x, y, z, heading), -- Employee starts/ends their shift here
    coords = vector4(x, y, z, heading), -- Where customer waits to order
    spawn = vector4(x, y, z, heading), -- Hidden/out-of-sight point near entrance
    route = { -- Optional navigation waypoints, in order, between spawn and counter
        vector3(x1, y1, z1),
        vector3(x2, y2, z2),
    },
    exitRoute = { -- Optional waypoints from counter back toward spawn
        vector3(x2, y2, z2),
        vector3(x1, y1, z1),
    },
    payment = {
        type = 'player', -- 'player', 'item', or 'society'
        account = 'cash', -- Player account: 'cash' or 'bank'
        -- item = 'money', -- Required when type = 'item'
        -- society = 'cafe', -- Required when type = 'society'
    },
    menu = {
        {
            item = 'sandwich', -- Exact qs-inventory item ID
            label = 'Sandwich',
            quantity = { min = 1, max = 2 },
            reward = { min = 50, max = 75 }, -- Reward per item
        },
        {
            item = 'coffee',
            label = 'Coffee',
            quantity = 1,
            reward = 40,
        },
    },
},
```

The total payment is `quantity * per-item reward`. `quantity` and `reward`
accept either a fixed number or a `{ min = ..., max = ... }` range. NPCs only
order products in that location's menu, so each business can have its own
products and prices.

Payment options:

- `type = 'player'`: add money to the employee's configured `cash` or `bank`.
- `type = 'item'`: add the configured currency item to `qs-inventory`.
- `type = 'society'`: add money to the configured society with the optional
  `qb-management` resource. Player and item payments do not require it.

Set `enabled = false` to pause a location. Add or remove entries to manage
locations. `jobs` restricts who can start a shift. The employee uses the
`ox_target` point to start and finish their shift.

## Customer flow and performance

Each employee sees their own NPC. No customers are created before the employee
starts a shift. A customer is spawned at `spawn`, follows the optional route
and walks to `coords`, requests a configured product, then waits for the
employee to use `ox_target` to deliver or reject the order. On departure, the
customer follows `exitRoute` if configured; otherwise, it retraces `route` in
reverse. In either case, it then walks to `spawn` and is deleted after reaching
it and waiting `CustomerCleanupDelay`. Configure waypoints around walls and
through doorways when a direct path is blocked.

There is no ambient pedestrian scan or idle polling loop. The only arrival
check runs while that employee's active customer is walking.

The server validates the active shift, job, order ID and expiry, shop distance,
and `qs-inventory` item count before removing products or paying. NPC entities
are client-local, so each employee handles an independent customer.
