import Darwin
import Foundation
import Security

public enum DatabaseKeyError: Error, LocalizedError {
  case invalidKeyLength(Int)
  case keychain(OSStatus)
  case randomGeneration(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidKeyLength(let length):
      "Database key must be 32 bytes, got \(length)."
    case .keychain(let status):
      "Keychain operation failed with status \(status)."
    case .randomGeneration(let status):
      "Secure random key generation failed with status \(status)."
    }
  }
}

public enum DatabaseKeyProvider {
  private enum LoadResult {
    case success(Data)
    case failure(OSStatus)
  }

  private static let service = "ai.rapp.recall"
  private static let account = "database-master-key-v1"

  public static var accessMode: String {
    hasStableSigningTeam ? "application-bound-keychain" : "local-key-file"
  }

  public static func loadOrCreate() throws -> Data {
    if !hasStableSigningTeam {
      return try loadOrCreateLocalKeyFile()
    }
    return try loadOrCreateApplicationBoundKeychainItem()
  }

  private static func loadOrCreateApplicationBoundKeychainItem() throws -> Data {
    switch load() {
    case .success(let key):
      return try validate(key)
    case .failure(let status) where status == errSecItemNotFound:
      break
    case .failure(let status):
      throw DatabaseKeyError.keychain(status)
    }

    var bytes = Data(count: 32)
    let randomStatus = bytes.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw DatabaseKeyError.randomGeneration(randomStatus)
    }

    let addStatus = addApplicationBound(bytes)
    if addStatus == errSecDuplicateItem {
      switch load() {
      case .success(let key):
        return try validate(key)
      case .failure(let status):
        throw DatabaseKeyError.keychain(status)
      }
    }
    guard addStatus == errSecSuccess else {
      throw DatabaseKeyError.keychain(addStatus)
    }
    return bytes
  }

  private static func load() -> LoadResult {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return .failure(status) }
    guard let storedData = result as? Data else {
      return .failure(errSecDecode)
    }
    if storedData.count == 32 {
      return .success(storedData)
    }
    guard let decoded = Data(base64Encoded: storedData), decoded.count == 32 else {
      return .failure(errSecDecode)
    }
    return .success(decoded)
  }

  private static func validate(_ key: Data) throws -> Data {
    guard key.count == 32 else {
      throw DatabaseKeyError.invalidKeyLength(key.count)
    }
    return key
  }

  private static func addApplicationBound(_ key: Data) -> OSStatus {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecValueData: key,
    ]
    return SecItemAdd(query as CFDictionary, nil)
  }

  private static func loadOrCreateLocalKeyFile() throws -> Data {
    let fileManager = FileManager.default
    let keyURL: URL
    let ownsKeyDirectory: Bool
    if let override = getenv("RAPP_RECALL_LOCAL_KEY_PATH"), override.pointee != 0 {
      keyURL = URL(fileURLWithPath: String(cString: override)).standardizedFileURL
      ownsKeyDirectory = false
    } else {
      keyURL =
        fileManager.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        .appending(path: "ai.rapp.recall.keys", directoryHint: .isDirectory)
        .appending(path: account, directoryHint: .notDirectory)
      ownsKeyDirectory = true
    }
    let directory = keyURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    if ownsKeyDirectory {
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
    if fileManager.fileExists(atPath: keyURL.path) {
      return try validate(Data(contentsOf: keyURL))
    }

    var key = Data(count: 32)
    let randomStatus = key.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw DatabaseKeyError.randomGeneration(randomStatus)
    }

    let descriptor = Darwin.open(
      keyURL.path,
      O_WRONLY | O_CREAT | O_EXCL,
      S_IRUSR | S_IWUSR
    )
    if descriptor < 0 {
      if errno == EEXIST {
        return try validate(Data(contentsOf: keyURL))
      }
      throw CocoaError(.fileWriteUnknown)
    }
    defer { Darwin.close(descriptor) }

    let written = key.withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    guard written == key.count, Darwin.fsync(descriptor) == 0 else {
      try? fileManager.removeItem(at: keyURL)
      throw CocoaError(.fileWriteUnknown)
    }
    return key
  }

  private static var hasStableSigningTeam: Bool {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
      let code
    else {
      return false
    }
    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else {
      return false
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let dictionary = information as? [CFString: Any]
    else {
      return false
    }
    return dictionary[kSecCodeInfoTeamIdentifier] as? String != nil
  }
}
