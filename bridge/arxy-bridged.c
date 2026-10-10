// SPDX-License-Identifier: GPL-3.0-or-later
// arxy-bridged — daemon host-bridge de arxy.
// Protocolo: framing 4B big-endian + JSON, MaxFrame 128KiB,
// mensajes request/input/close-input/resize/output/error/exit, auth SO_PEERCRED
// (uid peer == getuid()) + token opcional del daemon (--token; NULL = sin
// exigir, compat tests; ver OUT-OF-SCOPE §12), socket 0600, allowlist por
// realpath + X_OK, límites.
// C11/POSIX, solo libc, sin dependencias externas.
// Uso: arxy-bridged --socket PATH --allowed-cmd BIN [...]
// DEUDA (auditoría pre-commit):
// BLOQUEANTES resueltos (con tests en bridge/test-bridge.sh):
//  1. jskip con tope JSON_MAX_DEPTH (era recursivo sin tope).
//  2. resolve_cmd rechaza relativo con '/' y componentes PATH no absolutos.
//  3. Strict JSON: claves desconocidas y basura tras '}' se rechazan.
//  4. \u subrogados se combinan (huérfanos se rechazan).
// HARDENING (no bloqueante):
// TODO: TOCTOU realpath->execv; upgrade: openat2 RESOLVE_* o fexecve.
// TODO: EINTR en drenaje final; upgrade: reintentar read en [done].
// TODO: padding base64 interior laxo; upgrade: exigir '=' solo al final.
// TODO: off-by-one 65/64 en parse (inocuo: authorize() limita a MAXARGS).
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define MAXFRAME (128u * 1024u) // == hrun MaxFrameSize
#define MAXARGS 64 // spec D1 (hrun usa 256)
#define MAXARGSZ 4096 // spec D1: 4KiB por arg (hrun usa 16KiB)
#define CHUNK 32768 // lectura salida hijo (b64 cabe holgado en MaxFrame)
#define INQUEUEMAX (4u * 1024u * 1024u) // tope de stdin pendiente
// Magia centralizada (estaba duplicada en session/resize/listener):
#define WS_MAXDIM 65536 // tope de columna/fila pedida
#define WS_DEF_COLS 80 // defecto como xterm
#define WS_DEF_ROWS 24
#define REQ_TIMEOUT_MS 10000 // espera del request (== hrun requestTimeout)
#define LISTEN_BACKLOG 16
#define DIR_MODE 0700 // dir del socket
#define SOCK_MODE 0600
#define UMASK_PRIV 077 // lo creado sale 0700/0600 aunque el umask sea otro
#define EXIT_NOEXEC 127 // hijo que no se pudo ejecutar (== shell)
#define EXIT_NOSIG 126 // hijo muerto sin exit ni señal (== bash)
#define EXIT_SIGNAL_BASE 128 // 128+señal (== bash)

static char **g_allow;
static int g_nallow;
static const char *g_sockpath;
static const char *g_token = NULL; // NULL = sin exigir (compat tests sin token)

static void die(const char *m) { fprintf(stderr, "arxy-bridged: %s\n", m); exit(1); }
static char diebuf[512]; // mensajes die() con contexto (path+strerror)
static void usage(void) { fprintf(stderr, "uso: arxy-bridged --socket PATH --allowed-cmd BIN [...]\n"); }

// ---------- io ----------
static int wfull(int fd, const void *b, size_t n) {
    size_t o = 0;
    while (o < n) {
        ssize_t w = write(fd, (const char *)b + o, n - o);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        o += (size_t)w;
    }
    return 0;
}
static void nonblock(int fd) { int f = fcntl(fd, F_GETFL); if (f >= 0) fcntl(fd, F_SETFL, f | O_NONBLOCK); }

// ---------- base64 (Data de hrun es []byte -> JSON b64) ----------
static const char b64t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char *b64enc(const uint8_t *in, size_t n) {
    size_t o = 4 * ((n + 2) / 3);
    char *s = malloc(o + 1);
    if (!s) return NULL;
    size_t i = 0, j = 0;
    while (i < n) {
        uint32_t a = in[i++], b = i < n ? in[i++] : 0, c = i < n ? in[i++] : 0;
        uint32_t t = (a << 16) | (b << 8) | c; // a siempre existe (i<n)
        s[j++] = b64t[(t >> 18) & 63]; s[j++] = b64t[(t >> 12) & 63];
        s[j++] = b64t[(t >> 6) & 63]; s[j++] = b64t[t & 63];
    }
    for (size_t k = 0; k < (3 - n % 3) % 3; k++) s[o - 1 - k] = '=';
    s[o] = 0;
    return s;
}
static int b64v(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}
static uint8_t *b64dec(const char *s, size_t n, size_t *on) {
    if (n % 4) return NULL;
    size_t pad = 0;
    if (n >= 1 && s[n - 1] == '=') pad++;
    if (n >= 2 && s[n - 2] == '=') pad++;
    uint8_t *o = malloc(n / 4 * 3 + 1);
    if (!o) return NULL;
    size_t j = 0;
    for (size_t i = 0; i < n; i += 4) {
        int a = b64v(s[i]), b = b64v(s[i + 1]);
        int c = s[i + 2] == '=' ? 0 : b64v(s[i + 2]);
        int d = s[i + 3] == '=' ? 0 : b64v(s[i + 3]);
        if (a < 0 || b < 0 || c < 0 || d < 0) { free(o); return NULL; }
        uint32_t t = ((uint32_t)a << 18) | ((uint32_t)b << 12) | ((uint32_t)c << 6) | (uint32_t)d;
        o[j++] = (uint8_t)(t >> 16); o[j++] = (uint8_t)(t >> 8); o[j++] = (uint8_t)t;
    }
    *on = j - pad;
    return o;
}

// ---------- JSON emitido ----------
static char *jesc(const char *s) {
    size_t n = 0;
    for (const char *p = s; *p; p++) n += (*p == '"' || *p == '\\' || (uint8_t)*p < 32) ? 6 : 1;
    char *o = malloc(n + 1), *q = o;
    if (!o) return NULL;
    for (const char *p = s; *p; p++) {
        uint8_t c = (uint8_t)*p;
        if (c == '"') { *q++ = '\\'; *q++ = '"'; }
        else if (c == '\\') { *q++ = '\\'; *q++ = '\\'; }
        else if (c == '\n') { *q++ = '\\'; *q++ = 'n'; }
        else if (c == '\r') { *q++ = '\\'; *q++ = 'r'; }
        else if (c == '\t') { *q++ = '\\'; *q++ = 't'; }
        else if (c == '\b') { *q++ = '\\'; *q++ = 'b'; }
        else if (c == '\f') { *q++ = '\\'; *q++ = 'f'; }
        else if (c < 32) { q += sprintf(q, "\\u%04x", c); }
        else *q++ = *p;
    }
    *q = 0;
    return o;
}
static int sendjson(int fd, const char *js, size_t n) {
    if (n == 0 || n > MAXFRAME) return -1;
    uint32_t be = htonl((uint32_t)n);
    return (wfull(fd, &be, 4) || wfull(fd, js, n)) ? -1 : 0;
}
static void merror(int fd, const char *e) {
    char *x = jesc(e), *js = NULL;
    if (!x) return;
    if (asprintf(&js, "{\"type\":\"error\",\"error\":\"%s\"}", x) > 0) sendjson(fd, js, strlen(js));
    free(js); free(x);
}
static int moutput(int fd, const uint8_t *d, size_t n) {
    char *b = b64enc(d, n), *js = NULL;
    int rc = -1;
    if (!b) return -1;
    if (asprintf(&js, "{\"type\":\"output\",\"data\":\"%s\"}", b) > 0) rc = sendjson(fd, js, strlen(js));
    free(js); free(b);
    return rc;
}
static void mexit(int fd, int code) {
    char js[64];
    int n = snprintf(js, sizeof js, "{\"type\":\"exit\",\"code\":%d}", code);
    if (n > 0) sendjson(fd, js, (size_t)n);
}

// ---------- JSON parseado (mínimo: lo que usa el protocolo) ----------
typedef struct { const char *p, *end; } J;
static void jws(J *j) { while (j->p < j->end && isspace((uint8_t)*j->p)) j->p++; }
// string JSON -> buffer malloc con len (puede traer NUL via \u0000); NULL si malformado
static int jhex4(J *j, unsigned *v) { // 4 hex del \u (0 si malformado)
    unsigned r = 0;
    if (j->end - j->p < 4) return 0;
    for (int k = 0; k < 4; k++) {
        char h = j->p[k];
        r <<= 4;
        if (h >= '0' && h <= '9') r |= (unsigned)(h - '0');
        else if (h >= 'a' && h <= 'f') r |= (unsigned)(h - 'a' + 10);
        else if (h >= 'A' && h <= 'F') r |= (unsigned)(h - 'A' + 10);
        else return 0;
    }
    j->p += 4;
    *v = r;
    return 1;
}
static int jput(char **o, size_t *n, size_t *cap, const char *t, int tn) {
    for (int k = 0; k < tn; k++) {
        if (*n + 1 >= *cap) {
            *cap *= 2;
            char *no = realloc(*o, *cap);
            if (!no) return 0;
            *o = no;
        }
        (*o)[(*n)++] = t[k];
    }
    return 1;
}
// string JSON -> buffer malloc con len (puede traer NUL via \u0000); NULL si malformado
static char *jstr(J *j, size_t *ln) {
    if (j->p >= j->end || *j->p != '"') return NULL;
    j->p++;
    size_t cap = 64, n = 0;
    char *o = malloc(cap);
    if (!o) return NULL;
    for (;;) {
        char c;
        if (j->p >= j->end) { free(o); return NULL; }
        c = *j->p++;
        if (c == '"') break;
        if (c == '\\') {
            if (j->p >= j->end) { free(o); return NULL; }
            char e = *j->p++;
            if (e == 'u') {
                unsigned v = 0;
                if (!jhex4(j, &v)) { free(o); return NULL; }
                char tmp[4]; int tn; // \u0000 deja NUL: lo detecta authorize
                if (v >= 0xD800 && v <= 0xDBFF) {
                    unsigned lo = 0; // alto: exige \uDC00-\uDFFF detrás
                    if (j->end - j->p < 6 || j->p[0] != '\\' || j->p[1] != 'u') { free(o); return NULL; }
                    j->p += 2;
                    if (!jhex4(j, &lo) || lo < 0xDC00 || lo > 0xDFFF) { free(o); return NULL; }
                    unsigned cp = 0x10000u + ((v & 0x3FFu) << 10) + (lo & 0x3FFu);
                    tmp[0] = (char)(0xF0 | (cp >> 18)); tmp[1] = (char)(0x80 | ((cp >> 12) & 63));
                    tmp[2] = (char)(0x80 | ((cp >> 6) & 63)); tmp[3] = (char)(0x80 | (cp & 63)); tn = 4;
                } else if (v >= 0xDC00 && v <= 0xDFFF) { free(o); return NULL; } // bajo huérfano
                else if (v < 0x80) { tmp[0] = (char)v; tn = 1; }
                else if (v < 0x800) { tmp[0] = (char)(0xC0 | (v >> 6)); tmp[1] = (char)(0x80 | (v & 63)); tn = 2; }
                else { tmp[0] = (char)(0xE0 | (v >> 12)); tmp[1] = (char)(0x80 | ((v >> 6) & 63)); tmp[2] = (char)(0x80 | (v & 63)); tn = 3; }
                if (!jput(&o, &n, &cap, tmp, tn)) { free(o); return NULL; }
                continue;
            }
            if (e == '"') c = '"'; else if (e == '\\') c = '\\'; else if (e == '/') c = '/';
            else if (e == 'b') c = '\b'; else if (e == 'f') c = '\f'; else if (e == 'n') c = '\n';
            else if (e == 'r') c = '\r'; else if (e == 't') c = '\t';
            else { free(o); return NULL; }
        }
        if (n + 1 >= cap) { cap *= 2; char *no = realloc(o, cap); if (!no) { free(o); return NULL; } o = no; }
        o[n++] = c;
    }
    o[n] = 0;
    if (ln) *ln = n;
    return o;
}
static long jnum(J *j, int *ok) {
    char *e; long v = strtol(j->p, &e, 10);
    if (e == j->p || e > j->end) { *ok = 0; return 0; }
    j->p = e; *ok = 1;
    return v;
}
static int jlit(J *j, const char *w) { // consume literal si matchea
    size_t n = strlen(w);
    if ((size_t)(j->end - j->p) < n || memcmp(j->p, w, n)) return 0;
    j->p += n;
    return 1;
}
#define JSON_MAX_DEPTH 64 // tope anti-DoS (frame acota input, esto acota stack)
static int jskip(J *j, int depth) { // salta cualquier valor (solo overflow de command)
    if (depth > JSON_MAX_DEPTH) return 0;
    jws(j);
    if (j->p >= j->end) return 0;
    if (*j->p == '"') { size_t l; char *s = jstr(j, &l); free(s); return s != NULL; }
    if (*j->p == '{' || *j->p == '[') {
        char open = *j->p++, close = open == '{' ? '}' : ']';
        jws(j);
        if (j->p < j->end && *j->p == close) { j->p++; return 1; }
        for (;;) {
            if (open == '{') {
                size_t l; char *k = jstr(j, &l);
                if (!k) return 0;
                free(k); jws(j);
                if (j->p >= j->end || *j->p != ':') return 0;
                j->p++;
            }
            if (!jskip(j, depth + 1)) return 0;
            jws(j);
            if (j->p >= j->end) return 0;
            if (*j->p == ',') { j->p++; continue; }
            if (*j->p == close) { j->p++; return 1; }
            return 0;
        }
    }
    if (jlit(j, "true") || jlit(j, "false") || jlit(j, "null")) return 1;
    if (*j->p == '-' || isdigit((uint8_t)*j->p)) { int ok; jnum(j, &ok); return ok; }
    return 0;
}

typedef struct { char type[16]; char **cmd; size_t *clen; int ncmd; int tty; long w, h; char *data; size_t datalen; char *token; } Req;
static void req_free(Req *r) {
    for (int i = 0; i < r->ncmd && r->cmd; i++) free(r->cmd[i]);
    free(r->cmd); free(r->clen); free(r->data); free(r->token);
    memset(r, 0, sizeof *r);
}
static int parse_req(const uint8_t *b, size_t n, Req *r) {
    memset(r, 0, sizeof *r);
    J j = { (const char *)b, (const char *)b + n };
    jws(&j);
    if (j.p >= j.end || *j.p != '{') return -1;
    j.p++; jws(&j);
    if (j.p < j.end && *j.p == '}') return -1;
    for (;;) {
        size_t kl; char *k = jstr(&j, &kl);
        if (!k) return -1;
        jws(&j);
        if (j.p >= j.end || *j.p != ':') { free(k); return -1; }
        j.p++; jws(&j);
        if (!strcmp(k, "type")) {
            size_t l; char *v = jstr(&j, &l);
            if (!v) { free(k); return -1; }
            size_t c = strlen(v);
            if (c > sizeof r->type - 1) c = sizeof r->type - 1;
            memcpy(r->type, v, c); r->type[c] = 0;
            free(v);
        } else if (!strcmp(k, "command")) {
            if (j.p >= j.end || *j.p != '[') { free(k); return -1; }
            j.p++; jws(&j);
            for (int i = 0; i < r->ncmd; i++) free(r->cmd[i]); // clave repetida: manda la última
            free(r->cmd); free(r->clen);
            int cap = 8;
            r->cmd = malloc((size_t)cap * sizeof *r->cmd);
            r->clen = malloc((size_t)cap * sizeof *r->clen);
            if (!r->cmd || !r->clen) { free(k); return -1; }
            r->ncmd = 0;
            if (j.p < j.end && *j.p == ']') j.p++;
            else for (;;) {
                if (r->ncmd <= MAXARGS) {
                    size_t l = 0; char *v = jstr(&j, &l);
                    if (!v) { free(k); return -1; }
                    if (r->ncmd == cap) {
                        cap *= 2;
                        char **nc = realloc(r->cmd, (size_t)cap * sizeof *nc);
                        if (!nc) { free(v); free(k); return -1; }
                        r->cmd = nc;
                        size_t *nl = realloc(r->clen, (size_t)cap * sizeof *nl);
                        if (!nl) { free(v); free(k); return -1; }
                        r->clen = nl;
                    }
                    r->cmd[r->ncmd] = v; r->clen[r->ncmd] = l; r->ncmd++;
                } else { if (!jskip(&j, 0)) { free(k); return -1; } r->ncmd++; }
                jws(&j);
                if (j.p >= j.end) { free(k); return -1; }
                if (*j.p == ',') { j.p++; jws(&j); continue; }
                if (*j.p == ']') { j.p++; break; }
                free(k); return -1;
            }
        } else if (!strcmp(k, "tty")) {
            if (jlit(&j, "true")) r->tty = 1;
            else if (jlit(&j, "false")) r->tty = 0;
            else { free(k); return -1; }
        } else if (!strcmp(k, "width")) { int ok; r->w = jnum(&j, &ok); if (!ok) { free(k); return -1; } }
        else if (!strcmp(k, "height")) { int ok; r->h = jnum(&j, &ok); if (!ok) { free(k); return -1; } }
        else if (!strcmp(k, "data")) {
            size_t l; char *v = jstr(&j, &l);
            if (!v) { free(k); return -1; }
            free(r->data); r->data = v; r->datalen = l;
        } else if (!strcmp(k, "token")) {
            size_t l; char *v = jstr(&j, &l);
            if (!v) { free(k); return -1; }
            free(r->token); r->token = v;
        } else { free(k); return -1; } // strict: clave desconocida fuera
        free(k); jws(&j);
        if (j.p >= j.end) return -1;
        if (*j.p == ',') { j.p++; jws(&j); continue; }
        if (*j.p == '}') { j.p++; break; }
        return -1;
    }
    jws(&j);
    if (j.p != j.end) return -1; // strict: basura tras '}' fuera
    return r->type[0] ? 0 : -1;
}

// ---------- allowlist ----------
static char *resolve_cmd(const char *name) { // canoniza: PATH + realpath + regular + X_OK
    char *cand = NULL;
    if (strchr(name, '/')) {
        if (name[0] != '/') return NULL; // relativo con '/': fuera (./x, a/b, ../x)
        cand = strdup(name);
    } else {
        const char *path = getenv("PATH");
        if (!path || !*path) path = "/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin";
        const char *d = path;
        for (;;) {
            const char *e = strchr(d, ':');
            size_t dl = e ? (size_t)(e - d) : strlen(d);
            // fail-closed: componente vacio, relativo o '.' envenena la
            // resolucion (depende del CWD del daemon); todo el lookup falla.
            if (dl == 0 || d[0] != '/') return NULL;
            char *t = malloc(dl + 1 + strlen(name) + 1);
            if (!t) return NULL;
            memcpy(t, d, dl); t[dl] = '/'; strcpy(t + dl + 1, name);
            if (!access(t, X_OK)) { cand = t; break; }
            free(t);
            if (!e) break;
            d = e + 1;
        }
    }
    if (!cand) return NULL;
    char *rp = realpath(cand, NULL);
    free(cand);
    if (!rp) return NULL;
    struct stat st;
    if (stat(rp, &st) || !S_ISREG(st.st_mode) || access(rp, X_OK)) { free(rp); return NULL; }
    return rp;
}
static char *authorize(char **cmd, size_t *clen, int n, const char **why) {
    if (n < 1) { *why = "empty command"; return NULL; }
    if (n > MAXARGS) { *why = "too many arguments"; return NULL; }
    for (int i = 0; i < n; i++) {
        if (clen[i] == 0 || memchr(cmd[i], 0, clen[i])) { *why = "bad argument"; return NULL; }
        if (clen[i] > MAXARGSZ) { *why = "argument too large"; return NULL; }
    }
    char *rp = resolve_cmd(cmd[0]);
    if (!rp) { *why = "command not allowed"; return NULL; }
    for (int i = 0; i < g_nallow; i++) if (!strcmp(rp, g_allow[i])) return rp;
    free(rp); *why = "command not allowed";
    return NULL;
}

// ---------- auth ----------
static int peer_ok(int fd) { // SO_PEERCRED: solo el dueño del daemon
    struct ucred u; socklen_t n = sizeof u;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &u, &n)) return 0;
    return u.uid == getuid();
}

// ---------- lector incremental (multiplexa socket <-> hijo con poll) ----------
// 1 frame completo, 0 falta más, -1 corte/error, -2 tamaño inválido (0 o >128KiB)
typedef struct { uint8_t h[4]; int nh; uint8_t *pl; uint32_t sz, np; } FR;
static void fr_init(FR *f) { memset(f, 0, sizeof *f); }
static int fr_feed(FR *f, int fd) {
    if (f->nh < 4) {
        ssize_t r = read(fd, f->h + f->nh, (size_t)(4 - f->nh));
        if (r == 0) return -1;
        if (r < 0) { if (errno == EINTR) return 0; return errno == EAGAIN ? 0 : -1; }
        f->nh += (int)r;
        if (f->nh < 4) return 0;
        uint32_t sz; memcpy(&sz, f->h, 4); sz = ntohl(sz);
        if (sz == 0 || sz > MAXFRAME) return -2;
        f->sz = sz; f->pl = malloc(sz);
        if (!f->pl) return -1;
    }
    ssize_t r = read(fd, f->pl + f->np, f->sz - f->np);
    if (r == 0) return -1;
    if (r < 0) { if (errno == EINTR) return 0; return errno == EAGAIN ? 0 : -1; }
    f->np += (uint32_t)r;
    return f->np == f->sz ? 1 : 0;
}

// ---------- sesión ----------
static int pappend(uint8_t **pp, size_t *pn, size_t *po, const uint8_t *d, size_t n) {
    if (*pn - *po + n > INQUEUEMAX) return -1;
    if (*po) { memmove(*pp, *pp + *po, *pn - *po); *pn -= *po; *po = 0; }
    uint8_t *nq = realloc(*pp, *pn + n);
    if (!nq) return -1;
    memcpy(nq + *pn, d, n); *pn += n; *pp = nq;
    return 0;
}
static int pflush(int fd, uint8_t **pp, size_t *pn, size_t *po) { // 0 ok, -1 stdin roto
    while (*pp && *po < *pn) {
        ssize_t w = write(fd, *pp + *po, *pn - *po);
        if (w > 0) *po += (size_t)w;
        else if (w < 0 && errno == EINTR) continue;
        else if (w < 0 && errno == EAGAIN) break;
        else return -1;
    }
    if (*pp && *po == *pn) { free(*pp); *pp = NULL; *pn = *po = 0; }
    return 0;
}
static void session(int cfd, Req *q, char **av) {
    int infd = -1, outfd = -1, c0 = -1, c1 = -1; // c0/c1: extremos del hijo
    int ispty = q->tty ? 1 : 0;
    if (ispty) { // modo PTY: openpty + winsize del request (defecto 80x24)
        struct winsize ws;
        ws.ws_col = q->w > 0 && q->w < WS_MAXDIM ? (unsigned short)q->w : WS_DEF_COLS;
        ws.ws_row = q->h > 0 && q->h < WS_MAXDIM ? (unsigned short)q->h : WS_DEF_ROWS;
        ws.ws_xpixel = ws.ws_ypixel = 0;
        if (openpty(&outfd, &c0, NULL, NULL, &ws)) { merror(cfd, "pty failed"); return; }
        infd = outfd;
    } else { // modo pipe: stdin por pipe, stdout+stderr fusionados a un pipe
        int pin[2] = { -1, -1 }, pout[2] = { -1, -1 };
        if (pipe(pin) || pipe(pout)) {
            close(pin[0]); close(pin[1]); close(pout[0]); close(pout[1]);
            merror(cfd, "pipe failed"); return;
        }
        c0 = pin[0]; c1 = pout[1]; infd = pin[1]; outfd = pout[0];
    }
    pid_t pid = fork();
    if (pid < 0) {
        merror(cfd, "fork failed");
        close(c0); close(c1); if (!ispty) { close(infd); close(outfd); } else close(outfd);
        return;
    }
    if (pid == 0) { // hijo: ejecuta el comando permitido
        if (ispty) {
            close(outfd); close(cfd);
            setsid();
            ioctl(c0, TIOCSCTTY, 0);
            dup2(c0, 0); dup2(c0, 1); dup2(c0, 2);
            if (c0 > 2) close(c0);
        } else {
            dup2(c0, 0); dup2(c1, 1); dup2(c1, 2);
            close(c0); close(c1); close(infd); close(outfd); close(cfd);
        }
        execv(av[0], av);
        _exit(EXIT_NOEXEC); // como el shell: binario que no se pudo ejecutar
    }
    close(c0); // extremo del hijo
    if (!ispty) close(c1);
    nonblock(cfd); nonblock(outfd);
    if (!ispty) nonblock(infd); // el master pty ya quedó nonblock (== outfd)

    FR fr; fr_init(&fr);
    uint8_t *pend = NULL; size_t pn = 0, po = 0; // stdin pendiente (tubería llena)
    int conn_ok = 1, proto_err = 0, status = 0, have_st = 0, outeof = 0;
    for (;;) {
        struct pollfd pf[3];
        pf[0].fd = cfd; pf[0].events = POLLIN; pf[0].revents = 0;
        pf[1].fd = outfd; pf[1].events = (short)(outeof ? 0 : POLLIN); pf[1].revents = 0;
        pf[2].fd = (pend && infd >= 0) ? infd : -1; pf[2].events = POLLOUT; pf[2].revents = 0;
        if (poll(pf, 3, -1) < 0) { if (errno == EINTR) continue; conn_ok = 0; break; }
        if (pend && (pf[2].revents & POLLOUT) && pflush(infd, &pend, &pn, &po)) {
            free(pend); pend = NULL; pn = po = 0; // stdin roto: descarta y sigue
            if (infd >= 0 && !ispty) { close(infd); infd = -1; }
        }
        if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            int r = fr_feed(&fr, cfd);
            if (r == -2) { merror(cfd, "frame too large"); proto_err = 1; break; }
            if (r == -1) { conn_ok = 0; break; }
            if (r == 1) {
                Req m; memset(&m, 0, sizeof m);
                if (!parse_req(fr.pl, fr.sz, &m)) {
                    if (!strcmp(m.type, "input") && m.data && infd >= 0) {
                        size_t dl = 0; uint8_t *dd = b64dec(m.data, m.datalen, &dl);
                        if (dd) {
                            if (pend) { // ya hay cola: encola detrás (con tope)
                                if (pappend(&pend, &pn, &po, dd, dl)) {
                                    merror(cfd, "input too large"); proto_err = 1;
                                    free(dd); req_free(&m); free(fr.pl); fr.pl = NULL; goto done;
                                }
                            } else { // intento directo; lo que no quepa se encola
                                size_t off = 0;
                                for (;;) {
                                    ssize_t w = write(infd, dd + off, dl - off);
                                    if (w > 0) { off += (size_t)w; if (off == dl) break; }
                                    else if (w < 0 && errno == EINTR) continue;
                                    else if (w < 0 && errno == EAGAIN) {
                                        if (off < dl && pappend(&pend, &pn, &po, dd + off, dl - off)) {
                                            merror(cfd, "input too large"); proto_err = 1;
                                            free(dd); req_free(&m); free(fr.pl); fr.pl = NULL; goto done;
                                        }
                                        break;
                                    } else break; // EPIPE etc: el hijo no lee; se descarta
                                }
                            }
                            free(dd);
                        }
                    } else if (!strcmp(m.type, "close-input")) {
                        if (!ispty && infd >= 0) { close(infd); infd = -1; } // EOF al hijo
                    } else if (!strcmp(m.type, "resize") && ispty) {
                        struct winsize ws2; // SIGWINCH del cliente
                        ws2.ws_col = m.w > 0 && m.w < WS_MAXDIM ? (unsigned short)m.w : WS_DEF_COLS;
                        ws2.ws_row = m.h > 0 && m.h < WS_MAXDIM ? (unsigned short)m.h : WS_DEF_ROWS;
                        ws2.ws_xpixel = ws2.ws_ypixel = 0;
                        ioctl(outfd, TIOCSWINSZ, &ws2);
                    }
                }
                req_free(&m); free(fr.pl); fr_init(&fr);
            }
        }
        if (!outeof && (pf[1].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) {
            uint8_t buf[CHUNK];
            ssize_t r = read(outfd, buf, sizeof buf);
            if (r > 0) { if (moutput(cfd, buf, (size_t)r)) { conn_ok = 0; break; } }
            else if (r == 0) outeof = 1;
            else if (errno != EINTR && errno != EAGAIN) outeof = 1; // EIO: el pty murió
        }
        if (waitpid(pid, &status, WNOHANG) == pid) { have_st = 1; break; }
        if (outeof) break; // salida cerrada (el hijo ya no puede contar nada más)
    }
done:
    free(fr.pl);
    free(pend);
    if (!have_st) { kill(pid, SIGKILL); while (waitpid(pid, &status, 0) < 0 && errno == EINTR); }
    if (conn_ok && !proto_err) { // drena lo que quede y reporta exit{code}
        for (;;) {
            uint8_t buf[CHUNK];
            ssize_t r = read(outfd, buf, sizeof buf);
            if (r > 0) { if (moutput(cfd, buf, (size_t)r)) break; }
            else break;
        }
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? EXIT_SIGNAL_BASE + WTERMSIG(status) : EXIT_NOSIG;
        mexit(cfd, code);
    }
    if (!ispty && infd >= 0) close(infd);
    close(outfd);
}

// ---------- conexión ----------
static void handle(int cfd) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_DFL); // el padre lo ignora (auto-reap); aquí hace falta waitpid
    if (!peer_ok(cfd)) { close(cfd); return; } // como hrun: corte silencioso
    FR fr; fr_init(&fr);
    for (;;) { // espera el request (10s como hrun requestTimeout)
        struct pollfd p; p.fd = cfd; p.events = POLLIN; p.revents = 0;
        if (poll(&p, 1, REQ_TIMEOUT_MS) <= 0) { close(cfd); return; }
        int f = fr_feed(&fr, cfd);
        if (f == 1) break;
        if (f != 0) {
            if (f == -2) merror(cfd, "frame too large");
            free(fr.pl);
            close(cfd); return;
        }
    }
    Req q; memset(&q, 0, sizeof q);
    int ok = parse_req(fr.pl, fr.sz, &q);
    free(fr.pl);
    const char *why = "bad request";
    char *abs = NULL;
    // Token solo en request (lo que ejecuta): input/resize van en una
    // conexion ya aceptada por UID (sin refino por instancia: ver OUT-OF-SCOPE §12).
    if (!ok && !strcmp(q.type, "request")) {
        if (g_token && (!q.token || strcmp(q.token, g_token))) why = "bad token";
        else abs = authorize(q.cmd, q.clen, q.ncmd, &why);
    }
    if (!abs) { merror(cfd, why); req_free(&q); close(cfd); return; }
    char **av = malloc(((size_t)q.ncmd + 1) * sizeof *av);
    if (!av) { merror(cfd, "out of memory"); free(abs); req_free(&q); close(cfd); return; }
    av[0] = abs;
    for (int i = 1; i < q.ncmd; i++) av[i] = q.cmd[i];
    av[q.ncmd] = NULL;
    session(cfd, &q, av);
    free(av); free(abs); req_free(&q); close(cfd);
}

// ---------- listener seguro (dir DIR_MODE, socket SOCK_MODE, limpia stale) ----------
static void mkpath(char *d) {
    for (char *p = d + 1; *p; p++) if (*p == '/') { *p = 0; mkdir(d, DIR_MODE); *p = '/'; }
    mkdir(d, DIR_MODE);
}
static int secure_listen(const char *path) {
    const char *sl = strrchr(path, '/');
    char dir[PATH_MAX];
    if (sl) {
        size_t n = (size_t)(sl - path);
        if (n == 0) n = 1;
        if (n >= sizeof dir) die("socket path too long");
        memcpy(dir, path, n); dir[n] = 0;
    } else { strcpy(dir, "."); }
    mode_t old = umask(UMASK_PRIV); // que lo creado salga 0700/0600 aunque el umask sea otro
    mkpath(dir);
    umask(old);
    struct stat st;
    if (stat(dir, &st) || st.st_uid != getuid()) die("socket dir not owned by you");
    unlink(path); // stale de un apagado sucio
    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    // con path+strerror (antes indistinguible stale vs permisos).
    if (ls < 0) { snprintf(diebuf, sizeof diebuf, "socket failed for '%s': %s", path, strerror(errno)); die(diebuf); }
    struct sockaddr_un a; memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    size_t pl = strlen(path);
    if (pl >= sizeof a.sun_path) die("socket path too long");
    memcpy(a.sun_path, path, pl + 1);
    if (bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, LISTEN_BACKLOG)) { close(ls); snprintf(diebuf, sizeof diebuf, "bind/listen failed for '%s': %s", path, strerror(errno)); die(diebuf); }
    chmod(path, SOCK_MODE);
    return ls;
}

static void onterm(int s) { (void)s; if (g_sockpath) unlink(g_sockpath); _exit(0); }

// Higiene de fds: el daemon nace de `host-bridge --daemon` (hijo del CLI) y
// hereda sus fds (visto: data_lock retenido horas por un daemon huerfano; el
// lado bash ya los cierra, esto es defensa en profundidad). Cerrar todo >=3
// al arrancar: el listener aun no existe; 0/1/2 se conservan (el --daemon ya
// redirigio 1/2 al blog).
static void close_stray_fds(void) {
    long mx = sysconf(_SC_OPEN_MAX);
    if (mx < 0 || mx > 65536) mx = 65536;
    for (int fd = 3; fd < mx; fd++) close(fd);
}

int main(int argc, char **argv) {
    close_stray_fds();
    const char *sock = NULL;
    for (int i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "--socket")) && i + 1 < argc) sock = argv[++i];
        else if ((!strcmp(argv[i], "--token")) && i + 1 < argc) { i++; g_token = argv[i]; }
        else if ((!strcmp(argv[i], "--allowed-cmd")) && i + 1 < argc) {
            i++;
            char *rp = resolve_cmd(argv[i]);
            if (!rp) { fprintf(stderr, "arxy-bridged: not executable: %s\n", argv[i]); return 1; }
            char **na = realloc(g_allow, ((size_t)g_nallow + 1) * sizeof *na);
            if (!na) die("out of memory");
            g_allow = na; g_allow[g_nallow++] = rp;
        } else { usage(); return 1; } // --help incluido: el spike no lo necesita
    }
    if (!sock || !g_nallow) { usage(); return 1; }
    signal(SIGCHLD, SIG_IGN); // el padre no espera: cada conexión se atiende en un fork
    int ls = secure_listen(sock);
    g_sockpath = sock;
    signal(SIGTERM, onterm); signal(SIGINT, onterm); signal(SIGQUIT, onterm);
    signal(SIGPIPE, SIG_IGN);
    for (;;) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; continue; }
        pid_t p = fork();
        if (p == 0) { close(ls); handle(c); _exit(0); } // handle cierra c
        if (p < 0) { merror(c, "fork failed"); }
        close(c);
    }
}
