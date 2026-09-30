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
 *   2. PI_RETRO_SOURCE - the Amiga-visible path to the Pi's "retro"
 *      directory (e.g. wherever A314's shared filesystem mounts it, such
 *      as "PI0:retro"). This is used as the source for step 2 above. I do
 *      not know your A314 setup's actual volume/mount name, so this is a
 *      placeholder - edit it to match.
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
 *   - PI_EXEC_PREFIX and PI_RETRO_SOURCE (see above) - the two load-bearing
 *     unknowns about your specific A314 setup.
 *   - The pipe-based output capture and the recursive copy/compare logic
 *     use standard, well-documented AmigaDOS techniques (PIPE: device,
 *     Examine()/ExNext(), DateStamp fields, the "Copy CLONE" shell command)
 *     but none of this has been compile-tested in this environment - treat
 *     it as a strong starting point, not a guarantee.
 *   - "Illegal filename character" is checked as ':', '/', and control
 *     characters (the ones AmigaDOS filesystems genuinely can't store in a
 *     filename). It does not re-check the length limits sort.sh already
 *     enforces on the Pi side.
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

/* ------------------------------------------------------------------ */
/* THE TWO THINGS TO EDIT: how a shell command reaches the Pi, and     */
/* where the Pi's retro/ directory is visible from the Amiga side.    */
/* ------------------------------------------------------------------ */
#define PI_EXEC_PREFIX   "pi "
#define PI_RETRO_SOURCE  "PI0:retro"

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
    GID_ACT_SORT, GID_ACT_QUICK,

    GID_SET_ECS, GID_SET_AGA, GID_SET_RTG, GID_SET_ECSLO, GID_SET_AGALO,

    GID_FS_FFS, GID_FS_PFS,

    GID_NO_DETOX, GID_DEBUG, GID_MERGE_AMIGA,

    GID_DEST_STR, GID_ART_STR, GID_DEMOART_STR, GID_SET_STR,

    GID_EXECUTE, GID_QUIT,

    GID_LOG_LIST,

    GID_COUNT
};

/* One-of-a-group checkbox IDs, used to enforce mutual exclusivity */
static const int actionGroup[] = { GID_ACT_AUTO, GID_ACT_UPDATE, GID_ACT_EXTRACT,
                                    GID_ACT_MERGE, GID_ACT_SORT, GID_ACT_QUICK, -1 };
static const int setGroup[]    = { GID_SET_ECS, GID_SET_AGA, GID_SET_RTG,
                                    GID_SET_ECSLO, GID_SET_AGALO, -1 };
static const int fsGroup[]     = { GID_FS_FFS, GID_FS_PFS, -1 };

char destBuf[128]    = "";
char artBuf[128]     = "";
char demoArtBuf[128] = "";
char setBuf[64]      = "";

/* Persisted across runs via CONFIG_FILE */
char archiveDestBuf[PATH_BUF_SIZE] = "";
char whdloadDestBuf[PATH_BUF_SIZE] = "";

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
    strcpy(copy, text);

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

/* Joins a directory and a name, only inserting "/" when the directory
   isn't a bare volume/assign root (which already ends in ":"). */
void JoinPath(char *dir, char *name, char *out, int outSize)
{
    int len = strlen(dir);
    if (len > 0 && dir[len - 1] == ':') {
        snprintf(out, outSize, "%s%s", dir, name);
    } else {
        snprintf(out, outSize, "%s/%s", dir, name);
    }
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
        strncpy(archiveDestBuf, line, sizeof(archiveDestBuf) - 1);
    }
    if (FGets(fh, line, sizeof(line))) {
        StripNewline(line);
        strncpy(whdloadDestBuf, line, sizeof(whdloadDestBuf) - 1);
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
        strncpy(outBuf, fr->fr_Drawer, outBufSize - 1);
        outBuf[outBufSize - 1] = 0;
        ok = TRUE;
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
        if (c == ':' || c == '/' || c < 32) return TRUE;
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
    char cmd[600];
    LONG rc;
    snprintf(cmd, sizeof(cmd), "Copy CLONE \"%s\" \"%s\"", src, dst);
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
        if (HasIllegalChars(fib->fib_FileName)) {
            JoinPath(srcDir, fib->fib_FileName, srcPath, sizeof(srcPath));
            LogSkip(srcPath, "illegal character in filename");
            continue;
        }

        JoinPath(srcDir, fib->fib_FileName, srcPath, sizeof(srcPath));
        JoinPath(dstDir, fib->fib_FileName, dstPath, sizeof(dstPath));

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

void DoAmigaMerge(void)
{
    OpenCopyLog();

    AppendLog("=== Merge with Amiga: choose archive destination ===");
    if (!PickDrawer("Select Amiga archive destination", archiveDestBuf,
                     archiveDestBuf, sizeof(archiveDestBuf))) {
        AppendLog("Merge with Amiga cancelled (no archive destination chosen).");
        CloseCopyLog();
        return;
    }
    AppendLog(archiveDestBuf);

    AppendLog("=== Copying retro/ from the Pi into the archive destination ===");
    MergeTreeRecursive(PI_RETRO_SOURCE, archiveDestBuf);

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
    char cmd[512];
    char argbuf[512];

    strcpy(argbuf, "start.sh");

    if (IsChecked(GID_ACT_AUTO))    strcat(argbuf, " --auto");
    if (IsChecked(GID_ACT_UPDATE))  strcat(argbuf, " --update");
    if (IsChecked(GID_ACT_EXTRACT)) strcat(argbuf, " --extract");
    if (IsChecked(GID_ACT_MERGE))   strcat(argbuf, " --merge");
    if (IsChecked(GID_ACT_SORT))    strcat(argbuf, " --sort");
    if (IsChecked(GID_ACT_QUICK))   strcat(argbuf, " --quick");

    /* Read the current text of the string gadgets */
    {
        struct StringInfo *si;
        si = (struct StringInfo *)gad[GID_DEST_STR]->SpecialInfo;
        strncpy(destBuf, si->Buffer, sizeof(destBuf) - 1);
        si = (struct StringInfo *)gad[GID_ART_STR]->SpecialInfo;
        strncpy(artBuf, si->Buffer, sizeof(artBuf) - 1);
        si = (struct StringInfo *)gad[GID_DEMOART_STR]->SpecialInfo;
        strncpy(demoArtBuf, si->Buffer, sizeof(demoArtBuf) - 1);
        si = (struct StringInfo *)gad[GID_SET_STR]->SpecialInfo;
        strncpy(setBuf, si->Buffer, sizeof(setBuf) - 1);
    }

    /* A typed-in --set name takes priority over the checkbox shortcuts */
    if (setBuf[0]) {
        strcat(argbuf, " --set ");
        strcat(argbuf, setBuf);
    } else if (IsChecked(GID_SET_ECS))   strcat(argbuf, " --ecs");
    else if (IsChecked(GID_SET_AGA))     strcat(argbuf, " --aga");
    else if (IsChecked(GID_SET_RTG))     strcat(argbuf, " --rtg");
    else if (IsChecked(GID_SET_ECSLO))   strcat(argbuf, " --ecs-lo");
    else if (IsChecked(GID_SET_AGALO))   strcat(argbuf, " --aga-lo");

    if (IsChecked(GID_FS_FFS)) strcat(argbuf, " --ffs");
    if (IsChecked(GID_FS_PFS)) strcat(argbuf, " --pfs");

    if (IsChecked(GID_NO_DETOX)) strcat(argbuf, " --no-detox");
    if (IsChecked(GID_DEBUG))    strcat(argbuf, " --debug");

    if (destBuf[0])    { strcat(argbuf, " --dest \""); strcat(argbuf, destBuf); strcat(argbuf, "\""); }
    if (artBuf[0])     { strcat(argbuf, " --art \""); strcat(argbuf, artBuf); strcat(argbuf, "\""); }
    if (demoArtBuf[0]) { strcat(argbuf, " --demo-art \""); strcat(argbuf, demoArtBuf); strcat(argbuf, "\""); }

    strcpy(cmd, PI_EXEC_PREFIX);
    strcat(cmd, argbuf);

    AppendLog("--------------------------------------------------");
    AppendLog(cmd);
    AppendLog("--------------------------------------------------");

    RunCommandCapture(cmd);

    if (IsChecked(GID_MERGE_AMIGA)) {
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

    rc = SystemTagList(cmdline, (struct TagItem *)(struct TagItem[]) {
        { SYS_Output, (ULONG)writefh },
        { SYS_Asynch, TRUE },
        { TAG_END, 0 }
    });

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
    gad[GID_ACT_QUICK]   = prev = MakeCheckbox(&ng, prev, GID_ACT_QUICK,   "Quick (new files)", y);

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
    ng.ng_TopEdge = y; ng.ng_GadgetText = "ECS-Lo"; ng.ng_GadgetID = GID_SET_ECSLO;
    gad[GID_SET_ECSLO] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL); y += 18;
    ng.ng_TopEdge = y; ng.ng_GadgetText = "AGA-Lo"; ng.ng_GadgetID = GID_SET_AGALO;
    gad[GID_SET_AGALO] = prev = CreateGadgetA(CHECKBOX_KIND, prev, &ng, NULL);

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
    ng.ng_Width = 140;

    /* --- Text fields --- */
    y = 150;
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
    gad[GID_LOG_LIST] = prev = CreateGadgetA(LISTVIEW_KIND, prev, &ng,
        GTLV_Labels, (ULONG)&logList,
        GTLV_ShowSelected, NULL,
        TAG_END);

    if (!prev) return FALSE;

    win = OpenWindowTags(NULL,
        WA_Left, 40, WA_Top, 20,
        WA_Width, WIN_WIDTH, WA_Height, WIN_HEIGHT,
        WA_Title, (ULONG)"A314 Retroplay Control",
        WA_Gadgets, (ULONG)glist,
        WA_CloseGadget, TRUE, WA_DepthGadget, TRUE, WA_DragBar, TRUE,
        WA_IDCMP, IDCMP_GADGETUP | IDCMP_CLOSEWINDOW | IDCMP_REFRESHWINDOW,
        WA_PubScreen, (ULONG)scr,
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
                            EnforceGroup(actionGroup, g->GadgetID);
                            break;
                        case GID_SET_ECS: case GID_SET_AGA: case GID_SET_RTG:
                        case GID_SET_ECSLO: case GID_SET_AGALO:
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
