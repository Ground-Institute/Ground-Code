module administers;

// "but laye owns people not ground, ground will always get it from laye"
// "its the story of someone verifying they can trust laye the network they are about to join, with their agent"
// "that laye itself laye ground institue itself has its own pbt governing itself, and you can see it on github, and that is what verified means"
//
// 「[Fable 5.2] A pbt says who administers a laye: the administrator of the org that governs」
// 「[Fable 5.2] it. ground asks that laye whether it says so too.」

import proto : ParsedOrg, ParsedLaye;
import zbuf : ZBuf;

enum BOOK_COMMAND = q"EOS
# who this ground's pbt says administers the laye it names, and whether that laye says so too:
ground laye
EOS";

// 「[Fable 5.2] Who a pbt says administers its laye: the administrator of the org that」
// 「[Fable 5.2] governs it. Empty when no org governs it, or that org names nobody.」
string administratorOf(const(ParsedOrg)[] orgs, const ParsedLaye laye) {
    if (laye.org.length == 0) return "";
    foreach (ref o; orgs) if (o.name == laye.org) return o.administrator;
    return "";
}

// 「[Fable 5.2] What laye is asked: <url>/laye/administrator/<name>, at the laye the pbt names.」
void askedAt(ref ZBuf url, const(char)[] laye, const(char)[] name) {
    while (laye.length > 0 && laye[$ - 1] == '/') laye = laye[0 .. $ - 1];
    url.put(laye);
    url.put("/laye/administrator/");
    url.put(name);
}

private bool blank(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

// 「[Fable 5.2] laye's yes is the word true beside "administers", and nothing else is one.」
bool saysYes(const(char)[] answer) {
    enum key = `"administers"`;
    size_t at = 0;
    bool found = false;
    for (; at + key.length <= answer.length; at++)
        if (answer[at .. at + key.length] == key) { found = true; break; }
    if (!found) return false;
    at += key.length;
    while (at < answer.length && blank(answer[at])) at++;
    if (at >= answer.length || answer[at] != ':') return false;
    at++;
    while (at < answer.length && blank(answer[at])) at++;
    return at + 4 <= answer.length && answer[at .. at + 4] == "true";
}

// 「[Fable 5.2] ground laye: the laye this ground's controls name, who its pbt says」
// 「[Fable 5.2] administers it, and whether that laye says so too. 0 when it does.」
int handleLaye() {
    import core.stdc.stdio : stdout, stderr, fputs;
    import controls : allOrgs, layeNetwork;
    import http : httpGet;

    auto laye = layeNetwork();
    __gshared ZBuf say;
    say.reset();
    if (!laye.present || laye.url.length == 0) {
        fputs("ground laye: this ground's controls name no laye: laye { url: }\n", stderr);
        return 1;
    }
    auto who = administratorOf(allOrgs(), laye);
    if (who.length == 0) {
        say.put(laye.url);
        say.put(": its pbt names nobody who administers it: laye { org: } and that org's administrator:\n");
        fputs(say.ptr(), stderr);
        return 1;
    }

    __gshared ZBuf url;
    url.reset();
    askedAt(url, laye.url, who);
    __gshared char[4096] reply;
    auto r = httpGet(url.slice(), cast(const(char)[]) null, reply[], 10);
    auto answer = reply[0 .. r.len];
    if (r.status != 200) {
        say.put(url.slice());
        if (r.status > 0) {
            say.put(" answered ");
            say.putUint(r.status);
            say.put(": ");
            say.put(answer);
        } else {
            say.put(" was not reached: ");
            say.put(r.why());
            say.put(" (libcurl ");
            say.putUint(r.code);
            say.put(")");
        }
        say.put("\n");
        fputs(say.ptr(), stderr);
        return 1;
    }
    if (!saysYes(answer)) {
        say.put(laye.url);
        say.put(": its pbt names ");
        say.put(who);
        say.put(" as the administrator of ");
        say.put(laye.org);
        say.put(", and laye does not say ");
        say.put(who);
        say.put(" administers it: ");
        say.put(answer);
        say.put("\n");
        fputs(say.ptr(), stderr);
        return 1;
    }
    say.put(laye.url);
    say.put(": ");
    say.put(who);
    say.put(" administers it, as the administrator of ");
    say.put(laye.org);
    say.put("; laye says so too\n");
    fputs(say.ptr(), stdout);
    return 0;
}
