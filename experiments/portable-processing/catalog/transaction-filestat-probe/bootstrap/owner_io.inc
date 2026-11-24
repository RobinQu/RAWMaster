/* Private copy of the pinned Unix backend, strictly scoped to the calling thread. */
#include <sys/socket.h>
#include <sys/prctl.h>
#include <signal.h>
#include <stdint.h>
typedef struct { uint64_t nonce; int32_t op, flags, mode, reserved; } RmPeerRequest;
static _Thread_local struct {
  int active, peer;
  uint64_t nonce;
  char main[4096], wal[4100], shm[4100];
} rmSession;
int rm_private_owner_bind(int peer, uint64_t nonce, const char *main, int parent){
  if(rmSession.active || peer<3 || !nonce || !main || strlen(main)>=sizeof(rmSession.main)
      || main[0]!='/' || getppid()!=parent) return -1;
  if(prctl(PR_SET_PDEATHSIG,SIGKILL)!=0 || getppid()!=parent) return -1;
  int type=0; socklen_t n=sizeof(type);
  if(getsockopt(peer,SOL_SOCKET,SO_TYPE,&type,&n)<0 || type!=SOCK_SEQPACKET) return -1;
  struct timeval timeout={4,0};
  if(setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout))!=0
     || setsockopt(peer,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))!=0) return -1;
  rmSession.peer=peer; rmSession.nonce=nonce;
  snprintf(rmSession.main,sizeof(rmSession.main),"%s",main);
  snprintf(rmSession.wal,sizeof(rmSession.wal),"%s-wal",main);
  snprintf(rmSession.shm,sizeof(rmSession.shm),"%s-shm",main);
  rmSession.active=1;
  return 0;
}
static int rm_exchange(int op,int flags,int mode,const int *sendfds){
  RmPeerRequest req={rmSession.nonce,op,flags,mode,0};
  struct iovec iw={&req,sizeof(req)};
  union {struct cmsghdr a; char b[CMSG_SPACE(3*sizeof(int))];} ctrl;
  memset(&ctrl,0,sizeof(ctrl));
  struct msghdr msg={0}; msg.msg_iov=&iw; msg.msg_iovlen=1;
  if(sendfds){
    msg.msg_control=ctrl.b; msg.msg_controllen=sizeof(ctrl.b);
    struct cmsghdr *c=CMSG_FIRSTHDR(&msg); c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;
    c->cmsg_len=CMSG_LEN(3*sizeof(int));memcpy(CMSG_DATA(c),sendfds,3*sizeof(int));
  }
  if(sendmsg(rmSession.peer,&msg,MSG_NOSIGNAL)!=(ssize_t)sizeof(req)) {errno=EIO;return -1;}
  int32_t error=EPROTO; iw.iov_base=&error;iw.iov_len=sizeof(error);
  memset(&msg,0,sizeof(msg));msg.msg_iov=&iw;msg.msg_iovlen=1;
  msg.msg_control=ctrl.b;msg.msg_controllen=sizeof(ctrl.b);
  ssize_t got=recvmsg(rmSession.peer,&msg,MSG_CMSG_CLOEXEC);
  int received[3]={-1,-1,-1},nfds=0,bad=(got!=sizeof(error)) || (msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC));
  for(struct cmsghdr *c=CMSG_FIRSTHDR(&msg); c!=0&&got>0; c=CMSG_NXTHDR(&msg,c)){
    if(c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS || c->cmsg_len<CMSG_LEN(0)){
      bad=1;continue;
    }
    size_t bytes=c->cmsg_len-CMSG_LEN(0);
    if(bytes%sizeof(int))bad=1;
    for(size_t i=0;i<bytes/sizeof(int);i++){
      int fd;memcpy(&fd,(unsigned char*)CMSG_DATA(c)+i*sizeof(int),sizeof(fd));
      if(nfds<3)received[nfds++]=fd;else {close(fd);bad=1;}
    }
  }
  int need=op>=1&&op<=3&&error==0;
  if(!bad && nfds==need && !error && (!need||received[0]>=3))return need?received[0]:0;
  for(int i=0;i<nfds;i++)close(received[i]);
  errno=bad||nfds!=need||error<=0?EPROTO:error;return -1;
}
int rm_private_attest(const int *fds){return rmSession.active?rm_exchange(4,0,0,fds):-1;}
int rm_private_permit(void){return rmSession.active?rm_exchange(5,0,0,0):-1;}
static int rm_private_open(const char *z,int flags,mode_t mode,int role){
  if(!rmSession.active)return robust_open(z,flags,mode);
  const char *expected=role==1?rmSession.main:role==2?rmSession.wal:role==3?rmSession.shm:0;
  if(!expected||!z||strcmp(expected,z)!=0){errno=EPERM;return -1;}
  return rm_exchange(role,flags,mode,0);
}
static int rm_private_db_open(const char *z,int flags,mode_t mode,int eType){
  return rm_private_open(z,flags,mode,eType==SQLITE_OPEN_MAIN_DB?1:eType==SQLITE_OPEN_WAL?2:0);
}
/* The registered owner controls retirement after draining and checkpointing. Neither the
   default WAL xDelete nor the direct SHM unlink may remove a foreign entry on unwind. */
static int rm_private_unlink(const char *name){
  if(!rmSession.active)return osUnlink(name);
  errno=EPERM;return -1;
}
