#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn

; =============================================================================
; power-hotkey.ahk - optional utilities using the shared keybinding manager
; version: 0.1.0-preview.1 | AutoHotkey v2 / Windows
; =============================================================================
; purpose
;   Migrate the general-purpose actions from CapsLock Layer and Pause Command
;   Mode. All feature modules start OFF. This script does not own either layer
;   key, start the layer service, or implement Window Cascade commands.
;
; structure
;   This entry point owns lifecycle and deferred command dispatch. Four included
;   files group the module interface, virtual keys, Terminal macros and utilities.
;   lib/keybindings.ahk owns configuration/registration; caps-pause-client.ahk is
;   its adapter to the optional, separately running caps-pause-layers.ahk service.
;
; safety
;   Callbacks stay short. Commands wait for released inputs before executing on
;   a separate timer. Focus-sensitive work is tied to its original HWND + PID.
;   Reconfiguration, settings, capture, suspend and exit cancel pending work and
;   release owned output. Nothing forcibly terminates or changes other scripts.
;
; command line
;   --check    Parse only; no GUI, settings, hooks, audio, text or power actions.
;   --dry-run  Use a separate settings owner and log effects instead of executing.
;   --settings Open the module selector even when this is not the first launch.
; =============================================================================

#Include "lib\keybindings.ahk"
#Include "lib\caps-pause-client.ahk"
#Include "power-hotkey\modules.ahk"
#Include "power-hotkey\keyboard.ahk"
#Include "power-hotkey\terminal.ahk"
#Include "power-hotkey\utilities.ahk"

; Including the entry point from a test must not start the application.
if A_LineFile = A_ScriptFullPath
    PH_Main()

PH_Main() {
    try {
        dryRun := false
        openSettings := false
        for argument in A_Args {
            switch argument {
                case "--check":
                    FileAppend("PASS: Power Hotkey and its included modules parsed.`n", "*")
                    ExitApp 0
                case "--dry-run": dryRun := true
                case "--settings": openSettings := true
                default: throw ValueError("Unknown argument: " argument)
            }
        }
        application := PowerHotkeys({dryRun: dryRun})
        application.Start(openSettings)
    }
    catch Error as startupError {
        MsgBox(startupError.Message, "Power Hotkey - could not start", "Iconx")
        ExitApp 1
    }
}

class PowerHotkeys {
    static Version := "0.1.0-preview.1"

    __New(options := {}) {
        this.dryRun := !!Keybindings.Option(options, "dryRun", false)
        this.name := this.dryRun ? "Power Hotkey (dry run)" : "Power Hotkey"
        this.stopping := false
        this.systemSuspended := false
        this.modulesWindow := 0
        this.statusWindow := 0
        this.log := []
        this.pending := Map()
        this.generation := 0
        this.activeJob := 0
        this.enabledActions := Map()
        this.catalog := Map()
        this.modules := PH_Modules.Catalog()
        this.pollCallback := ObjBindMethod(this, "CheckPending")
        this.resumeCallback := ObjBindMethod(this, "ResumeInputs")
        this.powerCallback := ObjBindMethod(this, "PowerEvent")
        this.exitCallback := ObjBindMethod(this, "Stop")
        this.startupPath := A_Startup "\Power Hotkey.lnk"
        managerOptions := {statusCallback: ObjBindMethod(this, "Report"),
            layerFactory: (name, status) => CapsPauseClient(name, status)}
        if HasProp(options, "directory")
            managerOptions.directory := options.directory
        this.manager := Keybindings(this.dryRun ? "power-hotkey-dry-run" : "power-hotkey",
            this.name, managerOptions)
        if !HasMethod(this.manager, "SetPaused")
            throw Error("Update lib\keybindings.ahk from this package; SetPaused() is required.")
        this.keyboard := PH_Keyboard(this)
        this.terminal := PH_Terminal(this)
        this.utilities := PH_Utilities(this)
        PH_Modules.RegisterActions(this)
    }

    AddAction(moduleId, actionId, label, kind, value, defaultBinding, needsFocus := false) {
        this.catalog[actionId] := {id: actionId, moduleId: moduleId, kind: kind,
            value: value, needsFocus: needsFocus}
        this.manager.AddAction(actionId, label, ObjBindMethod(this, "Dispatch"),
            [defaultBinding], {category: PH_Modules.Label(this.modules, moduleId), enabled: false})
    }

    Start(openSettings := false) {
        legacy := this.FindLegacyLayers()
        if legacy != ""
            throw Error("Close Window Cascade first, then the old CapsLock and Pause scripts."
                . "`nDo not run the old layer scripts alongside their replacements."
                . "`n`nDetected: " legacy "`n`nNo script was stopped automatically.")
        ; Load saved module choices before allowing any of their hotkeys to fire.
        this.manager.SetPaused(true)
        InstallKeybdHook(true)
        this.manager.Start()
        this.SyncEnabledActions()
        OnExit(this.exitCallback)
        OnMessage(0x0218, this.powerCallback) ; WM_POWERBROADCAST
        SetStoreCapsLockMode false
        A_MenuMaskKey := "vkE8"
        Persistent true
        this.BuildTray()
        if this.manager.firstRun || openSettings
            PH_Modules.Show(this)
        else
            this.UpdatePause()
    }

    Stop(*) {
        if this.stopping
            return
        this.stopping := true
        SetTimer(this.resumeCallback, 0)
        try this.manager.SetPaused(true)
        this.CancelWork()
        try this.manager.Stop()
        try this.utilities.RestoreSpeakerVolume()
        try this.terminal.RestoreClipboard()
        try OnMessage(0x0218, this.powerCallback, 0)
    }

    SyncEnabledActions() {
        this.enabledActions := Map()
        for actionId, setting in this.manager.GetConfiguration()
            this.enabledActions[actionId] := setting.enabled
    }

    Enabled(actionId) => this.enabledActions.Has(actionId) && this.enabledActions[actionId]

    CanDispatch(actionId) {
        return !this.stopping && !this.systemSuspended && this.Enabled(actionId)
            && this.manager.running && !this.manager.gated && !this.manager.paused
            && !this.manager.applying
    }

    UpdatePause() {
        this.manager.SetPaused(this.stopping || this.systemSuspended || IsObject(this.modulesWindow))
    }

    CancelWork() {
        this.generation += 1
        this.pending.Clear()
        SetTimer(this.pollCallback, 0)
        this.keyboard.ReleaseAll()
        try this.utilities.RestoreSpeakerVolume()
        try this.terminal.RestoreClipboard()
    }

    Dispatch(event) {
        if !this.catalog.Has(event.actionId)
            return
        action := this.catalog[event.actionId]
        if action.kind = "virtual" {
            ; up/cancel must still be handled after a module was disabled.
            this.keyboard.Event(action.value, event)
            return
        }
        token := event.actionId "|" event.slot
        if event.phase = "up" || event.phase = "cancel" {
            ; Layer events remain authoritative when another process consumed
            ; the physical key before our local keyboard hook could observe it.
            if this.pending.Has(token)
                this.pending[token].completed := true
            return
        }
        if event.phase != "down" || !this.CanDispatch(event.actionId)
            return
        if this.pending.Count >= 16
            return
        targetPid := 0
        if action.needsFocus {
            targetPid := this.WindowPid(event.foregroundHwnd)
            if !targetPid || !this.TargetActive(event.foregroundHwnd, targetPid)
                return
        }
        this.pending[token] := {action: action, event: event.Clone(), pid: targetPid,
            generation: this.generation, created: A_TickCount, completed: false, worker: 0}
        SetTimer(this.pollCallback, 15)
    }

    CheckPending(*) {
        if this.stopping {
            SetTimer(this.pollCallback, 0)
            return
        }
        for token, job in this.pending.Clone() {
            if !this.JobValid(job) || ((A_TickCount - job.created) & 0xFFFFFFFF) > 5000 {
                this.pending.Delete(token)
                continue
            }
            if IsObject(this.activeJob) || !job.completed || !this.InputsReleased(job.event)
                continue
            this.pending.Delete(token)
            this.activeJob := job
            job.worker := ObjBindMethod(this, "RunJob", job)
            ; Slow macros do not run inside Keybindings' serialized event callback.
            SetTimer(job.worker, -1)
            break
        }
        if !this.pending.Count
            SetTimer(this.pollCallback, 0)
    }

    JobValid(job) {
        if job.generation != this.generation || !this.CanDispatch(job.action.id)
            return false
        if job.action.needsFocus && !this.TargetActive(job.event.foregroundHwnd, job.pid)
            return false
        if job.event.layer != "normal" {
            client := this.manager.client
            if !IsObject(client) || !client.session || !client.ServiceMatches()
                return false
        }
        return true
    }

    RunJob(job) {
        try {
            if !this.JobValid(job) || !this.InputsReleased(job.event)
                return
            if InStr(job.action.kind, "terminal-") = 1 && !this.terminal.Ready(job)
                return
            if this.dryRun {
                this.Report("dry run: " job.action.id " via " job.event.binding)
                return
            }
            switch job.action.kind {
                case "text": SendText(job.action.value)
                case "timestamp": SendText(FormatTime(, "yyyyMMdd-HHmmss"))
                case "caps-lock": SetCapsLockState(GetKeyState("CapsLock", "T") ? "Off" : "On")
                case "terminal-copy": this.terminal.Copy(job)
                case "terminal-clear": this.terminal.Clear(job)
                case "speaker-wake": this.utilities.WakeSpeakers(job)
                case "sleep": this.utilities.SleepComputer(job)
                case "interface": PH_Modules.Show(this)
                default: throw Error("Unknown action kind: " job.action.kind)
            }
        }
        catch Error as commandError {
            this.Report(job.action.id ": " commandError.Message)
            TrayTip(commandError.Message, this.name, 2)
        }
        finally {
            if this.activeJob = job
                this.activeJob := 0
            if this.pending.Count && !this.stopping
                SetTimer(this.pollCallback, 15)
        }
    }

    InputsReleased(event) {
        if !InStr(event.key, "Wheel") && GetKeyState(event.key, "P")
            return false
        ; Include both layer keys even for ordinary bindings: they may have been
        ; pressed after this command was queued. Never emit into a held layer.
        for key in ["Ctrl", "Alt", "Shift", "LWin", "RWin", "CapsLock", "Pause", "CtrlBreak"]
            if GetKeyState(key, "P")
                return false
        return true
    }

    WindowPid(hwnd) {
        processId := 0
        if hwnd
            DllCall("GetWindowThreadProcessId", "ptr", hwnd, "uint*", &processId, "uint")
        return processId
    }

    TargetActive(hwnd, pid) {
        return hwnd && pid && DllCall("GetForegroundWindow", "ptr") = hwnd
            && this.WindowPid(hwnd) = pid
    }

    PowerEvent(wParam, *) {
        if wParam = 4 { ; PBT_APMSUSPEND
            this.systemSuspended := true
            this.UpdatePause()
            this.CancelWork()
        } else if wParam = 7 || wParam = 0x12 { ; resume / resume automatic
            this.systemSuspended := true
            this.UpdatePause()
            this.CancelWork()
            SetTimer(this.resumeCallback, -500)
        }
    }

    ResumeInputs(*) {
        if this.stopping
            return
        ; Reinstall the hook without reloading or discarding saved configuration.
        try {
            InstallKeybdHook(true, true)
            this.systemSuspended := false
            this.UpdatePause()
        }
        catch Error as resumeError {
            this.Report("input recovery failed: " resumeError.Message)
        }
    }

    BuildTray() {
        A_IconTip := this.name
        A_TrayMenu.Delete()
        A_TrayMenu.Add("Modules", (*) => PH_Modules.Show(this))
        A_TrayMenu.Add("Keybindings", ObjBindMethod(this, "OpenKeybindings"))
        A_TrayMenu.Add("Status", (*) => PH_Modules.ShowStatus(this))
        A_TrayMenu.Add()
        A_TrayMenu.Add("Run at startup", ObjBindMethod(this, "ToggleStartup"))
        A_TrayMenu.Add("Reload", (*) => Reload())
        A_TrayMenu.Add("Exit", (*) => ExitApp())
        A_TrayMenu.Default := "Modules"
        this.UpdateStartupMenu()
    }

    OpenKeybindings(*) {
        this.CancelWork()
        ; Create the library window before unpausing the module-selector gate.
        this.manager.ShowSettings()
        PH_Modules.Close(this)
    }

    ToggleStartup(*) {
        if this.dryRun {
            MsgBox("Startup is unavailable in dry-run mode.", this.name)
            return
        }
        try {
            if FileExist(this.startupPath) {
                FileDelete(this.startupPath)
            } else if A_IsCompiled {
                FileCreateShortcut(A_ScriptFullPath, this.startupPath, A_ScriptDir)
            } else {
                FileCreateShortcut(A_AhkPath, this.startupPath, A_ScriptDir,
                    '"' A_ScriptFullPath '"')
            }
            this.UpdateStartupMenu()
        }
        catch Error as startupError {
            MsgBox(startupError.Message, this.name " - startup setting", "Iconx")
        }
    }

    UpdateStartupMenu() {
        if FileExist(this.startupPath)
            A_TrayMenu.Check("Run at startup")
        else
            A_TrayMenu.Uncheck("Run at startup")
    }

    Report(text) {
        this.log.Push(FormatTime(, "HH:mm:ss") "  " text)
        if this.log.Length > 100
            this.log.RemoveAt(1)
        OutputDebug(this.name ": " text)
    }

    FindLegacyLayers() {
        handle := DllCall("OpenMutexW", "uint", 0x100000, "int", false,
            "str", "Local\WindowCascade.CapsLockLayer", "ptr")
        if handle {
            DllCall("CloseHandle", "ptr", handle)
            return "CapsLock Layer"
        }
        wasHidden := A_DetectHiddenWindows
        DetectHiddenWindows(true)
        try {
            for hwnd in WinGetList("ahk_class AutoHotkey") {
                if hwnd = A_ScriptHwnd
                    continue
                try title := WinGetTitle(hwnd)
                catch
                    continue
                if RegExMatch(title, "i)\\(?:capslock-layer|pause-command-mode)(?:\([^\\]*\))?\.ahk - AutoHotkey")
                    return title
            }
        }
        finally DetectHiddenWindows(wasHidden)
        return ""
    }
}
