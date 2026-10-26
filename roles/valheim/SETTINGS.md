# Valheim mod settings

<!-- Hand-written, unlike CLIENT_MODS.md beside it. Keep both in step
     when a mod is added or removed in valheim_mods. -->

Which mods to install is in [CLIENT_MODS.md](CLIENT_MODS.md). This
file is about what to change once they are installed: first the
settings each player changes on their own client, then the ones only
the server admin can change.

Most mods here keep their settings on the server and push them to
every client when it connects. Changing those on your own client does
nothing, or is reset as soon as you join. That is why the player
section is short.

## Every player

Change these in game with [ConfigurationManager](https://thunderstore.io/c/valheim/p/shudnal/ConfigurationManager/)
(press `F1`), which comes with the profile, or edit the file under
`BepInEx/config/` in your r2modman profile (*Config editor* in
r2modman) and restart the game.

### Shared map markers (ServerSideMap)

The explored map is shared automatically. Markers (pins) are **not**:
every player has to switch that on for themselves. The server allows
it (see *Allowing shared map markers* below).

- File: `eu.mydayyy.plugins.serversidemap.cfg`, section `[General]`
- `EnableMarkerShare = true` (default `false`)
- Restart the game afterwards.

New pins are uploaded from then on. To upload the pins you already
had, type `/convertpins` in chat, or `/convertpins ignorelocaldupes`
to skip any that already have a shared pin within 15 m.
`/deletealllocalpins` deletes your local pins and **cannot be
undone**.

### Portal previews (PortalPeek)

[PortalPeek](https://thunderstore.io/c/valheim/p/tboods/PortalPeek/)
comes with the profile. It shows a snapshot of what is on the other
side of a portal, not a live view. The server does not check for it,
so you can disable it in r2modman if you would rather not have it.

- A snapshot is taken when two portals are linked. Stand within about
  12 m of the portal for about 5 seconds.
- `RefreshMinutes` (default `30`): an older snapshot is taken again
  the next time you are near the portal.
- `RecaptureKey` (default `Ctrl+F8`): take a new snapshot now, while
  standing next to the portal.
- Turn off any other portal mod that changes what is shown inside the
  portal ring, since the two can conflict.

## Server admin

Only the admin can change these. They live on the server, in
`/srv/valheim/config/bepinex/` on carcosa. This directory is the live
`BepInEx/config` and is edited there by hand: the repository installs
the mods, but it does not manage their settings - apart from the
WebMap file it creates once, and the few single keys listed in
`valheim_mod_settings` in `roles/valheim/defaults/main.yml`. **Change
those in the repository, not on the host**: the next deploy writes
them back. They are marked *(set by the repository)* below.

Restart the server after editing, which drops anyone who is
connected:

```sh
docker compose --project-directory /etc/valheim restart
```

The world modifiers are the exception: they are set in this
repository, in `valheim.server.args` in
`inventories/group_vars/production/valheim.yml`, and deployed with
the `valheim` playbook.

### Carry limit (ServersideQoL_ControlCenter)

- File: `ArgusMagnus.ServersideQoL.ControlCenter.cfg`, section
  `[GlobalKeys]`
- `CarryWeightRate = 150` *(set by the repository)*: the carry limit
  is 150 % of vanilla's (vanilla `100`, default `NotSet` = vanilla).

ControlCenter writes it into the world as a global key, and the server
sends that to every player, so nobody installs anything for it. The
key stays in the world save even if the mod is removed: set it back
to `NotSet` and restart once before removing the mod.

### Item weights (ItemStacksItemWeights)

Making items lighter raises what players can carry as well, on top
of the carry limit above:

- File: `shudnal.ItemStacksItemWeights.yml`
- `WeightMultiplier` → `Global: 0.5` halves every item's weight, so
  players carry about twice as much.
- `WeightAmount` → `<PrefabName>: <weight>` sets a single item's
  weight, and takes priority over the multiplier.

The server pushes these values to every client.

DropMoreLoot can change item weights as well. Set weights in only one
of the two mods and leave the other at its defaults: if both change
them, whichever loads last wins.

**This server currently uses DropMoreLoot for it**, not
ItemStacksItemWeights: `TastyChickenLegs.DropMoreLoot.cfg` has
`percentofweight = 0.197` (default `0.5`), and ItemStacksItemWeights
is at its defaults. Change the weight there, or move it to
ItemStacksItemWeights and put DropMoreLoot's value back to `0.5`.

### Larger stacks (ItemStacksItemWeights)

Same file:

- `StackMultiplier` → `Global: 2` doubles every stack size.
- `StackSize` → `<PrefabName>: <size>` sets a single item's stack size,
  and takes priority over the multiplier.

The exact item names are listed in the `Items stacks and weights.txt`
file the mod writes, or by the `iwisdocs` console command.

The same rule applies here: DropMoreLoot also has item stacking, so
leave stack sizes in DropMoreLoot at its defaults.

### Base raids

Three things make raids hard here, and they add up:

1. **More raids, by world modifier.** `-modifier raids more` in
   `valheim.server.args`. Change it to `default` or `less` in the
   repository and run the `valheim` playbook. Other values are `none`,
   `muchless` and `muchmore`.
2. **High-level raiders (StarLevelSystem).** In `RaidSettings.yaml`,
   for each raid under `Spawns`:
   - `LevelMax`: the highest level a raider can have. `0` or missing
     means the mod's general maximum level.
   - `LevelMin`: the lowest level a raider can have.
   - `UseRaidLevelSystem: false` together with
     `CustomCreatureLevelUpChance` replaces the normal level-up chances
     with your own, for that raid only.

   Creature levels outside raids are in `LevelSettings.yaml`, mainly
   `defaultCreatureLevelUpChance` and, per biome,
   `biomeMaxLevelOverride`.
3. **Seasons.** The Seasons mod also changes raids depending on the
   season. Check its config if raids still get hard at certain times
   of year.

### Crafting from chests (DvergerAutomation)

Nothing to switch on. Crafting from nearby chests only works once an
**Autosorter** has been built:

- Built with the Hammer, under *Crafting*, near a Forge.
- Default cost: 20 Stone, 8 Bronze, 20 Greydwarf Eyes, 4 Ectoplasm.
  Bronze and Ectoplasm mean it is not available until the Black
  Forest and Swamp have been reached.
- It needs at least one Surtling Core in its four core slots. Each
  extra core adds range.
- It only uses chests the player could open themselves. A personal
  (private) chest can be crafted from, but is never sorted into.
- It also crafts from carts and boats (`Craft From Carts`,
  `Craft From Boats`), but never sorts into them.

The same Autosorter also sorts items into chests. Its **[C]** button
picks which item types are sorted, and whether the hotbar and quick
slots are included. Equipped gear always stays with the player.

Build cost and the minimum number of cores can be changed in its
config. Lowering them is the way to make it available earlier. These
settings are on the server, and only the admin can change them.

With Epic Loot, magic items stay in the deposit box unless
`Sort Magic Items` is on.

### Portals

- `-modifier portals casual` in `valheim.server.args` lets everything
  through portals, ore and metal included. ServersideQoL_PortalProgression,
  which used to unlock that step by step per boss, had nothing left to
  do with it set and was removed on 2026-10-25. To go back to
  progression, set `portals` to `default` and add that mod again.
- **ServersideQoL_AutoMapTables** puts portals, ships, ore deposits
  and dungeons players have found on map tables. That is the quickest
  way to see where portals are, and it needs nothing from players.

### Allowing shared map markers (ServerSideMap)

The server has the final say on marker sharing: with it off there,
no player's pins are shared, whatever their own setting says.

- File: `eu.mydayyy.plugins.serversidemap.cfg`, section `[General]`
- `EnableMarkerShare = true` *(set by the repository; default
  `false`)*

### Container sizes (ServersideQoL_ContainerSizes)

- File: `ArgusMagnus.ServersideQoL.ContainerSizes.cfg`, section
  `[ContainerSizes]`, one `InventorySize_<prefab>` setting per
  container type.
- `InventorySize_piece_chest_wood = 8x4` *(set by the repository;
  default `5x2`)*: the wood chest.
- `InventorySize_VikingShip = 8x4` *(set by the repository; default
  `6x3`)*: the longship, see below.
- Every other default is that container's own size, so nothing
  changes until a value is set.
- A trailing `+` (`5x2+`) lets a container keep growing as long as it
  holds only one kind of item.
- Sizes are only changed on **empty** containers, so items are never
  lost. A full chest takes its new size once it has been emptied.

**Keep the longship at least 7x4.** LongshipUpgrades stores an
upgraded longship's bigger storage (7x4, its default) on that ship,
and only ever grows a container, never shrinks it. Below 7x4 here,
the two keep undoing each other on every empty upgraded longship; at
or above it LongshipUpgrades has nothing left to do. At 8x4 every
longship gets more storage than the upgrade would give, which makes
LongshipUpgrades' storage upgrade redundant. If its `Upgrade - Lvl 1 -
Container Width` or `Lvl 2 - Container Height` is raised above 8 or
4, raise this to match.

Not tested together with MultiUserChest, which also deals with open
containers: check that two players can still use a resized chest at
once.

### The other new server mods

**ServersideQoL_Treesurrection** (tree stumps regrow),
**ServersideQoL_SuperWishbone** (the wishbone also finds dungeons,
vegvisirs and more) and **ServersideQoL_SmartDefense** (ballistae
spare players and tames, and reload from nearby containers) work at
their defaults. Each has its own `ArgusMagnus.ServersideQoL.*.cfg`.

## Not installed yet

These would need a new server-only mod added to `valheim_mods`.
Players would install nothing for them.

| Wish | Mod | Setting |
| --- | --- | --- |
| Keep a Megingjord's carry bonus permanently | ServersideQoL_Player | `CanSacrificeMegingjord = true`, then put a Megingjord in an obliterator |
| Link unpaired portals to a hub | ServersideQoL_AutoPortalHub | `Enabled = true`. `AutoNameNewPortals = true` names new portals after their biome. |
| Put items into nearby chests automatically | ServersideQoL_AutoStore | see its config. Overlaps DvergerAutomation's Autosorter. |
