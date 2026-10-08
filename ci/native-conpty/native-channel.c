/* Private Win32 transport slice; no Nim runtime callbacks, mocks or native
 * acceptance claim. Own only supplied host pipe handles. A timeout retains
 * the capsule and all live worker authority; never free a live worker. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define CAPACITY 65536u
struct pty_channel {
  HANDLE input, output, writer, reader;
  HANDLE read_changed, write_changed, input_work, output_space;
  CRITICAL_SECTION lock, submit;
  unsigned char incoming[CAPACITY], outgoing[CAPACITY];
  size_t in_head, in_count, out_head, out_count;
  uint64_t submitted, transferred;
  DWORD input_error, output_error;
  int stopping, drain, eof, owns_pipes, lock_ready, submit_ready;
};
static int close_slot(HANDLE *slot,DWORD *error) {
  if(!*slot)return 1;
  if(!CloseHandle(*slot)){*error=GetLastError();return 0;}
  *slot=NULL;return 1;
}
static void changed(struct pty_channel *c) {
  if(c->read_changed)SetEvent(c->read_changed);
  if(c->write_changed)SetEvent(c->write_changed);
}
static DWORD WINAPI reader(void *arg) {
  struct pty_channel *c = arg;
  unsigned char bytes[4096]; DWORD count, error;
  for (;;) {
    if (!ReadFile(c->output, bytes, sizeof bytes, &count, NULL)) {
      error = GetLastError(); EnterCriticalSection(&c->lock);
      if (error != ERROR_BROKEN_PIPE && error != ERROR_OPERATION_ABORTED)
        c->output_error = error;
      c->eof = 1; changed(c); LeaveCriticalSection(&c->lock); return 0;
    }
    if (!count) { EnterCriticalSection(&c->lock); c->eof = 1;
      changed(c); LeaveCriticalSection(&c->lock); return 0; }
    for (DWORD i=0; i<count;) {
      EnterCriticalSection(&c->lock);
      if (c->drain) { LeaveCriticalSection(&c->lock); break; }
      while (i<count && c->out_count<CAPACITY) {
        c->outgoing[(c->out_head+c->out_count)%CAPACITY]=bytes[i++];
        ++c->out_count;
      }
      changed(c);
      if (i<count) ResetEvent(c->output_space);
      LeaveCriticalSection(&c->lock);
      if (i<count) WaitForSingleObject(c->output_space, INFINITE);
    }
  }
}
static DWORD WINAPI writer(void *arg) {
  struct pty_channel *c=arg;
  unsigned char bytes[4096];
  for (;;) {
    EnterCriticalSection(&c->lock);
    if (c->stopping) { LeaveCriticalSection(&c->lock); return 0; }
    size_t count=c->in_count<sizeof bytes?c->in_count:sizeof bytes;
    for(size_t i=0;i<count;++i) bytes[i]=c->incoming[(c->in_head+i)%CAPACITY];
    if (!count) ResetEvent(c->input_work);
    LeaveCriticalSection(&c->lock);
    if (!count) { WaitForSingleObject(c->input_work,INFINITE); continue; }
    DWORD done=0;
    if (!WriteFile(c->input,bytes,(DWORD)count,&done,NULL) || !done) {
      DWORD error=GetLastError(); if(!error) error=ERROR_WRITE_FAULT;
      EnterCriticalSection(&c->lock); c->input_error=error; changed(c);
      LeaveCriticalSection(&c->lock); return 0;
    }
    EnterCriticalSection(&c->lock);
    c->in_head=(c->in_head+done)%CAPACITY; c->in_count-=done;
    c->transferred+=done; changed(c); LeaveCriticalSection(&c->lock);
  }
}
/* If *unresolved is nonnull on failure, the capsule BORROWS supplied pipes:
 * caller cannot close/reuse them until exact worker termination and release.
 * Construction transfers host pipes only on success. Failure closes exact
 * acquired events/threads; caller pipes remain caller-owned. */
struct pty_channel *pty_channel_create(HANDLE input,HANDLE output,DWORD *error,struct pty_channel **unresolved) {
  *unresolved=NULL;
  struct pty_channel *c=calloc(1,sizeof *c); if(!c){*error=ERROR_NOT_ENOUGH_MEMORY;return NULL;}
  c->input=input;c->output=output;
  if(!InitializeCriticalSectionEx(&c->lock,0,0))goto fail;c->lock_ready=1;
  if(!InitializeCriticalSectionEx(&c->submit,0,0))goto fail;c->submit_ready=1;
  c->read_changed=CreateEventW(NULL,TRUE,FALSE,NULL);if(!c->read_changed)goto fail;
  c->write_changed=CreateEventW(NULL,TRUE,FALSE,NULL);if(!c->write_changed)goto fail;
  c->input_work=CreateEventW(NULL,TRUE,FALSE,NULL);if(!c->input_work)goto fail;
  c->output_space=CreateEventW(NULL,TRUE,FALSE,NULL);if(!c->output_space)goto fail;
  c->reader=CreateThread(NULL,0,reader,c,0,NULL); if(!c->reader) goto fail;
  c->writer=CreateThread(NULL,0,writer,c,0,NULL); if(!c->writer) goto fail;
  c->owns_pipes=1; return c;
fail:
  *error=GetLastError();
  if(c->reader) {
    CancelSynchronousIo(c->reader);
    /* Native launch-failure cleanup is not yet qualified. Preserve capsule
     * if the OS doesn't complete cancellation, rather than freeing live state. */
    if(WaitForSingleObject(c->reader,5000)!=WAIT_OBJECT_0) {
      *unresolved=c; return NULL;
    }
    if(!close_slot(&c->reader,error)){*unresolved=c;return NULL;}
  }
  if(!close_slot(&c->read_changed,error) || !close_slot(&c->write_changed,error) ||
     !close_slot(&c->input_work,error) || !close_slot(&c->output_space,error)) {
    *unresolved=c; return NULL;
  }
  if(c->submit_ready)DeleteCriticalSection(&c->submit);
  if(c->lock_ready)DeleteCriticalSection(&c->lock); free(c); return NULL;
}

/* Return -1 only for timeout, zero only for EOF/zero-sized destination.
 * GetTickCount64 uses the monotonic system uptime clock. */
int pty_channel_read(struct pty_channel *c,void *dest,size_t size,DWORD timeout,DWORD *error) {
  ULONGLONG start=GetTickCount64(); *error=0; if(!size) return 0;
  for(;;) {
    EnterCriticalSection(&c->lock);
    size_t count=c->out_count<size?c->out_count:size;
    if(count) {
      for(size_t i=0;i<count;++i) ((unsigned char*)dest)[i]=c->outgoing[(c->out_head+i)%CAPACITY];
      c->out_head=(c->out_head+count)%CAPACITY; c->out_count-=count;
      SetEvent(c->output_space); LeaveCriticalSection(&c->lock); return (int)count;
    }
    if(c->output_error){*error=c->output_error;LeaveCriticalSection(&c->lock);return -2;}
    if(c->eof){LeaveCriticalSection(&c->lock);return 0;}
    ResetEvent(c->read_changed); LeaveCriticalSection(&c->lock);
    ULONGLONG elapsed=GetTickCount64()-start;
    if(timeout!=INFINITE && elapsed>=timeout) return -1;
    DWORD left=timeout==INFINITE?INFINITE:(DWORD)(timeout-elapsed);
    DWORD result=WaitForSingleObject(c->read_changed,left);
    if(result==WAIT_TIMEOUT) return -1;
    if(result!=WAIT_OBJECT_0){*error=GetLastError();return -2;}
  }
}
/* Completion means actual WriteFile byte transfer, never ring acceptance. */
int pty_channel_write(struct pty_channel *c,const void *bytes,size_t size,DWORD *error) {
  *error=0; EnterCriticalSection(&c->submit); size_t accepted=0;
  EnterCriticalSection(&c->lock); uint64_t end=c->submitted+size;
  if(end<c->submitted){*error=ERROR_ARITHMETIC_OVERFLOW;goto failure;}
  while(accepted<size || c->transferred<end) {
    if(c->stopping || c->input_error){*error=c->input_error?c->input_error:ERROR_OPERATION_ABORTED;goto failure;}
    while(accepted<size && c->in_count<CAPACITY) {
      c->incoming[(c->in_head+c->in_count)%CAPACITY]=((const unsigned char*)bytes)[accepted++];
      ++c->in_count; ++c->submitted;
    }
    SetEvent(c->input_work);
    if(c->transferred>=end) break;
    ResetEvent(c->write_changed); LeaveCriticalSection(&c->lock);
    DWORD result=WaitForSingleObject(c->write_changed,INFINITE);
    EnterCriticalSection(&c->lock);
    if(result!=WAIT_OBJECT_0){*error=GetLastError();goto failure;}
  }
  LeaveCriticalSection(&c->lock);LeaveCriticalSection(&c->submit);return 1;
failure:
  LeaveCriticalSection(&c->lock);LeaveCriticalSection(&c->submit);return 0;
}
/* Called BEFORE owned ClosePseudoConsole. Buffered output may be discarded
 * only for explicit close; the worker keeps draining the kernel pipe. */
void pty_channel_begin_teardown(struct pty_channel *c) {
  if(!c->lock_ready)return;
  EnterCriticalSection(&c->lock);c->drain=1;c->stopping=1;
  if(c->output_space)SetEvent(c->output_space);
  if(c->input_work)SetEvent(c->input_work);changed(c);
  LeaveCriticalSection(&c->lock);if(c->writer)CancelSynchronousIo(c->writer);
}
/* Call only AFTER pseudoconsole closure has completed. Failure retains every
 * handle and the capsule. It does not convert a live worker into cleanup. */
int pty_channel_release(struct pty_channel **owner,DWORD timeout,DWORD *error) {
  struct pty_channel *c=*owner; if(!c){*error=0;return 1;}
  ULONGLONG start=GetTickCount64(); HANDLE workers[2]={c->writer,c->reader};
  for(unsigned i=0;i<2;++i) {
    ULONGLONG elapsed=GetTickCount64()-start;
    DWORD left=timeout==INFINITE?INFINITE:(elapsed>=timeout?0:(DWORD)(timeout-elapsed));
    if(!workers[i])continue;
    DWORD result=WaitForSingleObject(workers[i],left);
    if(result!=WAIT_OBJECT_0){*error=result==WAIT_TIMEOUT?ERROR_TIMEOUT:GetLastError();return 0;}
  }
  /* Native caller must have completed all public read/write operations first. */
  if(c->owns_pipes) {
    if(!close_slot(&c->input,error) || !close_slot(&c->output,error))return 0;
  } else { c->input=NULL;c->output=NULL; } /* Borrow ends only after join. */
  if(!close_slot(&c->writer,error) || !close_slot(&c->reader,error) ||
     !close_slot(&c->read_changed,error) || !close_slot(&c->write_changed,error) ||
     !close_slot(&c->input_work,error) || !close_slot(&c->output_space,error))return 0;
  if(c->submit_ready)DeleteCriticalSection(&c->submit);
  if(c->lock_ready)DeleteCriticalSection(&c->lock);free(c);*owner=NULL;*error=0;return 1;
}
