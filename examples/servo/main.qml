import QtQuick
import QtQuick.Window
import CefQml
import CefQml.Components
import ServoQml

// A minimal browser on Servo (ServoWebView), with an optional Chromium
// (CefWebView) view next to it showing the same page.
//   QML_IMPORT_PATH=build /usr/lib/qt6/bin/qml examples/servo/main.qml [-- URL]
// Keys: Ctrl+L address, F5 reload, Alt+Left/Right history, Ctrl+D compare.
Window {
    id: win
    width: 1280; height: 800
    visible: true
    color: Style.background
    title: (servo.title || "Servo") + " — ServoWebView"

    readonly property string startUrl: {
        const args = Qt.application.arguments
        for (let i = args.length - 1; i > 0; i--)
            if (/^[a-z]+:/.test(args[i]) && !args[i].endsWith(".qml")) return args[i]
        return "https://servo.org/"
    }
    property bool compare: false

    function navigate(text) {
        text = text.trim()
        if (text === "") return
        let url = Cef.urlFromUserInput(text)
        if (!url.toString())
            url = "https://duckduckgo.com/html/?q=" + encodeURIComponent(text)
        servo.url = url
        servo.forceActiveFocus()
    }

    Rectangle {
        id: bar
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: Style.barHeight + 8
        color: Style.surface

        Row {
            id: buttons
            anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 2
            IconButton { text: "←"; toolTip: "Back"; enabled: servo.canGoBack; onClicked: servo.goBack() }
            IconButton { text: "→"; toolTip: "Forward"; enabled: servo.canGoForward; onClicked: servo.goForward() }
            IconButton { text: "⟳"; toolTip: "Reload"; onClicked: servo.reload() }
        }

        Rectangle {
            id: field
            anchors {
                left: buttons.right; leftMargin: 6; right: tools.left; rightMargin: 6
                verticalCenter: parent.verticalCenter
            }
            height: Style.barHeight - 6
            radius: height / 2
            color: Style.background
            border.color: address.activeFocus ? Style.accent : Style.border

            TextInput {
                id: address
                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                verticalAlignment: TextInput.AlignVCenter
                color: Style.text
                selectionColor: Style.accent
                font.pixelSize: Style.fontSize + 1
                font.family: Style.fontFamily
                clip: true
                selectByMouse: true
                text: servo.url
                onAccepted: win.navigate(text)
                onActiveFocusChanged: if (activeFocus) selectAll()
                Keys.onEscapePressed: { text = servo.url; servo.forceActiveFocus() }
            }
        }

        Row {
            id: tools
            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 6
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: badge.implicitWidth + 16; height: 22; radius: 11
                color: "#2f5f3a"
                Text {
                    id: badge
                    anchors.centerIn: parent
                    text: "Servo"
                    color: "#d8f5df"
                    font.pixelSize: Style.fontSize - 1
                    font.bold: true
                }
            }
            IconButton {
                text: win.compare ? "Hide Chromium" : "Compare with Chromium"
                checked: win.compare
                onClicked: win.compare = !win.compare
            }
        }

        // Load progress.
        Rectangle {
            anchors { left: parent.left; bottom: parent.bottom }
            height: 2
            width: parent.width * servo.loadProgress
            color: Style.accent
            visible: servo.loading
        }
    }

    Item {
        id: pages
        anchors { left: parent.left; right: parent.right; top: bar.bottom; bottom: parent.bottom }

        ServoWebView {
            id: servo
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: win.compare ? parent.width / 2 : parent.width
            url: win.startUrl
            focus: true
            // No windows of its own: open target=_blank links here.
            onNewWindowRequested: (url) => servo.url = url
            onCrashed: (reason) => console.warn("Servo crashed:", reason)
        }

        // Follows the Servo view's URL.
        Loader {
            active: win.compare
            anchors { left: servo.right; right: parent.right; top: parent.top; bottom: parent.bottom }
            sourceComponent: Item {
                Rectangle { width: 1; height: parent.height; color: Style.border; z: 1 }
                CefWebView {
                    anchors.fill: parent
                    url: servo.url
                }
                Rectangle {
                    anchors { right: parent.right; bottom: parent.bottom; margins: 8 }
                    width: chromeLabel.implicitWidth + 16; height: 22; radius: 11
                    color: "#1f3f6a"
                    Text {
                        id: chromeLabel
                        anchors.centerIn: parent
                        text: "Chromium " + Cef.chromiumVersion
                        color: "#dbe8ff"
                        font.pixelSize: Style.fontSize - 1
                        font.bold: true
                    }
                }
            }
        }
        // Link under the pointer.
        Rectangle {
            visible: servo.hoveredUrl !== ""
            anchors { left: parent.left; bottom: parent.bottom; margins: 4 }
            width: Math.min(hover.implicitWidth + 16, servo.width - 8)
            height: hover.implicitHeight + 8
            radius: 4
            color: Style.surface
            border.color: Style.border
            Text {
                id: hover
                anchors { fill: parent; margins: 4; leftMargin: 8 }
                text: servo.hoveredUrl
                color: Style.textDim
                elide: Text.ElideMiddle
                font.pixelSize: Style.fontSize - 1
            }
        }
    }

    Shortcut { sequence: "Ctrl+L"; onActivated: address.forceActiveFocus() }
    Shortcut { sequence: "F5"; onActivated: servo.reload() }
    Shortcut { sequence: "Alt+Left"; onActivated: servo.goBack() }
    Shortcut { sequence: "Alt+Right"; onActivated: servo.goForward() }
    Shortcut { sequence: "Ctrl+D"; onActivated: win.compare = !win.compare }
}
