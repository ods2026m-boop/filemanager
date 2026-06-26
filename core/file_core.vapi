[CCode (cprefix = "", lower_case_cprefix = "", cheader_filename = "file_core.h")]
namespace FileCore {
    [CCode (cname = "FmCore", free_function = "fm_core_free")]
    [Compact]
    public class Core {
        [CCode (cname = "fm_core_new")]
        public Core();

        [CCode (cname = "fm_core_list_dir")]
        public string? list_dir(string path, out string? error_message);

        [CCode (cname = "fm_core_copy_or_move")]
        public int copy_or_move(
            string source_path,
            string destination_dir_path,
            int is_cut,
            out string? final_path,
            out string? error_message
        );

        [CCode (cname = "fm_core_delete_with_undo")]
        public int delete_with_undo(string source_path, out string? error_message);

        [CCode (cname = "fm_core_undo")]
        public int undo(out string? error_message);

        [CCode (cname = "fm_core_can_undo")]
        public int can_undo();

        [CCode (cname = "fm_core_redo")]
        public int redo(out string? error_message);

        [CCode (cname = "fm_core_can_redo")]
        public int can_redo();

        [CCode (cname = "fm_core_request_cancel")]
        public void request_cancel();

        [CCode (cname = "fm_core_reset_cancel")]
        public void reset_cancel();
    }
}
