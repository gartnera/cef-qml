import QtQuick
import QtQuick.Dialogs
import CefQml

// Answers CefFileDialogRequests with Qt's native file dialogs (portal on
// Wayland). Loaded on demand by Browser so QtQuick.Dialogs stays optional.
Item {
    id: handler
    property CefFileDialogRequest request: null

    function open(req) {
        if (request) request.reject()
        request = req
        if (req.mode === CefFileDialogRequest.OpenFolder) {
            folderDialog.title = req.title || "Select folder"
            folderDialog.open()
            return
        }
        fileDialog.title = req.title || (req.mode === CefFileDialogRequest.Save ? "Save file" : "Open file")
        fileDialog.fileMode = req.mode === CefFileDialogRequest.Save ? FileDialog.SaveFile
            : req.mode === CefFileDialogRequest.OpenMultiple ? FileDialog.OpenFiles : FileDialog.OpenFile
        fileDialog.nameFilters = req.nameFilters
        fileDialog.open()
    }

    FileDialog {
        id: fileDialog
        onAccepted: {
            const files = fileMode === FileDialog.OpenFiles ? selectedFiles : [selectedFile]
            if (handler.request) handler.request.accept(files.map(f => f.toString()))
            handler.request = null
        }
        onRejected: { if (handler.request) handler.request.reject(); handler.request = null }
    }
    FolderDialog {
        id: folderDialog
        onAccepted: { if (handler.request) handler.request.accept([selectedFolder.toString()]); handler.request = null }
        onRejected: { if (handler.request) handler.request.reject(); handler.request = null }
    }
}
