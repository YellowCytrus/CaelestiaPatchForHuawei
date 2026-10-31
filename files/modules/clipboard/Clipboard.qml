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
    property bool closing: false
    property bool deleteMode: false
    property ShellScreen targetScreen

    function screenForFocus(): ShellScreen {
        const mon = Hypr.focusedMonitor;
        return Screens.screens.find(s => Hypr.monitorFor(s) === mon) ?? Screens.screens[0] ?? null;
    }

    function show(openInDeleteMode: bool): void {
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

        root.targetScreen = screen;
        root.deleteMode = openInDeleteMode;
        root.closing = false;
        root.isOpen = true;
    }

    function hide(): void {
        if (root.isOpen)
            root.closing = true;
    }

    function toggle(): void {
        if (root.isOpen && !root.closing)
            root.hide();
        else
            root.show(false);
    }

    StyledWindow {
        id: win

        screen: root.targetScreen ?? Screens.screens[0]
        visible: root.isOpen
        name: "clipboard"
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.isOpen && !root.closing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        Loader {
            id: contentLoader

            anchors.fill: parent
            active: root.isOpen
            sourceComponent: Content {
                closing: root.closing
                deleteMode: root.deleteMode

                onRequestClose: root.hide()
                onClosed: {
                    root.isOpen = false;
                }
            }
        }
    }

    IpcHandler {
        target: "clipboard"

        function open(): void {
            root.show(false);
        }

        function openDelete(): void {
            root.show(true);
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
        name: "clipboard"
        description: "Open clipboard history"
        onPressed: root.toggle()
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "clipboardDelete"
        description: "Open clipboard history in delete mode"
        onPressed: root.show(true)
    }
}
