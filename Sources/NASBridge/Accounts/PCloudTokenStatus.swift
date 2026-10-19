import NASBridgeCore
import SwiftUI

/// pCloud 鑰匙圈中已存 token 的實際狀態（帳號清單與帳號編輯器共用）。
///
/// 「鑰匙圈有 token」不等於已登入：token 會因登出、過期、改密碼而失效，所以要實際向 pCloud 確認（`userinfo`）。
/// 停留狀態：
///   - none：鑰匙圈沒有 token
///   - checking：確認中
///   - valid：token 有效
///   - expired：token 失效，需輸入密碼重新登入
///   - unverified：連不上 pCloud，無法確認（不當成失效）
enum PCloudTokenStatus: Equatable {
    case none, checking, valid, expired, unverified

    /// 確認帳號的 token。呼叫端以 `.task(id:)` 執行：先等 0.5 秒，輸入中途被取消就不打 API。
    /// 回傳 nil＝被取消（呼叫端保持原狀態）。
    static func check(_ account: Account) async -> PCloudTokenStatus? {
        guard account.protocol == .pcloud, let token = KeychainStore.secret(for: account) else { return PCloudTokenStatus.none }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return nil }
        do {
            _ = try await PCloudLogin.validate(token: token, region: account.pcloudRegion)
            return .valid
        } catch {
            // 被取消時 URLSession 回 cancelled，也會對應成 EACCES——不可當成失效
            guard !Task.isCancelled else { return nil }
            return (error as? DAVError)?.code == EACCES ? .expired : .unverified
        }
    }

    /// 狀態文字；`detailed` 為編輯器用的完整說明，清單用短的
    @ViewBuilder func label(detailed: Bool) -> some View {
        switch self {
        case .none: Text("Not signed in").foregroundStyle(.orange)
        case .checking: Text("Checking…").foregroundStyle(.secondary)
        case .valid: Text("Signed in")
        case .expired:
            if detailed {
                Text("Sign-in expired — enter the password and sign in again").foregroundStyle(.red)
            } else {
                Text("Sign in again").foregroundStyle(.red)
            }
        case .unverified:
            if detailed {
                Text("Signed in (cannot reach pCloud to verify)").foregroundStyle(.orange)
            } else {
                Text("Signed in (unverified)").foregroundStyle(.orange)
            }
        }
    }
}
