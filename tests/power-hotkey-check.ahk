#Requires AutoHotkey v2.0
#SingleInstance Off
#Include "%A_ScriptDir%\..\power-hotkey.ahk"
#Warn All, StdOut

; =============================================================================
; pure catalog / configuration tests; never start Power Hotkey or send input
; =============================================================================
; No settings are written, no layer session is opened, and no real clipboard,
; volume, capitalization or power state is changed by these tests.
; =============================================================================

try {
    PH_Check.Run()
    ExitApp 0
}
catch Error as powerHotkeysTestError {
    FileAppend("FAIL: " powerHotkeysTestError.Message "`n", "**")
    ExitApp 1
}

class PH_Check {
    static count := 0

    static Assert(condition, label) {
        this.count += 1
        if !condition
            throw Error(label)
    }

    static Run() {
        app := PowerHotkeys({dryRun: true,
            directory: A_Temp "\PowerHotkeys-check-" DllCall("GetCurrentProcessId", "uint")})
        manager := app.manager
        this.Assert(app.modules.Length = 9, "nine optional feature modules")
        this.Assert(app.catalog.Count = 33, "33 original feature/control actions")
        this.Assert(manager.actions.Count = 33, "every catalog action is registered")
        this.Assert(!manager.running, "construction must not start hooks or persistence")
        this.Assert(!IsObject(manager.client), "construction must not connect to the layer service")
        configuration := manager._DefaultConfiguration()
        for actionId, setting in configuration {
            this.Assert(!setting.enabled, actionId " starts disabled")
            this.Assert(setting.bindings.Length = 2, actionId " has two configurable slots")
        }
        expectedFunctionKeys := ["Q", "W", "E", "R", "A", "S", "D", "F", "Z", "X", "C", "V"]
        for index, suffix in expectedFunctionKeys {
            output := "F" (index + 12)
            actionId := "keyboard." StrLower(output)
            this.Assert(app.catalog[actionId].value = output, "output " output)
            this.Assert(configuration[actionId].bindings[1] = Keybindings.Parse("Caps + " suffix).signature,
                "default " output)
        }
        loop 10 {
            numpadDigit := A_Index - 1
            actionId := "keyboard.numpad" numpadDigit
            this.Assert(app.catalog[actionId].value = "Numpad" numpadDigit, "number-pad output " numpadDigit)
            this.Assert(configuration[actionId].bindings[1] = Keybindings.Parse("Caps + " numpadDigit).signature,
                "number-pad binding " numpadDigit)
        }
        this.Assert(app.catalog["text.sharp-s"].value = "ß", "sharp s preserved")
        this.Assert(app.catalog["text.en-dash"].value = "–", "en dash preserved")
        this.Assert(app.catalog["text.apostrophe"].value = "’", "curly apostrophe preserved")
        this.Assert(app.catalog["text.nbsp"].value = "&nbsp;", "literal entity preserved, not converted to whitespace")
        this.Assert(app.catalog["text.timestamp"].kind = "timestamp", "timestamp remains dynamic")
        this.Assert(app.catalog["terminal.copy"].needsFocus, "copy requires its original foreground window")
        this.Assert(app.catalog["terminal.clear"].needsFocus, "clear requires its original foreground window")
        this.Assert(configuration["terminal.copy"].bindings[1] = Keybindings.Parse("Caps + Ctrl + C").signature,
            "copy has a distinct binding from F23")
        this.Assert(configuration["system.wake-speakers"].bindings[1] = Keybindings.Parse("Pause + W").signature,
            "speaker wake has an assignable non-sequence default")
        this.Assert(configuration["keyboard.toggle-caps"].bindings[1] = Keybindings.Parse("Caps + Shift + Space").signature,
            "Caps Lock toggle has an assignable default")
        this.Assert(configuration["system.sleep"].bindings[1] = Keybindings.Parse("Pause + Escape").signature,
            "sleep retains Pause+Escape")
        enabledConfiguration := manager._CloneConfiguration(configuration)
        for module in app.modules {
            PH_Modules.SetModule(enabledConfiguration, app.catalog, module.id, true)
            state := PH_Modules.State(enabledConfiguration, app.catalog, module.id)
            this.Assert(state.total > 0 && state.enabled = state.total, module.id " enables as one unit")
        }
        routes := manager._CandidateRoutes(enabledConfiguration).routes
        this.Assert(routes.Length = 33, "all modules expose all 33 default bindings")
        signatures := Map()
        for route in routes {
            this.Assert(Keybindings.ConflictingSignature(route.binding, signatures) = "",
                "defaults must not overlap: " route.action.id)
            signatures[route.binding.signature] := true
        }
        customBindings := [Keybindings.Parse("Ctrl + Alt + F8").signature,
            Keybindings.Parse("Ctrl + Shift + F8").signature]
        enabledConfiguration["text.sharp-s"].bindings := customBindings.Clone()
        PH_Modules.SetModule(enabledConfiguration, app.catalog, "text", false)
        this.Assert(!enabledConfiguration["text.sharp-s"].enabled, "module disables actions")
        this.Assert(enabledConfiguration["text.sharp-s"].bindings[1] = customBindings[1], "disable preserves primary")
        this.Assert(enabledConfiguration["text.sharp-s"].bindings[2] = customBindings[2], "disable preserves secondary")
        PH_Modules.SetModule(enabledConfiguration, app.catalog, "text", true)
        this.Assert(enabledConfiguration["text.sharp-s"].bindings[1] = customBindings[1], "reenable preserves customization")
        this.Assert(!configuration["text.sharp-s"].enabled, "configuration copies are isolated")
        fence := Chr(96) Chr(96) Chr(96)
        this.Assert(PH_Terminal.FormatBuffer("hello`r`n`r`n") = fence "`nhello`n" fence,
            "Markdown copy trims trailing empty lines")
        this.Assert(PH_Terminal.FormatBuffer("a`n`nb`n") = fence "`na`n`nb`n" fence,
            "Markdown copy preserves internal blank lines")
        this.Assert(PH_Terminal.FormatBuffer("x`n `t`n") = fence "`nx`n" fence,
            "Markdown copy trims whitespace-only trailing lines")
        this.Assert(PH_Utilities.ShouldRestoreVolume(0.16, 0.16), "restore unchanged temporary volume")
        this.Assert(!PH_Utilities.ShouldRestoreVolume(0.25, 0.16), "preserve user-selected volume")
        this.Assert(PH_Utilities.ShouldRestoreVolume(0.160001, 0.16), "tolerate endpoint rounding")
        manager.SetPaused(true)
        this.Assert(manager.paused && !manager.running, "pause works before Start without starting the manager")
        manager.SetPaused(false)
        this.Assert(!manager.paused, "pause can be cleared")
        this.Assert(!FileExist(manager.path), "pure checks did not create a settings file")
        FileAppend("PASS: " this.count " Power Hotkey catalog and safety-helper assertions.`n", "*")
    }
}
