module direct;

// "Q should never be used for backfill type ops"
// "its really important the stream ground produces stops hammering the box"
// "k should be delegating auth to the node entirely to q"
// The operator's choice for both: "q signs, data direct".
//
// 「[Fable 5.2] A kept transcript line goes to a node only directly (db.d, DIRECT_ONLY). The node」
// 「[Fable 5.2] admits only its primary's word, so the primary is asked for its signature and」
// 「[Fable 5.2] nothing else (QNTX server/auth/peers.go, POST /n/<name>): one signature a batch,」
// 「[Fable 5.2] spent once at the node. The lines are read from the files they were kept from,」
// 「[Fable 5.2] under the ids the store holds them by, and how far each file was sent is kept」
// 「[Fable 5.2] beside the store. The store's write lock is never taken here.」

import zbuf : ZBuf;
import db : sqlite3;
import stream : SKELETON_SQL;

private enum DIRECT_ONLY_TEXT = () { import db : DIRECT_ONLY; import std.conv : to; return DIRECT_ONLY.to!string; }();

// The node refuses a request body larger than this (stream.d, NODE_BODY_CAP).
enum BODY_CAP = 10 * 1024 * 1024;

// The most rows one batch carries, and the most of a file read for one.
enum BATCH_ROWS = 256;
enum READ_MOST = 4 * 1024 * 1024;

// "its really important the stream ground produces stops hammering the box"
// 600 lines a second, in batches of megabytes, stopped k's node: "the
// operational store did not answer in 1m0s" (2026-11-21T14:59Z). A batch takes
// no more rows once it is past BATCH_BYTES, and the wait after one is twice
// what the node took to answer it: the node gives this a third of its time at most.
enum BATCH_BYTES = 256 * 1024;

// Paced by twice the node's answer time, k's node still stopped (2026-11-21
// 17:11Z); it was at 49% I/O wait with nothing sent to it. A batch is sixteen
// lines of at most 64 KB together, and a node that takes more than two seconds
// over one is busy: the pass ends there, and nothing more is sent until the
// caller comes back. What this adds to a node in trouble is one small write.
enum TRICKLE_ROWS = 16;
enum TRICKLE_BYTES = 64 * 1024;
enum BUSY_US = 2_000_000;

// At night k took 2.3 s over 256 rows, 9 ms a row, and each such batch rested
// the stream ten minutes (2026-11-21T23:19Z..00:01Z). Busy is sixteen rows
// slower than BUSY_US, or any batch slower than BUSY_MOST_US.
enum BUSY_MOST_US = 10_000_000;

bool nodeBusy(long tookUs, long rows) {
    if (tookUs > BUSY_MOST_US) return true;
    return rows <= TRICKLE_ROWS && tookUs > BUSY_US;
}

// "considering there will be stretches where k wont be ringing the bell, as in,
// no deploys during the night"
// A pass starts at a full batch (Pace). A batch the node answers in under FAST_US is
// followed by one twice its size, up to BATCH_ROWS and BATCH_BYTES; a batch it
// is busy over brings the next back to the trickle.
enum FAST_US = 500_000;

// k writes a batch at once: 16 rows came in at 8-43 rows/s, 256 at 59-710
// (k's put= times, 2026-11-22). A pass starts at a full batch.
struct Pace {
    long rows = BATCH_ROWS;
    size_t bytes = BATCH_BYTES;
}

void paceAfter(ref Pace p, long tookUs) {
    if (nodeBusy(tookUs, p.rows)) {
        p.rows = TRICKLE_ROWS;
        p.bytes = TRICKLE_BYTES;
        return;
    }
    if (tookUs > BUSY_US) {
        // Slow over a large batch: the next is half of it.
        p.rows = p.rows / 2 < TRICKLE_ROWS ? TRICKLE_ROWS : p.rows / 2;
        p.bytes = p.bytes / 2 < TRICKLE_BYTES ? TRICKLE_BYTES : p.bytes / 2;
        return;
    }
    if (tookUs >= FAST_US) return;
    p.rows = p.rows * 2 > BATCH_ROWS ? BATCH_ROWS : p.rows * 2;
    p.bytes = p.bytes * 2 > BATCH_BYTES ? BATCH_BYTES : p.bytes * 2;
}

// "keep sending without resting on slow batches, since a slow batch still lands"
// (Cumulus, from k's log, 2026-11-22, after k's store moved to its own disk).
// A slow batch makes the next one small (paceAfter); only a batch that did not
// land ends the pass, and that rests the node.
bool endsPass(bool landed, long tookUs, long rows) {
    return !landed;
}

// How long to wait after a batch the node took `tookUs` to answer, in microseconds.
long waitAfter(long tookUs) {
    auto w = tookUs * 2;
    if (w < 250_000) return 250_000;
    if (w > 30_000_000) return 30_000_000;
    return w;
}

struct Batch {
    char[BODY_CAP] data = 0;
    size_t len;
    long rows;
    long end;  // the file's offset after the last line taken
    bool over; // a put ran past the body the node takes
    long[BATCH_ROWS] starts; // where each row's line starts in the file
    long refusedAt;          // where the line the node refused starts
    void reset() { len = 0; rows = 0; end = 0; over = false; }
    void put(const(char)[] s) {
        foreach (c; s) { if (len < data.length) data[len++] = c; else over = true; }
    }
    void putNum(long v) {
        char[24] d = 0;
        int n = 0;
        if (v == 0) { put("0"); return; }
        if (v < 0) { put("-"); v = -v; }
        while (v > 0 && n < 23) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. n) put(d[i .. i + 1]);
    }
    const(char)[] slice() const return { return data[0 .. len]; }
}

// What the primary answered a request for its signature with: the
// Authorization to present at the node, or nothing when it gave none.
const(char)[] authorizationOf(const(char)[] reply) {
    import parse : extractJsonString;
    __gshared char[4096] buf = 0;
    auto a = extractJsonString(reply, `"authorization"`, &buf[0], buf.length);
    return a is null ? "" : a;
}

// How far a file has been sent, from the lines ground keeps of it:
// <path> TAB <offset>, the last said for a file standing.
long sentUpTo(const(char)[] lines, const(char)[] path) {
    long best = 0;
    size_t at = 0;
    while (at < lines.length) {
        auto end = at;
        while (end < lines.length && lines[end] != '\n') end++;
        auto line = lines[at .. end];
        at = end + 1;
        size_t tab = line.length;
        while (tab > 0 && line[tab - 1] != '\t') tab--;
        if (tab == 0 || line[0 .. tab - 1] != path) continue;
        long v = 0;
        foreach (c; line[tab .. $]) { if (c < '0' || c > '9') { v = -1; break; } v = v * 10 + (c - '0'); }
        if (v >= 0) best = v;
    }
    return best;
}

private void putJson(ref Batch b, const(char)[] s) {
    import proposed : jsonInto;
    auto before = b.len;
    jsonInto(s, b.data[], b.len);
    // jsonInto stops at the end of the buffer without saying so.
    if (b.len == b.data.length && before + s.length >= b.data.length) b.over = true;
}

// The whole lines of `content`, which starts at byte `base` of `path`, as the
// rows the store holds of them (transcript.d): the same id, so a line that
// reached the node another way is the same row there. At most `most` rows, and
// no row that would take the list past what the node takes.
void batchFrom(ref Batch b, const(char)[] content, long base, const(char)[] path,
               const(char)[] session, long now, long most, size_t mostBytes = BODY_CAP) {
    import parse : extractJsonString;
    import collected : epochOf;
    b.reset();
    b.end = base;
    b.put("[");
    size_t at = 0;
    while (at < content.length && b.rows < most) {
        // One row always; no more once the batch is past its bytes.
        if (b.rows > 0 && b.len >= mostBytes) break;
        auto e = at;
        while (e < content.length && content[e] != '\n') e++;
        if (e == content.length) break;
        auto line = content[at .. e];

        long when = now;
        {
            __gshared char[64] stamp = 0;
            auto t = extractJsonString(line, `"timestamp"`, &stamp[0], stamp.length);
            if (t !is null) {
                auto at_ = epochOf(t);
                if (at_ >= 0) when = at_;
            }
        }

        auto mark = b.len;
        if (b.rows > 0) b.put(",");
        b.put(`{"id":"ground:transcript:`);
        putJson(b, path);
        b.put(":");
        b.putNum(base + cast(long) at);
        b.put(`","subjects":["session:`);
        putJson(b, session);
        b.put(`"],"predicates":["transcript:line"],"contexts":["session:`);
        putJson(b, session);
        b.put(`"],"actors":["ground"],"timestamp":`);
        b.putNum(when);
        b.put(`,"source":"ground","attributes":{"path":"`);
        putJson(b, path);
        b.put(`","offset":`);
        b.putNum(base + cast(long) at);
        b.put(`,"end":`);
        b.putNum(base + cast(long) e + 1);
        b.put(`,"line":"`);
        putJson(b, line);
        b.put(`"}}`);
        // One more byte is the list's own end.
        if (b.over || b.len + 1 > b.data.length) {
            b.len = mark;
            b.over = false;
            break;
        }
        if (b.rows < b.starts.length) b.starts[b.rows] = base + cast(long) at;
        b.rows++;
        at = e + 1;
        b.end = base + cast(long) at;
    }
    b.put("]");
}

// ---- the hook rows set aside ----

// "i want all agent traces"
// The hook rows set aside from the stream through q (db.d, DIRECT_ONLY) go to
// the node directly as well. How far they were sent is kept beside the files',
// under this name, as the last rowid sent; a refused row is stuck the same way.
enum STORE_KEY = "store:attestations";

// The shape the stream gives a row (stream.d): a tool's output stays home.
enum SET_ASIDE_SQL = "SELECT rowid, json_object('id', id, 'subjects', json(subjects), 'predicates', json(predicates), "
    ~ "'contexts', json(contexts), 'actors', json(actors), "
    ~ "'timestamp', CAST(strftime('%s', timestamp) AS INTEGER), 'source', source, "
    ~ "'attributes', json(" ~ SKELETON_SQL ~ ")) "
    ~ "FROM attestations WHERE rowid > ?1 AND qntx_at = " ~ DIRECT_ONLY_TEXT ~ " "
    ~ "AND json_extract(predicates, '$[0]') != 'transcript:line' ORDER BY rowid LIMIT ?2\0";

// The set-aside rows after rowid `after`, at most `most` and no more once past
// `mostBytes`, into `b`: starts are their rowids, end the last one taken.
void rowsBatch(sqlite3* db, ref Batch b, long after, long most, size_t mostBytes) {
    import db : sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_int64, sqlite3_step,
        sqlite3_column_int64, sqlite3_column_text, sqlite3_finalize, SQLITE_OK, SQLITE_ROW;
    b.reset();
    b.end = after;
    b.put("[");
    scope (exit) b.put("]");
    enum sql = SET_ASIDE_SQL;
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    scope (exit) sqlite3_finalize(stmt);
    sqlite3_bind_int64(stmt, 1, after);
    sqlite3_bind_int64(stmt, 2, most);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (b.rows > 0 && b.len >= mostBytes) break;
        auto rowid = sqlite3_column_int64(stmt, 0);
        auto text = sqlite3_column_text(stmt, 1);
        if (text is null) continue;
        size_t n = 0;
        while (text[n] != 0) n++;
        auto mark = b.len;
        if (b.rows > 0) b.put(",");
        b.put((cast(const(char)*) text)[0 .. n]);
        if (b.over || b.len + 1 > b.data.length) {
            b.len = mark;
            b.over = false;
            break;
        }
        if (b.rows < b.starts.length) b.starts[b.rows] = rowid;
        b.rows++;
        b.end = rowid;
    }
}

// ---- a file the node refused a line of ----

// How long a file waits at a line the node refused before the line is asked again.
enum STUCK_WAIT = 3600;

// When a file was last refused at this offset, from the lines ground keeps:
// <path> TAB <offset> TAB <unix time>, the last said for a file standing.
// 0 when it is not stuck there.
long stuckAt(const(char)[] lines, const(char)[] path, long offset) {
    long when = 0;
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
        if (part[0] != path) continue;
        long num(const(char)[] t) {
            long v = 0;
            if (t.length == 0) return -1;
            foreach (c; t) { if (c < '0' || c > '9') return -1; v = v * 10 + (c - '0'); }
            return v;
        }
        when = num(part[1]) == offset ? num(part[2]) : 0;
        if (when < 0) when = 0;
    }
    return when;
}

// ~/.local/share/ground/direct-stuck.
const(char)* stuckFile() {
    import db : storeDir;
    __gshared ZBuf path;
    path.reset();
    auto dir = storeDir();
    if (dir is null) return null;
    path.put(dir);
    path.put("/direct-stuck");
    return path.ptr();
}

private void recordStuck(const(char)[] path, long offset, long now) {
    import core.stdc.stdio : fopen, fprintf, fclose;
    auto at = stuckFile();
    if (at is null) return;
    auto f = fopen(at, "a");
    if (f is null) return;
    fprintf(f, "%.*s\t%lld\t%lld\n", cast(int) path.length, path.ptr, offset, now);
    fclose(f);
}

// ---- how far each file was sent ----

// ~/.local/share/ground/direct-sent: <path> TAB <offset>, a line a batch.
const(char)* sentFile() {
    import db : storeDir;
    __gshared ZBuf path;
    path.reset();
    auto dir = storeDir();
    if (dir is null) return null;
    path.put(dir);
    path.put("/direct-sent");
    return path.ptr();
}

private void recordSent(const(char)[] path, long offset) {
    import core.stdc.stdio : fopen, fprintf, fclose;
    auto at = sentFile();
    if (at is null) return;
    auto f = fopen(at, "a");
    if (f is null) return;
    fprintf(f, "%.*s\t%lld\n", cast(int) path.length, path.ptr, offset);
    fclose(f);
}

// ---- the sending ----

struct Sent {
    bool ok = true;
    bool unreachable; // a far end did not answer: nothing to say of it each minute
    bool halt;        // no batch can go on: a far end is away, or refused the request whole
    bool busy;        // the node was slow over a batch: it is left alone
    long stuck;       // files stopped at a line the node refused
    long rows;
    long mostRows;    // the largest batch that landed
    long slowestUs;   // the longest the node took over a batch
    long slowestSignUs; // the longest the primary took to sign for one
    long slowestPostUs; // the longest the node took to answer the post of one
    Pace pace;        // the size of the next batch
    long files;
    char[400] whyBuf = 0;
    size_t whyLen;
    const(char)[] why() const return { return whyBuf[0 .. whyLen]; }
    void say(const(char)[] s) { foreach (c; s) if (whyLen < whyBuf.length) whyBuf[whyLen++] = c; }
}

// One batch of one file: signed for by the primary, posted to the node, and
// every row answered. The offset the file is sent up to after it, or -1.
private long sendBatch(const(char)[] primary, const(char)[] node, ref Batch b, ref Sent s) {
    import http : httpPostInto, httpPostAs, ToNode;
    import stream : nextAnswer, Answer;

    __gshared char[8192] signedReply = 0;
    import hookrun : usecNow;
    auto signAsked = usecNow();
    auto asked = httpPostInto(primary, "", ToNode(), signedReply[], 10);
    {
        auto took = usecNow() - signAsked;
        if (took > s.slowestSignUs) s.slowestSignUs = took;
    }
    if (asked.status == 0) { s.ok = false; s.halt = true; s.unreachable = true; s.say("the primary did not answer"); return -1; }
    auto authorization = authorizationOf(signedReply[0 .. asked.len]);
    if (asked.status != 200 || authorization.length == 0) {
        s.ok = false;
        s.halt = true;
        s.say("the primary gave no signature: ");
        s.say(signedReply[0 .. asked.len]);
        return -1;
    }

    __gshared ZBuf endpoint;
    endpoint.reset();
    endpoint.put(node);
    endpoint.put("/api/attestations");
    __gshared char[1024 * 1024] reply = 0;
    // k stalls for half a minute and more on its own, and finishes what it was
    // sent all the same: a batch given up on at 30s was work done twice
    // (2026-11-21). The signature lasts a minute to be presented, not to be answered.
    auto postAsked = usecNow();
    auto posted = httpPostAs(endpoint.slice(), b.slice(), authorization, reply[], 120);
    {
        auto took = usecNow() - postAsked;
        if (took > s.slowestPostUs) s.slowestPostUs = took;
    }
    if (posted.status == 0) { s.ok = false; s.halt = true; s.unreachable = true; s.say("the node did not answer"); return -1; }
    if (posted.status != 200 || posted.overran) {
        s.ok = false;
        s.halt = true;
        s.say("the node did not take the batch: ");
        s.say(reply[0 .. posted.len]);
        return -1;
    }
    // Every row by its own answer: the file moves on only when each landed.
    size_t at = 0;
    long landed = 0;
    foreach (i; 0 .. b.rows) {
        Answer a;
        if (!nextAnswer(reply[0 .. posted.len], at, a)) break;
        if (a.status < 200 || a.status >= 300) {
            // The lines before it landed; the file stops at this one, and it
            // is asked again after STUCK_WAIT. The other files go on.
            s.ok = false;
            s.stuck++;
            if (s.whyLen == 0) {
                s.say("the node refused a line: ");
                // The end of what it said is the reason; its start is the id.
                auto t = a.text;
                s.say(t.length > 300 ? t[$ - 300 .. $] : t);
            }
            s.rows += landed;
            b.refusedAt = b.starts[i];
            return -2;
        }
        landed++;
    }
    if (landed != b.rows) {
        s.ok = false;
        s.halt = true;
        s.say("the node answered fewer results than the rows it was sent");
        return -1;
    }
    s.rows += landed;
    return b.end;
}

// One file from where it was sent up to, until its end, the deadline, or a failure.
private void sendFile(const(char)[] primary, const(char)[] node, const(char)[] path,
                      const(char)[] sentLines, const(char)[] stuckLines, long deadline, ref Sent s) {
    import core.stdc.stdio : fopen, fclose, fread, fseek, ftell, SEEK_END, SEEK_SET;
    import core.stdc.stdlib : malloc, free;
    import core.stdc.time : time;
    import transcript : sessionOfPath;

    char[4096] z = 0;
    if (path.length + 1 >= z.length) return;
    z[0 .. path.length] = path[];
    auto from = sentUpTo(sentLines, path);
    {
        auto since = stuckAt(stuckLines, path, from);
        if (since > 0 && cast(long) time(null) - since < STUCK_WAIT) return;
    }

    auto f = fopen(z.ptr, "rb");
    if (f is null) return;
    scope (exit) fclose(f);
    fseek(f, 0, SEEK_END);
    auto size = ftell(f);
    if (size <= from) return;

    auto buf = cast(char*) malloc(READ_MOST);
    if (buf is null) return;
    scope (exit) free(buf);
    __gshared Batch b;
    auto session = sessionOfPath(path);
    bool any = false;

    while (from < size && cast(long) time(null) < deadline) {
        fseek(f, from, SEEK_SET);
        auto got = fread(buf, 1, READ_MOST, f);
        if (got == 0) break;
        batchFrom(b, buf[0 .. got], from, path, session, cast(long) time(null), s.pace.rows, s.pace.bytes);
        if (b.rows == 0) {
            // No whole line in what was read: one still being written, or one
            // longer than a read. The second is said, never passed over.
            if (got == READ_MOST) {
                s.ok = false;
                s.say("a line longer than ground reads for a batch, in ");
                s.say(path);
            }
            break;
        }
        import hookrun : usecNow;
        auto asked = usecNow();
        auto upTo = sendBatch(primary, node, b, s);
        auto took = usecNow() - asked;
        scope (exit) {
            // The node's own pace: it rests twice as long as the batch took it.
            import core.sys.posix.unistd : usleep;
            if (upTo != -1) usleep(cast(uint) waitAfter(took));
        }
        if (upTo == -2) {
            recordSent(path, b.refusedAt);
            recordStuck(path, b.refusedAt, cast(long) time(null));
            break;
        }
        if (upTo < 0) break;
        recordSent(path, upTo);
        from = upTo;
        any = true;
        if (b.rows > s.mostRows) s.mostRows = b.rows;
        if (took > s.slowestUs) s.slowestUs = took;
        paceAfter(s.pace, took);
        // The batch landed, and the node was slow over it: it is left alone.
        if (endsPass(true, took, b.rows)) break;
    }
    if (any) s.files++;
}

// The set-aside rows from where they were last sent, until none are left, the
// deadline, or a failure: paced as a file is.
private void sendRows(const(char)[] primary, const(char)[] node, sqlite3* db,
                      const(char)[] sentLines, const(char)[] stuckLines, long deadline, ref Sent s) {
    import core.stdc.time : time;
    import hookrun : usecNow;
    import core.sys.posix.unistd : usleep;
    auto from = sentUpTo(sentLines, STORE_KEY);
    {
        auto since = stuckAt(stuckLines, STORE_KEY, from);
        if (since > 0 && cast(long) time(null) - since < STUCK_WAIT) return;
    }
    __gshared Batch b;
    bool any = false;
    while (!s.halt && cast(long) time(null) < deadline) {
        rowsBatch(db, b, from, s.pace.rows, s.pace.bytes);
        if (b.rows == 0) {
            if (b.len > 2) { s.ok = false; s.say("a set-aside row larger than the node takes"); }
            break;
        }
        auto asked = usecNow();
        auto upTo = sendBatch(primary, node, b, s);
        auto took = usecNow() - asked;
        if (upTo != -1) usleep(cast(uint) waitAfter(took));
        if (upTo == -2) {
            recordSent(STORE_KEY, b.refusedAt - 1);
            recordStuck(STORE_KEY, b.refusedAt - 1, cast(long) time(null));
            break;
        }
        if (upTo < 0) break;
        recordSent(STORE_KEY, upTo);
        from = upTo;
        any = true;
        if (b.rows > s.mostRows) s.mostRows = b.rows;
        if (took > s.slowestUs) s.slowestUs = took;
        paceAfter(s.pace, took);
        if (endsPass(true, took, b.rows)) break;
    }
    if (any) s.files++;
}

private void sendDir(const(char)[] primary, const(char)[] node, const(char)[] dir,
                     const(char)[] sentLines, const(char)[] stuckLines, long deadline, ref Sent s, int depth) {
    import core.sys.posix.dirent : opendir, readdir, closedir, DT_DIR, DT_REG;
    import core.stdc.time : time;
    if (depth > 8) return;
    char[4096] z = 0;
    if (dir.length + 1 >= z.length) return;
    z[0 .. dir.length] = dir[];
    auto d = opendir(z.ptr);
    if (d is null) return;
    scope (exit) closedir(d);
    for (auto e = readdir(d); e !is null; e = readdir(d)) {
        if (s.halt || cast(long) time(null) >= deadline) return;
        size_t n = 0;
        while (e.d_name[n] != 0) n++;
        auto name = e.d_name[0 .. n];
        if (name == "." || name == "..") continue;
        if (dir.length + 1 + name.length >= 4096) continue;
        char[4096] child = 0;
        size_t cl = 0;
        foreach (c; dir) child[cl++] = c;
        child[cl++] = '/';
        foreach (c; name) child[cl++] = c;
        auto path = child[0 .. cl];
        if (e.d_type == DT_DIR) { sendDir(primary, node, path, sentLines, stuckLines, deadline, s, depth + 1); continue; }
        if (e.d_type != DT_REG) continue;
        if (name.length < 6 || name[$ - 6 .. $] != ".jsonl") continue;
        sendFile(primary, node, path, sentLines, stuckLines, deadline, s);
    }
}

// Every transcript under root sent on from where it stood, for at most
// `seconds`. `primary` is where the stream posts, the primary's address for the
// node (…/n/<name>): asked with no path on the node, it signs. `node` is the
// node itself, reached directly.
Sent sendDirect(const(char)[] primary, const(char)[] node, const(char)[] root, int seconds) {
    import core.stdc.stdio : fopen, fread, fclose;
    import core.stdc.time : time;
    Sent s;
    __gshared char[4 * 1024 * 1024] sentLines = 0;
    size_t n = 0;
    auto at = sentFile();
    if (at !is null) {
        auto f = fopen(at, "r");
        if (f !is null) { n = fread(sentLines.ptr, 1, sentLines.length, f); fclose(f); }
    }
    __gshared char[1024 * 1024] stuckLines = 0;
    size_t sn = 0;
    auto st = stuckFile();
    if (st !is null) {
        auto f = fopen(st, "r");
        if (f !is null) { sn = fread(stuckLines.ptr, 1, stuckLines.length, f); fclose(f); }
    }
    auto deadline = cast(long) time(null) + seconds;
    // The hook rows set aside first, read from the store without its write
    // lock: 156 MB of them against 2.5 GB of transcript lines on 2026-11-21.
    {
        import db : openDb, sqlite3_close;
        auto db = openDb();
        if (db !is null) {
            sendRows(primary, node, db, sentLines[0 .. n], stuckLines[0 .. sn], deadline, s);
            sqlite3_close(db);
        }
    }
    if (!s.halt && cast(long) time(null) < deadline)
        sendDir(primary, node, root, sentLines[0 .. n], stuckLines[0 .. sn], deadline, s, 0);
    return s;
}

// "this means this should not be pbt authored, humans have no business in owning this part"
// The node a sky sends to directly is the one `ground keep send` last sent to,
// kept beside the store as direct-node. None kept, none sent to.
const(char)[] directNodeOf(const(char)[] content) {
    size_t a = 0, e = content.length;
    while (a < e && (content[a] == ' ' || content[a] == '\n' || content[a] == '\t' || content[a] == '\r')) a++;
    while (e > a && (content[e - 1] == ' ' || content[e - 1] == '\n' || content[e - 1] == '\t' || content[e - 1] == '\r')) e--;
    auto t = content[a .. e];
    bool http = (t.length > 7 && t[0 .. 7] == "http://") || (t.length > 8 && t[0 .. 8] == "https://");
    return http ? t : "";
}

// When a node that was slow or away may be sent to again, kept as direct-rest.
long restOf(const(char)[] content) {
    long v = 0;
    size_t n = 0;
    foreach (c; content) {
        if (c == '\n') break;
        if (c < '0' || c > '9') return 0;
        v = v * 10 + (c - '0');
        n++;
    }
    return n == 0 ? 0 : v;
}

enum DIRECT_REST = 600;

private const(char)* besideStore(const(char)[] name) {
    import db : storeDir;
    __gshared ZBuf path;
    path.reset();
    auto dir = storeDir();
    if (dir is null) return null;
    path.put(dir);
    path.put("/");
    path.put(name);
    return path.ptr();
}

private const(char)[] readSmall(const(char)[] name, char[] into) {
    import core.stdc.stdio : fopen, fread, fclose;
    auto at = besideStore(name);
    if (at is null) return "";
    auto f = fopen(at, "r");
    if (f is null) return "";
    auto n = fread(into.ptr, 1, into.length, f);
    fclose(f);
    return into[0 .. n];
}

private void writeSmall(const(char)[] name, const(char)[] text) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    auto at = besideStore(name);
    if (at is null) return;
    auto f = fopen(at, "w");
    if (f is null) return;
    fwrite(text.ptr, 1, text.length, f);
    fclose(f);
}

// What `ground keep send <node>` remembers for the skies.
void rememberDirectNode(const(char)[] node) {
    writeSmall("direct-node", node);
}

// The node is left alone for DIRECT_REST seconds from now.
void restDirect(long now) {
    char[24] d = 0;
    import core.stdc.stdio : snprintf;
    auto n = snprintf(d.ptr, d.length, "%lld\n", now + DIRECT_REST);
    if (n > 0) writeSmall("direct-rest", d[0 .. n]);
}

// A sky's pass of it: only one sky sends at a time, only to the node
// `ground keep send` last sent to, and not while that node is left alone.
// Nothing is said of a far end that is not there.
void directPass(const(char)[] streamUrl, const(char)[] sessionId) {
    import transcript : projectsRoot;
    import core.sys.posix.fcntl : open, O_CREAT, O_RDWR;
    import core.stdc.time : time;
    import core.sys.posix.unistd : close;

    if (streamUrl.length == 0) return;
    __gshared char[512] nodeBuf = 0;
    __gshared char[32] restBuf = 0;
    auto node = directNodeOf(readSmall("direct-node", nodeBuf[]));
    if (node.length == 0 || node == streamUrl) return;
    if (restOf(readSmall("direct-rest", restBuf[])) > cast(long) time(null)) return;
    auto root = projectsRoot();
    if (root.length == 0) return;

    auto at = sentFile();
    if (at is null) return;
    auto fd = open(at, O_CREAT | O_RDWR, 420);
    if (fd < 0) return;
    scope (exit) close(fd);
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) return;

    auto s = sendDirect(streamUrl, node, root, DIRECT_SECONDS);
    if (s.busy || s.halt) restDirect(cast(long) time(null));
    if (!s.ok && !s.unreachable) {
        import errors : sayQuietly;
        sayQuietly("direct.send", "kept lines were not sent to the node directly", -1,
                   sessionId, "direct", s.why());
    }
}

// How long one pass sends for, and how often a sky makes one.
enum DIRECT_SECONDS = 10;
enum DIRECT_EVERY = 30;

extern (C) private int flock(int fd, int operation);
private enum LOCK_EX = 2;
private enum LOCK_NB = 4;
