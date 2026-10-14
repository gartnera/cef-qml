// Session files in use by SessionStores of this engine (internal), so that
// two stores do not overwrite each other's file.
.pragma library

var owners = {}

// Returns true if `owner` may write `path` (claiming it if it is free).
function claim(path, owner) {
    if (owners[path] && owners[path] !== owner) return false
    owners[path] = owner
    return true
}

function release(path, owner) {
    if (owners[path] === owner) delete owners[path]
}
