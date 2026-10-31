pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.components.effects
import qs.services
import qs.utils

Item {
    id: root

    property bool closing: false
    property bool deleteMode: false

    signal requestClose
    signal closed

    readonly property int columns: 3
    readonly property int rows: 4
    readonly property int fetchLimit: 30
    readonly property real padding: Tokens.padding.large
    readonly property real spacing: Tokens.spacing.small

    readonly property real cardWidth: Math.min(width - Tokens.padding.extraLarge * 2, 920)
    readonly property real cardHeight: Math.min(height - Tokens.padding.extraLarge * 2, 720)

    property bool opened: false
    property bool previewMode: false
    property string previewText: ""
    property var allClips: []
    property var clips: []
    property int nextOffset: 0
    property bool loading: false
    property bool hasMore: true
    property int pendingIndex: -1
    property bool keyboardNav: false

    readonly property var currentClip: grid.currentIndex >= 0 && grid.currentIndex < clips.length ? clips[grid.currentIndex] : null

    focus: true

    function applyFilter(resetPosition: bool): void {
        const query = search.text.trim().toLowerCase();
        const previous = grid.currentIndex;
        clips = query.length === 0 ? allClips.slice() : allClips.filter(c => c.type === "image" || String(c.content).toLowerCase().includes(query));

        if (clips.length === 0)
            grid.currentIndex = -1;
        else if (previous < 0 || previous >= clips.length)
            grid.currentIndex = 0;

        if (resetPosition)
            grid.positionViewAtBeginning();
    }

    function fetchClips(offset: int): void {
        if (loading)
            return;

        loading = true;
        fetcher.command = ["python3", Quickshell.shellPath("modules/clipboard/clip_fetcher.py"), offset, fetchLimit, `${Paths.cache}/clipboard`];
        fetcher.running = true;
    }

    function loadMore(): void {
        if (loading || !hasMore)
            return;

        fetchClips(nextOffset);
    }

    function moveBy(delta: int): void {
        previewMode = false;
        keyboardNav = true;
        navTimer.restart();

        if (clips.length === 0)
            return;

        let target = grid.currentIndex + delta;
        if (target < 0)
            target = 0;
        if (target >= clips.length) {
            if (hasMore) {
                pendingIndex = target;
                loadMore();
                return;
            }
            target = clips.length - 1;
        }

        grid.currentIndex = target;
    }

    function activateCurrent(): void {
        if (root.deleteMode)
            root.deleteCurrent();
        else
            root.copyCurrent();
    }

    function copyCurrent(): void {
        const clip = root.currentClip;
        if (!clip)
            return;

        root.copyClip(clip.id);
    }

    function copyClip(id: var): void {
        const safeId = String(id).replace(/[^0-9]/g, "");
        if (safeId.length === 0)
            return;

        Quickshell.execDetached(["sh", "-c", `cliphist decode ${safeId} | wl-copy`]);
        root.requestClose();
    }

    function deleteCurrent(): void {
        const clip = root.currentClip;
        if (!clip)
            return;

        root.deleteClip(clip.id);
    }

    function deleteClip(id: var): void {
        const safeId = String(id).replace(/[^0-9]/g, "");
        if (safeId.length === 0)
            return;

        Quickshell.execDetached(["sh", "-c", `cliphist list | grep -m1 '^${safeId}\t' | cliphist delete`]);

        root.allClips = root.allClips.filter(c => String(c.id) !== safeId);
        root.applyFilter(true);
    }

    function togglePreview(): void {
        const clip = root.currentClip;
        if (!clip)
            return;

        if (root.previewMode) {
            root.previewMode = false;
            return;
        }

        root.previewText = "";
        root.previewMode = true;

        if (clip.type === "text") {
            decodeProcess.running = false;
            decodeProcess.command = ["cliphist", "decode", String(clip.id).replace(/[^0-9]/g, "")];
            decodeProcess.running = true;
        }
    }

    onClosingChanged: {
        if (closing) {
            opened = false;
            closeTimer.restart();
        } else {
            closeTimer.stop();
            opened = true;
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => {
            root.opened = true;
            search.forceActiveFocus();
        });
        root.fetchClips(0);
    }

    Timer {
        id: navTimer

        interval: Tokens.anim.durations.expressiveDefaultSpatial
        onTriggered: root.keyboardNav = false
    }

    Timer {
        id: closeTimer

        interval: Math.max(Tokens.anim.durations.expressiveSlowSpatial, Tokens.anim.durations.expressiveSlowEffects) + 50
        onTriggered: root.closed()
    }

    Process {
        id: fetcher

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const items = JSON.parse(text);
                    const list = Array.isArray(items) ? items : [];

                    if (root.nextOffset === 0)
                        root.allClips = list;
                    else
                        root.allClips = root.allClips.concat(list);

                    root.nextOffset = root.allClips.length;
                    root.hasMore = list.length >= root.fetchLimit;
                    root.applyFilter(false);
                } catch (e) {
                    root.hasMore = false;
                    console.warn("Failed to parse clipboard history:", e);
                } finally {
                    root.loading = false;
                }

                if (root.pendingIndex !== -1) {
                    grid.currentIndex = Math.min(root.pendingIndex, root.clips.length - 1);
                    root.pendingIndex = -1;
                }
            }
        }
    }

    Process {
        id: decodeProcess

        stdout: StdioCollector {
            onStreamFinished: root.previewText = text
        }
    }

    StyledRect {
        id: scrim

        anchors.fill: parent
        color: Colours.palette.m3scrim
        opacity: root.opened ? 0.35 : 0

        Behavior on opacity {
            Anim {
                type: Anim.SlowEffects
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.requestClose()
    }

    Item {
        id: cardWrapper

        anchors.centerIn: parent
        width: root.cardWidth
        height: root.cardHeight

        scale: root.opened ? 1 : 0.94
        opacity: root.opened ? 1 : 0

        Behavior on scale {
            Anim {
                type: Anim.Emphasized
            }
        }

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        Elevation {
            anchors.fill: card
            radius: card.radius
            level: 4
        }

        StyledRect {
            id: card

            anchors.fill: parent
            radius: Tokens.rounding.extraLarge
            color: Colours.palette.m3surface
            border.width: 1
            border.color: Colours.palette.m3outlineVariant
            clip: true

            // Keep clicks inside the card from reaching the dismiss area
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onClicked: mouse => mouse.accepted = true
            }

            SearchBar {
                id: search

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: root.padding

                topPadding: Math.round((Tokens.padding.medium + Tokens.padding.large) / 2)
                bottomPadding: Math.round((Tokens.padding.medium + Tokens.padding.large) / 2)

                placeholderText: root.deleteMode ? Tr.tr("Search clipboard to delete") : Tr.tr("Search clipboard")

                onTextChanged: {
                    root.previewMode = false;
                    root.pendingIndex = -1;
                    root.applyFilter(true);
                }

                Keys.onEscapePressed: event => {
                    if (root.previewMode)
                        root.previewMode = false;
                    else
                        root.requestClose();
                    event.accepted = true;
                }

                Keys.onReturnPressed: event => {
                    root.previewMode ? root.copyCurrent() : root.activateCurrent();
                    event.accepted = true;
                }

                Keys.onEnterPressed: event => {
                    root.previewMode ? root.copyCurrent() : root.activateCurrent();
                    event.accepted = true;
                }

                Keys.onTabPressed: event => {
                    root.togglePreview();
                    event.accepted = true;
                }

                Keys.onDeletePressed: event => {
                    root.deleteCurrent();
                    event.accepted = true;
                }

                Keys.onRightPressed: event => {
                    root.moveBy(1);
                    event.accepted = true;
                }

                Keys.onLeftPressed: event => {
                    root.moveBy(-1);
                    event.accepted = true;
                }

                Keys.onDownPressed: event => {
                    root.moveBy(root.columns);
                    event.accepted = true;
                }

                Keys.onUpPressed: event => {
                    root.moveBy(-root.columns);
                    event.accepted = true;
                }
            }

            Item {
                id: footer

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: root.padding

                implicitHeight: hint.implicitHeight

                StyledText {
                    id: hint

                    anchors.centerIn: parent

                    text: root.previewMode ? Tr.tr("Esc back · Enter copy") : Tr.tr("Tab preview · Enter copy · Del delete · Esc close")
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.small
                }
            }

            GridView {
                id: grid

                anchors.top: search.bottom
                anchors.topMargin: Tokens.spacing.medium
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: footer.top
                anchors.bottomMargin: Tokens.spacing.small
                anchors.leftMargin: root.padding
                anchors.rightMargin: root.padding

                clip: true
                cellWidth: Math.floor((width - root.spacing * (root.columns - 1)) / root.columns)
                cellHeight: Math.floor((height - root.spacing * (root.rows - 1)) / root.rows)
                boundsBehavior: Flickable.StopAtBounds
                highlightFollowsCurrentItem: false
                currentIndex: -1
                model: root.clips

                Behavior on contentY {
                    enabled: root.keyboardNav

                    Anim {
                        type: Anim.DefaultSpatial
                    }
                }

                onContentYChanged: {
                    if (contentY + height >= contentHeight - cellHeight)
                        root.loadMore();
                }

                onCurrentIndexChanged: {
                    if (currentIndex < 0)
                        return;

                    if (currentIndex >= root.clips.length - root.columns * 2)
                        root.loadMore();

                    const rowTop = Math.floor(currentIndex / root.columns) * cellHeight;
                    const rowBottom = rowTop + cellHeight;
                    if (rowTop < contentY)
                        contentY = rowTop;
                    else if (rowBottom > contentY + height)
                        contentY = rowBottom - height;
                }

                StyledScrollBar.vertical: StyledScrollBar {
                    flickable: grid
                }
                delegate: Item {
                    id: delegateRoot

                    required property int index
                    required property var modelData

                    readonly property var entry: modelData
                    readonly property bool selected: grid.currentIndex === index

                    width: grid.cellWidth
                    height: grid.cellHeight

                    StyledRect {
                        id: cardItem

                        anchors.fill: parent
                        anchors.margins: root.spacing / 2
                        radius: Tokens.rounding.large
                        color: delegateRoot.selected ? Colours.palette.m3secondaryContainer : stateLayer.containsMouse ? Qt.alpha(Colours.palette.m3onSurface, 0.06) : Qt.alpha(Colours.palette.m3surfaceContainerHigh, 0.55)
                        clip: true

                        StyledClippingRect {
                            anchors.fill: parent
                            anchors.margins: Tokens.spacing.extraSmall
                            radius: cardItem.radius
                            color: "transparent"
                            visible: delegateRoot.entry.type === "image"

                            Image {
                                anchors.fill: parent
                                source: delegateRoot.entry.type === "image" ? `file://${delegateRoot.entry.content}` : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                sourceSize: Qt.size(width, height)
                            }
                        }

                        StyledText {
                            anchors.fill: parent
                            anchors.leftMargin: Tokens.padding.medium
                            anchors.rightMargin: Tokens.padding.medium
                            anchors.topMargin: Tokens.padding.medium + badge.height + Tokens.spacing.extraSmall
                            anchors.bottomMargin: Tokens.padding.medium

                            visible: delegateRoot.entry.type !== "image"
                            text: delegateRoot.entry.content
                            color: delegateRoot.selected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                            font: Tokens.font.body.small
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                            maximumLineCount: 4
                            verticalAlignment: Text.AlignTop
                        }

                        StyledRect {
                            id: badge

                            x: Tokens.spacing.extraSmall
                            y: Tokens.spacing.extraSmall
                            implicitWidth: 22
                            implicitHeight: 22
                            radius: Tokens.rounding.small
                            color: delegateRoot.selected ? Colours.palette.m3primary : Qt.alpha(Colours.palette.m3surfaceContainerHighest, 0.9)

                            StyledText {
                                anchors.centerIn: parent
                                text: delegateRoot.index + 1
                                color: delegateRoot.selected ? Colours.palette.m3onPrimary : Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.small
                            }
                        }

                        StateLayer {
                            id: stateLayer

                            anchors.fill: parent
                            radius: cardItem.radius
                            showHoverBackground: false
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: event => {
                                grid.currentIndex = delegateRoot.index;
                                if (event.button === Qt.RightButton)
                                    root.togglePreview();
                                else if (root.deleteMode)
                                    root.deleteClip(delegateRoot.entry.id);
                                else
                                    root.copyClip(delegateRoot.entry.id);
                            }
                        }
                    }
                }
            }

            Item {
                id: emptyState

                anchors.fill: grid
                visible: root.clips.length === 0
                opacity: visible ? 1 : 0

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: Tokens.spacing.small

                    LoadingIndicator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        implicitSize: 36
                        animated: root.loading
                        opacity: root.loading ? 1 : 0

                        Behavior on opacity {
                            Anim {
                                type: Anim.DefaultEffects
                            }
                        }
                    }

                    MaterialIcon {
                        anchors.horizontalCenter: parent.horizontalCenter

                        text: root.loading ? "content_paste_search" : "content_paste_off"
                        color: Colours.palette.m3onSurfaceVariant
                        fontStyle: Tokens.font.icon.extraLarge
                        visible: !root.loading
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter

                        text: root.loading ? Tr.tr("Loading clipboard…") : Tr.tr("Clipboard is empty")
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.medium
                    }
                }
            }

            Item {
                id: preview

                anchors.fill: grid
                visible: opacity > 0
                opacity: root.previewMode ? 1 : 0
                scale: root.previewMode ? 1 : 0.96

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                Behavior on scale {
                    Anim {
                        type: Anim.Emphasized
                    }
                }

                StyledRect {
                    anchors.fill: parent
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainerHighest
                    border.width: 1
                    border.color: Colours.palette.m3outlineVariant

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.AllButtons
                        onClicked: mouse => mouse.accepted = true
                    }
                }

                MaterialIcon {
                    id: previewIcon

                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: Tokens.padding.medium

                    text: root.currentClip?.type === "image" ? "image" : "notes"
                    color: Colours.palette.m3onSurfaceVariant
                    fontStyle: Tokens.font.icon.small
                }

                StyledText {
                    anchors.left: previewIcon.right
                    anchors.leftMargin: Tokens.spacing.small
                    anchors.verticalCenter: previewIcon.verticalCenter

                    text: root.currentClip?.type === "image" ? Tr.tr("Image") : Tr.tr("Text")
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.medium
                }

                IconButton {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: Tokens.padding.small

                    icon: "close"
                    type: IconButton.Text
                    onClicked: root.previewMode = false
                }

                Image {
                    id: previewImage

                    anchors.fill: parent
                    anchors.topMargin: previewIcon.height + Tokens.padding.medium * 2
                    anchors.margins: Tokens.padding.medium

                    source: root.previewMode && root.currentClip?.type === "image" ? `file://${root.currentClip.content}` : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    visible: root.currentClip?.type === "image"
                }

                Flickable {
                    id: previewFlick

                    anchors.fill: parent
                    anchors.topMargin: previewIcon.height + Tokens.padding.medium * 2
                    anchors.margins: Tokens.padding.medium

                    visible: root.currentClip?.type === "text"
                    contentWidth: width
                    contentHeight: previewTextItem.paintedHeight
                    clip: true

                    ScrollBar.vertical: StyledScrollBar {
                        flickable: previewFlick
                    }

                    TextEdit {
                        id: previewTextItem

                        width: previewFlick.width
                        text: root.previewMode ? (root.previewText.length > 0 ? root.previewText : (root.currentClip?.content ?? "")) : ""
                        color: Colours.palette.m3onSurface
                        font: Tokens.font.body.medium
                        textFormat: TextEdit.PlainText
                        wrapMode: TextEdit.Wrap
                        readOnly: true
                        selectByMouse: true
                        selectionColor: Qt.alpha(Colours.palette.m3primary, 0.4)
                        selectedTextColor: Colours.palette.m3onSurface
                    }
                }
            }
        }
    }
}
