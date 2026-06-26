# Hybrid File Manager (Vala + GTK4 + C++ + C)

A simple file manager built with a mixed stack:

- **Vala + GTK4** for the desktop UI
- **C++** for the core library (`core/file_core.cpp`)
- **C** for native utility (`human_size` formatting)

## Features

- Browse directories
- Go to parent folder (`Up`)
- Open any path from the path bar
- Double-click a directory to enter it
- Double-click a file to open it via `xdg-open`
- Copy/Cut/Paste workflow similar to classic file managers
- Rename selected file or folder
- Delete confirmation dialog before removing items
- Delete with simple undo support (items move to local undo stash)
- Search/filter in current folder, with optional recursive mode
- Real file icons from system theme
- Keyboard shortcuts: `Ctrl+C`, `Ctrl+X`, `Ctrl+V`, `Delete`, `F2`, `Ctrl+Z`
- Smart right-click context menu (native `PopoverMenu`): context-aware actions with icons, `Paste Into <folder>`, auto-disabled unavailable items, and a clean empty-space menu (`Paste Here`/`New Folder`/`Refresh`)
- `New Folder` auto-suffixes duplicates (for example: `New Folder (2)`)
- Busy progress indicator for copy/move operations
- Directory listing + file ops (`copy/move/delete/undo`) produced by C++ backend
- File size labels formatted by C helper

## Project Layout

- `src/main.vala` - GTK4 UI and glue code
- `core/file_core.cpp` - C++ core library for listing and file operations
- `core/file_core.h` - C ABI used by Vala
- `core/file_core.vapi` - Vala bindings for the core API
- `c_utils/human_size.c` - converts raw byte size to human-readable text
- `run.sh` - builds everything and starts the app

## Build Requirements

You need these tools/libraries installed:

- `vala`
- `meson`
- `ninja`
- `pkg-config`
- `gtk4` development files
- `g++` (with C++17 support)

## Run

```bash
cd filemanager/
./run.sh
```

`run.sh` will:
1. compile the Vala/C/C++ app with Meson,
2. run the file manager.
