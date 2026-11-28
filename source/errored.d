module errored;

// "just show a short message that its errored and reported to sentry"
// "why inst an error"
// "only the thing that is also shown to a user"
//
// 「[Opus 5.5] What a tool beside ground shows a person as an error, ag first, is the」
// 「[Opus 5.5] error Sentry is told, whole: `ground errored <from where> <what>` leaves it」
// 「[Opus 5.5] in ground's outbox as every error ground raises is left (errors.d,」
// 「[Opus 5.5] reportQuietly), and the courier posts it. The tool needs no Sentry of its own.」

import errors : GroundError;

// 「[Opus 5.5] What ground errored prints once the error is left for Sentry.」
enum TOLD = "left for Sentry\n\0";

// 「[Opus 5.5] The error a person was shown: from where, what, for which session, when.」
GroundError errorOf(const(char)[] origin, const(char)[] what, const(char)[] sessionId, long now) {
    GroundError err;
    err.origin = cast(string) origin;
    err.message = cast(string) what;
    err.sessionId = cast(string) sessionId;
    err.exitCode = -1;
    err.timestamp = now;
    return err;
}

// 「[Opus 5.5] ground errored <from where> <what>: 0 once it is left for Sentry, 2 when」
// 「[Opus 5.5] either is missing.」
int handleErrored(int argc, const(char)** argv) {
    import core.stdc.stdio : stderr, fputs;
    import core.stdc.stdlib : getenv;
    import core.stdc.time : time;
    import errors : reportQuietly;
    import hookrun : argLen;
    if (argc != 4 || argLen(argv[2]) == 0 || argLen(argv[3]) == 0) {
        fputs("ground errored <from where> <what>: what a person was shown as an error, told to Sentry whole\n", stderr);
        return 2;
    }
    auto sid = getenv("CLAUDE_CODE_SESSION_ID");
    size_t n = 0;
    if (sid !is null) while (sid[n] != 0) n++;
    auto err = errorOf(argv[2][0 .. argLen(argv[2])], argv[3][0 .. argLen(argv[3])],
        sid is null ? "" : sid[0 .. n], cast(long) time(null));
    reportQuietly(err);
    // 「[Opus 5.5] What the caller believes, and nothing else: a ground without this」
    // 「[Opus 5.5] command prints its version and exits 0, and ag took that for told.」
    import core.stdc.stdio : stdout;
    fputs(TOLD.ptr, stdout);
    return 0;
}
