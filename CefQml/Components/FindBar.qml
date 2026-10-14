import QtQuick
import CefQml

// Find-in-page bar. Enter: next, Shift+Enter: previous, Escape: close.
Rectangle {
    id: bar
    property CefWebView view
    property alias text: input.text
    property int matchCount: 0
    property int activeMatch: 0
    property bool matchCase: false
    signal closeRequested()

    implicitHeight: Style.barHeight
    color: Style.surface

    function open() {
        visible = true
        input.forceActiveFocus(Qt.ShortcutFocusReason)
        input.selectAll()
    }
    function close() {
        if (view) view.stopFinding(true)
        matchCount = 0
        activeMatch = 0
        visible = false
        if (view) view.forceActiveFocus(Qt.OtherFocusReason)
        closeRequested()
    }
    function findNext(forward) {
        if (view) view.find(input.text, forward === undefined ? true : forward, matchCase)
    }

    onViewChanged: { matchCount = 0; activeMatch = 0 }

    Connections {
        target: bar.view
        function onFindResult(count, active, finalUpdate) {
            bar.matchCount = count
            if (active > 0) bar.activeMatch = active
            // A fresh search reports no active match; step onto the first one.
            else if (finalUpdate && count > 0 && bar.activeMatch === 0) bar.findNext(true)
        }
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Rectangle {
            width: 240; height: 26
            radius: Style.radius
            color: Style.background
            border.color: input.activeFocus ? Style.accent : Style.border
            TextInput {
                id: input
                objectName: "findInput"
                anchors.fill: parent
                anchors.leftMargin: 8; anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                color: Style.text
                selectionColor: Style.accent
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
                onTextChanged: {
                    bar.activeMatch = 0
                    if (text === "") { bar.matchCount = 0; if (bar.view) bar.view.stopFinding(true) }
                    else bar.findNext(true)
                }
                Keys.onReturnPressed: event => bar.findNext(!(event.modifiers & Qt.ShiftModifier))
                Keys.onEnterPressed: event => bar.findNext(!(event.modifiers & Qt.ShiftModifier))
                Keys.onEscapePressed: bar.close()
            }
        }
        Text {
            objectName: "findStatus"
            anchors.verticalCenter: parent.verticalCenter
            text: input.text === "" ? "" : bar.matchCount === 0 ? "No matches"
                : (bar.activeMatch > 0 ? bar.activeMatch : "?") + " / " + bar.matchCount
            color: bar.matchCount === 0 && input.text !== "" ? Style.danger : Style.textDim
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
        IconButton { text: "↑"; onClicked: bar.findNext(false) }
        IconButton { text: "↓"; onClicked: bar.findNext(true) }
        IconButton { text: "×"; onClicked: bar.close() }
    }
}
