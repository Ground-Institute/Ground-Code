module userprompt;

// TODO: decision:block support — reject prompts that match certain patterns
// TODO: use permission_mode to adjust behavior (e.g. stricter in plan mode)

import parse : extractJsonString;
import matcher : contains, envSubst;
import controls : userPromptScopes;
import hooks : scopeMatches;
import db : ZBuf, openDb, attestationExists, attestEvent, sqlite3_close;
import core.stdc.stdio : stdout, fputs, fwrite;

// additionalContext is a JSON string, and everything said in it is JSON text:
// the switch, every control's message and the playbill alike. A message holds
// quotes and newlines, and one put raw ended the string where the quote stood.
void putJsonText(ref ZBuf b, const(char)[] s) {
    enum hex = "0123456789abcdef";
    foreach (c; s) {
        switch (c) {
            case '"': b.put(`\"`); break;
            case '\\': b.put(`\\`); break;
            case '\n': b.put(`\n`); break;
            case '\r': b.put(`\r`); break;
            case '\t': b.put(`\t`); break;
            default:
                if (cast(ubyte) c < 0x20) {
                    b.put(`\u00`);
                    b.putChar(hex[(c >> 4) & 0xf]);
                    b.putChar(hex[c & 0xf]);
                } else {
                    b.putChar(c);
                }
        }
    }
}

const(char)[] extractPrompt(const(char)[] json) {
    __gshared char[8192] buf = 0;
    return extractJsonString(json, `"prompt"`, &buf[0], buf.length);
}

// 「[Opus 5.5] Its timing row names each step it walked: sweep, ingest, said, controls, bill.」
int handleUserPromptSubmit(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import hookrun : usecNow;
    auto t0 = usecNow();
    long tSweep, tIngest, tSaid, tControls, tBill;
    scope (exit) {
        import phases : phaseChain;
        import hookrun : setPhases;
        static immutable string[5] KEYS = ["sweep", "ingest", "said", "controls", "bill"];
        long[5] stamps = [tSweep, tIngest, tSaid, tControls, tBill];
        __gshared ZBuf prof;
        prof.reset();
        phaseChain(prof, t0, KEYS[], stamps[], usecNow(), "none");
        setPhases(prof.slice());
    }

    auto prompt = extractPrompt(input);
    if (prompt is null) return 0;

    // "can we make it somethng like a slahs command so its not spending a turn?"
    // The prompt is already in the store, which is where gates are read from;
    // blocking it erases it, so no model turn is spent on it.
    {
        import gates : isGatesOff, isGatesOn;
        if (isGatesOff(prompt) || isGatesOn(prompt)) {
            fputs(isGatesOff(prompt)
                ? `{"decision":"block","reason":"gates off: no ground control gates this session until gates on"}`.ptr
                : `{"decision":"block","reason":"gates on: ground's controls gate this session again"}`.ptr, stdout);
            fputs("\n", stdout);
            return 0;
        }
    }

    auto db = openDb();

    // "I dont know how to explain how serious this defect is"
    // Typing is when a dead driver's walk is halted and said, if no Stop got there first.
    if (db !is null) {
        import ritual.orphan : sweepOrphans;
        sweepOrphans(db);
    }
    tSweep = usecNow();

    // A message typed mid-turn fires no hook, so the transcript is the only
    // record of it. Without this the corpus holds what was submitted rather
    // than what was said.
    {
        import parse : extractTranscriptPath;
        import queued : ingestTranscript;
        auto tp = extractTranscriptPath(input);
        if (tp !is null) ingestTranscript(db, tp, sessionId, cwd);
    }
    tIngest = usecNow();

    __gshared ZBuf ctx;
    ctx.reset();
    bool any = false;

    // Messages addressed to this route are invisible to sky. A receipt here
    // consumes one only when its complete escaped text fits this response.
    if (db !is null) {
        import immediate : readImmediateMessage, markImmediateDelivered;
        while (true) {
            auto pending = readImmediateMessage(db, cwd, sessionId, "delivered:", "next_user_prompt");
            if (pending.message is null) break;
            size_t escaped;
            foreach (ch; pending.message)
                escaped += ch == '"' || ch == '\\' || ch == '\n' || ch == '\r' || ch == '\t' ? 2 :
                           cast(ubyte) ch < 0x20 ? 6 : 1;
            if (ctx.len + escaped + (any ? 3 : 0) >= ctx.data.length) {
                import core.stdc.stdio : stderr;
                fputs("ground: pending prompt context exceeds response capacity; retained in queue\n", stderr);
                break;
            }
            if (!markImmediateDelivered(db, pending.msgId, pending.projectContext, sessionId)) break;
            if (any) ctx.put(" | ");
            putJsonText(ctx, pending.message);
            any = true;
        }
    }

    // "it should be easy for me to switch, simply by saying the words"
    __gshared char[512] sw = 0;
    size_t swLen = 0;
    {
        import ritual : saidOf, Said, switched;
        import controls : parsedOnce;
        import git : repoRoot, originOf;
        import core.stdc.time : time;
        alias parsed = parsedOnce;
        auto said = saidOf(prompt);
        if (said != Said.Nothing) {
            swLen = switched(db, parsed, said, cwd, repoRoot(cwd), originOf(cwd),
                             sessionId, cast(long) time(null), sw[]);
            if (any) ctx.put(" | ");
            putJsonText(ctx, sw[0 .. swLen]);
            any = true;
            if (db !is null) {
                import fired : noteFired;
                noteFired(db, sessionId, "UserPromptSubmit", "control",
                          said == Said.On ? "rituals-on" : "rituals-off", "context", cwd);
            }
        }
    }
    tSaid = usecNow();

    foreach (ref sc; userPromptScopes) {
        if (!scopeMatches(sc, cwd))
            continue;
        foreach (ref c; sc.controls) {
            if (c.userprompt.len == 0) continue;
            bool matched = false;
            import matcher : wildcardContains;
            foreach (ref v; c.userprompt.values)
                if (wildcardContains(prompt, v)) { matched = true; break; }
            if (!matched) continue;

            // Once per session
            if (db !is null && attestationExists(db, "GroundedUserPromptSubmit", c.name, sessionId))
                continue;

            if (any) ctx.put(" | ");
            putJsonText(ctx, envSubst(c.msg.value, cwd));
            any = true;

            if (db !is null) {
                import db : attestControlFire;
                attestControlFire(db, "GroundedUserPromptSubmit", c.name, cwd, sessionId);
                import fired : noteFired;
                noteFired(db, sessionId, "UserPromptSubmit", "control", c.name, "context", cwd);
            }
        }
    }
    tControls = usecNow();

    // Standing where a ritual performs is enough, whether the session started
    // here or walked in. Said once, so a turn spent here costs nothing after.
    {
        import playbill : unsaidBillInto;
        __gshared char[4096] bill = void;
        auto n = unsaidBillInto(db, sessionId, cwd, bill[]);
        if (n > 0) {
            if (any) ctx.put(" | ");
            putJsonText(ctx, bill[0 .. n]);
            any = true;
        }
    }
    tBill = usecNow();

    if (db !is null) sqlite3_close(db);

    // "but you would think, it should be Cumulus, no ?"
    // A name taken at laye since the session started (`ground name`) is what
    // Claude Code is to call it, when it calls it anything else.
    const(char)[] title = layeTitle(sessionId);

    if (!any && title is null) return 0;

    fputs(`{`, stdout);
    // The switch is said to the person who said the words, not only to the model.
    if (swLen > 0) {
        import parse : writeJsonString;
        fputs(`"systemMessage":"`, stdout);
        writeJsonString(sw[0 .. swLen]);
        fputs(`",`, stdout);
    }
    fputs(`"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"`, stdout);
    if (ctx.len > 0) fwrite(&ctx.data[0], 1, ctx.len, stdout);
    if (title !is null) {
        import parse : writeJsonString;
        fputs(`","sessionTitle":"`, stdout);
        writeJsonString(title);
    }
    fputs(`"}}`, stdout);
    fputs("\n", stdout);

    return 0;
}

// The name laye holds for the session, kept beside its key, when Claude Code
// calls the session anything else; null when they agree or none is kept.
const(char)[] layeTitle(const(char)[] sessionId) {
    import naming : keptName, harnessName, sessionKeyFile;
    import nodeconfig : nodeHere;
    import sky : getppid;
    if (sessionId.length == 0) return null;
    auto here = nodeHere();
    if (here.sandUrl.length == 0) return null;
    __gshared char[256] keptBuf;
    auto kept = keptName(sessionKeyFile(sessionId), here.sandUrl, keptBuf[]);
    if (kept is null || kept.length == 0) return null;
    char[256] harnessBuf;
    auto called = harnessName(getppid(), harnessBuf[]);
    if (called !is null && called == kept) return null;
    return kept;
}
