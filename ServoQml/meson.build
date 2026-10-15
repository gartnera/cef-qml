# ServoQml: ServoWebView, a web view backed by Servo (-Dservo=enabled).
# libservo_qml.so (servo/, Rust) is built with cargo, or taken prebuilt
# from -Dservo_lib=<path>.
servo_lib_opt = get_option('servo_lib')
if servo_lib_opt != ''
  servo_lib = custom_target('servo-lib',
    input: servo_lib_opt,
    output: 'libservo_qml.so',
    command: ['cp', '-f', '@INPUT@', '@OUTPUT@'],
    install: true,
    install_dir: runtime_dir,
  )
else
  find_program('cargo')
  servo_lib = custom_target('servo-lib',
    output: 'libservo_qml.so',
    command: [
      find_program('../scripts/cargo-build.sh'),
      meson.project_source_root() / 'servo' / 'Cargo.toml',
      meson.project_build_root() / 'servo-target',
      '@OUTPUT@',
    ],
    # cargo decides what to rebuild; a no-op run takes a second.
    build_always_stale: true,
    console: true,
    install: true,
    install_dir: runtime_dir,
  )
endif

servo_moc = qt6.compile_moc(
  headers: ['../src/servo/servowebview.h', '../src/servo/servoplugin.h'],
  include_directories: include_directories('../servo/include'),
  dependencies: qt_dep,
)

servo_plugin = shared_module('servoqmlplugin',
  '../src/servo/servowebview.cpp',
  '../src/servo/servoplugin.cpp',
  servo_moc,
  include_directories: include_directories('../servo/include', '../src/servo'),
  dependencies: qt_dep,
  link_with: servo_lib,
  cpp_args: ['-DQT_NO_KEYWORDS'],
  build_rpath: '$ORIGIN',
  install_rpath: plugin_install_rpath,
  install: true,
  install_dir: qml_dir / 'ServoQml',
)

servo_qmldir = fs.copyfile('qmldir', install: true, install_dir: qml_dir / 'ServoQml')
