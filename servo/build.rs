fn main() {
    // A SONAME, so whatever links the library records "libservo_qml.so"
    // rather than the path it was linked from.
    println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,libservo_qml.so");
}
