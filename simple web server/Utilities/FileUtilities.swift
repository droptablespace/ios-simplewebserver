//
//  FileUtilities.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import Foundation

class FileUtilities {
    
    // MARK: - File Type Detection
    
    static func isImageFile(_ filename: String) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif"]
        let ext = (filename as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
    
    static func isVideoFile(_ filename: String) -> Bool {
        let videoExtensions = ["mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg", "3gp"]
        let ext = (filename as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }
    
    // MARK: - MIME Type Detection
    
    static func mimeTypeForPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        
        switch ext {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "mp4", "m4v", "mov": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "flv": return "video/x-flv"
        case "wmv": return "video/x-ms-wmv"
        case "mpg", "mpeg": return "video/mpeg"
        case "3gp": return "video/3gpp"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
    
    // MARK: - URL Encoding
    
    static func encodePathForURL(_ path: String) -> String {
        // Custom encoding that handles all special characters including ', |, [], etc.
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "[]|'\"")
        return path.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? path
    }
    
    // MARK: - Directory Helpers
    
    static func hasImages(in url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        
        for itemURL in contents {
            let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDirectory && isImageFile(itemURL.lastPathComponent) {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Natural Sorting
    
    static func naturalSort(_ items: [(name: String, isDirectory: Bool, path: String)]) -> [(name: String, isDirectory: Bool, path: String)] {
        return items.sorted { item1, item2 in
            // Directories first
            if item1.isDirectory != item2.isDirectory {
                return item1.isDirectory
            }
            // Then natural sort by name
            return item1.name.localizedStandardCompare(item2.name) == .orderedAscending
        }
    }
    
    static func naturalSortMediaItems(_ items: [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)]) -> [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)] {
        return items.sorted { item1, item2 in
            return item1.name.localizedStandardCompare(item2.name) == .orderedAscending
        }
    }
}
