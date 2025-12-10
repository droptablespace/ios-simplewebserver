//
//  WebServerManager.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import Foundation
import Combine
import FlyingFox
import UIKit
import Zip

@MainActor
class WebServerManager: ObservableObject {
    @Published var selectedFolderURL: URL?
    @Published var isServerRunning = false
    @Published var errorMessage: String?
    @Published var serverURL: String?
    @Published var networkAddresses: [String] = []
    
    private var server: HTTPServer?
    let port: UInt16 = 8080
    
    // HTML Templates
    private var folderTemplate: String = ""
    private var galleryTemplate: String = ""
    private var errorTemplate: String = ""
    
    init() {
        loadTemplates()
    }
    
    private func loadTemplates() {
        if let folderURL = Bundle.main.url(forResource: "folder_template", withExtension: "html"),
           let folderHTML = try? String(contentsOf: folderURL, encoding: .utf8) {
            folderTemplate = folderHTML
        }
        
        if let galleryURL = Bundle.main.url(forResource: "gallery_template", withExtension: "html"),
           let galleryHTML = try? String(contentsOf: galleryURL, encoding: .utf8) {
            galleryTemplate = galleryHTML
        }
        
        if let errorURL = Bundle.main.url(forResource: "error_template", withExtension: "html"),
           let errorHTML = try? String(contentsOf: errorURL, encoding: .utf8) {
            errorTemplate = errorHTML
        }
    }
    
    func selectFolder(_ url: URL) {
        // Stop server if running
        if isServerRunning {
            Task {
                await stopServer()
            }
        }
        
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Cannot access folder"
            return
        }
        
        selectedFolderURL = url
        errorMessage = nil
    }
    
    func startServer() async {
        guard let folderURL = selectedFolderURL else {
            errorMessage = "No folder selected"
            return
        }
        
        do {
            let server = HTTPServer(port: port)
            self.server = server
            
            // Root route - browse folder structure
            await server.appendRoute("GET /") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                return await self.handleBrowseRequest(path: "", request: request)
            }
            
            // Browse route for folders
            await server.appendRoute("GET /browse/*") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                let path = String(request.path.dropFirst("/browse/".count))
                return await self.handleBrowseRequest(path: path, request: request)
            }
            
            // File serving route
            await server.appendRoute("GET /file/*") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                let path = String(request.path.dropFirst("/file/".count))
                return await self.handleFileRequest(path: path, request: request)
            }
            
            // Image gallery route
            await server.appendRoute("GET /gallery/*") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                let path = String(request.path.dropFirst("/gallery/".count))
                let sortBy = request.query["sort"] ?? "name"
                return await self.handleGalleryRequest(path: path, sortBy: sortBy)
            }
            
            // Download file route
            await server.appendRoute("GET /download/*") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                let path = String(request.path.dropFirst("/download/".count))
                return await self.handleDownloadRequest(path: path)
            }
            
            // Download folder as zip route
            await server.appendRoute("GET /download-zip/*") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                let path = String(request.path.dropFirst("/download-zip/".count))
                return await self.handleDownloadZipRequest(path: path)
            }
            
            Task {
                try await server.start()
            }
            
            isServerRunning = true
            
            // Prevent screen from locking while server is running
            UIApplication.shared.isIdleTimerDisabled = true
            
            // Get local IP addresses
            let ipAddresses = getLocalIPAddresses()
            networkAddresses = ipAddresses
            
            if let primaryIP = ipAddresses.first {
                serverURL = "http://\(primaryIP):\(port)"
            } else {
                serverURL = "http://localhost:\(port)"
            }
            
            errorMessage = nil
            
        } catch {
            errorMessage = "Failed to start server: \(error.localizedDescription)"
        }
    }
    
    func stopServer() async {
        await server?.stop()
        server = nil
        isServerRunning = false
        serverURL = nil
        networkAddresses = []
        
        // Re-enable idle timer (allow screen to lock)
        UIApplication.shared.isIdleTimerDisabled = false
        
        if let url = selectedFolderURL {
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    // MARK: - Request Handlers
    
    private func handleBrowseRequest(path: String, request: HTTPRequest) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        let decodedPath = path.removingPercentEncoding ?? path
        let targetURL = decodedPath.isEmpty ? folderURL : folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
        
        if isDirectory.boolValue {
            let html = generateFolderHTML(for: targetURL, relativePath: decodedPath)
            return HTTPResponse(statusCode: .ok,
                              headers: [.contentType: "text/html; charset=utf-8"],
                              body: html.data(using: .utf8) ?? Data())
        } else {
            return HTTPResponse(statusCode: .badRequest)
        }
    }
    
    private func handleFileRequest(path: String, request: HTTPRequest? = nil) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        let decodedPath = path.removingPercentEncoding ?? path
        let fileURL = folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        // Check if file is markdown
        if fileURL.pathExtension.lowercased() == "md" {
            do {
                let markdownContent = try String(contentsOf: fileURL, encoding: .utf8)
                let html = generateMarkdownHTML(content: markdownContent, filename: fileURL.lastPathComponent)
                return HTTPResponse(statusCode: .ok,
                                  headers: [.contentType: "text/html; charset=utf-8"],
                                  body: html.data(using: .utf8) ?? Data())
            } catch {
                return HTTPResponse(statusCode: .internalServerError)
            }
        }
        
        // Check if file is video - serve video player page (only if not requesting raw video)
        // If the request has a query parameter ?raw=true, serve raw video
        let isRawRequest = request?.query["raw"] != nil
        
        if isVideoFile(fileURL.lastPathComponent) && !isRawRequest {
            let html = generateVideoPlayerHTML(videoPath: path, filename: fileURL.lastPathComponent)
            return HTTPResponse(statusCode: .ok,
                              headers: [.contentType: "text/html; charset=utf-8"],
                              body: html.data(using: .utf8) ?? Data())
        }
        
        // Handle range requests for video streaming
        do {
            let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
            let mimeType = mimeTypeForPath(fileURL.path)
            
            // Check for Range header
            if let rangeHeader = request?.headers[.range] {
                return try handleRangeRequest(fileURL: fileURL, rangeHeader: rangeHeader, fileSize: fileSize, mimeType: mimeType)
            }
            
            // No range request - for video files, always use partial content to avoid loading entire file
            if isVideoFile(fileURL.lastPathComponent) {
                // For videos without a Range header, send the first chunk as a 206 Partial Content
                // This allows the browser to get metadata and then request specific ranges
                let chunkSize: Int64 = min(1024 * 1024, fileSize) // 1MB or file size, whichever is smaller
                
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
                let data = try Data(contentsOf: fileURL)
                return HTTPResponse(statusCode: .ok,
                                  headers: [
                                    .contentType: mimeType,
                                    .acceptRanges: "bytes",
                                    .contentLength: "\(data.count)"
                                  ],
                                  body: data)
            }
        } catch {
            return HTTPResponse(statusCode: .internalServerError)
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
    
    private func handleGalleryRequest(path: String, sortBy: String) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        let decodedPath = path.removingPercentEncoding ?? path
        let targetURL = folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        let html = generateGalleryHTML(for: targetURL, relativePath: decodedPath, sortBy: sortBy)
        return HTTPResponse(statusCode: .ok,
                          headers: [.contentType: "text/html; charset=utf-8"],
                          body: html.data(using: .utf8) ?? Data())
    }
    
    // MARK: - HTML Generation
    
    private func generateFolderHTML(for url: URL, relativePath: String) -> String {
        let fileManager = FileManager.default
        var items: [(name: String, isDirectory: Bool, path: String)] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            
            for itemURL in contents {
                let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let itemPath = relativePath.isEmpty ? itemURL.lastPathComponent : "\(relativePath)/\(itemURL.lastPathComponent)"
                items.append((name: itemURL.lastPathComponent, isDirectory: isDirectory, path: itemPath))
            }
            
            items = naturalSort(items)
        } catch {
            return generateErrorHTML("Error reading directory: \(error.localizedDescription)")
        }
        
        // Use template if available, otherwise fall back to inline HTML
        if !folderTemplate.isEmpty {
            // Generate breadcrumb
            var breadcrumb = "<a href='/'>Home</a>"
            if !relativePath.isEmpty {
                let pathComponents = relativePath.split(separator: "/")
                var currentPath = ""
                for component in pathComponents {
                    currentPath += currentPath.isEmpty ? String(component) : "/\(component)"
                    breadcrumb += " / <a href='/browse/\(encodePathForURL(currentPath))'>\(component)</a>"
                }
            }
            
            // Check if current folder has images to show gallery button
            let currentHasImages = hasImages(in: url)
            let galleryButton = currentHasImages ? "<div style='margin: 20px 0;'><a href='/gallery/\(encodePathForURL(relativePath))' class='gallery-view-btn' style='display: inline-block; padding: 10px 20px; background: #007AFF; color: white; text-decoration: none; border-radius: 6px; font-weight: 500;'>🖼️ View as Gallery</a></div>" : ""
            
            // Generate items HTML
            var itemsHTML = ""
            if items.isEmpty {
                itemsHTML = "<p>Empty folder</p>"
            } else {
                for item in items {
                    let encodedPath = encodePathForURL(item.path)
                    
                    if item.isDirectory {
                        let folderURL = url.appendingPathComponent(item.name)
                        if hasImages(in: folderURL) {
                            itemsHTML += """
                            <div class='item'>
                                <span class='item-icon folder'>📁</span>
                                <span class='item-name'>
                                    <a href='/browse/\(encodedPath)'>\(item.name)</a>
                                    <small style='color: #999;'> | <a href='/gallery/\(encodedPath)'>View Gallery</a> | <a href='/download-zip/\(encodedPath)'>Download ZIP</a></small>
                                </span>
                            </div>
                            """
                        } else {
                            itemsHTML += """
                            <div class='item'>
                                <span class='item-icon folder'>📁</span>
                                <span class='item-name'>
                                    <a href='/browse/\(encodedPath)'>\(item.name)</a>
                                    <small style='color: #999;'> | <a href='/download-zip/\(encodedPath)'>Download ZIP</a></small>
                                </span>
                            </div>
                            """
                        }
                    } else if item.name.lowercased().hasSuffix(".pdf") {
                        itemsHTML += """
                        <div class='item'>
                            <span class='item-icon pdf'>📄</span>
                            <span class='item-name'>
                                <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                                <small style='color: #999;'> | <a href='/download/\(encodedPath)'>Download</a></small>
                            </span>
                        </div>
                        """
                    } else if item.name.lowercased().hasSuffix(".md") {
                        itemsHTML += """
                        <div class='item'>
                            <span class='item-icon'>📝</span>
                            <span class='item-name'>
                                <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                                <small style='color: #999;'> | <a href='/download/\(encodedPath)'>Download</a></small>
                            </span>
                        </div>
                        """
                    } else if isVideoFile(item.name) {
                        itemsHTML += """
                        <div class='item'>
                            <span class='item-icon'>🎬</span>
                            <span class='item-name'>
                                <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                                <small style='color: #999;'> | <a href='/download/\(encodedPath)'>Download</a></small>
                            </span>
                        </div>
                        """
                    } else if isImageFile(item.name) {
                        itemsHTML += """
                        <div class='item'>
                            <span class='item-icon image'>🖼️</span>
                            <span class='item-name'>
                                <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                                <small style='color: #999;'> | <a href='/download/\(encodedPath)'>Download</a></small>
                            </span>
                        </div>
                        """
                    } else {
                        itemsHTML += """
                        <div class='item'>
                            <span class='item-icon'>📄</span>
                            <span class='item-name'>
                                <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                                <small style='color: #999;'> | <a href='/download/\(encodedPath)'>Download</a></small>
                            </span>
                        </div>
                        """
                    }
                }
            }
            
            return folderTemplate
                .replacingOccurrences(of: "{{BREADCRUMB}}", with: breadcrumb + galleryButton)
                .replacingOccurrences(of: "{{ITEMS}}", with: itemsHTML)
        }
        
        // Fallback inline HTML (in case template loading fails)
        return generateFolderHTMLInline(for: url, relativePath: relativePath, items: items)
    }
    
    private func generateFolderHTMLInline(for url: URL, relativePath: String, items: [(name: String, isDirectory: Bool, path: String)]) -> String {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Folder Browser</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                    max-width: 1200px;
                    margin: 0 auto;
                    padding: 20px;
                    background-color: #f5f5f5;
                }
                h1 {
                    color: #333;
                    border-bottom: 2px solid #007AFF;
                    padding-bottom: 10px;
                }
                .breadcrumb {
                    margin: 20px 0;
                    color: #666;
                }
                .breadcrumb a {
                    color: #007AFF;
                    text-decoration: none;
                }
                .breadcrumb a:hover {
                    text-decoration: underline;
                }
                .item-list {
                    background: white;
                    border-radius: 8px;
                    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                    padding: 20px;
                }
                .item {
                    padding: 12px;
                    margin: 5px 0;
                    border-radius: 4px;
                    display: flex;
                    align-items: center;
                    transition: background-color 0.2s;
                }
                .item:hover {
                    background-color: #f0f0f0;
                }
                .item-icon {
                    margin-right: 12px;
                    font-size: 24px;
                }
                .item-name {
                    flex-grow: 1;
                }
                .item a {
                    color: #333;
                    text-decoration: none;
                }
                .item a:hover {
                    color: #007AFF;
                }
                .folder { color: #007AFF; }
                .pdf { color: #FF3B30; }
                .image { color: #34C759; }
            </style>
        </head>
        <body>
            <h1>📁 Folder Browser</h1>
        """
        
        html += "<div class='breadcrumb'><a href='/'>Home</a>"
        if !relativePath.isEmpty {
            let pathComponents = relativePath.split(separator: "/")
            var currentPath = ""
            for component in pathComponents {
                currentPath += currentPath.isEmpty ? String(component) : "/\(component)"
                html += " / <a href='/browse/\(encodePathForURL(currentPath))'>\(component)</a>"
            }
        }
        html += "</div>"
        
        // Add gallery button if current folder has images
        if hasImages(in: url) {
            html += "<div style='margin: 20px 0;'><a href='/gallery/\(encodePathForURL(relativePath))' style='display: inline-block; padding: 10px 20px; background: #007AFF; color: white; text-decoration: none; border-radius: 6px; font-weight: 500;'>🖼️ View as Gallery</a></div>"
        }
        
        html += "<div class='item-list'>"
        
        if items.isEmpty {
            html += "<p>Empty folder</p>"
        } else {
            for item in items {
                let encodedPath = encodePathForURL(item.path)
                
                if item.isDirectory {
                    let folderURL = url.appendingPathComponent(item.name)
                    if hasImages(in: folderURL) {
                        html += """
                        <div class='item'>
                            <span class='item-icon folder'>📁</span>
                            <span class='item-name'>
                                <a href='/browse/\(encodedPath)'>\(item.name)</a>
                                <small style='color: #999;'> | <a href='/gallery/\(encodedPath)'>View Gallery</a></small>
                            </span>
                        </div>
                        """
                    } else {
                        html += """
                        <div class='item'>
                            <span class='item-icon folder'>📁</span>
                            <span class='item-name'>
                                <a href='/browse/\(encodedPath)'>\(item.name)</a>
                            </span>
                        </div>
                        """
                    }
                } else if item.name.lowercased().hasSuffix(".pdf") {
                    html += """
                    <div class='item'>
                        <span class='item-icon pdf'>📄</span>
                        <span class='item-name'>
                            <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                        </span>
                    </div>
                    """
                } else if item.name.lowercased().hasSuffix(".md") {
                    html += """
                    <div class='item'>
                        <span class='item-icon'>📝</span>
                        <span class='item-name'>
                            <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                        </span>
                    </div>
                    """
                } else if isVideoFile(item.name) {
                    html += """
                    <div class='item'>
                        <span class='item-icon'>🎬</span>
                        <span class='item-name'>
                            <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                        </span>
                    </div>
                    """
                } else if isImageFile(item.name) {
                    html += """
                    <div class='item'>
                        <span class='item-icon image'>🖼️</span>
                        <span class='item-name'>
                            <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                        </span>
                    </div>
                    """
                } else {
                    html += """
                    <div class='item'>
                        <span class='item-icon'>📄</span>
                        <span class='item-name'>
                            <a href='/file/\(encodedPath)' target='_blank'>\(item.name)</a>
                        </span>
                    </div>
                    """
                }
            }
        }
        
        html += "</div></body></html>"
        return html
    }
    
    private func generateGalleryHTML(for url: URL, relativePath: String, sortBy: String) -> String {
        let fileManager = FileManager.default
        var images: [(name: String, path: String, modificationDate: Date?, size: Int64)] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            
            for itemURL in contents {
                let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDirectory && isImageFile(itemURL.lastPathComponent) {
                    let modDate = (try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    let fileSize = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    let itemPath = relativePath.isEmpty ? itemURL.lastPathComponent : "\(relativePath)/\(itemURL.lastPathComponent)"
                    images.append((name: itemURL.lastPathComponent, path: itemPath, modificationDate: modDate, size: Int64(fileSize)))
                }
            }
            
            // Sort images with natural sorting for "name"
            switch sortBy {
            case "date":
                images.sort { ($0.modificationDate ?? Date.distantPast) > ($1.modificationDate ?? Date.distantPast) }
            case "size":
                images.sort { $0.size > $1.size }
            default: // "name"
                images = naturalSortImages(images)
            }
        } catch {
            return generateErrorHTML("Error reading directory: \(error.localizedDescription)")
        }
        
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Image Gallery</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                    margin: 0;
                    padding: 20px;
                    background-color: #000;
                    color: #fff;
                }
                .header {
                    max-width: 1400px;
                    margin: 0 auto 20px;
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    flex-wrap: wrap;
                }
                h1 {
                    color: #fff;
                    margin: 10px 0;
                }
                .controls {
                    display: flex;
                    gap: 10px;
                    align-items: center;
                }
                .sort-btn {
                    padding: 8px 16px;
                    background: #007AFF;
                    color: white;
                    border: none;
                    border-radius: 4px;
                    cursor: pointer;
                    text-decoration: none;
                    font-size: 14px;
                }
                .sort-btn:hover {
                    background: #0051D5;
                }
                .sort-btn.active {
                    background: #34C759;
                }
                .back-btn {
                    padding: 8px 16px;
                    background: #666;
                    color: white;
                    border: none;
                    border-radius: 4px;
                    cursor: pointer;
                    text-decoration: none;
                    font-size: 14px;
                }
                .back-btn:hover {
                    background: #888;
                }
                .gallery {
                    max-width: 1400px;
                    margin: 0 auto;
                    display: grid;
                    grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
                    gap: 15px;
                }
                .gallery-item {
                    position: relative;
                    aspect-ratio: 1;
                    overflow: hidden;
                    border-radius: 8px;
                    background: #222;
                    cursor: pointer;
                }
                .gallery-item img {
                    width: 100%;
                    height: 100%;
                    object-fit: cover;
                    transition: transform 0.3s;
                }
                .gallery-item:hover img {
                    transform: scale(1.1);
                }
                .image-name {
                    position: absolute;
                    bottom: 0;
                    left: 0;
                    right: 0;
                    padding: 10px;
                    background: linear-gradient(transparent, rgba(0,0,0,0.8));
                    font-size: 12px;
                    word-break: break-all;
                }
                .lightbox {
                    display: none;
                    position: fixed;
                    top: 0;
                    left: 0;
                    width: 100%;
                    height: 100%;
                    background: rgba(0,0,0,0.95);
                    z-index: 1000;
                    align-items: center;
                    justify-content: center;
                }
                .lightbox.active {
                    display: flex;
                }
                .lightbox img {
                    max-width: 90%;
                    max-height: 90%;
                    object-fit: contain;
                }
                .lightbox-close {
                    position: absolute;
                    top: 20px;
                    right: 30px;
                    font-size: 40px;
                    color: white;
                    cursor: pointer;
                }
                .lightbox-nav {
                    position: absolute;
                    top: 50%;
                    transform: translateY(-50%);
                    font-size: 50px;
                    color: white;
                    cursor: pointer;
                    padding: 20px;
                    user-select: none;
                }
                .lightbox-prev { left: 20px; }
                .lightbox-next { right: 20px; }
            </style>
        </head>
        <body>
            <div class='header'>
                <h1>🖼️ Image Gallery</h1>
                <div class='controls'>
                    <a href='/browse/\(encodePathForURL(relativePath))' class='back-btn'>← Back to Folder</a>
                    <a href='?sort=name' class='sort-btn \(sortBy == "name" ? "active" : "")'>Sort by Name</a>
                    <a href='?sort=date' class='sort-btn \(sortBy == "date" ? "active" : "")'>Sort by Date</a>
                    <a href='?sort=size' class='sort-btn \(sortBy == "size" ? "active" : "")'>Sort by Size</a>
                </div>
            </div>
            <div class='gallery'>
        """
        
        if images.isEmpty {
            html += "<p style='grid-column: 1/-1; text-align: center;'>No images found in this folder</p>"
        } else {
            for (index, image) in images.enumerated() {
                let encodedPath = encodePathForURL(image.path)
                html += """
                <div class='gallery-item' onclick='openLightbox(\(index))'>
                    <img src='/file/\(encodedPath)' alt='\(image.name)' loading='lazy'>
                    <div class='image-name'>\(image.name)</div>
                </div>
                """
            }
        }
        
        html += """
            </div>
            <div class='lightbox' id='lightbox'>
                <span class='lightbox-close' onclick='closeLightbox()'>×</span>
                <span class='lightbox-nav lightbox-prev' onclick='event.stopPropagation(); changeImage(-1)'>‹</span>
                <img id='lightbox-img' src='' alt=''>
                <span class='lightbox-nav lightbox-next' onclick='event.stopPropagation(); changeImage(1)'>›</span>
            </div>
            <script>
                const images = [
        """
        
        for image in images {
            let encodedPath = encodePathForURL(image.path)
            html += "'/file/\(encodedPath)',\n"
        }
        
        html += """
                ];
                let currentIndex = 0;
                
                function openLightbox(index) {
                    currentIndex = index;
                    document.getElementById('lightbox-img').src = images[index];
                    document.getElementById('lightbox').classList.add('active');
                }
                
                function closeLightbox() {
                    document.getElementById('lightbox').classList.remove('active');
                }
                
                function changeImage(direction) {
                    currentIndex = (currentIndex + direction + images.length) % images.length;
                    document.getElementById('lightbox-img').src = images[currentIndex];
                }
                
                document.addEventListener('keydown', function(e) {
                    if (document.getElementById('lightbox').classList.contains('active')) {
                        if (e.key === 'Escape') closeLightbox();
                        if (e.key === 'ArrowLeft') changeImage(-1);
                        if (e.key === 'ArrowRight') changeImage(1);
                    }
                });
                
                // Touch swipe support
                let touchStartX = 0;
                let touchEndX = 0;
                const lightboxImg = document.getElementById('lightbox-img');
                
                lightboxImg.addEventListener('touchstart', function(e) {
                    touchStartX = e.changedTouches[0].screenX;
                }, false);
                
                lightboxImg.addEventListener('touchend', function(e) {
                    touchEndX = e.changedTouches[0].screenX;
                    handleSwipe();
                }, false);
                
                function handleSwipe() {
                    const swipeThreshold = 50; // minimum distance for swipe
                    const diff = touchStartX - touchEndX;
                    
                    if (Math.abs(diff) > swipeThreshold) {
                        if (diff > 0) {
                            // Swiped left, show next image
                            changeImage(1);
                        } else {
                            // Swiped right, show previous image
                            changeImage(-1);
                        }
                    }
                }
            </script>
        </body>
        </html>
        """
        
        return html
    }
    
    private func generateVideoPlayerHTML(videoPath: String, filename: String) -> String {
        let encodedPath = encodePathForURL(videoPath)
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(filename)</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    margin: 0;
                    padding: 20px;
                    background-color: #000;
                    color: #fff;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    min-height: 100vh;
                }
                .header {
                    margin-bottom: 20px;
                    text-align: center;
                }
                .filename {
                    color: #999;
                    font-size: 0.9em;
                    margin-top: 5px;
                }
                video {
                    max-width: 100%;
                    max-height: 80vh;
                    border-radius: 8px;
                    box-shadow: 0 4px 12px rgba(0,0,0,0.5);
                }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>🎬 Video Player</h1>
                <div class="filename">\(filename)</div>
            </div>
            <video controls preload="metadata">
                <source src="/file/\(encodedPath)?raw=true" type="\(mimeTypeForPath(filename))">
                Your browser does not support the video element.
            </video>
        </body>
        </html>
        """
    }
    
    private func generateMarkdownHTML(content: String, filename: String) -> String {
        // Escape content for safe JavaScript embedding
        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(filename)</title>
            <script src="https://cdn.jsdelivr.net/npm/markdown-it@14/dist/markdown-it.min.js"></script>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                    max-width: 900px;
                    margin: 0 auto;
                    padding: 40px 20px;
                    background-color: #ffffff;
                    color: #333;
                    line-height: 1.6;
                }
                #markdown-content {
                    background: white;
                }
                #markdown-content h1, #markdown-content h2 {
                    border-bottom: 1px solid #eee;
                    padding-bottom: 0.3em;
                    margin-top: 24px;
                    margin-bottom: 16px;
                }
                #markdown-content h1 { font-size: 2em; }
                #markdown-content h2 { font-size: 1.5em; }
                #markdown-content h3 { font-size: 1.25em; }
                #markdown-content code {
                    background: #f6f8fa;
                    padding: 0.2em 0.4em;
                    border-radius: 3px;
                    font-family: 'SF Mono', Monaco, 'Courier New', monospace;
                    font-size: 0.9em;
                }
                #markdown-content pre {
                    background: #f6f8fa;
                    padding: 16px;
                    border-radius: 6px;
                    overflow-x: auto;
                }
                #markdown-content pre code {
                    background: transparent;
                    padding: 0;
                }
                #markdown-content blockquote {
                    border-left: 4px solid #ddd;
                    padding-left: 16px;
                    color: #666;
                    margin: 0;
                }
                #markdown-content table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 16px 0;
                }
                #markdown-content table th, #markdown-content table td {
                    border: 1px solid #ddd;
                    padding: 8px 12px;
                }
                #markdown-content table th {
                    background: #f6f8fa;
                    font-weight: 600;
                }
                #markdown-content img {
                    max-width: 100%;
                    height: auto;
                }
                #markdown-content a {
                    color: #007AFF;
                    text-decoration: none;
                }
                #markdown-content a:hover {
                    text-decoration: underline;
                }
                .header {
                    margin-bottom: 30px;
                    padding-bottom: 10px;
                    border-bottom: 2px solid #007AFF;
                }
                .filename {
                    color: #666;
                    font-size: 0.9em;
                    margin-top: 5px;
                }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>📝 Markdown Document</h1>
                <div class="filename">\(filename)</div>
            </div>
            <div id="markdown-content"></div>
            <script>
                const md = window.markdownit({
                    html: true,
                    linkify: true,
                    typographer: true
                });
                const markdownText = `\(escapedContent)`;
                document.getElementById('markdown-content').innerHTML = md.render(markdownText);
            </script>
        </body>
        </html>
        """
    }
    
    private func generateErrorHTML(_ message: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>Error</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    margin: 0;
                    background-color: #f5f5f5;
                }
                .error {
                    background: white;
                    padding: 40px;
                    border-radius: 8px;
                    box-shadow: 0 2px 8px rgba(0,0,0,0.1);
                    text-align: center;
                }
                h1 { color: #FF3B30; }
            </style>
        </head>
        <body>
            <div class='error'>
                <h1>Error</h1>
                <p>\(message)</p>
            </div>
        </body>
        </html>
        """
    }
    
    // MARK: - Helper Methods
    
    private func encodePathForURL(_ path: String) -> String {
        // Custom encoding that handles all special characters including ', |, [], etc.
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "[]|'\"")
        return path.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? path
    }
    
    private func hasImages(in url: URL) -> Bool {
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
    
    private func isImageFile(_ filename: String) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif"]
        let ext = (filename as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
    
    private func isVideoFile(_ filename: String) -> Bool {
        let videoExtensions = ["mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg", "3gp"]
        let ext = (filename as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }
    
    private func mimeTypeForPath(_ path: String) -> String {
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
    
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return addresses }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // Check for IPv4 (AF_INET)
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                
                // Skip loopback and only include WiFi/Ethernet interfaces
                if name != "lo0" && (name.hasPrefix("en") || name.hasPrefix("pdp_ip")) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let address = String(cString: hostname)
                        
                        // Only include local network addresses (192.168.x.x, 172.16-31.x.x, not VPN 10.x.x.x)
                        if address.hasPrefix("192.168.") || 
                           (address.hasPrefix("172.") && isPrivateClassB(address)) {
                            addresses.append(address)
                        }
                    }
                }
            }
        }
        
        return addresses
    }
    
    private func isPrivateClassB(_ address: String) -> Bool {
        let components = address.split(separator: ".")
        guard components.count >= 2,
              let second = Int(components[1]) else { return false }
        return second >= 16 && second <= 31
    }
    
    // MARK: - Download Handlers
    
    private func handleDownloadRequest(path: String) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        let decodedPath = path.removingPercentEncoding ?? path
        let fileURL = folderURL.appendingPathComponent(decodedPath)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent
            let mimeType = mimeTypeForPath(fileURL.path)
            
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
    
    private func handleDownloadZipRequest(path: String) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
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
    
    // MARK: - Natural Sorting
    
    private func naturalSort(_ items: [(name: String, isDirectory: Bool, path: String)]) -> [(name: String, isDirectory: Bool, path: String)] {
        return items.sorted { item1, item2 in
            // Directories first
            if item1.isDirectory != item2.isDirectory {
                return item1.isDirectory
            }
            // Then natural sort by name
            return item1.name.localizedStandardCompare(item2.name) == .orderedAscending
        }
    }
    
    private func naturalSortImages(_ images: [(name: String, path: String, modificationDate: Date?, size: Int64)]) -> [(name: String, path: String, modificationDate: Date?, size: Int64)] {
        return images.sorted { image1, image2 in
            return image1.name.localizedStandardCompare(image2.name) == .orderedAscending
        }
    }
}
