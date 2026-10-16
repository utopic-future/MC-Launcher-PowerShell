# MC-Launcher-PowerShell
This project is a single-file, text-based Minecraft Java Edition launcher for Windows PowerShell 5.1 that downloads and runs many game versions in offline mode, with no login.

**Purpose**
It lets you install and play Minecraft on a machine that can't reach Microsoft's login servers. It uses the game's own offline path (`--accessToken 0`, `--userType legacy`) instead of authenticating, so it covers singleplayer and `online-mode=false` servers only.

**What it does**
- **Installs versions:** it pulls Mojang's official manifest and downloads the client, libraries, native DLLs and assets, with SHA-1 verification. Asset downloads run 8 in parallel.
- **Supports many versions:** releases and snapshots from 1.6.1 onward, with filtering, scrolling and an installed-only view. It also handles locally dropped Fabric/Forge-style profiles that inherit from a base version.
- **Handles format differences:** it launches both the legacy argument format (before 1.13) and the modern format with conditional rules. It also covers old asset layouts, LWJGL 2 and 3 natives, and server auto-join.
- **Picks Java:** it finds installed Javas, including the Minecraft launcher's bundled runtimes, and picks one that meets each version's requirement.
- **Gives you a TUI:** the interface is menu-driven (Play, Version, Install/Repair, Settings, Status), keyboard-only, with progress bars. Settings cover profile name, memory, server, Java path, extra JVM args and shared versus per-version game folders.
- **Keeps worlds consistent:** it derives the same offline UUID vanilla would from your profile name.

**Structure**
```
Minecraft\
  libraries\, assets\          shared by all versions
  versions\<id>\               json, jar, natives
  instances\<id>\              per-version worlds and options
  launcher.json                your settings
```

**Constraints**
- **Not an authenticated launcher:** there is no Microsoft login, so it won't join official online servers.
- **Single script:** everything lives in `MCLauncher-TUI-multi.ps1`, so it's easy to move around but gets long.
