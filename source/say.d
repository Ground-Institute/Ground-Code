module say;

// "SESSION ALDER SPEAKS TO SLATE ON K"
// "BY NAME"
// "VIA SAY"
// "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"
// "A SESSION THATS SENDING TO ANOTHER SESSION BY NAME IS TOLD ABOUT THE MESSAGE BEING RECEIVED OR NOT, AND WE DONT INVENT HERE, WE TAKE THE A2A CONVENTIONS, WE TAKE THE SDK SERIOUSLY"
//
// A name an agent holds is an A2A tenant at its node (QNTX #1671): what is
// said to it is a Task. The session says it with its own key, and asks after
// the Task by its id.

import zbuf : ZBuf;
import code.reply : Reply, putEscaped;

enum BOOK_COMMAND = q"EOS
# say something to the session that holds a name, as this session, by its own key:
ground say Slate "the build on k is red"

# say it with an A2UI v1.0 surface beside the words: the file holds one A2UI
# message, or a list of them, each with "version": "1.0":
ground say Slate --a2ui which-first.json "Which do I do first?"

# whether what was said was received, by the Task the saying answered with:
ground heard Slate 01a1d0c3-0922-759f-a495-a1e92e3a6851

# say by hand that this session received what a Task said to its name; sky
# says so itself as it hands the words over:
ground received 01a1d0c3-0922-759f-a495-a1e92e3a6851
EOS";

// The node's A2A address of a name: its tenant. A space in a name of two
// words is written as the address writes one.
void tenantUrl(ref ZBuf url, const(char)[] node, const(char)[] name) {
    url.reset();
    url.put(node);
    url.put("/a2a/");
    foreach (c; name) {
        if (c == ' ') url.put("%20");
        else { char[1] one = [c]; url.put(one[]); }
    }
}

// What a Task is in, in the words it is told in.
const(char)[] stateSaid(const(char)[] state) {
    if (state == "TASK_STATE_SUBMITTED") return "is not received yet";
    if (state == "TASK_STATE_WORKING") return "is being received";
    if (state == "TASK_STATE_COMPLETED") return "was received";
    if (state == "TASK_STATE_FAILED") return "was not received";
    if (state == "TASK_STATE_CANCELED") return "was taken back";
    if (state == "TASK_STATE_REJECTED") return "was refused";
    return state;
}

private struct Asking {
    const(char)[] node;
    const(char)* keyAt;
    bool ok;
}

// The node this session is signed in to and the key it says things by, or why
// not, said on stderr.
private Asking asking(const(char)* what) {
    import core.stdc.stdio : stderr, fputs;
    import core.stdc.stdlib : getenv;
    import nodeconfig : nodeHere;
    import naming : sessionKeyFile;
    Asking a;
    void no(const(char)* why) {
        fputs(what, stderr);
        fputs(": ", stderr);
        fputs(why, stderr);
        fputs("\n", stderr);
    }
    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) { no("CLAUDE_CODE_SESSION_ID is not set, so this is no session's to say"); return a; }
    size_t n = 0;
    while (sid[n] != 0) n++;
    auto here = nodeHere();
    if (here.sandUrl.length == 0) { no("no node to say it at"); return a; }
    a.keyAt = sessionKeyFile(sid[0 .. n]);
    if (a.keyAt is null) { no("this session has no key of its own to say it by"); return a; }
    a.node = here.sandUrl;
    a.ok = true;
    return a;
}

// "do you think the ground say should show near misses ?"
// What a node says of a name nobody holds, in words: nobody holds it, and the
// names near it when the node gave some (QNTX #1686). Empty when the answer is
// about something else.
const(char)[] nobodyHolds(const(char)[] name, const(char)[] answer, ref ZBuf line) {
    import matcher : indexOf;
    enum none = "no agent is served at tenant ";
    if (indexOf(answer, none) < 0) return "";
    line.reset();
    line.put("nobody holds the name ");
    line.put(name);
    enum near = ". Near it: ";
    auto at = indexOf(answer, near);
    if (at >= 0) {
        auto rest = answer[at + near.length .. $];
        size_t end = 0;
        while (end < rest.length && rest[end] != '"' && rest[end] != '\\') end++;
        line.put(". Near it: ");
        line.put(rest[0 .. end]);
    }
    return line.slice();
}

// What the node answered with, said whole when it was no Task.
private int refused(const(char)* what, const(char)[] url, int status, int code, const(char)[] why, const(char)[] answer) {
    import core.stdc.stdio : stderr, fputs;
    __gshared ZBuf line;
    line.reset();
    line.put(url);
    if (status > 0) {
        line.put(" answered ");
        line.putUint(status);
        line.put(": ");
        line.put(answer);
    } else {
        line.put(" was not reached: ");
        line.put(why);
        line.put(" (libcurl ");
        line.putUint(code);
        line.put(")");
    }
    line.put("\n");
    fputs(what, stderr);
    fputs(": ", stderr);
    fputs(line.ptr(), stderr);
    return 1;
}

// The row ug writes news as: the item's id after it, which for what was said
// to a name is its Task's.
enum NEWS_ROW = "immediate:news:";

// The session asks its node for the whole of a news item, by its own key: for
// what was said to its name, that is the node hearing it was received (QNTX
// #1684). Any other news is asked for and nothing follows. Empty when the node
// answered, whatever it answered; else why it was not reached.
const(char)[] toldTheNode(const(char)[] sessionId, const(char)[] item) {
    import http : httpGet, ToNode;
    import nodeconfig : nodeHere;
    import naming : sessionKeyFile;
    foreach (c; item) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')) return "";
    }
    auto here = nodeHere();
    auto keyAt = sessionKeyFile(sessionId);
    // No node to say it to, or no key to say it by, is not said: and is said so.
    if (here.sandUrl.length == 0) return "this ground is signed in to no node, so nothing was said as received";
    if (keyAt is null) return "this session has no key of its own, so nothing was said as received";
    __gshared ZBuf url;
    url.reset();
    url.put(here.sandUrl);
    url.put("/am/statusline/");
    url.put(item);
    __gshared char[4096] reply;
    auto r = httpGet(url.slice(), ToNode(keyAt), reply[], 15);
    // The node answered with the item: it heard who asked.
    if (r.status == 200) return "";
    __gshared ZBuf why;
    why.reset();
    why.put(url.slice());
    if (r.status > 0) {
        why.put(" answered ");
        why.putUint(r.status);
        why.put(": ");
        why.put(reply[0 .. r.len]);
    } else {
        why.put(" was not reached: ");
        why.put(r.why());
    }
    return why.slice();
}

// ground received <task>: this session says to its node, by its own key, that
// it received what a Task said to its name. sky says so as it hands news over;
// this is the same said by hand.
int handleReceived(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import core.stdc.stdlib : getenv;
    import hookrun : argLen;
    if (argc < 3) {
        fputs("ground received <task>: say to the node that this session received what was said to its name\n", stderr);
        return 2;
    }
    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) {
        fputs("ground received: CLAUDE_CODE_SESSION_ID is not set, so this is no session's to say\n", stderr);
        return 1;
    }
    size_t n = 0;
    while (sid[n] != 0) n++;
    auto why = toldTheNode(sid[0 .. n], argv[2][0 .. argLen(argv[2])]);
    if (why.length > 0) {
        fputs("ground received: ", stderr);
        __gshared ZBuf line;
        line.reset();
        line.put(why);
        line.put("\n");
        fputs(line.ptr(), stderr);
        return 1;
    }
    fputs("Said to the node as received.\n", stdout);
    return 0;
}

// "Getting A2UI pieces to show up in another session from this one"
//
// A2UI over A2A, the a2ui v1.0 extension specification at the commit laye
// pins in parity/a2ui_v1.0_36725ee: a DataPart whose metadata mimeType is
// application/a2ui+json, and whose data is a list of A2UI messages:
// "It MUST be an array of messages."
enum A2UI_MIME = "application/a2ui+json";

// Why `surface` is neither one A2UI 1.0 message nor a list of them; empty when
// it is one of the two.
const(char)[] notASurface(const(char)[] surface) {
    import libjsonc : json_object, json_type, json_object_get_type, json_object_array_length,
        json_object_array_get_idx, json_object_put, jsonField, parseJson,
        json_object_get_string, json_object_get_string_len;
    auto value = parseJson(surface);
    if (value is null) return "the surface is no JSON";
    scope (exit) json_object_put(value);
    __gshared ZBuf why;
    const(char)[] message(json_object* m, size_t at) {
        why.reset();
        why.put("the surface's message ");
        why.putUint(at);
        if (json_object_get_type(m) != json_type.object) {
            why.put(" is no JSON object");
            return why.slice();
        }
        auto v = jsonField(m, "version");
        if (v is null || json_object_get_type(v) != json_type.string_
            || json_object_get_string(v)[0 .. json_object_get_string_len(v)] != "1.0") {
            why.put(` says no "version": "1.0"`);
            return why.slice();
        }
        return "";
    }
    switch (json_object_get_type(value)) {
    case json_type.object:
        return message(value, 0);
    case json_type.array:
        auto n = json_object_array_length(value);
        if (n == 0) return "the surface is a list of no A2UI messages";
        foreach (i; 0 .. n) {
            auto said = message(json_object_array_get_idx(value, i), i);
            if (said.length > 0) return said;
        }
        return "";
    default:
        return "the surface is neither an A2UI message nor a list of them";
    }
}

private bool blank(char c) { return c == ' ' || c == '\n' || c == '\t' || c == '\r'; }

// The send of `words` to a name, and of `surface` beside them when there is
// one: the A2UI data part, its messages as they were written. Empty when it
// was written into `body_`; else why not, and nothing was.
const(char)[] saidBody(ref Reply body_, const(char)[] id, const(char*)[] words, const(char)[] surface) {
    import hookrun : argLen;
    size_t from = 0, to = surface.length;
    while (from < to && blank(surface[from])) from++;
    while (to > from && blank(surface[to - 1])) to--;
    surface = surface[from .. to];
    if (surface.length > 0) {
        auto why = notASurface(surface);
        if (why.length > 0) return why;
    }
    body_.add(`{"message":{"messageId":"`);
    body_.add(id);
    body_.add(`","role":"ROLE_USER","parts":[{"text":"`);
    foreach (i, w; words) {
        if (i > 0) body_.add(" ");
        putEscaped(body_, w[0 .. argLen(w)]);
    }
    body_.add(`"}`);
    if (surface.length > 0) {
        body_.add(`,{"data":`);
        if (surface[0] == '[') body_.add(surface);
        else { body_.add("["); body_.add(surface); body_.add("]"); }
        body_.add(`,"mediaType":"` ~ A2UI_MIME ~ `","metadata":{"mimeType":"` ~ A2UI_MIME ~ `"}}`);
    }
    body_.add(`]},"configuration":{"returnImmediately":true}}`);
    return "";
}

// The whole of the file at `path`, read into `into`; or null, and why not in
// `why`.
private const(char)[] readSurface(const(char)[] path, ref Reply into, ref ZBuf why) {
    import core.stdc.stdio : FILE, fopen, fread, fclose, ferror;
    import core.stdc.errno : errno;
    import core.stdc.string : strerror;
    __gshared ZBuf at;
    at.reset();
    at.put(path);
    why.reset();
    FILE* f = fopen(at.ptr(), "rb");
    if (f is null) {
        why.put(path);
        why.put(": ");
        auto e = strerror(errno);
        size_t n = 0;
        while (e[n] != 0) n++;
        why.put(e[0 .. n]);
        return null;
    }
    scope (exit) fclose(f);
    char[4096] chunk;
    for (;;) {
        auto n = fread(chunk.ptr, 1, chunk.length, f);
        if (n > 0) into.add(chunk[0 .. n]);
        if (n < chunk.length) break;
    }
    if (ferror(f)) {
        why.put(path);
        why.put(": it was not read whole");
        return null;
    }
    if (into.full) {
        why.put(path);
        why.put(": it did not fit in memory");
        return null;
    }
    return into.slice();
}

// ground say <Name> [--a2ui <file>] <words>: said to the agent that holds the
// name, as a Task; with the A2UI messages in the file beside the words.
int handleSay(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import core.stdc.time : time;
    import core.sys.posix.unistd : getpid;
    import hookrun : argLen;
    import http : httpPostInto, ToNode;
    import parse : extractJsonString;

    enum usage = "ground say <Name> [--a2ui <file>] <words>: say something to the session that holds the name, with the A2UI surface in the file beside it\n";
    if (argc < 4) {
        fputs(usage, stderr);
        return 2;
    }
    auto name = argv[2][0 .. argLen(argv[2])];
    int words = 3;
    Reply surface;
    scope (exit) surface.dispose();
    const(char)[] drawn;
    if (argv[3][0 .. argLen(argv[3])] == "--a2ui") {
        if (argc < 6) {
            fputs(usage, stderr);
            return 2;
        }
        __gshared ZBuf unread;
        drawn = readSurface(argv[4][0 .. argLen(argv[4])], surface, unread);
        if (drawn is null) {
            fputs("ground say: ", stderr);
            unread.put("\n");
            fputs(unread.ptr(), stderr);
            return 1;
        }
        words = 5;
    }
    auto who = asking("ground say");
    if (!who.ok) return 1;

    __gshared ZBuf url;
    tenantUrl(url, who.node, name);
    url.put("/message:send");

    Reply body_;
    scope (exit) body_.dispose();
    __gshared ZBuf id;
    id.reset();
    id.put("ground-say-");
    id.putUint(cast(ulong) time(null));
    id.put("-");
    id.putUint(cast(ulong) getpid());
    auto why = saidBody(body_, id.slice(), argv[words .. argc], drawn);
    if (why.length > 0) {
        __gshared ZBuf line;
        line.reset();
        line.put("ground say: ");
        line.put(why);
        line.put("\n");
        fputs(line.ptr(), stderr);
        return 1;
    }

    __gshared char[16384] reply;
    auto r = httpPostInto(url.slice(), body_.slice(), ToNode(who.keyAt), reply[], 60);
    auto answer = reply[0 .. r.len];
    if (r.status == 404) {
        __gshared ZBuf nobody;
        auto said = nobodyHolds(name, answer, nobody);
        if (said.length > 0) {
            fputs("ground say: ", stderr);
            nobody.put("\n");
            fputs(nobody.ptr(), stderr);
            return 1;
        }
    }
    if (r.status != 200) return refused("ground say", url.slice(), r.status, r.code, r.why(), answer);

    char[128] taskBuf, stateBuf;
    auto task = extractJsonString(answer, `"id"`, taskBuf.ptr, taskBuf.length);
    auto state = extractJsonString(answer, `"state"`, stateBuf.ptr, stateBuf.length);
    if (task is null || state is null) return refused("ground say", url.slice(), r.status, r.code, r.why(), answer);

    __gshared ZBuf line;
    line.reset();
    line.put("Said to ");
    line.put(name);
    line.put(", and it ");
    line.put(stateSaid(state));
    line.put(". Task ");
    line.put(task);
    line.put(": `ground heard ");
    line.put(name);
    line.put(" ");
    line.put(task);
    line.put("` says whether it was received.\n");
    fputs(line.ptr(), stdout);
    return 0;
}

// ground heard <Name> <task>: whether what was said to the name was received.
int handleHeard(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import hookrun : argLen;
    import http : httpGet, ToNode;
    import parse : extractJsonString;

    if (argc < 4) {
        fputs("ground heard <Name> <task>: whether what was said to the name was received\n", stderr);
        return 2;
    }
    auto name = argv[2][0 .. argLen(argv[2])];
    auto task = argv[3][0 .. argLen(argv[3])];
    foreach (c; task) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')) {
            fputs("ground heard: that is no Task's id\n", stderr);
            return 2;
        }
    }
    auto who = asking("ground heard");
    if (!who.ok) return 1;

    __gshared ZBuf url;
    tenantUrl(url, who.node, name);
    url.put("/tasks/");
    url.put(task);

    __gshared char[16384] reply;
    auto r = httpGet(url.slice(), ToNode(who.keyAt), reply[], 30);
    auto answer = reply[0 .. r.len];
    if (r.status != 200) return refused("ground heard", url.slice(), r.status, r.code, r.why(), answer);
    char[128] stateBuf;
    auto state = extractJsonString(answer, `"state"`, stateBuf.ptr, stateBuf.length);
    if (state is null) return refused("ground heard", url.slice(), r.status, r.code, r.why(), answer);

    __gshared ZBuf line;
    line.reset();
    line.put("What was said to ");
    line.put(name);
    line.put(" ");
    line.put(stateSaid(state));
    line.put(".\n");
    fputs(line.ptr(), stdout);
    return 0;
}
