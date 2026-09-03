import SwiftUI
import AppKit
import Foundation
import Security
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Models

struct SkillItem: Identifiable, Equatable {
    let id = UUID()
    let dirName: String
    let dirURL: URL
    let skillPath: String
    let writable: Bool
    let isBuiltin: Bool
    var isUserInstalled: Bool
    var originalName: String
    var originalDesc: String
    var originalMetaName: String?
    var name: String
    var desc: String
    var metaName: String?          // panel title override from _skillhub_meta.json etc.
    var metaPath: String?          // path to the meta JSON file
    var baselineName: String
    var baselineDesc: String
    var baselineMetaName: String?
    var savedName: String
    var savedDesc: String
    var savedMetaName: String?
    var trueOrigName: String
    var trueOrigDesc: String
    var trueOrigMetaName: String?
    var hasChanges: Bool = false
    var prefix: String = ""
    var customName: String = ""
    var customDesc: String = ""
    var source: String = ""
    /// 该 skill 目录在本机创建(添加)的时间
    var addedDate: Date?
    /// 是否已请求“恢复此 skill 最初”，需点保存才真正执行。
    var pendingRestore: Bool = false

    /// 该 skill 是否“被改过”：已保存值是否偏离真实原始(名/解释/面板标题)。
    /// 注意：WorkBuddy 默认面板标题就与 frontmatter 名不同，不能据此判定为“被改过”。
    var modifiedFromOriginal: Bool {
        (savedName != trueOrigName) || (savedDesc != trueOrigDesc) || (savedMetaName != trueOrigMetaName)
    }

    /// 该 skill 的解释是否“最初是英文且现在仍显示英文”（未本地化）。
    /// 前提：trueOrigDesc（首次扫描/备份抓到的原始值）是英文；
    /// 且当前实际解释(effective)仍是英文（没改，或改完依旧是英文）。
    /// effective 取「已保存/文件当前值 savedDesc」，不回退冻结的 trueOrigDesc——
    /// 否则改完中文并保存/重开后，会错误地把冻结的英文原始值当成当前解释，仍在「英文」筛选里出现。
    /// 排除：原本中文、用户手敲成英文的 skill。
    var hasEnglishDesc: Bool {
        let effective = customDesc.isEmpty ? savedDesc : customDesc
        return looksEnglish(trueOrigDesc) && looksEnglish(effective)
    }
}

struct BackupEntry: Codable {
    let dir: String
    let path: String
    let originalName: String
    let originalDesc: String
    let originalMetaName: String?
    let metaPath: String?
}

struct BackupManifest: Codable {
    let timestamp: String
    let count: Int
    let entries: [BackupEntry]
}

// MARK: - 导出/导入配置（本地化配置：各 skill 的已保存名称/解释）

struct SavedConfigEntry: Codable {
    let dir: String
    let name: String
    let desc: String
}

struct SavedConfigFile: Codable {
    let app: String
    let version: String
    let exportedAt: String
    let entries: [SavedConfigEntry]
}

// MARK: - 英文检测（判断是否仍为英文解释，未本地化）

/// 判断一段文本是否仍主要为英文（未本地化为中文）。
/// 规则：ASCII 字母(A-Za-z) ≥ 3 且不含任何中文字符(CJK) → 视为英文。
func looksEnglish(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return false }
    var asciiLetters = 0
    var cjk = 0
    var totalLetters = 0
    for ch in t {
        guard let sc = ch.unicodeScalars.first else { continue }
        let v = sc.value
        if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
            asciiLetters += 1
            totalLetters += 1
        } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) {
            cjk += 1
            totalLetters += 1
        } else if ch.isLetter {
            totalLetters += 1
        }
    }
    guard totalLetters > 0 else { return false }
    return asciiLetters >= 3 && cjk == 0
}

// MARK: - Frontmatter helpers

func parseFrontmatter(_ content: String) -> (name: String?, desc: String?, endIndex: Int?) {
    let lines = content.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
        return (nil, nil, nil)
    }
    let search = lines.dropFirst(start + 1)
    guard let inner = search.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
        return (nil, nil, nil)
    }
    let end = start + 1 + inner
    var name: String?
    var desc: String?
    var i = start + 1
    while i < end {
        let raw = lines[i]
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("name:") {
            var val = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            name = String(val)
        } else if trimmed.hasPrefix("description:") {
            var val = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix(">") || val.hasPrefix("|") {
                val = String(val.dropFirst()).trimmingCharacters(in: .whitespaces)
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                var folded = String(val)
                var j = i + 1
                while j < end {
                    let l = lines[j]
                    if l.hasPrefix(" ") || l.hasPrefix("\t") {
                        folded += " " + l.trimmingCharacters(in: .whitespaces)
                        j += 1
                    } else { break }
                }
                desc = folded
                i = j; continue
            } else {
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                desc = String(val)
            }
        }
        i += 1
    }
    return (name, desc, end)
}

func yamlQuote(_ s: String) -> String {
    if s.contains("\"") || s.contains(":") || s.contains("#") || s.contains("'") || s.hasPrefix("[") || s.hasPrefix("{") || s.contains("\n") {
        var out = ""
        for c in s {
            if c == "\\" { out += "\\\\" }
            else if c == "\"" { out += "\\\"" }
            else if c == "\n" { out += "\\n" }
            else { out.append(c) }
        }
        return "\"" + out + "\""
    }
    return s
}

func rewriteFrontmatter(content: String, newName: String, newDesc: String) -> String {
    let lines = content.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
        return "---\nname: \(yamlQuote(newName))\ndescription: \(yamlQuote(newDesc))\n---\n" + content
    }
    let search = lines.dropFirst(start + 1)
    guard let inner = search.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
        return "---\nname: \(yamlQuote(newName))\ndescription: \(yamlQuote(newDesc))\n---\n" + content
    }
    let end = start + 1 + inner
    var out: [String] = []
    var i = start + 1
    var wroteName = false, wroteDesc = false
    while i < end {
        let raw = lines[i]
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("name:") {
            out.append("name: \(yamlQuote(newName))")
            wroteName = true
            i += 1
        } else if trimmed.hasPrefix("description:") {
            out.append("description: \(yamlQuote(newDesc))")
            wroteDesc = true
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("|") {
                var j = i + 1
                while j < end {
                    let l = lines[j]
                    if l.hasPrefix(" ") || l.hasPrefix("\t") { j += 1 } else { break }
                }
                i = j
            } else {
                i += 1
            }
        } else {
            out.append(raw)
            i += 1
        }
    }
    if !wroteName { out.insert("name: \(yamlQuote(newName))", at: 0) }
    if !wroteDesc { out.insert("description: \(yamlQuote(newDesc))", at: 1) }
    var result = [String]()
    result.append("---")
    result.append(contentsOf: out)
    result.append("---")
    result.append(contentsOf: lines.dropFirst(end + 1))
    return result.joined(separator: "\n")
}

// MARK: - Meta JSON helpers

let metaFileNames = ["_skillhub_meta.json", "_marketplace_meta.json", "_knot_meta.json", "_builtin_market_meta.json", "_user_meta.json"]

func findMetaFile(in dir: URL) -> (path: String, name: String)? {
    for f in metaFileNames {
        let p = dir.appendingPathComponent(f)
        if FileManager.default.fileExists(atPath: p.path) {
            if let data = try? Data(contentsOf: p),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String {
                return (p.path, name)
            }
        }
    }
    return nil
}

func writeMetaName(path: String, newName: String) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    obj["name"] = newName
    obj["skillLocalizerModifiedAt"] = ISO8601DateFormatter().string(from: Date())
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
        return false
    }
    do {
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    } catch {
        return false
    }
}

// MARK: - True-original (跨会话真实原始值)

let originalsStorePath = ("~/.workbuddy/skills/.skilllocalizer_originals.json" as NSString).expandingTildeInPath

func loadOriginalsStore() -> [String: [String: String]] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: originalsStorePath)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return [:] }
    return obj
}

func saveOriginalsStore(_ store: [String: [String: String]]) {
    if let data = try? JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: originalsStorePath), options: .atomic)
    }
}

/// 从备份文件找回该 skill 被本 App 修改前的真实原始 name/desc/meta。
/// 扫描全部备份（升序）：
///   - name/desc 取最早一次非空值；
///   - meta 取最早一次非空 originalMetaName（可能在更晚的备份里，不因此截断）。
/// 兼容旧备份 schema(dirName/origName/origDesc) 与新备份 schema(dir/originalName/originalDesc/originalMetaName)。
func earliestBackupOriginal(for dir: String) -> (name: String?, desc: String?, meta: String?)? {
    let fm = FileManager.default
    let base = ("~/.workbuddy/skills" as NSString).expandingTildeInPath
    guard let files = try? fm.contentsOfDirectory(atPath: base) else { return nil }
    let backups = files
        .filter { $0.hasPrefix("skills_backup_") && $0.hasSuffix(".json") }
        .sorted() // 升序 = 最早优先
    var rname: String? = nil
    var rdesc: String? = nil
    var rmeta: String? = nil
    for b in backups {
        let p = (base as NSString).appendingPathComponent(b)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let list = obj["entries"] as? [[String: Any]] ?? obj["skills"] as? [[String: Any]] ?? []
        for e in list {
            let d = (e["dirName"] as? String) ?? (e["dir"] as? String) ?? ""
            if d == dir {
                if rname == nil {
                    rname = (e["origName"] as? String) ?? (e["originalName"] as? String)
                    rdesc = (e["origDesc"] as? String) ?? (e["originalDesc"] as? String)
                }
                if rmeta == nil {
                    rmeta = e["originalMetaName"] as? String
                }
            }
        }
    }
    if rname == nil && rdesc == nil && rmeta == nil { return nil }
    return (rname, rdesc, rmeta)
}

// MARK: - 安装来源探测

/// 持久化映射：目录名 -> 仓库(owner/repo)。数据来自本机对话调查，记录「从 GitHub 链接(tarball)安装」的 skill。
/// 这些 skill 目录内没有 .git，普通探测会误判为「手动安装」，故用显式映射优先标记。
private var _githubLinkCache: [String: String]? = nil
func githubLinkRepo(for dirName: String) -> String? {
    if _githubLinkCache == nil {
        let path = ("~/.workbuddy/skills/.skilllocalizer_sources.json" as NSString).expandingTildeInPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            var m: [String: String] = [:]
            for (k, v) in obj {
                if let repo = v["repo"] as? String { m[k] = repo }
            }
            _githubLinkCache = m
        } else {
            _githubLinkCache = [:]
        }
    }
    return _githubLinkCache?[dirName]
}

/// 探测 skill 的安装来源，用于右栏展示：GitHub / 技能市场 / 本地 等。
func detectSource(dirName: String) -> String {
    let base = ("~/.workbuddy/skills" as NSString).expandingTildeInPath
    let dirPath = (base as NSString).appendingPathComponent(dirName)
    let skillFile = (dirPath as NSString).appendingPathComponent("SKILL.md")

    // 0.5) WorkBuddy 自身生成的 skill（frontmatter 含 agent_created: true）
    if let content = try? String(contentsOfFile: skillFile, encoding: .utf8),
       let r = content.range(of: "agent_created:"),
       let le = content[r.lowerBound...].firstIndex(of: "\n") {
        let v = String(content[r.upperBound..<le]).trimmingCharacters(in: .whitespacesAndNewlines)
        if v == "true" { return "workbuddy 生成" }
    }

    // 0) 持久化映射优先：从 GitHub 链接(tarball)安装、目录内无 .git 的 skill
    if let repo = githubLinkRepo(for: dirName) {
        return "GitHub 链接安装（\(repo)）"
    }

    let fm = FileManager.default

    // 1) Git 仓库：解析 remote "origin" 的 url
    let gitConfig = (dirPath as NSString).appendingPathComponent(".git/config")
    if let cfg = try? String(contentsOfFile: gitConfig, encoding: .utf8) {
        if let url = extractGitOriginURL(cfg) {
            if url.contains("github.com") {
                return "GitHub（\(shortRepo(url))"
            }
            if let host = hostOf(url) {
                return "Git（\(host))"
            }
            return "Git 仓库"
        }
        return "Git 仓库（无 remote）"
    }

    // 2) 市场 meta
    for f in ["_skillhub_meta.json", "_marketplace_meta.json", "_knot_meta.json"] {
        if fm.fileExists(atPath: (dirPath as NSString).appendingPathComponent(f)) {
            return "WorkBuddy 技能市场"
        }
    }
    if fm.fileExists(atPath: (dirPath as NSString).appendingPathComponent("_builtin_market_meta.json")) {
        return "内置"
    }
    return "本地 / 手动安装"
}

func extractGitOriginURL(_ cfg: String) -> String? {
    let lines = cfg.components(separatedBy: .newlines)
    var inOrigin = false
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[remote") && t.contains("origin") {
            inOrigin = true
            continue
        }
        if inOrigin {
            if t.hasPrefix("[") { break }
            if t.hasPrefix("url") {
                let parts = t.components(separatedBy: "=")
                if parts.count >= 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
    }
    return nil
}

func hostOf(_ url: String) -> String? {
    if let r = url.range(of: "://") {
        let rest = url[r.upperBound...]
        if let slash = rest.firstIndex(of: "/") {
            return String(rest[..<slash])
        }
        return String(rest)
    }
    if url.contains("@") {
        let parts = url.components(separatedBy: ":")
        if let first = parts.first, first.contains("@") {
            return String(first.split(separator: "@").last ?? "")
        }
    }
    return nil
}

func shortRepo(_ url: String) -> String {
    var u = url
    if let r = u.range(of: "://") { u = String(u[r.upperBound...]) }
    else if let at = u.firstIndex(of: "@") { u = String(u[u.index(after: at)...]) }
    u = u.replacingOccurrences(of: ".git", with: "")
    let comps = u.components(separatedBy: "/").filter { !$0.isEmpty }
    if comps.count >= 2 {
        return comps[comps.count - 2] + "/" + comps[comps.count - 1]
    }
    return u
}

// MARK: - Logging

let debugLogPath = ("~/.workbuddy/skills/skilllocalizer_debug.log" as NSString).expandingTildeInPath

func logDebug(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    let fm = FileManager.default
    if !fm.fileExists(atPath: debugLogPath) {
        fm.createFile(atPath: debugLogPath, contents: Data(), attributes: nil)
    }
    if let handle = FileHandle(forWritingAtPath: debugLogPath) {
        _ = try? handle.seekToEnd()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

// MARK: - Keychain & Translation Config

enum SLSettings {
    static let providerKey = "sl_provider"
    // 旧版（1.1.5 及之前）全局凭证键名，仅用于一次性迁移
    static let legacyKeyAccount = "sl_api_key"      // Keychain
    static let legacyBaseKey = "sl_api_base"        // UD
    static let legacyModelKey = "sl_api_model"      // UD
    static let legacyAppidKey = "sl_api_appid"      // UD
    static let migrated116Key = "sl_migrated_116"
    // 每预设各自独立的键名（base/model/appid 存 UD，key 存钥匙串）
    static func baseKey(_ p: String) -> String { "sl_api_base_\(p)" }
    static func modelKey(_ p: String) -> String { "sl_api_model_\(p)" }
    static func appidKey(_ p: String) -> String { "sl_api_appid_\(p)" }
    static func keyAccount(_ p: String) -> String { "sl_api_key_\(p)" }

    /// 一次性迁移：把 1.1.5 的全局凭证搬进「当前所选预设」的独立槽位，避免旧 key 跨预设串用/丢失。
    static func migrateToPerProvider() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrated116Key) else { return }
        ud.set(true, forKey: migrated116Key)
        let p = ud.string(forKey: providerKey) ?? "custom"
        if let old = KeychainHelper.read(account: legacyKeyAccount), !old.isEmpty {
            KeychainHelper.save(account: keyAccount(p), value: old)
            KeychainHelper.delete(account: legacyKeyAccount)
        }
        if let oldBase = ud.string(forKey: legacyBaseKey), !oldBase.isEmpty {
            ud.set(oldBase, forKey: baseKey(p)); ud.removeObject(forKey: legacyBaseKey)
        }
        if let oldModel = ud.string(forKey: legacyModelKey), !oldModel.isEmpty {
            ud.set(oldModel, forKey: modelKey(p)); ud.removeObject(forKey: legacyModelKey)
        }
        if let oldAppid = ud.string(forKey: legacyAppidKey), !oldAppid.isEmpty {
            ud.set(oldAppid, forKey: appidKey(p)); ud.removeObject(forKey: legacyAppidKey)
        }
    }
}

enum KeychainHelper {
    static let service = "com.banqiu.skilllocalizer"
    static func save(account: String, value: String) {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - App State

class AppState: ObservableObject {
    @Published var items: [SkillItem] = []
    @Published var search: String = ""
    @Published var isLoading = false
    @Published var status: String = ""
    @Published var showAbout = false
    @Published var pendingRestoreAll: Bool = false
    @Published var showOnlyModified = false
    @Published var showOnlyEnglish = false
    @Published var showSettings = false

    // 导入配置：确认弹窗状态 + 待应用的匹配项 + 跳过的无对应 skill 数
    @Published var showImportConfirm = false
    var pendingImportEntries: [SavedConfigEntry] = []
    var importSkippedCount: Int = 0

    let skillsURL = URL(fileURLWithPath: ("~/.workbuddy/skills" as NSString).expandingTildeInPath)

    init() {
        SLSettings.migrateToPerProvider()
    }

    func loadSkills() {
        isLoading = true
        defer { isLoading = false }
        var result: [SkillItem] = []
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: skillsURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            status = "无法读取 ~/.workbuddy/skills"
            return
        }
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else { continue }
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            let fmParsed = parseFrontmatter(content)
            let dirName = dir.lastPathComponent
            let addedDate = (try? fm.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date
            let writable = fm.isWritableFile(atPath: skillFile.path)
            let isBuiltin = dirName.contains("builtin") || skillFile.path.contains("builtin-skills")
            let isUserInstalled = !isBuiltin
            let originalName = fmParsed.name ?? dirName
            let originalDesc = fmParsed.desc ?? ""
            let meta = findMetaFile(in: dir)
            let originalMetaName = meta?.name
            let metaPath = meta?.path

            // 真正原始值：持久化 originals 存储优先；meta 在 store 缺时回退备份(取最早非空)；再回退当前(未知)
            var originalsStore = loadOriginalsStore()
            let bk = earliestBackupOriginal(for: dirName)
            let trueOrigName: String
            let trueOrigDesc: String
            let trueOrigMeta: String?
            if let stored = originalsStore[dirName], let sn = stored["name"] {
                trueOrigName = sn
                trueOrigDesc = stored["desc"] ?? originalDesc
                trueOrigMeta = stored["meta"] ?? bk?.meta ?? originalMetaName
            } else if let bkName = bk?.name {
                trueOrigName = bkName
                trueOrigDesc = bk?.desc ?? originalDesc
                trueOrigMeta = bk?.meta ?? originalMetaName
            } else {
                trueOrigName = originalName
                trueOrigDesc = originalDesc
                trueOrigMeta = originalMetaName
            }
            // 持久化：store 缺 或 meta 为空时，用备份/当前补写，避免 nil 缓存永久遮盖真实原始 meta
            if originalsStore[dirName] == nil || originalsStore[dirName]?["meta"] == nil {
                var rec: [String: String] = ["name": trueOrigName, "desc": trueOrigDesc]
                if let m = trueOrigMeta { rec["meta"] = m }
                originalsStore[dirName] = rec
                saveOriginalsStore(originalsStore)
            }

            let item = SkillItem(
                dirName: dirName,
                dirURL: dir,
                skillPath: skillFile.path,
                writable: writable,
                isBuiltin: isBuiltin,
                isUserInstalled: isUserInstalled,
                originalName: originalName,
                originalDesc: originalDesc,
                originalMetaName: originalMetaName,
                name: originalName,
                desc: originalDesc,
                metaName: originalMetaName,
                metaPath: metaPath,
                baselineName: originalName,
                baselineDesc: originalDesc,
                baselineMetaName: originalMetaName,
                savedName: originalName,
                savedDesc: originalDesc,
                savedMetaName: originalMetaName,
                trueOrigName: trueOrigName,
                trueOrigDesc: trueOrigDesc,
                trueOrigMetaName: trueOrigMeta,
                source: detectSource(dirName: dirName),
                addedDate: addedDate
            )
            result.append(item)
        }
        DispatchQueue.main.async {
            self.items = result
            self.status = "已加载 \(result.count) 个 skill"
        }
    }

    var filteredItems: [SkillItem] {
        var list = items
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.dirName.lowercased().contains(q) ||
                $0.name.lowercased().contains(q) ||
                $0.metaName?.lowercased().contains(q) ?? false
            }
        }
        if showOnlyModified {
            list = list.filter { $0.modifiedFromOriginal || $0.hasChanges }
        }
        if showOnlyEnglish {
            list = list.filter { $0.hasEnglishDesc }
        }
        return list
    }

    func updateChangeState(for item: inout SkillItem) {
        let targetName = item.customName.isEmpty
            ? (item.prefix.isEmpty ? item.trueOrigName : "[\(item.prefix)] \(item.trueOrigName)")
            : item.customName
        item.name = targetName
        item.desc = item.customDesc.isEmpty ? item.trueOrigDesc : item.customDesc
        item.hasChanges = (item.name != item.savedName) || (item.desc != item.savedDesc) || (item.metaName != item.savedMetaName)
    }

    func doSave() {
        var restoredCount = 0
        var ok = 0
        var fail = 0
        var backups: [BackupEntry] = []

        // 1) 待执行的恢复：保存才真正写文件（恢复优先于编辑保存）
        let doRestoreAll = pendingRestoreAll
        if doRestoreAll {
            for idx in items.indices {
                var it = items[idx]
                guard it.writable && !it.isBuiltin else { continue }
                backups.append(BackupEntry(dir: it.dirName, path: it.skillPath, originalName: it.savedName, originalDesc: it.savedDesc, originalMetaName: it.savedMetaName, metaPath: it.metaPath))
                _ = restoreSkill(&it)
                items[idx] = it
                restoredCount += 1
            }
        } else {
            for idx in items.indices where items[idx].pendingRestore {
                var it = items[idx]
                backups.append(BackupEntry(dir: it.dirName, path: it.skillPath, originalName: it.savedName, originalDesc: it.savedDesc, originalMetaName: it.savedMetaName, metaPath: it.metaPath))
                _ = restoreSkill(&it)
                items[idx] = it
                restoredCount += 1
            }
        }

        // 2) 编辑保存（hasChanges；恢复已先清空了相关 hasChanges）
        let changed = items.filter { $0.hasChanges }
        for var it in changed {
            let targetName = it.customName.isEmpty
                ? (it.prefix.isEmpty ? it.trueOrigName : "[\(it.prefix)] \(it.trueOrigName)")
                : it.customName
            let targetDesc = it.customDesc.isEmpty ? it.trueOrigDesc : it.customDesc
            logDebug("[doSave] changed: dir=\(it.dirName) name='\(targetName)' desc='\(targetDesc)' writable=\(it.writable) metaPath=\(it.metaPath ?? "nil")")

            let entry = BackupEntry(
                dir: it.dirName,
                path: it.skillPath,
                originalName: it.savedName,
                originalDesc: it.savedDesc,
                originalMetaName: it.savedMetaName,
                metaPath: it.metaPath
            )
            backups.append(entry)

            // Write SKILL.md
            guard let content = try? String(contentsOfFile: it.skillPath, encoding: .utf8) else {
                logDebug("FAIL read SKILL.md: \(it.dirName)"); fail += 1; continue
            }
            let newContent = rewriteFrontmatter(content: content, newName: targetName, newDesc: targetDesc)
            do {
                try newContent.write(toFile: it.skillPath, atomically: true, encoding: .utf8)
                logDebug("WRITE OK SKILL.md: \(it.dirName) -> name='\(targetName)'")
            } catch {
                logDebug("FAIL write SKILL.md: \(it.dirName) error=\(error)"); fail += 1; continue
            }

            // Write meta JSON if present
            if let mp = it.metaPath {
                if writeMetaName(path: mp, newName: targetName) {
                    logDebug("WRITE OK meta: \(it.dirName) -> \(mp)")
                } else {
                    logDebug("FAIL write meta: \(it.dirName) -> \(mp)")
                }
            }

            ok += 1
            it.savedName = targetName
            it.savedDesc = targetDesc
            it.savedMetaName = targetName
            it.metaName = targetName
            it.hasChanges = false
            if let idx = items.firstIndex(where: { $0.id == it.id }) {
                items[idx] = it
            }
        }

        if !backups.isEmpty {
            saveBackup(entries: backups)
        }

        // 3) 汇总状态
        var parts: [String] = []
        if restoredCount > 0 { parts.append("恢复 \(restoredCount) 个") }
        if ok > 0 || fail > 0 { parts.append("保存完成：成功 \(ok)，失败 \(fail)") }
        if parts.isEmpty {
            status = "没有需要保存或恢复的改动。"
        } else {
            status = parts.joined(separator: "；") + "。重启 WorkBuddy 后技能面板生效。"
        }
        logDebug("doSave restored=\(restoredCount) ok=\(ok) fail=\(fail)")

        // 4) 清空 pending 标记
        pendingRestoreAll = false
        for idx in items.indices { items[idx].pendingRestore = false }
    }

    func saveBackup(entries: [BackupEntry]) {
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupPath = ("~/.workbuddy/skills/skills_backup_\(ts).json" as NSString).expandingTildeInPath
        let manifest = BackupManifest(timestamp: ISO8601DateFormatter().string(from: Date()), count: entries.count, entries: entries)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: URL(fileURLWithPath: backupPath))
        }
    }

    /// 将单个 skill 还原为真实原始（从最早备份找回，而非会话快照）。
    /// 只作用于当前传入的这一个 skill，与全局无关。
    func restoreOne(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items[idx]
        guard it.writable && !it.isBuiltin else {
            status = "「\(it.dirName)」为只读/内置，无法恢复。"
            return
        }
        let ok = restoreSkill(&it)
        items[idx] = it
        status = ok ? "已恢复「\(it.dirName)」为最初真实原始。" : "恢复「\(it.dirName)」失败，请检查文件权限。"
    }

    /// 全部 skill 还原为真实原始（无视是否已在本会话改动）。
    func restoreAll() {
        var ok = 0, fail = 0, skipped = 0
        for idx in items.indices {
            var it = items[idx]
            guard it.writable && !it.isBuiltin else { skipped += 1; continue }
            if restoreSkill(&it) { ok += 1 } else { fail += 1 }
            items[idx] = it
        }
        status = "全部恢复：成功 \(ok)，失败 \(fail)，跳过(只读/内置) \(skipped)。重启 WorkBuddy 后技能面板生效。"
    }

    /// 核心：把单个 skill 的 SKILL.md 与 meta 写回真实原始值，并刷新内存状态。返回是否成功写文件。
    @discardableResult
    private func restoreSkill(_ it: inout SkillItem) -> Bool {
        guard let content = try? String(contentsOfFile: it.skillPath, encoding: .utf8) else { return false }
        let newContent = rewriteFrontmatter(content: content, newName: it.trueOrigName, newDesc: it.trueOrigDesc)
        do {
            try newContent.write(toFile: it.skillPath, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        // 仅当备份里有真实原始 meta 名时才写回 meta；否则保留 meta 现状（可能本就是正确的英文原名）
        if let mp = it.metaPath, let om = it.trueOrigMetaName {
            _ = writeMetaName(path: mp, newName: om)
        }
        it.name = it.trueOrigName
        it.desc = it.trueOrigDesc
        it.metaName = it.trueOrigMetaName
        it.savedName = it.trueOrigName
        it.savedDesc = it.trueOrigDesc
        it.savedMetaName = it.trueOrigMetaName
        it.prefix = ""
        it.customName = ""
        it.customDesc = ""
        it.hasChanges = false
        return true
    }

    // MARK: - 翻译（AI 批量中文解释）

    @Published var isTranslating = false
    @Published var translateProgress: Double = 0   // 0...1
    @Published var translateDone: Int = 0
    @Published var translateTotal: Int = 0

    private func apiConfigComplete() -> Bool {
        let cfg = apiConfig()
        if cfg.provider == "baidu" {
            return !cfg.appid.isEmpty && !cfg.key.isEmpty
        }
        return !cfg.key.isEmpty && !cfg.base.isEmpty && !cfg.model.isEmpty
    }
    private func apiConfig() -> (base: String, model: String, key: String, appid: String, provider: String) {
        let ud = UserDefaults.standard
        let p = ud.string(forKey: SLSettings.providerKey) ?? "custom"
        let base = (ud.string(forKey: SLSettings.baseKey(p)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (ud.string(forKey: SLSettings.modelKey(p)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (KeychainHelper.read(account: SLSettings.keyAccount(p)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appid = (ud.string(forKey: SLSettings.appidKey(p)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (base, model, key, appid, p)
    }

    /// 异步翻译入口：按 provider 分流。未配置时直接失败并提示。
    func translate(text: String, completion: @escaping (String?) -> Void) {
        let cfg = apiConfig()
        if cfg.provider == "baidu" {
            guard !cfg.appid.isEmpty, !cfg.key.isEmpty else {
                DispatchQueue.main.async {
                    self.status = "未配置百度翻译：需填 AppID 与 API Key / 密钥（设置中选「百度翻译开放平台」）。"
                }
                logDebug("[translate] 百度未配置")
                completion(nil)
                return
            }
            translateViaBaidu(text: text, appid: cfg.appid, secretKey: cfg.key) { res in
                if res == nil {
                    DispatchQueue.main.async {
                        if self.status.isEmpty { self.status = "百度翻译失败（检查 AppID / Key / 网络 / 额度，详见设置测试连接）。" }
                    }
                }
                completion(res)
            }
            return
        }
        guard !cfg.key.isEmpty, !cfg.base.isEmpty, !cfg.model.isEmpty else {
            DispatchQueue.main.async {
                self.status = "未配置 API（Base URL / Model / Key）。请在「设置」中配置后使用批量翻译 / 翻译此条。"
            }
            logDebug("[translate] API 未配置")
            completion(nil)
            return
        }
        callAPI(text: text, base: cfg.base, model: cfg.model, key: cfg.key) { apiResult in
            completion(apiResult)
        }
    }

    /// 同步包装：后台线程调用，用信号量等待异步回调，避免阻塞 UI。
    func translateSync(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var result: String? = nil
        let sem = DispatchSemaphore(value: 0)
        translate(text: text) { r in result = r; sem.signal() }
        sem.wait()
        return result
    }

    private func callAPI(text: String, base: String, model: String, key: String, completion: @escaping (String?) -> Void) {
        let endpoint = base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions"
        guard let url = URL(string: endpoint) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        let prompt = "Translate the following English text into Simplified Chinese. Output ONLY the translated text, without any explanation, quotes, or extra content.\n\n" + text
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.3
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { completion(nil); return }
        req.httpBody = httpBody
        let start = Date()
        slAPISession().dataTask(with: req) { data, resp, err in
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            if let err = err { logDebug("[API] error: \(err)"); DispatchQueue.main.async { self.status = "翻译请求失败（\(elapsed)s）：\(slDescribeError(err))" }; completion(nil); return }
            guard let data = data else { completion(nil); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logDebug("[API] non-json response"); completion(nil); return
            }
            // 成功路径
            if let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines)); return
            }
            // 失败路径：提取服务器真实错误（硅基流动顶层 message / OpenAI error.message）
            var errMsg = "API 返回非预期格式"
            if let m = json["message"] as? String, !m.isEmpty { errMsg = m }
            else if let e = json["error"] as? [String: Any], let m = e["message"] as? String, !m.isEmpty { errMsg = m }
            else if let m = json["error_message"] as? String, !m.isEmpty { errMsg = m }
            logDebug("[API] error response: \(errMsg)")
            DispatchQueue.main.async { self.status = "翻译失败：\(errMsg)" }
            completion(nil)
        }.resume()
    }

    /// 百度翻译开放平台（传统 API，非 OpenAI 兼容）：GET 请求 + MD5(appid+q+salt+secretKey) 签名。
    private func translateViaBaidu(text: String, appid: String, secretKey: String, completion: @escaping (String?) -> Void) {
        // 百度单次 q 上限 6000 字节：超长按字符边界截断到 5900 字节，避免硬报错
        var q = text
        if q.utf8.count > 5900 {
            while q.utf8.count > 5900, !q.isEmpty { q.removeLast() }
            logDebug("[Baidu] q 超长已截断至 \(q.utf8.count) 字节")
        }
        let salt = Int.random(in: 10000...65536)
        let signRaw = appid + q + String(salt) + secretKey
        let sign = md5hex(signRaw)
        guard var comps = URLComponents(string: "https://fanyi-api.baidu.com/api/trans/vip/translate") else { completion(nil); return }
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: "zh"),
            URLQueryItem(name: "appid", value: appid),
            URLQueryItem(name: "salt", value: String(salt)),
            URLQueryItem(name: "sign", value: sign)
        ]
        guard let url = comps.url else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 60
        let start = Date()
        slAPISession().dataTask(with: req) { data, resp, err in
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            if let err = err { logDebug("[Baidu] error: \(err)"); DispatchQueue.main.async { self.status = "百度翻译请求失败（\(elapsed)s）：\(slDescribeError(err))" }; completion(nil); return }
            guard let data = data else { completion(nil); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logDebug("[Baidu] non-json"); completion(nil); return
            }
            if let code = json["error_code"] {
                let msg = json["error_msg"] as? String ?? "未知错误"
                logDebug("[Baidu] error_code=\(code) error_msg=\(msg)")
                DispatchQueue.main.async { self.status = "百度翻译失败：错误码 \(code) - \(msg)" }
                completion(nil); return
            }
            guard let results = json["trans_result"] as? [[String: Any]],
                  let dst = results.first?["dst"] as? String else {
                logDebug("[Baidu] no trans_result, body=\(String(data: data, encoding: .utf8) ?? "")"); completion(nil); return
            }
            completion(dst)
        }.resume()
    }

    /// MD5 32 位小写（CryptoKit，macOS 10.15+）
    private func md5hex(_ s: String) -> String {
        let d = Data(s.utf8)
        let digest = Insecure.MD5.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // 系统翻译引擎已移除：macOS 15 SDK 下 TranslationSession 无法后台批量调用，且挂主视图会白屏。翻译统一走自定义 API（见 callAPI/translate）。

    /// 批量翻译：对所有可写、非内置、有原解释的 skill 翻译并填入 customDesc（pending，点保存才写文件）。
    func batchTranslate() {
        // 只批量翻译左边筛选出来的 skill（filteredItems），按 id 映射回 items 真实下标写回
        let targets: [(Int, SkillItem)] = filteredItems.compactMap { it in
            guard let idx = items.firstIndex(where: { $0.id == it.id }) else { return nil }
            let item = items[idx]
            guard item.writable && !item.isBuiltin && !item.trueOrigDesc.isEmpty else { return nil }
            return (idx, item)
        }
        let total = targets.count
        guard total > 0 else {
            status = "当前筛选结果中没有可翻译的 skill（需为可写、非内置、且有原解释）。"
            return
        }
        if !apiConfigComplete() {
            status = "未配置 API。请在「设置」中填写 Base URL / Model / Key 后使用批量翻译。"
            self.showSettings = true
            return
        }
        isTranslating = true
        translateTotal = total
        translateDone = 0
        translateProgress = 0
        var done = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var failed = 0
            for (idx, it) in targets {
                let translated = self.translateSync(it.trueOrigDesc)
                if translated == nil { failed += 1 }
                DispatchQueue.main.async {
                    if let t = translated {
                        var item = self.items[idx]
                        item.customDesc = t
                        self.updateChangeState(for: &item)
                        self.items[idx] = item
                    }
                    done += 1
                    self.translateDone = done
                    self.translateProgress = total > 0 ? Double(done) / Double(total) : 1
                    if done < total {
                        self.status = "翻译中 \(done)/\(total)…"
                    }
                }
            }
            DispatchQueue.main.async {
                self.isTranslating = false
                self.translateProgress = 1
                self.status = "批量翻译完成 \(total) 个（已填入「中文解释」，请检查后点保存）。失败 \(failed) 个已跳过。"
            }
        }
    }

    /// 单条翻译：把指定 id 的 trueOrigDesc 翻译成中文填入 customDesc（pending）。
    func translateOne(id: UUID, completion: @escaping (Bool) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { completion(false); return }
        let it = items[idx]
        guard it.writable && !it.isBuiltin && !it.trueOrigDesc.isEmpty else { completion(false); return }
        if !apiConfigComplete() {
            status = "未配置 API。请在「设置」中配置自定义 API 后使用翻译此条。"
            self.showSettings = true
            completion(false); return
        }
        isTranslating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let t = self.translateSync(it.trueOrigDesc)
            DispatchQueue.main.async {
                self.isTranslating = false
                if let t = t {
                    var item = self.items[idx]
                    item.customDesc = t
                    self.updateChangeState(for: &item)
                    self.items[idx] = item
                    self.status = "已翻译「\(it.dirName)」，请检查后点保存。"
                    completion(true)
                } else {
                    if self.status.isEmpty {
                        self.status = "翻译「\(it.dirName)」失败，请检查网络 / API 配置。"
                    }
                    completion(false)
                }
            }
        }
    }

    func hasAnyChanges() -> Bool {
        items.contains { $0.hasChanges }
    }

    // MARK: - 导出/导入配置

    /// 导出当前已保存的本地化配置（各 skill 的 dir/name/desc）为 JSON 文件。建议「保存」后再导出，确保导出的就是磁盘真实状态。
    func exportConfig() {
        let entries: [SavedConfigEntry] = items.map {
            SavedConfigEntry(dir: $0.dirName, name: $0.savedName, desc: $0.savedDesc)
        }
        let file = SavedConfigFile(
            app: "SkillLocalizer",
            version: "1.1.9",
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            entries: entries
        )
        guard let data = try? JSONEncoder().encode(file) else {
            status = "导出失败：无法编码配置。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出本地化配置"
        panel.nameFieldStringValue = "skilllocalizer-config.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                status = "已导出 \(entries.count) 个 skill 的本地化配置到 \(url.lastPathComponent)。"
            } catch {
                status = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    /// 导入本地化配置 JSON：按 dir 比对本地 skill，重合>0 弹确认窗（沿用 b15 保存才执行）。
    func importConfig() {
        let panel = NSOpenPanel()
        panel.title = "导入本地化配置"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            importFrom(url: url)
        }
    }

    private func importFrom(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SavedConfigFile.self, from: data) else {
            status = "导入失败：文件格式不正确（需为导出的本地化配置 JSON）。"
            return
        }
        let localDirs = Set(items.map { $0.dirName })
        let matched = file.entries.filter { localDirs.contains($0.dir) }
        importSkippedCount = file.entries.count - matched.count
        if matched.isEmpty {
            status = "导入的配置在本地找不到对应 skill（共 \(file.entries.count) 个均不匹配），未应用任何改动。"
            return
        }
        pendingImportEntries = matched
        showImportConfirm = true
    }

    /// 确认应用导入：先备份当前本地已保存配置（便于还原），再把匹配项载入为待保存（点保存才写文件）。
    func applyImport() {
        showImportConfirm = false
        let entries = pendingImportEntries
        pendingImportEntries = []
        guard !entries.isEmpty else { return }

        // 1) 备份当前本地的「已保存」配置，方便还原
        let backups: [BackupEntry] = items.compactMap { it in
            guard entries.contains(where: { $0.dir == it.dirName }) else { return nil }
            return BackupEntry(dir: it.dirName, path: it.skillPath, originalName: it.savedName, originalDesc: it.savedDesc, originalMetaName: it.savedMetaName, metaPath: it.metaPath)
        }
        if !backups.isEmpty { saveBackup(entries: backups) }

        // 2) 载入为待保存（延续 b15 保存才执行）
        var applied = 0
        for entry in entries {
            if let idx = items.firstIndex(where: { $0.dirName == entry.dir }) {
                var it = items[idx]
                guard it.writable && !it.isBuiltin else { continue }
                it.customName = entry.name
                it.customDesc = entry.desc
                updateChangeState(for: &it)
                items[idx] = it
                applied += 1
            }
        }
        var msg = "已应用导入：载入 \(applied) 个 skill 的导入名称/解释为待保存项（已备份原配置供还原）。请检查后点「保存」写入文件。"
        if importSkippedCount > 0 {
            msg += "另有 \(importSkippedCount) 个在本地无对应 skill 已跳过。"
        }
        status = msg
    }
}

// MARK: - Views

struct SkillDetail: View {
    @Binding var item: SkillItem
    @ObservedObject var state: AppState
    @State private var justCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(item.dirName)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if item.isBuiltin {
                        badge("内置", Color.red)
                    } else if !item.writable {
                        badge("只读", Color.orange)
                    }
                    if item.hasChanges {
                        badge("有未保存修改", Color.blue)
                    }
                }

                // 来源地址（该 skill 所在目录）
                HStack(spacing: 4) {
                    Text("来源：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(item.dirURL.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("在 Finder 中打开") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: item.dirURL.path))
                    }
                    .font(.caption)
                }
                HStack(spacing: 4) {
                    Text("安装来源：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(item.source.isEmpty ? "未知" : item.source)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 4) {
                    Text("添加日期：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(item.addedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "未知")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button(item.pendingRestore ? "取消恢复" : "恢复此 skill 最初") {
                        item.pendingRestore.toggle()
                    }
                    .disabled(!item.writable || item.isBuiltin)
                    .help("把当前右侧显示的这个 skill 还原为最初真实原始（从最早备份找回）。点保存后才真正执行。")
                }
                if item.pendingRestore {
                    Text("⏳ 已请求恢复，点顶部「保存」后生效。")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                // ===== 第一段：最初（只读，始终显示真实原始）=====
                sectionTitle("最初（只读 · 真实原始）")
                labeledReadOnly("最初原名", item.trueOrigName)
                // 最初原解释 + 复制按钮
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("最初原解释")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(justCopied ? "已复制 ✓" : "复制") { copyOriginalDesc() }
                            .font(.caption)
                            .disabled(item.trueOrigDesc.isEmpty)
                    }
                    ScrollView {
                        Text(item.trueOrigDesc.isEmpty ? "（无）" : item.trueOrigDesc)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                }
                if item.baselineName != item.trueOrigName || item.baselineDesc != item.trueOrigDesc {
                    Text("注意：打开 App 时该 skill 已被改过，上面是从备份找回的最早真实原始值。")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                Divider()

                // ===== 第二段：改过的（当前已保存，保存后覆盖）=====
                sectionTitle("改过的（当前已保存）")
                let sameAsInitial = (item.savedName == item.trueOrigName) && (item.savedDesc == item.trueOrigDesc)
                if sameAsInitial {
                    Text("未更改")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } else {
                    labeledReadOnly("显示名", item.savedName)
                    labeledReadOnly("解释", item.savedDesc.isEmpty ? "（无）" : item.savedDesc)
                }

                Divider()

                // ===== 第三段：继续修改（可编辑，保存后覆盖“改过的”）=====
                sectionTitle("继续修改（保存后覆盖上面的“改过的”）")
                HStack(spacing: 8) {
                    TextField("中文前缀", text: $item.prefix)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 160)
                        .disabled(!item.writable || item.isBuiltin)
                    Text("或")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("完整中文名", text: $item.customName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(!item.writable || item.isBuiltin)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("中文解释")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $item.customDesc)
                        .font(.callout)
                        .frame(height: 160)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                        .disabled(!item.writable || item.isBuiltin)
                }
                HStack {
                    Button(state.isTranslating ? "翻译中…" : "翻译此条") {
                        state.translateOne(id: item.id) { _ in }
                    }
                    .disabled(!item.writable || item.isBuiltin || item.trueOrigDesc.isEmpty || state.isTranslating)
                    .help("把『最初原解释』翻译成中文填入上面的『中文解释』")
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("预览显示名：\(item.name)")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("预览解释：\(item.desc)")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding(20)
        }
        .onChange(of: item.prefix) { _ in state.updateChangeState(for: &item) }
        .onChange(of: item.customName) { _ in state.updateChangeState(for: &item) }
        .onChange(of: item.customDesc) { _ in state.updateChangeState(for: &item) }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.primary)
            .padding(.top, 4)
    }
    private func labeledReadOnly(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
    private func copyOriginalDesc() {
        let text = item.trueOrigDesc
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            justCopied = false
        }
    }
    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(c.opacity(0.2))
            .cornerRadius(4)
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var selectedId: UUID? = nil
    @AppStorage("sl_provider") private var provider = "custom"

    private var providerName: String {
        switch provider {
        case "siliconflow": return "硅基流动"
        case "baidu": return "百度翻译开放平台"
        case "zhipu": return "智谱 AI"
        default: return "自定义 OpenAI 兼容"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜索 skill", text: $state.search)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Toggle("仅改", isOn: $state.showOnlyModified)
                        .help("只看已修改")
                    Toggle("英文", isOn: $state.showOnlyEnglish)
                        .help("只看仍含英文解释的 skill")
                }
                .padding(8)
                Divider()
                List(state.filteredItems, selection: $selectedId) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if item.hasChanges {
                            Text("未保存修改")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        } else if item.modifiedFromOriginal {
                            Text("已修改")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        } else if item.hasEnglishDesc {
                            Text("英文")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                    .tag(item.id)
                }
                .listStyle(SidebarListStyle())
                if state.showOnlyEnglish && state.filteredItems.isEmpty {
                    Text("（已全部本地化 ✓ 没有仍含英文的 skill）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                } else if state.showOnlyModified && state.filteredItems.isEmpty {
                    Text("（当前没有已改的 skill）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                }
                let enCount = state.items.filter { $0.hasEnglishDesc }.count
                Text("仍有 \(enCount) 个含英文解释")
                    .font(.caption)
                    .foregroundColor(enCount > 0 ? .red : .secondary)
                    .padding(8)
            }
            .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text("接口：\(providerName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                    Button(state.isTranslating ? "翻译中…" : "批量翻译") {
                        state.batchTranslate()
                    }
                    .disabled(state.isTranslating)
                    Spacer()
                    Button(state.pendingRestoreAll ? "取消全部恢复" : "全部恢复最初") {
                        state.pendingRestoreAll.toggle()
                    }
                    .disabled(!state.items.contains { $0.writable && !$0.isBuiltin })
                    if state.pendingRestoreAll {
                        Text("⏳ 保存后生效")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Button("保存") { state.doSave() }
                        .disabled(!state.hasAnyChanges() && !state.pendingRestoreAll && !state.items.contains { $0.pendingRestore })
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("关于") { state.showAbout = true }
                    Button("设置") { state.showSettings = true }
                    Button("导出配置") { state.exportConfig() }
                    Button("导入配置") { state.importConfig() }
                }
                .padding(8)
                HStack {
                    if state.isTranslating {
                        ProgressView(value: state.translateProgress) {
                            EmptyView()
                        }
                        .frame(width: 220)
                        Text("\(state.translateDone)/\(state.translateTotal)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if !state.status.isEmpty {
                        Text(state.status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                Divider()

                if let idx = state.items.firstIndex(where: { $0.id == selectedId }) {
                    SkillDetail(item: $state.items[idx], state: state)
                } else {
                    VStack {
                        Spacer()
                        Text("从左侧选择一个 skill")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            state.loadSkills()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if selectedId == nil { selectedId = state.items.first?.id }
            }
        }
        .sheet(isPresented: $state.showAbout) {
            AboutView()
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsView()
        }
        .alert("应用导入配置？", isPresented: $state.showImportConfirm) {
            Button("取消", role: .cancel) {
                state.showImportConfirm = false
                state.pendingImportEntries = []
            }
            Button("应用") { state.applyImport() }
        } message: {
            Text("导入的配置将覆盖 \(state.pendingImportEntries.count) 个本地 skill 的名称/解释（载入为待保存，点「保存」后才写入文件）。应用前已自动备份原配置，可随时还原。")
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("SkillLocalizer")
                .font(.title)
            Text("版本 1.1.9")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("将 WorkBuddy skill 的显示名与解释本地化为中文。")
                .multilineTextAlignment(.center)
            Text("修改范围：用户级 ~/.workbuddy/skills/ 下的 SKILL.md 与 _skillhub_meta.json 等 meta 文件。目录名不变，故对话 @ 与自动化旧引用继续生效。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Text("MIT License · 由 半秋 维护")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(30)
        .frame(width: 420)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider: String
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String
    @State private var appid: String
    @State private var testResult: String = ""

    init() {
        let ud = UserDefaults.standard
        let p = ud.string(forKey: SLSettings.providerKey) ?? "custom"
        _provider = State(initialValue: p)
        _baseURL = State(initialValue: ud.string(forKey: SLSettings.baseKey(p)) ?? "")
        _model = State(initialValue: ud.string(forKey: SLSettings.modelKey(p)) ?? "")
        _apiKey = State(initialValue: KeychainHelper.read(account: SLSettings.keyAccount(p)) ?? "")
        _appid = State(initialValue: ud.string(forKey: SLSettings.appidKey(p)) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("翻译设置").font(.headline)
            Picker("接口预设", selection: $provider) {
                Text("自定义 OpenAI 兼容").tag("custom")
                Text("硅基流动").tag("siliconflow")
                Text("智谱 AI").tag("zhipu")
                Text("百度翻译开放平台").tag("baidu")
            }
            .pickerStyle(SegmentedPickerStyle())
            .onChange(of: provider) { applyPreset($0) }
            Text("本机（macOS 15）下系统翻译无法在后台批量调用，已移除。翻译统一通过 API。选「百度翻译开放平台」将自动填入百度翻译开放平台传统接口地址，需填 AppID 与 Secret Key（Key 不自动填）。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(label: Text(provider == "baidu" ? "百度翻译开放平台（传统 API）" : "自定义 API（OpenAI 兼容）").font(.caption)) {
                VStack(alignment: .leading, spacing: 8) {
                    if provider == "baidu" {
                        TextField("接口地址（自动）", text: $baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .disabled(true)
                        TextField("AppID（百度翻译开放平台）", text: $appid)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        SecureField("API Key / 密钥（百度开放平台控制台获取）", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Text("百度翻译接口需 AppID + API Key / 密钥，App 自动计算 MD5 签名；Key 不落明文。")
                            .font(.caption2).foregroundColor(.secondary)
                    } else {
                        TextField("Base URL（如 https://api.siliconflow.cn/v1）", text: $baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField("Model（如 Qwen/Qwen2.5-7B-Instruct）", text: $model)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        SecureField("API Key（仅存于系统钥匙串）", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Text("支持任意 OpenAI 兼容端点：硅基流动、智谱 AI、Groq、OpenRouter 等。Key 不落明文，存于系统钥匙串。")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Button("测试连接") { testConnection() }
                    if !testResult.isEmpty {
                        Text(testResult).font(.caption).foregroundColor(.secondary)
                    }
                }.padding(8)
            }

            Spacer()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存设置") { save(); dismiss() }.keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(width: 480, height: 380)
    }

    private func applyPreset(_ p: String) {
        let ud = UserDefaults.standard
        // 先加载该预设已保存的凭证（base/model/key/appid 各自独立），再对预设项覆盖自动值
        baseURL = ud.string(forKey: SLSettings.baseKey(p)) ?? ""
        model = ud.string(forKey: SLSettings.modelKey(p)) ?? ""
        apiKey = KeychainHelper.read(account: SLSettings.keyAccount(p)) ?? ""
        appid = ud.string(forKey: SLSettings.appidKey(p)) ?? ""
        switch p {
        case "siliconflow":
            baseURL = "https://api.siliconflow.cn/v1"
            model = "Qwen/Qwen2.5-7B-Instruct"
        case "zhipu":
            // 智谱 AI OpenAI 兼容端点（免费模型 glm-4-flash）
            baseURL = "https://open.bigmodel.cn/api/paas/v4"
            model = "glm-4-flash"
        case "baidu":
            // 百度翻译开放平台传统 API（非 OpenAI 兼容）：自动填接口地址，model 作占位（百度不使用 model）
            baseURL = "https://fanyi-api.baidu.com/api/trans/vip/translate"
            model = "baidu"
        default:
            break // 自定义：保留用户当前填写
        }
        // API Key 不自动填，仍由用户手动输入（但会加载该预设已保存的 key）
    }

    private func save() {
        let ud = UserDefaults.standard
        let p = provider
        ud.set(p, forKey: SLSettings.providerKey)
        ud.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SLSettings.baseKey(p))
        ud.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SLSettings.modelKey(p))
        ud.set(appid.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SLSettings.appidKey(p))
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty {
            KeychainHelper.delete(account: SLSettings.keyAccount(p))
        } else {
            KeychainHelper.save(account: SLSettings.keyAccount(p), value: k)
        }
    }

    private func testConnection() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "baidu" {
            let a = appid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty, !key.isEmpty else {
                testResult = "请先填 AppID 与 API Key / 密钥"; return
            }
            testResult = "测试中…"
            let salt = Int.random(in: 10000...65536)
            let sign = md5hex(a + "ping" + String(salt) + key)
            guard var comps = URLComponents(string: "https://fanyi-api.baidu.com/api/trans/vip/translate") else {
                testResult = "接口地址无效"; return
            }
            comps.queryItems = [
                URLQueryItem(name: "q", value: "ping"),
                URLQueryItem(name: "from", value: "auto"),
                URLQueryItem(name: "to", value: "zh"),
                URLQueryItem(name: "appid", value: a),
                URLQueryItem(name: "salt", value: String(salt)),
                URLQueryItem(name: "sign", value: sign)
            ]
            guard let url = comps.url else { testResult = "接口地址无效"; return }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 60
            let start = Date()
            slAPISession().dataTask(with: req) { data, resp, err in
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
                DispatchQueue.main.async {
                    if let err = err { testResult = "失败（\(elapsed)s）：\(slDescribeError(err))"; return }
                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        testResult = "失败：返回非预期"; return
                    }
                    if let code = json["error_code"] {
                        let msg = json["error_msg"] as? String ?? "未知错误"
                        testResult = "失败（\(code)）：\(msg)"; return
                    }
                    guard let results = json["trans_result"] as? [[String: Any]],
                          results.first?["dst"] != nil else {
                        testResult = "失败：返回无译文"; return
                    }
                    testResult = "连接成功 ✓（百度翻译可用，\(elapsed)s）"
                }
            }.resume()
            return
        }
        // OpenAI 兼容
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let mdl = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !mdl.isEmpty, !key.isEmpty else {
            testResult = "请先填 Base URL / Model / Key"; return
        }
        testResult = "测试中…"
        let endpoint = base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions"
        guard let url = URL(string: endpoint) else { testResult = "Base URL 无效"; return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": mdl, "messages": [["role": "user", "content": "ping"]], "temperature": 0.3]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let start = Date()
        slAPISession().dataTask(with: req) { data, resp, err in
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            DispatchQueue.main.async {
                if let err = err { testResult = "失败（\(elapsed)s）：\(slDescribeError(err))"; return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    testResult = "失败：返回非预期"; return
                }
                if let choices = json["choices"] as? [[String: Any]], !choices.isEmpty {
                    testResult = "连接成功 ✓（\(elapsed)s）"; return
                }
                var errMsg = "返回非预期（可能 key 无效 / 额度不足 / 模型名错）"
                if let m = json["message"] as? String, !m.isEmpty { errMsg = m }
                else if let e = json["error"] as? [String: Any], let m = e["message"] as? String, !m.isEmpty { errMsg = m }
                else if let m = json["error_message"] as? String, !m.isEmpty { errMsg = m }
                testResult = "失败：\(errMsg)"
            }
        }.resume()
    }

    private func md5hex(_ s: String) -> String {
        let d = Data(s.utf8)
        let digest = Insecure.MD5.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 共享网络会话：读系统代理 + 环境变量代理（覆盖终端 curl 通但原生 App 不通的场景），超时 60s
private var _slAPISession: URLSession?
private func slAPISession() -> URLSession {
    if let s = _slAPISession { return s }
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 60
    cfg.timeoutIntervalForResource = 120
    let env = ProcessInfo.processInfo.environment
    let raw = env["https_proxy"] ?? env["HTTPS_PROXY"] ?? env["http_proxy"] ?? env["HTTP_PROXY"] ?? env["all_proxy"] ?? env["ALL_PROXY"]
    if let raw = raw, let comps = URLComponents(string: raw), let h = comps.host, let p = comps.port {
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": h, "HTTPPort": p,
            "HTTPSEnable": 1, "HTTPSProxy": h, "HTTPSPort": p
        ]
        logDebug("[net] 使用环境变量代理 \(h):\(p)")
    }
    let s = URLSession(configuration: cfg)
    _slAPISession = s
    return s
}

// MARK: - 网络错误友好描述（带原始 domain + code，便于区分 超时/连不上/找不到主机）
private func slDescribeError(_ err: Error) -> String {
    let ns = err as NSError
    let name: String
    switch (ns.domain, ns.code) {
    case (NSURLErrorDomain, -1001): name = "请求超时"
    case (NSURLErrorDomain, -1004): name = "无法连接主机"
    case (NSURLErrorDomain, -1003): name = "找不到主机"
    case (NSURLErrorDomain, -1009): name = "无网络连接"
    case (NSURLErrorDomain, -1200): name = "SSL/TLS 错误"
    case (NSURLErrorDomain, -1005): name = "网络连接丢失"
    case (NSURLErrorDomain, -1012): name = "鉴权失败"
    default: name = ns.domain
    }
    return "\(name) (\(ns.domain) \(ns.code))"
}

@main
struct SkillLocalizerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
    }
}
