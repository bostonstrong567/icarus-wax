/* waxnet: downloads files from the Wax mod catalogue for Lua, which cannot make web requests. It never touches Lua. */
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>

#define HOST L"wax-icarus.duckdns.org"
#define MAX_JOBS 600
#define MAX_ANSWER (25ULL * 1024 * 1024)
#define MAX_RUN (64ULL * 1024 * 1024)
#define MAX_REQUEST (512 * 1024)
#define MAX_URL 1024
#define MAX_OUT 220
#define TIMEOUT_MS 20000
#define JOB_MS 90000
#define CHUNK 65536
#define TRIES 4

typedef struct {
    WCHAR net[MAX_PATH];
    DWORD net_len;
    WCHAR agent[40];
    HINTERNET session, connect;
    BCRYPT_ALG_HANDLE sha;
    unsigned char *chunk;
    unsigned long long total;
    int broken;
    char why[64];
} Run;

static volatile LONG running;
static const char anchor = 0;

static char *put(char *at, const char *text)
{
    while (*text) *at++ = *text++;
    return at;
}

static char *put_number(char *at, unsigned long long value)
{
    char digits[24];
    int n = 0;
    do { digits[n++] = (char)('0' + value % 10); value /= 10; } while (value);
    while (n) *at++ = digits[--n];
    return at;
}

static int is_alnum(char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int same(const char *text, DWORD n, const char *word)
{
    DWORD i;
    for (i = 0; i < n; i++) {
        if (!word[i] || (text[i] | 32) != (word[i] | 32)) return 0;
    }
    return word[n] == 0;
}

static int ends(const char *text, DWORD n, const char *tail)
{
    DWORD m = 0;
    while (tail[m]) m++;
    return n >= m && same(text + n - m, m, tail);
}

/* Windows opens these names as devices, with or without an ending. */
static int device(const char *stem, DWORD n)
{
    if (n == 3) return same(stem, 3, "con") || same(stem, 3, "prn") || same(stem, 3, "aux") || same(stem, 3, "nul");
    if (n == 4 && stem[3] >= '0' && stem[3] <= '9') return same(stem, 3, "com") || same(stem, 3, "lpt");
    return 0;
}

static int good_name(const char *name, DWORD n)
{
    DWORD i, stem = 0;
    if (n == 0 || name[0] == ' ' || name[n - 1] == ' ' || name[n - 1] == '.') return 0;
    for (i = 0; i + 1 < n; i++) {
        if (name[i] == '.' && name[i + 1] == '.') return 0;
    }
    while (stem < n && name[stem] != '.') stem++;
    while (stem > 0 && name[stem - 1] == ' ') stem--;
    return !device(name, stem);
}

/* An output path: folders and a name inside run\net, forward slashes only. */
static int good_out(const char *out, DWORD n)
{
    DWORD i, from = 0;
    if (n == 0 || n > MAX_OUT) return 0;
    for (i = 0; i <= n; i++) {
        if (i < n && out[i] != '/') {
            char c = out[i];
            if (!is_alnum(c) && c != ' ' && c != '.' && c != '_' && c != '-') return 0;
            continue;
        }
        if (!good_name(out + from, i - from)) return 0;
        from = i + 1;
    }
    if (ends(out, n, ".status") || ends(out, n, ".part")) return 0;
    return !same(out, n, "done") && !same(out, n, "request.txt");
}

static int good_url(const char *url, DWORD n)
{
    DWORD i;
    if (n < 6 || n > MAX_URL) return 0;
    if (url[0] != '/' || url[1] != 'a' || url[2] != 'p' || url[3] != 'i' || url[4] != '/') return 0;
    for (i = 0; i < n; i++) {
        char c = url[i];
        if (!is_alnum(c) && c != '/' && c != '.' && c != '_' && c != '-' && c != '%' && c != '?' && c != '=' && c != '&') return 0;
        if ((c == '.' || c == '/') && i + 1 < n && url[i + 1] == c) return 0;
        if (c == '%') {
            int high = i + 2 < n ? hex_value(url[i + 1]) : -1, low = i + 2 < n ? hex_value(url[i + 2]) : -1;
            int value = high * 16 + low;
            if (high < 0 || low < 0 || value < 0x20 || value == 0x7f || value == '.' || value == '/' || value == '\\') return 0;
        }
    }
    return 1;
}

/* Writes "<Wax root>\" into root and returns its length. The root is the folder above this file's own bin folder. */
static DWORD find_root(WCHAR *root)
{
    HMODULE self = NULL;
    WCHAR raw[MAX_PATH];
    DWORD n, i, last = 0, before = 0;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCWSTR)(const void *)&anchor, &self)) return 0;
    n = GetModuleFileNameW(self, raw, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 0;
    n = GetFullPathNameW(raw, MAX_PATH, root, NULL);
    if (n == 0 || n >= MAX_PATH) return 0;
    for (i = 0; i < n; i++) {
        if (root[i] == L'\\') { before = last; last = i; }
    }
    if (before == 0 || last - before != 4) return 0;
    if ((root[before + 1] | 32) != L'b' || (root[before + 2] | 32) != L'i' || (root[before + 3] | 32) != L'n') return 0;
    root[before + 1] = 0;
    return before + 1;
}

/* Writes "<Wax root>\run\net\" into net, makes the two folders, and returns the length. */
static DWORD make_net(WCHAR *net)
{
    static const WCHAR run[] = L"run", inner[] = L"\\net";
    DWORD n = find_root(net), i;
    if (n == 0 || n + 12 >= MAX_PATH) return 0;
    for (i = 0; run[i]; i++) net[n++] = run[i];
    net[n] = 0;
    CreateDirectoryW(net, NULL);
    for (i = 0; inner[i]; i++) net[n++] = inner[i];
    net[n] = 0;
    CreateDirectoryW(net, NULL);
    if (GetFileAttributesW(net) == INVALID_FILE_ATTRIBUTES) return 0;
    net[n++] = L'\\';
    net[n] = 0;
    return n;
}

static int join(const Run *run, const char *out, DWORD n, const WCHAR *tail, WCHAR *full)
{
    DWORD i, at = run->net_len, extra = (DWORD)lstrlenW(tail);
    if (at + n + extra + 1 >= MAX_PATH) return 0;
    for (i = 0; i < at; i++) full[i] = run->net[i];
    for (i = 0; i < n; i++) full[at++] = out[i] == '/' ? L'\\' : (WCHAR)out[i];
    for (i = 0; i < extra; i++) full[at++] = tail[i];
    full[at] = 0;
    return 1;
}

/* Makes the folders an output sits in. A link in the way is refused, so nothing is written outside run\net. */
static int make_parents(const Run *run, const char *out, DWORD n)
{
    WCHAR path[MAX_PATH];
    DWORD i, at = run->net_len;
    if (at + n + 1 >= MAX_PATH) return 0;
    for (i = 0; i < at; i++) path[i] = run->net[i];
    for (i = 0; i < n; i++) {
        if (out[i] == '/') {
            DWORD kind;
            path[at] = 0;
            kind = GetFileAttributesW(path);
            if (kind == INVALID_FILE_ATTRIBUTES) {
                if (!CreateDirectoryW(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return 0;
            } else if (!(kind & FILE_ATTRIBUTE_DIRECTORY) || (kind & FILE_ATTRIBUTE_REPARSE_POINT)) {
                return 0;
            }
            path[at++] = L'\\';
        } else {
            path[at++] = (WCHAR)out[i];
        }
    }
    return 1;
}

static int save(const WCHAR *path, const char *data, DWORD size)
{
    DWORD written = 0;
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    int ok;
    if (file == INVALID_HANDLE_VALUE) return 0;
    ok = WriteFile(file, data, size, &written, NULL) && written == size;
    CloseHandle(file);
    return ok;
}

static char *slurp(const WCHAR *path, DWORD limit, DWORD *size)
{
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    DWORD length, got = 0, done = 0;
    char *data = NULL;
    if (file == INVALID_HANDLE_VALUE) return NULL;
    length = GetFileSize(file, NULL);
    if (length != INVALID_FILE_SIZE && length <= limit) data = HeapAlloc(GetProcessHeap(), 0, (SIZE_T)length + 1);
    while (data && done < length) {
        if (!ReadFile(file, data + done, length - done, &got, NULL) || got == 0) {
            HeapFree(GetProcessHeap(), 0, data);
            data = NULL;
        } else {
            done += got;
        }
    }
    CloseHandle(file);
    if (data) *size = length;
    return data;
}

/* The status file of an output: "<http status> <bytes> <sha256>", or "<status> 0 - <reason>" when there is no file. */
static void say(const Run *run, const char *out, DWORD n, DWORD code, unsigned long long bytes, const unsigned char *digest, const char *why)
{
    static const char hex[] = "0123456789abcdef";
    WCHAR path[MAX_PATH];
    char line[160], *at = line;
    int i;
    if (!join(run, out, n, L".status", path)) return;
    at = put_number(at, code);
    *at++ = ' ';
    at = put_number(at, digest ? bytes : 0);
    *at++ = ' ';
    if (digest) {
        for (i = 0; i < 32; i++) { *at++ = hex[digest[i] >> 4]; *at++ = hex[digest[i] & 15]; }
    } else {
        *at++ = '-';
        if (why && *why) { *at++ = ' '; at = put(at, why); }
    }
    *at++ = '\n';
    save(path, line, (DWORD)(at - line));
}

static void blame(Run *run, const char *what, DWORD error)
{
    char *at = put(run->why, what);
    if (error) {
        at = put(at, " (");
        at = put_number(at, error);
        *at++ = ')';
    }
    *at = 0;
    run->broken = 1;
}

/* One GET into the file `part`. Returns the http status, or 0 with run->why set when no usable answer came. */
static DWORD fetch(Run *run, const WCHAR *address, const WCHAR *part, unsigned long long *bytes, unsigned char *digest, DWORD *wait)
{
    HINTERNET request = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    BCRYPT_HASH_HANDLE hash = NULL;
    DWORD code = 0, size = sizeof code, off = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    DWORD got = 0, written = 0, answered = 0;
    ULONGLONG started = GetTickCount64();
    *bytes = 0;
    run->why[0] = 0;

    if (!run->session) {
        run->session = WinHttpOpen(run->agent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!run->session) run->session = WinHttpOpen(run->agent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (run->session) WinHttpSetTimeouts(run->session, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS);
    }
    if (run->session && !run->connect) run->connect = WinHttpConnect(run->session, HOST, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!run->connect) { blame(run, "could not start a connection", GetLastError()); goto out; }

    request = WinHttpOpenRequest(run->connect, L"GET", address, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!request || !WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &off, sizeof off)) {
        blame(run, "could not make the request", GetLastError());
        goto out;
    }
    if (!WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
            || !WinHttpReceiveResponse(request, NULL)) {
        blame(run, "no connection", GetLastError());
        goto out;
    }
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &answered, &size,
            WINHTTP_NO_HEADER_INDEX)) {
        blame(run, "no status in the answer", GetLastError());
        goto out;
    }
    if (answered != 200) {
        code = answered;
        size = sizeof *wait;
        if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_RETRY_AFTER | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, wait, &size,
                WINHTTP_NO_HEADER_INDEX)) *wait = 2;
        goto out;
    }

    file = CreateFileW(part, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) { blame(run, "could not write the file", GetLastError()); goto out; }
    if (BCryptCreateHash(run->sha, &hash, NULL, 0, NULL, 0, 0) < 0) { hash = NULL; blame(run, "could not start the checksum", 0); goto out; }
    for (;;) {
        if (!WinHttpReadData(request, run->chunk, CHUNK, &got)) { blame(run, "the answer stopped part way", GetLastError()); break; }
        if (got == 0) {
            if (BCryptFinishHash(hash, digest, 32, 0) < 0) blame(run, "could not finish the checksum", 0);
            else code = 200;
            break;
        }
        *bytes += got;
        run->total += got;
        if (*bytes > MAX_ANSWER) { blame(run, "the answer is larger than 25 MB", 0); break; }
        if (run->total > MAX_RUN) { blame(run, "the answers are larger than 64 MB in all", 0); break; }
        if (GetTickCount64() - started > JOB_MS) { blame(run, "the answer took too long", 0); break; }
        if (BCryptHashData(hash, run->chunk, got, 0) < 0) { blame(run, "could not work out the checksum", 0); break; }
        if (!WriteFile(file, run->chunk, got, &written, NULL) || written != got) { blame(run, "could not write the file", GetLastError()); break; }
    }

out:
    if (hash) BCryptDestroyHash(hash);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (request) WinHttpCloseHandle(request);
    if (code != 200) DeleteFileW(part);
    return code;
}

static void get(Run *run, const char *url, DWORD url_len, const char *out, DWORD out_len)
{
    WCHAR address[MAX_URL + 1], status[MAX_PATH], part[MAX_PATH], final[MAX_PATH];
    unsigned char digest[32];
    unsigned long long bytes = 0;
    DWORD code = 0, wait = 2, i;
    int attempt;

    if (!join(run, out, out_len, L".status", status) || !join(run, out, out_len, L".part", part) || !join(run, out, out_len, L"", final)) return;
    if (!make_parents(run, out, out_len)) return;
    DeleteFileW(status);
    if (!good_url(url, url_len)) {
        DeleteFileW(final);
        say(run, out, out_len, 0, 0, NULL, "this address is not allowed");
        return;
    }
    if (run->broken) {
        DeleteFileW(final);
        say(run, out, out_len, 0, 0, NULL, "not tried after an earlier failure");
        return;
    }
    for (i = 0; i < url_len; i++) address[i] = (WCHAR)url[i];
    address[url_len] = 0;
    for (attempt = 0; attempt < TRIES; attempt++) {
        code = fetch(run, address, part, &bytes, digest, &wait);
        if (code != 429 || attempt == TRIES - 1) break;
        Sleep((wait < 1 ? 1 : wait > 30 ? 30 : wait) * 1000);
    }
    if (code == 200 && MoveFileExW(part, final, MOVEFILE_REPLACE_EXISTING)) {
        say(run, out, out_len, 200, bytes, digest, NULL);
        return;
    }
    if (code == 200) {
        code = 0;
        blame(run, "could not save the file", GetLastError());
        DeleteFileW(part);
    }
    DeleteFileW(final);
    say(run, out, out_len, code, 0, NULL, run->why);
}

/* Deletes a folder and what is in it. A link is removed as a link, never followed. */
static int wipe(WCHAR *path, DWORD len, int depth)
{
    WIN32_FIND_DATAW item;
    HANDLE find;
    DWORD kind = GetFileAttributesW(path);
    int ok = 1;
    if (kind == INVALID_FILE_ATTRIBUTES) return GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND;
    if (!(kind & FILE_ATTRIBUTE_DIRECTORY)) {
        if (kind & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL);
        return DeleteFileW(path) != 0;
    }
    if (kind & FILE_ATTRIBUTE_REPARSE_POINT) return RemoveDirectoryW(path) != 0;
    if (depth > 32 || len + 3 >= MAX_PATH) return 0;
    path[len] = L'\\';
    path[len + 1] = L'*';
    path[len + 2] = 0;
    find = FindFirstFileW(path, &item);
    path[len] = 0;
    if (find != INVALID_HANDLE_VALUE) {
        do {
            const WCHAR *name = item.cFileName;
            DWORD n = (DWORD)lstrlenW(name), i;
            if (name[0] == L'.' && (name[1] == 0 || (name[1] == L'.' && name[2] == 0))) continue;
            if (len + 1 + n + 3 >= MAX_PATH) { ok = 0; continue; }
            path[len] = L'\\';
            for (i = 0; i < n; i++) path[len + 1 + i] = name[i];
            path[len + 1 + n] = 0;
            if (!wipe(path, len + 1 + n, depth + 1)) ok = 0;
            path[len] = 0;
        } while (FindNextFileW(find, &item));
        FindClose(find);
    }
    return RemoveDirectoryW(path) != 0 && ok;
}

/* A request line "-<TAB>stage/<folder>" empties that folder before files are fetched into it. */
static void clear(Run *run, const char *out, DWORD out_len)
{
    WCHAR status[MAX_PATH], path[MAX_PATH];
    int ok;
    if (!join(run, out, out_len, L".status", status) || !join(run, out, out_len, L"", path)) return;
    if (!make_parents(run, out, out_len)) return;
    DeleteFileW(status);
    if (out_len < 7 || !same(out, 6, "stage/")) {
        say(run, out, out_len, 0, 0, NULL, "only folders under stage can be cleared");
        return;
    }
    ok = wipe(path, (DWORD)lstrlenW(path), 0);
    say(run, out, out_len, ok ? 200 : 0, 0, NULL, ok ? "" : "the folder could not be cleared");
}

/* "Wax/<version>", the version being the first line of <Wax root>\VERSION. */
static void name_agent(Run *run)
{
    static const WCHAR prefix[] = L"Wax/", file[] = L"VERSION";
    WCHAR path[MAX_PATH];
    DWORD n = find_root(path), i, size = 0, at = 0;
    char *text = NULL;
    for (i = 0; prefix[i]; i++) run->agent[at++] = prefix[i];
    if (n && n + 8 < MAX_PATH) {
        for (i = 0; file[i]; i++) path[n + i] = file[i];
        path[n + i] = 0;
        text = slurp(path, 64, &size);
    }
    for (i = 0; text && i < size && i < 24 && (is_alnum(text[i]) || text[i] == '.' || text[i] == '-'); i++) run->agent[at++] = (WCHAR)text[i];
    if (at == 4) { run->agent[at++] = L'd'; run->agent[at++] = L'e'; run->agent[at++] = L'v'; }
    run->agent[at] = 0;
    if (text) HeapFree(GetProcessHeap(), 0, text);
}

static void work(void)
{
    static const WCHAR asked[] = L"request.txt", finished[] = L"done", unfinished[] = L"done.part";
    WCHAR request_path[MAX_PATH], done_path[MAX_PATH], part_path[MAX_PATH];
    char id[24] = "#0", *text = NULL;
    DWORD size = 0, at = 0, i, jobs = 0;
    int first = 1;
    Run *run = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *run);
    if (!run) return;
    run->net_len = make_net(run->net);
    if (run->net_len == 0 || run->net_len + 16 >= MAX_PATH) goto out;
    for (i = 0; i < run->net_len; i++) request_path[i] = done_path[i] = part_path[i] = run->net[i];
    lstrcpyW(request_path + run->net_len, asked);
    lstrcpyW(done_path + run->net_len, finished);
    lstrcpyW(part_path + run->net_len, unfinished);

    text = slurp(request_path, MAX_REQUEST, &size);
    if (!text) goto out;
    DeleteFileW(request_path);
    DeleteFileW(done_path);
    run->chunk = HeapAlloc(GetProcessHeap(), 0, CHUNK);
    if (!run->chunk || BCryptOpenAlgorithmProvider(&run->sha, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0) { run->sha = NULL; goto out; }
    name_agent(run);

    while (at < size) {
        DWORD start = at, end, tab;
        while (at < size && text[at] != '\n') at++;
        end = at;
        if (at < size) at++;
        if (end > start && text[end - 1] == '\r') end--;
        if (end == start) continue;
        if (first && text[start] == '#') {
            for (i = 1; i < 19 && start + i < end && text[start + i] >= '0' && text[start + i] <= '9'; i++) id[i] = text[start + i];
            if (i > 1) id[i] = 0;
            first = 0;
            continue;
        }
        first = 0;
        for (tab = start; tab < end && text[tab] != '\t'; tab++) {}
        if (tab == end) continue;
        if (++jobs > MAX_JOBS) break;
        if (!good_out(text + tab + 1, end - tab - 1)) continue;
        if (tab - start == 1 && text[start] == '-') clear(run, text + tab + 1, end - tab - 1);
        else get(run, text + start, tab - start, text + tab + 1, end - tab - 1);
    }

    for (i = 0; id[i]; i++) {}
    id[i++] = '\n';
    if (save(part_path, id, i)) MoveFileExW(part_path, done_path, MOVEFILE_REPLACE_EXISTING);

out:
    if (run->connect) WinHttpCloseHandle(run->connect);
    if (run->session) WinHttpCloseHandle(run->session);
    if (run->sha) BCryptCloseAlgorithmProvider(run->sha, 0);
    if (run->chunk) HeapFree(GetProcessHeap(), 0, run->chunk);
    if (text) HeapFree(GetProcessHeap(), 0, text);
    HeapFree(GetProcessHeap(), 0, run);
}

/* The thread keeps this file loaded until it has finished, whatever Lua does meanwhile. */
static DWORD WINAPI worker(LPVOID self)
{
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    work();
    InterlockedExchange(&running, 0);
    FreeLibraryAndExitThread((HMODULE)self, 0);
    return 0;
}

/* wax_net_ready(): makes <Wax root>\run\net, so that Lua can write its request there. */
__declspec(dllexport) int wax_net_ready(void *state)
{
    WCHAR net[MAX_PATH];
    (void)state;
    make_net(net);
    return 0;
}

/* wax_net_run(): starts the thread that does what run\net\request.txt asks. Does nothing while one is running. */
__declspec(dllexport) int wax_net_run(void *state)
{
    HMODULE self = NULL;
    HANDLE thread;
    (void)state;
    if (InterlockedCompareExchange(&running, 1, 0) != 0) return 0;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCWSTR)(const void *)&anchor, &self)) {
        InterlockedExchange(&running, 0);
        return 0;
    }
    thread = CreateThread(NULL, 0, worker, self, 0, NULL);
    if (!thread) {
        FreeLibrary(self);
        InterlockedExchange(&running, 0);
        return 0;
    }
    CloseHandle(thread);
    return 0;
}
