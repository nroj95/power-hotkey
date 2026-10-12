# Power Hotkey

experimental AutoHotkey v2 application providing optional, configurable keyboard utilities and macros.

all 33 actions are visible in the unified Keybindings window under their original categories.
Every action begins without a shortcut on new installations; existing enabled
assignments are preserved. The first migration backs up the original INI file
next to it with a `.legacy-*.bak` suffix. Previously disabled shortcuts are not
activated automatically. Caps + Pause Layers remains optional.

The optional classic F13-F24 preset will be added in a later step and does not
run automatically in this build.

**status:** early development. functionality and APIs may change.

## testing

```powershell
.\tests\check-power-hotkey.ps1
```

## dependencies

```powershell
.\tools\sync-dependencies.ps1
```
