module errored_test;

// "just show a short message that its errored and reported to sentry"

import errored;

// 「[Opus 5.5] What a person was shown as an error is the error Sentry is told: from where,」
// 「[Opus 5.5] what, for which session, and when.」
unittest {
    auto err = errorOf("ag", "/api/collected/release answered 502: ground.institute | 502: Bad gateway",
        "sid-1", 1_795_862_552);
    assert(err.origin == "ag", err.origin);
    assert(err.message == "/api/collected/release answered 502: ground.institute | 502: Bad gateway", err.message);
    assert(err.sessionId == "sid-1", err.sessionId);
    assert(err.timestamp == 1_795_862_552);
    assert(err.exitCode == -1);
}

// 「[Opus 5.5] Without a from-where and a what, nothing is told, and how to ask is said.」
unittest {
    const(char)*[3] argv = ["ground", "errored", "ag"];
    assert(handleErrored(3, argv.ptr) == 2);
    const(char)*[4] empty = ["ground", "errored", "ag", ""];
    assert(handleErrored(4, empty.ptr) == 2);
}
