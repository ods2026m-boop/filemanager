project('omanager', ['vala', 'c', 'cpp'], version: '0.1.0')

gtk_dep = dependency('gtk4')
glib_dep = dependency('glib-2.0')

cpp_args = ['-std=c++17']
core_inc = include_directories('core')

core_lib = static_library(
  'fm_core',
  ['core/file_core.cpp'],
  include_directories: core_inc,
  dependencies: [glib_dep],
  cpp_args: cpp_args,
  install: false
)

executable(
  'omanager',
  [
    'src/main.vala',
    'c_utils/human_size.c',
  ],
  include_directories: core_inc,
  dependencies: [gtk_dep],
  vala_args: [
    '--pkg', 'gio-2.0',
    '--vapidir', meson.current_source_dir() / 'core',
    '--pkg', 'file_core'
  ],
  link_with: [core_lib]
)

core_tests = executable(
  'file-core-tests',
  ['core/core_tests.cpp'],
  include_directories: core_inc,
  dependencies: [glib_dep],
  cpp_args: cpp_args,
  link_with: [core_lib],
  install: false
)

test('file-core-tests', core_tests)

bash = find_program('bash')
test(
  'filemanager-ui-smoke',
  bash,
  args: [
    '-c',
    'if command -v xvfb-run >/dev/null 2>&1; then FM_UI_SMOKE=1 xvfb-run -a ./omanager; elif [ -n "${DISPLAY:-}" ] && command -v xset >/dev/null 2>&1 && xset q >/dev/null 2>&1; then FM_UI_SMOKE=1 ./omanager; elif [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "/run/user/$(id -u)/${WAYLAND_DISPLAY}" ]; then FM_UI_SMOKE=1 ./omanager; else echo "No usable display available; skipping UI smoke"; fi'
  ],
  workdir: meson.current_build_dir()
)
