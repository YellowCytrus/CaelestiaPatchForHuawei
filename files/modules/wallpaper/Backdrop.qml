import QtQuick

// Crossfades / slides between wallpapers inside the picker.
// The old shell animated the desktop with awww transitions; Caelestia draws
// its own wallpaper, so the same idea is reproduced here for the picker
// backdrop instead of being hidden behind the overlay.
Item {
    id: root

    property string source: ""
    property string transition: "random"
    property int duration: 850
    property Item front
    property string currentPath: ""
    property bool initialized: false
    property int zCounter: 0

    readonly property var transitionList: ["fade", "left", "right", "up", "down", "zoom"]

    function pickTransition(): string {
        if (transition === "random" || transition === "simple")
            return transition === "simple" ? "none" : transitionList[Math.floor(Math.random() * transitionList.length)];
        return transition;
    }

    function show(path: string, type: string): void {
        if (!path || path === root.currentPath)
            return;

        root.currentPath = path;

        const layer = bgComp.createObject(root, {
            path: path,
            transitionType: type,
            zValue: root.zCounter++
        });
        root.front = layer;
        cleanupTimer.restart();
    }

    onSourceChanged: {
        if (root.initialized && source)
            root.show(source, root.pickTransition());
    }

    Component.onCompleted: {
        root.initialized = true;
        if (source)
            root.show(source, "none");
    }

    Timer {
        id: cleanupTimer

        interval: root.duration + 100
        onTriggered: {
            for (let i = root.children.length - 1; i >= 0; --i) {
                const child = root.children[i];
                if (child !== root.front)
                    child.destroy();
            }
        }
    }

    Component {
        id: bgComp

        Item {
            id: layer

            anchors.fill: parent
            clip: true

            property string path: ""
            property string transitionType: "fade"
            property real progress: 0
            property int zValue: 0

            z: zValue

            opacity: transitionType === "fade" || transitionType === "zoom" ? progress : 1
            scale: transitionType === "zoom" ? 1.08 - 0.08 * progress : 1
            transformOrigin: Item.Center

            transform: Translate {
                x: layer.transitionType === "left" ? (1 - layer.progress) * layer.width : layer.transitionType === "right" ? -(1 - layer.progress) * layer.width : 0
                y: layer.transitionType === "up" ? (1 - layer.progress) * layer.height : layer.transitionType === "down" ? -(1 - layer.progress) * layer.height : 0
            }

            Image {
                id: img

                anchors.fill: parent
                source: layer.path ? (String(layer.path).startsWith("file://") ? layer.path : "file://" + layer.path) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                visible: status === Image.Ready
            }

            NumberAnimation {
                id: anim

                target: layer
                property: "progress"
                from: 0
                to: 1
                duration: root.duration
                easing.type: Easing.OutCubic
            }

            function start(): void {
                if (transitionType === "none") {
                    layer.progress = 1;
                    return;
                }
                anim.start();
            }

            Component.onCompleted: {
                if (img.status === Image.Ready)
                    start();
            }

            Connections {
                target: img

                function onStatusChanged(): void {
                    if (img.status === Image.Ready || img.status === Image.Error)
                        layer.start();
                }
            }
        }
    }
}
