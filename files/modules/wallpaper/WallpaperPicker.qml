pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components.containers
import qs.components.misc
import qs.services

Scope {
    id: root

    property bool isOpen: false
    property ShellScreen targetScreen
    property string initialWall: ""

    function screenForFocus(): ShellScreen {
        const mon = Hypr.focusedMonitor;
        return Screens.screens.find(s => Hypr.monitorFor(s) === mon) ?? Screens.screens[0] ?? null;
    }

    function show(): void {
        const screen = root.screenForFocus();
        if (!screen)
            return;

        const state = ShellState.forActive();
        if (state) {
            state.launcher = false;
            state.session = false;
            state.dashboard = false;
            state.sidebar = false;
            state.utilities = false;
        }

        const current = Wallpapers.actualCurrent ?? "";
        root.initialWall = current.split("/").pop();
        root.targetScreen = screen;
        root.isOpen = true;
    }

    function hide(): void {
        root.isOpen = false;
    }

    function toggle(): void {
        if (root.isOpen)
            root.hide();
        else
            root.show();
    }

    StyledWindow {
        id: win

        screen: root.targetScreen ?? Screens.screens[0]
        visible: root.isOpen
        name: "wallpaper-picker"
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.isOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        Loader {
            id: contentLoader

            anchors.fill: parent
            active: root.isOpen
            sourceComponent: Picker {
                widgetArg: root.initialWall
                onRequestClose: root.hide()
            }
        }
    }

    IpcHandler {
        target: "wallpaperPicker"

        function open(): void {
            root.show();
        }

        function close(): void {
            root.hide();
        }

        function toggle(): void {
            root.toggle();
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "wallpaper"
        description: "Open the wallpaper picker"
        onPressed: root.toggle()
    }
}
