//
//  RequestHandlers.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import Foundation
import FlyingFox
import Zip
import Photos
import AVFoundation

class RequestHandlers {
    private let htmlGenerator: HTMLGenerator
    private let securityManager: SecurityManager
    private let photoGalleryManager: PhotoGalleryManager
    weak var webServerManager: WebServerManager?
    
    // Cache for transcoded video URLs
    private var transcodedVideoCache: [String: URL] = [:]
    
    init(htmlGenerator: HTMLGenerator, securityManager: SecurityManager, photoGalleryManager: PhotoGalleryManager) {
        self.htmlGenerator = htmlGenerator
        self.securityManager = securityManager
        self.photoGalleryManager = photoGalleryManager
    }
    
    // MARK: - Video Transcoding
    
    /// Transcodes a video to H.264 if it's in HEVC format
    private func getCompatibleVideoURL(for originalURL: URL) async -> URL {
        // Check if already cached
        let cacheKey = originalURL.path
        if let cachedURL = transcodedVideoCache[cacheKey],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        
        // Check if video needs transcoding (HEVC/MOV files often need it)
        let asset = AVURLAsset(url: originalURL)
        
        // Check video tracks for HEVC codec using modern API
        guard let allTracks = try? await asset.load(.tracks) else {
            return originalURL
        }
        
        // Filter video tracks by checking each track's media type
        let videoTracks = allTracks.filter { $0.mediaType == .video }
        
        var isHEVC = false
        
        for track in videoTracks {
            if let formatDescriptions = try? await track.load(.formatDescriptions) {
                for formatDescription in formatDescriptions {
                    let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
                    // HEVC codec types: 'hvc1', 'hev1'
                    if codecType == kCMVideoCodecType_HEVC || codecType == kCMVideoCodecType_HEVCWithAlpha {
                        isHEVC = true
                        break
                    }
                }
            }
        }
        
        // If not HEVC, return original URL
        if !isHEVC {
            print("Video is not HEVC, serving original: \(originalURL.lastPathComponent)")
            return originalURL
        }
        
        print("Video is HEVC, transcoding to H.264: \(originalURL.lastPathComponent)")
        
        // Create temp file for transcoded video
        let tempDir = FileManager.default.temporaryDirectory
        let filename = originalURL.deletingPathExtension().lastPathComponent
        let tempVideoURL = tempDir.appendingPathComponent("transcoded_\(filename).mp4")
        
        // Remove existing file
        try? FileManager.default.removeItem(at: tempVideoURL)
        
        // Choose appropriate preset based on video resolution using modern API
        let naturalSize: CGSize
        if let firstTrack = videoTracks.first,
           let loadedSize = try? await firstTrack.load(.naturalSize) {
            naturalSize = loadedSize
        } else {
            naturalSize = CGSize(width: 1920, height: 1080)
        }
        let maxDimension = max(naturalSize.width, naturalSize.height)
        
        let exportPreset: String
        if maxDimension >= 1920 {
            exportPreset = AVAssetExportPreset1920x1080
        } else if maxDimension >= 1280 {
            exportPreset = AVAssetExportPreset1280x720
        } else if maxDimension >= 960 {
            exportPreset = AVAssetExportPreset960x540
        } else {
            exportPreset = AVAssetExportPreset640x480
        }
        
        // Transcode video using modern API
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            print("Failed to create export session, serving original")
            return originalURL
        }
        
        exportSession.outputURL = tempVideoURL
        exportSession.outputFileType = .mp4
        
        // Export asynchronously using modern API
        do {
            try await exportSession.export(to: tempVideoURL, as: .mp4)
            print("Transcoding completed successfully")
            transcodedVideoCache[cacheKey] = tempVideoURL
            return tempVideoURL
        } catch {
            print("Transcoding failed: \(error.localizedDescription)")
            return originalURL
        }
    }
    
    /// Clean up transcoded video cache
    func cleanupTranscodedVideos() {
        let tempDir = FileManager.default.temporaryDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for file in contents where file.lastPathComponent.hasPrefix("transcoded_") {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            print("Error cleaning transcoded videos: \(error)")
        }
        transcodedVideoCache.removeAll()
    }
    
    // MARK: - Security Handlers
    
    func handleSecurePageRequest() async -> HTTPResponse {
        let html = htmlGenerator.generateSecurePageHTML()
        return HTTPResponse(statusCode: .ok,
                          headers: [.contentType: "text/html; charset=utf-8"],
                          body: html.data(using: .utf8) ?? Data())
    }
    
    func handleCheckSessionRequest(request: HTTPRequest) async -> HTTPResponse {
        let isValid = securityManager.validateSessionCode(from: request)
        let json = """
        {"valid": \(isValid)}
        """
        return HTTPResponse(statusCode: .ok,
                          headers: [.contentType: "application/json"],
                          body: json.data(using: .utf8) ?? Data())
    }
    
    // MARK: - Static File Handler
    
    func handleStaticFileRequest(path: String) async -> HTTPResponse {
        // Load static files from htmltemplates folder (or root if not found)
        let filename: String
        let fileExtension: String
        
        if path.hasSuffix(".min.js") {
            filename = path.replacingOccurrences(of: ".min.js", with: "")
            fileExtension = "min.js"
        } else if path.hasSuffix(".js") {
            filename = path.replacingOccurrences(of: ".js", with: "")
            fileExtension = "js"
        } else {
            filename = path
            fileExtension = ""
        }
        
        // Try subdirectory first, then root of bundle
        var staticFileURL = Bundle.main.url(forResource: filename, withExtension: fileExtension, subdirectory: "htmltemplates")
        if staticFileURL == nil {
            staticFileURL = Bundle.main.url(forResource: filename, withExtension: fileExtension)
        }
        
        guard let fileURL = staticFileURL else {
            print("Static file not found: \(filename).\(fileExtension)")
            return HTTPResponse(statusCode: .notFound)
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = path.hasSuffix(".js") ? "application/javascript" : "text/plain"
            
            return HTTPResponse(statusCode: .ok,
                              headers: [
                                .contentType: mimeType,
                                .contentLength: "\(data.count)",
                                HTTPHeader("Cache-Control"): "public, max-age=31536000" // Cache for 1 year
                              ],
                              body: data)
        } catch {
            print("Error loading static file: \(error)")
            return HTTPResponse(statusCode: .internalServerError)
        }
    }
    
    // MARK: - Folder Handlers
    
    func handleBrowseRequest(path: String, request: HTTPRequest, folderURL: URL) async -> HTTPResponse {
        let decodedPath = path.removingPercentEncoding ?? path
        let targetURL = decodedPath.isEmpty ? folderURL : folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
        
        if isDirectory.boolValue {
            let html = htmlGenerator.generateFolderHTML(for: targetURL, relativePath: decodedPath)
            return HTTPResponse(statusCode: .ok,
                              headers: [.contentType: "text/html; charset=utf-8"],
                              body: html.data(using: .utf8) ?? Data())
        } else {
            return HTTPResponse(statusCode: .badRequest)
        }
    }
    
    func handleFileRequest(path: String, request: HTTPRequest? = nil, folderURL: URL) async -> HTTPResponse {
        let decodedPath = path.removingPercentEncoding ?? path
        let fileURL = folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        // Check if file is markdown
        if fileURL.pathExtension.lowercased() == "md" {
            do {
                let markdownContent = try String(contentsOf: fileURL, encoding: .utf8)
                let html = htmlGenerator.generateMarkdownHTML(content: markdownContent, filename: fileURL.lastPathComponent)
                return HTTPResponse(statusCode: .ok,
                                  headers: [.contentType: "text/html; charset=utf-8"],
                                  body: html.data(using: .utf8) ?? Data())
            } catch {
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
        
        // Check if file is video - serve video player page (only if not requesting raw video)
        let isRawRequest = request?.query["raw"] != nil
        
        if FileUtilities.isVideoFile(fileURL.lastPathComponent) && !isRawRequest {
            let html = htmlGenerator.generateVideoPlayerHTML(videoPath: path, filename: fileURL.lastPathComponent)
            return HTTPResponse(statusCode: .ok,
                              headers: [.contentType: "text/html; charset=utf-8"],
                              body: html.data(using: .utf8) ?? Data())
        }
        
        // Handle range requests for video streaming
        let fileSize: Int64
        do {
            fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
        } catch {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        let mimeType = FileUtilities.mimeTypeForPath(fileURL.path)
        
        // Check for Range header - for videos, use transcoded version if HEVC
        if let rangeHeader = request?.headers[.range] {
            if FileUtilities.isVideoFile(fileURL.lastPathComponent) {
                let compatibleURL = await getCompatibleVideoURL(for: fileURL)
                let actualFileSize: Int64
                do {
                    actualFileSize = try FileManager.default.attributesOfItem(atPath: compatibleURL.path)[.size] as? Int64 ?? 0
                } catch {
                    return HTTPResponse(statusCode: .internalServerError)
                }
                let actualMimeType = compatibleURL.path != fileURL.path ? "video/mp4" : mimeType
                do {
                    return try handleRangeRequest(fileURL: compatibleURL, rangeHeader: rangeHeader, fileSize: actualFileSize, mimeType: actualMimeType)
                } catch {
                    return HTTPResponse(statusCode: .internalServerError)
                }
            } else {
                do {
                    return try handleRangeRequest(fileURL: fileURL, rangeHeader: rangeHeader, fileSize: fileSize, mimeType: mimeType)
                } catch {
                    return HTTPResponse(statusCode: .internalServerError)
                }
            }
        }
        
        // No range request - for video files, use transcoding if HEVC and stream
        if FileUtilities.isVideoFile(fileURL.lastPathComponent) {
            // Get compatible video URL (transcodes HEVC to H.264 if needed)
            let compatibleURL = await getCompatibleVideoURL(for: fileURL)
            
            let actualFileSize: Int64
            do {
                actualFileSize = try FileManager.default.attributesOfItem(atPath: compatibleURL.path)[.size] as? Int64 ?? 0
            } catch {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            let chunkSize: Int64 = min(1024 * 1024, actualFileSize)
            
            guard let fileHandle = try? FileHandle(forReadingFrom: compatibleURL) else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            defer { try? fileHandle.close() }
            
            guard let data = try? fileHandle.read(upToCount: Int(chunkSize)) else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            // Use video/mp4 for transcoded videos
            let actualMimeType = compatibleURL.path != fileURL.path ? "video/mp4" : mimeType
            
            return HTTPResponse(
                statusCode: .partialContent,
                headers: [
                    .contentType: actualMimeType,
                    .contentRange: "bytes 0-\(chunkSize - 1)/\(actualFileSize)",
                    .acceptRanges: "bytes",
                    .contentLength: "\(data.count)"
                ],
                body: data
            )
        } else {
            // For non-video files, serve normally
            do {
                let data = try Data(contentsOf: fileURL)
                return HTTPResponse(statusCode: .ok,
                                  headers: [
                                    .contentType: mimeType,
                                    .acceptRanges: "bytes",
                                    .contentLength: "\(data.count)"
                                  ],
                                  body: data)
            } catch {
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
    }
    
    private func handleRangeRequest(fileURL: URL, rangeHeader: String, fileSize: Int64, mimeType: String) throws -> HTTPResponse {
        // Parse Range header (format: "bytes=start-end")
        let rangeString = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
        let rangeParts = rangeString.split(separator: "-")
        
        guard let startString = rangeParts.first else {
            return HTTPResponse(statusCode: .badRequest)
        }
        
        let start = Int64(startString) ?? 0
        let end: Int64
        
        if rangeParts.count > 1, let endString = rangeParts.last, !endString.isEmpty {
            end = Int64(endString) ?? (fileSize - 1)
        } else {
            end = fileSize - 1
        }
        
        let length = end - start + 1
        
        // Read the requested range
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        defer { try? fileHandle.close() }
        
        try fileHandle.seek(toOffset: UInt64(start))
        guard let data = try? fileHandle.read(upToCount: Int(length)) else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        return HTTPResponse(
            statusCode: .partialContent,
            headers: [
                .contentType: mimeType,
                .contentRange: "bytes \(start)-\(end)/\(fileSize)",
                .acceptRanges: "bytes",
                .contentLength: "\(data.count)"
            ],
            body: data
        )
    }
    
    func handleGalleryRequest(path: String, sortBy: String, folderURL: URL) async -> HTTPResponse {
        let decodedPath = path.removingPercentEncoding ?? path
        let targetURL = folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        let html = htmlGenerator.generateGalleryHTML(for: targetURL, relativePath: decodedPath, sortBy: sortBy)
        return HTTPResponse(statusCode: .ok,
                          headers: [.contentType: "text/html; charset=utf-8"],
                          body: html.data(using: .utf8) ?? Data())
    }
    
    // MARK: - Download Handlers
    
    func handleDownloadRequest(path: String, folderURL: URL) async -> HTTPResponse {
        let decodedPath = path.removingPercentEncoding ?? path
        let fileURL = folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent
            let mimeType = FileUtilities.mimeTypeForPath(fileURL.path)
            
            return HTTPResponse(statusCode: .ok,
                              headers: [
                                .contentType: mimeType,
                                .contentDisposition: "attachment; filename=\"\(filename)\"",
                                .contentLength: "\(data.count)"
                              ],
                              body: data)
        } catch {
            return HTTPResponse(statusCode: .internalServerError)
        }
    }
    
    func handleDownloadZipRequest(path: String, folderURL: URL) async -> HTTPResponse {
        let decodedPath = path.removingPercentEncoding ?? path
        let targetURL = decodedPath.isEmpty ? folderURL : folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
        
        guard isDirectory.boolValue else {
            return HTTPResponse(statusCode: .badRequest)
        }
        
        do {
            // Create a temporary zip file
            let tempDir = FileManager.default.temporaryDirectory
            let zipFilename = "\(targetURL.lastPathComponent).zip"
            let zipURL = tempDir.appendingPathComponent(zipFilename)
            
            // Remove existing zip file if it exists
            try? FileManager.default.removeItem(at: zipURL)
            
            // Create zip archive using Zip library
            try Zip.zipFiles(paths: [targetURL], zipFilePath: zipURL, password: nil, progress: nil)
            
            // Read the zip data
            let data = try Data(contentsOf: zipURL)
            
            // Clean up temporary file
            try? FileManager.default.removeItem(at: zipURL)
            
            return HTTPResponse(statusCode: .ok,
                              headers: [
                                .contentType: "application/zip",
                                .contentDisposition: "attachment; filename=\"\(zipFilename)\"",
                                .contentLength: "\(data.count)"
                              ],
                              body: data)
        } catch {
            return HTTPResponse(statusCode: .internalServerError)
        }
    }
    
    // MARK: - Photo Gallery Handlers
    
    func handlePhotoGalleryRoot(sortBy: String) async -> HTTPResponse {
        let assets = photoGalleryManager.getPhotoAssets()
        let html = htmlGenerator.generatePhotoGalleryHTML(assets: assets, sortBy: sortBy)
        return HTTPResponse(statusCode: .ok,
                          headers: [.contentType: "text/html; charset=utf-8"],
                          body: html.data(using: .utf8) ?? Data())
    }
    
    func handlePhotoAssetRequest(assetId: String) async -> HTTPResponse {
        guard let data = await photoGalleryManager.getAssetData(for: assetId) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        return HTTPResponse(statusCode: .ok,
                          headers: [
                            .contentType: "image/jpeg",
                            .contentLength: "\(data.count)"
                          ],
                          body: data)
    }
    
    func handleVideoAssetRequest(assetId: String, request: HTTPRequest) async -> HTTPResponse {
        guard let videoURL = await photoGalleryManager.getVideoAssetURL(for: assetId) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        do {
            let fileSize = try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64 ?? 0
            
            // Check for Range header for video streaming
            if let rangeHeader = request.headers[.range] {
                // Parse Range header
                let rangeString = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
                let rangeParts = rangeString.split(separator: "-")
                
                guard let startString = rangeParts.first else {
                    return HTTPResponse(statusCode: .badRequest)
                }
                
                let start = Int64(startString) ?? 0
                let end: Int64
                
                if rangeParts.count > 1, let endString = rangeParts.last, !endString.isEmpty {
                    end = Int64(endString) ?? (fileSize - 1)
                } else {
                    end = fileSize - 1
                }
                
                let length = end - start + 1
                
                // Read the requested range
                guard let fileHandle = try? FileHandle(forReadingFrom: videoURL) else {
                    return HTTPResponse(statusCode: .internalServerError)
                }
                
                defer { try? fileHandle.close() }
                
                do {
                    try fileHandle.seek(toOffset: UInt64(start))
                    guard let data = try? fileHandle.read(upToCount: Int(length)) else {
                        return HTTPResponse(statusCode: .internalServerError)
                    }
                    
                    return HTTPResponse(
                        statusCode: .partialContent,
                        headers: [
                            .contentType: "video/mp4",
                            .contentRange: "bytes \(start)-\(end)/\(fileSize)",
                            .acceptRanges: "bytes",
                            .contentLength: "\(data.count)"
                        ],
                        body: data
                    )
                } catch {
                    return HTTPResponse(statusCode: .internalServerError)
                }
            } else {
                // No range request - send first chunk
                let chunkSize: Int64 = min(1024 * 1024, fileSize)
                
                guard let fileHandle = try? FileHandle(forReadingFrom: videoURL) else {
                    return HTTPResponse(statusCode: .internalServerError)
                }
                
                defer { try? fileHandle.close() }
                
                guard let data = try? fileHandle.read(upToCount: Int(chunkSize)) else {
                    return HTTPResponse(statusCode: .internalServerError)
                }
                
                return HTTPResponse(
                    statusCode: .partialContent,
                    headers: [
                        .contentType: "video/mp4",
                        .contentRange: "bytes 0-\(chunkSize - 1)/\(fileSize)",
                        .acceptRanges: "bytes",
                        .contentLength: "\(data.count)"
                    ],
                    body: data
                )
            }
        } catch {
            return HTTPResponse(statusCode: .internalServerError)
        }
    }
}
