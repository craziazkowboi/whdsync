/*
 * a314_retroplay_gui.c - whdsync front end for the Amiga side of an A314
 *
 * Runs the whdsync scripts on the Raspberry Pi from a MUI window on the
 * Amiga, shows what they print, and can copy the finished games across.
 *
 * WHAT IT DOES
 *   Simple mode    Pick All, RTG, AGA or ECS and press Start. That runs
 *                  all.sh, rtg.sh, aga.sh or ecs.sh with the settings in
 *                  retroplay.conf - nothing else is added.
 *   Advanced mode  Every task and option start.sh has, chosen with radio
 *                  buttons, cycles, sliders and checkboxes; and every
 *                  everyday setting in retroplay.conf, on five pages.
 *                  "Save settings" writes them to retroplay.conf in the
 *                  folder this program was started from (PROGDIR:).
 *   Copy           After a build (or with "Copy now"), copies the games
 *                  into a drawer on the Amiga: just the latest new games
 *                  (build/new_<variant>/<date>), or everything that is new
 *                  or changed in build/retro_<variant>.
 *
 * WHERE TO PUT IT
 *   In the whdsync main folder on the Pi share - the folder holding
 *   artwork/, build/ and downloads/ (for example PI0:whdsync). Then
 *   "Save settings" writes the retroplay.conf the scripts actually read,
 *   and the defaults for the build folder and the last-run record are
 *   right without changing anything. Anywhere else works too: set the
 *   folders on the A314 page.
 *
 * HOW A RUN REACHES THE PI
 *   <Pi command> <scripts folder>/<script> --color=never <options>
 *   "Pi command" is whatever runs a Pi program from the Amiga shell - the
 *   A314 "pi" command by default. Both are set on the A314 page. The run
 *   goes through a two-line script in T: so that its exit code can be
 *   read back ("FailAt 1000", the command, then "Echo" of $RC), and its
 *   output goes to a file in T: that the window reads four times a second.
 *   The window never blocks while the Pi works.
 *
 * REQUIREMENTS
 *   Kickstart/Workbench 2.04 (V37) or later, and MUI 3.8 or later.
 *   Everything else used is in ROM or in a standard 2.04 installation:
 *   timer.device, asl.library (through MUI's Popasl), the Execute and
 *   Echo commands. On 2.04 the drawer requester cannot hide files (that
 *   arrived with asl.library V38): pick the drawer and leave the file
 *   field empty.
 *
 * BUILDING (needs the NDK 3.x includes and the MUI 3.8 developer includes)
 *   vbcc:   vc +aos68k -O2 -I<MUI>/Developer/C/Include
 *              a314_retroplay_gui.c -lamiga -o A314RetroplayGUI
 *   SAS/C:  sc a314_retroplay_gui.c IDIR=<MUI>/Developer/C/Include
 *              LINK LIB lib:amiga.lib TO A314RetroplayGUI
 *   gcc:    m68k-amigaos-gcc -O2 -noixemul -I<MUI>/Developer/C/Include
 *              a314_retroplay_gui.c -o A314RetroplayGUI
 *   (Do not link vbcc's -lauto: this program opens its own libraries.)
 *
 *   Written in plain C89: no // comments, no compound literals, no
 *   snprintf (SAS/C 6 has none). All string handling goes through the
 *   bounded helpers below; tests/run_tests.sh compiles and runs those on
 *   the build machine.
 *
 * Copyright (c) 2025-2026 Craziazkowboi and whdsync contributors
 * License: MIT - see LICENSE
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <exec/ports.h>
#include <exec/io.h>
#include <devices/timer.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <dos/dostags.h>
#include <intuition/intuition.h>
#include <intuition/intuitionbase.h>
#include <intuition/classusr.h>
#include <libraries/asl.h>
#include <libraries/mui.h>
#include <utility/tagitem.h>

#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/muimaster.h>
#include <clib/alib_protos.h>

#include <string.h>

#ifndef MAKE_ID
#define MAKE_ID(a,b,c,d) ((ULONG)(a)<<24 | (ULONG)(b)<<16 | (ULONG)(c)<<8 | (ULONG)(d))
#endif

#define APP_RELEASE  "0.6"
static const char versionTag[] = "$VER: A314RetroplayGUI 0.6 (18.11.2026)";

/* A deep drawer walk during a copy, and MUI itself, want more than the
   4 KB a Workbench start gives. SAS/C and libnix both read this. */
long __stack = 32768;

/* ------------------------------------------------------------------ */
/* Files and sizes                                                     */
/* ------------------------------------------------------------------ */
#define CONF_FILE     "PROGDIR:retroplay.conf"
#define CONF_NEW      "PROGDIR:retroplay.conf.new"
#define CONF_BAK      "PROGDIR:retroplay.conf.bak"
#define PREFS_FILE    "PROGDIR:A314RetroplayGUI.prefs"
#define COPY_LOG_FILE "PROGDIR:A314RetroplayGUI_copylog.txt"
#define RUN_SCRIPT    "A314RetroplayGUI.run"
#define RUN_OUTPUT    "A314RetroplayGUI.out"
#define RC_SENTINEL   "@@A314GUI-RC="
#define TEMP_NAME     "A314GUI.tmp"

#define CMD_SIZE    1024
#define PATH_SIZE   256
#define RAW_SIZE    256
#define LINE_SIZE   512
#define MAX_LOG     500
#define MAX_CHOICE  10
#define MAX_LIST    8
#define COPY_BUF    32768

/* Return IDs */
enum { ID_START = 1, ID_STATUS, ID_DOCTOR, ID_COPY, ID_SAVE, ID_REFRESH };

struct IntuitionBase *IntuitionBase = NULL;
struct Library *MUIMasterBase = NULL;

/* ================================================================== */
/* Bounded string helpers.                                             */
/* Every one of these is compiled and run on the build machine by      */
/* tests/run_tests.sh, so they use nothing but <string.h> and BOOL.    */
/* ================================================================== */

/* Copies src into dst (dstSize bytes, always terminated).
   TRUE when all of it fitted; FALSE when it had to be cut short. */
BOOL CopyStr(char *dst, const char *src, int dstSize)
{
    int i;
    if (dstSize <= 0) return FALSE;
    for (i = 0; i < dstSize - 1 && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
    return src[i] == 0 ? TRUE : FALSE;
}

/* Appends src to the string in dst. Same rules as CopyStr. */
BOOL AppendStr(char *dst, const char *src, int dstSize)
{
    int len = (int)strlen(dst);
    if (len >= dstSize - 1) return src[0] == 0 ? TRUE : FALSE;
    return CopyStr(dst + len, src, dstSize - len);
}

/* dir + name, with a "/" only where one is needed: not after a volume or
   assign ("DH0:"), not after a "/" already there, not with no dir at all.
   FALSE when the result did not fit (out then holds a cut-short path,
   which callers must not use). */
BOOL JoinPath(const char *dir, const char *name, char *out, int outSize)
{
    int len = (int)strlen(dir);
    if (!CopyStr(out, dir, outSize)) return FALSE;
    if (len > 0 && dir[len - 1] != ':' && dir[len - 1] != '/') {
        if (!AppendStr(out, "/", outSize)) return FALSE;
    }
    return AppendStr(out, name, outSize);
}

/* Text that goes to the Pi - into a command line or into retroplay.conf -
   may only hold characters that mean nothing to the Amiga shell, the Pi's
   shell or the settings file: letters, digits, space and / . _ - + , : = @
   % ~. Everything else is refused rather than escaped: quotes, $, `, ;
   (a comment in an AmigaDOS script), * (AmigaDOS's escape character),
   wildcards, redirection, brackets and control characters. */
BOOL IsSafeFieldText(const char *s)
{
    const char *ok = " /._-+,:=@%~";
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c >= 'a' && c <= 'z') continue;
        if (c >= 'A' && c <= 'Z') continue;
        if (c >= '0' && c <= '9') continue;
        if (c != 0 && strchr(ok, c) != NULL) continue;
        return FALSE;
    }
    return TRUE;
}

/* Appends a number (no printf: SAS/C 6 has no snprintf). */
BOOL AppendNum(char *dst, long n, int dstSize)
{
    char tmp[16];
    int i = 15;
    BOOL neg = n < 0 ? TRUE : FALSE;
    unsigned long u = neg ? (unsigned long)(-n) : (unsigned long)n;
    tmp[i] = 0;
    do { tmp[--i] = (char)('0' + (int)(u % 10)); u /= 10; } while (u && i > 1);
    if (neg) tmp[--i] = '-';
    return AppendStr(dst, tmp + i, dstSize);
}

/* Reads a whole number; FALSE when s is not one (empty, or other text). */
BOOL ParseLong(const char *s, long *out)
{
    long v = 0;
    BOOL neg = FALSE, any = FALSE;
    while (*s == ' ') s++;
    if (*s == '-') { neg = TRUE; s++; }
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; any = TRUE; }
    while (*s == ' ') s++;
    if (!any || *s) return FALSE;
    *out = neg ? -v : v;
    return TRUE;
}

/* ================================================================== */
/* Choices offered on the pages                                        */
/* ================================================================== */
static const char *const vVariants[] = { "aga", "ecs", "rtg", "aga-laced", "ecs-laced", NULL };
static const char *const lVariants[] = { "AGA", "ECS", "RTG", "AGA laced", "ECS laced", NULL };
static const char *const vMirror[] = { "HD_Loaders/Games", "JST/Games", "WHDLoad/Magazines",
                                       "WHDLoad/Demos", "WHDLoad/Games",
                                       "WHDLoad/Games/Beta & Unreleased", NULL };
static const char *const lMirror[] = { "HD Loaders", "JST", "Magazines", "Demos", "Games",
                                       "Betas & unreleased", NULL };
static const char *const vFs[] = { "pfs", "ffs", NULL };
static const char *const lFs[] = { "PFS - names up to 107 characters",
                                   "FFS - names up to 30 characters", NULL };
static const char *const vArtSync[] = { "auto", "ask", "no", NULL };
static const char *const lArtSync[] = { "Automatically, at the interval below",
                                        "Only missing packs (others on request)",
                                        "Never", NULL };
static const char *const vOrder[] = { "Screens,Covers,Titles", "Screens,Titles,Covers",
                                      "Covers,Screens,Titles", "Covers,Titles,Screens",
                                      "Titles,Screens,Covers", "Titles,Covers,Screens", NULL };
static const char *const lOrder[] = { "Screens, Covers, Titles", "Screens, Titles, Covers",
                                      "Covers, Screens, Titles", "Covers, Titles, Screens",
                                      "Titles, Screens, Covers", "Titles, Covers, Screens", NULL };
static const char *const vLocal[] = { "ask", "keep-local", "backup-and-replace", "fail", NULL };
static const char *const lLocal[] = { "Ask (keep mine when nobody is there)", "Keep mine",
                                      "Back mine up, then replace it", "Stop the run", NULL };
static const char *const vFail[] = { "warn-and-continue", "fail", NULL };
static const char *const lFail[] = { "Carry on with the artwork I have", "Stop the run", NULL };
static const char *const vVerify[] = { "auto", "yes", "no", NULL };
static const char *const lVerify[] = { "Batches of up to 100 files", "Always", "Never", NULL };
static const char *const vNice[] = { "auto", "no", NULL };
static const char *const lNice[] = { "When nobody is watching", "Never", NULL };

/* ================================================================== */
/* The settings in retroplay.conf this window manages                  */
/* ================================================================== */
enum { K_BOOL, K_CHOICE, K_NUM, K_TEXT, K_LIST, K_DERIVED };
enum { PG_NONE, PG_COLL, PG_ART, PG_DL, PG_SYS };
#define SF_AUTOZERO 1     /* K_NUM: 0 on the slider is "auto" in the file */
#define SF_EMPTYDEF 2     /* K_TEXT: left empty means the default (written out) */

struct Setting {
    const char *key;
    int page;
    int kind;
    const char *label;
    const char *help;
    const char *def;                 /* the built-in default (lib.sh) */
    const char *const *values;       /* K_CHOICE values / K_LIST tokens */
    const char *const *labels;       /* what the window shows for them */
    long min, max, scale;            /* K_NUM: slider range; file = slider x scale */
    const char *fmt;                 /* K_NUM: slider text */
    const char *sep;                 /* K_LIST: written between tokens */
    int flags;
    /* filled in at run time */
    Object *obj;
    Object *box[MAX_LIST];
    char raw[RAW_SIZE];              /* the value as it is in the file now */
    long init;                       /* the widget state that value shows as */
    int nvalues;
    const char *cyc[MAX_CHOICE + 2];
    char keepLabel[72];
    char newRaw[RAW_SIZE];           /* used while saving */
    BOOL dirty, written;             /* used while saving */
};

static struct Setting settings[] = {
    /* -------- Collections -------- */
    { "VARIANTS", PG_COLL, K_LIST, "Collections to build",
      "Each one is a complete collection of its own on the Pi's drive.\n"
      "The artwork packs they need are fetched to match. (VARIANTS)",
      "aga ecs rtg aga-laced ecs-laced", vVariants, lVariants, 0, 0, 0, NULL, " ", 0 },
    { "FILESYSTEM", PG_COLL, K_CHOICE, "Amiga filesystem",
      "The filename limits to keep to. With PFS, run\nsetfnsize <drive:> 107 on the Amiga first. (FILESYSTEM)",
      "pfs", vFs, lFs, 0, 0, 0, NULL, NULL, 0 },
    { "AMIGA_NAMES", PG_COLL, K_BOOL, "Make names Amiga-safe",
      "At the end of a run: accented letters lose their accents,\n# ? and \\ become _. - and + are kept. (AMIGA_NAMES)",
      "yes", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "USE_DETOX", PG_COLL, K_BOOL, "Clean names with detox",
      "Run detox over the names before sorting. (USE_DETOX)",
      "no", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "KEEP_NEW_BATCHES", PG_COLL, K_NUM, "New-game folders kept",
      "How many dated folders of new games to keep in\nbuild/new_<variant>/. (KEEP_NEW_BATCHES)",
      "14", NULL, NULL, 1, 60, 1, "%ld", NULL, 0 },
    { "OUTPUT_ROOT", PG_COLL, K_TEXT, "Build on (Pi folder)",
      "Where build/ goes on the Pi - \".\" is the whdsync folder,\nor e.g. /mnt/ssd/retroplay for a USB drive. (OUTPUT_ROOT)",
      ".", NULL, NULL, 0, 0, 0, NULL, NULL, SF_EMPTYDEF },
    { "MIRROR_DIRS", PG_COLL, K_LIST, "Download from the server",
      "Which Retroplay folders are mirrored. (MIRROR_DIRS)",
      "HD_Loaders/Games, JST/Games, WHDLoad/Magazines, WHDLoad/Demos, WHDLoad/Games",
      vMirror, lMirror, 0, 0, 0, NULL, ", ", 0 },
    { "ARTWORK_PACKS", PG_NONE, K_DERIVED, NULL, NULL,
      "AGA ECS RTG AGA_Laced ECS_Laced", NULL, NULL, 0, 0, 0, NULL, " ", 0 },
    /* -------- Artwork -------- */
    { "ARTWORK_SYNC", PG_ART, K_CHOICE, "Update artwork packs",
      "When a run fetches newer artwork packs. Missing packs\nare always fetched. (ARTWORK_SYNC)",
      "auto", vArtSync, lArtSync, 0, 0, 0, NULL, NULL, 0 },
    { "ARTWORK_CHECK_INTERVAL_HOURS", PG_ART, K_NUM, "Check for new packs every",
      "(ARTWORK_CHECK_INTERVAL_HOURS)",
      "24", NULL, NULL, 1, 168, 1, "%ld hours", NULL, 0 },
    { "ART_ORDER", PG_ART, K_CHOICE, "Artwork order: games",
      "Which picture iGame shows first. (ART_ORDER)",
      "Screens,Covers,Titles", vOrder, lOrder, 0, 0, 0, NULL, NULL, 0 },
    { "ART_ORDER_RTG", PG_ART, K_CHOICE, "Artwork order: RTG",
      "The order for the RTG collection. (ART_ORDER_RTG)",
      "Covers,Screens,Titles", vOrder, lOrder, 0, 0, 0, NULL, NULL, 0 },
    { "DEMO_ART_ORDER", PG_ART, K_CHOICE, "Artwork order: demos",
      "(DEMO_ART_ORDER)",
      "Titles,Screens,Covers", vOrder, lOrder, 0, 0, 0, NULL, NULL, 0 },
    { "ARTWORK_LOCAL_CHANGE_POLICY", PG_ART, K_CHOICE, "A pack I changed myself",
      "What an artwork update does with a pack of your own.\n(ARTWORK_LOCAL_CHANGE_POLICY)",
      "ask", vLocal, lLocal, 0, 0, 0, NULL, NULL, 0 },
    { "ARTWORK_FAILURE_POLICY", PG_ART, K_CHOICE, "If artwork can't be updated",
      "(ARTWORK_FAILURE_POLICY)",
      "warn-and-continue", vFail, lFail, 0, 0, 0, NULL, NULL, 0 },
    { "ARTWORK_KEEP_BACKUPS", PG_ART, K_NUM, "Previous packs kept",
      "For --artwork-rollback. (ARTWORK_KEEP_BACKUPS)",
      "2", NULL, NULL, 0, 10, 1, "%ld", NULL, 0 },
    { "GAPFILL_DAYS", PG_ART, K_NUM, "Fill artwork gaps at least every",
      "(GAPFILL_DAYS)",
      "7", NULL, NULL, 1, 60, 1, "%ld days", NULL, 0 },
    { "ARTWORK_FETCH", PG_ART, K_BOOL, "Search for missing artwork",
      "Ask the command below for pictures no pack has. (ARTWORK_FETCH)",
      "no", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "ARTWORK_FETCH_COMMAND", PG_ART, K_TEXT, "Search command (Pi)",
      "Called as: <command> \"<game>\" \"<output image>\". (ARTWORK_FETCH_COMMAND)",
      "", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "ARTWORK_FETCH_LIMIT", PG_ART, K_NUM, "Searches per run",
      "(ARTWORK_FETCH_LIMIT)",
      "25", NULL, NULL, 1, 200, 1, "%ld", NULL, 0 },
    /* -------- Downloads -------- */
    { "DOWNLOAD_TIMEOUT", PG_DL, K_NUM, "Give up a stalled download after",
      "Seconds with nothing arriving. A download that keeps\nmoving is never cut short. (DOWNLOAD_TIMEOUT)",
      "60", NULL, NULL, 10, 600, 1, "%ld s", NULL, 0 },
    { "ARTWORK_TIMEOUT", PG_DL, K_NUM, "Time allowed per artwork pack",
      "0 = no limit. (ARTWORK_TIMEOUT)",
      "3600", NULL, NULL, 0, 240, 60, "%ld min", NULL, 0 },
    { "DOWNLOAD_RETRIES", PG_DL, K_NUM, "Download attempts",
      "(DOWNLOAD_RETRIES)",
      "3", NULL, NULL, 1, 10, 1, "%ld", NULL, 0 },
    { "VERIFY_DOWNLOADS", PG_DL, K_CHOICE, "Test new downloads",
      "A damaged download is fetched again in the same run. (VERIFY_DOWNLOADS)",
      "auto", vVerify, lVerify, 0, 0, 0, NULL, NULL, 0 },
    { "MAX_EXTRACT_ATTEMPTS", PG_DL, K_NUM, "Tries before an archive is set aside",
      "(MAX_EXTRACT_ATTEMPTS)",
      "3", NULL, NULL, 1, 10, 1, "%ld", NULL, 0 },
    { "OLD_ARCHIVE_DAYS", PG_DL, K_NUM, "Keep replaced archives for",
      "(OLD_ARCHIVE_DAYS)",
      "30", NULL, NULL, 1, 365, 1, "%ld days", NULL, 0 },
    { "MIN_FREE_MB", PG_DL, K_NUM, "Always leave free on the Pi",
      "(MIN_FREE_MB)",
      "1024", NULL, NULL, 0, 100, 1024, "%ld GB", NULL, 0 },
    { "SPACE_FACTOR", PG_DL, K_NUM, "Room to allow per archive",
      "Extracted size as a multiple of the archive. (SPACE_FACTOR)",
      "3", NULL, NULL, 1, 10, 1, "%ld x", NULL, 0 },
    /* -------- System -------- */
    { "JOBS", PG_SYS, K_NUM, "Jobs at once (0 = automatic)",
      "How many things the Pi does at once. (JOBS)",
      "auto", NULL, NULL, 0, 16, 1, "%ld", NULL, SF_AUTOZERO },
    { "NICE", PG_SYS, K_CHOICE, "Run gently",
      "Lower priority, so the Pi stays usable. (NICE)",
      "auto", vNice, lNice, 0, 0, 0, NULL, NULL, 0 },
    { "RUN_LOG", PG_SYS, K_BOOL, "Keep logs/last_run.log",
      "A copy of a run started at a terminal. (RUN_LOG)",
      "yes", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "STATE_BACKUP", PG_SYS, K_BOOL, "Back up the queue each run",
      "(STATE_BACKUP)",
      "no", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "UPDATE_CHECK", PG_SYS, K_BOOL, "Say when a new release is out",
      "Reads one version number from GitHub. Never downloads. (UPDATE_CHECK)",
      "yes", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "NTFY_TOPIC", PG_SYS, K_TEXT, "ntfy topic",
      "Notifications through ntfy.sh when a run fails. (NTFY_TOPIC)",
      "", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "NOTIFY_EMAIL", PG_SYS, K_TEXT, "E-mail address",
      "Needs a working 'mail' command on the Pi. (NOTIFY_EMAIL)",
      "", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { "NOTIFY_ON_SUCCESS", PG_SYS, K_BOOL, "Also notify when a run works",
      "(NOTIFY_ON_SUCCESS)",
      "no", NULL, NULL, 0, 0, 0, NULL, NULL, 0 },
    { NULL, 0, 0, NULL, NULL, NULL, NULL, NULL, 0, 0, 0, NULL, NULL, 0 }
};

/* ================================================================== */
/* The window's own choices                                            */
/* ================================================================== */
static const char *const modeEntries[]   = { "Simple", "Advanced", NULL };
static const char *const simpleEntries[] = { "All", "RTG", "AGA", "ECS", NULL };
static const char *const simpleScripts[] = { "all.sh", "rtg.sh", "aga.sh", "ecs.sh" };
static const char *const simpleSuffix[]  = { NULL, "rtg", "aga", "ecs" };
static const char *const registerTitles[] = { "Task", "Collections", "Artwork", "Downloads",
                                              "System", "A314", NULL };

enum { T_SYNC, T_PLAN, T_PREVIEW, T_REBUILD, T_UPDATE, T_EXTRACT, T_MERGE, T_SORT };
static const char *const taskEntries[] = {
    "Update and build", "Show what a run would do", "Build just the new games",
    "Rebuild from the downloads", "Download only", "Extract only",
    "Artwork only", "Sort and check names only", NULL };

#define TB(t) (1L << (t))
#define M_BUILDS (TB(T_SYNC) | TB(T_PLAN) | TB(T_PREVIEW) | TB(T_REBUILD))
#define M_ALL    0xFFL

static const char *const variantEntries[] = { "As in settings", "AGA", "ECS", "RTG",
                                              "AGA laced", "ECS laced", "Other artwork set", NULL };
static const char *const variantSuffix[]  = { NULL, "aga", "ecs", "rtg", "aga_laced", "ecs_laced", NULL };
static const char *const fsEntries[]    = { "As in settings", "PFS", "FFS", NULL };
static const char *const detoxEntries[] = { "As in settings", "Use detox", "Don't use detox", NULL };
static const char *const orderEntries[] = { "As in settings", "Screens, Covers, Titles",
                                            "Screens, Titles, Covers", "Covers, Screens, Titles",
                                            "Covers, Titles, Screens", "Titles, Screens, Covers",
                                            "Titles, Covers, Screens", NULL };
static const char *const copyVariantEntries[] = { "AGA", "ECS", "RTG", "AGA laced", "ECS laced", NULL };
static const char *const copyVariantSuffix[]  = { "aga", "ecs", "rtg", "aga_laced", "ecs_laced" };
static const char *const copyModeEntries[] = { "Only the latest new games",
                                               "Everything new or changed", NULL };

/* One-off options on the Task page: which tasks each applies to. */
enum { O_SKIPUPDATE, O_CLEAN, O_FORCE, O_REFRESH, O_ONLYMISSING, O_NONAMES,
       O_SKIPCHK, O_SKIPVSORT, O_DEBUG, O_COUNT };
static const char *const optLabels[O_COUNT] = {
    "Don't download", "Rebuild from scratch", "Fill artwork gaps",
    "Rewrite all artwork", "Only games with no artwork", "Skip Amiga-safe names",
    "Skip the filename check", "Skip the variant sort", "Debug output" };
static const char *const optHelp[O_COUNT] = {
    "Process what is already downloaded. (--skip-update)",
    "Check for updates, then build again from nothing. (--clean)",
    "Also fill artwork gaps when nothing else is new. (--force)",
    "Write artwork for every game, not only the gaps. (--refresh-artwork)",
    "Leave existing artwork alone. (--only-missing)",
    "Skip the names clean-up at the end, this run only. (--no-amiga-names)",
    "Skip the Amiga filename check. (--skipchk)",
    "Don't move games into CD32/AGA/NTSC/language folders. (--skip-variant-sort)",
    "Print everything, including each stage's own detail. (--debug)" };
static const long optMask[O_COUNT] = {
    TB(T_SYNC) | TB(T_PLAN) | TB(T_PREVIEW),
    TB(T_SYNC),
    M_BUILDS,
    TB(T_SYNC) | TB(T_PREVIEW) | TB(T_REBUILD) | TB(T_MERGE),
    TB(T_MERGE),
    M_BUILDS,
    TB(T_SORT),
    TB(T_SORT),
    M_ALL };
#define MASK_VARIANT  (M_BUILDS | TB(T_MERGE))
#define MASK_FS       (M_BUILDS | TB(T_SORT))
#define MASK_DETOX    (TB(T_SYNC) | TB(T_PREVIEW) | TB(T_REBUILD) | TB(T_SORT))
#define MASK_ART      (M_BUILDS | TB(T_MERGE))
#define MASK_JOBS     (M_ALL & ~TB(T_UPDATE))
#define MASK_DEST     (M_BUILDS | TB(T_EXTRACT) | TB(T_MERGE) | TB(T_SORT))
#define MASK_COPY     (TB(T_SYNC) | TB(T_PREVIEW) | TB(T_REBUILD))

/* ================================================================== */
/* Objects                                                             */
/* ================================================================== */
static Object *app, *win;
static Object *rdMode, *grpPages;
static Object *rdSimple, *txSimpleCmd;
static Object *rdTask, *cyVariant, *strSet, *cyFs, *cyDetox, *cyArt, *cyDemoArt;
static Object *slJobs, *strDest, *txTaskCmd, *chkOpt[O_COUNT];
static Object *strPiCmd, *strPiScripts, *strBase, *strBuild, *cyCopyVariant, *cyCopyMode;
static Object *txConf;
static Object *chkCopyAfter, *strCopyDest;
static Object *lsLog, *lvLog, *txStatus;
static Object *btStart, *btStatus, *btDoctor, *btCopy, *btStop, *btSave;

/* Remembered between sessions in PREFS_FILE */
static char prefPiCmd[64]          = "pi";
static char prefPiScripts[PATH_SIZE] = "/home/pi/whdsync";
static char prefBase[PATH_SIZE]    = "PROGDIR:";
static char prefBuild[PATH_SIZE]   = "";
static char prefCopyDest[PATH_SIZE] = "";
static long prefMode = 0, prefSimple = 0, prefCopyAfter = 0, prefCopyMode = 0, prefCopyVariant = 0;
static BOOL prefsFound = FALSE, oldPrefsMigrated = FALSE;
static BOOL confFound = FALSE;

/* ================================================================== */
/* Small MUI helpers                                                   */
/* ================================================================== */
static ULONG xget(Object *obj, ULONG attr)
{
    ULONG v = 0;
    if (obj) GetAttr(attr, obj, &v);
    return v;
}

static void xset(Object *obj, ULONG attr, ULONG value)
{
    if (obj) SetAttrs(obj, attr, value, TAG_DONE);
}

static const char *xstr(Object *obj)
{
    const char *s = (const char *)xget(obj, MUIA_String_Contents);
    return s ? s : "";
}

static Object *MakeCheck(BOOL selected, const char *help)
{
    return ImageObject,
        ImageButtonFrame,
        MUIA_InputMode, MUIV_InputMode_Toggle,
        MUIA_Image_Spec, MUII_CheckMark,
        MUIA_Image_FreeVert, TRUE,
        MUIA_Selected, selected,
        MUIA_Background, MUII_ButtonBack,
        MUIA_ShowSelState, FALSE,
        MUIA_CycleChain, 1,
        MUIA_ShortHelp, (ULONG)help,
    End;
}

static Object *MakeCycle(const char *const *entries, long active, const char *help)
{
    return CycleObject,
        MUIA_Cycle_Entries, (ULONG)entries,
        MUIA_Cycle_Active, active,
        MUIA_CycleChain, 1,
        MUIA_ShortHelp, (ULONG)help,
    End;
}

static Object *MakeSlider(long min, long max, long value, const char *fmt, const char *help)
{
    return SliderObject,
        MUIA_Numeric_Min, min,
        MUIA_Numeric_Max, max,
        MUIA_Numeric_Value, value,
        MUIA_Numeric_Format, (ULONG)fmt,
        MUIA_CycleChain, 1,
        MUIA_ShortHelp, (ULONG)help,
    End;
}

static Object *MakeString(const char *contents, int maxLen, const char *help)
{
    return StringObject,
        StringFrame,
        MUIA_String_MaxLen, maxLen,
        MUIA_String_Contents, (ULONG)contents,
        MUIA_CycleChain, 1,
        MUIA_ShortHelp, (ULONG)help,
    End;
}

/* A string with a drawer requester button. *strOut gets the string. */
static Object *MakePopDrawer(Object **strOut, const char *contents, const char *title,
                             const char *help)
{
    Object *str = MakeString(contents, PATH_SIZE, help);
    if (!str) return NULL;
    *strOut = str;
    return PopaslObject,
        MUIA_Popstring_String, (ULONG)str,
        MUIA_Popstring_Button, (ULONG)PopButton(MUII_PopDrawer),
        MUIA_Popasl_Type, ASL_FileRequest,
        ASLFR_TitleText, (ULONG)title,
        ASLFR_DrawersOnly, TRUE,       /* asl V38+; ignored on 2.04 */
        MUIA_ShortHelp, (ULONG)help,
    End;
}

/* A checkmark followed by its text, as a pair of cells. */
static BOOL AddCheckPair(Object *grp, Object *chk, const char *label)
{
    Object *lab;
    if (!chk) return FALSE;
    lab = LLabel1((char *)label);
    if (!lab) { MUI_DisposeObject(chk); return FALSE; }
    DoMethod(grp, OM_ADDMEMBER, (ULONG)chk);
    DoMethod(grp, OM_ADDMEMBER, (ULONG)lab);
    return TRUE;
}

/* A label and a widget, as a pair of cells. The widget is kept left
   aligned and at its own size (a checkmark would otherwise be centred). */
static BOOL AddLabelled(Object *grp, const char *label, Object *widget, BOOL keepNarrow, BOOL dbl)
{
    Object *lab, *cell;
    if (!widget) return FALSE;
    lab = dbl ? Label2((char *)label) : Label1((char *)label);
    if (keepNarrow) {
        cell = HGroup, Child, widget, Child, HSpace(0), End;
    } else {
        cell = widget;
    }
    if (!lab || !cell) return FALSE;
    DoMethod(grp, OM_ADDMEMBER, (ULONG)lab);
    DoMethod(grp, OM_ADDMEMBER, (ULONG)cell);
    return TRUE;
}

/* Wraps a page in a vertical scroller, so the window still opens on a
   640x200 screen with a big font: the page scrolls instead. */
static Object *Scrolled(Object *contents)
{
    if (!contents) return NULL;
    return ScrollgroupObject,
        MUIA_Scrollgroup_FreeHoriz, FALSE,
        MUIA_Scrollgroup_Contents, (ULONG)(VirtgroupObject,
            VirtualFrame,
            Child, (ULONG)contents,
            Child, (ULONG)VSpace(0),
        End),
    End;
}

/* The text goes in as an argument to "%s", never as the format itself:
   a % in a message (or in a path) would otherwise read an argument that
   isn't there. */
static long Request(const char *gadgets, const char *text)
{
    ULONG args[1];
    args[0] = (ULONG)text;
    return MUI_RequestA(app, win, 0, (char *)"A314 Retroplay", (char *)gadgets,
                        (char *)"%s", args);
}

/* ================================================================== */
/* The log                                                             */
/* ================================================================== */
static void AddLog(const char *line)
{
    long n;
    DoMethod(lsLog, MUIM_List_InsertSingle, (ULONG)line, MUIV_List_Insert_Bottom);
    n = (long)xget(lsLog, MUIA_List_Entries);
    while (n > MAX_LOG) {
        DoMethod(lsLog, MUIM_List_Remove, MUIV_List_Remove_First);
        n--;
    }
    if (n > 0) DoMethod(lsLog, MUIM_List_Jump, n - 1);
}

static void AddLog2(const char *a, const char *b)
{
    char line[LINE_SIZE];
    CopyStr(line, a, sizeof line);
    AppendStr(line, b, sizeof line);
    AddLog(line);
}

static void SetStatus(const char *text)
{
    xset(txStatus, MUIA_Text_Contents, (ULONG)text);
}

/* ================================================================== */
/* Reading retroplay.conf (the same rules lib.sh uses)                 */
/* ================================================================== */
static struct Setting *FindSetting(const char *key, int keyLen)
{
    struct Setting *s;
    for (s = settings; s->key; s++) {
        if ((int)strlen(s->key) == keyLen && strncmp(s->key, key, keyLen) == 0) return s;
    }
    return NULL;
}

/* For a settings line, where its key starts and how long it is.
   Comments, blank lines and anything not KEY=... give 0. */
static int LineKey(const char *line, const char **keyOut)
{
    const char *p = line, *k;
    while (*p == ' ' || *p == '\t') p++;
    k = p;
    while ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
           (*p >= '0' && *p <= '9') || *p == '_') p++;
    if (p == k || *p != '=') return 0;
    *keyOut = k;
    return (int)(p - k);
}

/* The value of a KEY=value line: a quoted value runs to its closing
   quote; an unquoted one stops at a # that follows a space or tab. */
static void LineValue(const char *line, int keyLen, const char *key, char *out, int outSize)
{
    const char *v = key + keyLen + 1;
    int n = 0;
    if (*v == '"' || *v == '\'') {
        char q = *v++;
        while (v[n] && v[n] != q) n++;
    } else {
        while (v[n] && v[n] != '\n' && v[n] != '\r') {
            if (v[n] == '#' && n > 0 && (v[n - 1] == ' ' || v[n - 1] == '\t')) break;
            n++;
        }
        while (n > 0 && (v[n - 1] == ' ' || v[n - 1] == '\t')) n--;
    }
    if (n >= outSize) n = outSize - 1;
    memcpy(out, v, n);
    out[n] = 0;
    (void)line;
}

static void LoadConf(void)
{
    struct Setting *s;
    BPTR fh;
    char line[LINE_SIZE];
    const char *key;
    int keyLen;
    BOOL atStart = TRUE;

    for (s = settings; s->key; s++) CopyStr(s->raw, s->def, RAW_SIZE);
    fh = Open((STRPTR)CONF_FILE, MODE_OLDFILE);
    confFound = fh ? TRUE : FALSE;
    if (!fh) return;
    /* FGets hands over a line longer than the buffer in pieces; only the
       first piece of a line can start a setting. */
    while (FGets(fh, (STRPTR)line, sizeof line - 1)) {
        int len = (int)strlen(line);
        BOOL hadNl = (len > 0 && line[len - 1] == '\n') ? TRUE : FALSE;
        if (atStart && (keyLen = LineKey(line, &key)) > 0) {
            s = FindSetting(key, keyLen);
            if (s) LineValue(line, keyLen, key, s->raw, RAW_SIZE);
        }
        atStart = hadNl;
    }
    Close(fh);
}

/* ---------------------------------------------------------------- */
/* A setting <-> its widget                                          */
/* ---------------------------------------------------------------- */
static BOOL IsYes(const char *v)
{
    return (!strcmp(v, "yes") || !strcmp(v, "y") || !strcmp(v, "1") || !strcmp(v, "true")
            || !strcmp(v, "on") || !strcmp(v, "YES") || !strcmp(v, "Yes")) ? TRUE : FALSE;
}

/* Is the token tok one of the entries in raw? (", " or " " separated) */
static BOOL ListHas(const char *raw, const char *tok, const char *sep)
{
    char buf[RAW_SIZE];
    char *p, *e;
    BOOL comma = strchr(sep, ',') ? TRUE : FALSE;
    CopyStr(buf, raw, sizeof buf);
    p = buf;
    while (*p) {
        while (*p == ' ' || *p == ',' || (!comma && *p == '\t')) p++;
        if (!*p) break;
        e = p;
        while (*e && (comma ? *e != ',' : (*e != ' ' && *e != '\t'))) e++;
        {
            char *t = e;
            char c = *e;
            while (t > p && (t[-1] == ' ' || t[-1] == '/')) t--;
            *t = 0;
            if (!strcmp(p, tok)) return TRUE;
            *e = c;
        }
        p = e;
    }
    return FALSE;
}

static BOOL IsKnownToken(const struct Setting *s, const char *tok)
{
    int i;
    for (i = 0; s->values[i]; i++) if (!strcmp(s->values[i], tok)) return TRUE;
    return FALSE;
}

/* Works out the widget state the current raw value stands for. */
static void SettingBaseline(struct Setting *s)
{
    int i;
    long v;
    switch (s->kind) {
    case K_BOOL:
        s->init = IsYes(s->raw);
        break;
    case K_CHOICE:
        s->init = s->nvalues;            /* "keep as it is", unless it matches */
        for (i = 0; i < s->nvalues; i++) if (!strcmp(s->values[i], s->raw)) s->init = i;
        break;
    case K_NUM:
        if ((s->flags & SF_AUTOZERO) && !strcmp(s->raw, "auto")) v = 0;
        else if (ParseLong(s->raw, &v)) v = (v + s->scale / 2) / s->scale;
        else v = s->min;
        if (v < s->min) v = s->min;
        if (v > s->max) v = s->max;
        s->init = v;
        break;
    case K_LIST:
        s->init = 0;
        for (i = 0; s->values[i] && i < MAX_LIST; i++)
            if (ListHas(s->raw, s->values[i], s->sep)) s->init |= 1L << i;
        break;
    default:
        s->init = 0;
    }
}

/* The widget's state now, in the same terms as s->init. */
static long SettingState(struct Setting *s)
{
    long v = 0;
    int i;
    switch (s->kind) {
    case K_BOOL:   return xget(s->obj, MUIA_Selected) ? 1 : 0;
    case K_CHOICE: return (long)xget(s->obj, MUIA_Cycle_Active);
    case K_NUM:    return (long)xget(s->obj, MUIA_Numeric_Value);
    case K_LIST:
        for (i = 0; s->values[i] && i < MAX_LIST; i++)
            if (xget(s->box[i], MUIA_Selected)) v |= 1L << i;
        return v;
    }
    return 0;
}

static BOOL SettingChanged(struct Setting *s)
{
    if (!s->obj && s->kind != K_LIST) return FALSE;
    if (s->kind == K_TEXT) return strcmp(xstr(s->obj), s->raw) ? TRUE : FALSE;
    return SettingState(s) != s->init ? TRUE : FALSE;
}

/* The value to write for the widget's state. FALSE if it can't be written. */
static BOOL SettingNewRaw(struct Setting *s, char *out, int outSize)
{
    long st;
    int i;
    char tok[RAW_SIZE], buf[RAW_SIZE];
    out[0] = 0;
    switch (s->kind) {
    case K_BOOL:
        return CopyStr(out, SettingState(s) ? "yes" : "no", outSize);
    case K_CHOICE:
        st = SettingState(s);
        if (st < 0 || st >= s->nvalues) return CopyStr(out, s->raw, outSize);
        return CopyStr(out, s->values[st], outSize);
    case K_NUM:
        st = SettingState(s);
        if ((s->flags & SF_AUTOZERO) && st == 0) return CopyStr(out, "auto", outSize);
        return AppendNum(out, st * s->scale, outSize);
    case K_TEXT:
        if ((s->flags & SF_EMPTYDEF) && !xstr(s->obj)[0]) return CopyStr(out, s->def, outSize);
        return CopyStr(out, xstr(s->obj), outSize);
    case K_LIST:
        st = SettingState(s);
        for (i = 0; s->values[i] && i < MAX_LIST; i++) {
            if (!(st & (1L << i))) continue;
            if (out[0] && !AppendStr(out, s->sep, outSize)) return FALSE;
            if (!AppendStr(out, s->values[i], outSize)) return FALSE;
        }
        /* Entries this window doesn't offer are kept, after the others. */
        {
            BOOL comma = strchr(s->sep, ',') ? TRUE : FALSE;
            char *p, *e;
            CopyStr(buf, s->raw, sizeof buf);
            p = buf;
            while (*p) {
                while (*p == ' ' || *p == ',') p++;
                if (!*p) break;
                e = p;
                while (*e && (comma ? *e != ',' : *e != ' ')) e++;
                i = (int)(e - p);
                if (i >= (int)sizeof tok) i = sizeof tok - 1;
                memcpy(tok, p, i);
                tok[i] = 0;
                while (i > 0 && (tok[i - 1] == ' ' || tok[i - 1] == '/')) tok[--i] = 0;
                if (tok[0] && !IsKnownToken(s, tok)) {
                    if (out[0] && !AppendStr(out, s->sep, outSize)) return FALSE;
                    if (!AppendStr(out, tok, outSize)) return FALSE;
                }
                p = e;
            }
        }
        return TRUE;
    }
    return CopyStr(out, s->raw, outSize);
}

/* ARTWORK_PACKS follows VARIANTS, as setup.sh does: a laced collection
   built without its own pack is no different from the plain one. Packs
   that aren't one of the five are kept. */
static void DerivePacks(struct Setting *variants, struct Setting *packs, char *out, int outSize)
{
    static const char *const vv[] = { "aga", "ecs", "rtg", "aga-laced", "ecs-laced" };
    static const char *const pp[] = { "AGA", "ECS", "RTG", "AGA_Laced", "ECS_Laced" };
    char buf[RAW_SIZE], tok[64];
    char *p, *e;
    int i, n;
    out[0] = 0;
    for (i = 0; i < 5; i++) {
        if (!ListHas(variants->newRaw, vv[i], " ")) continue;
        if (out[0]) AppendStr(out, " ", outSize);
        AppendStr(out, pp[i], outSize);
    }
    CopyStr(buf, packs->raw, sizeof buf);
    p = buf;
    while (*p) {
        while (*p == ' ') p++;
        if (!*p) break;
        e = p;
        while (*e && *e != ' ') e++;
        n = (int)(e - p);
        if (n >= (int)sizeof tok) n = sizeof tok - 1;
        memcpy(tok, p, n);
        tok[n] = 0;
        for (i = 0; i < 5; i++) if (!strcmp(tok, pp[i])) break;
        if (i == 5) {
            if (out[0]) AppendStr(out, " ", outSize);
            AppendStr(out, tok, outSize);
        }
        p = e;
    }
}

static BOOL AnySettingChanged(void)
{
    struct Setting *s;
    for (s = settings; s->key; s++) if (s->page != PG_NONE && SettingChanged(s)) return TRUE;
    return FALSE;
}

/* ---------------------------------------------------------------- */
/* Writing retroplay.conf                                            */
/* ---------------------------------------------------------------- */
static BOOL IsNumberText(const char *v)
{
    long dummy;
    return ParseLong(v, &dummy);
}

static void ConfLine(const struct Setting *s, char *out, int outSize)
{
    CopyStr(out, s->key, outSize);
    AppendStr(out, "=", outSize);
    if (s->kind == K_NUM && IsNumberText(s->newRaw)) {
        AppendStr(out, s->newRaw, outSize);
    } else {
        AppendStr(out, "\"", outSize);
        AppendStr(out, s->newRaw, outSize);
        AppendStr(out, "\"", outSize);
    }
    AppendStr(out, "\n", outSize);
}

/* Saves the changed settings into PROGDIR:retroplay.conf. Every other
   line - comments, settings this window doesn't show, your own notes - is
   kept exactly as it was; a changed setting's line is replaced where it
   stands, and one the file doesn't have yet is added at the end. The
   previous file is kept as retroplay.conf.bak. */
static BOOL SaveConf(void)
{
    struct Setting *s, *variants = NULL, *packs = NULL;
    BPTR in, out;
    char line[LINE_SIZE], newLine[LINE_SIZE + 32], msg[LINE_SIZE];
    const char *key;
    int keyLen, changed = 0, len;
    BOOL ok = TRUE, atStart = TRUE, lastHadNl = TRUE, skipRest = FALSE, header = FALSE;
    BOOL hadNl, replaced;

    for (s = settings; s->key; s++) {
        s->dirty = s->written = FALSE;
        s->newRaw[0] = 0;
        if (!strcmp(s->key, "VARIANTS")) variants = s;
        if (!strcmp(s->key, "ARTWORK_PACKS")) packs = s;
        if (s->page == PG_NONE || !SettingChanged(s)) continue;
        if (!SettingNewRaw(s, s->newRaw, RAW_SIZE)) {
            AddLog2("Not saved - this value is too long: ", s->key);
            return FALSE;
        }
        if (s->kind == K_TEXT && !IsSafeFieldText(s->newRaw)) {
            CopyStr(msg, "This setting holds a character that can't go into\n"
                         "retroplay.conf:\n\n   ", sizeof msg);
            AppendStr(msg, s->label, sizeof msg);
            AppendStr(msg, "\n\nUse letters, digits, spaces and / . _ - + , : = @ % ~", sizeof msg);
            Request("_OK", msg);
            return FALSE;
        }
        if (s->kind == K_LIST && !s->newRaw[0]) {
            CopyStr(msg, "Tick at least one entry for:\n\n   ", sizeof msg);
            AppendStr(msg, s->label, sizeof msg);
            Request("_OK", msg);
            return FALSE;
        }
        s->dirty = TRUE;
        changed++;
    }
    if (variants && packs && variants->dirty) {
        DerivePacks(variants, packs, packs->newRaw, RAW_SIZE);
        if (strcmp(packs->newRaw, packs->raw)) packs->dirty = TRUE;
    }
    if (changed == 0) {
        AddLog("Settings: nothing has changed, so retroplay.conf was left as it is.");
        return TRUE;
    }

    out = Open((STRPTR)CONF_NEW, MODE_NEWFILE);
    if (!out) {
        Request("_OK", "Could not write retroplay.conf in the folder this\n"
                       "program was started from. Is it write-protected?");
        return FALSE;
    }
    in = Open((STRPTR)CONF_FILE, MODE_OLDFILE);
    if (in) {
        /* Every line is copied as it is, except the line of a changed
           setting, which is replaced where it stands. FGets hands over a
           line longer than the buffer in pieces: only a first piece can
           start a setting, and the rest of a replaced line is dropped. */
        while (FGets(in, (STRPTR)line, sizeof line - 1)) {
            len = (int)strlen(line);
            hadNl = (len > 0 && line[len - 1] == '\n') ? TRUE : FALSE;
            if (skipRest) {
                if (hadNl) skipRest = FALSE;
                atStart = hadNl;
                continue;
            }
            replaced = FALSE;
            if (atStart && (keyLen = LineKey(line, &key)) > 0) {
                for (s = settings; s->key; s++) {
                    if (!s->dirty) continue;
                    if ((int)strlen(s->key) != keyLen || strncmp(s->key, key, keyLen)) continue;
                    /* Every copy of the key is replaced: lib.sh would use
                       the last one, so they must all agree. */
                    ConfLine(s, newLine, sizeof newLine);
                    if (FPuts(out, (STRPTR)newLine)) ok = FALSE;
                    s->written = TRUE;
                    replaced = TRUE;
                    break;
                }
            }
            if (replaced) {
                if (!hadNl) skipRest = TRUE;
                lastHadNl = TRUE;
            } else {
                if (FPuts(out, (STRPTR)line)) ok = FALSE;
                lastHadNl = hadNl;
            }
            atStart = hadNl;
        }
        Close(in);
        if (!lastHadNl && FPuts(out, (STRPTR)"\n")) ok = FALSE;
    }
    /* Settings the file didn't have yet go at the end. */
    for (s = settings; s->key; s++) {
        if (!s->dirty || s->written) continue;
        if (!header) {
            if (FPuts(out, (STRPTR)"\n# Set with A314RetroplayGUI\n")) ok = FALSE;
            header = TRUE;
        }
        ConfLine(s, newLine, sizeof newLine);
        if (FPuts(out, (STRPTR)newLine)) ok = FALSE;
    }
    if (!Close(out)) ok = FALSE;
    if (!ok) {
        DeleteFile((STRPTR)CONF_NEW);
        Request("_OK", "Writing retroplay.conf failed part-way (is the disk full?).\n"
                       "The settings file was left as it was.");
        return FALSE;
    }
    /* Swap the new file in, keeping the old one as .bak. */
    DeleteFile((STRPTR)CONF_BAK);
    if (in) Rename((STRPTR)CONF_FILE, (STRPTR)CONF_BAK);
    if (!Rename((STRPTR)CONF_NEW, (STRPTR)CONF_FILE)) {
        if (in) Rename((STRPTR)CONF_BAK, (STRPTR)CONF_FILE);
        DeleteFile((STRPTR)CONF_NEW);
        Request("_OK", "Could not put the new retroplay.conf in place.\n"
                       "The old one is unchanged.");
        return FALSE;
    }
    /* What is on disk now is the new starting point. */
    for (s = settings; s->key; s++) {
        if (!s->dirty) continue;
        CopyStr(s->raw, s->newRaw, RAW_SIZE);
        /* A field left empty for its default now shows the default. */
        if (s->kind == K_TEXT && s->obj) xset(s->obj, MUIA_String_Contents, (ULONG)s->raw);
        if (s->page != PG_NONE) s->init = SettingState(s);
    }
    confFound = TRUE;
    CopyStr(msg, "Settings: saved ", sizeof msg);
    AppendNum(msg, changed, sizeof msg);
    AppendStr(msg, changed == 1 ? " change" : " changes", sizeof msg);
    if (packs && packs->dirty) AppendStr(msg, " (and ARTWORK_PACKS, to match)", sizeof msg);
    AppendStr(msg, " to retroplay.conf.", sizeof msg);
    AddLog(msg);
    AddLog(in ? "The previous file is kept as retroplay.conf.bak."
              : "It is a new file, holding only what you changed.");
    xset(txConf, MUIA_Text_Contents, (ULONG)"Settings file: PROGDIR:retroplay.conf");
    return TRUE;
}

/* ================================================================== */
/* The window's own preferences                                        */
/* ================================================================== */
static void LoadPrefs(void)
{
    BPTR fh;
    char line[LINE_SIZE], *eq;
    int n = 0;
    long v;
    fh = Open((STRPTR)PREFS_FILE, MODE_OLDFILE);
    if (!fh) return;
    prefsFound = TRUE;
    while (FGets(fh, (STRPTR)line, sizeof line - 1)) {
        int len = (int)strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
        n++;
        eq = strchr(line, '=');
        if (!eq) {
            /* The previous version wrote two bare lines: the archive drawer,
               then the WHDLoad drawer. The second is where games go. */
            if (n == 2 && line[0]) { CopyStr(prefCopyDest, line, PATH_SIZE); oldPrefsMigrated = TRUE; }
            continue;
        }
        *eq++ = 0;
        if (!strcmp(line, "PI_COMMAND")) CopyStr(prefPiCmd, eq, sizeof prefPiCmd);
        else if (!strcmp(line, "PI_SCRIPTS")) CopyStr(prefPiScripts, eq, PATH_SIZE);
        else if (!strcmp(line, "AMIGA_BASE")) CopyStr(prefBase, eq, PATH_SIZE);
        else if (!strcmp(line, "AMIGA_BUILD")) CopyStr(prefBuild, eq, PATH_SIZE);
        else if (!strcmp(line, "COPY_DEST")) CopyStr(prefCopyDest, eq, PATH_SIZE);
        else if (ParseLong(eq, &v)) {
            if (!strcmp(line, "MODE")) prefMode = v ? 1 : 0;
            else if (!strcmp(line, "SIMPLE")) prefSimple = (v >= 0 && v <= 3) ? v : 0;
            else if (!strcmp(line, "COPY_AFTER")) prefCopyAfter = v ? 1 : 0;
            else if (!strcmp(line, "COPY_MODE")) prefCopyMode = v ? 1 : 0;
            else if (!strcmp(line, "COPY_VARIANT")) prefCopyVariant = (v >= 0 && v <= 4) ? v : 0;
        }
    }
    Close(fh);
}

static BOOL PutPref(BPTR fh, const char *key, const char *value)
{
    char line[LINE_SIZE];
    CopyStr(line, key, sizeof line);
    AppendStr(line, "=", sizeof line);
    AppendStr(line, value, sizeof line);
    AppendStr(line, "\n", sizeof line);
    return FPuts(fh, (STRPTR)line) == 0 ? TRUE : FALSE;
}

static BOOL PutPrefNum(BPTR fh, const char *key, long value)
{
    char num[16];
    num[0] = 0;
    AppendNum(num, value, sizeof num);
    return PutPref(fh, key, num);
}

static BOOL SavePrefs(void)
{
    BPTR fh = Open((STRPTR)PREFS_FILE, MODE_NEWFILE);
    BOOL ok;
    if (!fh) return FALSE;
    ok = PutPref(fh, "PI_COMMAND", xstr(strPiCmd));
    ok = PutPref(fh, "PI_SCRIPTS", xstr(strPiScripts)) && ok;
    ok = PutPref(fh, "AMIGA_BASE", xstr(strBase)) && ok;
    ok = PutPref(fh, "AMIGA_BUILD", xstr(strBuild)) && ok;
    ok = PutPref(fh, "COPY_DEST", xstr(strCopyDest)) && ok;
    ok = PutPrefNum(fh, "MODE", (long)xget(rdMode, MUIA_Radio_Active)) && ok;
    ok = PutPrefNum(fh, "SIMPLE", (long)xget(rdSimple, MUIA_Radio_Active)) && ok;
    ok = PutPrefNum(fh, "COPY_AFTER", (long)xget(chkCopyAfter, MUIA_Selected)) && ok;
    ok = PutPrefNum(fh, "COPY_MODE", (long)xget(cyCopyMode, MUIA_Cycle_Active)) && ok;
    ok = PutPrefNum(fh, "COPY_VARIANT", (long)xget(cyCopyVariant, MUIA_Cycle_Active)) && ok;
    if (!Close(fh)) ok = FALSE;
    return ok;
}

/* ================================================================== */
/* Building the command line                                           */
/* ================================================================== */
enum { CMD_RUN, CMD_STATUS, CMD_DOCTOR };

/* Appends to cmd; on overflow ok goes FALSE (checked by the caller). */
#define ADD(s)     (ok = AppendStr(cmd, (s), size) && ok)
#define ADDNUM(n)  (ok = AppendNum(cmd, (n), size) && ok)

/* "<pi command> <scripts>/<script>" - quoted when the folder has spaces. */
static BOOL CommandStart(char *cmd, int size, const char *script, char *why, int whySize)
{
    BOOL ok = TRUE;
    char path[PATH_SIZE];
    const char *pic = xstr(strPiCmd), *dir = xstr(strPiScripts);
    cmd[0] = 0;
    if (!pic[0] || !dir[0]) {
        CopyStr(why, "Set the Pi command and the whdsync scripts folder\n"
                     "on the A314 page (Advanced mode) first.", whySize);
        return FALSE;
    }
    if (!IsSafeFieldText(pic) || !IsSafeFieldText(dir)) {
        CopyStr(why, "The Pi command or the scripts folder on the A314 page\n"
                     "holds a character that can't go into a command line.\n\n"
                     "Use letters, digits, spaces and / . _ - + , : = @ % ~", whySize);
        return FALSE;
    }
    if (!JoinPath(dir, script, path, sizeof path)) {
        CopyStr(why, "The scripts folder on the A314 page is too long.", whySize);
        return FALSE;
    }
    ADD(pic);
    ADD(" ");
    if (strchr(path, ' ')) { ADD("\""); ADD(path); ADD("\""); }
    else ADD(path);
    /* Never colour or terminal codes: they would only clutter the log. */
    ADD(" --color=never");
    return ok;
}

/* The task chosen on the Task page and its options, as start.sh takes them. */
static BOOL BuildAdvanced(char *cmd, int size, char *why, int whySize)
{
    BOOL ok;
    long task = (long)xget(rdTask, MUIA_Radio_Active);
    long tbit = TB(task), v;
    const char *t;

    ok = CommandStart(cmd, size, "start.sh", why, whySize);
    if (!ok) return FALSE;

    switch (task) {
    case T_SYNC:    ADD(" --sync"); break;
    case T_PLAN:    ADD(" --plan"); break;
    case T_PREVIEW: ADD(" --preview-new"); break;
    case T_REBUILD: ADD(" --rebuild"); break;
    case T_UPDATE:  ADD(" --update"); break;
    case T_EXTRACT: ADD(" --extract"); break;
    case T_MERGE:   ADD(" --merge"); break;
    case T_SORT:    ADD(" --sort"); break;
    }

    if (tbit & MASK_VARIANT) {
        switch (xget(cyVariant, MUIA_Cycle_Active)) {
        case 1: ADD(" --aga"); break;
        case 2: ADD(" --ecs"); break;
        case 3: ADD(" --rtg"); break;
        case 4: ADD(" --aga-laced"); break;
        case 5: ADD(" --ecs-laced"); break;
        case 6:
            t = xstr(strSet);
            if (!t[0] || strchr(t, ' ') || strchr(t, '/') || !IsSafeFieldText(t)) {
                CopyStr(why, "Give the other artwork set as one word - the part\n"
                             "after iGame_ in its folder name (e.g. art).", whySize);
                return FALSE;
            }
            ADD(" --set ");
            ADD(t);
            break;
        }
    }
    if ((tbit & optMask[O_SKIPUPDATE]) && xget(chkOpt[O_SKIPUPDATE], MUIA_Selected)) ADD(" --skip-update");
    if ((tbit & optMask[O_CLEAN]) && xget(chkOpt[O_CLEAN], MUIA_Selected)) ADD(" --clean");
    if ((tbit & optMask[O_FORCE]) && xget(chkOpt[O_FORCE], MUIA_Selected)) ADD(" --force");
    if ((tbit & optMask[O_REFRESH]) && xget(chkOpt[O_REFRESH], MUIA_Selected)) {
        ADD(" --refresh-artwork");
    } else if ((tbit & optMask[O_ONLYMISSING]) && xget(chkOpt[O_ONLYMISSING], MUIA_Selected)) {
        ADD(" --only-missing");
    }
    if ((tbit & optMask[O_NONAMES]) && xget(chkOpt[O_NONAMES], MUIA_Selected)) ADD(" --no-amiga-names");
    if ((tbit & optMask[O_SKIPCHK]) && xget(chkOpt[O_SKIPCHK], MUIA_Selected)) ADD(" --skipchk");
    if ((tbit & optMask[O_SKIPVSORT]) && xget(chkOpt[O_SKIPVSORT], MUIA_Selected)) ADD(" --skip-variant-sort");

    if (tbit & MASK_FS) {
        v = (long)xget(cyFs, MUIA_Cycle_Active);
        if (v == 1) ADD(" --pfs");
        else if (v == 2) ADD(" --ffs");
    }
    if (tbit & MASK_DETOX) {
        v = (long)xget(cyDetox, MUIA_Cycle_Active);
        if (v == 1 && task != T_SORT) ADD(" --detox");
        else if (v == 2) ADD(" --no-detox");
    }
    if (tbit & MASK_ART) {
        v = (long)xget(cyArt, MUIA_Cycle_Active);
        if (v > 0) { ADD(" --art "); ADD(vOrder[v - 1]); }
        v = (long)xget(cyDemoArt, MUIA_Cycle_Active);
        if (v > 0) { ADD(" --demo-art "); ADD(vOrder[v - 1]); }
    }
    if (tbit & MASK_JOBS) {
        v = (long)xget(slJobs, MUIA_Numeric_Value);
        if (v > 0) { ADD(" --jobs "); ADDNUM(v); }
    }
    if (tbit & MASK_DEST) {
        t = xstr(strDest);
        if (t[0]) {
            if (!IsSafeFieldText(t) || strchr(t, ' ')) {
                CopyStr(why, "\"Build into\" must be a Pi folder without spaces, using\n"
                             "letters, digits and / . _ - + , : = @ % ~", whySize);
                return FALSE;
            }
            ADD(" --dest ");
            ADD(t);
        }
    }
    if (xget(chkOpt[O_DEBUG], MUIA_Selected)) ADD(" --debug");
    if (!ok) CopyStr(why, "The command line is too long.", whySize);
    return ok;
}

static BOOL BuildSimple(char *cmd, int size, char *why, int whySize)
{
    long v = (long)xget(rdSimple, MUIA_Radio_Active);
    if (v < 0 || v > 3) v = 0;
    return CommandStart(cmd, size, simpleScripts[v], why, whySize);
}

static BOOL BuildInfo(char *cmd, int size, int which, char *why, int whySize)
{
    BOOL ok = CommandStart(cmd, size, "start.sh", why, whySize);
    if (!ok) return FALSE;
    if (which == CMD_STATUS) ADD(" --status");
    else ADD(" --doctor");
    if (!ok) CopyStr(why, "The command line is too long.", whySize);
    return ok;
}

#undef ADD
#undef ADDNUM

/* ================================================================== */
/* Keeping the window in step                                          */
/* ================================================================== */
static int runState = 0;          /* 0 idle, 1 a run on the Pi, 2 copying */

static void UpdateButtons(void)
{
    BOOL busy = runState != 0 ? TRUE : FALSE;
    xset(btStart, MUIA_Disabled, busy);
    xset(btStatus, MUIA_Disabled, busy);
    xset(btDoctor, MUIA_Disabled, busy);
    xset(btCopy, MUIA_Disabled, busy);
    xset(btStop, MUIA_Disabled, !busy);
}

static void AppendFirstLine(char *dst, const char *src, int size)
{
    char tmp[LINE_SIZE], *nl;
    CopyStr(tmp, src, sizeof tmp);
    nl = strchr(tmp, '\n');
    if (nl) *nl = 0;
    AppendStr(dst, tmp, size);
}

/* Greys out what the chosen task does not use, and shows the command. */
static void RefreshTaskPage(void)
{
    long task = (long)xget(rdTask, MUIA_Radio_Active), tbit = TB(task);
    char cmd[CMD_SIZE], why[LINE_SIZE], show[CMD_SIZE + 16];
    int i;
    BOOL refresh;

    xset(cyVariant, MUIA_Disabled, !(tbit & MASK_VARIANT));
    xset(strSet, MUIA_Disabled, !(tbit & MASK_VARIANT) || xget(cyVariant, MUIA_Cycle_Active) != 6);
    xset(cyFs, MUIA_Disabled, !(tbit & MASK_FS));
    xset(cyDetox, MUIA_Disabled, !(tbit & MASK_DETOX));
    xset(cyArt, MUIA_Disabled, !(tbit & MASK_ART));
    xset(cyDemoArt, MUIA_Disabled, !(tbit & MASK_ART));
    xset(slJobs, MUIA_Disabled, !(tbit & MASK_JOBS));
    xset(strDest, MUIA_Disabled, !(tbit & MASK_DEST));
    refresh = (tbit & optMask[O_REFRESH]) && xget(chkOpt[O_REFRESH], MUIA_Selected) ? TRUE : FALSE;
    for (i = 0; i < O_COUNT; i++) {
        BOOL off = !(tbit & optMask[i]);
        if (i == O_ONLYMISSING && refresh) off = TRUE;   /* the two contradict */
        xset(chkOpt[i], MUIA_Disabled, off);
    }

    if (BuildAdvanced(cmd, sizeof cmd, why, sizeof why)) {
        CopyStr(show, "Will run: ", sizeof show);
        AppendStr(show, cmd, sizeof show);
    } else {
        CopyStr(show, "Not ready: ", sizeof show);
        AppendFirstLine(show, why, sizeof show);
    }
    xset(txTaskCmd, MUIA_Text_Contents, (ULONG)show);

    if (BuildSimple(cmd, sizeof cmd, why, sizeof why)) {
        CopyStr(show, "Will run: ", sizeof show);
        AppendStr(show, cmd, sizeof show);
    } else {
        CopyStr(show, "Not ready: ", sizeof show);
        AppendFirstLine(show, why, sizeof show);
    }
    xset(txSimpleCmd, MUIA_Text_Contents, (ULONG)show);
}

/* ================================================================== */
/* Paths on the Amiga side                                             */
/* ================================================================== */
static void BaseFolder(char *out, int size)
{
    const char *b = xstr(strBase);
    CopyStr(out, b[0] ? b : "PROGDIR:", size);
}

static BOOL BuildFolder(char *out, int size)
{
    const char *b = xstr(strBuild);
    char base[PATH_SIZE];
    if (b[0]) return CopyStr(out, b, size);
    BaseFolder(base, sizeof base);
    return JoinPath(base, "build", out, size);
}

static BOOL IsDrawer(const char *path)
{
    BPTR lock;
    struct FileInfoBlock *fib;
    BOOL dir = FALSE;
    lock = Lock((STRPTR)path, ACCESS_READ);
    if (!lock) return FALSE;
    fib = (struct FileInfoBlock *)AllocDosObject(DOS_FIB, NULL);
    if (fib) {
        if (Examine(lock, fib) && fib->fib_DirEntryType > 0) dir = TRUE;
        FreeDosObject(DOS_FIB, fib);
    }
    UnLock(lock);
    return dir;
}

/* The last-run record all.sh writes (.retroplay/last_run in the whdsync
   folder): its time, exit code and one-line result. FALSE if unreadable. */
static BOOL ReadLastRun(char *timeOut, int timeSize, long *code, char *result, int resultSize)
{
    char path[PATH_SIZE], base[PATH_SIZE], line[LINE_SIZE];
    BPTR fh;
    BOOL any = FALSE;
    timeOut[0] = 0;
    if (result) result[0] = 0;
    *code = -1;
    BaseFolder(base, sizeof base);
    if (!JoinPath(base, ".retroplay/last_run", path, sizeof path)) return FALSE;
    fh = Open((STRPTR)path, MODE_OLDFILE);
    if (!fh) return FALSE;
    while (FGets(fh, (STRPTR)line, sizeof line - 1)) {
        int len = (int)strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
        if (!strncmp(line, "time=", 5)) { CopyStr(timeOut, line + 5, timeSize); any = TRUE; }
        else if (!strncmp(line, "code=", 5)) ParseLong(line + 5, code);
        else if (result && !strncmp(line, "result=", 7)) CopyStr(result, line + 7, resultSize);
    }
    Close(fh);
    return any;
}

/* ================================================================== */
/* Copying the games to the Amiga                                      */
/* ================================================================== */
static long cpChecked, cpCopied, cpSkipped, cpFailed;
static BOOL cpStopped;
static BPTR cpLog = 0;
static UBYTE *cpBuf = NULL;

static void CopyLogLine(const char *what, const char *path)
{
    char line[LINE_SIZE];
    if (!cpLog) cpLog = Open((STRPTR)COPY_LOG_FILE, MODE_NEWFILE);
    CopyStr(line, what, sizeof line);
    AppendStr(line, path, sizeof line);
    if (cpLog) { FPuts(cpLog, (STRPTR)line); FPuts(cpLog, (STRPTR)"\n"); }
    AddLog(line);
}

static BOOL HasIllegalChars(const char *name)
{
    for (; *name; name++) {
        unsigned char c = (unsigned char)*name;
        if (c == ':' || c == '/' || c < 32 || c == 127) return TRUE;
    }
    return FALSE;
}

static BOOL IsNewer(const struct DateStamp *a, const struct DateStamp *b)
{
    if (a->ds_Days != b->ds_Days) return a->ds_Days > b->ds_Days ? TRUE : FALSE;
    if (a->ds_Minute != b->ds_Minute) return a->ds_Minute > b->ds_Minute ? TRUE : FALSE;
    return a->ds_Tick > b->ds_Tick ? TRUE : FALSE;
}

/* Keeps the window alive during a copy, and notices Stop. */
static void Pump(const char *current)
{
    char line[LINE_SIZE];
    if ((cpChecked & 7) == 0 || current == NULL) {
        CopyStr(line, "Copying: ", sizeof line);
        AppendNum(line, cpCopied, sizeof line);
        AppendStr(line, " copied, ", sizeof line);
        AppendNum(line, cpChecked, sizeof line);
        AppendStr(line, " checked", sizeof line);
        if (current) { AppendStr(line, " - ", sizeof line); AppendStr(line, current, sizeof line); }
        SetStatus(line);
    }
    DoMethod(app, MUIM_Application_InputBuffered);
    if (xget(btStop, MUIA_UserData)) cpStopped = TRUE;
}

/* One file: written to a temporary name in the same drawer first, and only
   renamed over the old one once it is complete - an interrupted copy never
   leaves a half-written game file behind. Date, protection bits and
   comment are carried across, as Copy CLONE would. */
static BOOL CopyOneFile(const char *src, const char *dst, const char *dstDir,
                        const struct FileInfoBlock *fib)
{
    char tmp[PATH_SIZE];
    BPTR in, out;
    LONG n;
    BOOL ok = TRUE;
    if (!JoinPath(dstDir, TEMP_NAME, tmp, sizeof tmp)) return FALSE;
    in = Open((STRPTR)src, MODE_OLDFILE);
    if (!in) return FALSE;
    out = Open((STRPTR)tmp, MODE_NEWFILE);
    if (!out) { Close(in); return FALSE; }
    while ((n = Read(in, cpBuf, COPY_BUF)) > 0) {
        if (Write(out, cpBuf, n) != n) { ok = FALSE; break; }
    }
    if (n < 0) ok = FALSE;
    Close(in);
    if (!Close(out)) ok = FALSE;
    if (ok) {
        SetProtection((STRPTR)dst, 0);       /* a delete-protected old copy */
        DeleteFile((STRPTR)dst);
        if (!Rename((STRPTR)tmp, (STRPTR)dst)) ok = FALSE;
    }
    if (!ok) { DeleteFile((STRPTR)tmp); return FALSE; }
    SetFileDate((STRPTR)dst, (struct DateStamp *)&fib->fib_Date);
    SetProtection((STRPTR)dst, fib->fib_Protection);
    if (fib->fib_Comment[0]) SetComment((STRPTR)dst, (STRPTR)fib->fib_Comment);
    return TRUE;
}

/* Copies a file when the Amiga has no copy of it, or an older one. */
static void CopyIfNewer(const char *src, const char *dst, const char *dstDir,
                        const struct FileInfoBlock *srcFib)
{
    BPTR lock;
    struct FileInfoBlock *fib;
    BOOL need = TRUE;
    lock = Lock((STRPTR)dst, ACCESS_READ);
    if (lock) {
        fib = (struct FileInfoBlock *)AllocDosObject(DOS_FIB, NULL);
        if (fib) {
            if (Examine(lock, fib)) {
                if (fib->fib_DirEntryType > 0) need = FALSE;      /* a drawer there */
                else need = IsNewer(&srcFib->fib_Date, &fib->fib_Date);
            }
            FreeDosObject(DOS_FIB, fib);
        }
        UnLock(lock);
    }
    if (!need) return;
    if (CopyOneFile(src, dst, dstDir, srcFib)) cpCopied++;
    else { cpFailed++; CopyLogLine("COULD NOT COPY: ", src); }
}

static BOOL EnsureDrawer(const char *path)
{
    BPTR lock;
    if (IsDrawer(path)) return TRUE;
    lock = CreateDir((STRPTR)path);
    if (!lock) return FALSE;
    UnLock(lock);
    return TRUE;
}

/* Walks srcDir and mirrors it into dstDir. Paths and the FileInfoBlock
   come from the heap, so a deep drawer tree costs little stack. */
static void CopyTree(const char *srcDir, const char *dstDir, int depth)
{
    struct FileInfoBlock *fib;
    BPTR lock;
    char *srcPath, *dstPath;

    if (cpStopped || depth > 40) return;
    fib = (struct FileInfoBlock *)AllocDosObject(DOS_FIB, NULL);
    srcPath = (char *)AllocVec(PATH_SIZE * 2, MEMF_ANY);
    if (!fib || !srcPath) {
        if (fib) FreeDosObject(DOS_FIB, fib);
        if (srcPath) FreeVec(srcPath);
        cpFailed++;
        CopyLogLine("OUT OF MEMORY at: ", srcDir);
        return;
    }
    dstPath = srcPath + PATH_SIZE;
    lock = Lock((STRPTR)srcDir, ACCESS_READ);
    if (lock && Examine(lock, fib) && fib->fib_DirEntryType > 0) {
        while (!cpStopped && ExNext(lock, fib)) {
            const char *name = fib->fib_FileName;
            if (!strcmp(name, TEMP_NAME)) continue;
            if (!JoinPath(srcDir, name, srcPath, PATH_SIZE) ||
                !JoinPath(dstDir, name, dstPath, PATH_SIZE)) {
                cpSkipped++;
                CopyLogLine("SKIPPED (path too long): ", name);
                continue;
            }
            if (HasIllegalChars(name)) {
                cpSkipped++;
                CopyLogLine("SKIPPED (a character AmigaDOS can't store): ", srcPath);
                continue;
            }
            if (fib->fib_DirEntryType > 0) {
                if (EnsureDrawer(dstPath)) CopyTree(srcPath, dstPath, depth + 1);
                else { cpFailed++; CopyLogLine("COULD NOT MAKE DRAWER: ", dstPath); }
            } else {
                cpChecked++;
                CopyIfNewer(srcPath, dstPath, dstDir, fib);
                Pump(name);
            }
        }
    } else {
        cpFailed++;
        CopyLogLine("COULD NOT READ: ", srcDir);
    }
    if (lock) UnLock(lock);
    FreeVec(srcPath);
    FreeDosObject(DOS_FIB, fib);
}

/* The newest dated folder in dir (names are 2026-11-18_020000, so the
   newest is the one that sorts last). */
static BOOL NewestSubdir(const char *dir, char *out, int outSize)
{
    BPTR lock;
    struct FileInfoBlock *fib;
    char best[108];
    best[0] = 0;
    lock = Lock((STRPTR)dir, ACCESS_READ);
    if (!lock) return FALSE;
    fib = (struct FileInfoBlock *)AllocDosObject(DOS_FIB, NULL);
    if (fib && Examine(lock, fib)) {
        while (ExNext(lock, fib)) {
            if (fib->fib_DirEntryType <= 0) continue;
            if (fib->fib_FileName[0] < '0' || fib->fib_FileName[0] > '9') continue;
            if (strcmp(fib->fib_FileName, best) > 0) CopyStr(best, fib->fib_FileName, sizeof best);
        }
    }
    if (fib) FreeDosObject(DOS_FIB, fib);
    UnLock(lock);
    if (!best[0]) return FALSE;
    return JoinPath(dir, best, out, outSize);
}

/* Copies one collection's games to the drawer chosen beside
   "Copy the games to the Amiga". suffix is aga, ecs, rtg, aga_laced... */
static void DoCopy(const char *suffix)
{
    char build[PATH_SIZE], src[PATH_SIZE], name[64], line[LINE_SIZE];
    const char *dest = xstr(strCopyDest);
    long mode = (long)xget(cyCopyMode, MUIA_Cycle_Active);

    if (!dest[0]) {
        Request("_OK", "First choose where the games go on the Amiga, with the\n"
                       "drawer button beside \"Copy the games to the Amiga\".");
        return;
    }
    if (!IsDrawer(dest)) {
        AddLog2("Copy: no such drawer on the Amiga - ", dest);
        return;
    }
    if (!BuildFolder(build, sizeof build)) { AddLog("Copy: the build folder path is too long."); return; }
    if (mode == 0) {
        CopyStr(name, "new_", sizeof name);
        AppendStr(name, suffix, sizeof name);
        if (!JoinPath(build, name, line, sizeof line) || !NewestSubdir(line, src, sizeof src)) {
            AddLog2("Copy: no new games folder yet in ", line);
            AddLog("      (it appears after a build that found new games)");
            return;
        }
    } else {
        CopyStr(name, "retro_", sizeof name);
        AppendStr(name, suffix, sizeof name);
        if (!JoinPath(build, name, src, sizeof src) || !IsDrawer(src)) {
            AddLog2("Copy: that collection isn't built yet - ", src);
            AddLog("      (check \"Build folder\" on the A314 page)");
            return;
        }
    }
    cpBuf = (UBYTE *)AllocVec(COPY_BUF, MEMF_ANY);
    if (!cpBuf) { AddLog("Copy: not enough memory."); return; }

    cpChecked = cpCopied = cpSkipped = cpFailed = 0;
    cpStopped = FALSE;
    xset(btStop, MUIA_UserData, 0);
    runState = 2;
    UpdateButtons();
    AddLog("--------------------------------------------------------------");
    AddLog2("Copying from: ", src);
    AddLog2("        into: ", dest);
    CopyTree(src, dest, 0);
    FreeVec(cpBuf);
    cpBuf = NULL;
    if (cpLog) { Close(cpLog); cpLog = 0; }

    CopyStr(line, cpStopped ? "Copy stopped: " : "Copy finished: ", sizeof line);
    AppendNum(line, cpCopied, sizeof line);
    AppendStr(line, " file(s) copied, ", sizeof line);
    AppendNum(line, cpChecked - cpCopied - cpFailed, sizeof line);
    AppendStr(line, " already up to date", sizeof line);
    if (cpSkipped) { AppendStr(line, ", ", sizeof line); AppendNum(line, cpSkipped, sizeof line); AppendStr(line, " skipped", sizeof line); }
    if (cpFailed) { AppendStr(line, ", ", sizeof line); AppendNum(line, cpFailed, sizeof line); AppendStr(line, " failed", sizeof line); }
    AddLog(line);
    if (cpSkipped || cpFailed) AddLog("The list of what was left out is in " COPY_LOG_FILE);
    SetStatus(line);
    runState = 0;
    UpdateButtons();
}

/* Which collection is copied: the one this run built, or - for "All" and
   "As in settings" - the one chosen on the A314 page as this Amiga's. */
static const char *CopySuffixFor(BOOL simple)
{
    long v;
    if (simple) {
        v = (long)xget(rdSimple, MUIA_Radio_Active);
        if (v >= 1 && v <= 3) return simpleSuffix[v];
    } else {
        v = (long)xget(cyVariant, MUIA_Cycle_Active);
        if (v >= 1 && v <= 5) return variantSuffix[v];
    }
    v = (long)xget(cyCopyVariant, MUIA_Cycle_Active);
    if (v < 0 || v > 4) v = 0;
    return copyVariantSuffix[v];
}

/* ================================================================== */
/* Running a command on the Pi                                         */
/* ================================================================== */
static struct MsgPort *timerPort = NULL;
static struct timerequest *timerReq = NULL;
static BOOL timerOpen = FALSE, timerPending = FALSE;

static BPTR runOut = 0;
static char runOutName[64], runScriptName[64];
static char lineBuf[LINE_SIZE];
static int lineLen = 0, escState = 0, u8need = 0;
static unsigned long u8cp = 0;
static BOOL crPending = FALSE, runFinished = FALSE, sawUnknownCommand = FALSE;
static long runRc = -1;
static struct DateStamp runStart;
static char lastRunBefore[64];
static BOOL copyAfterRun = FALSE;
static const char *copySuffix = NULL;

static void StartTimer(void)
{
    if (!timerOpen || timerPending) return;
    timerReq->tr_node.io_Command = TR_ADDREQUEST;
    timerReq->tr_time.tv_secs = 0;
    timerReq->tr_time.tv_micro = 250000;
    SendIO((struct IORequest *)timerReq);
    timerPending = TRUE;
}

static BOOL SetupTimer(void)
{
    timerPort = CreateMsgPort();
    if (!timerPort) return FALSE;
    timerReq = (struct timerequest *)CreateIORequest(timerPort, sizeof(struct timerequest));
    if (!timerReq) return FALSE;
    if (OpenDevice((STRPTR)TIMERNAME, UNIT_VBLANK, (struct IORequest *)timerReq, 0) != 0) return FALSE;
    timerOpen = TRUE;
    return TRUE;
}

static void CleanupTimer(void)
{
    if (timerPending) {
        AbortIO((struct IORequest *)timerReq);
        WaitIO((struct IORequest *)timerReq);
        timerPending = FALSE;
    }
    if (timerOpen) CloseDevice((struct IORequest *)timerReq);
    if (timerReq) DeleteIORequest((struct IORequest *)timerReq);
    if (timerPort) DeleteMsgPort(timerPort);
}

static long ElapsedSeconds(void)
{
    struct DateStamp now;
    DateStamp(&now);
    return (now.ds_Days - runStart.ds_Days) * 86400L
         + (now.ds_Minute - runStart.ds_Minute) * 60L
         + (now.ds_Tick - runStart.ds_Tick) / TICKS_PER_SECOND;
}

static void AppendDuration(char *out, long secs, int size)
{
    if (secs < 0) secs = 0;
    if (secs >= 3600) { AppendNum(out, secs / 3600, size); AppendStr(out, ":", size); secs %= 3600;
                        if (secs < 600) AppendStr(out, "0", size); }
    AppendNum(out, secs / 60, size);
    AppendStr(out, ":", size);
    if (secs % 60 < 10) AppendStr(out, "0", size);
    AppendNum(out, secs % 60, size);
}

/* ---------------------------------------------------------------- */
/* Turning what the Pi prints into lines for the log                */
/*  - terminal escape sequences (colour) are dropped;               */
/*  - a carriage return starts the line again, as on a terminal, so */
/*    a redrawn progress bar ends up as its final state;            */
/*  - UTF-8 becomes Latin-1, the Amiga's own character set, with    */
/*    the few symbols the scripts print (ticks, arrows, dashes)     */
/*    turned into plain characters.                                 */
/* ---------------------------------------------------------------- */
static void PutChar(int c)
{
    if (crPending) { lineLen = 0; crPending = FALSE; }
    if (lineLen < LINE_SIZE - 1) lineBuf[lineLen++] = (char)c;
}

static void PutCodepoint(unsigned long cp)
{
    if (cp >= 0xA0 && cp <= 0xFF) { PutChar((int)cp); return; }
    switch (cp) {
    case 0x2713: case 0x2714: case 0x2705: PutChar('+'); return;   /* ticks */
    case 0x2717: case 0x2718: case 0x274C: PutChar('x'); return;   /* crosses */
    case 0x26A0: PutChar('!'); return;                              /* warning */
    case 0x2192: case 0x2794: PutChar('>'); return;                 /* arrows */
    case 0x2190: PutChar('<'); return;
    case 0x2013: case 0x2014: case 0x2500: PutChar('-'); return;    /* dashes, rules */
    case 0x2022: case 0x00B7: PutChar('*'); return;                 /* bullets */
    case 0x2026: PutChar('.'); PutChar('.'); PutChar('.'); return;
    case 0x2018: case 0x2019: PutChar('\''); return;
    case 0x201C: case 0x201D: PutChar('"'); return;
    case 0x2588: case 0x2589: case 0x258A: case 0x258B: case 0x258C:
    case 0x258D: case 0x258E: case 0x258F: case 0x2593: case 0x2592:
        PutChar('#'); return;                                       /* progress blocks */
    case 0x2591: PutChar('.'); return;
    }
    PutChar('?');
}

static void LineDone(void)
{
    long rc;
    lineBuf[lineLen] = 0;
    lineLen = 0;
    crPending = FALSE;
    if (!strncmp(lineBuf, RC_SENTINEL, sizeof(RC_SENTINEL) - 1)) {
        runRc = ParseLong(lineBuf + sizeof(RC_SENTINEL) - 1, &rc) ? rc : -1;
        runFinished = TRUE;
        return;
    }
    if (strstr(lineBuf, "Unknown command") || strstr(lineBuf, "unknown command")
        || strstr(lineBuf, "object not found")) sawUnknownCommand = TRUE;
    AddLog(lineBuf);
}

static void FeedByte(unsigned char b)
{
    if (escState == 1) { escState = (b == '[') ? 2 : 0; return; }
    if (escState == 2) { if (b >= 0x40 && b <= 0x7E) escState = 0; return; }
    if (u8need > 0) {
        if ((b & 0xC0) == 0x80) {
            u8cp = (u8cp << 6) | (b & 0x3F);
            if (--u8need == 0) PutCodepoint(u8cp);
            return;
        }
        u8need = 0;
        PutChar('?');                 /* a broken sequence; b is read as itself */
    }
    if (b == 0x1B) { escState = 1; return; }
    if (b == 0x9B) { escState = 2; return; }      /* 8-bit CSI */
    if (b == '\n') { LineDone(); return; }
    if (b == '\r') { crPending = TRUE; return; }
    if (b == '\t') {
        do PutChar(' '); while ((lineLen % 8) != 0 && lineLen < LINE_SIZE - 1);
        return;
    }
    if (b < 0x20 || b == 0x7F) return;
    if (b < 0x80) { PutChar(b); return; }
    if ((b & 0xE0) == 0xC0) { u8cp = b & 0x1F; u8need = 1; return; }
    if ((b & 0xF0) == 0xE0) { u8cp = b & 0x0F; u8need = 2; return; }
    if ((b & 0xF8) == 0xF0) { u8cp = b & 0x07; u8need = 3; return; }
    PutChar('?');
}

static const char *ExitMeaning(long rc)
{
    switch (rc) {
    case 0:   return "done";
    case 2:   return "nothing to do - everything is up to date";
    case 3:   return "network or server problem - it tries again next run";
    case 4:   return "setup or option problem - press Check set-up";
    case 5:   return "done, but some archives could not be extracted (they are retried)";
    case 130: return "interrupted";
    }
    return "failed";
}

static void FinishRun(void)
{
    char line[LINE_SIZE], when[64], result[LINE_SIZE];
    long code = runRc, fileCode;

    if (lineLen > 0) LineDone();              /* a last line with no newline */
    if (runOut) { Close(runOut); runOut = 0; }
    DeleteFile((STRPTR)runOutName);
    DeleteFile((STRPTR)runScriptName);

    /* all.sh's own record is the reliable answer: it does not depend on the
       Pi command passing the exit code back. Used when this run wrote it. */
    if (ReadLastRun(when, sizeof when, &fileCode, result, sizeof result)
        && strcmp(when, lastRunBefore) && fileCode >= 0) {
        code = fileCode;
    } else {
        result[0] = 0;
    }

    CopyStr(line, "Finished after ", sizeof line);
    AppendDuration(line, ElapsedSeconds(), sizeof line);
    AppendStr(line, " - ", sizeof line);
    if (code < 0) AppendStr(line, "could not tell how it ended", sizeof line);
    else {
        AppendStr(line, ExitMeaning(code), sizeof line);
        AppendStr(line, " (exit ", sizeof line);
        AppendNum(line, code, sizeof line);
        AppendStr(line, ")", sizeof line);
    }
    AddLog("--------------------------------------------------------------");
    if (result[0]) AddLog(result);
    AddLog(line);
    SetStatus(line);
    if (sawUnknownCommand && code != 0) {
        AddLog("The Amiga could not run the Pi command. Check \"Pi command\" on the A314");
        AddLog("page (Advanced mode) - it is what you type to run a program on the Pi.");
    }
    runState = 0;
    UpdateButtons();

    if (copyAfterRun) {
        if (code == 0 || code == 5) DoCopy(copySuffix);
        else if (code == 2) AddLog("Nothing new was built, so there is nothing new to copy.");
        else AddLog("The copy to the Amiga was skipped, because the run did not finish.");
    }
}

/* Stop during a run: the Pi can't be interrupted from here, but the
   window can stop waiting - which is also the way out if the command
   never reports back (the Pi command missing, say). */
static void AbandonRun(void)
{
    if (runOut) { Close(runOut); runOut = 0; }
    AddLog("--------------------------------------------------------------");
    AddLog("Stopped waiting. Anything already running on the Pi carries on there;");
    AddLog("Status shows how it ended. Nothing is copied to the Amiga.");
    SetStatus("Stopped waiting for the run");
    runState = 0;
    UpdateButtons();
}

/* Reads whatever the Pi has printed since the last look. */
static void PollRun(void)
{
    UBYTE buf[1024];
    LONG n, i;
    char status[LINE_SIZE];
    if (runState != 1 || !runOut) return;
    if (xget(btStop, MUIA_UserData)) { AbandonRun(); return; }
    while (!runFinished && (n = Read(runOut, buf, sizeof buf)) > 0) {
        for (i = 0; i < n && !runFinished; i++) FeedByte(buf[i]);
    }
    if (runFinished) { FinishRun(); return; }
    CopyStr(status, "Running ", sizeof status);
    AppendDuration(status, ElapsedSeconds(), sizeof status);
    if (lineLen > 0 && crPending == FALSE) {
        lineBuf[lineLen] = 0;
        AppendStr(status, " - ", sizeof status);
        AppendStr(status, lineBuf, sizeof status);
    }
    SetStatus(status);
}

static BOOL TempName(const char *name, char *out, int size)
{
    BPTR lock = Lock((STRPTR)"T:", ACCESS_READ);
    if (lock) { UnLock(lock); return JoinPath("T:", name, out, size); }
    return JoinPath("RAM:", name, out, size);
}

/* Starts cmd on the Pi. Output arrives in a file in T:, read by PollRun. */
static BOOL StartRun(const char *cmd, BOOL copyAfter, const char *suffix)
{
    BPTR fh, in, out;
    struct TagItem tags[5];
    char line[CMD_SIZE + 8], execCmd[96];
    long dummy;

    if (!TempName(RUN_SCRIPT, runScriptName, sizeof runScriptName) ||
        !TempName(RUN_OUTPUT, runOutName, sizeof runOutName)) return FALSE;

    /* FailAt 1000 so that a failing run still reaches the Echo that
       reports its exit code; $RC is set by the shell after each command. */
    fh = Open((STRPTR)runScriptName, MODE_NEWFILE);
    if (!fh) { AddLog2("Could not write ", runScriptName); return FALSE; }
    CopyStr(line, cmd, sizeof line);
    AppendStr(line, "\n", sizeof line);
    FPuts(fh, (STRPTR)"FailAt 1000\n");
    FPuts(fh, (STRPTR)line);
    FPuts(fh, (STRPTR)"Echo " RC_SENTINEL "$RC\n");
    if (!Close(fh)) { AddLog2("Could not write ", runScriptName); return FALSE; }

    /* The output file is made empty first, then opened twice with shared
       locks: once for the run to write to and once for this window to read
       from while it is still being written. */
    fh = Open((STRPTR)runOutName, MODE_NEWFILE);
    if (fh) Close(fh);
    out = Open((STRPTR)runOutName, MODE_READWRITE);
    runOut = Open((STRPTR)runOutName, MODE_OLDFILE);
    in = Open((STRPTR)"NIL:", MODE_OLDFILE);
    if (!out || !runOut || !in) {
        if (out) Close(out);
        if (in) Close(in);
        if (runOut) { Close(runOut); runOut = 0; }
        AddLog2("Could not open ", runOutName);
        return FALSE;
    }

    CopyStr(execCmd, "Execute ", sizeof execCmd);
    AppendStr(execCmd, runScriptName, sizeof execCmd);
    tags[0].ti_Tag = SYS_Input;  tags[0].ti_Data = (ULONG)in;
    tags[1].ti_Tag = SYS_Output; tags[1].ti_Data = (ULONG)out;
    tags[2].ti_Tag = SYS_Asynch; tags[2].ti_Data = TRUE;
    tags[3].ti_Tag = NP_StackSize; tags[3].ti_Data = 16384;
    tags[4].ti_Tag = TAG_DONE;   tags[4].ti_Data = 0;

    /* What the last run record says now, to tell afterwards whether this
       run wrote a new one. */
    ReadLastRun(lastRunBefore, sizeof lastRunBefore, &dummy, NULL, 0);

    lineLen = 0; escState = 0; u8need = 0; crPending = FALSE;
    xset(btStop, MUIA_UserData, 0);
    runFinished = FALSE; sawUnknownCommand = FALSE; runRc = -1;
    if (SystemTagList((STRPTR)execCmd, tags) == -1) {
        /* Not started: the handles are still ours to close. */
        Close(in);
        Close(out);
        Close(runOut);
        runOut = 0;
        AddLog("Could not start the shell to run the command.");
        return FALSE;
    }
    DateStamp(&runStart);
    copyAfterRun = copyAfter;
    copySuffix = suffix;
    runState = 1;
    UpdateButtons();
    AddLog("==============================================================");
    AddLog(cmd);
    AddLog("==============================================================");
    SetStatus("Running...");
    StartTimer();
    return TRUE;
}

/* ================================================================== */
/* Button actions                                                      */
/* ================================================================== */
/* Settings changed but not saved: the run would not see them. */
static BOOL OfferSaveFirst(void)
{
    long r;
    if (!AnySettingChanged()) return TRUE;
    r = Request("_Save and run|_Run without saving|_Cancel",
                "Some settings have changed but are not saved yet.\n"
                "The scripts read retroplay.conf, so this run would not see them.");
    if (r == 1) return SaveConf();
    return r == 2 ? TRUE : FALSE;
}

static void DoStart(void)
{
    char cmd[CMD_SIZE], why[LINE_SIZE];
    BOOL simple = xget(rdMode, MUIA_Radio_Active) == 0 ? TRUE : FALSE;
    BOOL copy = xget(chkCopyAfter, MUIA_Selected) ? TRUE : FALSE;
    BOOL ok;
    long task = (long)xget(rdTask, MUIA_Radio_Active);

    ok = simple ? BuildSimple(cmd, sizeof cmd, why, sizeof why)
                : BuildAdvanced(cmd, sizeof cmd, why, sizeof why);
    if (!ok) { Request("_OK", why); return; }
    if (!simple && !(TB(task) & MASK_COPY)) copy = FALSE;   /* only after a build */
    if (copy && !xstr(strCopyDest)[0]) {
        Request("_OK", "\"Copy the games to the Amiga\" is ticked, but no drawer\n"
                       "is chosen yet. Choose one with the button beside it.");
        return;
    }
    if (!OfferSaveFirst()) return;
    StartRun(cmd, copy, copy ? CopySuffixFor(simple) : NULL);
}

/* Status and Check set-up only ever read; they never lead to a copy. */
static void DoInfo(int which)
{
    char cmd[CMD_SIZE], why[LINE_SIZE];
    if (!BuildInfo(cmd, sizeof cmd, which, why, sizeof why)) { Request("_OK", why); return; }
    StartRun(cmd, FALSE, NULL);
}

static void DoSave(void)
{
    if (SaveConf()) {
        if (SavePrefs()) AddLog("This window's own choices are in " PREFS_FILE);
        else AddLog("Could not write " PREFS_FILE);
    }
}

/* ================================================================== */
/* Building the window                                                 */
/* ================================================================== */
static Object *BuildSettingsPage(int page)
{
    struct Setting *s;
    Object *grp, *w;
    int i;
    BOOL ok = TRUE;

    grp = ColGroup(2), End;
    if (!grp) return NULL;
    for (s = settings; s->key && ok; s++) {
        if (s->page != page) continue;
        SettingBaseline(s);
        switch (s->kind) {
        case K_BOOL:
            s->obj = MakeCheck(s->init ? TRUE : FALSE, s->help);
            ok = AddLabelled(grp, s->label, s->obj, TRUE, FALSE);
            break;
        case K_CHOICE:
            for (i = 0; s->values[i] && i < MAX_CHOICE; i++) s->cyc[i] = s->labels[i];
            s->nvalues = i;
            SettingBaseline(s);
            if (s->init == s->nvalues) {
                /* The file has a value this window doesn't offer: keep it. */
                CopyStr(s->keepLabel, "Keep as it is: ", sizeof s->keepLabel);
                AppendStr(s->keepLabel, s->raw, sizeof s->keepLabel);
                s->cyc[i++] = s->keepLabel;
            }
            s->cyc[i] = NULL;
            s->obj = MakeCycle(s->cyc, s->init, s->help);
            ok = AddLabelled(grp, s->label, s->obj, FALSE, FALSE);
            break;
        case K_NUM:
            s->obj = MakeSlider(s->min, s->max, s->init, s->fmt, s->help);
            ok = AddLabelled(grp, s->label, s->obj, FALSE, FALSE);
            break;
        case K_TEXT:
            s->obj = MakeString(s->raw, RAW_SIZE - 1, s->help);
            ok = AddLabelled(grp, s->label, s->obj, FALSE, TRUE);
            break;
        case K_LIST:
            /* Three to a row when the names are short, two when they are
               long, so the page stays inside a 640-pixel screen. */
            {
                int longest = 0, l;
                for (i = 0; s->labels[i]; i++) { l = (int)strlen(s->labels[i]); if (l > longest) longest = l; }
                w = ColGroup(longest > 10 ? 4 : 6), MUIA_ShortHelp, (ULONG)s->help, End;
            }
            if (!w) { ok = FALSE; break; }
            for (i = 0; s->values[i] && i < MAX_LIST && ok; i++) {
                s->box[i] = MakeCheck((s->init & (1L << i)) ? TRUE : FALSE, s->help);
                ok = AddCheckPair(w, s->box[i], s->labels[i]);
            }
            s->obj = w;
            if (ok) ok = AddLabelled(grp, s->label, w, FALSE, FALSE);
            break;
        }
    }
    if (!ok) { MUI_DisposeObject(grp); return NULL; }
    return grp;
}

static Object *BuildTaskPage(void)
{
    Object *opts, *right;
    int i;

    rdTask = RadioObject,
        MUIA_Radio_Entries, (ULONG)taskEntries,
        MUIA_Radio_Active, T_SYNC,
        MUIA_CycleChain, 1,
        MUIA_ShortHelp, (ULONG)"What start.sh does this time.",
    End;
    cyVariant = MakeCycle(variantEntries, 0,
        "Which collection. \"As in settings\" builds every one\nin Collections to build.");
    strSet = MakeString("", 32, "The artwork set's name: iGame_<name>. (--set)");
    cyFs = MakeCycle(fsEntries, 0, "(--pfs / --ffs) for this run only");
    cyDetox = MakeCycle(detoxEntries, 0, "(--detox / --no-detox) for this run only");
    cyArt = MakeCycle(orderEntries, 0, "Artwork order for games, this run only. (--art)");
    cyDemoArt = MakeCycle(orderEntries, 0, "Artwork order for demos, this run only. (--demo-art)");
    slJobs = MakeSlider(0, 16, 0, "%ld", "How many things at once, this run only.\n0 = as in settings. (--jobs)");
    strDest = MakeString("", PATH_SIZE, "Build somewhere other than the usual folder\n(a Pi folder; one collection only). (--dest)");
    txTaskCmd = TextObject, TextFrame, MUIA_Background, MUII_TextBack,
        MUIA_Text_SetMin, FALSE, MUIA_Text_Contents, (ULONG)"", End;
    if (!rdTask || !cyVariant || !strSet || !cyFs || !cyDetox || !cyArt || !cyDemoArt
        || !slJobs || !strDest || !txTaskCmd) return NULL;

    right = ColGroup(2), End;
    if (!right) return NULL;
    if (!AddLabelled(right, "Collection", cyVariant, FALSE, FALSE)) return NULL;
    if (!AddLabelled(right, "Other set", strSet, FALSE, TRUE)) return NULL;
    if (!AddLabelled(right, "Filesystem", cyFs, FALSE, FALSE)) return NULL;
    if (!AddLabelled(right, "Detox", cyDetox, FALSE, FALSE)) return NULL;
    if (!AddLabelled(right, "Artwork order", cyArt, FALSE, FALSE)) return NULL;
    if (!AddLabelled(right, "Demo artwork", cyDemoArt, FALSE, FALSE)) return NULL;
    if (!AddLabelled(right, "Jobs at once", slJobs, FALSE, FALSE)) return NULL;
    if (!AddLabelled(right, "Build into", strDest, FALSE, TRUE)) return NULL;

    opts = ColGroup(4), End;          /* two to a row: the labels are long */
    if (!opts) return NULL;
    for (i = 0; i < O_COUNT; i++) {
        chkOpt[i] = MakeCheck(FALSE, optHelp[i]);
        if (!AddCheckPair(opts, chkOpt[i], optLabels[i])) return NULL;
    }

    return VGroup,
        Child, (ULONG)(HGroup,
            Child, (ULONG)(VGroup, GroupFrameT("What to do"),
                Child, (ULONG)rdTask,
                Child, (ULONG)VSpace(0),
            End),
            Child, (ULONG)(VGroup, GroupFrameT("For this run"),
                Child, (ULONG)right,
                Child, (ULONG)VSpace(0),
            End),
        End),
        Child, (ULONG)(VGroup, GroupFrameT("Options for this run"),
            Child, (ULONG)opts,
        End),
        Child, (ULONG)txTaskCmd,
    End;
}

static Object *BuildA314Page(void)
{
    Object *grp, *popBase, *popBuild;
    static const char *intro =
        "How this Amiga reaches the Pi. The settings pages are saved to\n"
        "retroplay.conf in the folder this program was started from -\n"
        "keep it in the whdsync folder on the Pi share so the scripts read it.";

    strPiCmd = MakeString(prefPiCmd, sizeof prefPiCmd,
        "What you type in a Shell to run a program on the Pi.\nWith the A314 software this is: pi");
    strPiScripts = MakeString(prefPiScripts, PATH_SIZE,
        "The folder on the Pi that holds all.sh, start.sh and the rest.");
    popBase = MakePopDrawer(&strBase, prefBase, "The whdsync folder on the Pi share",
        "The whdsync folder, as the Amiga sees it (for example PI0:whdsync).\n"
        "PROGDIR: means the folder this program is in.");
    popBuild = MakePopDrawer(&strBuild, prefBuild, "The build folder on the Pi share",
        "The build folder, as the Amiga sees it.\nLeave empty for the build folder inside the whdsync folder.");
    cyCopyVariant = MakeCycle(copyVariantEntries, prefCopyVariant,
        "The collection copied after a run that builds them all.");
    cyCopyMode = MakeCycle(copyModeEntries, prefCopyMode,
        "Latest new games: just the dated folder the last run made - quick.\n"
        "Everything: the whole collection, copying only what is new or changed.");
    txConf = TextObject, MUIA_Text_SetMin, FALSE,
        MUIA_Text_Contents, (ULONG)(confFound ? "Settings file: PROGDIR:retroplay.conf"
            : "Settings file: none in PROGDIR: yet - the built-in defaults are shown"),
    End;
    if (!strPiCmd || !strPiScripts || !popBase || !popBuild || !cyCopyVariant
        || !cyCopyMode || !txConf) return NULL;

    grp = ColGroup(2), End;
    if (!grp) return NULL;
    if (!AddLabelled(grp, "Pi command", strPiCmd, FALSE, TRUE)) return NULL;
    if (!AddLabelled(grp, "Scripts folder on the Pi", strPiScripts, FALSE, TRUE)) return NULL;
    if (!AddLabelled(grp, "whdsync folder (Amiga)", popBase, FALSE, TRUE)) return NULL;
    if (!AddLabelled(grp, "Build folder (Amiga)", popBuild, FALSE, TRUE)) return NULL;
    if (!AddLabelled(grp, "This Amiga uses", cyCopyVariant, FALSE, FALSE)) return NULL;
    if (!AddLabelled(grp, "Copy", cyCopyMode, FALSE, FALSE)) return NULL;

    return VGroup,
        Child, (ULONG)(TextObject, MUIA_Text_Contents, (ULONG)intro, MUIA_Text_SetMin, FALSE, End),
        Child, (ULONG)grp,
        Child, (ULONG)txConf,
    End;
}

static Object *BuildSimplePage(void)
{
    rdSimple = RadioObject,
        MUIA_Radio_Entries, (ULONG)simpleEntries,
        MUIA_Radio_Active, prefSimple,
        MUIA_Group_Horiz, TRUE,
        MUIA_CycleChain, 1,
        MUIA_ShortHelp, (ULONG)"All builds every collection in your settings.\n"
                               "RTG, AGA and ECS build just that one.",
    End;
    txSimpleCmd = TextObject, TextFrame, MUIA_Background, MUII_TextBack,
        MUIA_Text_SetMin, FALSE, MUIA_Text_Contents, (ULONG)"", End;
    if (!rdSimple || !txSimpleCmd) return NULL;
    return VGroup,
        Child, (ULONG)VSpace(0),
        Child, (ULONG)(HGroup, GroupFrameT("Build"),
            Child, (ULONG)HSpace(0),
            Child, (ULONG)rdSimple,
            Child, (ULONG)HSpace(0),
        End),
        Child, (ULONG)(TextObject, MUIA_Text_PreParse, (ULONG)"\33c", MUIA_Text_SetMin, FALSE,
            MUIA_Text_Contents, (ULONG)"Downloads what is new, then builds with the settings in\n"
                                       "retroplay.conf. For everything else, choose Advanced.",
        End),
        Child, (ULONG)txSimpleCmd,
        Child, (ULONG)VSpace(0),
    End;
}

static BOOL BuildApp(void)
{
    Object *pgSimple, *pgTask, *pgColl, *pgArt, *pgDl, *pgSys, *pgA314, *popDest;

    pgSimple = BuildSimplePage();
    pgTask = Scrolled(BuildTaskPage());
    pgColl = Scrolled(BuildSettingsPage(PG_COLL));
    pgArt = Scrolled(BuildSettingsPage(PG_ART));
    pgDl = Scrolled(BuildSettingsPage(PG_DL));
    pgSys = Scrolled(BuildSettingsPage(PG_SYS));
    pgA314 = Scrolled(BuildA314Page());
    rdMode = RadioObject,
        MUIA_Radio_Entries, (ULONG)modeEntries,
        MUIA_Radio_Active, prefMode,
        MUIA_Group_Horiz, TRUE,
        MUIA_CycleChain, 1,
        MUIA_ShortHelp, (ULONG)"Simple: build with your settings.\nAdvanced: every task, option and setting.",
    End;
    chkCopyAfter = MakeCheck(prefCopyAfter ? TRUE : FALSE,
        "After a build that worked, copy the games to this drawer.\n"
        "What is copied is set on the A314 page.");
    popDest = MakePopDrawer(&strCopyDest, prefCopyDest, "Where the games go on the Amiga",
        "The drawer the games are copied into - your games drive or drawer.\n"
        "WHDLoad/, HD_Loaders/ and JST/ are made inside it.");
    lsLog = ListObject, ReadListFrame,
        MUIA_List_ConstructHook, MUIV_List_ConstructHook_String,
        MUIA_List_DestructHook, MUIV_List_DestructHook_String,
        MUIA_Font, MUIV_Font_Fixed,
    End;
    if (!pgSimple || !pgTask || !pgColl || !pgArt || !pgDl || !pgSys || !pgA314
        || !rdMode || !chkCopyAfter || !popDest || !lsLog) return FALSE;
    lvLog = ListviewObject,
        MUIA_Listview_Input, FALSE,
        MUIA_Listview_List, (ULONG)lsLog,
        MUIA_VertWeight, 150,
    End;
    txStatus = TextObject, TextFrame, MUIA_Background, MUII_TextBack,
        MUIA_Text_SetMin, FALSE, MUIA_Text_Contents, (ULONG)"Ready", End;
    btStart = SimpleButton("_Start");
    btStatus = SimpleButton("S_tatus");
    btDoctor = SimpleButton("Check set-_up");
    btCopy = SimpleButton("_Copy now");
    btStop = SimpleButton("Sto_p");
    btSave = SimpleButton("Sa_ve settings");
    if (!lvLog || !txStatus || !btStart || !btStatus || !btDoctor || !btCopy || !btStop || !btSave)
        return FALSE;
    xset(btStop, MUIA_ShortHelp, (ULONG)"Stops a copy to the Amiga. During a run, stops waiting for it\n"
                                        "(the Pi can't be interrupted from here; it carries on).");

    app = ApplicationObject,
        MUIA_Application_Title, (ULONG)"A314RetroplayGUI",
        MUIA_Application_Version, (ULONG)versionTag,
        MUIA_Application_Copyright, (ULONG)"(c) 2025-2026 Craziazkowboi and whdsync contributors",
        MUIA_Application_Author, (ULONG)"whdsync contributors",
        MUIA_Application_Description, (ULONG)"Runs whdsync on the Pi through an A314",
        MUIA_Application_Base, (ULONG)"A314RETRO",
        SubWindow, (ULONG)(win = WindowObject,
            MUIA_Window_Title, (ULONG)"whdsync " APP_RELEASE " - A314 Retroplay",
            MUIA_Window_ID, MAKE_ID('W','H','D','S'),
            WindowContents, (ULONG)(VGroup,
                Child, (ULONG)(HGroup,
                    Child, (ULONG)Label1("Mode"),
                    Child, (ULONG)rdMode,
                    Child, (ULONG)HSpace(0),
                End),
                Child, (ULONG)(grpPages = PageGroup,
                    Child, (ULONG)pgSimple,
                    Child, (ULONG)(RegisterGroup(registerTitles),
                        MUIA_Register_Frame, TRUE,
                        Child, (ULONG)pgTask,
                        Child, (ULONG)pgColl,
                        Child, (ULONG)pgArt,
                        Child, (ULONG)pgDl,
                        Child, (ULONG)pgSys,
                        Child, (ULONG)pgA314,
                    End),
                End),
                Child, (ULONG)(HGroup,
                    Child, (ULONG)chkCopyAfter,
                    Child, (ULONG)Label1("Copy the games to the Amiga, into"),
                    Child, (ULONG)popDest,
                End),
                Child, (ULONG)lvLog,
                Child, (ULONG)txStatus,
                Child, (ULONG)(HGroup, MUIA_Group_SameSize, TRUE,
                    Child, (ULONG)btStart,
                    Child, (ULONG)btStatus,
                    Child, (ULONG)btDoctor,
                    Child, (ULONG)btCopy,
                    Child, (ULONG)btStop,
                    Child, (ULONG)btSave,
                End),
            End),
        End),
    End;
    return app ? TRUE : FALSE;
}

static void Notify(Object *obj, ULONG attr, ULONG id)
{
    DoMethod(obj, MUIM_Notify, attr, MUIV_EveryTime, (ULONG)app, 2,
             MUIM_Application_ReturnID, id);
}

static void NotifyButton(Object *obj, ULONG id)
{
    DoMethod(obj, MUIM_Notify, MUIA_Pressed, FALSE, (ULONG)app, 2,
             MUIM_Application_ReturnID, id);
}

static void SetupNotifies(void)
{
    int i;
    DoMethod(win, MUIM_Notify, MUIA_Window_CloseRequest, TRUE, (ULONG)app, 2,
             MUIM_Application_ReturnID, MUIV_Application_ReturnID_Quit);
    DoMethod(rdMode, MUIM_Notify, MUIA_Radio_Active, MUIV_EveryTime, (ULONG)grpPages, 3,
             MUIM_Set, MUIA_Group_ActivePage, MUIV_TriggerValue);
    NotifyButton(btStart, ID_START);
    NotifyButton(btStatus, ID_STATUS);
    NotifyButton(btDoctor, ID_DOCTOR);
    NotifyButton(btCopy, ID_COPY);
    NotifyButton(btSave, ID_SAVE);
    /* Stop is noticed by polling, not by a return ID: during a copy the
       window is only serviced by MUIM_Application_InputBuffered, and
       return IDs would wait until the copy had finished. */
    DoMethod(btStop, MUIM_Notify, MUIA_Pressed, FALSE, MUIV_Notify_Self, 3,
             MUIM_Set, MUIA_UserData, 1);

    Notify(rdSimple, MUIA_Radio_Active, ID_REFRESH);
    Notify(rdTask, MUIA_Radio_Active, ID_REFRESH);
    Notify(cyVariant, MUIA_Cycle_Active, ID_REFRESH);
    Notify(strSet, MUIA_String_Contents, ID_REFRESH);
    Notify(cyFs, MUIA_Cycle_Active, ID_REFRESH);
    Notify(cyDetox, MUIA_Cycle_Active, ID_REFRESH);
    Notify(cyArt, MUIA_Cycle_Active, ID_REFRESH);
    Notify(cyDemoArt, MUIA_Cycle_Active, ID_REFRESH);
    Notify(slJobs, MUIA_Numeric_Value, ID_REFRESH);
    Notify(strDest, MUIA_String_Contents, ID_REFRESH);
    Notify(strPiCmd, MUIA_String_Contents, ID_REFRESH);
    Notify(strPiScripts, MUIA_String_Contents, ID_REFRESH);
    for (i = 0; i < O_COUNT; i++) Notify(chkOpt[i], MUIA_Selected, ID_REFRESH);
}

/* ================================================================== */
/* Start and finish                                                    */
/* ================================================================== */
static void Fail(const char *text)
{
    struct EasyStruct es;
    ULONG args[1];
    if (!IntuitionBase) return;
    args[0] = (ULONG)text;
    es.es_StructSize = sizeof es;
    es.es_Flags = 0;
    es.es_Title = (UBYTE *)"A314 Retroplay";
    es.es_TextFormat = (UBYTE *)"%s";
    es.es_GadgetFormat = (UBYTE *)"OK";
    EasyRequestArgs(NULL, &es, NULL, args);
}

static BOOL ConfirmQuit(void)
{
    if (runState == 1) {
        return Request("_Quit|_Cancel",
            "A run is still going on the Pi. It carries on there after\n"
            "this window closes, but its output won't be shown here.") == 1 ? TRUE : FALSE;
    }
    if (AnySettingChanged()) {
        long r = Request("_Save and quit|_Quit without saving|_Cancel",
                         "Some settings have changed but are not saved yet.");
        if (r == 1) return SaveConf();
        return r == 2 ? TRUE : FALSE;
    }
    return TRUE;
}

int main(void)
{
    ULONG sigs = 0, timerSig, got;
    LONG id;
    BOOL done = FALSE;
    int rc = 0;

    IntuitionBase = (struct IntuitionBase *)OpenLibrary((STRPTR)"intuition.library", 37);
    if (!IntuitionBase) return 20;                      /* needs 2.04 */
    MUIMasterBase = OpenLibrary((STRPTR)MUIMASTER_NAME, 19);
    if (!MUIMasterBase) {
        Fail("This program needs MUI 3.8 or later\n(muimaster.library version 19).");
        CloseLibrary((struct Library *)IntuitionBase);
        return 20;
    }

    LoadPrefs();
    LoadConf();
    if (!SetupTimer()) {
        Fail("Could not open timer.device.");
        rc = 20;
    } else if (!BuildApp()) {
        Fail("Could not create the window.\nIs MUI 3.8 or later installed?");
        rc = 20;
    } else {
        SetupNotifies();
        xset(grpPages, MUIA_Group_ActivePage, prefMode);
        RefreshTaskPage();
        UpdateButtons();
        xset(win, MUIA_Window_Open, TRUE);
        if (!xget(win, MUIA_Window_Open)) {
            Fail("Could not open the window - the screen may be too small.");
            rc = 20;
            done = TRUE;
        }
        AddLog("Ready. Choose what to build and press Start.");
        if (!confFound)
            AddLog("No retroplay.conf in this program's folder: the built-in defaults are shown.");
        if (oldPrefsMigrated)
            AddLog("Your WHDLoad drawer from the previous version is now the copy destination.");
        if (!prefsFound)
            AddLog("First time? Check the A314 page in Advanced mode: how to reach the Pi.");

        timerSig = 1UL << timerPort->mp_SigBit;
        while (!done) {
            id = (LONG)DoMethod(app, MUIM_Application_NewInput, (ULONG)&sigs);
            switch (id) {
            case MUIV_Application_ReturnID_Quit:
                if (ConfirmQuit()) done = TRUE;
                break;
            case ID_START:   if (runState == 0) DoStart(); break;
            case ID_STATUS:  if (runState == 0) DoInfo(CMD_STATUS); break;
            case ID_DOCTOR:  if (runState == 0) DoInfo(CMD_DOCTOR); break;
            case ID_COPY:
                if (runState == 0) DoCopy(CopySuffixFor(xget(rdMode, MUIA_Radio_Active) == 0));
                break;
            case ID_SAVE:    DoSave(); break;
            case ID_REFRESH: RefreshTaskPage(); break;
            }
            if (timerPending && CheckIO((struct IORequest *)timerReq)) {
                WaitIO((struct IORequest *)timerReq);
                timerPending = FALSE;
                PollRun();
                if (runState == 1) StartTimer();
            }
            if (!done && sigs) {
                got = Wait(sigs | timerSig | SIGBREAKF_CTRL_C);
                if (got & SIGBREAKF_CTRL_C) done = TRUE;
                sigs = got & ~timerSig;
            }
        }
        SavePrefs();
        if (runState == 1 && runOut) { Close(runOut); runOut = 0; }
        xset(win, MUIA_Window_Open, FALSE);
    }
    if (app) MUI_DisposeObject(app);
    CleanupTimer();
    CloseLibrary(MUIMasterBase);
    CloseLibrary((struct Library *)IntuitionBase);
    return rc;
}
