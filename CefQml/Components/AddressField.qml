import QtQuick
import CefQml

// URL/search field bound to a CefWebView. Shows the page URL while not being
// edited; Enter navigates (typed text that is not an address is searched).
// Escape restores the page URL; pressed again (or with nothing edited) it
// returns focus to the page. With `suggestions` (an AddressSuggestions, which
// sets itself here) keys go to the popup first.
Rectangle {
    id: field
    property CefWebView view
    // "%s" is replaced by the URL-encoded query.
    property string searchUrl: "https://duckduckgo.com/?q=%s"
    property alias text: input.text
    // URLs shown as an empty field (e.g. the new-tab page).
    property var isInternalUrl: url => false
    property alias input: input
    // AddressSuggestions handling keys and edits (set by AddressSuggestions).
    property var suggestions: null
    // Emitted after navigating; the default handler focuses the page.
    signal navigated(url url)

    implicitHeight: 28
    radius: Style.radius
    color: Style.surface
    border.color: input.activeFocus ? Style.accent : "transparent"
    border.width: 1

    function urlFor(text) {
        const u = Cef.urlFromUserInput(text)
        if (u.toString() !== "") return u
        return searchUrl.replace("%s", encodeURIComponent(text.trim()))
    }

    // Loads `target` (a url) in `view`, focuses the page and emits
    // navigated(). The same URL again reloads.
    function go(target) {
        if (!field.view) return
        const dec = u => { u = String(u); try { return decodeURIComponent(u) } catch (e) { return u } }
        if (dec(field.view.url) === dec(target)) field.view.reload()
        else field.view.url = target
        field.view.forceActiveFocus(Qt.OtherFocusReason)
        field.navigated(target)
    }

    function focusAndSelect() {
        input.forceActiveFocus(Qt.ShortcutFocusReason)
        input.selectAll()
    }

    function _display() {
        if (!field.view) return ""
        const u = field.view.url.toString()
        return field.isInternalUrl(u) ? "" : u
    }
    function _sync() {
        if (!input.activeFocus)
            input.text = field._display()
    }

    Connections {
        target: field.view
        function onUrlChanged() { field._sync() }
    }
    onViewChanged: _sync()

    TextInput {
        id: input
        objectName: "addressInput"
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        // While not editing, `pretty` below draws the URL with the host emphasized.
        color: activeFocus || pretty.text === "" ? Style.text : "transparent"
        selectionColor: Style.accent
        selectedTextColor: "white"
        selectByMouse: true
        font.pixelSize: Style.fontSize
        font.family: Style.fontFamily

        onActiveFocusChanged: {
            if (activeFocus) selectAll()
            else field._sync()
        }
        onAccepted: {
            if (!field.view || text.trim() === "") return
            field.go(field.urlFor(text))
        }
        Keys.onPressed: event => {
            if (field.suggestions && field.suggestions.handleKey(event)) {
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Escape) {
                const shown = field._display()
                if (text !== shown) {
                    text = shown
                    selectAll()
                } else if (field.view) {
                    field.view.forceActiveFocus(Qt.OtherFocusReason)
                }
                event.accepted = true
            }
        }

        Text {
            id: pretty
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: !input.activeFocus
            elide: Text.ElideRight
            textFormat: Text.StyledText
            font: input.font
            color: Style.textDim
            text: {
                const m = /^([a-z][a-z0-9+.-]*:\/\/)([^\/?#]*)(.*)$/i.exec(input.text)
                if (!m) return ""
                const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                const scheme = m[1] === "https://" ? "" : esc(m[1])
                return scheme + "<font color=\"" + Style.text + "\">" + esc(m[2]) + "</font>" + esc(m[3])
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text === "" && !input.activeFocus
            text: "Search or enter address"
            color: Style.textDim
            font: input.font
        }
    }
}
