module say_test;

// "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"

version (Posix):

import say;
import zbuf : ZBuf;

// A name is a tenant of its node's A2A, and a name of two words is written as
// an address writes one.
unittest {
    ZBuf url;
    tenantUrl(url, "https://api.q.sbvh.nl", "Slate");
    assert(url.slice() == "https://api.q.sbvh.nl/a2a/Slate", url.slice());
    tenantUrl(url, "https://api.q.sbvh.nl", "Ada Lovelace");
    assert(url.slice() == "https://api.q.sbvh.nl/a2a/Ada%20Lovelace", url.slice());
}

// "A SESSION THATS SENDING TO ANOTHER SESSION BY NAME IS TOLD ABOUT THE MESSAGE BEING RECEIVED OR NOT"
unittest {
    assert(stateSaid("TASK_STATE_SUBMITTED") == "is not received yet");
    assert(stateSaid("TASK_STATE_COMPLETED") == "was received");
    assert(stateSaid("TASK_STATE_FAILED") == "was not received");
}

// "do you think the ground say should show near misses ?"
// A name nobody holds is said so, with the names the node says are near it.
unittest {
    ZBuf line;
    auto answer = `{"error":{"code":404,"status":"NOT_FOUND","message":"no agent is served at tenant Kwi Kwi. Near it: Kwikwi","details":[]}}`;
    assert(nobodyHolds("Kwi Kwi", answer, line) == "nobody holds the name Kwi Kwi. Near it: Kwikwi", line.slice());
    auto alone = `{"error":{"code":404,"message":"no agent is served at tenant Slate","details":[]}}`;
    assert(nobodyHolds("Slate", alone, line) == "nobody holds the name Slate", line.slice());
    assert(nobodyHolds("Slate", `{"error":{"code":404,"message":"no such task"}}`, line) == "");
}

// "Getting A2UI pieces to show up in another session from this one"
// "i expect my own workflow to not change"
// What is said without a surface is the one text part it always was.
unittest {
    import code.reply : Reply;
    Reply body_;
    scope (exit) body_.dispose();
    const(char)*[2] words = ["the build on k", "is red"];
    assert(saidBody(body_, "ground-say-1-2", words[], "") == "");
    assert(body_.slice() == `{"message":{"messageId":"ground-say-1-2","role":"ROLE_USER","parts":[{"text":"the build on k is red"}]},"configuration":{"returnImmediately":true}}`, body_.slice());
}

// A surface is said beside the words, as A2UI over A2A says it: a data part of
// application/a2ui+json whose data is a list of A2UI messages.
unittest {
    import code.reply : Reply;
    Reply body_;
    scope (exit) body_.dispose();
    const(char)*[1] words = ["Which do I do first?"];
    auto one = `{"version":"1.0","createSurface":{"surfaceId":"which-first","catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}}`;
    assert(saidBody(body_, "ground-say-1-2", words[], one) == "");
    assert(body_.slice() == `{"message":{"messageId":"ground-say-1-2","role":"ROLE_USER","parts":[{"text":"Which do I do first?"},{"data":[{"version":"1.0","createSurface":{"surfaceId":"which-first","catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}}],"mediaType":"application/a2ui+json","metadata":{"mimeType":"application/a2ui+json"}}]},"configuration":{"returnImmediately":true}}`, body_.slice());

    body_.dispose();
    auto two = `[{"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"c"}},{"version":"1.0","deleteSurface":{"surfaceId":"s"}}]`;
    assert(saidBody(body_, "ground-say-1-2", words[], two) == "");
    assert(body_.slice() == `{"message":{"messageId":"ground-say-1-2","role":"ROLE_USER","parts":[{"text":"Which do I do first?"},{"data":` ~ two ~ `,"mediaType":"application/a2ui+json","metadata":{"mimeType":"application/a2ui+json"}}]},"configuration":{"returnImmediately":true}}`, body_.slice());
}

// What is no list of A2UI 1.0 messages is not said, and says why.
unittest {
    import code.reply : Reply;
    Reply body_;
    scope (exit) body_.dispose();
    const(char)*[1] words = ["x"];
    assert(saidBody(body_, "i", words[], `{"version":"1.0",`) == "the surface is no JSON");
    assert(saidBody(body_, "i", words[], `"text"`) == "the surface is neither an A2UI message nor a list of them");
    assert(saidBody(body_, "i", words[], `[]`) == "the surface is a list of no A2UI messages");
    assert(saidBody(body_, "i", words[], `[1]`) == "the surface's message 0 is no JSON object");
    assert(saidBody(body_, "i", words[], `{"createSurface":{}}`) == "the surface's message 0 says no \"version\": \"1.0\"");
    assert(saidBody(body_, "i", words[], `[{"version":"1.0"},{"version":"0.9"}]`) == "the surface's message 1 says no \"version\": \"1.0\"");
}
