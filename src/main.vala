using Gtk;
using GLib;
using Gdk;

[CCode (cname = "human_size")]
public extern unowned string c_human_size(uint64 bytes);

public class FileManagerWindow : ApplicationWindow {
    private const string FIELD_SEP = "\t";
    private delegate void EntryDialogHandler(bool accepted, string text);
    private delegate void ConfirmDialogHandler(bool accepted);

    private Entry? path_entry;
    private Entry? search_entry;
    private CheckButton? recursive_check;
    private StringList? rows;
    private MultiSelection? selection;
    private ListView? list_view;
    private ProgressBar? progress_bar;
    private Button? progress_cancel_button;
    private Button? sort_name_button;
    private Button? sort_size_button;
    private ListBox? places_list;
    private Label? queue_label;
    private Label? status_label;
    private bool operation_active = false;
    private string[] recent_jobs = {};
    private enum SortMode { NAME, SIZE }
    private SortMode sort_mode = SortMode.NAME;
    private bool sort_ascending = true;

    private string current_path;
    private string[] all_records = {};
    private string[] recursive_records = {};
    private bool recursive_ready = false;

    private string[] clipboard_paths = {};
    private bool clipboard_has_item = false;
    private bool clipboard_is_cut = false;
    private FileCore.Core? core_handle = null;

    private SimpleActionGroup? context_actions;
    private SimpleAction? ctx_open_action;
    private SimpleAction? ctx_rename_action;
    private SimpleAction? ctx_copy_action;
    private SimpleAction? ctx_cut_action;
    private SimpleAction? ctx_paste_here_action;
    private SimpleAction? ctx_paste_into_action;
    private SimpleAction? ctx_delete_action;
    private SimpleAction? ctx_undo_action;
    private SimpleAction? ctx_redo_action;
    private SimpleAction? ctx_new_folder_action;
    private SimpleAction? ctx_refresh_action;

    private bool context_has_selection = false;
    private bool context_selected_is_dir = false;
    private string context_selected_path = "";
    private string context_selected_name = "";

    public FileManagerWindow(Gtk.Application app) {
        Object(application: app, title: "Omanager", default_width: 1040, default_height: 680);
        core_handle = new FileCore.Core();
        current_path = Environment.get_home_dir();
        init_context_actions();
        build_ui();
        install_shortcuts();
        load_directory(current_path);
    }

    ~FileManagerWindow() {
        core_handle = null;
    }

    private void build_ui() {
        apply_native_css();

        var root = new Box(Orientation.VERTICAL, 8);
        root.margin_top = 8;
        root.margin_bottom = 8;
        root.margin_start = 8;
        root.margin_end = 8;
        set_child(root);

        var toolbar = new Box(Orientation.HORIZONTAL, 6);
        toolbar.add_css_class("toolbar");
        toolbar.add_css_class("boxed-list");
        root.append(toolbar);

        var up_button = new Button.from_icon_name("go-up-symbolic");
        up_button.tooltip_text = "Go to parent folder";
        up_button.add_css_class("flat");
        up_button.clicked.connect(() => { go_up(); });
        toolbar.append(up_button);

        path_entry = new Entry();
        path_entry.hexpand = true;
        path_entry.add_css_class("monospace");
        path_entry.placeholder_text = "Enter folder path and press Enter";
        path_entry.activate.connect(() => {
            var target = path_entry.text.strip();
            if (target.length > 0) {
                load_directory(target);
            }
        });
        toolbar.append(path_entry);

        var refresh_button = new Button.from_icon_name("view-refresh-symbolic");
        refresh_button.tooltip_text = "Refresh";
        refresh_button.add_css_class("flat");
        refresh_button.clicked.connect(() => { load_directory(current_path); });
        toolbar.append(refresh_button);

        var copy_button = new Button.from_icon_name("edit-copy-symbolic");
        copy_button.tooltip_text = "Copy";
        copy_button.add_css_class("flat");
        copy_button.clicked.connect(() => { copy_selected_to_clipboard(); });
        toolbar.append(copy_button);

        var cut_button = new Button.from_icon_name("edit-cut-symbolic");
        cut_button.tooltip_text = "Cut";
        cut_button.add_css_class("flat");
        cut_button.clicked.connect(() => { cut_selected_to_clipboard(); });
        toolbar.append(cut_button);

        var paste_button = new Button.from_icon_name("edit-paste-symbolic");
        paste_button.tooltip_text = "Paste";
        paste_button.add_css_class("flat");
        paste_button.clicked.connect(() => { paste_from_clipboard(); });
        toolbar.append(paste_button);

        var rename_button = new Button.from_icon_name("edit-rename-symbolic");
        rename_button.tooltip_text = "Rename";
        rename_button.add_css_class("flat");
        rename_button.clicked.connect(() => { rename_selected(); });
        toolbar.append(rename_button);

        var delete_button = new Button.from_icon_name("user-trash-symbolic");
        delete_button.tooltip_text = "Delete";
        delete_button.add_css_class("flat");
        delete_button.clicked.connect(() => { confirm_and_delete_selected(); });
        toolbar.append(delete_button);

        var undo_button = new Button.from_icon_name("edit-undo-symbolic");
        undo_button.tooltip_text = "Undo";
        undo_button.add_css_class("flat");
        undo_button.clicked.connect(() => { undo_last_action(); });
        toolbar.append(undo_button);

        var redo_button = new Button.from_icon_name("edit-redo-symbolic");
        redo_button.tooltip_text = "Redo";
        redo_button.add_css_class("flat");
        redo_button.clicked.connect(() => { redo_last_action(); });
        toolbar.append(redo_button);

        var search_bar = new Box(Orientation.HORIZONTAL, 8);
        search_bar.add_css_class("toolbar");
        root.append(search_bar);

        search_entry = new Entry();
        search_entry.hexpand = true;
        search_entry.placeholder_text = "Search in current folder...";
        search_entry.changed.connect(() => {
            refresh_visible_records();
        });
        search_bar.append(search_entry);

        recursive_check = new CheckButton.with_label("Recursive");
        recursive_check.toggled.connect(() => {
            refresh_visible_records();
        });
        search_bar.append(recursive_check);

        var content_pane = new Paned(Orientation.HORIZONTAL);
        content_pane.resize_start_child = false;
        content_pane.shrink_start_child = false;
        content_pane.shrink_end_child = false;
        root.append(content_pane);

        var sidebar = build_places_sidebar();
        content_pane.set_start_child(sidebar);

        rows = new StringList(null);
        selection = new MultiSelection(rows);

        var factory = new SignalListItemFactory();
        factory.setup.connect((obj) => {
            var item = obj as ListItem;
            var hbox = new Box(Orientation.HORIZONTAL, 10);

            var image = new Image.from_icon_name("text-x-generic");
            image.pixel_size = 20;
            image.halign = Align.START;

            var name_label = new Label("");
            name_label.xalign = 0.0f;
            name_label.hexpand = true;
            name_label.halign = Align.FILL;

            var size_label = new Label("");
            size_label.xalign = 1.0f;
            size_label.halign = Align.END;
            size_label.add_css_class("dim-label");
            size_label.add_css_class("monospace");
            size_label.width_chars = 10;

            hbox.append(image);
            hbox.append(name_label);
            hbox.append(size_label);
            item.set_child(hbox);
        });

        factory.bind.connect((obj) => {
            var item = obj as ListItem;
            var hbox = item.get_child() as Box;
            var image = hbox.get_first_child() as Image;
            var name_label = hbox.get_first_child().get_next_sibling() as Label;
            var size_label = hbox.get_last_child() as Label;
            var s_obj = item.get_item() as StringObject;
            hbox.set_name("fm-row-%u".printf(item.get_position()));

            bool is_dir;
            string display_name;
            uint64 size;
            string icon_name;
            string rel_path;
            if (!unpack_record(s_obj.get_string(), out is_dir, out display_name, out size, out icon_name, out rel_path)) {
                image.set_from_icon_name("text-x-generic");
                name_label.label = s_obj.get_string();
                size_label.label = "";
                return;
            }

            image.set_from_icon_name(icon_name);
            name_label.label = display_name;
            size_label.label = is_dir ? "-" : c_human_size(size);
        });

        list_view = new ListView(selection, factory);
        list_view.vexpand = true;
        list_view.activate.connect((position) => {
            open_selected(position);
        });
        install_context_menu();

        var list_header = new Box(Orientation.HORIZONTAL, 10);
        list_header.add_css_class("toolbar");
        list_header.add_css_class("boxed-list");
        var header_spacer = new Label("");
        header_spacer.width_chars = 2;
        sort_name_button = new Button.with_label("Name");
        sort_name_button.halign = Align.FILL;
        sort_name_button.hexpand = true;
        sort_name_button.add_css_class("flat");
        sort_name_button.add_css_class("monospace");
        sort_name_button.clicked.connect(() => {
            toggle_sort(SortMode.NAME);
        });

        sort_size_button = new Button.with_label("Size");
        sort_size_button.halign = Align.END;
        sort_size_button.width_request = 120;
        sort_size_button.add_css_class("flat");
        sort_size_button.add_css_class("monospace");
        sort_size_button.clicked.connect(() => {
            toggle_sort(SortMode.SIZE);
        });

        list_header.append(header_spacer);
        list_header.append(sort_name_button);
        list_header.append(sort_size_button);
        update_sort_buttons();

        var scrolled = new ScrolledWindow();
        scrolled.vexpand = true;
        scrolled.hexpand = true;
        scrolled.set_child(list_view);

        var main_panel = new Box(Orientation.VERTICAL, 8);
        main_panel.vexpand = true;
        main_panel.hexpand = true;
        main_panel.append(list_header);
        main_panel.append(scrolled);
        content_pane.set_end_child(main_panel);

        var progress_row = new Box(Orientation.HORIZONTAL, 8);
        progress_row.visible = false;

        progress_bar = new ProgressBar();
        progress_bar.hexpand = true;
        progress_bar.show_text = true;
        progress_row.append(progress_bar);

        progress_cancel_button = new Button.with_label("Cancel");
        progress_cancel_button.clicked.connect(() => {
            if (!operation_active || core_handle == null) {
                return;
            }
            core_handle.request_cancel();
            progress_cancel_button.sensitive = false;
            set_status("Cancellation requested...");
            push_job_event("Cancel requested for active operation");
        });
        progress_row.append(progress_cancel_button);

        main_panel.append(progress_row);

        var queue_frame = new Frame("Recent Operations");
        queue_label = new Label("No recent operations.");
        queue_label.xalign = 0.0f;
        queue_label.wrap = true;
        queue_label.use_markup = true;
        queue_frame.set_child(queue_label);
        main_panel.append(queue_frame);

        status_label = new Label("Ready");
        status_label.xalign = 0.0f;
        main_panel.append(status_label);
    }

    private void apply_native_css() {
        var css = """
        .place-row {
            padding: 6px 8px;
            border-radius: 8px;
        }
        .queue-frame {
            padding: 4px;
        }
        """;
        var provider = new CssProvider();
        provider.load_from_string(css);
        StyleContext.add_provider_for_display(
            Display.get_default(),
            provider,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private Widget build_places_sidebar() {
        places_list = new ListBox();
        places_list.selection_mode = SelectionMode.SINGLE;
        places_list.add_css_class("navigation-sidebar");

        add_place("Home", Environment.get_home_dir(), "user-home-symbolic");
        add_place_if_exists("Desktop", Path.build_filename(Environment.get_home_dir(), "Desktop"), "user-desktop-symbolic");
        add_place_if_exists("Documents", Path.build_filename(Environment.get_home_dir(), "Documents"), "folder-documents-symbolic");
        add_place_if_exists("Downloads", Path.build_filename(Environment.get_home_dir(), "Downloads"), "folder-download-symbolic");
        add_place_if_exists("Trash", Path.build_filename(Environment.get_home_dir(), ".local/share/Trash/files"), "user-trash-symbolic");
        add_place("Filesystem", "/", "drive-harddisk-symbolic");

        places_list.row_activated.connect((row) => {
            var path = row.tooltip_text;
            if (path != null && path.length > 0) {
                load_directory(path);
            }
        });

        var scrolled = new ScrolledWindow();
        scrolled.min_content_width = 220;
        scrolled.vexpand = true;
        scrolled.set_child(places_list);
        return scrolled;
    }

    private void add_place_if_exists(string title, string path, string icon_name) {
        if (!File.new_for_path(path).query_exists()) {
            return;
        }
        add_place(title, path, icon_name);
    }

    private void add_place(string title, string path, string icon_name) {
        if (places_list == null) {
            return;
        }

        var row = new ListBoxRow();
        row.tooltip_text = path;
        var box = new Box(Orientation.HORIZONTAL, 8);
        box.add_css_class("place-row");
        var icon = new Image.from_icon_name(icon_name);
        icon.pixel_size = 18;
        var label = new Label(title);
        label.xalign = 0.0f;
        label.hexpand = true;
        box.append(icon);
        box.append(label);
        row.set_child(box);
        places_list.append(row);
    }

    private void install_shortcuts() {
        var controller = new EventControllerKey();
        controller.key_pressed.connect((keyval, keycode, state) => {
            if (handle_shortcut((uint) keyval, state)) {
                return true;
            }
            return false;
        });
        ((Widget) this).add_controller(controller);
    }

    private bool handle_shortcut(uint keyval, ModifierType state) {
        var focus = get_focus();
        bool editing = focus is Editable;
        bool ctrl = (state & ModifierType.CONTROL_MASK) != 0;

        if (ctrl && !editing && keyval == Key.c) {
            copy_selected_to_clipboard();
            return true;
        }
        if (ctrl && !editing && keyval == Key.x) {
            cut_selected_to_clipboard();
            return true;
        }
        if (ctrl && !editing && keyval == Key.v) {
            paste_from_clipboard();
            return true;
        }
        if (ctrl && !editing && keyval == Key.z) {
            undo_last_action();
            return true;
        }
        if (ctrl && !editing && keyval == Key.y) {
            redo_last_action();
            return true;
        }
        if (ctrl && !editing && keyval == Key.n && (state & ModifierType.SHIFT_MASK) != 0) {
            create_new_folder();
            return true;
        }
        if (!editing && keyval == Key.Delete) {
            confirm_and_delete_selected();
            return true;
        }
        if (!editing && keyval == Key.F2) {
            rename_selected();
            return true;
        }

        return false;
    }

    private void init_context_actions() {
        context_actions = new SimpleActionGroup();
        insert_action_group("ctx", context_actions);

        ctx_open_action = new SimpleAction("open", null);
        ctx_open_action.activate.connect((parameter) => { open_current_selection(); });
        context_actions.add_action(ctx_open_action);

        ctx_rename_action = new SimpleAction("rename", null);
        ctx_rename_action.activate.connect((parameter) => { rename_selected(); });
        context_actions.add_action(ctx_rename_action);

        ctx_copy_action = new SimpleAction("copy", null);
        ctx_copy_action.activate.connect((parameter) => { copy_selected_to_clipboard(); });
        context_actions.add_action(ctx_copy_action);

        ctx_cut_action = new SimpleAction("cut", null);
        ctx_cut_action.activate.connect((parameter) => { cut_selected_to_clipboard(); });
        context_actions.add_action(ctx_cut_action);

        ctx_paste_here_action = new SimpleAction("paste_here", null);
        ctx_paste_here_action.activate.connect((parameter) => { paste_from_clipboard(); });
        context_actions.add_action(ctx_paste_here_action);

        ctx_paste_into_action = new SimpleAction("paste_into", null);
        ctx_paste_into_action.activate.connect((parameter) => {
            if (context_has_selection && context_selected_is_dir) {
                paste_from_clipboard_to(context_selected_path);
            }
        });
        context_actions.add_action(ctx_paste_into_action);

        ctx_delete_action = new SimpleAction("delete", null);
        ctx_delete_action.activate.connect((parameter) => { confirm_and_delete_selected(); });
        context_actions.add_action(ctx_delete_action);

        ctx_undo_action = new SimpleAction("undo", null);
        ctx_undo_action.activate.connect((parameter) => { undo_last_action(); });
        context_actions.add_action(ctx_undo_action);

        ctx_redo_action = new SimpleAction("redo", null);
        ctx_redo_action.activate.connect((parameter) => { redo_last_action(); });
        context_actions.add_action(ctx_redo_action);

        ctx_new_folder_action = new SimpleAction("new_folder", null);
        ctx_new_folder_action.activate.connect((parameter) => { create_new_folder(); });
        context_actions.add_action(ctx_new_folder_action);

        ctx_refresh_action = new SimpleAction("refresh", null);
        ctx_refresh_action.activate.connect((parameter) => { load_directory(current_path); });
        context_actions.add_action(ctx_refresh_action);
    }

    private void install_context_menu() {
        if (list_view == null) {
            return;
        }

        var gesture = new GestureClick();
        gesture.set_button(3);
        gesture.pressed.connect((n_press, x, y) => {
            var clicked_row = row_index_from_point(x, y);
            if (clicked_row >= 0 && selection != null && rows != null && (uint) clicked_row < rows.get_n_items()) {
                selection.select_item((uint) clicked_row, true);
                show_context_menu(x, y);
            } else {
                show_background_context_menu(x, y);
            }
        });
        list_view.add_controller(gesture);
    }

    private int row_index_from_point(double x, double y) {
        if (list_view == null) {
            return -1;
        }

        var picked = list_view.pick(x, y, PickFlags.DEFAULT);
        while (picked != null) {
            var name = picked.get_name();
            if (name != null && name.has_prefix("fm-row-")) {
                uint idx;
                if (uint.try_parse(name.substring(7), out idx)) {
                    return (int) idx;
                }
            }

            if (picked == list_view) {
                break;
            }
            picked = picked.get_parent();
        }

        return -1;
    }

    private void show_context_menu(double x, double y) {
        if (list_view == null) {
            return;
        }

        context_has_selection = try_single_selected_path_and_type(out context_selected_path, out context_selected_is_dir, out context_selected_name);
        sync_context_actions();

        var model = build_item_context_menu_model();
        popup_menu_model(model, x, y);
    }

    private void show_background_context_menu(double x, double y) {
        if (list_view == null) {
            return;
        }

        context_has_selection = false;
        context_selected_is_dir = false;
        context_selected_path = "";
        context_selected_name = "";
        sync_context_actions();

        var model = build_background_context_menu_model();
        popup_menu_model(model, x, y);
    }

    private GLib.Menu build_item_context_menu_model() {
        var top = new GLib.Menu();

        var open_label = "Open";
        if (context_has_selection) {
            open_label = context_selected_is_dir ? "Open Folder" : "Open File";
        }

        append_menu_item(top, open_label, "ctx.open", "document-open-symbolic");
        append_menu_item(top, "Rename", "ctx.rename", "edit-rename-symbolic");
        append_menu_item(top, "Copy", "ctx.copy", "edit-copy-symbolic");
        append_menu_item(top, "Cut", "ctx.cut", "edit-cut-symbolic");

        if (context_has_selection && context_selected_is_dir) {
            append_menu_item(top, "Paste Into '%s'".printf(context_selected_name), "ctx.paste_into", "edit-paste-symbolic");
        }

        append_menu_item(top, "Paste Here", "ctx.paste_here", "edit-paste-symbolic");
        append_menu_item(top, "Delete", "ctx.delete", "user-trash-symbolic");

        var undo_section = new GLib.Menu();
        append_menu_item(undo_section, "Undo", "ctx.undo", "edit-undo-symbolic");
        append_menu_item(undo_section, "Redo", "ctx.redo", "edit-redo-symbolic");
        top.append_section(null, undo_section);
        return top;
    }

    private GLib.Menu build_background_context_menu_model() {
        var menu = new GLib.Menu();
        append_menu_item(menu, "Paste Here", "ctx.paste_here", "edit-paste-symbolic");
        append_menu_item(menu, "New Folder", "ctx.new_folder", "folder-new-symbolic");
        append_menu_item(menu, "Refresh", "ctx.refresh", "view-refresh-symbolic");
        var history = new GLib.Menu();
        append_menu_item(history, "Undo", "ctx.undo", "edit-undo-symbolic");
        append_menu_item(history, "Redo", "ctx.redo", "edit-redo-symbolic");
        menu.append_section(null, history);
        return menu;
    }

    private void append_menu_item(GLib.Menu menu, string label, string action_name, string? icon_name) {
        var item = new GLib.MenuItem(label, action_name);
        if (icon_name != null) {
            item.set_icon(new ThemedIcon(icon_name));
        }
        menu.append_item(item);
    }

    private void popup_menu_model(MenuModel model, double x, double y) {
        if (list_view == null) {
            return;
        }

        var popover = new PopoverMenu.from_model(model);
        popover.set_parent(list_view);

        Gdk.Rectangle rect = Gdk.Rectangle();
        rect.x = (int) x;
        rect.y = (int) y;
        rect.width = 1;
        rect.height = 1;
        popover.set_pointing_to(rect);
        popover.popup();
    }

    private void set_action_enabled(SimpleAction? action, bool enabled) {
        if (action != null) {
            action.set_enabled(enabled);
        }
    }

    private void sync_context_actions() {
        set_action_enabled(ctx_open_action, context_has_selection);
        set_action_enabled(ctx_rename_action, context_has_selection);
        set_action_enabled(ctx_copy_action, context_has_selection);
        set_action_enabled(ctx_cut_action, context_has_selection);
        set_action_enabled(ctx_delete_action, context_has_selection);

        set_action_enabled(ctx_paste_here_action, clipboard_has_item);
        set_action_enabled(ctx_paste_into_action, context_has_selection && context_selected_is_dir && clipboard_has_item);

        set_action_enabled(ctx_undo_action, core_handle != null && core_handle.can_undo() != 0);
        set_action_enabled(ctx_redo_action, core_handle != null && core_handle.can_redo() != 0);
        set_action_enabled(ctx_new_folder_action, true);
        set_action_enabled(ctx_refresh_action, true);
    }

    private string pack_record(bool is_dir, string display_name, uint64 size, string icon_name, string rel_path) {
        return "%s%s%s%s%llu%s%s%s%s".printf(
            is_dir ? "1" : "0",
            FIELD_SEP,
            display_name,
            FIELD_SEP,
            size,
            FIELD_SEP,
            icon_name,
            FIELD_SEP,
            rel_path
        );
    }

    private bool unpack_record(
        string record,
        out bool is_dir,
        out string display_name,
        out uint64 size,
        out string icon_name,
        out string rel_path
    ) {
        is_dir = false;
        display_name = "";
        size = 0;
        icon_name = "text-x-generic";
        rel_path = "";

        var parts = record.split(FIELD_SEP);
        if (parts.length < 5) {
            return false;
        }

        is_dir = parts[0] == "1";
        display_name = parts[1];
        uint64.try_parse(parts[2], out size);
        icon_name = parts[3];
        rel_path = parts[4];
        return true;
    }

    private void toggle_sort(SortMode mode) {
        if (sort_mode == mode) {
            sort_ascending = !sort_ascending;
        } else {
            sort_mode = mode;
            sort_ascending = true;
        }
        update_sort_buttons();
        refresh_visible_records();
    }

    private void update_sort_buttons() {
        if (sort_name_button != null) {
            var suffix = (sort_mode == SortMode.NAME) ? (sort_ascending ? " \u25b2" : " \u25bc") : "";
            sort_name_button.set_label("Name" + suffix);
        }
        if (sort_size_button != null) {
            var suffix = (sort_mode == SortMode.SIZE) ? (sort_ascending ? " \u25b2" : " \u25bc") : "";
            sort_size_button.set_label("Size" + suffix);
        }
    }

    private string current_sort_label() {
        var field = (sort_mode == SortMode.NAME) ? "Name" : "Size";
        var direction = sort_ascending ? "Asc" : "Desc";
        return "Sorted by %s (%s)".printf(field, direction);
    }

    private void update_window_title() {
        var folder_name = File.new_for_path(current_path).get_basename();
        if (folder_name == null || folder_name.length == 0) {
            folder_name = current_path;
        }

        string search_state = "";
        if (search_entry != null) {
            var query = search_entry.text.strip();
            if (query.length > 0) {
                search_state = " | Search: " + query;
            }
        }

        string recursive_state = "";
        if (recursive_check != null && recursive_check.active) {
            recursive_state = " [Recursive]";
        }

        title = "Omanager - %s%s%s | %s".printf(
            folder_name,
            search_state,
            recursive_state,
            current_sort_label()
        );
    }

    private int compare_records(string a, string b) {
        bool a_is_dir;
        bool b_is_dir;
        string a_name;
        string b_name;
        uint64 a_size;
        uint64 b_size;
        string a_icon;
        string b_icon;
        string a_rel;
        string b_rel;

        if (!unpack_record(a, out a_is_dir, out a_name, out a_size, out a_icon, out a_rel)) {
            return 0;
        }
        if (!unpack_record(b, out b_is_dir, out b_name, out b_size, out b_icon, out b_rel)) {
            return 0;
        }

        if (a_is_dir != b_is_dir) {
            return a_is_dir ? -1 : 1;
        }

        if (sort_mode == SortMode.SIZE && a_size != b_size) {
            if (sort_ascending) {
                return a_size < b_size ? -1 : 1;
            }
            return a_size > b_size ? -1 : 1;
        }

        var a_lower = a_name.down();
        var b_lower = b_name.down();
        int name_cmp = 0;
        if (a_lower < b_lower) {
            name_cmp = -1;
        } else if (a_lower > b_lower) {
            name_cmp = 1;
        }

        if (sort_mode == SortMode.NAME && !sort_ascending) {
            name_cmp *= -1;
        }
        return name_cmp;
    }

    private void sort_records_in_place(string[] records) {
        quick_sort_records(records, 0, records.length - 1);
    }

    private void quick_sort_records(string[] records, int left, int right) {
        if (left >= right || right >= records.length) {
            return;
        }
        var pivot = records[left + (right - left) / 2];
        int i = left;
        int j = right;
        while (i <= j) {
            while (i <= right && compare_records(records[i], pivot) < 0) i++;
            while (j >= left && compare_records(records[j], pivot) > 0) j--;
            if (i <= j) {
                var tmp = records[i];
                records[i] = records[j];
                records[j] = tmp;
                i++;
                j--;
            }
        }
        if (left < j) quick_sort_records(records, left, j);
        if (i < right) quick_sort_records(records, i, right);
    }

    private void clear_rows() {
        if (rows == null) {
            return;
        }
        while (rows.get_n_items() > 0) {
            rows.remove(rows.get_n_items() - 1);
        }
    }

    private void refresh_visible_records() {
        if (rows == null || search_entry == null || recursive_check == null) {
            return;
        }

        var query = search_entry.text.strip().down();
        var use_recursive = recursive_check.active && query.length > 0;

        if (use_recursive && !recursive_ready) {
            build_recursive_records();
        }

        var source_records = use_recursive ? recursive_records : all_records;
        string[] filtered_records = {};

        clear_rows();
        foreach (var record in source_records) {
            bool is_dir;
            string display_name;
            uint64 size;
            string icon_name;
            string rel_path;
            if (!unpack_record(record, out is_dir, out display_name, out size, out icon_name, out rel_path)) {
                continue;
            }

            if (query.length > 0 && !display_name.down().contains(query)) {
                continue;
            }

            filtered_records += record;
        }

        sort_records_in_place(filtered_records);
        foreach (var record in filtered_records) {
            rows.append(record);
        }

        var mode = use_recursive ? "recursive" : "current";
        set_status("%u/%u item(s) [%s] in %s | %s".printf(
            rows.get_n_items(),
            (uint) source_records.length,
            mode,
            current_path,
            current_sort_label()
        ));
        update_window_title();
        sync_context_actions();
    }

    private void go_up() {
        var parent = Path.get_dirname(current_path);
        if (parent == current_path) {
            return;
        }
        load_directory(parent);
    }

    private string themed_icon_name(Icon? icon, bool is_dir) {
        var fallback = is_dir ? "folder" : "text-x-generic";
        if (icon is ThemedIcon) {
            var names = ((ThemedIcon) icon).get_names();
            if (names != null && names.length > 0) {
                return names[0];
            }
        }
        return fallback;
    }

    private string icon_name_for_path(string full_path, bool is_dir) {
        var file = File.new_for_path(full_path);
        try {
            var info = file.query_info("standard::icon", FileQueryInfoFlags.NONE, null);
            return themed_icon_name(info.get_icon(), is_dir);
        } catch (Error err) {
            return is_dir ? "folder" : "text-x-generic";
        }
    }

    private void load_directory(string path) {
        if (rows == null || path_entry == null || search_entry == null) {
            return;
        }

        var file = File.new_for_path(path);
        if (!file.query_exists()) {
            set_status("Path not found: " + path);
            return;
        }

        if (file.query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
            set_status("Not a directory: " + path);
            return;
        }

        clear_rows();
        all_records = {};
        recursive_records = {};
        recursive_ready = false;

        current_path = file.get_path();
        path_entry.text = current_path;

        if (core_handle == null) {
            set_status("Core is not available.");
            return;
        }

        string? err_text = null;
        var out_text = core_handle.list_dir(current_path, out err_text);
        if (out_text == null) {
            set_status("List failed: " + ((err_text != null) ? err_text : "unknown error"));
            return;
        }

        foreach (var line in out_text.split("\n")) {
            var trimmed = line.strip();
            if (trimmed.length == 0) {
                continue;
            }

            var parts = trimmed.split("\t");
            if (parts.length < 3) {
                continue;
            }

            bool is_dir = parts[1] == "1";
            var name = parts[0];
            var full_path = Path.build_filename(current_path, name);
            var icon_name = icon_name_for_path(full_path, is_dir);
            uint64 size = 0;
            uint64.try_parse(parts[2], out size);

            all_records += pack_record(is_dir, name, size, icon_name, name);
        }

        refresh_visible_records();
    }

    private void build_recursive_records() {
        recursive_records = {};
        var base_dir = File.new_for_path(current_path);

        try {
            append_recursive_from_directory(base_dir);
            recursive_ready = true;
        } catch (Error err) {
            recursive_ready = false;
            set_status("Recursive scan failed: " + err.message);
        }
    }

    private void append_recursive_from_directory(File current_dir) throws Error {
        var attrs = "standard::name,standard::type,standard::size,standard::icon";
        var enumerator = current_dir.enumerate_children(attrs, FileQueryInfoFlags.NONE, null);

        FileInfo info;
        while ((info = enumerator.next_file(null)) != null) {
            var child = current_dir.get_child(info.get_name());
            var child_path = child.get_path();
            if (child_path == null || !child_path.has_prefix(current_path + "/")) {
                continue;
            }

            var rel_path = child_path.substring(current_path.length + 1);
            var is_dir = info.get_file_type() == FileType.DIRECTORY;
            var size = is_dir ? 0 : info.get_size();
            var icon_name = themed_icon_name(info.get_icon(), is_dir);

            recursive_records += pack_record(is_dir, rel_path, size, icon_name, rel_path);

            if (is_dir) {
                append_recursive_from_directory(child);
            }
        }
    }

    private bool get_single_selected_record(out string record) {
        record = "";
        string[] records = {};
        get_selected_records(out records);
        if (records.length != 1) {
            return false;
        }
        record = records[0];
        return true;
    }

    private void get_selected_records(out string[] records) {
        if (rows == null || selection == null) {
            records = {};
            return;
        }

        int count = 0;
        for (uint i = 0; i < rows.get_n_items(); i++) {
            if (!selection.is_selected(i)) {
                continue;
            }
            count++;
        }

        records = new string[count];
        int idx = 0;
        for (uint i = 0; i < rows.get_n_items(); i++) {
            if (!selection.is_selected(i)) {
                continue;
            }
            var row_obj = rows.get_object(i) as StringObject;
            records[idx++] = row_obj.get_string();
        }
    }

    private int find_row_index_by_rel_path(string rel_path) {
        if (rows == null) {
            return -1;
        }

        for (uint i = 0; i < rows.get_n_items(); i++) {
            var row_obj = rows.get_object(i) as StringObject;
            bool is_dir;
            string display_name;
            uint64 size;
            string icon_name;
            string row_rel_path;
            if (!unpack_record(row_obj.get_string(), out is_dir, out display_name, out size, out icon_name, out row_rel_path)) {
                continue;
            }
            if (row_rel_path == rel_path) {
                return (int) i;
            }
        }
        return -1;
    }

    private void select_rel_paths(string[] rel_paths) {
        if (selection == null) {
            return;
        }

        selection.unselect_all();
        foreach (var rel_path in rel_paths) {
            var idx = find_row_index_by_rel_path(rel_path);
            if (idx >= 0) {
                selection.select_item((uint) idx, false);
            }
        }
    }

    private bool single_selected_path_and_type(out string full_path, out bool is_dir, out string basename) {
        if (!try_single_selected_path_and_type(out full_path, out is_dir, out basename)) {
            set_status("Select exactly one item.");
            return false;
        }
        return true;
    }

    private bool try_single_selected_path_and_type(out string full_path, out bool is_dir, out string basename) {
        full_path = "";
        is_dir = false;
        basename = "";

        string record;
        if (!get_single_selected_record(out record)) {
            return false;
        }

        string display_name;
        uint64 size;
        string icon_name;
        string rel_path;
        if (!unpack_record(record, out is_dir, out display_name, out size, out icon_name, out rel_path)) {
            return false;
        }

        full_path = Path.build_filename(current_path, rel_path);
        basename = File.new_for_path(full_path).get_basename();
        return true;
    }

    private void open_current_selection() {
        string[] records = {};
        get_selected_records(out records);
        if (records.length == 0) {
            return;
        }

        bool is_dir;
        string display_name;
        uint64 size;
        string icon_name;
        string rel_path;
        if (!unpack_record(records[0], out is_dir, out display_name, out size, out icon_name, out rel_path)) {
            return;
        }

        var full_path = Path.build_filename(current_path, rel_path);
        if (is_dir) {
            load_directory(full_path);
            return;
        }

        string[] argv = { "xdg-open", full_path };
        try {
            Pid child_pid;
            Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, out child_pid);
            set_status("Opened file: " + full_path);
        } catch (SpawnError err) {
            set_status("Failed to open file: " + err.message);
        }
    }

    private void open_selected(uint position) {
        if (rows == null || position >= rows.get_n_items()) {
            return;
        }

        var row_obj = rows.get_object(position) as StringObject;

        bool is_dir;
        string display_name;
        uint64 size;
        string icon_name;
        string rel_path;
        if (!unpack_record(row_obj.get_string(), out is_dir, out display_name, out size, out icon_name, out rel_path)) {
            return;
        }

        var next_path = Path.build_filename(current_path, rel_path);

        if (is_dir) {
            load_directory(next_path);
            return;
        }

        string[] argv = { "xdg-open", next_path };
        try {
            Pid child_pid;
            Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, out child_pid);
            set_status("Opened file: " + next_path);
        } catch (SpawnError err) {
            set_status("Failed to open file: " + err.message);
        }
    }

    private void copy_selected_to_clipboard() {
        string[] records = {};
        get_selected_records(out records);
        if (records.length == 0) {
            set_status("No item selected.");
            return;
        }

        clipboard_paths = {};
        foreach (var record in records) {
            bool is_dir;
            string display_name;
            uint64 size;
            string icon_name;
            string rel_path;
            if (!unpack_record(record, out is_dir, out display_name, out size, out icon_name, out rel_path)) {
                continue;
            }
            clipboard_paths += Path.build_filename(current_path, rel_path);
        }

        if (clipboard_paths.length == 0) {
            set_status("No valid selection.");
            return;
        }

        clipboard_has_item = true;
        clipboard_is_cut = false;
        set_status("Copied %d item(s) to clipboard.".printf(clipboard_paths.length));
    }

    private void cut_selected_to_clipboard() {
        string[] records = {};
        get_selected_records(out records);
        if (records.length == 0) {
            set_status("No item selected.");
            return;
        }

        clipboard_paths = {};
        foreach (var record in records) {
            bool is_dir;
            string display_name;
            uint64 size;
            string icon_name;
            string rel_path;
            if (!unpack_record(record, out is_dir, out display_name, out size, out icon_name, out rel_path)) {
                continue;
            }
            clipboard_paths += Path.build_filename(current_path, rel_path);
        }

        if (clipboard_paths.length == 0) {
            set_status("No valid selection.");
            return;
        }

        clipboard_has_item = true;
        clipboard_is_cut = true;
        set_status("Cut %d item(s) to clipboard.".printf(clipboard_paths.length));
    }

    private void begin_progress(string text, bool cancellable) {
        if (progress_bar == null || progress_cancel_button == null) {
            return;
        }

        var row = progress_bar.get_parent() as Widget;
        if (row != null) {
            row.visible = true;
        }
        progress_bar.fraction = 0.0;
        progress_bar.text = text;
        progress_cancel_button.visible = cancellable;
        progress_cancel_button.sensitive = cancellable;
    }

    private void end_progress() {
        if (progress_bar == null) {
            return;
        }
        var row = progress_bar.get_parent() as Widget;
        if (row != null) {
            row.visible = false;
        }
        progress_bar.text = "";
        progress_bar.fraction = 0.0;
    }

    private string format_eta_seconds(double seconds) {
        if (seconds < 1.0) {
            return "<1s";
        }
        int total = (int) Math.ceil(seconds);
        int mins = total / 60;
        int secs = total % 60;
        if (mins > 0) {
            return "%dm %02ds".printf(mins, secs);
        }
        return "%ds".printf(secs);
    }

    private string build_queue_progress_text(string op_name, int done, int total, int64 started_us) {
        if (done <= 0 || total <= 0) {
            return "%s 0/%d | ETA --".printf(op_name, total);
        }

        var elapsed_sec = ((double) (GLib.get_monotonic_time() - started_us)) / 1000000.0;
        var avg_per_item = elapsed_sec / ((double) done);
        var remaining = total - done;
        var eta = avg_per_item * ((double) remaining);
        return "%s %d/%d | ETA %s".printf(op_name, done, total, format_eta_seconds(eta));
    }

    private void push_job_event(string text) {
        var now = new DateTime.now_local();
        var lower = text.down();
        string level = "INFO";
        if (lower.contains("fail") || lower.contains("error")) {
            level = "FAIL";
        } else if (lower.contains("cancel")) {
            level = "CANCELLED";
        } else if (lower.contains("completed")) {
            level = "SUCCESS";
        }

        var stamped = "[%s] [%s] %s".printf(now.format("%H:%M:%S"), level, text);
        recent_jobs += stamped;
        if (recent_jobs.length > 6) {
            string[] trimmed = {};
            for (int i = recent_jobs.length - 6; i < recent_jobs.length; i++) {
                trimmed += recent_jobs[i];
            }
            recent_jobs = trimmed;
        }
        render_job_queue();
    }

    private void render_job_queue() {
        if (queue_label == null) {
            return;
        }
        if (recent_jobs.length == 0) {
            queue_label.label = Markup.escape_text("No recent operations.");
            return;
        }

        string[] lines = {};
        for (int i = recent_jobs.length - 1; i >= 0; i--) {
            var raw = recent_jobs[i];
            var escaped = Markup.escape_text(raw);
            string color = "#6b7280";
            string icon = "•";
            if (raw.contains("[SUCCESS]")) {
                color = "#138a36";
                icon = "✔";
            } else if (raw.contains("[FAIL]")) {
                color = "#b42318";
                icon = "✖";
            } else if (raw.contains("[CANCELLED]")) {
                color = "#b54708";
                icon = "⚠";
            }
            lines += "<span foreground='%s'>%s %s</span>".printf(color, icon, escaped);
        }
        queue_label.label = string.joinv("\n", lines);
    }


    private void paste_from_clipboard() {
        paste_from_clipboard_to(current_path);
    }

    private Window create_modal_dialog_window(string title) {
        var win = new Window();
        win.set_title(title);
        win.set_modal(true);
        win.set_transient_for(this);
        win.set_resizable(false);
        win.set_default_size(420, -1);
        return win;
    }

    private void show_entry_dialog(
        string title,
        string prompt_text,
        string initial_value,
        string confirm_label,
        EntryDialogHandler on_done
    ) {
        var dialog = create_modal_dialog_window(title);

        var root = new Box(Orientation.VERTICAL, 10);
        root.margin_top = 12;
        root.margin_bottom = 12;
        root.margin_start = 12;
        root.margin_end = 12;
        dialog.set_child(root);

        var prompt = new Label(prompt_text);
        prompt.xalign = 0.0f;
        root.append(prompt);

        var entry = new Entry();
        entry.text = initial_value;
        root.append(entry);

        var actions = new Box(Orientation.HORIZONTAL, 8);
        actions.halign = Align.END;
        root.append(actions);

        var cancel_btn = new Button.with_label("Cancel");
        var ok_btn = new Button.with_label(confirm_label);
        ok_btn.add_css_class("suggested-action");

        actions.append(cancel_btn);
        actions.append(ok_btn);

        cancel_btn.clicked.connect(() => {
            on_done(false, "");
            dialog.close();
        });

        ok_btn.clicked.connect(() => {
            on_done(true, entry.text);
            dialog.close();
        });

        entry.activate.connect(() => {
            on_done(true, entry.text);
            dialog.close();
        });

        dialog.present();
        entry.grab_focus();
    }

    private void show_confirm_dialog(
        string title,
        string message,
        string confirm_label,
        bool destructive,
        ConfirmDialogHandler on_done
    ) {
        var dialog = create_modal_dialog_window(title);

        var root = new Box(Orientation.VERTICAL, 10);
        root.margin_top = 12;
        root.margin_bottom = 12;
        root.margin_start = 12;
        root.margin_end = 12;
        dialog.set_child(root);

        var prompt = new Label(message);
        prompt.wrap = true;
        prompt.xalign = 0.0f;
        root.append(prompt);

        var actions = new Box(Orientation.HORIZONTAL, 8);
        actions.halign = Align.END;
        root.append(actions);

        var cancel_btn = new Button.with_label("Cancel");
        var ok_btn = new Button.with_label(confirm_label);
        if (destructive) {
            ok_btn.add_css_class("destructive-action");
        } else {
            ok_btn.add_css_class("suggested-action");
        }

        actions.append(cancel_btn);
        actions.append(ok_btn);

        cancel_btn.clicked.connect(() => {
            on_done(false);
            dialog.close();
        });

        ok_btn.clicked.connect(() => {
            on_done(true);
            dialog.close();
        });

        dialog.present();
    }

    private void create_new_folder() {
        show_entry_dialog("New Folder", "Folder name:", "New Folder", "Create", (accepted, text) => {
            if (!accepted) {
                return;
            }

            var folder_name = text.strip();
            if (folder_name.length == 0) {
                set_status("Invalid folder name.");
            } else if (folder_name.contains("/")) {
                set_status("Folder name cannot contain '/'.");
            } else {
                var parent = File.new_for_path(current_path);
                var final_name = unique_folder_name(parent, folder_name);
                var child = parent.get_child(final_name);
                try {
                    child.make_directory(null);
                    set_status("Folder created: " + final_name);
                    load_directory(current_path);
                } catch (Error err) {
                    set_status("Create folder failed: " + err.message);
                }
            }
        });
    }

    private string unique_folder_name(File parent, string base_name) {
        var candidate = parent.get_child(base_name);
        if (!candidate.query_exists()) {
            return base_name;
        }

        for (int i = 2; i < 10000; i++) {
            var name = "%s (%d)".printf(base_name, i);
            candidate = parent.get_child(name);
            if (!candidate.query_exists()) {
                return name;
            }
        }

        return base_name + " (copy)";
    }

    private void paste_from_clipboard_to(string destination_dir_path) {
        if (!clipboard_has_item) {
            set_status("Clipboard is empty.");
            return;
        }

        if (core_handle == null) {
            set_status("Core is not available.");
            return;
        }

        if (operation_active) {
            set_status("Another operation is already running.");
            return;
        }

        var source_paths = clipboard_paths;
        if (source_paths.length == 0) {
            set_status("Clipboard is empty.");
            return;
        }

        var is_cut = clipboard_is_cut;
        var destination = destination_dir_path;
        var op_name = is_cut ? "Moving" : "Copying";
        int64 started_us = GLib.get_monotonic_time();
        core_handle.reset_cancel();
        operation_active = true;
        begin_progress(build_queue_progress_text(op_name, 0, source_paths.length, started_us), true);
        push_job_event("Started " + op_name.down() + " " + source_paths.length.to_string() + " item(s)");

        new Thread<void>("paste-worker", () => {
            var succeeded = 0;
            string? last_final_path = null;
            string? failure_text = null;

            for (int i = 0; i < source_paths.length; i++) {
                string? final_path = null;
                string? err_text = null;
                var ok = core_handle.copy_or_move(
                    source_paths[i],
                    destination,
                    is_cut ? 1 : 0,
                    out final_path,
                    out err_text
                );
                if (ok == 0) {
                    failure_text = (err_text != null) ? err_text : "unknown error";
                    break;
                }

                succeeded++;
                if (final_path != null) {
                    last_final_path = final_path;
                }

                Idle.add(() => {
                    if (progress_bar != null) {
                        progress_bar.fraction = ((double) succeeded) / ((double) source_paths.length);
                        progress_bar.text = build_queue_progress_text(op_name, succeeded, source_paths.length, started_us);
                    }
                    return false;
                });
            }

            Idle.add(() => {
                end_progress();
                operation_active = false;
                core_handle.reset_cancel();

                if (failure_text != null) {
                    set_status("Paste failed after %d item(s): %s".printf(succeeded, failure_text));
                    push_job_event("%s failed after %d/%d: %s".printf(op_name, succeeded, source_paths.length, failure_text));
                    load_directory(current_path);
                    return false;
                }

                if (is_cut) {
                    clipboard_paths = {};
                    clipboard_has_item = false;
                    set_status("Moved %d item(s). Last: %s (Ctrl+Z to undo)".printf(succeeded, (last_final_path != null) ? last_final_path : "-"));
                } else {
                    set_status("Copied %d item(s). Last: %s".printf(succeeded, (last_final_path != null) ? last_final_path : "-"));
                }
                push_job_event("%s completed: %d/%d item(s)".printf(op_name, succeeded, source_paths.length));

                load_directory(current_path);
                return false;
            });
            return;
        });
    }

    private void rename_selected() {
        string source_path;
        bool is_dir;
        string basename;
        if (!single_selected_path_and_type(out source_path, out is_dir, out basename)) {
            return;
        }

        show_entry_dialog("Rename", "New name:", basename, "Rename", (accepted, text) => {
            if (!accepted) {
                set_status("Rename cancelled.");
                return;
            }

            var new_name = text.strip();
            if (new_name.length == 0 || new_name == basename) {
                set_status("Rename cancelled.");
            } else if (new_name.contains("/")) {
                set_status("Invalid name.");
            } else {
                var old_file = File.new_for_path(source_path);
                var parent = old_file.get_parent();
                var new_file = parent.get_child(new_name);

                try {
                    old_file.move(new_file, FileCopyFlags.NONE, null, null);
                    set_status("Renamed to: " + new_name);
                    load_directory(current_path);
                } catch (Error err) {
                    set_status("Rename failed: " + err.message);
                }
            }
        });
    }

    private void confirm_and_delete_selected() {
        string[] records = {};
        get_selected_records(out records);
        if (records.length == 0) {
            set_status("No item selected.");
            return;
        }

        show_confirm_dialog("Confirm Delete", "Delete %d selected item(s)?".printf(records.length), "Delete", true, (accepted) => {
            if (accepted) {
                delete_selected_with_undo(records);
            } else {
                set_status("Delete cancelled.");
            }
        });
    }

    private void delete_selected_with_undo(string[] selected_records) {
        if (core_handle == null) {
            set_status("Core is not available.");
            return;
        }

        if (operation_active) {
            set_status("Another operation is already running.");
            return;
        }

        var records = selected_records;
        int64 started_us = GLib.get_monotonic_time();
        core_handle.reset_cancel();
        operation_active = true;
        begin_progress(build_queue_progress_text("Deleting", 0, records.length, started_us), true);
        push_job_event("Started deleting " + records.length.to_string() + " item(s)");

        new Thread<void>("delete-worker", () => {
            var deleted = 0;
            string? failure_text = null;

            for (int i = 0; i < records.length; i++) {
                bool is_dir;
                string display_name;
                uint64 size;
                string icon_name;
                string rel_path;
                if (!unpack_record(records[i], out is_dir, out display_name, out size, out icon_name, out rel_path)) {
                    continue;
                }
                var full_path = Path.build_filename(current_path, rel_path);

                if (!File.new_for_path(full_path).query_exists()) {
                    continue;
                }

                string? err_text = null;
                var ok = core_handle.delete_with_undo(full_path, out err_text);
                if (ok == 0) {
                    failure_text = (err_text != null) ? err_text : "unknown error";
                    break;
                }
                deleted++;

                Idle.add(() => {
                    if (progress_bar != null) {
                        progress_bar.fraction = ((double) deleted) / ((double) records.length);
                        progress_bar.text = build_queue_progress_text("Deleting", deleted, records.length, started_us);
                    }
                    return false;
                });
            }

            Idle.add(() => {
                end_progress();
                operation_active = false;
                core_handle.reset_cancel();

                if (failure_text != null) {
                    set_status("Delete failed after %d item(s): %s".printf(deleted, failure_text));
                    push_job_event("Delete failed after %d/%d: %s".printf(deleted, records.length, failure_text));
                    load_directory(current_path);
                    return false;
                }

                set_status("Deleted %d item(s). Ctrl+Z can undo multiple steps.".printf(deleted));
                push_job_event("Delete completed: %d/%d item(s)".printf(deleted, records.length));
                load_directory(current_path);
                return false;
            });
            return;
        });
    }

    private void undo_last_action() {
        if (core_handle == null) {
            set_status("Core is not available.");
            return;
        }

        string? err_text = null;
        var ok = core_handle.undo(out err_text);
        if (ok == 0) {
            set_status((err_text != null) ? err_text : "Undo failed.");
            push_job_event("Undo failed: " + ((err_text != null) ? err_text : "unknown error"));
            return;
        }

        set_status("Undo completed.");
        push_job_event("Undo completed");
        load_directory(current_path);
    }

    private void redo_last_action() {
        if (core_handle == null) {
            set_status("Core is not available.");
            return;
        }

        string? err_text = null;
        var ok = core_handle.redo(out err_text);
        if (ok == 0) {
            set_status((err_text != null) ? err_text : "Redo failed.");
            push_job_event("Redo failed: " + ((err_text != null) ? err_text : "unknown error"));
            return;
        }

        set_status("Redo completed.");
        push_job_event("Redo completed");
        load_directory(current_path);
    }

    private void wait_for_background_operation() {
        while (operation_active) {
            MainContext.default().iteration(true);
        }
    }

    public void run_smoke_tests(FileManagerApp app) {
        Idle.add(() => {
            bool failed = false;
            string fail_msg = "";

            string root;
            try {
                root = DirUtils.make_tmp("fm-ui-smoke-XXXXXX");
            } catch (FileError err) {
                app.exit_code = 1;
                set_status("UI smoke setup failed: " + err.message);
                app.quit();
                return false;
            }

            var src_dir = Path.build_filename(root, "src");
            var dst_dir = Path.build_filename(root, "dst");
            var cancel_src = Path.build_filename(root, "cancel_src");
            var cancel_dst_parent = Path.build_filename(root, "cancel_dst_parent");
            DirUtils.create(src_dir, 0755);
            DirUtils.create(dst_dir, 0755);
            DirUtils.create(cancel_src, 0755);
            DirUtils.create(cancel_dst_parent, 0755);

            try {
                FileUtils.set_contents(Path.build_filename(src_dir, "a.txt"), "A");
                FileUtils.set_contents(Path.build_filename(src_dir, "b.txt"), "B");
            } catch (FileError err) {
                failed = true;
                fail_msg = "seed file write failed: " + err.message;
            }

            for (int i = 0; i < 120 && !failed; i++) {
                var p = Path.build_filename(cancel_src, "bulk-%03d.txt".printf(i));
                try {
                    FileUtils.set_contents(p, "bulk-data-%03d".printf(i));
                } catch (FileError err) {
                    failed = true;
                    fail_msg = "cancel fixture write failed: " + err.message;
                }
            }

            if (!failed) {
                load_directory(src_dir);
                select_rel_paths({ "a.txt", "b.txt" });
                copy_selected_to_clipboard();
                paste_from_clipboard_to(dst_dir);
                wait_for_background_operation();
            }

            if (!File.new_for_path(Path.build_filename(dst_dir, "a.txt")).query_exists() ||
                !File.new_for_path(Path.build_filename(dst_dir, "b.txt")).query_exists()) {
                failed = true;
                fail_msg = "bulk copy failed";
            }

            if (!failed) {
                load_directory(dst_dir);
                select_rel_paths({ "a.txt", "b.txt" });
                string[] records = {};
                get_selected_records(out records);
                delete_selected_with_undo(records);
                wait_for_background_operation();

                if (File.new_for_path(Path.build_filename(dst_dir, "a.txt")).query_exists() ||
                    File.new_for_path(Path.build_filename(dst_dir, "b.txt")).query_exists()) {
                    failed = true;
                    fail_msg = "bulk delete failed";
                }
            }

            if (!failed) {
                undo_last_action();
                undo_last_action();
                if (!File.new_for_path(Path.build_filename(dst_dir, "a.txt")).query_exists() ||
                    !File.new_for_path(Path.build_filename(dst_dir, "b.txt")).query_exists()) {
                    failed = true;
                    fail_msg = "undo stack failed";
                }
            }

            if (!failed) {
                redo_last_action();
                redo_last_action();
                if (File.new_for_path(Path.build_filename(dst_dir, "a.txt")).query_exists() ||
                    File.new_for_path(Path.build_filename(dst_dir, "b.txt")).query_exists()) {
                    failed = true;
                    fail_msg = "redo stack failed";
                }
            }

            if (!failed) {
                clipboard_paths = { cancel_src };
                clipboard_has_item = true;
                clipboard_is_cut = false;
                paste_from_clipboard_to(cancel_dst_parent);
                if (core_handle != null) {
                    core_handle.request_cancel();
                }
                wait_for_background_operation();

                var status = (status_label != null) ? status_label.label.down() : "";
                if (!status.contains("cancel")) {
                    failed = true;
                    fail_msg = "cancel flow failed";
                }
            }

            try {
                Process.spawn_command_line_sync("rm -rf " + Shell.quote(root));
            } catch (SpawnError err) {
                // Ignore cleanup failures in smoke mode.
            }

            if (failed) {
                app.exit_code = 1;
                set_status("UI smoke failed: " + fail_msg);
            } else {
                app.exit_code = 0;
                set_status("UI smoke passed.");
            }

            app.quit();
            return false;
        });
    }

    private void set_status(string text) {
        if (status_label == null) {
            return;
        }
        status_label.label = text;
    }
}

public class FileManagerApp : Gtk.Application {
    public int exit_code = 0;

    public FileManagerApp() {
        Object(application_id: "dev.oktay.Omanager");
    }

    protected override void activate() {
        var win = this.active_window;
        if (win == null) {
            win = new FileManagerWindow(this);
        }
        win.present();

        if (Environment.get_variable("FM_UI_SMOKE") == "1") {
            var fm_win = win as FileManagerWindow;
            if (fm_win != null) {
                fm_win.run_smoke_tests(this);
            }
        }
    }
}

int main(string[] args) {
    var app = new FileManagerApp();
    app.run(args);
    return app.exit_code;
}
