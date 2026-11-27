module standing;

// "more elegant would be"
// "to just take into account the worktree"
// "and make it clear that that ground is active for that worktree"
// "so lock it in"
//
// 「[Opus 5.5] The worktree a session stands in decides which ground that session runs. Nothing is」
// 「[Opus 5.5] forbidden, nothing is switched back afterwards, and the machine's ground is never」
// 「[Opus 5.5] touched. `make install` in a worktree puts its ground in <worktree>/.ground. Each」
// 「[Opus 5.5] program the machine starts by name hands itself over to that worktree's program of」
// 「[Opus 5.5] the same name when it is started standing in that worktree; Claude Code starts a」
// 「[Opus 5.5] hook where its session stands.」

import core.stdc.stdlib : getenv;

enum BIN = "/.ground/bin/";
version (OSX) enum SAND_FILE = "libground_sand.dylib";
else enum SAND_FILE = "libground_sand.so";

// 「[Opus 5.5] The top of the git worktree dir stands in: the nearest directory up whose .git is a file.」
// 「[Opus 5.5] A .git that is a directory is a checkout of its own, and nothing is returned.」
const(char)[] worktreeOf(const(char)[] dir, char[] buf) {
    import core.sys.posix.sys.stat : stat, stat_t, S_IFMT, S_IFDIR, S_IFREG;
    enum dotgit = "/.git";
    size_t n = dir.length;
    while (n > 1 && dir[n - 1] == '/') n--;
    while (n > 0 && dir[0] == '/') {
        if (n + dotgit.length + 1 > buf.length) return buf[0 .. 0];
        size_t at = n == 1 ? 0 : n;         // the root's .git is "/.git"
        foreach (i, c; dir[0 .. at]) buf[i] = c;
        foreach (i, c; dotgit) buf[at + i] = c;
        buf[at + dotgit.length] = 0;
        stat_t st;
        if (stat(buf.ptr, &st) == 0) {
            if ((st.st_mode & S_IFMT) == S_IFREG) { buf[at] = 0; return buf[0 .. at]; }
            if ((st.st_mode & S_IFMT) == S_IFDIR) return buf[0 .. 0];
        }
        if (n == 1) break;
        while (n > 1 && dir[n - 1] != '/') n--;
        if (n > 1) n--;
    }
    return buf[0 .. 0];
}

// 「[Opus 5.5] The worktree a program at path is the ground of: path is <worktree>/.ground/bin/<name>.」
const(char)[] worktreeOfProgram(const(char)[] path) {
    size_t dir = path.length;
    while (dir > 0 && path[dir - 1] != '/') dir--;
    auto at = path[0 .. dir];
    if (at.length <= BIN.length || at[$ - BIN.length .. $] != BIN) return path[0 .. 0];
    return at[0 .. $ - BIN.length];
}

// 「[Opus 5.5] The worktree whose ground is running, or nothing when it is the machine's.」
const(char)[] worktreeOfSelf() {
    import ritual.command : ownBinary;
    return worktreeOfProgram(ownBinary());
}

// 「[Opus 5.5] Called first by each program the machine starts by name. Standing in a worktree that holds a」
// 「[Opus 5.5] ground of its own, the process becomes that ground's program of the same name, with the same」
// 「[Opus 5.5] arguments and the same stdin. A worktree's own program takes its worktree's sand.」
void standWhereStarted(const(char)* name, const(char)** argv) {
    import core.sys.posix.unistd : getcwd, access, X_OK, execv;
    import core.sys.posix.stdlib : realpath;
    import core.stdc.stdio : fprintf, stderr;
    import ritual.command : ownBinary;

    auto self = ownBinary();
    auto mine = worktreeOfProgram(self);
    if (mine.length > 0) {
        holdSandOf(mine);
        return;
    }

    __gshared char[4096] cwd = 0;
    __gshared char[4096] top = 0;
    __gshared char[4096] target = 0;
    if (getcwd(cwd.ptr, cwd.length) is null) return;
    size_t cl = 0;
    while (cwd[cl] != 0) cl++;
    auto wt = worktreeOf(cwd[0 .. cl], top[]);
    if (wt.length == 0) return;
    size_t nl = 0;
    while (name[nl] != 0) nl++;
    if (wt.length + BIN.length + nl + 1 > target.length) return;
    size_t t = 0;
    foreach (c; wt) target[t++] = c;
    foreach (c; BIN) target[t++] = c;
    foreach (c; name[0 .. nl]) target[t++] = c;
    target[t] = 0;
    if (access(target.ptr, X_OK) != 0) return;

    // 「[Opus 5.5] Already that program, by whatever path it was started: it stays.」
    __gshared char[4096] selfZ = 0;
    __gshared char[4096] a = 0;
    __gshared char[4096] b = 0;
    if (self.length > 0 && self.length < selfZ.length) {
        foreach (i, c; self) selfZ[i] = c;
        selfZ[self.length] = 0;
        if (realpath(selfZ.ptr, a.ptr) !is null && realpath(target.ptr, b.ptr) !is null) {
            size_t i = 0;
            while (a[i] != 0 && a[i] == b[i]) i++;
            if (a[i] == 0 && b[i] == 0) return;
        }
    }
    execv(target.ptr, cast(char**) argv);
    fprintf(stderr, "ground: this worktree's ground at %s did not start; the machine's runs\n", target.ptr);
}

// 「[Opus 5.5] GROUND_SAND names the worktree's sand, unless the turn named one already.」
private void holdSandOf(const(char)[] top) {
    import core.sys.posix.unistd : access, F_OK;
    import core.sys.posix.stdlib : setenv;
    import comet : SAND_VAR;
    auto named = getenv(SAND_VAR.ptr);
    if (named !is null && named[0] != 0) return;
    __gshared char[4096] sand = 0;
    enum mid = "/.ground/sand/";
    if (top.length + mid.length + SAND_FILE.length + 1 > sand.length) return;
    size_t n = 0;
    foreach (c; top) sand[n++] = c;
    foreach (c; mid) sand[n++] = c;
    foreach (c; SAND_FILE) sand[n++] = c;
    sand[n] = 0;
    if (access(sand.ptr, F_OK) != 0) return;
    setenv(SAND_VAR.ptr, sand.ptr, 1);
}

// 「[Opus 5.5] What a session is told at its start: which ground runs for it, and that it is a worktree's.」
void sayWhichGround(Put)(ref Put ctx) {
    import db : versionString;
    auto wt = worktreeOfSelf();
    ctx.put("ground ");
    ctx.put(versionString());
    if (wt.length > 0) {
        ctx.put(" is active for this session: the ground installed in the worktree ");
        ctx.put(wt);
        ctx.put(", which runs only for sessions standing in it. The machine's ground is untouched.");
    } else {
        ctx.put(" is active for this session: the machine's.");
    }
}

// "right, to me it makes sense a session should know, but opportunistically,"
// "so we dont force it via a stop, it comes with one of the tool uses pre or post"
// 「[Opus 5.5] What a session was last told about its ground is kept beside its key, as `ground`. A」
// 「[Opus 5.5] session that moves into another tree runs that tree's ground from its next hook on, and」
// 「[Opus 5.5] the next tool use tells it; one that is told what it was told already hears nothing.」
const(char)* toldFile(const(char)[] sessionId) {
    import naming : sessionKeyFile;
    __gshared char[1024] path = 0;
    auto key = sessionKeyFile(sessionId);
    if (key is null) return null;
    size_t n = 0;
    while (key[n] != 0) n++;
    if (n < 3 || n + 4 > path.length) return null;
    // 「[Opus 5.5] <home>/.qntx/sessions/<id>/key → <home>/.qntx/sessions/<id>/ground」
    size_t dir = n;
    while (dir > 0 && key[dir - 1] != '/') dir--;
    foreach (i; 0 .. dir) path[i] = key[i];
    enum name = "ground";
    foreach (i, c; name) path[dir + i] = c;
    path[dir + name.length] = 0;
    return path.ptr;
}

// 「[Opus 5.5] Keeps line as what the session was told about its ground.」
void keepTold(const(char)[] sessionId, const(char)[] line) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    import db : mkdir;
    auto at = toldFile(sessionId);
    if (at is null) return;
    __gshared char[1024] dir = 0;
    size_t n = 0;
    while (at[n] != 0) n++;
    foreach (i; 0 .. n) dir[i] = at[i];
    // 「[Opus 5.5] its two directories, from the outer one in」
    size_t cut = n;
    while (cut > 0 && dir[cut - 1] != '/') cut--;
    size_t outer = cut - 1;
    while (outer > 0 && dir[outer - 1] != '/') outer--;
    dir[outer - 1] = 0; cast(void) mkdir(dir.ptr, 493); dir[outer - 1] = '/';
    dir[cut - 1] = 0;  cast(void) mkdir(dir.ptr, 493); dir[cut - 1] = '/';
    auto f = fopen(at, "w");
    if (f is null) return;
    fwrite(line.ptr, 1, line.length, f);
    fclose(f);
}

// 「[Opus 5.5] Whether line is other than what the session was last told about its ground.」
bool toldOtherwise(const(char)[] sessionId, const(char)[] line) {
    import core.stdc.stdio : fopen, fread, fclose;
    auto at = toldFile(sessionId);
    if (at is null) return false;
    auto f = fopen(at, "r");
    if (f is null) return true;
    __gshared char[4096] kept = 0;
    auto n = fread(kept.ptr, 1, kept.length, f);
    fclose(f);
    return kept[0 .. n] != line;
}
