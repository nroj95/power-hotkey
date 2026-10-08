; =============================================================================
; modules.ahk - feature catalog and the module-selection interface
; =============================================================================
; Module toggles are saved in the keybinding manager's existing enabled fields.
; There is no second settings file to drift out of sync with those fields.
; Disabling a module removes its active bindings but retains both saved slots.
; The keybinding dialog itself remains the shared library's responsibility.
; =============================================================================

class PH_Modules {
    static Catalog() {
        return [
            {id: "function-keys", label: "extra function keys",
                description: "F13-F24 through the original Q/W/E/R, A/S/D/F, Z/X/C/V positions."},
            {id: "number-pad", label: "virtual number pad",
                description: "Numpad 0-9 through the number row, with held-key release handling."},
            {id: "terminal", label: "Windows Terminal tools",
                description: "Copy the buffer as Markdown, or clear it. Only acts in Windows Terminal."},
            {id: "text", label: "text snippets",
                description: "Insert ß, an en dash, a curly apostrophe, or the literal text &nbsp;."},
            {id: "timestamp", label: "timestamps",
                description: "Insert the current local time as yyyyMMdd-HHmmss."},
            {id: "caps-lock", label: "Caps Lock toggle",
                description: "Toggle actual capitalization using a configurable shortcut."},
            {id: "speaker-wake", label: "speaker wake",
                description: "Play the original Windows sound; temporarily raise low volume to 16%."},
            {id: "sleep", label: "computer sleep",
                description: "Put Windows to sleep after the trigger keys are released. Wake events stay enabled."},
            {id: "interface", label: "Power Hotkey controls",
                description: "Open this window from a configurable shortcut. The tray menu is always available."}
        ]
    }

    static Label(modules, moduleId) {
        for module in modules
            if module.id = moduleId
                return module.label
        throw ValueError("Unknown module: " moduleId)
    }

    static RegisterActions(app) {
        for index, key in ["Q", "W", "E", "R", "A", "S", "D", "F", "Z", "X", "C", "V"] {
            output := "F" (12 + index)
            app.AddAction("function-keys", "keyboard." StrLower(output), "send " output,
                "virtual", output, "Caps + " key)
        }
        loop 10 {
            numpadDigit := A_Index - 1
            app.AddAction("number-pad", "keyboard.numpad" numpadDigit, "send Numpad" numpadDigit,
                "virtual", "Numpad" numpadDigit, "Caps + " numpadDigit)
        }
        ; The old Caps+C override and F23 cannot both own one global signature.
        ; Keep the actions independently configurable instead of hiding a router.
        app.AddAction("terminal", "terminal.copy", "copy buffer as Markdown",
            "terminal-copy", "", "Caps + Ctrl + C", true)
        app.AddAction("terminal", "terminal.clear", "clear buffer",
            "terminal-clear", "", "Caps + K", true)
        app.AddAction("text", "text.sharp-s", "insert ß", "text", "ß", "Pause + S", true)
        app.AddAction("text", "text.en-dash", "insert en dash", "text", "–", "Pause + -", true)
        app.AddAction("text", "text.apostrophe", "insert curly apostrophe", "text", "’", "Pause + '", true)
        app.AddAction("text", "text.nbsp", "insert literal &nbsp;", "text", "&nbsp;", "Pause + N", true)
        app.AddAction("timestamp", "text.timestamp", "insert timestamp",
            "timestamp", "", "Pause + T", true)
        ; Sequences/modifier-only gestures are not part of the current library.
        app.AddAction("caps-lock", "keyboard.toggle-caps", "toggle Caps Lock",
            "caps-lock", "", "Caps + Shift + Space")
        app.AddAction("speaker-wake", "system.wake-speakers", "wake speakers",
            "speaker-wake", "", "Pause + W")
        app.AddAction("sleep", "system.sleep", "sleep computer", "sleep", "", "Pause + Escape")
        app.AddAction("interface", "interface.open", "open Power Hotkey",
            "interface", "", "Pause + H")
    }

    static SetModule(configuration, catalog, moduleId, enabled) {
        found := false
        for actionId, action in catalog {
            if action.moduleId != moduleId
                continue
            configuration[actionId].enabled := !!enabled
            found := true
        }
        if !found
            throw ValueError("Unknown or empty module: " moduleId)
        return configuration
    }

    static State(configuration, catalog, moduleId) {
        enabled := 0
        total := 0
        for actionId, action in catalog {
            if action.moduleId != moduleId
                continue
            total += 1
            if configuration[actionId].enabled
                enabled += 1
        }
        return {enabled: enabled, total: total}
    }

    static Show(app) {
        if app.stopping
            return
        if IsObject(app.manager.settings) {
            app.manager.ShowSettings()
            return
        }
        if IsObject(app.modulesWindow) {
            app.modulesWindow.Show()
            return
        }
        window := Gui("-Resize", app.name)
        app.modulesWindow := window
        app.UpdatePause()
        app.CancelWork()
        window.SetFont("s10", "Segoe UI")
        window.AddText("x20 y16 w590 h34 +0x80",
            "choose which modules to enable. disabled modules keep their saved keybindings."
            . "`nCaps/Pause defaults need the layer service; ordinary bindings work without it.")
        configuration := app.manager.GetConfiguration()
        for index, module in app.modules {
            y := 62 + (index - 1) * 55
            state := this.State(configuration, app.catalog, module.id)
            check := window.AddCheckbox("x20 y" y " w590 h22 Check3", module.label)
            check.Value := state.enabled = 0 ? 0 : state.enabled = state.total ? 1 : -1
            check.OnEvent("Click", ObjBindMethod(this, "Change", app, module.id))
            window.AddText("x42 y" (y + 24) " w568 h28 +0x80", module.description)
        }
        footerY := 65 + app.modules.Length * 55
        window.AddText("x20 y" footerY " w590 h2 +0x10", "")
        window.AddButton("x164 y" (footerY + 14) " w145 h30", "keybindings").OnEvent(
            "Click", ObjBindMethod(app, "OpenKeybindings"))
        window.AddButton("x321 y" (footerY + 14) " w145 h30", "done").OnEvent(
            "Click", ObjBindMethod(this, "Close", app))
        window.OnEvent("Close", ObjBindMethod(this, "Close", app))
        window.OnEvent("Escape", ObjBindMethod(this, "Close", app))
        window.Show("w630 h" (footerY + 60))
    }

    static Change(app, moduleId, control, *) {
        configuration := app.manager.GetConfiguration()
        previous := this.State(configuration, app.catalog, moduleId)
        ; The indeterminate visual state means a future/new action remains off.
        ; Clicking the selector always chooses a consistent on/off module state.
        enabled := previous.enabled < previous.total
        this.SetModule(configuration, app.catalog, moduleId, enabled)
        app.CancelWork()
        try {
            try app.manager.Apply(configuration)
            catch KB_SavedConflict as savedWarning {
                if MsgBox(savedWarning.Message "`n`nKeep these assignments anyway?",
                    app.name, "YesNo Icon!") != "Yes" {
                    control.Value := previous.enabled = 0 ? 0 : previous.enabled = previous.total ? 1 : -1
                    return
                }
                app.manager.Apply(configuration, true)
            }
            app.SyncEnabledActions()
            control.Value := enabled ? 1 : 0
        }
        catch Error as moduleError {
            ; A failed binding transaction must not pretend the module was enabled.
            app.SyncEnabledActions()
            actual := this.State(app.manager.GetConfiguration(), app.catalog, moduleId)
            control.Value := actual.enabled = 0 ? 0 : actual.enabled = actual.total ? 1 : -1
            MsgBox(moduleError.Message, app.name " - module unchanged", "Icon!")
        }
    }

    static Close(app, *) {
        if IsObject(app.modulesWindow)
            app.modulesWindow.Destroy()
        app.modulesWindow := 0
        app.UpdatePause()
    }

    static ShowStatus(app, *) {
        if IsObject(app.statusWindow) {
            this.RefreshStatus(app)
            app.statusWindow.Show()
            return
        }
        window := Gui("-Resize", app.name " - status")
        app.statusWindow := window
        window.SetFont("s10", "Segoe UI")
        window.AddEdit("x14 y14 w720 h380 ReadOnly -Wrap vstatus")
        window.AddButton("x236 y406 w110 h28", "refresh").OnEvent("Click", ObjBindMethod(this, "RefreshStatus", app))
        window.AddButton("x360 y406 w110 h28", "close").OnEvent("Click", ObjBindMethod(this, "CloseStatus", app))
        window.OnEvent("Close", ObjBindMethod(this, "CloseStatus", app))
        window.OnEvent("Escape", ObjBindMethod(this, "CloseStatus", app))
        this.RefreshStatus(app)
        window.Show("w748 h448")
    }

    static RefreshStatus(app, *) {
        if !IsObject(app.statusWindow)
            return
        lines := ["Power Hotkey " PowerHotkeys.Version,
            "mode: " (app.dryRun ? "dry run - no real effects" : "normal"),
            "settings: " app.manager.path, "", "bindings"]
        statuses := app.manager.GetStatus()
        if !statuses.Length
            lines.Push("none - enable a module first")
        for status in statuses
            lines.Push(status.label " / " status.binding ": " status.state)
        lines.Push("", "recent messages")
        for line in app.log
            lines.Push(line)
        app.statusWindow["status"].Value := Keybindings.Join(lines, "`r`n")
    }

    static CloseStatus(app, *) {
        if IsObject(app.statusWindow)
            app.statusWindow.Destroy()
        app.statusWindow := 0
    }
}
