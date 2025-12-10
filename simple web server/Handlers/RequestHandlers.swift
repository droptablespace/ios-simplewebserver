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

class RequestHandlers {
    private let htmlGenerator: HTMLGenerator
    private let securityManager: SecurityManager
    private let photoGalleryManager: PhotoGalleryManager
    weak var webServerManager: WebServerManager?
    
    init(htmlGenerator: HTMLGenerator, securityManager: SecurityManager, photoGalleryManager: PhotoGalleryManager) {
        self.htmlGenerator = htmlGenerator
        self.securityManager = securityManager
        self.photoGalleryManager = photoGalleryManager
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
        // Load static files from Templates folder
        guard let staticFileURL = Bundle.main.url(forResource: path.replacingOccurrences(of: ".min.js", with: "").replacingOccurrences(of: ".js", with: ""), withExtension: path.contains(".min.js") ? "min.js" : "js", subdirectory: "Templates") else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        do {
            let data = try Data(contentsOf: staticFileURL)
            let mimeType = path.hasSuffix(".js") ? "application/javascript" : "text/plain"
            
            return HTTPResponse(statusCode: .ok,
                              headers: [
                                .contentType: mimeType,
                                .contentLength: "\(data.count)",
                                HTTPHeader("Cache-Control"): "public, max-age=31536000" // Cache for 1 year
                              ],
                              body: data)
        } catch {
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
        
        // Check for Range header
        if let rangeHeader = request?.headers[.range] {
            do {
                return try handleRangeRequest(fileURL: fileURL, rangeHeader: rangeHeader, fileSize: fileSize, mimeType: mimeType)
            } catch {
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
        
        // No range request - for video files, always use partial content to avoid loading entire file
        if FileUtilities.isVideoFile(fileURL.lastPathComponent) {
            let chunkSize: Int64 = min(1024 * 1024, fileSize)
            
            guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            defer { try? fileHandle.close() }
            
            guard let data = try? fileHandle.read(upToCount: Int(chunkSize)) else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            return HTTPResponse(
                statusCode: .partialContent,
                headers: [
                    .contentType: mimeType,
                    .contentRange: "bytes 0-\(chunkSize - 1)/\(fileSize)",
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
