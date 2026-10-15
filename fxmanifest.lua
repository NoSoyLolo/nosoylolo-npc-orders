fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'nosoylolo-npc-orders'
description 'On-demand NPC customer orders for configurable QBX businesses'

dependencies {
    'qbx_core',
    'ox_lib',
    'ox_target',
    'qs-inventory',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_script 'client.lua'
server_script 'server.lua'
