import QtQuick
import CefQml

// Browsing history page for a HistoryStore: searchable, grouped by day
// (Today, Yesterday, then dates), newest first. Click an entry to open it
// (Ctrl/Shift+click or middle click: in a new tab), × removes it, and
// "Clear history…" removes the last hour, today or everything.
//
//   HistoryView {
//       anchors.fill: parent
//       store: myHistoryStore
//       onOpenRequested: (url, newTab) => newTab ? tabs.openTab(url) : tabs.currentView.url = url
//       onCloseRequested: visible = false
//   }
//
// Keys (in the search field): Up/Down/PgUp/PgDown select, Enter opens
// (Ctrl/Shift+Enter in a new tab), Shift+Delete removes the selected entry,
// Escape cancels "Clear history…", then clears the search, then emits
// closeRequested(). `Browser` shows one as an overlay (action
// "history.show", Ctrl+H).
//
// objectNames for tests and automation: historySearch, historyList,
// historyEmpty, historyStatus, historyClear, historyClearHour,
// historyClearToday, historyClearAll, historyClearCancel, historyClose; rows
// (rowAt(i)) contain historyRemove.
FocusScope {
    id: hv

    property HistoryStore store: null
    property alias filterText: search.text
    // Selected row (-1: none); Enter opens it.
    property alias currentIndex: list.currentIndex
    readonly property int count: filtered.count
    readonly property HistoryModel model: filtered
    property string title: "History"
    // Show the × close button (emits closeRequested()).
    property bool closable: true
    // Whether the "Clear history…" choices are shown.
    readonly property bool clearing: _clearing
    // Last message in the status line ("Removed 3 entries").
    readonly property string status: _status

    signal openRequested(string url, bool newTab)
    signal closeRequested()

    implicitWidth: 720
    implicitHeight: 560

    // --- API ------------------------------------------------------------

    function focusDefault() {
        _today = _dayKey(new Date())
        search.forceActiveFocus(Qt.OtherFocusReason)
    }
    // The entry shown at row `i` ({ url, title, icon, visitCount, ... }).
    function entryAt(i) { return filtered.get(i) }
    // Emits openRequested() for row `i` (default: the selected row).
    function open(i, newTab) {
        const e = entryAt(i === undefined ? currentIndex : i)
        if (!e) return false
        openRequested(e.url, !!newTab)
        return true
    }
    // Removes the history entry at row `i` (default: the selected row).
    function remove(i) {
        const e = entryAt(i === undefined ? currentIndex : i)
        if (!e || !store) return false
        const row = i === undefined ? currentIndex : i
        store.remove(e.url)
        _setStatus("Removed " + (e.title || _display(e.url)))
        if (filtered.count > 0 && row >= 0) currentIndex = Math.min(row, filtered.count - 1)
        else currentIndex = -1
        return true
    }
    // Removes history: "hour" (the last hour), "today", "all", or every
    // entry visited at or after `range` (ms or Date). Returns the count.
    function clearHistory(range) {
        if (!store) return 0
        let n
        if (range === "hour") n = store.clear(Date.now() - 3600 * 1000)
        else if (range === "today") {
            const d = new Date()
            n = store.clear(new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime())
        } else if (range === undefined || range === "all") n = store.clear()
        else n = store.clear(range)
        _clearing = false
        currentIndex = -1
        _setStatus(n === 0 ? "Nothing to remove" : "Removed " + n + (n === 1 ? " entry" : " entries"))
        search.forceActiveFocus(Qt.OtherFocusReason)
        return n
    }
    // Shows (or hides) the "Clear history…" choices.
    function askClear(show) { _clearing = show === undefined ? true : !!show }
    // The delegate of row `i` (null when it is not instantiated).
    function rowAt(i) {
        list.forceLayout()
        return list.itemAtIndex(i)
    }
    // Section label of a "yyyy-MM-dd" day: Today, Yesterday or the date.
    function dayLabel(day) {
        if (day === _today) return "Today"
        const t = new Date()
        if (day === _dayKey(new Date(t.getFullYear(), t.getMonth(), t.getDate() - 1))) return "Yesterday"
        const p = day.split("-").map(Number)
        if (p.length !== 3) return day
        const d = new Date(p[0], p[1] - 1, p[2])
        return Qt.formatDate(d, d.getFullYear() === t.getFullYear() ? "dddd, d MMMM" : "dddd, d MMMM yyyy")
    }
    // Keyboard handling (the search field forwards its keys here).
    function handleKey(event) {
        const ctrlOrShift = (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) !== 0
        switch (event.key) {
        case Qt.Key_Down: _move(1); break
        case Qt.Key_Up: _move(-1); break
        case Qt.Key_PageDown: _move(Math.max(1, Math.floor(list.height / 44))); break
        case Qt.Key_PageUp: _move(-Math.max(1, Math.floor(list.height / 44))); break
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (currentIndex < 0 && count > 0 && filterText !== "") currentIndex = 0
            if (!open(currentIndex, ctrlOrShift)) return
            break
        case Qt.Key_Delete:
            if (!(event.modifiers & Qt.ShiftModifier) || currentIndex < 0) return
            remove(currentIndex)
            break
        case Qt.Key_Escape:
            if (_clearing) _clearing = false
            else if (filterText !== "") filterText = ""
            else closeRequested()
            break
        default:
            return
        }
        event.accepted = true
    }

    // --- Internals ------------------------------------------------------

    property bool _clearing: false
    property string _status: ""
    property string _today: _dayKey(new Date())

    function _dayKey(d) {
        const pad = n => (n < 10 ? "0" : "") + n
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    }
    function _display(u) {
        u = String(u)
        try { u = decodeURI(u) } catch (e) {}
        return u.length > 300 ? u.substring(0, 300) + "…" : u
    }
    function _setStatus(text) { _status = text }
    function _move(delta) {
        if (count === 0) return
        const i = currentIndex < 0 ? (delta > 0 ? 0 : count - 1) : currentIndex + delta
        currentIndex = Math.max(0, Math.min(count - 1, i))
        list.positionViewAtIndex(currentIndex, ListView.Contain)
    }

    onVisibleChanged: if (visible) _today = _dayKey(new Date())
    onFilterTextChanged: currentIndex = filterText !== "" && count > 0 ? 0 : -1
    onCountChanged: if (currentIndex >= count) currentIndex = count - 1
    Keys.onPressed: event => handleKey(event)

    HistoryModel {
        id: filtered
        store: hv.store
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
        // Keeps clicks and wheel events from reaching what is underneath.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: hv.focusDefault()
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
                width: parent.width - clearButton.width - (closeButton.visible ? closeButton.width : 0) - 16
                text: hv.title
                color: Style.text
                font.pixelSize: Style.fontSize + 3
                font.bold: true
                font.family: Style.fontFamily
                elide: Text.ElideRight
            }
            Button {
                id: clearButton
                objectName: "historyClear"
                anchors.right: closeButton.visible ? closeButton.left : parent.right
                anchors.rightMargin: closeButton.visible ? 8 : 0
                anchors.verticalCenter: parent.verticalCenter
                text: "Clear history…"
                danger: true
                enabled: hv.store !== null && hv.store.count > 0
                onClicked: hv.askClear(!hv.clearing)
            }
            IconButton {
                id: closeButton
                objectName: "historyClose"
                visible: hv.closable
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "×"
                onClicked: hv.closeRequested()
            }
        }

        // "Clear history…" choices.
        Rectangle {
            visible: hv._clearing
            width: parent.width
            height: visible ? clearRow.implicitHeight + 16 : 0
            radius: Style.radius
            color: Style.background
            border.color: Style.danger
            Row {
                id: clearRow
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                spacing: 6
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Remove the history of:"
                    color: Style.text
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                    rightPadding: 4
                }
                Button { objectName: "historyClearHour"; text: "Last hour"; onClicked: hv.clearHistory("hour") }
                Button { objectName: "historyClearToday"; text: "Today"; onClicked: hv.clearHistory("today") }
                Button { objectName: "historyClearAll"; text: "Everything"; primary: true; onClicked: hv.clearHistory("all") }
                Button {
                    objectName: "historyClearCancel"
                    text: "Cancel"
                    onClicked: { hv.askClear(false); hv.focusDefault() }
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
                objectName: "historySearch"
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
                Keys.onPressed: event => hv.handleKey(event)
                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: search.text === ""
                    text: "Search history"
                    color: Style.textDim
                    font: search.font
                    elide: Text.ElideRight
                }
            }
        }

        Text {
            objectName: "historyStatus"
            width: parent.width
            visible: text !== ""
            text: hv.store && !hv.store.enabled ? "History is turned off."
                : hv.store && !hv.store.recording ? "Private browsing: new visits are not recorded."
                    + (hv._status ? " " + hv._status : "")
                : hv._status
            color: Style.textDim
            elide: Text.ElideRight
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
    }

    ListView {
        id: list
        objectName: "historyList"
        // No cache buffer: buffered rows are created asynchronously, and a
        // model reset (history cleared or reloaded) while one is pending
        // makes Qt warn "DelegateModel::cancel: index out range".
        cacheBuffer: 0
        anchors.top: header.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        clip: true
        currentIndex: -1
        boundsBehavior: Flickable.StopAtBounds
        highlightFollowsCurrentItem: false
        model: filtered
        section.property: "day"
        section.delegate: Text {
            required property string section
            width: ListView.view.width
            topPadding: 12
            bottomPadding: 4
            leftPadding: 8
            text: hv.dayLabel(section)
            color: Style.textDim
            font.pixelSize: Style.fontSize - 1
            font.bold: true
            font.family: Style.fontFamily
        }

        Text {
            objectName: "historyEmpty"
            anchors.centerIn: parent
            visible: list.count === 0
            width: parent.width - 32
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: !hv.store ? "No history store."
                : hv.filterText !== "" ? "No history matches “" + hv.filterText + "”."
                : "No browsing history yet."
            color: Style.textDim
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }

        delegate: Rectangle {
            id: row
            required property int index
            required property string url
            required property string title
            required property string icon
            required property int visitCount
            required property double lastVisit

            width: ListView.view.width
            height: 40
            radius: Style.radius
            color: ListView.isCurrentItem ? Style.surfaceActive
                 : rowMouse.containsMouse ? Style.surfaceHover : "transparent"

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    hv.currentIndex = row.index
                    hv.open(row.index, mouse.button === Qt.MiddleButton
                            || (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) !== 0)
                }
            }

            Text {
                id: time
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 44
                text: Qt.formatTime(new Date(row.lastVisit), "hh:mm")
                color: Style.textDim
                font.pixelSize: Style.fontSize - 1
                font.family: Style.fontFamily
            }
            Item {
                id: iconBox
                anchors.left: time.right
                anchors.verticalCenter: parent.verticalCenter
                width: 16; height: 16
                Image {
                    id: favicon
                    anchors.fill: parent
                    sourceSize: Qt.size(32, 32)
                    asynchronous: true
                    source: row.icon
                    visible: status === Image.Ready
                }
                Text {
                    anchors.centerIn: parent
                    visible: !favicon.visible
                    text: "◷"
                    color: Style.textDim
                    font.pixelSize: Style.fontSize
                }
            }
            Column {
                anchors.left: iconBox.right
                anchors.leftMargin: 10
                anchors.right: removeButton.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    width: parent.width
                    text: row.title || hv._display(row.url)
                    color: Style.text
                    elide: Text.ElideRight
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                Text {
                    width: parent.width
                    text: hv._display(row.url) + (row.visitCount > 1 ? "  ·  " + row.visitCount + " visits" : "")
                    color: Style.textDim
                    elide: Text.ElideMiddle
                    font.pixelSize: Style.fontSize - 2
                    font.family: Style.fontFamily
                }
            }
            IconButton {
                id: removeButton
                objectName: "historyRemove"
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: "×"
                textColor: rowMouse.containsMouse || row.ListView.isCurrentItem ? Style.text : Style.textDim
                onClicked: hv.remove(row.index)
            }
        }
    }
}
