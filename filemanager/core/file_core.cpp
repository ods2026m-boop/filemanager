#include "file_core.h"
#include <glib.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

namespace {

enum class UndoKind {
    None,
    Move,
    DeleteStash,
};

struct Entry {
    int is_dir;
    std::string name;
    std::uintmax_t size;
};

struct FmCoreImpl {
    struct UndoEntry {
        UndoKind kind = UndoKind::None;
        std::string from_path;
        std::string to_path;
        std::string meta_path;
    };
    std::vector<UndoEntry> undo_stack;
    std::vector<UndoEntry> redo_stack;
    std::atomic<bool> cancel_requested{false};
};

std::string to_lower_ascii(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return text;
}

std::string escape_tabs_and_newlines(const std::string& text) {
    std::string out;
    out.reserve(text.size());

    for (char ch : text) {
        if (ch == '\t') {
            out += "\\t";
        } else if (ch == '\n') {
            out += "\\n";
        } else {
            out += ch;
        }
    }

    return out;
}

char* dup_string(const std::string& text) {
    return g_strdup(text.c_str());
}

void set_error(char** error_message, const std::string& message) {
    if (error_message == nullptr) {
        return;
    }

    *error_message = dup_string(message);
}

void push_undo_entry(
    FmCoreImpl& impl,
    UndoKind kind,
    const std::string& from_path,
    const std::string& to_path,
    const std::string& meta_path
) {
    constexpr std::size_t kMaxUndoEntries = 256;
    if (impl.undo_stack.size() >= kMaxUndoEntries) {
        impl.undo_stack.erase(impl.undo_stack.begin());
    }
    impl.undo_stack.push_back({kind, from_path, to_path, meta_path});
}

void cleanup_redo_entry(const FmCoreImpl::UndoEntry& entry) {
    if (entry.kind != UndoKind::DeleteStash || entry.meta_path.empty()) {
        return;
    }

    std::error_code ec;
    auto trash_path = std::filesystem::path(entry.to_path);
    if (std::filesystem::exists(trash_path, ec)) {
        return;
    }

    std::filesystem::remove(std::filesystem::path(entry.meta_path), ec);
}

void clear_redo_stack(FmCoreImpl& impl) {
    for (const auto& entry : impl.redo_stack) {
        cleanup_redo_entry(entry);
    }
    impl.redo_stack.clear();
}

void push_redo_entry(
    FmCoreImpl& impl,
    UndoKind kind,
    const std::string& from_path,
    const std::string& to_path,
    const std::string& meta_path
) {
    constexpr std::size_t kMaxUndoEntries = 256;
    if (impl.redo_stack.size() >= kMaxUndoEntries) {
        cleanup_redo_entry(impl.redo_stack.front());
        impl.redo_stack.erase(impl.redo_stack.begin());
    }
    impl.redo_stack.push_back({kind, from_path, to_path, meta_path});
}

bool path_is_inside(const std::filesystem::path& candidate, const std::filesystem::path& base) {
    std::error_code ec;
    auto normalized_candidate = std::filesystem::weakly_canonical(candidate, ec);
    if (ec) {
        return false;
    }

    auto normalized_base = std::filesystem::weakly_canonical(base, ec);
    if (ec) {
        return false;
    }

    auto candidate_it = normalized_candidate.begin();
    auto base_it = normalized_base.begin();

    for (; base_it != normalized_base.end(); ++base_it, ++candidate_it) {
        if (candidate_it == normalized_candidate.end() || *candidate_it != *base_it) {
            return false;
        }
    }

    return true;
}

std::filesystem::path unique_copy_destination(const std::filesystem::path& destination_dir, const std::string& basename) {
    auto candidate = destination_dir / basename;
    if (!std::filesystem::exists(candidate)) {
        return candidate;
    }

    auto dot = basename.find_last_of('.');
    std::string stem = basename;
    std::string ext;

    if (dot != std::string::npos && dot > 0) {
        stem = basename.substr(0, dot);
        ext = basename.substr(dot);
    }

    for (int i = 2; i < 10000; ++i) {
        auto attempt_name = stem + " (copy " + std::to_string(i) + ")" + ext;
        candidate = destination_dir / attempt_name;
        if (!std::filesystem::exists(candidate)) {
            return candidate;
        }
    }

    return destination_dir / (basename + "-copy");
}

std::error_code cancelled_error() {
    return std::make_error_code(std::errc::operation_canceled);
}

void copy_recursively(
    std::atomic<bool>* cancel_requested,
    const std::filesystem::path& source,
    const std::filesystem::path& destination,
    std::error_code& ec
) {
    if (cancel_requested != nullptr && cancel_requested->load()) {
        ec = cancelled_error();
        return;
    }

    if (std::filesystem::is_directory(source, ec)) {
        if (ec) {
            return;
        }

        std::filesystem::create_directories(destination, ec);
        if (ec) {
            return;
        }

        for (const auto& entry : std::filesystem::directory_iterator(source, ec)) {
            if (ec) {
                return;
            }
            if (cancel_requested != nullptr && cancel_requested->load()) {
                ec = cancelled_error();
                return;
            }

            auto child_source = entry.path();
            auto child_destination = destination / child_source.filename();
            copy_recursively(cancel_requested, child_source, child_destination, ec);
            if (ec) {
                return;
            }
        }
        return;
    }

    if (cancel_requested != nullptr && cancel_requested->load()) {
        ec = cancelled_error();
        return;
    }
    std::filesystem::copy_file(source, destination, std::filesystem::copy_options::overwrite_existing, ec);
}

std::filesystem::path trash_base_dir() {
    const char* home = std::getenv("HOME");
    std::filesystem::path base = (home == nullptr) ? "." : home;
    return base / ".local" / "share" / "Trash";
}

std::string now_local_iso8601() {
    GDateTime* now = g_date_time_new_now_local();
    gchar* text = g_date_time_format(now, "%Y-%m-%dT%H:%M:%S");
    std::string out = (text != nullptr) ? text : "";
    g_free(text);
    g_date_time_unref(now);
    return out;
}

std::string escape_trash_path(const std::string& path) {
    gchar* escaped = g_uri_escape_string(path.c_str(), G_URI_RESERVED_CHARS_ALLOWED_IN_PATH, TRUE);
    std::string out = (escaped != nullptr) ? escaped : path;
    g_free(escaped);
    return out;
}

std::string unique_trash_name(
    const std::filesystem::path& trash_files_dir,
    const std::filesystem::path& trash_info_dir,
    const std::string& basename
) {
    auto file_candidate = trash_files_dir / basename;
    auto info_candidate = trash_info_dir / (basename + ".trashinfo");
    if (!std::filesystem::exists(file_candidate) && !std::filesystem::exists(info_candidate)) {
        return basename;
    }

    for (int i = 2; i < 10000; ++i) {
        auto suffix = "." + std::to_string(i);
        auto candidate_name = basename + suffix;
        file_candidate = trash_files_dir / candidate_name;
        info_candidate = trash_info_dir / (candidate_name + ".trashinfo");
        if (!std::filesystem::exists(file_candidate) && !std::filesystem::exists(info_candidate)) {
            return candidate_name;
        }
    }

    return basename + ".recycle";
}

bool write_trash_info(
    const std::filesystem::path& info_path,
    const std::string& original_path,
    std::error_code& ec
) {
    std::ofstream out(info_path);
    if (!out.is_open()) {
        ec = std::make_error_code(std::errc::io_error);
        return false;
    }

    out << "[Trash Info]\n";
    out << "Path=" << escape_trash_path(original_path) << "\n";
    out << "DeletionDate=" << now_local_iso8601() << "\n";
    out.close();
    if (!out) {
        ec = std::make_error_code(std::errc::io_error);
        return false;
    }

    ec.clear();
    return true;
}

}  // namespace

struct FmCore {
    FmCoreImpl impl;
};

FmCore* fm_core_new(void) {
    return new FmCore();
}

void fm_core_free(FmCore* core) {
    delete core;
}

char* fm_core_list_dir(FmCore* core, const char* path, char** error_message) {
    (void) core;

    if (error_message != nullptr) {
        *error_message = nullptr;
    }

    if (path == nullptr) {
        set_error(error_message, "Path is null.");
        return nullptr;
    }

    std::filesystem::path dir(path);
    std::error_code ec;
    if (!std::filesystem::exists(dir, ec)) {
        set_error(error_message, "Path not found.");
        return nullptr;
    }

    if (!std::filesystem::is_directory(dir, ec)) {
        set_error(error_message, "Not a directory.");
        return nullptr;
    }

    std::vector<Entry> entries;
    for (const auto& item : std::filesystem::directory_iterator(dir, ec)) {
        if (ec) {
            break;
        }

        std::error_code meta_ec;
        const bool is_dir = item.is_directory(meta_ec);
        if (meta_ec) {
            continue;
        }

        const bool is_file = item.is_regular_file(meta_ec);
        if (meta_ec) {
            continue;
        }

        std::uintmax_t size = 0;
        if (is_file) {
            size = item.file_size(meta_ec);
            if (meta_ec) {
                size = 0;
            }
        }

        auto name = item.path().filename().string();
        entries.push_back({is_dir ? 1 : 0, escape_tabs_and_newlines(name), size});
    }

    std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
        if (a.is_dir != b.is_dir) {
            return a.is_dir > b.is_dir;
        }
        return to_lower_ascii(a.name) < to_lower_ascii(b.name);
    });

    std::string out;
    for (const auto& entry : entries) {
        out += entry.name + "\t" + std::to_string(entry.is_dir) + "\t" + std::to_string(entry.size) + "\n";
    }

    return dup_string(out);
}

int fm_core_copy_or_move(
    FmCore* core,
    const char* source_path,
    const char* destination_dir_path,
    int is_cut,
    char** out_final_path,
    char** error_message
) {
    if (out_final_path != nullptr) {
        *out_final_path = nullptr;
    }
    if (error_message != nullptr) {
        *error_message = nullptr;
    }

    if (core == nullptr || source_path == nullptr || destination_dir_path == nullptr) {
        set_error(error_message, "Invalid arguments.");
        return 0;
    }

    auto source = std::filesystem::path(source_path);
    auto destination_dir = std::filesystem::path(destination_dir_path);
    std::error_code ec;

    if (!std::filesystem::exists(source, ec)) {
        set_error(error_message, "Source path does not exist.");
        return 0;
    }

    if (!std::filesystem::exists(destination_dir, ec) || !std::filesystem::is_directory(destination_dir, ec)) {
        set_error(error_message, "Destination directory does not exist.");
        return 0;
    }

    auto basename = source.filename().string();
    auto destination = destination_dir / basename;

    if (is_cut && source == destination) {
        set_error(error_message, "Source and destination are the same.");
        return 0;
    }

    if (std::filesystem::is_directory(source, ec) && path_is_inside(destination_dir, source)) {
        set_error(error_message, "Cannot move/copy a folder into itself.");
        return 0;
    }

    if (!is_cut && std::filesystem::exists(destination, ec)) {
        destination = unique_copy_destination(destination_dir, basename);
    }

    if (is_cut) {
        if (core->impl.cancel_requested.load()) {
            set_error(error_message, "Operation cancelled.");
            return 0;
        }

        std::filesystem::rename(source, destination, ec);
        if (ec) {
            ec.clear();
            copy_recursively(&core->impl.cancel_requested, source, destination, ec);
            if (ec) {
                if (ec == cancelled_error()) {
                    std::error_code cleanup_ec;
                    std::filesystem::remove_all(destination, cleanup_ec);
                    set_error(error_message, "Operation cancelled.");
                    return 0;
                }
                set_error(error_message, "Move failed: " + ec.message());
                return 0;
            }

            std::filesystem::remove_all(source, ec);
            if (ec) {
                set_error(error_message, "Move cleanup failed: " + ec.message());
                return 0;
            }
        }

        clear_redo_stack(core->impl);
        push_undo_entry(core->impl, UndoKind::Move, destination.string(), source.string(), "");
    } else {
        copy_recursively(&core->impl.cancel_requested, source, destination, ec);
        if (ec) {
            if (ec == cancelled_error()) {
                std::error_code cleanup_ec;
                std::filesystem::remove_all(destination, cleanup_ec);
                set_error(error_message, "Operation cancelled.");
                return 0;
            }
            set_error(error_message, "Copy failed: " + ec.message());
            return 0;
        }
        clear_redo_stack(core->impl);
    }

    if (out_final_path != nullptr) {
        *out_final_path = dup_string(destination.string());
    }

    return 1;
}

int fm_core_delete_with_undo(FmCore* core, const char* source_path, char** error_message) {
    if (error_message != nullptr) {
        *error_message = nullptr;
    }

    if (core == nullptr || source_path == nullptr) {
        set_error(error_message, "Invalid arguments.");
        return 0;
    }
    if (core->impl.cancel_requested.load()) {
        set_error(error_message, "Operation cancelled.");
        return 0;
    }

    auto source = std::filesystem::path(source_path);
    std::error_code ec;

    if (!std::filesystem::exists(source, ec)) {
        set_error(error_message, "Source path does not exist.");
        return 0;
    }

    auto trash_base = trash_base_dir();
    auto trash_files_dir = trash_base / "files";
    auto trash_info_dir = trash_base / "info";
    std::filesystem::create_directories(trash_files_dir, ec);
    if (ec) {
        set_error(error_message, "Failed to prepare trash directory: " + ec.message());
        return 0;
    }
    std::filesystem::create_directories(trash_info_dir, ec);
    if (ec) {
        set_error(error_message, "Failed to prepare trash metadata: " + ec.message());
        return 0;
    }

    auto trash_name = unique_trash_name(trash_files_dir, trash_info_dir, source.filename().string());
    auto trash_file_path = trash_files_dir / trash_name;
    auto trash_info_path = trash_info_dir / (trash_name + ".trashinfo");

    std::filesystem::rename(source, trash_file_path, ec);
    if (ec) {
        set_error(error_message, "Delete failed: " + ec.message());
        return 0;
    }

    if (!write_trash_info(trash_info_path, source.string(), ec)) {
        std::error_code rollback_ec;
        std::filesystem::rename(trash_file_path, source, rollback_ec);
        set_error(error_message, "Delete metadata write failed: " + ec.message());
        return 0;
    }

    clear_redo_stack(core->impl);
    push_undo_entry(core->impl, UndoKind::DeleteStash, trash_file_path.string(), source.string(), trash_info_path.string());

    return 1;
}

int fm_core_undo(FmCore* core, char** error_message) {
    if (error_message != nullptr) {
        *error_message = nullptr;
    }

    if (core == nullptr) {
        set_error(error_message, "Invalid core handle.");
        return 0;
    }

    if (core->impl.undo_stack.empty()) {
        set_error(error_message, "Nothing to undo.");
        return 0;
    }

    auto undo = core->impl.undo_stack.back();
    core->impl.undo_stack.pop_back();

    auto from = std::filesystem::path(undo.from_path);
    auto to = std::filesystem::path(undo.to_path);

    std::error_code ec;
    if (undo.kind == UndoKind::DeleteStash && !undo.meta_path.empty()) {
        auto info_path = std::filesystem::path(undo.meta_path);
        if (!std::filesystem::exists(info_path, ec)) {
            auto original_path = undo.to_path;
            if (!write_trash_info(info_path, original_path, ec)) {
                set_error(error_message, "Undo metadata repair failed: " + ec.message());
                return 0;
            }
        }
    }

    if (!std::filesystem::exists(from, ec)) {
        set_error(error_message, "Undo source no longer exists.");
        return 0;
    }

    if (std::filesystem::exists(to, ec)) {
        set_error(error_message, "Undo destination already exists.");
        return 0;
    }

    std::filesystem::rename(from, to, ec);
    if (ec) {
        set_error(error_message, "Undo failed: " + ec.message());
        return 0;
    }

    push_redo_entry(core->impl, undo.kind, undo.to_path, undo.from_path, undo.meta_path);

    return 1;
}

int fm_core_can_undo(FmCore* core) {
    if (core == nullptr) {
        return 0;
    }

    return core->impl.undo_stack.empty() ? 0 : 1;
}

int fm_core_redo(FmCore* core, char** error_message) {
    if (error_message != nullptr) {
        *error_message = nullptr;
    }

    if (core == nullptr) {
        set_error(error_message, "Invalid core handle.");
        return 0;
    }

    if (core->impl.redo_stack.empty()) {
        set_error(error_message, "Nothing to redo.");
        return 0;
    }

    auto redo = core->impl.redo_stack.back();
    core->impl.redo_stack.pop_back();

    auto from = std::filesystem::path(redo.from_path);
    auto to = std::filesystem::path(redo.to_path);
    std::error_code ec;

    if (redo.kind == UndoKind::DeleteStash && !redo.meta_path.empty()) {
        auto info_path = std::filesystem::path(redo.meta_path);
        if (!std::filesystem::exists(info_path, ec)) {
            if (!write_trash_info(info_path, redo.from_path, ec)) {
                set_error(error_message, "Redo metadata repair failed: " + ec.message());
                return 0;
            }
        }
    }

    if (!std::filesystem::exists(from, ec)) {
        set_error(error_message, "Redo source no longer exists.");
        return 0;
    }

    if (std::filesystem::exists(to, ec)) {
        set_error(error_message, "Redo destination already exists.");
        return 0;
    }

    std::filesystem::rename(from, to, ec);
    if (ec) {
        set_error(error_message, "Redo failed: " + ec.message());
        return 0;
    }

    push_undo_entry(core->impl, redo.kind, redo.to_path, redo.from_path, redo.meta_path);
    return 1;
}

int fm_core_can_redo(FmCore* core) {
    if (core == nullptr) {
        return 0;
    }

    return core->impl.redo_stack.empty() ? 0 : 1;
}

void fm_core_request_cancel(FmCore* core) {
    if (core == nullptr) {
        return;
    }
    core->impl.cancel_requested.store(true);
}

void fm_core_reset_cancel(FmCore* core) {
    if (core == nullptr) {
        return;
    }
    core->impl.cancel_requested.store(false);
}

void fm_string_free(char* value) {
    g_free(value);
}
