import QtQuick
import CefQml

// A modal panel over part of the window: dims what is underneath, centres
// its content (a card such as UserScriptManager or HistoryView) and closes
// on a backdrop click or Escape. `Browser` hosts its manager panels in
// these; for your own panels:
//
//   PanelOverlay {
//       id: settingsOverlay
//       anchors.fill: parent
//       returnFocusTo: tabs.currentView
//       MySettings { anchors.fill: parent; onCloseRequested: settingsOverlay.close() }
//   }
//   ... settingsOverlay.toggle()
//
// The content fills the centred panel (panelWidth x panelHeight, shrunk to
// the overlay's size). open() gives it focus by calling its focusDefault()
// when it has one; close() moves focus to `returnFocusTo`.
FocusScope {
    id: overlay

    default property alias content: panel.data
    // The first content item (whose focusDefault() open() calls).
    readonly property Item contentItem: panel.children.length > 0 ? panel.children[0] : null
    property real panelWidth: 820
    property real panelHeight: 600
    // Distance from the top edge when there is room (centred otherwise).
    property real topMargin: 48
    property real sideMargin: 16
    property color backdropColor: "#80000000"
    property bool closeOnBackdropClick: true
    property bool closeOnEscape: true
    // false keeps open() from showing the overlay (e.g. no store to manage).
    property bool available: true
    // Item that gets focus back when the overlay closes.
    property Item returnFocusTo: null
    // The centred panel holding the content.
    readonly property Item panelItem: panel

    signal opened()
    signal closed()

    visible: false

    function open() {
        if (!available) return false
        if (!visible) {
            visible = true
            opened()
        }
        focusContent()
        return true
    }
    function close() {
        if (!visible) return
        visible = false
        closed()
        if (returnFocusTo) returnFocusTo.forceActiveFocus(Qt.OtherFocusReason)
    }
    function toggle() { visible ? close() : open() }
    function focusContent() {
        const c = contentItem
        if (c && typeof c.focusDefault === "function") c.focusDefault()
        else if (c) c.forceActiveFocus(Qt.OtherFocusReason)
        else overlay.forceActiveFocus(Qt.OtherFocusReason)
    }

    onAvailableChanged: if (!available) close()

    // Escape the content did not handle.
    Keys.onEscapePressed: event => {
        if (closeOnEscape) close()
        else event.accepted = false
    }

    Rectangle {
        objectName: "panelOverlayBackdrop"
        anchors.fill: parent
        color: overlay.backdropColor
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: if (overlay.closeOnBackdropClick) overlay.close()
            onWheel: {}
        }
    }

    Item {
        id: panel
        objectName: "panelOverlayPanel"
        width: Math.max(0, Math.min(overlay.panelWidth, overlay.width - 2 * overlay.sideMargin))
        x: Math.round((overlay.width - width) / 2)
        y: Math.max(8, Math.min(overlay.topMargin, (overlay.height - overlay.panelHeight) / 2))
        height: Math.max(0, Math.min(overlay.panelHeight, overlay.height - 2 * y))
    }
}
