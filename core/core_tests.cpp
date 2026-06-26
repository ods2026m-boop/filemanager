#include "file_core.h"

#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <unistd.h>

namespace fs = std::filesystem;

namespace {

struct TempDir {
    fs::path path;

    TempDir() {
        char tmpl[] = "/tmp/fm-core-test-XXXXXX";
        char* created = mkdtemp(tmpl);
        assert(created != nullptr);
        path = created;
    }

    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

std::vector<std::string> split_lines(const std::string& text) {
    std::vector<std::string> lines;
    std::string cur;
    for (char ch : text) {
        if (ch == '\n') {
            if (!cur.empty()) {
                lines.push_back(cur);
            }
            cur.clear();
        } else {
            cur.push_back(ch);
        }
    }
    if (!cur.empty()) {
        lines.push_back(cur);
    }
    return lines;
}

void write_text(const fs::path& path, const std::string& text) {
    std::ofstream out(path);
    assert(out.is_open());
    out << text;
    out.close();
    assert(out.good());
}

void test_list_dir_and_sorting(FmCore* core, const fs::path& root) {
    fs::create_directories(root);
    fs::create_directory(root / "Zeta");
    write_text(root / "alpha.txt", "x");

    char* err = nullptr;
    char* out = fm_core_list_dir(core, root.c_str(), &err);
    assert(out != nullptr);
    assert(err == nullptr);

    std::string text(out);
    fm_string_free(out);

    auto lines = split_lines(text);
    assert(lines.size() == 2);
    // Directory entries should come before files.
    assert(lines[0].find("Zeta\t1\t0") == 0);
    assert(lines[1].find("alpha.txt\t0\t1") == 0);
}

void test_copy_unique_name(FmCore* core, const fs::path& root) {
    fs::create_directories(root / "src");
    fs::create_directories(root / "dst");
    write_text(root / "src" / "note.txt", "hello");
    write_text(root / "dst" / "note.txt", "existing");

    char* err = nullptr;
    char* final_path = nullptr;
    int ok = fm_core_copy_or_move(
        core,
        (root / "src" / "note.txt").c_str(),
        (root / "dst").c_str(),
        0,
        &final_path,
        &err
    );
    assert(ok == 1);
    assert(err == nullptr);
    assert(final_path != nullptr);

    std::string copied(final_path);
    fm_string_free(final_path);
    assert(copied.find("note (copy 2).txt") != std::string::npos);
    assert(fs::exists(copied));
}

void test_trash_delete_and_undo(FmCore* core, const fs::path& home_root) {
    assert(setenv("HOME", home_root.c_str(), 1) == 0);

    fs::create_directories(home_root / "work");
    fs::path original = home_root / "work" / "report.txt";
    write_text(original, "data");

    char* err = nullptr;
    int ok = fm_core_delete_with_undo(core, original.c_str(), &err);
    assert(ok == 1);
    assert(err == nullptr);
    assert(!fs::exists(original));

    fs::path trash_info_dir = home_root / ".local" / "share" / "Trash" / "info";
    bool has_info = false;
    for (const auto& entry : fs::directory_iterator(trash_info_dir)) {
        if (entry.path().extension() == ".trashinfo") {
            has_info = true;
            break;
        }
    }
    assert(has_info);

    ok = fm_core_undo(core, &err);
    assert(ok == 1);
    assert(err == nullptr);
    assert(fs::exists(original));
}

void test_multi_step_undo(FmCore* core, const fs::path& home_root) {
    assert(setenv("HOME", home_root.c_str(), 1) == 0);
    fs::create_directories(home_root / "stack");
    fs::path a = home_root / "stack" / "a.txt";
    fs::path b = home_root / "stack" / "b.txt";
    write_text(a, "a");
    write_text(b, "b");

    char* err = nullptr;
    int ok = fm_core_delete_with_undo(core, a.c_str(), &err);
    assert(ok == 1);
    assert(err == nullptr);
    ok = fm_core_delete_with_undo(core, b.c_str(), &err);
    assert(ok == 1);
    assert(err == nullptr);
    assert(fm_core_can_undo(core) == 1);

    ok = fm_core_undo(core, &err);
    assert(ok == 1);
    assert(err == nullptr);
    assert(fs::exists(b));
    assert(!fs::exists(a));
    assert(fm_core_can_undo(core) == 1);

    ok = fm_core_undo(core, &err);
    assert(ok == 1);
    assert(err == nullptr);
    assert(fs::exists(a));
    assert(fs::exists(b));
    assert(fm_core_can_undo(core) == 0);

    ok = fm_core_redo(core, &err);
    assert(ok == 1);
    assert(err == nullptr);
    assert(!fs::exists(a));
    assert(fs::exists(b));
    assert(fm_core_can_redo(core) == 1);

    ok = fm_core_redo(core, &err);
    assert(ok == 1);
    assert(err == nullptr);
    assert(!fs::exists(a));
    assert(!fs::exists(b));
    assert(fm_core_can_redo(core) == 0);
}

void test_cancel_reset_lifecycle(FmCore* core, const fs::path& root) {
    fs::create_directories(root / "src");
    fs::create_directories(root / "dst");
    write_text(root / "src" / "x.txt", "x");

    fm_core_request_cancel(core);

    char* err = nullptr;
    char* final_path = nullptr;
    int ok = fm_core_copy_or_move(
        core,
        (root / "src" / "x.txt").c_str(),
        (root / "dst").c_str(),
        0,
        &final_path,
        &err
    );
    assert(ok == 0);
    assert(err != nullptr);
    fm_string_free(err);
    err = nullptr;

    fm_core_reset_cancel(core);
    ok = fm_core_copy_or_move(
        core,
        (root / "src" / "x.txt").c_str(),
        (root / "dst").c_str(),
        0,
        &final_path,
        &err
    );
    assert(ok == 1);
    assert(err == nullptr);
    assert(final_path != nullptr);
    fm_string_free(final_path);
}

}  // namespace

int main() {
    TempDir temp;
    FmCore* core = fm_core_new();
    assert(core != nullptr);

    test_list_dir_and_sorting(core, temp.path / "list");
    test_copy_unique_name(core, temp.path / "copy");
    test_trash_delete_and_undo(core, temp.path / "home");
    test_multi_step_undo(core, temp.path / "home2");
    test_cancel_reset_lifecycle(core, temp.path / "cancel");

    fm_core_free(core);
    return 0;
}
