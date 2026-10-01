/*
 * a314_retroplay_gui.c
 *
 * AmigaOS 3.x (Kickstart/Workbench 2.04+) GadTools front end for the
 * Amiga Retroplay toolkit's start.sh, run on the Raspberry Pi side of an
 * A314 bridge.
 *
 * WHAT THIS DOES:
 *   - Opens a window with checkboxes/fields for every start.sh option
 *   - Builds the equivalent command line when you press Execute
 *   - Runs it via the PI_EXEC_PREFIX command below, capturing its output
 *     line-by-line into a scrolling log in the window
 *   - Optionally ("Merge with Amiga on completion"), once that finishes:
 *       1. Asks for an Amiga-side archive destination folder (ASL requester)
 *       2. Copies the Pi's retro/ tree into that folder
 *       3. Asks for your WHDLoad directory (ASL requester)
 *       4. Copies every new-or-changed file from the archive folder into
 *          the WHDLoad directory (skips anything with an illegal filename
 *          character, logging what was skipped and why)
 *       5. Remembers both folders as the defaults for next time
 *
 * *** THE TWO THINGS YOU MUST FIX BEFORE THIS WILL DO ANYTHING USEFUL ***
 *
 *   1. PI_EXEC_PREFIX - whatever you currently type on the Amiga to run a
 *      shell command on the Pi over A314 (a "pi" command in C:, a
 *      com0:-style serial bridge, etc). Final command line run is:
 *          <PI_EXEC_PREFIX> start.sh <flags built from the gadgets>
 *      If your real invocation needs different argument order/quoting,
 *      edit BuildAndRunCommand() - that's the only place it matters.
 *
 *   2. PI_BUILD_SOURCE - the Amiga-visible path to the Pi's "build"
 *      folder, the one that holds retro_aga, retro_ecs, retro_rtg,
 *      retro_aga_laced and retro_ecs_laced (e.g. wherever A314's shared
 *      filesystem mounts it, such as "PI0:whdsync/build"). The collection
 *      copied in step 2 is the one for the variant ticked in the window:
 *      <PI_BUILD_SOURCE>/retro_<variant>. This used to be PI_RETRO_SOURCE,
 *      pointing at a single "retro" folder that the scripts stopped
 *      producing when they moved to one collection per variant.
 *
 *   Both are plain #defines a few lines below the #includes. The window
 *   prints both values in its log when it opens, so a wrong one is visible
 *   before anything runs.
 *
 * BUILDING:
 *   With vbcc (m68k-amigaos target):
 *     vc +aos68k -c99 -O2 -lauto a314_retroplay_gui.c -o A314RetroplayGUI
 *   With SAS/C:
 *     sc a314_retroplay_gui.c link
 *
 *   Needs gadtools.library and asl.library (both built into OS 2.04+/3.x,
 *   no extra install).
 *
 * NOT YET WIRED UP / KNOWN GAPS:
 *   - PI_EXEC_PREFIX and PI_BUILD_SOURCE (see above) - the two load-bearing
 *     unknowns about your specific A314 setup.
 *   - The pipe-based output capture and the recursive copy/compare logic
 *     use standard, well-documented AmigaDOS techniques (PIPE: device,
 *     Examine()/ExNext(), DateStamp fields, the "Copy CLONE" shell command)
 *     but none of this has been compile-tested in this environment - treat
 *     it as a strong starting point, not a guarantee.
 *   - "Illegal filename character" is checked as ':', '/', and control
 *     characters (the ones AmigaDOS filesystems genuinely can't store in a
 *     filename), plus '"' and '*', which AmigaDOS cannot pass safely inside
 *     a quoted argument to Copy. It does not re-check the length limits
 *     sort.sh already enforces on the Pi side.
 *
 * STRING SAFETY:
 *   Every command line and path is built with AppendStr()/CopyStr(), which
 *   never write past the end of a buffer and report when something did not
 *   fit. A command or path that does not fit is refused and logged - never
 *   run or copied truncated, because a truncated path names a different
 *   file.
 *   - Window layout uses fixed coordinates sized for an 800x600-ish
 *     screen; adjust WIN_WIDTH/WIN_HEIGHT and the per-gadget ng_TopEdge
 *     values if you're on a smaller display (e.g. NTSC 640x400).
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <intuition/intuition.h>
#include <intuition/screens.h>
#include <libraries/gadtools.h>
#include <libraries/asl.h>
#include <workbench/startup.h>
#include <dos/dos.h>
#include <dos/dostags.h>

#include <clib/exec_protos.h>
#include <clib/intuition_protos.h>
#include <clib/gadtools_protos.h>
#include <clib/dos_protos.h>
#include <clib/graphics_protos.h>
#include <clib/alib_protos.h>
#include <clib/asl_protos.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ################################################################## */
/* ##                                                              ## */
/* ##   EDIT THESE TWO LINES FOR YOUR A314 SET-UP BEFORE BUILDING    ## */
/* ##                                                              ## */
/* ##   PI_EXEC_PREFIX   what you type on the Amiga to run a command ## */
/* ##                    on the Pi, followed by a space ("pi ")      ## */
/* ##   PI_BUILD_SOURCE  the Pi's whdsync build/ folder as the Amiga ## */
/* ##                    sees it (holds retro_aga, retro_ecs, ...)   ## */
/* ##                                                              ## */
/* ##   The window prints both when it opens, so a wrong one shows   ## */
/* ##   up before anything is run.                                   ## */
/* ##                                                              ## */
/* ################################################################## */
#define PI_EXEC_PREFIX   "pi "
#define PI_BUILD_SOURCE  "PI0:whdsync/build"
/* ################################################################## */

#define WIN_WIDTH  620
#define WIN_HEIGHT 440
#define LOG_LINES  200

#define CONFIG_FILE   "PROGDIR:A314RetroplayGUI.prefs"
#define COPY_LOG_FILE "PROGDIR:A314RetroplayGUI_copylog.txt"

#define PATH_BUF_SIZE 256

struct Library *IntuitionBase = NULL;
struct Library *GadToolsBase  = NULL;
struct Library *GfxBase       = NULL;
struct Library *AslBase       = NULL;

struct Screen  *scr = NULL;
struct Window  *win = NULL;
struct Gadget  *glist = NULL;
struct Gadget  *gad[64];
void           *vi = NULL;

/* Gadget IDs */
enum {
    GID_ACT_AUTO, GID_ACT_UPDATE, GID_ACT_EXTRACT, GID_ACT_MERGE,
    GID_ACT_SORT, GID_ACT_QUICK, GID_ACT_STATUS, GID_ACT_DOCTOR,

    GID_SET_ECS, GID_SET_AGA, GID_SET_RTG, GID_SET_ECSLACED, GID_SET_AGALACED,

    GID_FS_FFS, GID_FS_PFS,

    GID_NO_DETOX, GID_DEBUG, GID_MERGE_AMIGA,

    GID_REBUILD, GID_SKIP_UPDATE, GID_REFRESH_ART, GID_VERBOSE,

    GID_DEST_STR, GID_ART_STR, GID_DEMOART_STR, GID_SET_STR,

    GID_EXECUTE, GID_QUIT,

    GID_LOG_LIST,

    GID_COUNT
};

/* One-of-a-group checkbox IDs, used to enforce mutual exclusivity */
static const int actionGroup[] = { GID_ACT_AUTO, GID_ACT_UPDATE, GID_ACT_EXTRACT,
                                    GID_ACT_MERGE, GID_ACT_SORT, GID_ACT_QUICK,
                                    GID_ACT_STATUS, GID_ACT_DOCTOR, -1 };
static const int setGroup[]    = { GID_SET_ECS, GID_SET_AGA, GID_SET_RTG,
                                    GID_SET_ECSLACED, GID_SET_AGALACED, -1 };
static const int fsGroup[]     = { GID_FS_FFS, GID_FS_PFS, -1 };

char destBuf[128]    = "";
char artBuf[128]     = "";
char demoArtBuf[128] = "";
char setBuf[64]      = "";

/* Persisted across runs via CONFIG_FILE */
char archiveDestBuf[PATH_BUF_SIZE] = "";
char whdloadDestBuf[PATH_BUF_SIZE] = "";

/* Defined further down; AppendLog needs CopyStr before its definition. */
BOOL CopyStr(char *dst, const char *src, int dstSize);

struct List logList;
int logCount = 0;

BPTR gCopyLogFH = 0;

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

void AppendLog(char *text)
{
    struct Node *n;
    char *copy;

    copy = (char *)AllocVec(strlen(text) + 1, MEMF_CLEAR);
    if (!copy) return;
    CopyStr(copy, text, strlen(text) + 1);

    n = (struct Node *)AllocVec(sizeof(struct Node), MEMF_CLEAR);
    if (!n) { FreeVec(copy); return; }
    n->ln_Name = copy;

    if (logCount >= LOG_LINES) {
        struct Node *old = (struct Node *)RemHead(&logList);
        if (old) {
            FreeVec(old->ln_Name);
            FreeVec(old);
            logCount--;
        }
    }
    AddTail(&logList, n);
    logCount++;

    if (win) {
        GT_SetGadgetAttrs(gad[GID_LOG_LIST], win, NULL,
            GTLV_Labels, (ULONG)&logList,
            GTLV_Top, (logCount > 10) ? logCount - 10 : 0,
            TAG_END);
    }
}

BOOL IsChecked(int id)
{
    return (gad[id]->Flags & GFLG_SELECTED) ? TRUE : FALSE;
}

void SetChecked(int id, BOOL on)
{
    GT_SetGadgetAttrs(gad[id], win, NULL,
        GTCB_Checked, on ? TRUE : FALSE,
        TAG_END);
}

/* Enforces "only one checked" within a group when `changedId` was just
   toggled on. Pass a -1 terminated array of gadget IDs. */
void EnforceGroup(const int *group, int changedId)
{
    int i;
    if (!IsChecked(changedId)) return;
    for (i = 0; group[i] != -1; i++) {
        if (group[i] != changedId) SetChecked(group[i], FALSE);
    }
}

void StripNewline(char *s)
{
    int len = strlen(s);
    while (len > 0 && (s[len-1] == '\n' || s[len-1] == '\r')) s[--len] = 0;
}

/* CopyStr: strlcpy-style copy that always terminates. Returns TRUE when
   the whole of src fitted. (Amiga compilers do not all ship strlcpy.) */
BOOL CopyStr(char *dst, const char *src, int dstSize)
{
    int n;
    if (dstSize <= 0) return FALSE;
    for (n = 0; src[n] && n < dstSize - 1; n++) dst[n] = src[n];
    dst[n] = 0;
    return src[n] == 0;
}

/* AppendStr: strlcat-style append that always terminates. Returns TRUE when
   the whole of src fitted; on FALSE the buffer holds a truncated result
   that callers must not use. */
BOOL AppendStr(char *dst, const char *src, int dstSize)
{
    int len = strlen(dst);
    if (len >= dstSize) return FALSE;
    return CopyStr(dst + len, src, dstSize - len);
}

/* Joins a directory and a name, only inserting "/" when the directory
   isn't a bare volume/assign root (which already ends in ":").
   Returns FALSE when the result would not fit - the caller must then skip
   that entry: a truncated path names a different file. */
BOOL JoinPath(char *dir, char *name, char *out, int outSize)
{
    int len = strlen(dir), n;
    if (len > 0 && dir[len - 1] == ':') {
        n = snprintf(out, outSize, "%s%s", dir, name);
    } else {
        n = snprintf(out, outSize, "%s/%s", dir, name);
    }
    return n >= 0 && n < outSize;
}

/* Characters a text field may not contain. The value travels through an
   AmigaDOS command line and then a shell on the Pi; a quote, '*' (the
   AmigaDOS escape character) or any shell metacharacter would change what
   is run there. None of them belongs in a path, an art order or a set
   name, so they are refused rather than escaped. */
BOOL IsSafeFieldText(const char *s)
{
    const char *bad = "\"'`$\\*;&|<>(){}!\n\r";
    int i;
    for (i = 0; s[i]; i++) {
        if ((unsigned char)s[i] < 32 || strchr(bad, s[i])) return FALSE;
    }
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* Persisted config (archive + WHDLoad destinations)                   */
/* ------------------------------------------------------------------ */

void LoadConfig(void)
{
    BPTR fh;
    char line[PATH_BUF_SIZE];

    archiveDestBuf[0] = 0;
    whdloadDestBuf[0] = 0;

    fh = Open(CONFIG_FILE, MODE_OLDFILE);
    if (!fh) return;

    if (FGets(fh, line, sizeof(line))) {
        StripNewline(line);
        CopyStr(archiveDestBuf, line, sizeof(archiveDestBuf));
    }
    if (FGets(fh, line, sizeof(line))) {
        StripNewline(line);
        CopyStr(whdloadDestBuf, line, sizeof(whdloadDestBuf));
    }
    Close(fh);
}

void SaveConfig(void)
{
    BPTR fh;
    fh = Open(CONFIG_FILE, MODE_NEWFILE);
    if (!fh) {
        AppendLog("Warning: could not save archive/WHDLoad defaults.");
        return;
    }
    FPuts(fh, archiveDestBuf);
    FPuts(fh, "\n");
    FPuts(fh, whdloadDestBuf);
    FPuts(fh, "\n");
    Close(fh);
}

/* ------------------------------------------------------------------ */
/* ASL directory picker.                                                */
/* Uses the standard file requester and takes only the Drawer field -   */
/* the classic, reliable way to let someone "pick a directory" with ASL */
/* without depending on a drawers-only mode that may not exist on every */
/* asl.library version. Point it at any file inside the folder you want.*/
/* ------------------------------------------------------------------ */

BOOL PickDrawer(char *title, char *initial, char *outBuf, int outBufSize)
{
    struct FileRequester *fr;
    BOOL ok = FALSE;

    fr = (struct FileRequester *)AllocAslRequestTags(ASL_FileRequest, TAG_END);
    if (!fr) {
        AppendLog("ERROR: could not allocate file requester.");
        return FALSE;
    }

    if (AslRequestTags(fr,
            ASLFR_TitleText,     (ULONG)title,
            ASLFR_InitialDrawer, (ULONG)initial,
            ASLFR_RejectIcons,   TRUE,
            TAG_END))
    {
        if (CopyStr(outBuf, fr->fr_Drawer, outBufSize)) {
            ok = TRUE;
        } else {
            AppendLog("ERROR: that folder's path is too long to use here.");
        }
    }

    FreeAslRequest(fr);
    return ok;
}

/* ------------------------------------------------------------------ */
/* Illegal-filename check + skip logging                                */
/* ------------------------------------------------------------------ */

BOOL HasIllegalChars(char *name)
{
    int i;
    for (i = 0; name[i]; i++) {
        unsigned char c = (unsigned char)name[i];
        /* '"' and '*' are legal in some Amiga filenames but cannot be put
           inside the quoted Copy argument below without changing it. */
        if (c == ':' || c == '/' || c == '"' || c == '*' || c < 32) return TRUE;
    }
    return FALSE;
}

void LogSkip(char *path, char *reason)
{
    char line[320];
    snprintf(line, sizeof(line), "SKIPPED: %s (%s)", path, reason);
    if (gCopyLogFH) {
        FPuts(gCopyLogFH, line);
        FPuts(gCopyLogFH, "\n");
    }
    AppendLog(line);
}

void OpenCopyLog(void)
{
    gCopyLogFH = Open(COPY_LOG_FILE, MODE_NEWFILE);
    if (!gCopyLogFH) {
        AppendLog("Warning: could not open copy log file.");
    }
}

void CloseCopyLog(void)
{
    if (gCopyLogFH) {
        Close(gCopyLogFH);
        gCopyLogFH = 0;
    }
}

/* ------------------------------------------------------------------ */
/* Date comparison, done directly on DateStamp fields rather than      */
/* trusting a remembered library-call sign convention.                 */
/* ------------------------------------------------------------------ */

BOOL IsNewer(struct DateStamp *a, struct DateStamp *b)
{
    if (a->ds_Days   != b->ds_Days)   return a->ds_Days   > b->ds_Days;
    if (a->ds_Minute != b->ds_Minute) return a->ds_Minute > b->ds_Minute;
    return a->ds_Tick > b->ds_Tick;
}

/* ------------------------------------------------------------------ */
/* File copy (shells out to the standard "Copy CLONE" command so dates, */
/* comments and protection bits are preserved - simpler and more       */
/* reliable than a hand-rolled Read/Write loop).                       */
/* ------------------------------------------------------------------ */

BOOL CopyOneFile(char *src, char *dst)
{
    char cmd[2 * PATH_BUF_SIZE + 32];
    LONG rc;
    int n;
    n = snprintf(cmd, sizeof(cmd), "Copy CLONE \"%s\" \"%s\"", src, dst);
    if (n < 0 || n >= (int)sizeof(cmd)) return FALSE;   /* never run a cut-off command */
    rc = SystemTagList(cmd, NULL);
    return (rc == 0);
}

/* Copies srcPath -> dstPath only if dstPath doesn't exist yet, or exists
   but is older than srcPath. srcFib is the already-Examine()'d info for
   srcPath (avoids a second Lock/Examine on the source). */
void CopyFileIfNewer(char *srcPath, char *dstPath, struct FileInfoBlock *srcFib)
{
    BPTR dstLock;
    struct FileInfoBlock *dstFib;
    BOOL needCopy = TRUE;

    dstFib = (struct FileInfoBlock *)AllocVec(sizeof(struct FileInfoBlock), MEMF_CLEAR | MEMF_PUBLIC);
    if (!dstFib) return;

    dstLock = Lock(dstPath, ACCESS_READ);
    if (dstLock) {
        if (Examine(dstLock, dstFib)) {
            needCopy = IsNewer(&srcFib->fib_Date, &dstFib->fib_Date);
        }
        UnLock(dstLock);
    }
    FreeVec(dstFib);

    if (!needCopy) return;

    if (CopyOneFile(srcPath, dstPath)) {
        AppendLog(dstPath);
    } else {
        LogSkip(srcPath, "copy failed");
    }
}

/* ------------------------------------------------------------------ */
/* Recursive tree merge: walks srcDir, mirrors its subdirectories into   */
/* dstDir, and copies any file that's new or newer than its counterpart.*/
/* Anything with an illegal filename character is skipped and logged.   */
/* ------------------------------------------------------------------ */

void MergeTreeRecursive(char *srcDir, char *dstDir)
{
    BPTR lock;
    struct FileInfoBlock *fib;
    char srcPath[PATH_BUF_SIZE], dstPath[PATH_BUF_SIZE];

    fib = (struct FileInfoBlock *)AllocVec(sizeof(struct FileInfoBlock), MEMF_CLEAR | MEMF_PUBLIC);
    if (!fib) return;

    lock = Lock(srcDir, ACCESS_READ);
    if (!lock) {
        char msg[320];
        snprintf(msg, sizeof(msg), "Could not open source directory: %s", srcDir);
        AppendLog(msg);
        FreeVec(fib);
        return;
    }

    if (!Examine(lock, fib)) {
        UnLock(lock);
        FreeVec(fib);
        return;
    }

    while (ExNext(lock, fib)) {
        if (!JoinPath(srcDir, fib->fib_FileName, srcPath, sizeof(srcPath)) ||
            !JoinPath(dstDir, fib->fib_FileName, dstPath, sizeof(dstPath))) {
            LogSkip(fib->fib_FileName, "path too long");
            continue;
        }
        if (HasIllegalChars(fib->fib_FileName)) {
            LogSkip(srcPath, "character that cannot be copied safely");
            continue;
        }

        if (fib->fib_DirEntryType > 0) {
            /* Directory: make sure it exists on the destination side, then recurse */
            BPTR dl = CreateDir(dstPath);
            if (dl) UnLock(dl);
            MergeTreeRecursive(srcPath, dstPath);
        } else {
            CopyFileIfNewer(srcPath, dstPath, fib);
        }
    }

    UnLock(lock);
    FreeVec(fib);
}

/* ------------------------------------------------------------------ */
/* "Merge with Amiga on completion" - the whole flow                    */
/* ------------------------------------------------------------------ */

/* The Pi's collection folder for the variant ticked in the window, e.g.
   retro_aga_laced - the same names all.sh gives them. FALSE when no
   variant is ticked (the Pi may hold several collections, and guessing
   which one to copy is how the wrong one ends up on the Amiga). */
BOOL CollectionName(char *out, int outSize)
{
    char name[80];
    int i;
    if (setBuf[0]) {
        /* --set NAME builds retro_<name, lower case, - as _> */
        if (!CopyStr(name, "retro_", sizeof(name)) || !AppendStr(name, setBuf, sizeof(name)))
            return FALSE;
        for (i = 6; name[i]; i++) {
            if (name[i] >= 'A' && name[i] <= 'Z') name[i] = name[i] - 'A' + 'a';
            if (name[i] == '-') name[i] = '_';
        }
        return CopyStr(out, name, outSize);
    }
    if (IsChecked(GID_SET_ECS))      return CopyStr(out, "retro_ecs", outSize);
    if (IsChecked(GID_SET_AGA))      return CopyStr(out, "retro_aga", outSize);
    if (IsChecked(GID_SET_RTG))      return CopyStr(out, "retro_rtg", outSize);
    if (IsChecked(GID_SET_ECSLACED)) return CopyStr(out, "retro_ecs_laced", outSize);
    if (IsChecked(GID_SET_AGALACED)) return CopyStr(out, "retro_aga_laced", outSize);
    return FALSE;
}

void DoAmigaMerge(void)
{
    char coll[80], source[PATH_BUF_SIZE];

    if (!CollectionName(coll, sizeof(coll))) {
        AppendLog("Merge with Amiga needs one variant ticked (ECS, AGA, RTG, ECS laced,");
        AppendLog("AGA laced) or a set name, so it knows which collection to copy.");
        return;
    }
    if (!JoinPath(PI_BUILD_SOURCE, coll, source, sizeof(source))) {
        AppendLog("ERROR: PI_BUILD_SOURCE plus the collection name is too long.");
        return;
    }

    OpenCopyLog();

    AppendLog("=== Merge with Amiga: choose archive destination ===");
    if (!PickDrawer("Select Amiga archive destination", archiveDestBuf,
                     archiveDestBuf, sizeof(archiveDestBuf))) {
        AppendLog("Merge with Amiga cancelled (no archive destination chosen).");
        CloseCopyLog();
        return;
    }
    AppendLog(archiveDestBuf);

    AppendLog("=== Copying the collection from the Pi into the archive destination ===");
    AppendLog(source);
    MergeTreeRecursive(source, archiveDestBuf);

    AppendLog("=== Merge with Amiga: choose your WHDLoad directory ===");
    if (!PickDrawer("Select your WHDLoad directory", whdloadDestBuf,
                     whdloadDestBuf, sizeof(whdloadDestBuf))) {
        AppendLog("Merge with Amiga cancelled (no WHDLoad directory chosen).");
        SaveConfig();  /* still remember the archive destination we did get */
        CloseCopyLog();
        return;
    }
    AppendLog(whdloadDestBuf);

    SaveConfig();

    AppendLog("=== Copying new/changed files into the WHDLoad directory ===");
    MergeTreeRecursive(archiveDestBuf, whdloadDestBuf);

    CloseCopyLog();
    AppendLog("Merge with Amiga complete.");
    AppendLog("Skipped-file log (if any): " COPY_LOG_FILE);
}

/* ------------------------------------------------------------------ */
/* Command building                                                    */
/* ------------------------------------------------------------------ */

void RunCommandCapture(char *cmdline);

void BuildAndRunCommand(void)
{
    char cmd[640];
    char argbuf[600];
    BOOL fits = TRUE;

    /* Every piece goes through AppendStr, and "fits" collects whether all
       of them did. The four text fields together can exceed the old fixed
       512-byte buffer, which the old unbounded appends ran straight past. */
#define ADD(str) (fits = AppendStr(argbuf, (str), sizeof(argbuf)) && fits)

    argbuf[0] = 0;
    ADD("start.sh");

    if (IsChecked(GID_ACT_AUTO))    ADD(" --auto");
    if (IsChecked(GID_ACT_UPDATE))  ADD(" --update");
    if (IsChecked(GID_ACT_EXTRACT)) ADD(" --extract");
    if (IsChecked(GID_ACT_MERGE))   ADD(" --merge");
    if (IsChecked(GID_ACT_SORT))    ADD(" --sort");
    if (IsChecked(GID_ACT_QUICK))   ADD(" --quick");
    if (IsChecked(GID_ACT_STATUS))  ADD(" --status");
    if (IsChecked(GID_ACT_DOCTOR))  ADD(" --doctor");
    if (IsChecked(GID_REBUILD))     ADD(" --rebuild");
    if (IsChecked(GID_SKIP_UPDATE)) ADD(" --skip-update");
    if (IsChecked(GID_REFRESH_ART)) ADD(" --refresh-artwork");
    if (IsChecked(GID_VERBOSE))     ADD(" --verbose");

    /* Read the current text of the string gadgets */
    {
        struct StringInfo *si;
        si = (struct StringInfo *)gad[GID_DEST_STR]->SpecialInfo;
        CopyStr(destBuf, (char *)si->Buffer, sizeof(destBuf));
        si = (struct StringInfo *)gad[GID_ART_STR]->SpecialInfo;
        CopyStr(artBuf, (char *)si->Buffer, sizeof(artBuf));
        si = (struct StringInfo *)gad[GID_DEMOART_STR]->SpecialInfo;
        CopyStr(demoArtBuf, (char *)si->Buffer, sizeof(demoArtBuf));
        si = (struct StringInfo *)gad[GID_SET_STR]->SpecialInfo;
        CopyStr(setBuf, (char *)si->Buffer, sizeof(setBuf));
    }

    if (!IsSafeFieldText(destBuf) || !IsSafeFieldText(artBuf) ||
        !IsSafeFieldText(demoArtBuf) || !IsSafeFieldText(setBuf)) {
        AppendLog("ERROR: a text field contains a quote or one of  ` $ \\ * ; & | < > ( ) { } !");
        AppendLog("Those would change the command run on the Pi. Nothing was run.");
        return;
    }

    /* A typed-in --set name takes priority over the checkbox shortcuts */
    if (setBuf[0]) {
        ADD(" --set ");
        ADD(setBuf);
    } else if (IsChecked(GID_SET_ECS))      ADD(" --ecs");
    else if (IsChecked(GID_SET_AGA))        ADD(" --aga");
    else if (IsChecked(GID_SET_RTG))        ADD(" --rtg");
    else if (IsChecked(GID_SET_ECSLACED))   ADD(" --ecs-laced");
    else if (IsChecked(GID_SET_AGALACED))   ADD(" --aga-laced");

    if (IsChecked(GID_FS_FFS)) ADD(" --ffs");
    if (IsChecked(GID_FS_PFS)) ADD(" --pfs");

    if (IsChecked(GID_NO_DETOX)) ADD(" --no-detox");
    if (IsChecked(GID_DEBUG))    ADD(" --debug");

    if (destBuf[0])    { ADD(" --dest \""); ADD(destBuf); ADD("\""); }
    if (artBuf[0])     { ADD(" --art \""); ADD(artBuf); ADD("\""); }
    if (demoArtBuf[0]) { ADD(" --demo-art \""); ADD(demoArtBuf); ADD("\""); }

    cmd[0] = 0;
    fits = AppendStr(cmd, PI_EXEC_PREFIX, sizeof(cmd)) && fits;
    fits = AppendStr(cmd, argbuf, sizeof(cmd)) && fits;
#undef ADD

    if (!fits) {
        AppendLog("ERROR: the command line is too long - shorten a text field.");
        AppendLog("Nothing was run (a cut-off command would do something else).");
        return;
    }

    AppendLog("--------------------------------------------------");
    AppendLog(cmd);
    AppendLog("--------------------------------------------------");

    RunCommandCapture(cmd);

    /* Status and Check set-up only report; there is nothing new to copy. */
    if (IsChecked(GID_MERGE_AMIGA) && !IsChecked(GID_ACT_STATUS) && !IsChecked(GID_ACT_DOCTOR)) {
        DoAmigaMerge();
    }
}

/* ------------------------------------------------------------------ */
/* Run a command, streaming its output into the log a line at a time.  */
/* Uses the standard AmigaDOS PIPE: pattern: we open one end, the      */
/* launched command's SYS_Output is the other end.                     */
/* ------------------------------------------------------------------ */

void RunCommandCapture(char *cmdline)
{
    BPTR readfh, writefh;
    LONG rc;
    char line[256];

    readfh = Open("PIPE:A314GUI", MODE_NEWFILE);
    if (!readfh) {
        AppendLog("ERROR: could not open PIPE:A314GUI for reading");
        return;
    }

    writefh = Open("PIPE:A314GUI", MODE_OLDFILE);
    if (!writefh) {
        AppendLog("ERROR: could not open PIPE:A314GUI for writing");
        Close(readfh);
        return;
    }

    {
        /* A plain array rather than a C99 compound literal, so the SAS/C
           build line in the header comment actually works. */
        struct TagItem sysTags[3];
        sysTags[0].ti_Tag = SYS_Output; sysTags[0].ti_Data = (ULONG)writefh;
        sysTags[1].ti_Tag = SYS_Asynch; sysTags[1].ti_Data = TRUE;
        sysTags[2].ti_Tag = TAG_END;    sysTags[2].ti_Data = 0;
        rc = SystemTagList(cmdline, sysTags);
    }

    /* SYS_Asynch hands ownership of writefh to the child; don't close it
       here. Read lines from our end until EOF (child closes its end). */
    while (FGets(readfh, line, sizeof(line))) {
        int len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = 0;
        AppendLog(line);

        /* Let Intuition breathe so the window redraws as lines arrive */
        WaitTOF();
    }

    Close(readfh);

    if (rc < 0) {
        AppendLog("ERROR: failed to launch command on the Pi.");
        AppendLog("Check PI_EXEC_PREFIX at the top of this program's source.");
    } else {
        AppendLog("(command finished)");
    }
}

/* ------------------------------------------------------------------ */
/* GUI setup                                                            */
/* ------------------------------------------------------------------ */

struct Gadget *MakeCheckbox(struct NewGadget *ng, struct Gadget *prev, int id, char *label, int top)
{
    ng->ng_LeftEdge   = 10;
    ng->ng_TopEdge    = top;
    ng->ng_Width      = 140;
    ng->ng_Height     = 14;
    ng->ng_GadgetText = label;
    ng->ng_GadgetID   = id;
    ng->ng_Flags      = 0;
    return CreateGadgetA(CHECKBOX_KIND, prev, ng, NULL);
}

struct Gadget *MakeString(struct NewGadget *ng, struct Gadget *prev, int id, char *label, int left, int top, int width)
{
    ng->ng_LeftEdge   = left;
    ng->ng_TopEdge    = top;
    ng->ng_Width      = width;
    ng->ng_Height     = 14;
    ng->ng_GadgetText = label;
    ng->ng_GadgetID   = id;
    ng->ng_Flags      = PLACETEXT_ABOVE;
    return CreateGadgetA(STRING_KIND, prev, ng, NULL);
}

BOOL SetupGUI(void)
{
    struct NewGadget ng;
    struct Gadget *prev;
    int col1x = 10, col2x = 160, col3x = 310;
    int y;

    IntuitionBase = OpenLibrary("intuition.library", 37);
    GfxBase       = OpenLibrary("graphics.library", 37);
    GadToolsBase  = OpenLibrary("gadtools.library", 37);
    AslBase       = OpenLibrary("asl.library", 37);
    if (!IntuitionBase || !GfxBase || !GadToolsBase || !AslBase) return FALSE;

    scr = LockPubScreen(NULL);
    if (!scr) return FALSE;

    vi = GetVisualInfo(scr, TAG_END);
    if (!vi) return FALSE;

    memset(&ng, 0, sizeof(ng));
    ng.ng_VisualInfo = vi;
    ng.ng_TextAttr   = scr->Font;

    prev = CreateContext(&glist);

    /* --- Column 1: action --- */
    y = 20;
    gad[GID_ACT_AUTO]    = prev = MakeCheckbox(&ng, prev, GID_ACT_AUTO,    "Auto (full run)", y); y += 18;
    gad[GID_ACT_UPDATE]  = prev = MakeCheckbox(&ng, prev, GID_ACT_UPDATE,  "Update only", y);      y += 18;
    gad[GID_ACT_EXTRACT] = prev = MakeCheckbox(&ng, prev, GID_ACT_EXTRACT, "Extract only", y);     y += 18;
    gad[GID_ACT_MERGE]   = prev = MakeCheckbox(&ng, prev, GID_ACT_MERGE,   "Merge only", y);       y += 18;
    gad[GID_ACT_SORT]    = prev = MakeCheckbox(&ng, prev, GID_ACT_SORT,    "Sort only", y);        y += 18;
    gad[GID_ACT_QUICK]   = prev = MakeCheckbox(&ng, prev, GID_ACT_QUICK,   "Quick (new files)", y);  y += 18;
    /* Read-only: what state everything is in, and what is wrong with the
       set-up. Neither changes anything on the Pi. */
    gad[GID_ACT_STATUS]  = prev = MakeCheckbox(&ng, prev, GID_ACT_STATUS,  "Status", y);            y += 18;
    gad[GID_ACT_DOCTOR]  = prev = MakeCheckbox(&ng, prev, GID_ACT_DOCTOR,  "Check set-up", y);

    /* --- Column 2: artwork set --- */
    ng.ng_LeftEdge = col2x;
    y = 20;
    ng.ng_TopEdge = y; ng.ng_Width = 140; ng.ng_Height = 14;
    ng.ng_GadgetText = "ECS";      ng.ng_GadgetID = GID_SET_ECS;
    gad[GID_SET_ECS] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "AGA"; ng.ng_GadgetID = GID_SET_AGA;
    gad[GID_SET_AGA] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "RTG"; ng.ng_GadgetID = GID_SET_RTG;
    gad[GID_SET_RTG] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    /* The laced collections. These used to be "ECS-Lo"/"AGA-Lo" sending
       --ecs-lo/--aga-lo, which start.sh has never accepted: plain ECS and
       AGA already ARE the LoRes artwork. */
    ng.ng_TopEdge = y; ng.ng_GadgetText = "ECS laced"; ng.ng_GadgetID = GID_SET_ECSLACED;
    gad[GID_SET_ECSLACED] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "AGA laced"; ng.ng_GadgetID = GID_SET_AGALACED;
    gad[GID_SET_AGALACED] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "Rebuild"; ng.ng_GadgetID = GID_REBUILD;
    gad[GID_REBUILD] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "Skip update"; ng.ng_GadgetID = GID_SKIP_UPDATE;
    gad[GID_SKIP_UPDATE] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL);

    /* --- Column 3: filesystem + toggles --- */
    ng.ng_LeftEdge = col3x;
    y = 20;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "FFS"; ng.ng_GadgetID = GID_FS_FFS;
    gad[GID_FS_FFS] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "PFS (default)"; ng.ng_GadgetID = GID_FS_PFS;
    gad[GID_FS_PFS] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 26;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "No detox"; ng.ng_GadgetID = GID_NO_DETOX;
    gad[GID_NO_DETOX] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "Debug output"; ng.ng_GadgetID = GID_DEBUG;
    gad[GID_DEBUG] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "Merge with Amiga on completion"; ng.ng_GadgetID = GID_MERGE_AMIGA;
    ng.ng_Width = 260;
    gad[GID_MERGE_AMIGA] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL);
    ng.ng_Width = 140; y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "Refresh artwork"; ng.ng_GadgetID = GID_REFRESH_ART;
    gad[GID_REFRESH_ART] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "Verbose output"; ng.ng_GadgetID = GID_VERBOSE;
    gad[GID_VERBOSE] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL);

    /* --- Text fields --- (below the third row of checkboxes) */
    y = 176;
    gad[GID_DEST_STR]    = prev = MakeString(&ng, prev, GID_DEST_STR,    "Dest path (--dest)",        col1x, y, 280); 
    gad[GID_SET_STR]     = prev = MakeString(&ng, prev, GID_SET_STR,     "Custom set name (--set)",   col3x, y, 150);
    y += 34;
    gad[GID_ART_STR]      = prev = MakeString(&ng, prev, GID_ART_STR,     "Art order (--art)",         col1x, y, 280);
    gad[GID_DEMOART_STR]  = prev = MakeString(&ng, prev, GID_DEMOART_STR, "Demo art order (--demo-art)", col3x, y, 150);

    /* --- Execute / Quit buttons --- */
    y += 34;
    ng.ng_LeftEdge = col1x; ng.ng_TopEdge = y; ng.ng_Width = 100; ng.ng_Height = 20;
    ng.ng_GadgetText = "Execute"; ng.ng_GadgetID = GID_EXECUTE; ng.ng_Flags = 0;
    gad[GID_EXECUTE] = prev = CreateGadgetA(BUTTON_KIND, prev, &ng, NULL);

    ng.ng_LeftEdge = col1x + 110; ng.ng_GadgetText = "Quit"; ng.ng_GadgetID = GID_QUIT;
    gad[GID_QUIT] = prev = CreateGadgetA(BUTTON_KIND, prev, &ng, NULL);

    /* --- Output log --- */
    y += 30;
    NewList(&logList);
    ng.ng_LeftEdge = col1x; ng.ng_TopEdge = y; ng.ng_Width = WIN_WIDTH - 40; ng.ng_Height = WIN_HEIGHT - y - 20;
    ng.ng_GadgetText = "Output"; ng.ng_GadgetID = GID_LOG_LIST; ng.ng_Flags = PLACETEXT_ABOVE;
    {
        /* CreateGadgetA takes a POINTER to a tag array. This used to pass the
           tags inline, as if it were the varargs CreateGadget(), so the first
           tag value was read as the tag-list address - on a real Amiga the
           output list either never appeared or took the machine down. */
        struct TagItem lvTags[3];
        lvTags[0].ti_Tag = GTLV_Labels;       lvTags[0].ti_Data = (ULONG)&logList;
        lvTags[1].ti_Tag = GTLV_ShowSelected; lvTags[1].ti_Data = 0;
        lvTags[2].ti_Tag = TAG_END;           lvTags[2].ti_Data = 0;
        gad[GID_LOG_LIST] = prev = CreateGadgetA(LISTVIEW_KIND, prev, &ng, lvTags);
    }

    if (!prev) return FALSE;

    win = OpenWindowTags(NULL,
        WA_Left, 40, WA_Top, 20,
        WA_Width, WIN_WIDTH, WA_Height, WIN_HEIGHT,
        WA_Title, (ULONG)"A314 Retroplay Control",
        WA_Gadgets, (ULONG)glist,
        WA_CloseGadget, TRUE, WA_DepthGadget, TRUE, WA_DragBar, TRUE,
        WA_IDCMP, IDCMP_GADGETUP | IDCMP_CLOSEWINDOW | IDCMP_REFRESHWINDOW,
        WA_PubScreen, (ULONG)scr,
        /* On a screen smaller than the window (a 640x256 PAL Workbench),
           Intuition moves and shrinks it to fit instead of refusing to open
           it - the log list at the bottom is what gets cut short. */
        WA_AutoAdjust, TRUE,
        TAG_END);

    if (!win) return FALSE;

    GT_RefreshWindow(win, NULL);

    /* Default selections */
    SetChecked(GID_ACT_QUICK, TRUE);
    SetChecked(GID_FS_PFS, TRUE);

    LoadConfig();

    return TRUE;
}

void CleanupGUI(void)
{
    struct Node *n;
    if (win) CloseWindow(win);
    if (glist) FreeGadgets(glist);
    if (vi) FreeVisualInfo(vi);
    if (scr) UnlockPubScreen(NULL, scr);
    while ((n = (struct Node *)RemHead(&logList))) {
        FreeVec(n->ln_Name);
        FreeVec(n);
    }
    if (AslBase) CloseLibrary(AslBase);
    if (GadToolsBase) CloseLibrary(GadToolsBase);
    if (GfxBase) CloseLibrary(GfxBase);
    if (IntuitionBase) CloseLibrary(IntuitionBase);
}

int main(void)
{
    struct IntuiMessage *imsg;
    BOOL done = FALSE;

    if (!SetupGUI()) {
        CleanupGUI();
        return 20;
    }

    /* Say where commands go and where collections are copied from, so a
       wrong setting is visible before anything is run. */
    AppendLog("Pi command prefix (PI_EXEC_PREFIX): \"" PI_EXEC_PREFIX "\"");
    AppendLog("Pi build folder  (PI_BUILD_SOURCE): " PI_BUILD_SOURCE);
    AppendLog("If either is wrong, edit the two #defines at the top of the source.");
    AppendLog("Ready. Choose options and press Execute.");

    while (!done) {
        Wait(1L << win->UserPort->mp_SigBit);

        while ((imsg = GT_GetIMsg(win->UserPort))) {
            switch (imsg->Class) {
                case IDCMP_CLOSEWINDOW:
                    done = TRUE;
                    break;

                case IDCMP_REFRESHWINDOW:
                    GT_BeginRefresh(win);
                    GT_EndRefresh(win, TRUE);
                    break;

                case IDCMP_GADGETUP: {
                    struct Gadget *g = (struct Gadget *)imsg->IAddress;
                    switch (g->GadgetID) {
                        case GID_ACT_AUTO: case GID_ACT_UPDATE: case GID_ACT_EXTRACT:
                        case GID_ACT_MERGE: case GID_ACT_SORT: case GID_ACT_QUICK:
                        case GID_ACT_STATUS: case GID_ACT_DOCTOR:
                            EnforceGroup(actionGroup, g->GadgetID);
                            break;
                        case GID_SET_ECS: case GID_SET_AGA: case GID_SET_RTG:
                        case GID_SET_ECSLACED: case GID_SET_AGALACED:
                            EnforceGroup(setGroup, g->GadgetID);
                            break;
                        case GID_FS_FFS: case GID_FS_PFS:
                            EnforceGroup(fsGroup, g->GadgetID);
                            break;
                        case GID_EXECUTE:
                            BuildAndRunCommand();
                            break;
                        case GID_QUIT:
                            done = TRUE;
                            break;
                    }
                    break;
                }
            }
            GT_ReplyIMsg(imsg);
        }
    }

    CleanupGUI();
    return 0;
}
