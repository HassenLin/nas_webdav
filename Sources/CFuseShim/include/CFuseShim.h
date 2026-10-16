// CFuseShim.h — libfuse 2.x（macFUSE / FUSE-T）高階 API 的最小 ABI 宣告。
//
// 為什麼不直接 #include <fuse.h>：
//   - 讓專案在「未安裝 macFUSE」的機器上也能建置；libfuse 於執行期以 dlopen 載入
//     （見 FuseLibrary.swift）。未安裝時 app 仍可啟動並提示使用者安裝。
//
// ABI 相容性說明（修改前務必讀）：
//   - 以下 struct 佈局取自 libfuse 2.9 / macFUSE 4.x+ 的 FUSE_USE_VERSION 26 標頭。
//   - fuse_operations 只宣告到 utimens 為止；呼叫 fuse_main_real 時傳入的 op_size
//     為本檔 sizeof，libfuse 內部以 calloc + memcpy(op_size) 複製，後續欄位（含
//     macFUSE 的 Darwin 擴充欄位）自動為 NULL＝未實作。
//   - 未使用的函式指標一律宣告為 void*，大小與函式指標相同，佈局不變。
//   - macOS 版 setxattr/getxattr 多一個 uint32_t position 參數（Darwin 特有）。
//   - fuse_file_info 中 macFUSE 的 purge_attr/purge_ubc 位元欄位與 padding 同在一個
//     unsigned int 內，不影響 fh 的 offset。
#ifndef CFUSE_SHIM_H
#define CFUSE_SHIM_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>

struct fuse_conn_info;  // 不透明：本專案不讀寫其欄位

struct fuse_file_info {
    int flags;                      // open(2) 旗標
    unsigned long fh_old;
    int writepage;
    unsigned int direct_io : 1;
    unsigned int keep_cache : 1;
    unsigned int flush : 1;
    unsigned int nonseekable : 1;
    unsigned int flock_release : 1;
    unsigned int padding : 27;
    uint64_t fh;                    // 檔案 handle：本專案存 OpenFileTable 的 id
    uint64_t lock_owner;
};

typedef int (*fuse_fill_dir_t)(void *buf, const char *name,
                               const struct stat *stbuf, off_t off);

struct fuse_operations {
    int (*getattr)(const char *, struct stat *);
    void *readlink;
    void *getdir;                   // 已棄用
    void *mknod;
    int (*mkdir)(const char *, mode_t);
    int (*unlink)(const char *);
    int (*rmdir)(const char *);
    void *symlink;
    int (*rename)(const char *, const char *);
    void *link;
    int (*chmod)(const char *, mode_t);
    int (*chown)(const char *, uid_t, gid_t);
    int (*truncate)(const char *, off_t);
    void *utime;
    int (*open)(const char *, struct fuse_file_info *);
    int (*read)(const char *, char *, size_t, off_t, struct fuse_file_info *);
    int (*write)(const char *, const char *, size_t, off_t, struct fuse_file_info *);
    int (*statfs)(const char *, struct statvfs *);
    int (*flush)(const char *, struct fuse_file_info *);
    int (*release)(const char *, struct fuse_file_info *);
    int (*fsync)(const char *, int, struct fuse_file_info *);
    void *setxattr;                 // Darwin：(path, name, value, size, flags, position)
    void *getxattr;                 // Darwin：(path, name, value, size, position)
    void *listxattr;
    void *removexattr;
    void *opendir;
    int (*readdir)(const char *, void *, fuse_fill_dir_t, off_t, struct fuse_file_info *);
    void *releasedir;
    void *fsyncdir;
    void *(*init)(struct fuse_conn_info *);
    void (*destroy)(void *);
    void *access;
    int (*create)(const char *, mode_t, struct fuse_file_info *);
    int (*ftruncate)(const char *, off_t, struct fuse_file_info *);
    int (*fgetattr)(const char *, struct stat *, struct fuse_file_info *);
    void *lock;
    int (*utimens)(const char *, const struct timespec tv[2]);
};

// fuse_main() 在標頭中是巨集，實際匯出符號為 fuse_main_real。
typedef int (*fuse_main_real_fn)(int argc, char *argv[],
                                 const struct fuse_operations *op,
                                 size_t op_size, void *user_data);

#endif /* CFUSE_SHIM_H */
