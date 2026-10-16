// SwiftPM 的 C target 至少需要一個來源檔；本模組只提供標頭（CFuseShim.h），
// libfuse 本體在執行期以 dlopen 載入（見 NASBridgeCore/Fuse/FuseLibrary.swift）。
#include "CFuseShim.h"
