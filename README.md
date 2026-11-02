# Zone IFF

UE4SS Lua mod for S.T.A.L.K.E.R. 2. Aim at an NPC to see its faction, colored by its relation to you. Enemies also get a red X at the aim point.

The faction comes from the game's memory, not from the outfit. Monolith in Loner gear shows as Monolith.

| Color  | Relation   |
|--------|------------|
| Red    | Enemy      |
| Orange | Unfriendly |
| Yellow | Neutral    |
| Green  | Friend     |

## Requirements

- Game update 2.1 (build 26123434)
- UE4SS 3.0.1

## Install

Copy the `ZoneIFF` folder into `Stalker2/Binaries/Win64/ue4ss/Mods/`. If it does not load, add `ZoneIFF : 1` to `ue4ss/Mods/mods.txt`.

## Compatibility

Memory offsets are tied to one game build. After a patch the faction label turns off and the X keeps working.

## Bug reports

Attach the `[ZoneIFF]` lines from `ue4ss/UE4SS.log`. The game overwrites the log on every start.

## Release

Push a tag `vX.Y.Z` matching `VERSION` in `Scripts/main.lua`. The workflow builds the zip, creates a GitHub release, and uploads to Nexus Mods when the secret `NEXUSMODS_API_KEY` and variable `NEXUS_FILE_ID` are set.

## License

GPL-3.0-or-later.

Inspired by [NPC Identification HUD](https://www.nexusmods.com/stalker2heartofchornobyl/mods/2948).
