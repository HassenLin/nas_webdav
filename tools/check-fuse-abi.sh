#!/bin/bash
# 比對 Sources/CFuseShim/include/CFuseShim.h 與已安裝 macFUSE 真實標頭的 ABI（欄位位移、結構大小）。
#
# CFuseShim.h 是手寫的最小宣告（為了不需 macFUSE 也能建置），macFUSE 升版後跑一次這支確認仍相容。
# 用法：./tools/check-fuse-abi.sh      需要已安裝 macFUSE（/usr/local/include/fuse）
set -euo pipefail
cd "$(dirname "$0")/.."
INC=/usr/local/include/fuse
[ -f "$INC/fuse.h" ] || { echo "找不到 $INC/fuse.h，請先安裝 macFUSE" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIELDS="getattr mkdir unlink rmdir rename chmod chown truncate open read write statfs flush release fsync setxattr getxattr listxattr removexattr readdir init destroy create ftruncate fgetattr utimens"

gen() {   # gen <include 行> <輸出名>
    {
        echo "$1"
        echo '#include <stdio.h>'
        echo '#include <stddef.h>'
        echo 'int main(void) {'
        for f in $FIELDS; do echo "  printf(\"op.$f %zu\\n\", offsetof(struct fuse_operations, $f));"; done
        echo '  printf("fi.flags %zu\n", offsetof(struct fuse_file_info, flags));'
        echo '  printf("fi.fh %zu\n", offsetof(struct fuse_file_info, fh));'
        echo '  printf("sizeof(fi) %zu\n", sizeof(struct fuse_file_info));'
        echo '  return 0; }'
    } > "$TMP/$2.c"
    clang -w -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26 -I"$INC" -ISources/CFuseShim/include \
        "$TMP/$2.c" -o "$TMP/$2" && "$TMP/$2" > "$TMP/$2.txt"
}
gen '#include <fuse.h>' real
gen '#include "CFuseShim.h"' shim
if diff -u "$TMP/real.txt" "$TMP/shim.txt"; then
    echo "ABI 相容：CFuseShim.h 與 macFUSE 標頭一致（$(wc -l < "$TMP/real.txt" | tr -d ' ') 項）"
else
    echo "ABI 不一致！請依上方差異修正 CFuseShim.h" >&2
    exit 1
fi
