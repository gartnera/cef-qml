import QtQuick
import CefQml

// Site settings page for a SiteSettings store: every site scope (origin,
// host, [*.] pattern and the "*" default) with its stored values as chips.
// × on a chip resets that value, "Reset" removes everything stored for the
// site, "Reset all…" empties the store. Searchable (scope and key names).
//
//   SiteSettingsManager {
//       anchors.fill: parent
//       store: mySiteSettings
//       onCloseRequested: visible = false
//   }
//
// Keys (in the search field): Up/Down/PgUp/PgDown select, Shift+Delete
// resets the selected site, Escape cancels "Reset all…", then clears the
// search, then emits closeRequested(). `Browser` shows one as an overlay
// (action "site.settings", or "Site settings…" in the site info card).
//
// objectNames for tests and automation: siteSettingsSearch,
// siteSettingsList, siteSettingsEmpty, siteSettingsStatus,
// siteSettingsResetAll, siteSettingsResetAllConfirm,
// siteSettingsResetAllCancel, siteSettingsClose; rows (rowAt(i)) contain
// siteSettingsReset and siteSettingsChip (property settingKey) chips with
// a siteSettingsChipReset button.
FocusScope {
    id: sm

    property SiteSettings store: null
    property alias filterText: search.text
    property alias currentIndex: list.currentIndex
    readonly property int count: filtered.count
    readonly property SiteSettingsModel model: filtered
    property string title: "Site settings"
    property bool closable: true
    // Whether "Reset all…" asks for confirmation now.
    readonly property bool confirming: _confirming
    readonly property string status: _status

    signal closeRequested()

    implicitWidth: 720
    implicitHeight: 560

    // --- API ------------------------------------------------------------

    function focusDefault() { search.forceActiveFocus(Qt.OtherFocusReason) }
    // { scope, name, kind, settings, keys } of row `i`.
    function entryAt(i) { return filtered.get(i) }
    function rowAt(i) {
        list.forceLayout()
        return list.itemAtIndex(i)
    }
    // Resets one key of the site at row `i`, or the whole site without `key`.
    function resetSite(i, key) {
        const e = entryAt(i === undefined ? currentIndex : i)
        if (!e || !store) return false
        const ok = store.reset(e.scope, key === undefined ? "" : key)
        if (ok) _status = key ? "Reset " + label(key) + " for " + _scopeLabel(e)
                               : "Reset all settings for " + _scopeLabel(e)
        if (currentIndex >= count) currentIndex = count - 1
        return ok
    }
    // Shows (or hides) the "Reset all…" confirmation.
    function askResetAll(show) { _confirming = show === undefined ? true : !!show }
    // Removes every stored site setting.
    function resetAll() {
        if (!store) return false
        const n = store.count
        store.clear()
        _confirming = false
        currentIndex = -1
        _status = n === 0 ? "Nothing to reset" : "Reset " + n + (n === 1 ? " site" : " sites")
        focusDefault()
        return true
    }
    // Display name of a key ("camera" → "Camera", "midi-sysex" → "Midi sysex").
    function label(key) {
        const names = {
            javascript: "JavaScript", popups: "Pop-ups", geolocation: "Location",
            "midi-sysex": "MIDI SysEx", zoom: "Zoom"
        }
        if (key in names) return names[key]
        const t = String(key).replace(/-/g, " ")
        return t.charAt(0).toUpperCase() + t.slice(1)
    }
    // Display text of a value: "125%" for zoom, "Allow", "Block", "Ask".
    function valueText(key, value) {
        if (key === "zoom") return Math.round(Number(value) * 100) + "%"
        if (typeof value === "string") return value.charAt(0).toUpperCase() + value.slice(1)
        return JSON.stringify(value)
    }
    function handleKey(event) {
        switch (event.key) {
        case Qt.Key_Down: _move(1); break
        case Qt.Key_Up: _move(-1); break
        case Qt.Key_PageDown: _move(Math.max(1, Math.floor(list.height / 60))); break
        case Qt.Key_PageUp: _move(-Math.max(1, Math.floor(list.height / 60))); break
        case Qt.Key_Delete:
            if (!(event.modifiers & Qt.ShiftModifier) || currentIndex < 0) return
            resetSite(currentIndex)
            break
        case Qt.Key_Escape:
            if (_confirming) _confirming = false
            else if (filterText !== "") filterText = ""
            else closeRequested()
            break
        default:
            return
        }
        event.accepted = true
    }

    // --- Internals ------------------------------------------------------

    property bool _confirming: false
    property string _status: ""

    function _scopeLabel(e) {
        return e.kind === "default" ? "all sites" : e.scope
    }
    function _move(delta) {
        if (count === 0) return
        const i = currentIndex < 0 ? (delta > 0 ? 0 : count - 1) : currentIndex + delta
        currentIndex = Math.max(0, Math.min(count - 1, i))
        list.positionViewAtIndex(currentIndex, ListView.Contain)
    }

    onFilterTextChanged: currentIndex = filterText !== "" && count > 0 ? 0 : -1
    onCountChanged: if (currentIndex >= count) currentIndex = count - 1
    Keys.onPressed: event => handleKey(event)

    SiteSettingsModel {
        id: filtered
        store: sm.store
    }
    Binding { target: filtered; property: "filterText"; value: search.text }

    component Button: Rectangle {
        id: button
        property string text
        property bool primary: false
        property bool danger: false
        property bool enabled: true
        signal clicked()
        implicitWidth: label.implicitWidth + 20
        implicitHeight: 26
        radius: Style.radius
        opacity: enabled ? 1 : 0.4
        color: primary ? (mouse.pressed ? Qt.darker(Style.danger, 1.2) : Style.danger)
             : mouse.pressed ? Style.surfaceActive
             : mouse.containsMouse ? Style.surfaceHover : Style.background
        border.color: primary ? "transparent" : danger && mouse.containsMouse ? Style.danger : Style.border
        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            color: button.primary ? "white" : button.danger ? Style.danger : Style.text
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: button.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Style.radius * 2
        color: Style.surface
        border.color: Style.border
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: sm.focusDefault()
            onWheel: {}
        }
    }

    Column {
        id: header
        x: 16; y: 14
        width: parent.width - 32
        spacing: 10

        Item {
            width: parent.width
            height: 28
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - resetAllButton.width - (closeButton.visible ? closeButton.width : 0) - 16
                text: sm.title
                color: Style.text
                font.pixelSize: Style.fontSize + 3
                font.bold: true
                font.family: Style.fontFamily
                elide: Text.ElideRight
            }
            Button {
                id: resetAllButton
                objectName: "siteSettingsResetAll"
                anchors.right: closeButton.visible ? closeButton.left : parent.right
                anchors.rightMargin: closeButton.visible ? 8 : 0
                anchors.verticalCenter: parent.verticalCenter
                text: "Reset all…"
                danger: true
                enabled: sm.store !== null && sm.store.count > 0
                onClicked: sm.askResetAll(!sm.confirming)
            }
            IconButton {
                id: closeButton
                objectName: "siteSettingsClose"
                visible: sm.closable
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "×"
                onClicked: sm.closeRequested()
            }
        }

        Rectangle {
            visible: sm._confirming
            width: parent.width
            height: visible ? confirmRow.implicitHeight + 16 : 0
            radius: Style.radius
            color: Style.background
            border.color: Style.danger
            Row {
                id: confirmRow
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                spacing: 6
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Reset the settings of every site?"
                    color: Style.text
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                    rightPadding: 4
                }
                Button { objectName: "siteSettingsResetAllConfirm"; text: "Reset all"; primary: true; onClicked: sm.resetAll() }
                Button {
                    objectName: "siteSettingsResetAllCancel"
                    text: "Cancel"
                    onClicked: { sm.askResetAll(false); sm.focusDefault() }
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 30
            radius: Style.radius
            color: Style.background
            border.color: search.activeFocus ? Style.accent : Style.border
            TextInput {
                id: search
                objectName: "siteSettingsSearch"
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                focus: true
                color: Style.text
                selectionColor: Style.accent
                selectByMouse: true
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
                Keys.onPressed: event => sm.handleKey(event)
                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: search.text === ""
                    text: "Search sites and settings"
                    color: Style.textDim
                    font: search.font
                    elide: Text.ElideRight
                }
            }
        }

        Text {
            objectName: "siteSettingsStatus"
            width: parent.width
            visible: text !== ""
            text: sm._status
            color: Style.textDim
            elide: Text.ElideRight
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
    }

    ListView {
        id: list
        objectName: "siteSettingsList"
        cacheBuffer: 0
        anchors.top: header.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        clip: true
        currentIndex: -1
        spacing: 2
        boundsBehavior: Flickable.StopAtBounds
        highlightFollowsCurrentItem: false
        model: filtered

        Text {
            objectName: "siteSettingsEmpty"
            anchors.centerIn: parent
            visible: list.count === 0
            width: parent.width - 32
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: !sm.store ? "No site settings store."
                : sm.filterText !== "" ? "No site settings match “" + sm.filterText + "”."
                : "No site settings yet. Permission decisions you remember and zoom levels you choose are listed here."
            color: Style.textDim
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }

        delegate: Rectangle {
            id: row
            required property int index
            required property string scope
            required property string name
            required property string kind
            required property var settings
            required property var keys

            width: ListView.view.width
            height: rowColumn.implicitHeight + 16
            radius: Style.radius
            color: ListView.isCurrentItem ? Style.surfaceActive
                 : rowMouse.containsMouse ? Style.surfaceHover : "transparent"

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { sm.currentIndex = row.index; sm.focusDefault() }
            }

            Column {
                id: rowColumn
                x: 10; y: 8
                width: parent.width - 20 - resetButton.width - 8
                spacing: 6
                Text {
                    width: parent.width
                    text: row.kind === "default" ? "All sites (default)" : row.name
                    color: Style.text
                    elide: Text.ElideRight
                    font.pixelSize: Style.fontSize
                    font.bold: true
                    font.family: Style.fontFamily
                }
                Text {
                    width: parent.width
                    visible: row.kind !== "default"
                    text: row.scope + "  ·  " + ({
                        origin: "this origin",
                        host: "any scheme and port",
                        pattern: "including subdomains"
                    })[row.kind]
                    color: Style.textDim
                    elide: Text.ElideMiddle
                    font.pixelSize: Style.fontSize - 2
                    font.family: Style.fontFamily
                }
                Flow {
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: row.keys
                        delegate: Rectangle {
                            id: chip
                            required property string modelData
                            objectName: "siteSettingsChip"
                            readonly property string settingKey: modelData
                            readonly property var value: row.settings[modelData]
                            width: chipText.implicitWidth + chipReset.width + 14
                            height: 22
                            radius: 11
                            color: Style.background
                            border.color: value === "block" ? Style.danger
                                        : value === "allow" ? Style.accent : Style.border
                            Text {
                                id: chipText
                                x: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: sm.label(chip.settingKey) + ": " + sm.valueText(chip.settingKey, chip.value)
                                color: Style.text
                                font.pixelSize: Style.fontSize - 1
                                font.family: Style.fontFamily
                            }
                            Text {
                                id: chipReset
                                objectName: "siteSettingsChipReset"
                                anchors.left: chipText.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 18
                                horizontalAlignment: Text.AlignHCenter
                                text: "×"
                                color: chipMouse.containsMouse ? Style.text : Style.textDim
                                font.pixelSize: Style.fontSize
                                font.family: Style.fontFamily
                                function click() { sm.resetSite(row.index, chip.settingKey) }
                                MouseArea {
                                    id: chipMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: chipReset.click()
                                }
                            }
                        }
                    }
                }
            }
            Button {
                id: resetButton
                objectName: "siteSettingsReset"
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: "Reset"
                onClicked: sm.resetSite(row.index)
            }
        }
    }
}
