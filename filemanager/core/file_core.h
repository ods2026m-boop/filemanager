#ifndef FILE_CORE_H
#define FILE_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FmCore FmCore;

FmCore* fm_core_new(void);
void fm_core_free(FmCore* core);

char* fm_core_list_dir(FmCore* core, const char* path, char** error_message);
int fm_core_copy_or_move(
    FmCore* core,
    const char* source_path,
    const char* destination_dir_path,
    int is_cut,
    char** out_final_path,
    char** error_message
);
int fm_core_delete_with_undo(FmCore* core, const char* source_path, char** error_message);
int fm_core_undo(FmCore* core, char** error_message);
int fm_core_can_undo(FmCore* core);
int fm_core_redo(FmCore* core, char** error_message);
int fm_core_can_redo(FmCore* core);
void fm_core_request_cancel(FmCore* core);
void fm_core_reset_cancel(FmCore* core);

void fm_string_free(char* value);

#ifdef __cplusplus
}
#endif

#endif
