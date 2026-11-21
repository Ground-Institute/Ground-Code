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
    long stuck;       // files stopped at a line the node refused
    long rows;
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
    auto asked = httpPostInto(primary, "", ToNode(), signedReply[], 10);
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
    auto posted = httpPostAs(endpoint.slice(), b.slice(), authorization, reply[], 120);
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
        batchFrom(b, buf[0 .. got], from, path, session, cast(long) time(null), BATCH_ROWS, BATCH_BYTES);
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
    sendDir(primary, node, root, sentLines[0 .. n], stuckLines[0 .. sn], cast(long) time(null) + seconds, s, 0);
    return s;
}

// A sky's pass of it: only one sky sends at a time, and only where the ground
// installed here names a node of its own (nodes.pbt) beside the one its
// controls stream to. Nothing is said of a far end that is not there.
void directPass(const(char)[] streamUrl, const(char)[] sessionId) {
    import nodeconfig : NodeConfig, loadNodes;
    import transcript : projectsRoot;
    import core.sys.posix.fcntl : open, O_CREAT, O_RDWR;
    import core.sys.posix.unistd : close;

    if (streamUrl.length == 0) return;
    __gshared NodeConfig c;
    loadNodes(c);
    if (c.why().length > 0 || c.count != 1) return;
    auto node = c.nodes[0].url;
    if (node.length == 0 || node == streamUrl) return;
    auto root = projectsRoot();
    if (root.length == 0) return;

    auto at = sentFile();
    if (at is null) return;
    auto fd = open(at, O_CREAT | O_RDWR, 420);
    if (fd < 0) return;
    scope (exit) close(fd);
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) return;

    auto s = sendDirect(streamUrl, node, root, DIRECT_SECONDS);
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
