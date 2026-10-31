import QtQuick

// Scale the picker the same way the old shell did: relative to a 1920x1080
// canvas, with a slightly compressed curve so 1440p/4K do not get huge.
Item {
    id: root

    visible: false

    property real currentWidth: 1920
    property real currentHeight: 1080
    property real uiScale: 1

    readonly property real baseScale: {
        if (currentWidth <= 0 || currentHeight <= 0)
            return 1;

        const r = Math.min(currentWidth / 1920, currentHeight / 1080);
        const s = r <= 1 ? Math.max(0.35, Math.pow(r, 0.85)) : Math.pow(r, 0.5);
        return s * uiScale;
    }

    function s(value: real): real {
        return Math.round(value * baseScale);
    }
}
