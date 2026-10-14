// JsonStore: load/default/save/autosave/reload, corrupt files, path
// resolution under Cef.dataDir. Uses the per-run profile (CEF_QML_CACHE_DIR).
// Needs QML_XHR_ALLOW_FILE_READ/WRITE=1 (set by tests/run.sh).
import QtQuick
import QtTest
import CefQml

Item {
    id: root

    function read(path) {
        const xhr = new XMLHttpRequest()
        let done = false
        xhr.onreadystatechange = () => { if (xhr.readyState === XMLHttpRequest.DONE) done = true }
        xhr.open("GET", "file://" + path)
        xhr.send()
        test.tryVerify(() => done, 5000, "reading " + path)
        return xhr.status === 200 || xhr.status === 0 ? xhr.responseText : null
    }
    function write(path, text) {
        const xhr = new XMLHttpRequest()
        xhr.open("PUT", "file://" + path)
        xhr.send(text)
        test.tryVerify(() => xhr.readyState === XMLHttpRequest.DONE, 5000, "writing " + path)
    }

    Component {
        id: storeComponent
        JsonStore { }
    }

    TestCase {
        id: test
        name: "JsonStore"

        function test_dirs() {
            const profile = Cef.environment("CEF_QML_CACHE_DIR")
            verify(profile.length > 0)
            compare(Cef.profileDir, profile)
            compare(Cef.dataDir, profile + "/cefqml")
        }

        function test_default_and_save() {
            const s = storeComponent.createObject(root, { path: "t/one.json", data: { a: 1 } })
            verify(s.loaded)
            compare(s.filePath, Cef.dataDir + "/t/one.json")
            compare(s.data.a, 1)
            verify(!s.dirty, "a default is not a change")
            compare(root.read(s.filePath), "", "missing file is not created")
            s.set("b", "two")
            verify(s.dirty)
            verify(s.save())
            verify(!s.dirty)
            const json = JSON.parse(root.read(s.filePath))
            compare(json.a, 1)
            compare(json.b, "two")
            s.destroy()
        }

        function test_load_existing() {
            const path = Cef.dataDir + "/t/two.json"
            const s0 = storeComponent.createObject(root, { path: path, data: { x: [1, 2, { y: true }] } })
            s0.set("x", [1, 2, { y: true }])
            s0.set("n", null)
            verify(s0.save())
            s0.destroy()
            const s = storeComponent.createObject(root, { path: "file://" + path, data: { other: 1 } })
            compare(s.filePath, path)
            compare(s.data.other, undefined, "file content replaces the default")
            compare(s.data.x.length, 3)
            compare(s.data.x[2].y, true)
            compare(s.get("n", "def"), null)
            compare(s.get("missing", "def"), "def")
            compare(s.keys().sort(), ["n", "x"])
            s.remove("n")
            compare(s.keys(), ["x"])
            s.destroy()
        }

        function test_autosave_debounce() {
            const s = storeComponent.createObject(root, { path: "t/auto.json", saveDelay: 100 })
            const spy = Qt.createQmlObject("import QtTest; SignalSpy { signalName: 'saved' }", root)
            spy.target = s
            s.data = { v: 1 }
            s.set("v", 2)
            s.set("v", 3)
            verify(s.dirty)
            compare(spy.count, 0)
            tryCompare(spy, "count", 1, 3000)
            wait(250)
            compare(spy.count, 1, "several changes, one write")
            compare(JSON.parse(root.read(s.filePath)).v, 3)
            s.autoSave = false
            s.set("v", 4)
            wait(250)
            compare(JSON.parse(root.read(s.filePath)).v, 3, "no autosave")
            s.destroy()  // deferred; flushes pending changes
            tryVerify(() => JSON.parse(root.read(Cef.dataDir + "/t/auto.json")).v === 4, 3000,
                      "flushed on destruction")
            spy.destroy()
        }

        function test_reload_discards_and_rereads() {
            const s = storeComponent.createObject(root, { path: "t/reload.json", autoSave: false })
            s.data = { k: "saved" }
            verify(s.save())
            s.set("k", "unsaved")
            root.write(s.filePath, '{"k": "external"}')
            verify(s.reload())
            compare(s.data.k, "external")
            verify(!s.dirty)
            s.destroy()
        }

        function test_array_data() {
            const s = storeComponent.createObject(root, { path: "t/array.json", data: [] })
            s.data = ["a", { b: 2 }]
            verify(s.save())
            s.destroy()
            const t = storeComponent.createObject(root, { path: "t/array.json" })
            compare(t.data.length, 2)
            compare(t.data[1].b, 2)
            t.destroy()
        }

        function test_corrupt_file() {
            const path = Cef.dataDir + "/t/corrupt.json"
            root.write(path, '{"broken": ')
            const s = storeComponent.createObject(root, { path: path, data: { fallback: true } })
            verify(s.loaded)
            verify(s.errorString.indexOf("not valid JSON") >= 0, s.errorString)
            compare(s.data.fallback, true, "keeps the default")
            compare(root.read(path + ".corrupt"), '{"broken": ', "kept for inspection")
            s.set("fixed", 1)
            verify(s.save())
            compare(s.errorString, "")
            compare(JSON.parse(root.read(path)).fixed, 1)
            s.destroy()
        }

        function test_path_change() {
            const s = storeComponent.createObject(root, { path: "t/p1.json", autoSave: false, data: {} })
            s.set("which", 1)
            s.path = "t/p2.json"   // flushes p1, then loads p2 (missing: keeps data)
            compare(JSON.parse(root.read(Cef.dataDir + "/t/p1.json")).which, 1)
            verify(!s.dirty)
            s.set("which", 2)
            verify(s.save())
            compare(JSON.parse(root.read(Cef.dataDir + "/t/p2.json")).which, 2)
            s.path = "t/p1.json"
            compare(s.data.which, 1)
            s.destroy()
        }

        function test_in_memory() {
            const s = storeComponent.createObject(root, { data: { a: 1 } })
            compare(s.filePath, "")
            verify(s.loaded)
            s.set("a", 2)
            verify(s.save())
            compare(s.data.a, 2)
            s.destroy()
        }
    }
}
