// Read-only GNOME 42 / dash-to-dock probe. Paste into Looking Glass, or use
// diagnose_dock.py --shell-eval when this session already permits Shell.Eval.
JSON.stringify((() => {
    const Main = imports.ui.main;
    const tracker = imports.gi.Shell.WindowTracker.get_default();
    const focus = global.display.focus_window;
    const focusRect = focus ? focus.get_frame_rect() : null;
    const result = {
        pointer: global.get_pointer(),
        modalCount: Main.modalCount,
        overview: Main.overview.visibleTarget,
        focus: focus ? {
            xid: focus.get_xwindow(),
            type: focus.get_window_type(),
            fullscreen: focus.fullscreen,
            above: focus.is_above(),
            rect: {x: focusRect.x, y: focusRect.y,
                   width: focusRect.width, height: focusRect.height}
        } : null,
        docks: []
    };
    for (const uuid of ['ubuntu-dock@ubuntu.com', 'dash-to-dock@micxgx.gmail.com']) {
        const extension = Main.extensionManager.lookup(uuid);
        if (!extension || !extension.imports)
            continue;
        const manager = extension.imports.extension.dockManager;
        if (!manager)
            continue;
        for (const dock of manager._allDocks) {
            const intellihide = dock._intellihide;
            const appId = app => app ? app.get_id() : null;
            result.docks.push({
                uuid,
                monitor: dock.monitorIndex,
                state: dock._dockState,
                slide: dock._slider.get_property('slide-x'),
                hover: dock._box.hover,
                ignoreHover: dock._ignoreHover,
                requiresVisibility: dock.dash.requiresVisibility,
                intellihideEnabled: dock._intellihideIsEnabled,
                autohideEnabled: dock._autohideIsEnabled,
                overlap: intellihide.getOverlapStatus(),
                topApp: appId(intellihide._topApp),
                focusApp: appId(intellihide._focusApp),
                trackerFocusApp: appId(tracker.focus_app),
                box: {x1: dock.staticBox.x1, x2: dock.staticBox.x2,
                      y1: dock.staticBox.y1, y2: dock.staticBox.y2}
            });
        }
    }
    return result;
})())
