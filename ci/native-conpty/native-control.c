/* Genuine Win32 integration controls. No mocked OS, synthetic compiler or
 * successful native claim from cross-compilation. Failures retain owned state. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "native-session.c"
#define PAYLOAD (CAPACITY*4u+37u)
struct transfer {struct pty_channel *channel;HANDLE input,output;unsigned char *bytes;DWORD error;};
struct control_owner {
  struct transfer *transfer;
  struct pty_native_session *session;
  HANDLE host_input,host_output,echo,submit;
  wchar_t *command,*missing;
};
static DWORD WINAPI submit(void *arg) {
  struct transfer *t=arg;return pty_channel_write(t->channel,t->bytes,PAYLOAD,&t->error)?0:1;
}
static DWORD WINAPI echo(void *arg) {
  struct transfer *t=arg;unsigned char buffer[4096];DWORD remaining=PAYLOAD;
  while(remaining){DWORD count=0;
    if(!ReadFile(t->input,buffer,remaining<sizeof buffer?remaining:sizeof buffer,&count,NULL)||!count){t->error=GetLastError();return 1;}
    for(DWORD offset=0;offset<count;){DWORD done=0;
      if(!WriteFile(t->output,buffer+offset,count-offset,&done,NULL)||!done){t->error=GetLastError();return 2;}offset+=done;}
    remaining-=count;
  }
  DWORD error=0;
  if(!close_slot(&t->input,&error)||!close_slot(&t->output,&error)){t->error=error;return 3;}
  return 0;
}
static int join_owned(HANDLE *worker,DWORD timeout,int require_success) {
  DWORD code;
  if(WaitForSingleObject(*worker,timeout)!=WAIT_OBJECT_0)return 0;
  if(!GetExitCodeThread(*worker,&code)||(require_success && code))return 0;
  DWORD error=0;return close_slot(worker,&error);
}
static int transport(struct control_owner *owner) {
  owner->transfer=calloc(1,sizeof *owner->transfer);if(!owner->transfer)return 9;
  struct transfer *t=owner->transfer;
  if(!CreatePipe(&t->input,&owner->host_input,NULL,4096)||!CreatePipe(&owner->host_output,&t->output,NULL,4096))return 10;
  DWORD error=0;struct pty_channel *unresolved=NULL;
  t->channel=pty_channel_create(owner->host_input,owner->host_output,&error,&unresolved);
  if(!t->channel){t->channel=unresolved;return 11;}
  owner->host_input=NULL;owner->host_output=NULL;
  unsigned char emptyProbe[32];ULONGLONG start=GetTickCount64();
  if(pty_channel_read(t->channel,emptyProbe,sizeof emptyProbe,17,&error)!=-1 || error || GetTickCount64()-start<17)return 19;
  if(pty_channel_read(t->channel,emptyProbe,0,0,&error)!=0 || error)return 19;
  t->bytes=malloc(PAYLOAD);if(!t->bytes)return 12;
  for(size_t i=0;i<PAYLOAD;++i)t->bytes[i]=(unsigned char)((i*131u+17u)%256u);
  owner->echo=CreateThread(NULL,0,echo,t,0,NULL);
  owner->submit=CreateThread(NULL,0,submit,t,0,NULL);
  if(!owner->echo||!owner->submit)return 13;
  unsigned char bytes[4096];size_t offset=0;
  while(offset<PAYLOAD) {
    int count=pty_channel_read(t->channel,bytes,sizeof bytes,5000,&error);
    if(count<=0 || offset+(size_t)count>PAYLOAD)return 14;
    if(memcmp(bytes,t->bytes+offset,(size_t)count))return 15;
    offset+=(size_t)count;
  }
  if(!join_owned(&owner->submit,5000,1)||!join_owned(&owner->echo,5000,1))return 16;
  if(pty_channel_read(t->channel,bytes,sizeof bytes,5000,&error)!=0)return 17;
  pty_channel_begin_teardown(t->channel);
  if(!pty_channel_release(&t->channel,5000,&error))return 18;
  free(t->bytes);free(t);owner->transfer=NULL;return 0;
}
static int process(struct control_owner *owner,const wchar_t *child) {
  size_t n=wcslen(child);owner->command=malloc((n+16)*sizeof(wchar_t));if(!owner->command)return 20;
  swprintf(owner->command,n+16,L"\"%ls\" exit17",child);
  /* Explicit empty environment is valid and cannot inherit unrelated handles. */
  const wchar_t environment[2]={0,0};DWORD error=0,code=0;
  if(!pty_session_spawn(child,owner->command,environment,NULL,80,24,&owner->session,&error))return 21;
  free(owner->command);owner->command=NULL;
  if(pty_session_wait(owner->session,5000,&code,&error)!=1 || code!=17)return 22;
  if(!pty_session_close(&owner->session,5000,&error)||owner->session)return 23;
  if(!pty_session_close(&owner->session,5000,&error))return 24;
  owner->missing=malloc((n+32)*sizeof(wchar_t));if(!owner->missing)return 25;
  swprintf(owner->missing,n+32,L"%ls.deliberately-absent",child);
  if(GetFileAttributesW(owner->missing)!=INVALID_FILE_ATTRIBUTES)return 25;
  if(pty_session_spawn(owner->missing,owner->missing,environment,NULL,80,24,&owner->session,&error))return 25;
  if(error!=ERROR_FILE_NOT_FOUND && error!=ERROR_PATH_NOT_FOUND)return 26;
  if(!pty_session_close(&owner->session,5000,&error)||owner->session)return 27;
  free(owner->missing);owner->missing=NULL;return 0;
}

static int cleanup(struct control_owner *owner,DWORD *error) {
  struct transfer *t=owner->transfer;
  if(t) {
    if(t->channel)pty_channel_begin_teardown(t->channel);
    if(owner->echo)CancelSynchronousIo(owner->echo);
    if(t->channel && t->channel->reader)CancelSynchronousIo(t->channel->reader);
    /* These exact held handles own all native callbacks referencing t. */
    if(owner->submit && !join_owned(&owner->submit,5000,0)){*error=ERROR_TIMEOUT;return 0;}
    if(owner->echo && !join_owned(&owner->echo,5000,0)){*error=ERROR_TIMEOUT;return 0;}
    if(t->channel && !pty_channel_release(&t->channel,5000,error))return 0;
    if(!close_slot(&t->input,error)||!close_slot(&t->output,error))return 0;
    free(t->bytes);free(t);owner->transfer=NULL;
  }
  if(!close_slot(&owner->host_input,error)||!close_slot(&owner->host_output,error))return 0;
  if(owner->session && !pty_session_close(&owner->session,5000,error))return 0;
  free(owner->command);owner->command=NULL;free(owner->missing);owner->missing=NULL;
  return 1;
}
static void report_worker(const char *role,HANDLE worker) {
  if(!worker)return;
  FILETIME birth,exit,kernel,user;
  if(!GetThreadTimes(worker,&birth,&exit,&kernel,&user)) {
    fprintf(stderr,"unresolved_worker role=%s identity_error=%lu\n",role,GetLastError());return;
  }
  fprintf(stderr,"unresolved_worker role=%s tid=%lu birth=%lu:%lu state=%lu\n",role,
    GetThreadId(worker),birth.dwHighDateTime,birth.dwLowDateTime,WaitForSingleObject(worker,0));
}
static void report_owned(struct control_owner *owner,DWORD error) {
  fprintf(stderr,"native_control_unresolved owner_pid=%lu error=%lu\n",GetCurrentProcessId(),error);
  report_worker("echo",owner->echo);report_worker("submit",owner->submit);
  if(owner->transfer && owner->transfer->channel) {
    report_worker("channel-reader",owner->transfer->channel->reader);
    report_worker("channel-writer",owner->transfer->channel->writer);
  }
  if(owner->session) {
    report_worker("console-close",owner->session->teardown);
    FILETIME birth,exit,kernel,user;
    if(owner->session->process && GetProcessTimes(owner->session->process,&birth,&exit,&kernel,&user))
      fprintf(stderr,"owned_child pid=%lu birth=%lu:%lu reaped=%d\n",owner->session->pid,birth.dwHighDateTime,birth.dwLowDateTime,owner->session->reaped);
    else fprintf(stderr,"owned_child pid=%lu identity_error=%lu reaped=%d\n",owner->session->pid,GetLastError(),owner->session->reaped);
  }
  /* The supervising native controller owns this process and raw record.
   * No cleanup success is reported, and unresolved heap state is not freed. */
}
int wmain(int argc,wchar_t **argv) {
  if(argc!=2)return 2;
  struct control_owner *owner=calloc(1,sizeof *owner);if(!owner)return 3;
  DWORD before,after,error=0;if(!GetProcessHandleCount(GetCurrentProcess(),&before))return 3;
  int result=transport(owner);if(!result)result=process(owner,argv[1]);
  if(!cleanup(owner,&error)){report_owned(owner,error);return 30;}
  free(owner);
  if(result){fprintf(stderr,"Native ConPTY control failed boundary=%d\n",result);return result;}
  if(!GetProcessHandleCount(GetCurrentProcess(),&after)||after!=before)return 4;
  puts("native_transport_exact_bytes_conpty_exit_partial_launch_handles_ok");return 0;
}
