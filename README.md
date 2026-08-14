# Project CLUTCH

A Football Manager-style esports management game for Roblox. You build and run a
tactical FPS team — but you never aim a gun. Matches are played by AI bots in a
Valorant-style 5v5 shooter and spectated like a real esports broadcast.

## Locked design decisions

- **Game DNA:** Valorant-style — abilities + gunplay, round-based, credit economy
- **Match engine:** physics-live — bots fight for real in a 3D arena (server-authoritative)
- **Replays:** replay-by-recording (event log + state snapshots), never re-simulation
- **League:** online league vs. other managers, scheduled fixtures on reserved match
  servers; empty slots filled by AI-managed teams
- **Manager skills (v1):** Tactical Timeout + Set Play Call — influence, never control
- **Bot AI:** scripted utility AI driven by scoutable attributes — no ML

## Repo structure (Rojo)

```
src/
  ReplicatedStorage/
    Shared/
      Constants/        -- M0 design constants: attributes, weapons, rounds, sim tuning
      Types.luau        -- shared Luau type definitions
  ServerScriptService/
    Server/             -- match orchestrator, bot brains, event recorder
  StarterPlayerScripts/
    Client/             -- spectate UI, auto-director, radar, broadcast overlays
```

## Toolchain

Managed with [Rokit](https://github.com/rojo-rbx/rokit):

```bash
rokit install        # installs Rojo, StyLua, luau-lsp (see rokit.toml)
rojo serve           # then connect the Rojo plugin in Roblox Studio
```

Every push is verified by CI (`rojo build`, see `.github/workflows/build.yml`).

## Roadmap

1. **M0 — Prove it's watchable:** greybox map, 5v5 bots, rifles only, round logic
   + economy, auto-director v0, event recorder
2. **M1 — Broadcast package:** abilities, radar, replay theater, TTS caster
3. **M2 — Manager core:** roster, training, tactics board, saves, preseason vs AI
4. **M3 — League online:** fixtures, live spectate, human transfer market, Season 0
