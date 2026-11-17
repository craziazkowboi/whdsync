#ifndef AMIGA_STUB_H
#define AMIGA_STUB_H
/* Stand-in Amiga and MUI declarations, so tests/run_tests.sh can compile
   a314_retroplay_gui.c with the build machine's own C compiler.

   NOT the real headers. The types and function signatures follow the NDK
   3.x autodocs and MUI 3.8's mui.h, and the shortcut macros (VGroup, End,
   Child...) are written the way mui.h writes them, so a syntax slip, an
   unbalanced macro, a C99-ism or a wrong argument type shows up here. The
   numbers (attribute IDs, flags) are placeholders: nothing compiled against
   this file can run on an Amiga. The real build uses the NDK and the MUI
   developer includes. */
typedef unsigned long ULONG; typedef long LONG; typedef unsigned short UWORD; typedef short WORD;
typedef unsigned char UBYTE; typedef signed char BYTE; typedef short BOOL; typedef void *APTR;
typedef unsigned char *STRPTR; typedef long BPTR; typedef ULONG Tag; typedef LONG LONGBITS;
typedef ULONG Object;
#define TRUE 1
#define FALSE 0
#ifndef NULL
#define NULL ((void*)0)
#endif
struct TagItem { Tag ti_Tag; ULONG ti_Data; };
#define TAG_DONE 0UL
#define TAG_END 0UL
#define TAG_USER 0x80000000UL
struct Node { struct Node *ln_Succ, *ln_Pred; UBYTE ln_Type; BYTE ln_Pri; char *ln_Name; };
struct MinNode { struct MinNode *mln_Succ, *mln_Pred; };
struct Message { struct Node mn_Node; struct MsgPort *mn_ReplyPort; UWORD mn_Length; };
struct MsgPort { struct Node mp_Node; UBYTE mp_Flags; UBYTE mp_SigBit; void *mp_SigTask; };
struct Library { struct Node lib_Node; };
struct IORequest { struct Message io_Message; void *io_Device; void *io_Unit; UWORD io_Command; UBYTE io_Flags; BYTE io_Error; };
struct timeval { ULONG tv_secs; ULONG tv_micro; };
struct timerequest { struct IORequest tr_node; struct timeval tr_time; };
#define TR_ADDREQUEST 9
#define UNIT_VBLANK 1
#define TIMERNAME "timer.device"
#define MEMF_ANY 0L
#define MEMF_CLEAR (1L<<16)
#define SIGBREAKF_CTRL_C (1L<<12)
struct DateStamp { LONG ds_Days; LONG ds_Minute; LONG ds_Tick; };
#define TICKS_PER_SECOND 50
struct FileInfoBlock { LONG fib_DiskKey; LONG fib_DirEntryType; char fib_FileName[108]; LONG fib_Protection;
  LONG fib_EntryType; LONG fib_Size; LONG fib_NumBlocks; struct DateStamp fib_Date; char fib_Comment[80]; };
#define MODE_OLDFILE 1005
#define MODE_NEWFILE 1006
#define MODE_READWRITE 1004
#define ACCESS_READ -2
#define DOS_FIB 2
#define SYS_Dummy (TAG_USER + 32)
#define SYS_Input (SYS_Dummy + 1)
#define SYS_Output (SYS_Dummy + 2)
#define SYS_Asynch (SYS_Dummy + 3)
#define NP_StackSize (TAG_USER + 1000 + 11)
struct IntuitionBase { struct Library LibNode; };
struct EasyStruct { ULONG es_StructSize; ULONG es_Flags; UBYTE *es_Title; UBYTE *es_TextFormat; UBYTE *es_GadgetFormat; };
#define ASL_FileRequest 0
#define ASLFR_TitleText (TAG_USER + 0x80000 + 1)
#define ASLFR_DrawersOnly (TAG_USER + 0x80000 + 47)
/* exec */
struct Library *OpenLibrary(STRPTR, ULONG); void CloseLibrary(struct Library *);
APTR AllocVec(ULONG, ULONG); void FreeVec(APTR);
struct MsgPort *CreateMsgPort(void); void DeleteMsgPort(struct MsgPort *);
APTR CreateIORequest(struct MsgPort *, ULONG); void DeleteIORequest(APTR);
BYTE OpenDevice(STRPTR, ULONG, struct IORequest *, ULONG); void CloseDevice(struct IORequest *);
void SendIO(struct IORequest *); struct IORequest *CheckIO(struct IORequest *); BYTE WaitIO(struct IORequest *); void AbortIO(struct IORequest *);
ULONG Wait(ULONG);
/* dos */
BPTR Open(STRPTR, LONG); LONG Close(BPTR); LONG Read(BPTR, APTR, LONG); LONG Write(BPTR, APTR, LONG);
STRPTR FGets(BPTR, STRPTR, ULONG); LONG FPuts(BPTR, STRPTR);
BPTR Lock(STRPTR, LONG); void UnLock(BPTR); LONG Examine(BPTR, struct FileInfoBlock *); LONG ExNext(BPTR, struct FileInfoBlock *);
BPTR CreateDir(STRPTR); LONG DeleteFile(STRPTR); LONG Rename(STRPTR, STRPTR);
LONG SetProtection(STRPTR, LONG); LONG SetFileDate(STRPTR, struct DateStamp *); LONG SetComment(STRPTR, STRPTR);
APTR AllocDosObject(ULONG, struct TagItem *); void FreeDosObject(ULONG, APTR);
LONG SystemTagList(STRPTR, struct TagItem *); struct DateStamp *DateStamp(struct DateStamp *);
/* intuition */
ULONG GetAttr(ULONG, Object *, ULONG *); ULONG SetAttrs(APTR, ULONG, ...);
LONG EasyRequestArgs(void *, struct EasyStruct *, ULONG *, APTR);
/* amiga.lib */
ULONG DoMethod(Object *, ULONG, ...);
/* muimaster */
#define MUIMASTER_NAME "muimaster.library"
Object *MUI_NewObject(char *, Tag, ...); Object *MUI_MakeObject(LONG, ...); void MUI_DisposeObject(Object *);
LONG MUI_RequestA(APTR, APTR, LONGBITS, char *, char *, char *, APTR);
/* MUI 3.8 names used (values are placeholders) */
#define MUIC_Application "Application.mui"
#define MUIC_Window "Window.mui"
#define MUIC_Group "Group.mui"
#define MUIC_Register "Register.mui"
#define MUIC_Virtgroup "Virtgroup.mui"
#define MUIC_Scrollgroup "Scrollgroup.mui"
#define MUIC_Image "Image.mui"
#define MUIC_Cycle "Cycle.mui"
#define MUIC_Radio "Radio.mui"
#define MUIC_Slider "Slider.mui"
#define MUIC_String "String.mui"
#define MUIC_Text "Text.mui"
#define MUIC_List "List.mui"
#define MUIC_Listview "Listview.mui"
#define MUIC_Popasl "Popasl.mui"
enum { MUIO_Label = 1, MUIO_Button = 2, MUIO_PopButton = 8, MUIO_HSpace = 9, MUIO_VSpace = 10 };
#define MUIO_Label_SingleFrame (1<<8)
#define MUIO_Label_DoubleFrame (1<<9)
#define MUIO_Label_LeftAligned (1<<10)
enum { MUIA_Application_Title = 0x1000, MUIA_Application_Version, MUIA_Application_Copyright,
 MUIA_Application_Author, MUIA_Application_Description, MUIA_Application_Base, MUIA_Application_Window,
 MUIA_Window_Title, MUIA_Window_ID, MUIA_Window_RootObject, MUIA_Window_Open, MUIA_Window_CloseRequest,
 MUIA_Group_Child, MUIA_Group_Horiz, MUIA_Group_Columns, MUIA_Group_PageMode, MUIA_Group_ActivePage, MUIA_Group_SameSize,
 MUIA_Register_Titles, MUIA_Register_Frame, MUIA_Frame, MUIA_FrameTitle, MUIA_Background,
 MUIA_InputMode, MUIA_Image_Spec, MUIA_Image_FreeVert, MUIA_Selected, MUIA_ShowSelState, MUIA_CycleChain, MUIA_ShortHelp,
 MUIA_Cycle_Entries, MUIA_Cycle_Active, MUIA_Radio_Entries, MUIA_Radio_Active,
 MUIA_Numeric_Min, MUIA_Numeric_Max, MUIA_Numeric_Value, MUIA_Numeric_Format,
 MUIA_String_MaxLen, MUIA_String_Contents, MUIA_Popstring_String, MUIA_Popstring_Button, MUIA_Popasl_Type,
 MUIA_Scrollgroup_FreeHoriz, MUIA_Scrollgroup_Contents, MUIA_Text_Contents, MUIA_Text_SetMin, MUIA_Text_PreParse,
 MUIA_List_ConstructHook, MUIA_List_DestructHook, MUIA_List_Entries, MUIA_Font,
 MUIA_Listview_Input, MUIA_Listview_List, MUIA_VertWeight, MUIA_Disabled, MUIA_Pressed, MUIA_UserData };
enum { MUIM_Application_NewInput = 0x2000, MUIM_Application_InputBuffered, MUIM_Application_ReturnID,
 MUIM_Notify, MUIM_Set, MUIM_List_InsertSingle, MUIM_List_Remove, MUIM_List_Jump, OM_ADDMEMBER };
#define MUIV_Frame_ImageButton 3
#define MUIV_Frame_String 7
#define MUIV_Frame_Text 9
#define MUIV_Frame_ReadList 6
#define MUIV_Frame_Group 9
#define MUIV_Frame_Virtual 12
#define MUIV_InputMode_Toggle 2
#define MUII_CheckMark 15
#define MUII_ButtonBack 2
#define MUII_TextBack 4
#define MUII_GroupBack 6
#define MUII_PopDrawer 20
#define MUIV_List_ConstructHook_String ((APTR)-1)
#define MUIV_List_DestructHook_String ((APTR)-1)
#define MUIV_List_Insert_Bottom (-3)
#define MUIV_List_Remove_First 0
#define MUIV_Font_Fixed (-5)
#define MUIV_EveryTime 0x49893131
#define MUIV_TriggerValue 0x49893131
#define MUIV_Notify_Self 1
#define MUIV_Application_ReturnID_Quit -1
/* the mui.h shortcut macros, as MUI 3.8 defines them */
#define End TAG_DONE)
#define Child MUIA_Group_Child
#define SubWindow MUIA_Application_Window
#define WindowContents MUIA_Window_RootObject
#define ApplicationObject MUI_NewObject(MUIC_Application
#define WindowObject MUI_NewObject(MUIC_Window
#define ImageObject MUI_NewObject(MUIC_Image
#define CycleObject MUI_NewObject(MUIC_Cycle
#define RadioObject MUI_NewObject(MUIC_Radio
#define SliderObject MUI_NewObject(MUIC_Slider
#define StringObject MUI_NewObject(MUIC_String
#define TextObject MUI_NewObject(MUIC_Text
#define ListObject MUI_NewObject(MUIC_List
#define ListviewObject MUI_NewObject(MUIC_Listview
#define PopaslObject MUI_NewObject(MUIC_Popasl
#define ScrollgroupObject MUI_NewObject(MUIC_Scrollgroup
#define VirtgroupObject MUI_NewObject(MUIC_Virtgroup
#define VGroup MUI_NewObject(MUIC_Group
#define HGroup MUI_NewObject(MUIC_Group,MUIA_Group_Horiz,TRUE
#define ColGroup(cols) MUI_NewObject(MUIC_Group,MUIA_Group_Columns,(cols)
#define PageGroup MUI_NewObject(MUIC_Group,MUIA_Group_PageMode,TRUE
#define RegisterGroup(t) MUI_NewObject(MUIC_Register,MUIA_Register_Titles,(t)
#define ImageButtonFrame MUIA_Frame, MUIV_Frame_ImageButton
#define StringFrame MUIA_Frame, MUIV_Frame_String
#define TextFrame MUIA_Frame, MUIV_Frame_Text
#define ReadListFrame MUIA_Frame, MUIV_Frame_ReadList
#define VirtualFrame MUIA_Frame, MUIV_Frame_Virtual
#define GroupFrameT(s) MUIA_Frame, MUIV_Frame_Group, MUIA_FrameTitle, s, MUIA_Background, MUII_GroupBack
#define Label1(label) MUI_MakeObject(MUIO_Label,label,MUIO_Label_SingleFrame)
#define Label2(label) MUI_MakeObject(MUIO_Label,label,MUIO_Label_DoubleFrame)
#define LLabel1(label) MUI_MakeObject(MUIO_Label,label,MUIO_Label_SingleFrame|MUIO_Label_LeftAligned)
#define SimpleButton(label) MUI_MakeObject(MUIO_Button,label)
#define PopButton(img) MUI_MakeObject(MUIO_PopButton,img)
#define HSpace(x) MUI_MakeObject(MUIO_HSpace,x)
#define VSpace(x) MUI_MakeObject(MUIO_VSpace,x)
#endif
