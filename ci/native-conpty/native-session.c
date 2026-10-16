/* Private owned ConPTY session composition. No native execution qualification.
 * All worker and pipe authority remains reachable on bounded teardown failure. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include "native-channel.c"
typedef HANDLE private_hpc;
typedef HRESULT (WINAPI *create_console)(COORD,HANDLE,HANDLE,DWORD,private_hpc*);
typedef HRESULT (WINAPI *resize_console)(private_hpc,COORD);
typedef void (WINAPI *close_console)(private_hpc);
#define PRIVATE_PSEUDOCONSOLE_ATTRIBUTE 0x00020016
struct pty_native_session {
  struct pty_channel *channel;
  private_hpc console;
  close_console close_api;
  resize_console resize_api;
  HANDLE process, process_thread, teardown;
  HANDLE child_input, child_output, host_input, host_output;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes;
  int attributes_initialized;
  DWORD pid, exit_code;
  int reaped;
  short cols,rows;
};
static DWORD WINAPI close_worker(void *argument) {
  struct pty_native_session *s=argument;
  s->close_api(s->console);
  return 0;
}
/* Return zero retains *owner unchanged, including exact worker handles. */
int pty_session_close(struct pty_native_session **owner,DWORD timeout,DWORD *error) {
  struct pty_native_session *s=*owner;
  if(!s){*error=0;return 1;}
  if(!close_slot(&s->child_input,error) || !close_slot(&s->child_output,error))return 0;
  if(s->attributes) {
    if(s->attributes_initialized){DeleteProcThreadAttributeList(s->attributes);s->attributes_initialized=0;}
    if(!HeapFree(GetProcessHeap(),0,s->attributes)){*error=GetLastError();return 0;}
    s->attributes=NULL;
  }
  ULONGLONG start=GetTickCount64();
  if(s->console && !s->teardown) {
    pty_channel_begin_teardown(s->channel);
    s->teardown=CreateThread(NULL,0,close_worker,s,0,NULL);
    if(!s->teardown){*error=GetLastError();return 0;}
  }
  if(s->teardown) {
    DWORD result=WaitForSingleObject(s->teardown,timeout);
    if(result!=WAIT_OBJECT_0){*error=result==WAIT_TIMEOUT?ERROR_TIMEOUT:GetLastError();return 0;}
    if(!close_slot(&s->teardown,error))return 0;
    s->console=NULL;
  }
  ULONGLONG elapsed=GetTickCount64()-start;
  DWORD left=timeout==INFINITE?INFINITE:(elapsed>=timeout?0:(DWORD)(timeout-elapsed));
  if(s->channel && !s->console && !s->teardown) {
    pty_channel_begin_teardown(s->channel);
    if(s->channel->reader)CancelSynchronousIo(s->channel->reader);
  }
  if(s->channel && !pty_channel_release(&s->channel,left,error))return 0;
  if(s->process && !s->reaped) {
    elapsed=GetTickCount64()-start;
    left=timeout==INFINITE?INFINITE:(elapsed>=timeout?0:(DWORD)(timeout-elapsed));
    DWORD result=WaitForSingleObject(s->process,left);
    if(result!=WAIT_OBJECT_0){*error=result==WAIT_TIMEOUT?ERROR_TIMEOUT:GetLastError();return 0;}
    if(!GetExitCodeProcess(s->process,&s->exit_code)){*error=GetLastError();return 0;}
    s->reaped=1;
  }
  if(!close_slot(&s->process_thread,error) || !close_slot(&s->process,error) ||
     !close_slot(&s->host_input,error) || !close_slot(&s->host_output,error))return 0;
  free(s);*owner=NULL;*error=0;return 1;
}
/* Caller supplies a mutable properly quoted command line and explicit UTF16
 * environment block. No ambient command-shell lookup or environment alias. */
int pty_session_spawn(const wchar_t *application,wchar_t *command,
 const wchar_t *environment,const wchar_t *cwd,short cols,short rows,
 struct pty_native_session **owner,DWORD *error) {
  *owner=NULL;*error=0;
  if(!application || !*application || !environment || cols<=0 || rows<=0){*error=ERROR_INVALID_PARAMETER;return 0;}
  HMODULE kernel=GetModuleHandleW(L"kernel32.dll");
  create_console create=NULL;close_console close=NULL;resize_console resize=NULL;
  _Static_assert(sizeof(FARPROC)==sizeof(create), "Win32 function pointer size");
  _Static_assert(sizeof(FARPROC)==sizeof(close), "Win32 function pointer size");
  _Static_assert(sizeof(FARPROC)==sizeof(resize), "Win32 function pointer size");
  FARPROC symbol=GetProcAddress(kernel,"CreatePseudoConsole");memcpy(&create,&symbol,sizeof create);
  symbol=GetProcAddress(kernel,"ClosePseudoConsole");memcpy(&close,&symbol,sizeof close);
  symbol=GetProcAddress(kernel,"ResizePseudoConsole");memcpy(&resize,&symbol,sizeof resize);
  if(!create || !close || !resize){*error=ERROR_NOT_SUPPORTED;return 0;}
  struct pty_native_session *s=calloc(1,sizeof *s);
  if(!s){*error=ERROR_NOT_ENOUGH_MEMORY;return 0;}
  *owner=s;s->close_api=close;s->resize_api=resize;

  if(!CreatePipe(&s->child_input,&s->host_input,NULL,0))goto fail;
  if(!CreatePipe(&s->host_output,&s->child_output,NULL,0))goto fail;
  struct pty_channel *unresolved=NULL;
  s->channel=pty_channel_create(s->host_input,s->host_output,error,&unresolved);
  if(!s->channel) {
    if(unresolved) { s->channel=unresolved;unresolved->owns_pipes=1;s->host_input=NULL;s->host_output=NULL; }
    goto fail_preserve_error;
  }
  s->host_input=NULL;s->host_output=NULL;
  COORD size={cols,rows};HRESULT hr=create(size,s->child_input,s->child_output,0,&s->console);
  if(FAILED(hr)){*error=(DWORD)hr;goto fail_preserve_error;}
  s->cols=cols;s->rows=rows;
  SIZE_T bytes=0;InitializeProcThreadAttributeList(NULL,1,0,&bytes);
  s->attributes=HeapAlloc(GetProcessHeap(),0,bytes);
  if(!s->attributes){*error=ERROR_NOT_ENOUGH_MEMORY;goto fail_preserve_error;}
  if(!InitializeProcThreadAttributeList(s->attributes,1,0,&bytes))goto fail;
  s->attributes_initialized=1;
  if(!UpdateProcThreadAttribute(s->attributes,0,PRIVATE_PSEUDOCONSOLE_ATTRIBUTE,
    s->console,sizeof s->console,NULL,NULL))goto fail;
  STARTUPINFOEXW startup={0};startup.StartupInfo.cb=sizeof startup;startup.lpAttributeList=s->attributes;
  PROCESS_INFORMATION process={0};
  if(!CreateProcessW(application,command,NULL,NULL,FALSE,
     EXTENDED_STARTUPINFO_PRESENT|CREATE_UNICODE_ENVIRONMENT,
     (void*)environment,cwd,&startup.StartupInfo,&process))goto fail;
  s->process=process.hProcess;s->pid=process.dwProcessId;s->process_thread=process.hThread;
  if(!close_slot(&s->process_thread,error) || !close_slot(&s->child_input,error) ||
     !close_slot(&s->child_output,error))return 0;
  DeleteProcThreadAttributeList(s->attributes);s->attributes_initialized=0;
  if(!HeapFree(GetProcessHeap(),0,s->attributes)){*error=GetLastError();return 0;}
  s->attributes=NULL;return 1;
fail:
  *error=GetLastError();
fail_preserve_error:
  /* Entire acquired state remains reachable at *owner. Explicit close performs
   * checked slot cleanup; a failed CloseHandle never erases its authority. */
  return 0;
}

int pty_session_resize(struct pty_native_session *s,short cols,short rows,DWORD *error) {
  if(!s || !s->console || s->teardown || cols<=0 || rows<=0){*error=ERROR_INVALID_PARAMETER;return 0;}
  COORD size={cols,rows};HRESULT result=s->resize_api(s->console,size);
  if(FAILED(result)){*error=(DWORD)result;return 0;}
  s->cols=cols;s->rows=rows;*error=0;return 1;
}
/* Zero is native failure; two is still running/timeout; one is exact exit.
 * Waiting never closes the master or discards unread output. */
int pty_session_wait(struct pty_native_session *s,DWORD timeout,DWORD *code,DWORD *error) {
  if(!s || !s->process){*error=ERROR_INVALID_HANDLE;return 0;}
  if(!s->reaped) {
    DWORD result=WaitForSingleObject(s->process,timeout);
    if(result==WAIT_TIMEOUT){*error=0;return 2;}
    if(result!=WAIT_OBJECT_0){*error=GetLastError();return 0;}
    if(!GetExitCodeProcess(s->process,&s->exit_code)){*error=GetLastError();return 0;}
    s->reaped=1;
  }
  *code=s->exit_code;*error=0;return 1;
}
