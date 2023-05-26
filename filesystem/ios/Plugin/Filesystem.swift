import Foundation
import Combine

// MetadataItem is a wrapper of NSMetadataItem.
// When users rename an item, nsMetadataItem is the same, but the URL is different.
// Use url.path to implement Hashable and Equatable because only url.path is visible.
//
struct MetadataItem: Hashable {
    let nsMetadataItem: NSMetadataItem?
    let url: URL
    
    static func == (lhs: MetadataItem, rhs: MetadataItem) -> Bool {
        return lhs.url.path == rhs.url.path
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }
}

extension Notification.Name {
    static let sicdMetadataDidChange = Notification.Name("sicdMetadataDidChange")
}

@available(iOS 13.0, *)
class MetadataProvider {
    
    // Give userInfo a stronger type.
    //
    typealias MetadataDidChangeUserInfo = [MetadataDidChangeUserInfoKey: [MetadataItem]]
    enum MetadataDidChangeUserInfoKey: String {
        case queryResults
    }
    
    private(set) var containerRootURL: URL?
    public let metadataQuery = NSMetadataQuery()
    private var querySubscriber: AnyCancellable?
    
    // Failable init: fails if there isn’t a logged-in iCloud account.
    //
    init?(containerIdentifier: String?, fu: @escaping () -> Void, fs: Filesystem) {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            print("⛔️ iCloud isn't enabled yet. Please enable iCloud and run again.")
            return nil
        }
        
        // Dispatch to a global queue because url(forUbiquityContainerIdentifier:) might take a nontrivial
        // amount of time to set up iCloud and return the requested URL
        //
        DispatchQueue.global().async {
            if let url = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) {
                DispatchQueue.main.async {
                    self.containerRootURL = url
                    
                    let names: [NSNotification.Name] = [.NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering]
                    let publishers = names.map { NotificationCenter.default.publisher(for: $0) }
                    
                    self.querySubscriber = Publishers.MergeMany(publishers).receive(on: DispatchQueue.main).sink { notification in
                        // ловим событие обновления айклауда
                        print("iCloud updated event")
                        
                        var updatedFiles : [String] = []
                        
                        if let notifUserInfo = notification.userInfo {
                            for (kind, numbers) in notifUserInfo {
                                let baseEvent = kind as? String
                                if let uinf2 = numbers as? NSMutableArray {
                                    for ddk in uinf2 {
                                        if let ddk2 = ddk as? NSMetadataItem {
                                            let fn = ddk2.value(forAttribute: "kMDItemFSName")! as? String
                                            let isDownloadingKey = ddk2.value(forAttribute: "NSMetadataUbiquitousItemIsDownloadingKey")! as? Int
                                            let isUploadingKey = ddk2.value(forAttribute: "NSMetadataUbiquitousItemIsUploadingKey")! as? Int
                                            let isDownloadedKey = ddk2.value(forAttribute: "NSMetadataUbiquitousItemIsDownloadedKey")! as? Int
                                            let isUploadedKey = ddk2.value(forAttribute: "NSMetadataUbiquitousItemIsUploadedKey")! as? Int
                                            
                                            if (isDownloadingKey == 0 && isUploadingKey == 0 && isDownloadedKey == 1 && isUploadedKey == 1) {
                                                updatedFiles.append((fn ?? "") + "|"+(baseEvent ?? ""))
                                                //print(ddk2.values(forAttributes: ddk2.attributes))
                                            }
                                            
                                        }
                                    }
                                }
                            }
                        }
                        
                        // если есть обновленные - то запускаем событие в js и показываем что поменялось
                        if (updatedFiles.count > 0) {
                            print("Updated Files")
                            //print(updatedFiles)
                            fs.setUpdatedFiles(uf: updatedFiles)
                            fu() // updatedFiles: updatedFiles
                        }
                        
                        // идем по всем на кого есть метадата, и кого нет - скачиваем (в момент какого-то эвента.. если нет
                        // эвента то никогда и не скачаем... проблемка... надо бы при инициализации тоже делать)
                        guard notification.object as? NSMetadataQuery === self.metadataQuery else { return }
                        let vvv = self.metadataItemList()
                        for ddk in vvv {
                            let ddk2 = ddk.nsMetadataItem!
                            let fn = ddk2.value(forAttribute: "kMDItemDisplayName")! as? String
                            let isDownloadRequested = ddk2.value(forAttribute: "NSMetadataUbiquitousItemDownloadRequestedKey")! as? Int
                            if (isDownloadRequested == 0) {
                                print("Downloading " + (fn ?? "")) // kMDItemURL
                                do {
                                    try FileManager.default.startDownloadingUbiquitousItem(at: ddk.url)
                                } catch {
                                  print("Download error: \(error).")
                                }
                            }
                        }
                        // конец
                    }
                                        
                    // Set up a metadata query to gather document changes in the iCloud container.
                    //
                    self.metadataQuery.notificationBatchingInterval = 1
                    self.metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
                    self.metadataQuery.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
                    self.metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
                    self.metadataQuery.start()
                }
                return
            }
            print("⛔️ Failed to retrieve iCloud container URL for:\(containerIdentifier ?? "nil")\n"
                    + "Make sure your iCloud is available and run again.")
        }
        
        // Observe and handle NSMetadataQuery's notifications.
        // Posts .metadataDidChange from the main queue and returns after clients finish handling it.
        //

    }
    
    // Stop metadataQuery if it is still running.
    //
    deinit {
        guard metadataQuery.isStarted else { return }
        metadataQuery.stop()
    }
}

// MARK: - Providing metadata items
//
@available(iOS 13.0, *)
extension MetadataProvider {
    
    // Convert nsMetataItems to a MetadataItem array.
    // Filter out directory items and items that don't have a valid item URL.
    // Note that querying the .isDirectoryKey key from a file results in failure.
    //
    private func metadataItemList(from nsMetataItems: [NSMetadataItem]) -> [MetadataItem] {
        let validItems = nsMetataItems.filter { item in
            guard let fileURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  item.value(forAttribute: NSMetadataItemFSNameKey) != nil else { return false }
            
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            if let resourceValues = try? (fileURL as NSURL).resourceValues(forKeys: resourceKeys),
                let isDirectory = resourceValues[URLResourceKey.isDirectoryKey] as? Bool, isDirectory,
                let isPackage = resourceValues[URLResourceKey.isPackageKey] as? Bool, !isPackage {
                return false
            }
            return true
        }
        
        // Valid items have a valid item URL and file system name,
        // so unwrap the optionals directly.
        //
        return validItems.sorted {
            let name0 = $0.value(forAttribute: NSMetadataItemFSNameKey) as? String
            let name1 = $1.value(forAttribute: NSMetadataItemFSNameKey) as? String
            return name0! < name1!
        } .map {
            let itemURL = $0.value(forAttribute: NSMetadataItemURLKey) as? URL
            return MetadataItem(nsMetadataItem: $0, url: itemURL!)
        }
    }
    
    // Provide metadataItems directly from the query.
    // To avoid potential conflicts, disable the query update when accessing the results,
    // and enable it after finishing the access.
    //
    func metadataItemList() -> [MetadataItem] {
        var result = [MetadataItem]()
        metadataQuery.disableUpdates()
        if let metadatItems = metadataQuery.results as? [NSMetadataItem] {
            result = metadataItemList(from: metadatItems)
        }
        metadataQuery.enableUpdates()
        return result
    }
}











@available(iOS 13.0, *)
@objc public class Filesystem: NSObject {

    public enum FilesystemError: LocalizedError {
        case noParentFolder, noSave, failEncode, noAppend, notEmpty

        public var errorDescription: String? {
            switch self {
            case .noParentFolder:
                return "Parent folder doesn't exist"
            case .noSave:
                return "Unable to save file"
            case .failEncode:
                return "Unable to encode data to utf-8"
            case .noAppend:
                return "Unable to append file"
            case .notEmpty:
                return "Folder is not empty"
            }
        }
    }

    public func readFile(at fileUrl: URL, with encoding: String?) throws -> String {
        if encoding != nil {
            let data = try String(contentsOf: fileUrl, encoding: .utf8)
            return data
        } else {
            let data = try Data(contentsOf: fileUrl)
            return data.base64EncodedString()
        }
    }

    public func writeFile(at fileUrl: URL, with data: String, recursive: Bool, with encoding: String?) throws -> String {
        if !FileManager.default.fileExists(atPath: fileUrl.deletingLastPathComponent().path) {
            if recursive {
                try FileManager.default.createDirectory(at: fileUrl.deletingLastPathComponent(), withIntermediateDirectories: recursive, attributes: nil)
            } else {
                throw FilesystemError.noParentFolder
            }
        }
        if encoding != nil {
            try data.write(to: fileUrl, atomically: false, encoding: .utf8)
        } else {
            if let base64Data = Data.capacitor.data(base64EncodedOrDataUrl: data) {
                try base64Data.write(to: fileUrl)
            } else {
                throw FilesystemError.noSave
            }
        }
        return fileUrl.absoluteString
    }

    @objc public func appendFile(at fileUrl: URL, with data: String, recursive: Bool, with encoding: String?) throws {
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            let fileHandle = try FileHandle.init(forWritingTo: fileUrl)
            var writeData: Data?
            if encoding != nil {
                guard let userData = data.data(using: .utf8) else {
                    throw FilesystemError.failEncode
                }
                writeData = userData
            } else {
                if let base64Data = Data.capacitor.data(base64EncodedOrDataUrl: data) {
                    writeData = base64Data
                } else {
                    throw FilesystemError.noAppend
                }
            }
            defer {
                fileHandle.closeFile()
            }
            fileHandle.seekToEndOfFile()
            fileHandle.write(writeData!)
        } else {
            _ = try writeFile(at: fileUrl, with: data, recursive: recursive, with: encoding)
        }
    }

    @objc func deleteFile(at fileUrl: URL) throws {
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            try FileManager.default.removeItem(atPath: fileUrl.path)
        }
    }

    @objc public func mkdir(at fileUrl: URL, recursive: Bool) throws {
        try FileManager.default.createDirectory(at: fileUrl, withIntermediateDirectories: recursive, attributes: nil)
    }

    @objc public func rmdir(at fileUrl: URL, recursive: Bool) throws {
        let directoryContents = try FileManager.default.contentsOfDirectory(at: fileUrl, includingPropertiesForKeys: nil, options: [])
        if directoryContents.count != 0 && !recursive {
            throw FilesystemError.notEmpty
        }
        try FileManager.default.removeItem(at: fileUrl)
    }

    public func readdir(at fileUrl: URL) throws -> [URL] {
        return try FileManager.default.contentsOfDirectory(at: fileUrl, includingPropertiesForKeys: nil, options: [])
    }

    func stat(at fileUrl: URL) throws -> [FileAttributeKey: Any] {
        return try FileManager.default.attributesOfItem(atPath: fileUrl.path)
    }

    func getType(from attr: [FileAttributeKey: Any]) -> String {
        let fileType = attr[.type] as? String ?? ""
        if fileType == "NSFileTypeDirectory" {
            return "directory"
        } else {
            return "file"
        }
    }

    @objc public func rename(at srcURL: URL, to dstURL: URL) throws {
        try _copy(at: srcURL, to: dstURL, doRename: true)
    }

    @objc public func copy(at srcURL: URL, to dstURL: URL) throws {
        try _copy(at: srcURL, to: dstURL, doRename: false)
    }

    /**
     * Copy or rename a file or directory.
     */
    private func _copy(at srcURL: URL, to dstURL: URL, doRename: Bool) throws {
        if srcURL == dstURL {
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dstURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                try? FileManager.default.removeItem(at: dstURL)
            }
        }

        if doRename {
            try FileManager.default.moveItem(at: srcURL, to: dstURL)
        } else {
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        }

    }

    /**
     * Get the SearchPathDirectory corresponding to the JS string
     */
    public func getDirectory(directory: String?) -> FileManager.SearchPathDirectory? {
        if let directory = directory {
            switch directory {
            case "CACHE":
                return .cachesDirectory
            case "LIBRARY":
                return .libraryDirectory
            default:
                return .documentDirectory
            }
        }
        return nil
    }

    /**
     * Get the URL for this file, supporting file:// paths and
     * files with directory mappings.
     */
    @objc public func getFileUrl(at path: String, in directory: String?) -> URL? {
        if let directory = getDirectory(directory: directory) {
            guard let dir = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
                return nil
            }
            if !path.isEmpty {
                return dir.appendingPathComponent(path)
            }
            return dir
        } else {
            return URL(string: path)
        }
    }

    public func moveFilesToCloud() -> String {
        if (FileManager.default.ubiquityIdentityToken == nil) {
            return "ICLOUDISOFF"
        }
        let localDocumentsURL = FileManager.default.urls(for: FileManager.SearchPathDirectory.documentDirectory, in: .userDomainMask).last!
        let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("")
        let enumerator = FileManager.default.enumerator(atPath: localDocumentsURL.path)
        while let file = enumerator?.nextObject() as? String {
            do {
                try FileManager.default.copyItem(at: localDocumentsURL.appendingPathComponent(file), to: iCloudDocumentsURL!.appendingPathComponent(file))
            } catch let error as NSError {
                print("Failed to move file to Cloud : \(error)")
            }
        }
        deleteFilesInDirectory(url: localDocumentsURL);
        return "OK"
    }
    
    public func moveFilesToLocal() -> String {
        if (FileManager.default.ubiquityIdentityToken == nil) {
            return "ICLOUDISOFF"
        }
        let localDocumentsURL = FileManager.default.urls(for: FileManager.SearchPathDirectory.documentDirectory, in: .userDomainMask).last!
        let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("")
        deleteFilesInDirectory(url: localDocumentsURL);
        let enumerator = FileManager.default.enumerator(atPath: iCloudDocumentsURL!.path)
        while let file = enumerator?.nextObject() as? String {
            do {
                try FileManager.default.copyItem(at: iCloudDocumentsURL!.appendingPathComponent(file), to: localDocumentsURL.appendingPathComponent(file))
            } catch let error as NSError {
                print("Failed to move file to Local : \(error)")
            }
        }
        deleteFilesInDirectory(url: iCloudDocumentsURL!);
        return "OK"
    }
    
    private func deleteFilesInDirectory(url: URL?) {
        let enumerator = FileManager.default.enumerator(atPath: url!.path)
        while let file = enumerator?.nextObject() as? String {
            do {
                try FileManager.default.removeItem(at: url!.appendingPathComponent(file))
                print("Files deleted")
            } catch let error as NSError {
                print("Failed deleting files : \(error)")
            }
        }
    }    
    
    // запускается при запуске приложения... и в теории висит... потестить на скрытие прилы...
    public func observeDir(directory: String, f: @escaping () -> Void) {
        if (directory == "CLOUD" && FileManager.default.ubiquityIdentityToken != nil) {
            print("observeDir MetadataProvider")
            metadataProvider = MetadataProvider(containerIdentifier: nil, fu: {
                f()
            }, fs: self)
        } else {
            print("observeDir nil")
            metadataProvider = nil
        }
    }
}
