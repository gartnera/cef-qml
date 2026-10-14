pragma Singleton
import QtQuick

// Shared look of CefQml.Components. Properties are writable, so a shell can
// theme everything at once:  Component.onCompleted: Style.accent = "#e0a"
QtObject {
    property color background: "#1e1f22"
    property color surface: "#2b2d31"
    property color surfaceHover: "#35373c"
    property color surfaceActive: "#404249"
    property color border: "#3f4147"
    property color text: "#e6e6e8"
    property color textDim: "#9a9ca3"
    property color accent: "#5b9cf5"
    property color danger: "#e5534b"
    property real radius: 6
    property int fontSize: 13
    property int barHeight: 36
    property string fontFamily: "sans-serif"
}
