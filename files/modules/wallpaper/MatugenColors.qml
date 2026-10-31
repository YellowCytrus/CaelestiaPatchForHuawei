// Compatibility bridge for the wallpaper picker ported from ~/.config.old.
// Maps the old Matugen colour names onto Caelestia's Material palette.
import QtQuick
import qs.services

QtObject {
    readonly property color base: Colours.palette.m3surfaceContainerLow
    readonly property color mantle: Colours.palette.m3surfaceContainerLowest
    readonly property color text: Colours.palette.m3onSurface
    readonly property color surface1: Colours.palette.m3surfaceContainerHigh
    readonly property color surface2: Colours.palette.m3surfaceContainerHighest
}
