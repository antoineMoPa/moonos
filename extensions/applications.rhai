//! The desktop applications this machine has installed: start one in a frame of the window

// Where the desktop entries of this machine live: an `applications` folder under each of the
// XDG data folders, the user's own first, so an entry they wrote takes the place of the system
// one of the same file name. This is where flatpak and snap put theirs too - each adds its
// exports folder to `XDG_DATA_DIRS` - so there is no list of package managers to keep here.
//
// The defaults are the spec's, for a session that set neither variable.
fn entry_dirs() {
    let said = run("sh", [
        "-c",
        `printf %s "\${XDG_DATA_HOME:-$HOME/.local/share}:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"`,
    ]);
    if !said.ok {
        throw `could not read the XDG data folders: ${said.stderr}`;
    }
    let dirs = [];
    for dir in said.stdout.split(":") {
        if dir != "" {
            dirs.push(join_path(dir, "applications"));
        }
    }
    dirs
}

// What each key does, by name. `act` is where each name is carried out.
//
// Not called `keys`: a function of a script takes the place of Rhai's method of the same name,
// and `map.keys()` would then answer with this.
fn key_bindings() {
    #{
        "n": "down", "j": "down", "Down": "down",
        "p": "up", "k": "up", "Up": "up",
        "Enter": "start",
        "o": "start",
        "t": "terminal",
        "g": "refresh",
    }
}

// The `%` codes an Exec line may carry, which stand for the files or urls the entry was opened
// with. Nothing is being opened with it here, so each one is dropped. See the Desktop Entry
// spec, "The Exec key".
fn exec_codes() {
    ["%f", "%F", "%u", "%U", "%i", "%c", "%k", "%v", "%m", "%d", "%D", "%n", "%N"]
}

// The categories worth showing beside a name, shortened to what tells two entries apart. A
// category not here is left out of the column.
fn category_labels() {
    #{
        AudioVideo: "media",
        Audio: "audio",
        Video: "video",
        Development: "dev",
        Education: "education",
        Game: "game",
        Graphics: "graphics",
        Network: "network",
        Office: "office",
        Science: "science",
        Settings: "settings",
        System: "system",
        Utility: "utility",
        TerminalEmulator: "terminal",
    }
}

// The lines of one `[Desktop Entry]` group, as a map of its keys. Only the first group is read -
// an entry's actions (`[Desktop Action new-window]`) are groups of their own after it - and only
// the unlocalized keys: `Name[fr]` is a translation of `Name`, which the window has no use for.
fn entry_keys(text) {
    let fields = #{};
    let in_entry = false;
    for line in text.split("\n") {
        line.trim();
        if line.starts_with("#") || line == "" {
            continue;
        }
        if line.starts_with("[") {
            if in_entry {
                break;
            }
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let at = line.index_of("=");
        if at < 0 {
            continue;
        }
        let key = line.sub_string(0, at);
        key.trim();
        if key.contains("[") {
            continue;
        }
        let value = line.sub_string(at + 1);
        value.trim();
        fields[key] = value;
    }
    fields
}

// What `Terminal=`, `NoDisplay=` and `Hidden=` say. The spec's booleans are the two words
// spelled in full and in lower case; anything else is false.
fn says_true(fields, key) {
    key in fields && fields[key] == "true"
}

fn field(fields, key, fallback) {
    if key in fields { fields[key] } else { fallback }
}

// The command an entry starts, as the program and its arguments, with the `%` codes dropped.
//
// The spec quotes an argument that holds a space with `"`, and escapes with `\`, the way `sh`
// does: `printf` per word is the shell's own splitting.
fn exec_words(exec) {
    let stripped = exec;
    for code in global::EXEC_CODES {
        stripped.replace(code, "");
    }
    let said = run("sh", ["-c", `for w in ${stripped}; do printf '%s\n' "$w"; done`]);
    if !said.ok {
        return [];
    }
    let words = [];
    for word in said.stdout.split("\n") {
        if word != "" {
            words.push(word);
        }
    }
    words
}

// The short categories of an entry, in the order `category_labels` lists them, so that two
// entries read the same way.
fn short_categories(fields) {
    if !("Categories" in fields) {
        return "";
    }
    let theirs = fields.Categories.split(";");
    let shown = "";
    for name in global::CATEGORY_LABELS.keys() {
        if theirs.contains(name) {
            if shown != "" {
                shown += " ";
            }
            shown += global::CATEGORY_LABELS[name];
        }
    }
    shown
}

// One entry of the list, read from its file. `()` when the file is not an application to show:
// the spec's `Type` is something else, it asks not to be displayed, or it has no `Exec` to run.
fn read_entry(path) {
    let text = read_file(path);
    let fields = entry_keys(text);
    if field(fields, "Type", "") != "Application" {
        return ();
    }
    if says_true(fields, "NoDisplay") || says_true(fields, "Hidden") {
        return ();
    }
    if !("Exec" in fields) {
        return ();
    }
    let words = exec_words(fields.Exec);
    if words.is_empty() {
        return ();
    }
    #{
        id: name_of(path),
        name: field(fields, "Name", name_of(path)),
        comment: field(fields, "Comment", ""),
        categories: short_categories(fields),
        program: words[0],
        args: words.extract(1),
        in_terminal: says_true(fields, "Terminal"),
    }
}

// Every entry of every folder, by name, with the folders searched in `entry_dirs` order: the
// first folder to hold a file name is the one whose entry is kept, so an entry the user wrote
// in `~/.local/share/applications` takes the place of the system one.
fn read_entries() {
    let by_id = #{};
    for dir in entry_dirs() {
        let entries = [];
        try {
            entries = read_dir(dir);
        } catch {
            continue;
        }
        for file in entries {
            if file.is_dir || !file.name.ends_with(".desktop") {
                continue;
            }
            if file.name in by_id {
                continue;
            }
            let entry = ();
            try {
                entry = read_entry(file.path);
            } catch (error) {
                print(`applications: ${file.path}: ${error}`);
                continue;
            }
            if entry != () {
                by_id[file.name] = entry;
            }
        }
    }
    let listed = [];
    for id in by_id.keys() {
        listed.push(by_id[id]);
    }
    listed.sort(|a, b| if a.name.to_lower() < b.name.to_lower() { -1 } else { 1 });
    listed
}

// Whether an entry passes what is typed in the filter box: every word of it, in any case,
// somewhere in its name, its command, what it is for, or its categories.
fn passes(entry, query) {
    let about = `${entry.name} ${entry.program} ${entry.comment} ${entry.categories}`.to_lower();
    for word in query.to_lower().split(" ") {
        if word != "" && !about.contains(word) {
            return false;
        }
    }
    true
}

const EXEC_CODES = exec_codes();
const CATEGORY_LABELS = category_labels();

fn init(project_root) {
    let state = #{
        // Every entry read from disk, and the ones of them the filter box lets through - which
        // are what the table shows, and what `selected` counts in.
        listed: [],
        entries: [],
        query: "",
        selected: 0,
    };
    state.reread();
    state
}

fn reread() {
    this.listed = read_entries();
    this.refilter();
}

fn refilter() {
    let showing = [];
    for entry in this.listed {
        if passes(entry, this.query) {
            showing.push(entry);
        }
    }
    this.entries = showing;
    if this.selected >= this.entries.len() {
        this.selected = if this.entries.is_empty() { 0 } else { this.entries.len() - 1 };
    }
}

fn on_key(key) {
    let bound = key_bindings();
    if key in bound {
        this.act(bound[key]);
    }
}

fn update(event) {
    if "select" in event {
        this.selected = event.select;
    }
    if "filter" in event {
        this.query = event.value;
        this.selected = 0;
        this.refilter();
    }
    if "act" in event {
        this.act(event.act);
    }
    if "started" in event {
        let said = event.result;
        if !said.ok {
            print(`applications: ${event.name}: ${said.stderr}`);
        }
    }
}

fn act(what) {
    if what == "refresh" {
        this.reread();
        return;
    }
    if what == "down" {
        if this.selected + 1 < this.entries.len() {
            this.selected += 1;
        }
        return;
    }
    if what == "up" {
        if this.selected > 0 {
            this.selected -= 1;
        }
        return;
    }
    if this.entries.is_empty() {
        return;
    }
    let entry = this.entries[this.selected];
    if what == "start" {
        this.start(entry);
    }
    if what == "terminal" {
        open_shell(this.command_line(entry));
    }
    if what == "copy" {
        copy(this.command_line(entry));
    }
}

// The entry's command as one line for a shell, which is how an entry that asks for a terminal
// is started, and what `t` does to any of them.
fn command_line(entry) {
    let line = shell_quote(entry.program);
    for arg in entry.args {
        line += ` ${shell_quote(arg)}`;
    }
    line
}

// Starting an application means running its command and leaving it: the window it opens is
// caught by the launcher, which puts it in a frame of this window - see `moon_launcher`. An
// entry that asks for a terminal has no window of its own, so it gets a shell pane instead.
//
// `run_then` stops what it starts at its timeout, so the program is started in the background
// of a shell that exits as soon as it has started it.
fn start(entry) {
    if entry.in_terminal {
        open_shell(this.command_line(entry));
        return;
    }
    let detached = `${this.command_line(entry)} >/dev/null 2>&1 &`;
    // Nothing is said about having started it: the window arriving in a frame of its own is
    // the only news there is, and it says it better.
    run_then("sh", ["-c", detached], #{ started: true, name: entry.name });
}

fn view() {
    let rows = [];
    let at = 0;
    for entry in this.entries {
        rows.push(#{
            cells: [
                text(entry.name, #{ strong: at == this.selected }),
                muted(entry.categories),
                text(entry.comment, #{ small: true }),
            ],
            selected: at == this.selected,
            on_click: #{ select: at },
            on_double_click: #{ select: at, act: "start" },
            menu: [
                #{ label: "Start", event: #{ select: at, act: "start" } },
                #{ label: "Start in a shell", event: #{ select: at, act: "terminal" } },
                #{ label: "Copy the command", event: #{ select: at, act: "copy" } },
            ],
        });
        at += 1;
    }
    column([
        heading(`${this.entries.len()} applications`),
        input("filter", this.query, "filter applications", #{ filter: true }, #{ focus: true }),
        row([
            button("start", #{ act: "start" }, this.entries.is_empty()),
            button("start in a shell", #{ act: "terminal" }, this.entries.is_empty()),
            button("read again", #{ act: "refresh" }),
        ]),
        table(["application", "kind", "what it is for"], rows),
    ])
}
