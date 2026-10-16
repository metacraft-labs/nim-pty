/* Genuine native fixture candidate, not a substitute for original assertions.
 * No mocked Win32 boundaries. Actual ConPTY VT framing remains a native gate. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static int all(HANDLE output,const void *bytes,DWORD count) {
  const unsigned char *p=bytes;
  while(count){DWORD done=0;if(!WriteFile(output,p,count,&done,NULL)||!done)return 0;p+=done;count-=done;}
  return 1;
}
int main(int argc,char **argv) {
  HANDLE input=GetStdHandle(STD_INPUT_HANDLE),output=GetStdHandle(STD_OUTPUT_HANDLE);
  if(argc!=2)return 2;
  if(!strcmp(argv[1],"exit17"))return 17;
  if(!strcmp(argv[1],"dimensions")) {
    CONSOLE_SCREEN_BUFFER_INFO info;
    if(!GetConsoleScreenBufferInfo(output,&info))return 3;
    char result[64];int count=snprintf(result,sizeof result,"DIMENSIONS %u %u\n",
      (unsigned)(info.srWindow.Right-info.srWindow.Left+1),
      (unsigned)(info.srWindow.Bottom-info.srWindow.Top+1));
    return count>0 && all(output,result,(DWORD)count)?0:4;
  }
  if(!strcmp(argv[1],"echo")) {
    DWORD mode;
    if(!GetConsoleMode(input,&mode))return 5;
    if(!SetConsoleMode(input,mode & ~(ENABLE_LINE_INPUT|ENABLE_ECHO_INPUT|ENABLE_PROCESSED_INPUT)))return 6;
    if(!SetConsoleCP(CP_UTF8)||!SetConsoleOutputCP(CP_UTF8))return 7;
    unsigned char bytes[4096];
    for(;;){DWORD count=0;if(!ReadFile(input,bytes,sizeof bytes,&count,NULL))return GetLastError()==ERROR_BROKEN_PIPE?0:8;
      if(!count)return 0;if(!all(output,bytes,count))return 9;}
  }
  return 2;
}
