#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "failed at %d (%s) errno=%d\n", __LINE__, #c, errno); exit(2); } } while (0)
static const char *tf(int b) {return b?"true":"false";}
static void quote(const char *s){
    if (!s){printf("null");return;}
    putchar('"');for(;*s;s++){unsigned char ch=(unsigned char)*s;
        if(ch=='\\'||ch=='"')printf("\\%c",ch);
        else if(ch<32)printf("\\u%04x",ch);else putchar(ch);}
    putchar('"');
}
static void sql(sqlite3 *db,const char *q){CHECK(sqlite3_exec(db,q,NULL,NULL,NULL)==SQLITE_OK);}
static int guard(void *ctx,int op,const char *arg1,const char *arg2,const char *schema,const char *trigger){
    (void)arg1;(void)arg2;(void)schema;(void)trigger;
    if(op==SQLITE_SELECT||op==SQLITE_READ||op==SQLITE_TRANSACTION)return SQLITE_OK;
    ++*(int*)ctx;return SQLITE_DENY;
}
static int marker(sqlite3 *db,char *out,int capacity){
    sqlite3_stmt *s=NULL;
    CHECK(sqlite3_prepare_v2(db,"SELECT writer,marker FROM main.probe WHERE id=1",-1,&s,NULL)==SQLITE_OK);
    CHECK(sqlite3_step(s)==SQLITE_ROW);
    const unsigned char *writer=sqlite3_column_text(s,0),*m=sqlite3_column_text(s,1);
    CHECK(writer&&m&&!strcmp((const char*)writer,"same-writer"));
    int n=snprintf(out,(size_t)capacity,"%s",m);CHECK(n>0&&n<capacity);
    CHECK(sqlite3_step(s)==SQLITE_DONE);CHECK(sqlite3_finalize(s)==SQLITE_OK);
    return 1;
}
static char *filestat(sqlite3 *db,sqlite3_file *file,int *rc,int *length){
    sqlite3_str *str=sqlite3_str_new(db);CHECK(str);
    *rc=SQLITE_NOTFOUND;
    if(file&&file->pMethods&&file->pMethods->xFileControl)
        *rc=file->pMethods->xFileControl(file,SQLITE_FCNTL_FILESTAT,str);
    *length=sqlite3_str_length(str);CHECK(sqlite3_str_errcode(str)==SQLITE_OK);
    return sqlite3_str_finish(str);
}
static void size_info(const char *path){
    struct stat s;CHECK(lstat(path,&s)==0);CHECK(S_ISREG(s.st_mode));
    printf("{\"bytes\":%lld,\"inode\":%llu,\"device\":%u,\"birth\":[%lld,%ld]}",(long long)s.st_size,(unsigned long long)s.st_ino,(unsigned)s.st_dev,(long long)s.st_birthtimespec.tv_sec,s.st_birthtimespec.tv_nsec);
}
int main(int argc,char **argv){
    CHECK(argc==4);CHECK(chdir(argv[1])==0);
    int writing=!strcmp(argv[2],"write"), dirty=!strcmp(argv[3],"dirty");
    sqlite3 *keeper=NULL,*db=NULL;
    CHECK(sqlite3_open_v2("database.sqlite",&keeper,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,NULL)==SQLITE_OK);
    sql(keeper,"PRAGMA journal_mode=WAL;PRAGMA wal_autocheckpoint=0;CREATE TABLE probe(id INTEGER PRIMARY KEY,writer TEXT,marker TEXT);INSERT INTO probe VALUES(1,'same-writer','from-main');");
    int frames=-1,done=-1;CHECK(sqlite3_wal_checkpoint_v2(keeper,"main",SQLITE_CHECKPOINT_TRUNCATE,&frames,&done)==SQLITE_OK);
    if(dirty)sql(keeper,"UPDATE probe SET marker='only-in-wal' WHERE id=1");
    CHECK(sqlite3_open_v2("database.sqlite",&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOMUTEX,NULL)==SQLITE_OK);
    int denied=0;CHECK(sqlite3_set_authorizer(db,guard,&denied)==SQLITE_OK);
    sql(db,writing?"BEGIN IMMEDIATE":"BEGIN");
    char first[64],last[64];marker(db,first,sizeof(first));
    int txn=sqlite3_txn_state(db,"main");
    CHECK(!sqlite3_get_autocommit(db)&&txn==(writing?SQLITE_TXN_WRITE:SQLITE_TXN_READ));
    CHECK(!strcmp(first,dirty?"only-in-wal":"from-main"));
    char *vfs=NULL;CHECK(sqlite3_file_control(db,"main",SQLITE_FCNTL_VFSNAME,&vfs)==SQLITE_OK);
    sqlite3_file *main=NULL,*wal=NULL;
    int mrc=sqlite3_file_control(db,"main",SQLITE_FCNTL_FILE_POINTER,&main);
    int wrc=sqlite3_file_control(db,"main",SQLITE_FCNTL_JOURNAL_POINTER,&wal);
    CHECK(mrc==SQLITE_OK&&wrc==SQLITE_OK&&main&&wal&&main!=wal&&main->pMethods&&wal->pMethods);
    sqlite3_int64 changes_before=sqlite3_total_changes64(db);
    sqlite3_str *control=sqlite3_str_new(db);CHECK(control);
    int conn_rc=sqlite3_file_control(db,"main",SQLITE_FCNTL_FILESTAT,control);
    int ctl_len=sqlite3_str_length(control);
    CHECK(sqlite3_str_errcode(control)==SQLITE_OK);
    char *ctl=sqlite3_str_finish(control);
    int main_rc=-1,wal_rc=-1,main_len=0,wal_len=0;
    char *m=filestat(db,main,&main_rc,&main_len),*j=filestat(db,wal,&wal_rc,&wal_len);
    printf("{\"system\":");quote(sqlite3_libversion());printf(",\"sourceID\":");quote(sqlite3_sourceid());printf(",\"sdkSourceID\":");quote(SQLITE_SOURCE_ID);
    printf(",\"compileOptions\":[");for(int i=0;;i++){const char *opt=sqlite3_compileoption_get(i);if(!opt)break;if(i)putchar(',');quote(opt);}
    printf("],\"vfs\":");quote(vfs);sqlite3_free(vfs);
    printf(",\"mode\":");quote(argv[2]);printf(",\"fixture\":");quote(argv[3]);
    printf(",\"main\":");size_info("database.sqlite");printf(",\"wal\":");size_info("database.sqlite-wal");printf(",\"shm\":");size_info("database.sqlite-shm");
    printf(",\"filePointerRC\":%d,\"journalPointerRC\":%d,\"mainIOVersion\":%d,\"walIOVersion\":%d",mrc,wrc,main->pMethods->iVersion,wal->pMethods->iVersion);
    printf(",\"connectionFileStatRC\":%d,\"connectionFileStatBytes\":%d,\"connectionFileStat\":",conn_rc,ctl_len);quote(ctl);
    printf(",\"mainFileStatRC\":%d,\"mainFileStatBytes\":%d,\"mainFileStat\":",main_rc,main_len);quote(m);
    printf(",\"walFileStatRC\":%d,\"walFileStatBytes\":%d,\"walFileStat\":",wal_rc,wal_len);quote(j);
    sqlite3_free(ctl);sqlite3_free(m);sqlite3_free(j);
    marker(db,last,sizeof(last));int later=sqlite3_txn_state(db,"main");
    sqlite3_int64 changes_after=sqlite3_total_changes64(db);
    int active=!sqlite3_get_autocommit(db);CHECK(active&&later==txn&&!strcmp(first,last));
    sql(db,"ROLLBACK");int ended=sqlite3_txn_state(db,"main");CHECK(ended==SQLITE_TXN_NONE);
    CHECK(sqlite3_close(db)==SQLITE_OK);
    printf(",\"markerBefore\":");quote(first);printf(",\"markerAfter\":");quote(last);
    printf(",\"txnBefore\":%d,\"txnAfter\":%d,\"txnAfterRollback\":%d,\"activeAfterControl\":%s,\"forbiddenSQL\":%d,\"changesBefore\":%lld,\"changesAfter\":%lld,\"probeXFetchCalls\":0,\"probeXShmMapCalls\":0}\n",txn,later,ended,tf(active),denied,(long long)changes_before,(long long)changes_after);
    CHECK(sqlite3_close(keeper)==SQLITE_OK);
    return 0;
}
