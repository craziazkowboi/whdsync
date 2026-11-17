/* Runs a314_retroplay_gui.c's own code on the build machine, with fake
   AmigaDOS and MUI underneath (files map to the current folder; MUI objects
   are attribute tables). Used by tests/run_tests.sh, which compiles it
   against tests/gui_host/amiga_stub.h:
       harness <scenario>     exit 0 = every check in it passed
   PROGDIR: is the current folder, so run it inside a scratch folder that
   holds the retroplay.conf to work on. */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#define timeval amiga_timeval
#include <sys/stat.h>
#define main gui_main
#include "a314_retroplay_gui.c"
#undef main

static const char *progdir = ".";
static void mapname(const char *in, char *out) {
    if (!strncmp(in, "PROGDIR:", 8)) sprintf(out, "%s/%s", progdir, in + 8);
    else if (!strncmp(in, "T:", 2)) sprintf(out, "./T_%s", in + 2);
    else strcpy(out, in);
}
/* ---- fake objects: one attribute table each ---- */
typedef struct { ULONG a[256]; } Fake;
static Object *fake(void) { return (Object *)calloc(1, sizeof(Fake)); }
#define SLOT(t) (((t) - 0x1000) & 0xFF)
ULONG GetAttr(ULONG attr, Object *o, ULONG *v) { *v = ((Fake *)o)->a[SLOT(attr)]; return 1; }
ULONG SetAttrs(APTR o, ULONG tag, ...) { va_list ap; ULONG t = tag; va_start(ap, tag);
  while (t != TAG_DONE) { ULONG val = va_arg(ap, ULONG); ((Fake *)o)->a[SLOT(t)] = val; t = va_arg(ap, ULONG); }
  va_end(ap); return 0; }
static char logLines[2000][600]; static int nLog = 0;
ULONG DoMethod(Object *o, ULONG m, ...) { va_list ap; va_start(ap, m);
  if (m == MUIM_List_InsertSingle) { const char *s = (const char *)va_arg(ap, ULONG); strncpy(logLines[nLog++ % 2000], s, 599); }
  va_end(ap); return 0; }
static LONG nextAnswer = 1; static char lastRequest[600];
LONG MUI_RequestA(APTR a, APTR w, LONGBITS f, char *t, char *g, char *fmt, APTR p) {
  strncpy(lastRequest, (char *)((ULONG *)p)[0], 599); return nextAnswer; }
/* ---- fake DOS on stdio ---- */
BPTR Open(STRPTR n, LONG mode) { char p[512]; FILE *f; mapname((char *)n, p);
  if (!strcmp((char*)n, "NIL:")) p[0]=0, strcpy(p, "/dev/null");
  f = fopen(p, mode == MODE_OLDFILE ? "r" : mode == MODE_NEWFILE ? "w" : "a+"); return (BPTR)f; }
LONG Close(BPTR f) { return fclose((FILE *)f) == 0; }
STRPTR FGets(BPTR f, STRPTR b, ULONG n) { return (STRPTR)fgets((char *)b, (int)n + 1, (FILE *)f); }
LONG FPuts(BPTR f, STRPTR s) { return fputs((char *)s, (FILE *)f) < 0 ? -1 : 0; }
LONG Read(BPTR f, APTR b, LONG n) { return (LONG)fread(b, 1, n, (FILE *)f); }
LONG Write(BPTR f, APTR b, LONG n) { return (LONG)fwrite(b, 1, n, (FILE *)f); }
LONG DeleteFile(STRPTR n) { char p[512]; mapname((char *)n, p); return remove(p) == 0; }
LONG Rename(STRPTR a, STRPTR b) { char p[512], q[512]; struct stat st; mapname((char *)a, p); mapname((char *)b, q);
  if (stat(q, &st) == 0) return 0;            /* AmigaDOS: never overwrites */
  return rename(p, q) == 0; }
BPTR Lock(STRPTR n, LONG m) { return 0; } void UnLock(BPTR l) {}
LONG Examine(BPTR l, struct FileInfoBlock *f) { return 0; } LONG ExNext(BPTR l, struct FileInfoBlock *f) { return 0; }
BPTR CreateDir(STRPTR n) { return 0; } LONG SetProtection(STRPTR n, LONG p) { return 1; }
LONG SetFileDate(STRPTR n, struct DateStamp *d) { return 1; } LONG SetComment(STRPTR n, STRPTR c) { return 1; }
APTR AllocDosObject(ULONG t, struct TagItem *x) { return calloc(1, sizeof(struct FileInfoBlock)); }
void FreeDosObject(ULONG t, APTR p) { free(p); }
LONG SystemTagList(STRPTR c, struct TagItem *t) { return -1; }
struct DateStamp *DateStamp(struct DateStamp *d) { memset(d, 0, sizeof *d); return d; }
APTR AllocVec(ULONG n, ULONG f) { return calloc(1, n); } void FreeVec(APTR p) { free(p); }
struct Library *OpenLibrary(STRPTR n, ULONG v) { return NULL; } void CloseLibrary(struct Library *l) {}
struct MsgPort *CreateMsgPort(void) { return NULL; } void DeleteMsgPort(struct MsgPort *p) {}
APTR CreateIORequest(struct MsgPort *p, ULONG s) { return NULL; } void DeleteIORequest(APTR r) {}
BYTE OpenDevice(STRPTR n, ULONG u, struct IORequest *r, ULONG f) { return 1; } void CloseDevice(struct IORequest *r) {}
void SendIO(struct IORequest *r) {} struct IORequest *CheckIO(struct IORequest *r) { return NULL; }
BYTE WaitIO(struct IORequest *r) { return 0; } void AbortIO(struct IORequest *r) {} ULONG Wait(ULONG s) { return 0; }
LONG EasyRequestArgs(void *w, struct EasyStruct *e, ULONG *i, APTR a) { return 0; }
Object *MUI_NewObject(char *c, Tag t, ...) { return fake(); } Object *MUI_MakeObject(LONG k, ...) { return fake(); }
void MUI_DisposeObject(Object *o) {}

/* ---- helpers for the scenarios ---- */
static struct Setting *S(const char *k) { struct Setting *s; for (s = settings; s->key; s++) if (!strcmp(s->key, k)) return s; abort(); }
static void Baseline(void) { /* what BuildSettingsPage does, with fake widgets */
  struct Setting *s; int i;
  for (s = settings; s->key; s++) {
    if (s->kind == K_CHOICE) { for (i = 0; s->values[i]; i++) ; s->nvalues = i; }
    SettingBaseline(s);
    if (s->page == PG_NONE) continue;
    s->obj = fake();
    if (s->kind == K_BOOL) xset(s->obj, MUIA_Selected, s->init);
    if (s->kind == K_CHOICE) xset(s->obj, MUIA_Cycle_Active, s->init);
    if (s->kind == K_NUM) xset(s->obj, MUIA_Numeric_Value, s->init);
    if (s->kind == K_TEXT) { char *c = strdup(s->raw); xset(s->obj, MUIA_String_Contents, (ULONG)c); }
    if (s->kind == K_LIST) for (i = 0; s->values[i]; i++) { s->box[i] = fake(); xset(s->box[i], MUIA_Selected, (s->init >> i) & 1); }
  } }
static int fails = 0;
static void check(const char *what, int ok) { printf("  %s %s\n", ok ? "PASS" : "FAIL", what); if (!ok) fails++; }

int main(int argc, char **argv) {
  const char *scenario = argv[1];
  lsLog = fake(); txConf = fake(); txStatus = fake();
  LoadConf(); Baseline();
  if (!strcmp(scenario, "nochange")) {
    check("no change: SaveConf succeeds", SaveConf());
    check("...and says nothing changed", strstr(logLines[nLog-1], "nothing has changed") != NULL);
  } else if (!strcmp(scenario, "edits")) {
    struct Setting *v = S("VARIANTS");
    xset(S("DOWNLOAD_TIMEOUT")->obj, MUIA_Numeric_Value, 120);
    xset(v->box[4], MUIA_Selected, 0);                         /* drop ecs-laced */
    xset(S("ART_ORDER")->obj, MUIA_Cycle_Active, 2);           /* Covers,Screens,Titles */
    xset(S("NTFY_TOPIC")->obj, MUIA_String_Contents, (ULONG)"my-topic_1");
    xset(S("JOBS")->obj, MUIA_Numeric_Value, 4);
    xset(S("ARTWORK_TIMEOUT")->obj, MUIA_Numeric_Value, 0);    /* no limit */
    xset(S("AMIGA_NAMES")->obj, MUIA_Selected, 0);
    xset(S("MIRROR_DIRS")->box[5], MUIA_Selected, 1);          /* add betas */
    check("edits: SaveConf succeeds", SaveConf());
    check("...nothing left to save afterwards", !AnySettingChanged());
  } else if (!strcmp(scenario, "clear")) {
    xset(S("OUTPUT_ROOT")->obj, MUIA_String_Contents, (ULONG)"/mnt/ssd");
    xset(S("NTFY_TOPIC")->obj, MUIA_String_Contents, (ULONG)"");
    check("a text setting can be changed and saved", SaveConf());
    xset(S("OUTPUT_ROOT")->obj, MUIA_String_Contents, (ULONG)"");
    check("clearing a text setting is saved, not ignored", SaveConf());
    check("...as the default, which the field then shows", !strcmp(S("OUTPUT_ROOT")->raw, ".") && !strcmp(xstr(S("OUTPUT_ROOT")->obj), "."));
    check("...and nothing then looks unsaved", !AnySettingChanged());
  } else if (!strcmp(scenario, "unsafe")) {
    xset(S("NTFY_TOPIC")->obj, MUIA_String_Contents, (ULONG)"a\"b;rm");
    check("unsafe text is refused", !SaveConf());
    check("...with a message naming the setting", strstr(lastRequest, "ntfy topic") != NULL);
  } else if (!strcmp(scenario, "emptylist")) {
    int i; for (i = 0; i < 5; i++) xset(S("VARIANTS")->box[i], MUIA_Selected, 0);
    check("no collection ticked is refused", !SaveConf());
  } else if (!strcmp(scenario, "keep")) {
    check("a value the window doesn't offer shows as 'keep'", S("ART_ORDER")->init == S("ART_ORDER")->nvalues);
    xset(S("SPACE_FACTOR")->obj, MUIA_Numeric_Value, 4);
    check("saving another setting succeeds", SaveConf());
  } else if (!strcmp(scenario, "tokens")) {
    xset(S("VARIANTS")->box[2], MUIA_Selected, 1);             /* add rtg */
    check("unknown collection kept", SaveConf());
  } else if (!strcmp(scenario, "lines")) {
    /* the line reader: colour codes, a redrawn progress bar, UTF-8 */
    const char *in = "\033[1;32mGreen\033[0m text\n"
                     "Extracting: [#    ] 10%\rExtracting: [#####] 100%\n"
                     "  \xE2\x9C\x93 caf\xC3\xA9 \xE2\x80\x94 Zo\xC3\xAB \xE2\x86\x92 ok\n"
                     "tab\there\r\n" RC_SENTINEL "5\n";
    const char *p; for (p = in; *p; p++) FeedByte((unsigned char)*p);
    check("colour codes removed", !strcmp(logLines[0], "Green text"));
    check("a redrawn progress bar keeps its final state", !strcmp(logLines[1], "Extracting: [#####] 100%"));
    check("UTF-8 becomes Latin-1, symbols become plain characters", !strcmp(logLines[2], "  + caf\xE9 - Zo\xEB > ok"));
    check("tabs expand, CR LF ends a line", !strcmp(logLines[3], "tab     here"));
    check("the exit code line is read, not shown", runFinished && runRc == 5 && nLog == 4);
  } else if (!strcmp(scenario, "cmd")) {
    char cmd[CMD_SIZE], why[LINE_SIZE];
    rdTask = fake(); cyVariant = fake(); strSet = fake(); cyFs = fake(); cyDetox = fake(); cyArt = fake(); cyDemoArt = fake();
    slJobs = fake(); strDest = fake(); rdSimple = fake(); strPiCmd = fake(); strPiScripts = fake();
    { int i; for (i = 0; i < O_COUNT; i++) chkOpt[i] = fake(); }
    xset(strPiCmd, MUIA_String_Contents, (ULONG)"pi"); xset(strPiScripts, MUIA_String_Contents, (ULONG)"/home/pi/whdsync");
    xset(strSet, MUIA_String_Contents, (ULONG)""); xset(strDest, MUIA_String_Contents, (ULONG)"");
    xset(rdSimple, MUIA_Radio_Active, 2);
    check("simple AGA", BuildSimple(cmd, sizeof cmd, why, sizeof why) && !strcmp(cmd, "pi /home/pi/whdsync/aga.sh --color=never"));
    xset(rdSimple, MUIA_Radio_Active, 0);
    check("simple All", BuildSimple(cmd, sizeof cmd, why, sizeof why) && !strcmp(cmd, "pi /home/pi/whdsync/all.sh --color=never"));
    xset(rdTask, MUIA_Radio_Active, T_SYNC); xset(cyVariant, MUIA_Cycle_Active, 4);
    xset(chkOpt[O_SKIPUPDATE], MUIA_Selected, 1); xset(chkOpt[O_REFRESH], MUIA_Selected, 1); xset(chkOpt[O_ONLYMISSING], MUIA_Selected, 1);
    xset(chkOpt[O_SKIPCHK], MUIA_Selected, 1);  /* sort-only: must be left out of a sync */
    xset(cyArt, MUIA_Cycle_Active, 3); xset(slJobs, MUIA_Numeric_Value, 2); xset(cyFs, MUIA_Cycle_Active, 2);
    check("advanced sync", BuildAdvanced(cmd, sizeof cmd, why, sizeof why) && (printf("    %s\n", cmd), 1) &&
      !strcmp(cmd, "pi /home/pi/whdsync/start.sh --color=never --sync --aga-laced --skip-update --refresh-artwork --ffs --art Covers,Screens,Titles --jobs 2"));
    xset(rdTask, MUIA_Radio_Active, T_SORT);
    check("advanced sort only takes the sort options", BuildAdvanced(cmd, sizeof cmd, why, sizeof why) && (printf("    %s\n", cmd), 1) &&
      !strcmp(cmd, "pi /home/pi/whdsync/start.sh --color=never --sort --skipchk --ffs --jobs 2"));
    xset(rdTask, MUIA_Radio_Active, T_MERGE); xset(chkOpt[O_REFRESH], MUIA_Selected, 0);
    check("merge with only-missing", BuildAdvanced(cmd, sizeof cmd, why, sizeof why) && strstr(cmd, " --merge --aga-laced --only-missing") != NULL);
    xset(cyVariant, MUIA_Cycle_Active, 6); xset(strSet, MUIA_String_Contents, (ULONG)"$(reboot)");
    check("an unsafe set name is refused", !BuildAdvanced(cmd, sizeof cmd, why, sizeof why));
    xset(strSet, MUIA_String_Contents, (ULONG)"art");
    check("a set name is passed", BuildAdvanced(cmd, sizeof cmd, why, sizeof why) && strstr(cmd, " --set art") != NULL);
    xset(strPiScripts, MUIA_String_Contents, (ULONG)"/home/pi/my whdsync");
    check("a folder with a space is quoted", BuildSimple(cmd, sizeof cmd, why, sizeof why) && !strcmp(cmd, "pi \"/home/pi/my whdsync/all.sh\" --color=never"));
    xset(strPiScripts, MUIA_String_Contents, (ULONG)"/x;reboot");
    check("an unsafe scripts folder is refused", !BuildSimple(cmd, sizeof cmd, why, sizeof why));
    check("status", BuildInfo(cmd, sizeof cmd, CMD_STATUS, why, sizeof why) == 0);
  }
  return fails ? 1 : 0;
}
