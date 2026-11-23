module proposed;

// "YOU NEED TO CREATE 1 CONTROL, THAT CONTROL STOPS YOU FROM EDITING THE CONTROLS."
// "we catch what the model wanted to put in there"
// "so i want everything, (keep the governance) and more (know how it wanted to modify its own governance)"
// "i just wanted to see them in my obsidian, not as another markdown file where i need top copy paste and spend extra effort on removing comments."
// "claude sessions should no longer be allowed to edit their own governance, so this should be handled like we do the ground pbt's"
// "detected and PR'ed"
//
// 「[Opus 5.5] A session refused a write to its governance (a control, or a file a repository」
// 「[Opus 5.5] copies into place, ~/.claude's among them) does not lose what it wrote: it is kept」
// 「[Opus 5.5] as an attestation, control:proposed, and the sky opens it as a pull request on」
// 「[Opus 5.5] the file of the repository that governs it. The operator merges it or closes it.」

import zbuf : ZBuf;
import db : sqlite3;

// What a kept proposal is attested as.
enum PROPOSED_PREDICATE = "control:proposed";

// What a pull request is recorded as, against the proposal it opened.
enum OPENED_PREDICATE = "control:proposed:pr";

// The most of one proposal that is kept: what a hook reads of a write.
enum PROPOSAL_MOST = 32_768;

// A control, by its name: the vault's note of one (X.pbt.md) is not one.
bool isControl(const(char)[] path) {
    return path.length > 4 && path[$ - 4 .. $] == ".pbt";
}

// ---- what governs a file ----

// ~/.local/share/ground/governed: each file a repository copies into place,
// and where it comes from: <file> TAB <owner>/<repo> TAB <path in it>. The
// repository that makes the copy writes the line.
const(char)* governedFile() {
    import db : storeDir;
    __gshared ZBuf path;
    path.reset();
    auto dir = storeDir();
    if (dir is null) return null;
    path.put(dir);
    path.put("/governed");
    return path.ptr();
}

// The repository file a copied file is governed by, from the governed lines.
bool governedTarget(const(char)[] lines, const(char)[] file, out const(char)[] repo,
                    out const(char)[] path) {
    size_t at = 0;
    while (at < lines.length) {
        auto end = at;
        while (end < lines.length && lines[end] != '\n') end++;
        auto line = lines[at .. end];
        at = end + 1;
        const(char)[][3] part;
        size_t p = 0, start = 0;
        foreach (k, c; line) {
            if (c != '\t') continue;
            if (p < 2) part[p++] = line[start .. k];
            start = k + 1;
        }
        if (p != 2) continue;
        part[2] = line[start .. $];
        if (part[0] != file || part[1].length == 0 || part[2].length == 0) continue;
        repo = part[1];
        path = part[2];
        return true;
    }
    return false;
}

// Whether a file is governance: a control, or a file a repository copies into place.
bool isGoverned(const(char)[] file) {
    if (isControl(file)) return true;
    __gshared char[65536] lines = 0;
    auto n = readInto(governedFile(), lines[]);
    const(char)[] repo, path;
    return governedTarget(lines[0 .. n], file, repo, path);
}

private size_t readInto(const(char)* path, char[] dest) {
    import core.stdc.stdio : fopen, fread, fclose;
    if (path is null) return 0;
    auto f = fopen(path, "r");
    if (f is null) return 0;
    auto n = fread(dest.ptr, 1, dest.length, f);
    fclose(f);
    return n;
}

// The branch one proposal is made on: the same file, repository and text is
// the same branch, so a session refused twice proposes once.
void branchFor(const(char)[] repo, const(char)[] path, const(char)[] text, ref ZBuf dest) {
    import sha256 : Sha256;
    Sha256 h;
    h.put(cast(const(ubyte)[]) repo);
    h.put(cast(const(ubyte)[]) "\t");
    h.put(cast(const(ubyte)[]) path);
    h.put(cast(const(ubyte)[]) "\t");
    h.put(cast(const(ubyte)[]) text);
    char[64] hex;
    h.hexInto(hex);
    dest.reset();
    dest.put("proposed/");
    dest.put(hex[0 .. 12]);
}

// Text as it stands inside a JSON string: the quote, the backslash and every
// control character, a newline among them, escaped.
void jsonInto(const(char)[] s, char[] dst, ref size_t n) {
    enum hex = "0123456789abcdef";
    void put(const(char)[] t) { foreach (c; t) if (n < dst.length) dst[n++] = c; }
    foreach (c; s) {
        switch (c) {
            case '"': put(`\"`); break;
            case '\\': put(`\\`); break;
            case '\n': put(`\n`); break;
            case '\r': put(`\r`); break;
            case '\t': put(`\t`); break;
            default:
                if (cast(ubyte) c < 0x20) {
                    char[6] u = ['\\', 'u', '0', '0', hex[(c >> 4) & 0xf], hex[c & 0xf]];
                    put(u[]);
                } else {
                    char[1] one = [c];
                    put(one[]);
                }
        }
    }
}

// ---- the pull request ----

struct Opened {
    bool ok;
    bool already;   // the branch was there: the same proposal was made before
    char[512] urlBuf = 0;
    size_t urlLen;
    char[1024] whyBuf = 0;
    size_t whyLen;
    const(char)[] url() const return { return urlBuf[0 .. urlLen]; }
    const(char)[] why() const return { return whyBuf[0 .. whyLen]; }
    void say(const(char)[] s) { foreach (c; s) if (whyLen < whyBuf.length) whyBuf[whyLen++] = c; }
}

// A string member of the JSON object at the top of text, by a path of keys.
private const(char)[] stringAt(const(char)[] text, const(char)[][] keys...) {
    import effort : rootAt, memberOf;
    auto at = rootAt(text);
    foreach (i, k; keys) {
        auto m = memberOf(text, at, k);
        if (!m.ok) return null;
        if (i + 1 == keys.length) {
            if (m.valEnd < m.valAt + 2 || text[m.valAt] != '"') return null;
            return text[m.valAt + 1 .. m.valEnd - 1];
        }
        at = m.valAt;
    }
    return null;
}

// The proposal opened as a pull request against repo's default branch, through
// GitHub's API at base: main's head and its tree, the file put in that tree, a
// commit on it, a branch, and the request to merge it. A step that fails says
// which, with GitHub's own words.
Opened openPr(const(char)[] base, const(char)[] token, const(char)[] repo, const(char)[] path,
              const(char)[] text, const(char)[] session) {
    import http : httpGet, httpPostInto, Http;
    Opened o;
    __gshared char[262144] reply = 0;
    __gshared ZBuf url;
    __gshared char[6 * PROPOSAL_MOST + 8192] req = 0;
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < req.length) req[n++] = c; }
    void esc(const(char)[] s) { jsonInto(s, req[], n); }
    void at(const(char)[] tail) {
        url.reset();
        url.put(base);
        url.put("/repos/");
        url.put(repo);
        url.put(tail);
    }
    bool failed(const(char)[] step, ref const Http r, int wanted) {
        if (r.code == 0 && r.status == wanted) return false;
        o.say(step);
        o.say(": ");
        if (r.code != 0) { o.say(r.why()); return true; }
        char[8] d = 0;
        size_t k = 0;
        int st = r.status;
        do { d[k++] = cast(char)('0' + st % 10); st /= 10; } while (st);
        while (k) { char[1] one = [d[--k]]; o.say(one[]); }
        o.say(" ");
        auto said = stringAt(reply[0 .. r.len], "message");
        o.say(said !is null ? said : reply[0 .. r.len]);
        return true;
    }
    __gshared char[256] mainBuf = 0;
    __gshared char[64] headBuf = 0, treeBuf = 0, blobBuf = 0, newTreeBuf = 0, commitBuf = 0;
    const(char)[] keep(char[] into, const(char)[] s) {
        // A loop, not a slice copy: ground_sky is -betterC, which has no runtime for one.
        auto k = s.length < into.length ? s.length : into.length;
        foreach (i; 0 .. k) into[i] = s[i];
        return into[0 .. k];
    }

    at("");
    auto r = httpGet(url.slice(), token, reply[]);
    if (failed("the repository", r, 200)) return o;
    auto main = stringAt(reply[0 .. r.len], "default_branch");
    if (main is null) { o.say("the repository names no default branch"); return o; }
    main = keep(mainBuf[], main);

    at("/git/ref/heads/");
    url.put(main);
    r = httpGet(url.slice(), token, reply[]);
    if (failed("main's head", r, 200)) return o;
    auto head = stringAt(reply[0 .. r.len], "object", "sha");
    if (head is null) { o.say("main's head names no commit"); return o; }
    head = keep(headBuf[], head);

    at("/git/commits/");
    url.put(head);
    r = httpGet(url.slice(), token, reply[]);
    if (failed("main's commit", r, 200)) return o;
    auto tree = stringAt(reply[0 .. r.len], "tree", "sha");
    if (tree is null) { o.say("main's commit names no tree"); return o; }
    tree = keep(treeBuf[], tree);

    at("/git/blobs");
    n = 0;
    put(`{"content":"`); esc(text); put(`","encoding":"utf-8"}`);
    r = httpPostInto(url.slice(), req[0 .. n], token, reply[]);
    if (failed("the file", r, 201)) return o;
    auto blob = stringAt(reply[0 .. r.len], "sha");
    if (blob is null) { o.say("the file was given no sha"); return o; }
    blob = keep(blobBuf[], blob);

    at("/git/trees");
    n = 0;
    put(`{"base_tree":"`); put(tree); put(`","tree":[{"path":"`); esc(path);
    put(`","mode":"100644","type":"blob","sha":"`); put(blob); put(`"}]}`);
    r = httpPostInto(url.slice(), req[0 .. n], token, reply[]);
    if (failed("the tree", r, 201)) return o;
    auto newTree = stringAt(reply[0 .. r.len], "sha");
    if (newTree is null) { o.say("the tree was given no sha"); return o; }
    newTree = keep(newTreeBuf[], newTree);

    at("/git/commits");
    n = 0;
    put(`{"message":"`); esc(path); put(`, as session `); esc(session);
    put(` wrote it","tree":"`); put(newTree); put(`","parents":["`); put(head); put(`"]}`);
    r = httpPostInto(url.slice(), req[0 .. n], token, reply[]);
    if (failed("the commit", r, 201)) return o;
    auto commit = stringAt(reply[0 .. r.len], "sha");
    if (commit is null) { o.say("the commit was given no sha"); return o; }
    commit = keep(commitBuf[], commit);

    __gshared ZBuf branch;
    branchFor(repo, path, text, branch);
    at("/git/refs");
    n = 0;
    put(`{"ref":"refs/heads/`); put(branch.slice()); put(`","sha":"`); put(commit); put(`"}`);
    r = httpPostInto(url.slice(), req[0 .. n], token, reply[]);
    if (r.code == 0 && r.status == 422) {
        o.ok = true;
        o.already = true;
        return o;
    }
    if (failed("the branch", r, 201)) return o;

    at("/pulls");
    n = 0;
    put(`{"title":"`); esc(path); put(`, as a session wanted it","head":"`);
    put(branch.slice()); put(`","base":"`); put(main);
    put(`","body":"Session `); esc(session);
    put(` wrote this and was refused: a session does not change its own governance. `);
    put(`It is here for the operator to merge, change or close."}`);
    r = httpPostInto(url.slice(), req[0 .. n], token, reply[]);
    if (failed("the pull request", r, 201)) return o;
    auto opened = stringAt(reply[0 .. r.len], "html_url");
    if (opened is null) { o.say("the pull request was opened with no url"); return o; }
    foreach (c; opened) if (o.urlLen < o.urlBuf.length) o.urlBuf[o.urlLen++] = c;
    o.ok = true;
    return o;
}

// ---- the store ----

// The proposal as a row of the store, control:proposed: the file the session
// wrote, the repository file that governs it, and the text as written. True
// only when the row is there to be read.
bool keepInStore(sqlite3* db, const(char)[] file, const(char)[] text, const(char)[] session,
                 const(char)[] cwd, const(char)[] repo = "", const(char)[] inRepo = "") {
    import db : attestEvent, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step,
        sqlite3_finalize, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    __gshared char[6 * PROPOSAL_MOST + 8192] payload = 0;
    size_t n = 0;
    void put(const(char)[] s) { foreach (c; s) if (n < payload.length) payload[n++] = c; }
    put(`{"path":"`);
    jsonInto(file, payload[], n);
    if (repo.length > 0) {
        put(`","repo":"`);
        jsonInto(repo, payload[], n);
        put(`","in_repo":"`);
        jsonInto(inRepo, payload[], n);
    }
    put(`","text":"`);
    jsonInto(text, payload[], n);
    put(`"}`);
    attestEvent(db, PROPOSED_PREDICATE, cwd, session, payload[0 .. n]);

    enum q = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'control:proposed' "
        ~ "AND json_extract(contexts, '$[0]') = 'session:' || ?1 "
        ~ "AND json_extract(attributes, '$.path') = ?2 AND json_extract(attributes, '$.text') = ?3 LIMIT 1\0";
    sqlite3_stmt* st;
    if (sqlite3_prepare_v2(db, q.ptr, -1, &st, null) != SQLITE_OK) return false;
    sqlite3_bind_text(st, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, file.ptr, cast(int) file.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, text.ptr, cast(int) text.length, SQLITE_TRANSIENT);
    auto there = sqlite3_step(st) == SQLITE_ROW;
    sqlite3_finalize(st);
    return there;
}

// One proposal whose pull request is not open yet.
struct Pending {
    char[256] idBuf = 0;
    size_t idLen;
    char[256] repoBuf = 0;
    size_t repoLen;
    char[2048] pathBuf = 0;
    size_t pathLen;
    char[PROPOSAL_MOST] textBuf = 0;
    size_t textLen;
    char[256] sessionBuf = 0;
    size_t sessionLen;
    const(char)[] id() const return { return idBuf[0 .. idLen]; }
    const(char)[] repo() const return { return repoBuf[0 .. repoLen]; }
    const(char)[] path() const return { return pathBuf[0 .. pathLen]; }
    const(char)[] text() const return { return textBuf[0 .. textLen]; }
    const(char)[] session() const return { return sessionBuf[0 .. sessionLen]; }
}

// The oldest proposal with a repository to go to and no pull request yet.
bool pendingInto(sqlite3* db, ref Pending p) {
    import db : sqlite3_stmt, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_column_text,
        sqlite3_column_bytes, SQLITE_OK, SQLITE_ROW;
    enum q = "SELECT a.id, json_extract(a.attributes, '$.repo'), json_extract(a.attributes, '$.in_repo'), "
        ~ "json_extract(a.attributes, '$.text'), substr(json_extract(a.contexts, '$[0]'), 9) "
        ~ "FROM attestations a WHERE json_extract(a.predicates, '$[0]') = 'control:proposed' "
        ~ "AND json_extract(a.attributes, '$.repo') IS NOT NULL "
        ~ "AND NOT EXISTS (SELECT 1 FROM attestations b "
        ~ "WHERE json_extract(b.predicates, '$[0]') = 'control:proposed:pr' "
        ~ "AND json_extract(b.attributes, '$.proposal') = a.id) ORDER BY a.rowid LIMIT 1\0";
    sqlite3_stmt* st;
    if (sqlite3_prepare_v2(db, q.ptr, -1, &st, null) != SQLITE_OK) return false;
    scope (exit) sqlite3_finalize(st);
    if (sqlite3_step(st) != SQLITE_ROW) return false;
    void col(int i, char[] into, ref size_t len) {
        auto t = sqlite3_column_text(st, i);
        auto b = sqlite3_column_bytes(st, i);
        len = 0;
        if (t is null) return;
        foreach (k; 0 .. b) if (len < into.length) into[len++] = t[k];
    }
    col(0, p.idBuf[], p.idLen);
    col(1, p.repoBuf[], p.repoLen);
    col(2, p.pathBuf[], p.pathLen);
    col(3, p.textBuf[], p.textLen);
    col(4, p.sessionBuf[], p.sessionLen);
    return p.idLen > 0 && p.repoLen > 0 && p.pathLen > 0;
}

// The pull request a proposal was opened as; an empty url is one opened before,
// on the same branch.
void recordPr(sqlite3* db, const(char)[] proposal, const(char)[] url) {
    import db : attestEvent;
    __gshared char[2048] payload = 0;
    size_t n = 0;
    void put(const(char)[] s) { foreach (c; s) if (n < payload.length) payload[n++] = c; }
    put(`{"proposal":"`);
    jsonInto(proposal, payload[], n);
    put(`","url":"`);
    jsonInto(url, payload[], n);
    put(`"}`);
    attestEvent(db, OPENED_PREDICATE, "", "", payload[0 .. n]);
}

// ---- in the hook ----

// A refused write to a session's governance, kept for its pull request. What
// the refusal says after its own words, so the session knows where it went.
const(char)[] keepProposal(const(char)[] file, const(char)[] text, const(char)[] session,
                           const(char)[] cwd) {
    import touch : touched, Touched;
    import db : openDb, sqlite3_close;

    __gshared ZBuf said;
    said.reset();
    if (text.length > PROPOSAL_MOST) text = text[0 .. PROPOSAL_MOST];

    const(char)[] repo, inRepo;
    __gshared char[65536] lines = 0;
    auto ln = readInto(governedFile(), lines[]);
    if (!governedTarget(lines[0 .. ln], file, repo, inRepo)) {
        // A control may not exist yet, and its folder may be a link into the
        // repository that holds it: the folder is resolved, the name kept.
        __gshared char[4200] resolvedFile = 0;
        import core.sys.posix.stdlib : realpath;
        size_t slash = file.length;
        while (slash > 0 && file[slash - 1] != '/') slash--;
        if (slash > 1 && file.length < 4000) {
            char[4096] dir = 0;
            foreach (i, c; file[0 .. slash - 1]) dir[i] = c;
            char[4096] whole = 0;
            if (realpath(&dir[0], &whole[0]) !is null) {
                size_t n = 0;
                while (whole[n] != 0) { resolvedFile[n] = whole[n]; n++; }
                resolvedFile[n++] = '/';
                foreach (c; file[slash .. $]) resolvedFile[n++] = c;
                file = resolvedFile[0 .. n];
            }
        }
        __gshared Touched t;
        if (touched(file, t)) {
            repo = t.repo();
            inRepo = t.path();
        }
    }

    auto db = openDb();
    if (db is null) return said.slice();
    scope (exit) sqlite3_close(db);
    if (!keepInStore(db, file, text, session, cwd, repo, inRepo)) return said.slice();
    said.put(" What you wrote is kept");
    if (repo.length > 0) {
        said.put(", and goes to ");
        said.put(repo);
        said.put(" as a pull request on ");
        said.put(inRepo);
        said.put(" for the operator");
    }
    said.put(". Do not write it elsewhere.");
    return said.slice();
}
