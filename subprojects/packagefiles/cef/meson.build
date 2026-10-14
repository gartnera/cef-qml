# Meson overlay for a CEF binary distribution (cef-builds.spotifycdn.com).
#
# Builds libcef_dll_wrapper (the C++ -> C API glue every CEF C++ client must
# link) and exposes libcef.so plus the runtime files that have to ship next to
# it.

project('cef', 'cpp',
  version: '154.0.34',
  default_options: ['cpp_std=c++20', 'warning_level=0'],
)

cxx = meson.get_compiler('cpp')
root = meson.current_source_dir()

if host_machine.system() != 'linux'
  error('Only the Linux CEF distribution is supported')
endif

cef_inc = include_directories('.', is_system: true)
cef_defines = ['-D_FILE_OFFSET_BITS=64']

# Meson has no globbing; the wrapper is a few hundred generated files whose
# names change between CEF releases, so list them at configure time.
wrapper_list = run_command('find', root / 'libcef_dll', '-name', '*.cc',
  check: true).stdout().strip().split('\n')

# Not cxx.find_library(): Meson would bake the distribution's Release/ dir into
# the RPATH of everything linking libcef. Consumers set their own RPATH to the
# directory the runtime is staged/installed in.
if not cxx.has_function('cef_version_info', args: ['-L' + root / 'Release', '-lcef'])
  error('libcef.so not usable in ' + root / 'Release')
endif
libcef = declare_dependency(link_args: ['-L' + root / 'Release', '-lcef'])

cef_dll_wrapper = static_library('cef_dll_wrapper',
  files(wrapper_list),
  include_directories: cef_inc,
  cpp_args: cef_defines + [
    '-DWRAPPING_CEF_SHARED',
    '-fno-strict-aliasing',
    '-fvisibility=hidden',
    '-fvisibility-inlines-hidden',
    '-Wno-attributes',
    '-Wno-deprecated-declarations',
  ],
  pic: true,
)

cef_dep = declare_dependency(
  include_directories: cef_inc,
  compile_args: cef_defines,
  link_with: cef_dll_wrapper,
  dependencies: libcef,
)

# Files that must sit next to libcef.so at runtime.
cef_release_dir = root / 'Release'
cef_resources_dir = root / 'Resources'

cef_runtime_files = files(
  'Release/libcef.so',
  'Release/libvk_swiftshader.so',
  'Release/libvulkan.so.1',
  'Release/v8_context_snapshot.bin',
  'Release/vk_swiftshader_icd.json',
  'Resources/chrome_100_percent.pak',
  'Resources/chrome_200_percent.pak',
  'Resources/icudtl.dat',
  'Resources/resources.pak',
)
cef_locales_dir = root / 'Resources' / 'locales'
