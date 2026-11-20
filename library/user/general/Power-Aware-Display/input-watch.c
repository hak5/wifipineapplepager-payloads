/* Observe real buttons without EVIOCGRAB, so the native interface and games
 * retain ownership. Only monotonic timestamps are stored, never key contents.
 * The service separately pauses display control while a game suspends the UI. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
static volatile sig_atomic_t stop;
static void stopping(int sig) { (void)sig; stop=1; }
static long now(void) { struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)) return -1; return t.tv_sec; }
static int stamp(const char *root,const char *name,long value) {
    char path[512],tmp[512];
    if(snprintf(path,sizeof(path),"%s/%s",root,name)>=(int)sizeof(path) ||
       snprintf(tmp,sizeof(tmp),"%s/%s.new",root,name)>=(int)sizeof(tmp)) return -1;
    FILE *f=fopen(tmp,"w"); if(!f)return -1;
    if(fprintf(f,"%ld\n",value)<0){fclose(f);return -1;}
    if(fclose(f))return -1;
    return rename(tmp,path);
}
int main(int argc,char **argv) {
    if(argc!=3){fprintf(stderr,"Usage: input-watch DEVICE RUNTIME_DIRECTORY\n");return 2;}
    int fd=open(argv[1],O_RDONLY|O_NONBLOCK|O_CLOEXEC); if(fd<0){perror("input-watch open");return 1;}
    signal(SIGTERM,stopping); signal(SIGINT,stopping);
    long heartbeat=-1,events=0,t=now();
    if(t<0||stamp(argv[2],"last-input",t)||stamp(argv[2],"input-count",0))return 1;
    while(!stop){
        t=now(); if(t<0)return 1;
        if(t-heartbeat>=3){if(stamp(argv[2],"input-heartbeat",t))return 1;heartbeat=t;}
        struct pollfd p={fd,POLLIN,0}; int rc=poll(&p,1,1000);
        if(rc<0){if(errno==EINTR)continue;perror("input-watch poll");return 1;}
        if(p.revents&(POLLERR|POLLHUP|POLLNVAL))return 1;
        if(p.revents&POLLIN){
            struct input_event ev; ssize_t n;
            while((n=read(fd,&ev,sizeof(ev)))==(ssize_t)sizeof(ev)){
                /* Presses and held-button repeats count as activity. */
                if(ev.type==EV_KEY && ev.value>0){
                    if(stamp(argv[2],"last-input",now()) || stamp(argv[2],"input-count",++events))return 1;
                }
            }
            if(n>0 || (n<0 && errno!=EAGAIN && errno!=EINTR))return 1;
        }
    }
    close(fd); return 0;
}
