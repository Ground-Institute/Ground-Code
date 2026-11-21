module direct_test;

// "Q should never be used for backfill type ops"
// "k should be delegating auth to the node entirely to q"
// The answer chosen for both: "q signs, data direct".
//
// q is asked for its signature and nothing else; the kept lines go to k from
// the files they were kept from, and what was sent is remembered by file.

import direct : authorizationOf, sentUpTo, batchFrom, Batch;
import matcher : contains;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK, SQLITE_ROW,
    sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step, sqlite3_finalize, sqlite3_stmt,
    sqlite3_column_text, sqlite3_column_int64, SQLITE_TRANSIENT;

unittest {
    // What q answers POST /n/<name> with (QNTX server/auth/peers.go).
    assert(authorizationOf(`{"authorization":"Signed eyJhbGciOi.abc.def"}` ~ "\n") == "Signed eyJhbGciOi.abc.def");
    assert(authorizationOf(`{"error":"no session"}`) == "");
    assert(authorizationOf("") == "");
}

unittest {
    // How far each file has been sent: one line a file, the last said stands.
    enum kept = "/t/a.jsonl\t120\n/t/b.jsonl\t7\n/t/a.jsonl\t340\n";
    assert(sentUpTo(kept, "/t/a.jsonl") == 340);
    assert(sentUpTo(kept, "/t/b.jsonl") == 7);
    assert(sentUpTo(kept, "/t/c.jsonl") == 0);
}

private const(char)[] asked(sqlite3* db, const(char)[] json, const(char)* q) {
    __gshared char[4096] out_ = 0;
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q, -1, &s, null) != SQLITE_OK) return "prepare failed";
    sqlite3_bind_text(s, 1, json.ptr, cast(int) json.length, SQLITE_TRANSIENT);
    size_t n = 0;
    if (sqlite3_step(s) == SQLITE_ROW) {
        auto t = sqlite3_column_text(s, 0);
        if (t !is null) while (t[n] != 0 && n < out_.length) { out_[n] = t[n]; n++; }
    }
    sqlite3_finalize(s);
    return out_[0 .. n];
}

unittest {
    // The rows of a batch are the rows the store holds of the same lines: the
    // same id, so a line that reached k another way is the same row there.
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    enum first = `{"type":"user","timestamp":"2026-08-19T00:42:08.852Z","message":{"content":"say \"hi\"\n"}}`;
    enum second = `{"type":"mode"}`;
    enum content = first ~ "\n" ~ second ~ "\n" ~ `{"type":"half`;

    __gshared Batch b;
    batchFrom(b, content, 100, "/t/a b.jsonl", "sess-d", 1_800_000_000, 256);
    assert(b.rows == 2, "whole lines only");
    assert(b.end == 100 + first.length + 1 + second.length + 1);
    auto json = b.slice();

    assert(asked(db, json, "SELECT json_valid(?1)\0") == "1", "the batch is JSON");
    assert(asked(db, json, "SELECT json_array_length(?1)\0") == "2");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].id')\0") == "ground:transcript:/t/a b.jsonl:100");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].predicates[0]')\0") == "transcript:line");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].contexts[0]')\0") == "session:sess-d");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].subjects[0]')\0") == "session:sess-d");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].actors[0]')\0") == "ground");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].attributes.line')\0") == first, "the line whole, as written");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].attributes.offset')\0") == "100");
    assert(asked(db, json, "SELECT json_extract(?1, '$[0].timestamp')\0") == "1787100128", "at the moment the line gives");
    assert(asked(db, json, "SELECT json_extract(?1, '$[1].timestamp')\0") == "1800000000", "a line that gives none, now");
    assert(asked(db, json, "SELECT json_extract(?1, '$[1].id') = 'ground:transcript:/t/a b.jsonl:' || json_extract(?1, '$[1].attributes.offset')\0") == "1",
        "a row's id ends with where its line starts");
    assert(asked(db, json, "SELECT json_extract(?1, '$[1].attributes.offset') = 100 + length(CAST(json_extract(?1, '$[0].attributes.line') AS BLOB)) + 1\0") == "1");
    sqlite3_close(db);
}

unittest {
    // A batch takes as many rows as it is told, and says where it stopped.
    enum content = `{"a":1}` ~ "\n" ~ `{"a":2}` ~ "\n" ~ `{"a":3}` ~ "\n";
    __gshared Batch b;
    batchFrom(b, content, 0, "/t/c.jsonl", "s", 1, 2);
    assert(b.rows == 2);
    assert(b.end == 16);
}

// k keeps an attestation of at most a megabyte (QNTX crates/ats-duckdb/src/ffi.rs),
// and refused a 1.08 MB line: every file stopped behind it (2026-11-21). A file
// stops at the line the node refused, the lines before it are sent, and the
// other files go on. The line is asked again later, never passed over.
unittest {
    import direct : stuckAt;
    enum content = `{"a":1}` ~ "\n" ~ `{"a":2}` ~ "\n" ~ `{"a":3}` ~ "\n";
    __gshared Batch b;
    batchFrom(b, content, 50, "/t/c.jsonl", "s", 1, 256);
    assert(b.rows == 3);
    assert(b.starts[0] == 50 && b.starts[1] == 58 && b.starts[2] == 66, "where each row's line starts");

    // <path> TAB <offset> TAB <unix time>: the last said for a file stands.
    enum kept = "/t/a.jsonl\t120\t1000\n/t/b.jsonl\t7\t900\n/t/a.jsonl\t120\t5000\n";
    assert(stuckAt(kept, "/t/a.jsonl", 120) == 5000, "stuck there, since then");
    assert(stuckAt(kept, "/t/a.jsonl", 340) == 0, "past it, it is not stuck");
    assert(stuckAt(kept, "/t/c.jsonl", 0) == 0);
}

// 600 lines a second stopped k's node: "the operational store did not answer
// in 1m0s" (2026-11-21T14:59Z). A batch is small, and the wait after one is
// twice what the node took to answer it, so the node gives this at most a
// third of its time.
unittest {
    import direct : waitAfter, BATCH_BYTES;
    enum content = `{"a":1}` ~ "\n" ~ `{"a":2}` ~ "\n" ~ `{"a":3}` ~ "\n";
    __gshared Batch b;
    batchFrom(b, content, 0, "/t/c.jsonl", "s", 1, 256, 10);
    assert(b.rows == 1, "a batch past its bytes takes no more rows, and always one");
    batchFrom(b, content, 0, "/t/c.jsonl", "s", 1, 256, BATCH_BYTES);
    assert(b.rows == 3);

    assert(waitAfter(1_000_000) == 2_000_000, "twice what the node took");
    assert(waitAfter(10_000) == 250_000, "and never less than a quarter second");
    assert(waitAfter(60_000_000) == 30_000_000, "nor more than half a minute");
}

// Paced by twice the node's answer time, k's node still stopped (2026-11-21
// 17:11Z): k was at 49% I/O wait with nothing sent to it. A batch is sixteen
// lines, and a node that takes more than two seconds over one is busy: the
// pass ends there and nothing more is sent until the caller comes back.
unittest {
    import direct : nodeBusy, TRICKLE_ROWS, TRICKLE_BYTES;
    assert(TRICKLE_ROWS == 16);
    assert(TRICKLE_BYTES == 64 * 1024);
    assert(!nodeBusy(1_999_999));
    assert(nodeBusy(2_000_001), "slower than two seconds over sixteen lines is a node to leave alone");
}
