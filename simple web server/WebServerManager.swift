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
import Photos

enum SourceType {
    case folder
    case photoGallery
}

@MainActor
class WebServerManager: NSObject, ObservableObject {
    @Published var selectedFolderURL: URL?
    @Published var sourceType: SourceType = .folder
    @Published var isServerRunning = false
    @Published var errorMessage: String?
    @Published var serverURL: String?
    @Published var networkAddresses: [String] = []
    @Published var photoLibraryAuthorized = false
    @Published var bonjourHostname: String?
    
    private var server: HTTPServer?
    let port: UInt16 = 8080
    private var photoAssets: [PHAsset] = []
    private var assetCache: [String: Data] = [:]
    private var serverTask: Task<Void, Never>?
    
    // HTML Templates
    private var folderTemplate: String = ""
    private var galleryTemplate: String = ""
    private var errorTemplate: String = ""
    
    override init() {
        super.init()
        loadTemplates()
        setupAppLifecycleObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupAppLifecycleObservers() {
        // Handle app going to background
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("⚠️ App going to background - server may be suspended")
        }
        
        // Handle app returning to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAppBecameActive()
            }
        }
    }
    
    private func handleAppBecameActive() async {
        // Only restart if the server was running before
        guard isServerRunning else { return }
        
        print("🔄 App returned to foreground - checking server status...")
        
        // Save the folder URL and source type before stopping
        let savedFolderURL = selectedFolderURL
        let savedSourceType = sourceType
        
        // Stop server without releasing security-scoped resource
        await stopServerForRestart()
        
        // Wait for socket to be released
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
        
        // Restore folder URL and source type
        selectedFolderURL = savedFolderURL
        sourceType = savedSourceType
        
        // Re-access security-scoped resource if needed
        if sourceType == .folder, let url = savedFolderURL {
            _ = url.startAccessingSecurityScopedResource()
        }
        
        // Restart server with retry logic
        await startServerWithRetry()
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
        // Stop server if running - must wait for it to complete
        if isServerRunning {
            Task {
                await stopServer()
                
                // Now proceed with folder selection on main actor
                await MainActor.run {
                    self.performFolderSelection(url)
                }
            }
        } else {
            performFolderSelection(url)
        }
    }
    
    private func performFolderSelection(_ url: URL) {
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Cannot access folder"
            return
        }
        
        selectedFolderURL = url
        sourceType = .folder
        errorMessage = nil
    }
    
    func requestPhotoLibraryAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            photoLibraryAuthorized = true
            await fetchPhotoAssets()
            sourceType = .photoGallery
            selectedFolderURL = URL(fileURLWithPath: "Photos")
            errorMessage = nil
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if newStatus == .authorized || newStatus == .limited {
                photoLibraryAuthorized = true
                await fetchPhotoAssets()
                sourceType = .photoGallery
                selectedFolderURL = URL(fileURLWithPath: "Photos")
                errorMessage = nil
            } else {
                photoLibraryAuthorized = false
                errorMessage = "Photo library access denied"
            }
        case .denied, .restricted:
            photoLibraryAuthorized = false
            errorMessage = "Photo library access denied. Please enable in Settings."
        @unknown default:
            photoLibraryAuthorized = false
            errorMessage = "Unknown photo library authorization status"
        }
    }
    
    private func fetchPhotoAssets() async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Fetch both images and videos
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            // Only include images and videos
            if asset.mediaType == .image || asset.mediaType == .video {
                assets.append(asset)
            }
        }
        
        photoAssets = assets
        assetCache.removeAll()
    }
    
    func startServer() async {
        guard selectedFolderURL != nil else {
            errorMessage = "No source selected"
            return
        }
        
        // Ensure any previous server is fully stopped
        if server != nil {
            await stopServer()
            // Give the system a moment to release the socket
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        do {
            let newServer = HTTPServer(port: port)
            self.server = newServer
            
            // Static file route for libraries
            await newServer.appendRoute("GET /static/*") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                let path = String(request.path.dropFirst("/static/".count))
                return await self.handleStaticFileRequest(path: path)
            }
            
            if sourceType == .photoGallery {
                // Photo gallery routes
                await newServer.appendRoute("GET /") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    return await self.handlePhotoGalleryRoot(sortBy: request.query["sort"] ?? "date")
                }
                
                // Photo asset serving route
                await newServer.appendRoute("GET /photo/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    let assetId = String(request.path.dropFirst("/photo/".count))
                    return await self.handlePhotoAssetRequest(assetId: assetId)
                }
                
                // Video asset serving route
                await newServer.appendRoute("GET /video/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    let assetId = String(request.path.dropFirst("/video/".count))
                    return await self.handleVideoAssetRequest(assetId: assetId, request: request)
                }
            } else {
                // Folder routes
                await newServer.appendRoute("GET /") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    return await self.handleBrowseRequest(path: "", request: request)
                }
                
                // Browse route for folders
                await newServer.appendRoute("GET /browse/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    let path = String(request.path.dropFirst("/browse/".count))
                    return await self.handleBrowseRequest(path: path, request: request)
                }
                
                // File serving route
                await newServer.appendRoute("GET /file/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    let path = String(request.path.dropFirst("/file/".count))
                    return await self.handleFileRequest(path: path, request: request)
                }
                
                // Image gallery route
                await newServer.appendRoute("GET /gallery/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    let path = String(request.path.dropFirst("/gallery/".count))
                    let sortBy = request.query["sort"] ?? "name"
                    return await self.handleGalleryRequest(path: path, sortBy: sortBy)
                }
                
                // Download file route
                await newServer.appendRoute("GET /download/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    let path = String(request.path.dropFirst("/download/".count))
                    return await self.handleDownloadRequest(path: path)
                }
                
                // Download folder as zip route
                await newServer.appendRoute("GET /download-zip/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    let path = String(request.path.dropFirst("/download-zip/".count))
                    return await self.handleDownloadZipRequest(path: path)
                }
            }
            
            // Start the server and handle errors properly
            // Keep track of the task so we can monitor it
            serverTask = Task {
                do {
                    try await newServer.start()
                } catch {
                    await MainActor.run {
                        // Check if this is an expected error (socket closed, app background, etc.)
                        let errorString = "\(error)"
                        let isExpectedError = errorString.contains("disconnected") ||
                                             errorString.contains("Bad file descriptor") ||
                                             errorString.contains("kqueue") ||
                                             errorString.contains("errno: 9")
                        
                        if isExpectedError {
                            // Don't show error to user - this is expected when stopping server
                            print("ℹ️ Server stopped (expected)")
                        } else {
                            print("server error: \(error)")
                            self.errorMessage = "Server failed: \(error.localizedDescription)"
                        }
                        
                        self.isServerRunning = false
                        self.server = nil
                    }
                }
            }
            
            isServerRunning = true
            
            // Prevent screen from locking while server is running
            UIApplication.shared.isIdleTimerDisabled = true
            
            // Get local IP addresses
            let ipAddresses = getLocalIPAddresses()
            networkAddresses = ipAddresses
            
            // Get the system hostname (iOS already advertises this via mDNS)
            var hostname = ProcessInfo.processInfo.hostName
            
            // Remove trailing dot if present (DNS format vs browser format)
            if hostname.hasSuffix(".") {
                hostname = String(hostname.dropLast())
            }
            
            // If hostname doesn't include .local, it may just be the device name
            if !hostname.contains(".local") {
                hostname = "\(hostname).local"
            }
            
            // Store the hostname for display
            bonjourHostname = hostname
            
            if let primaryIP = ipAddresses.first {
                serverURL = "http://\(primaryIP):\(port) or http://\(hostname):\(port)"
            } else {
                serverURL = "http://\(hostname):\(port)"
            }
            
            errorMessage = nil
            
        } catch {
            errorMessage = "Failed to start server: \(error.localizedDescription)"
        }
    }
    
    func stopServer() async {
        // Cancel the server task
        serverTask?.cancel()
        serverTask = nil
        
        // Stop the HTTP server if it exists
        if let currentServer = server {
            await currentServer.stop()
            server = nil
        }
        
        isServerRunning = false
        serverURL = nil
        networkAddresses = []
        bonjourHostname = nil
        
        // Re-enable idle timer (allow screen to lock)
        UIApplication.shared.isIdleTimerDisabled = false
        
        if let url = selectedFolderURL, sourceType == .folder {
            url.stopAccessingSecurityScopedResource()
        }
        
        // Give the system time to fully release the socket
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    
    /// Stop server for restart - doesn't release security-scoped resource
    private func stopServerForRestart() async {
        // Cancel the server task
        serverTask?.cancel()
        serverTask = nil
        
        // Stop the HTTP server if it exists
        if let currentServer = server {
            await currentServer.stop()
            server = nil
        }
        
        isServerRunning = false
        serverURL = nil
        networkAddresses = []
        bonjourHostname = nil
        
        // Note: We don't release security-scoped resource here
        // because we're restarting and will need it again
        
        // Give the system time to fully release the socket
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    
    /// Start server with retry logic for "Address already in use" errors
    private func startServerWithRetry() async {
        var retryCount = 0
        let maxRetries = 3
        
        while retryCount < maxRetries {
            // Try to start the server
            await startServer()
            
            // Check if it succeeded (no error and running)
            if isServerRunning && errorMessage == nil {
                print("✅ Server started successfully")
                return
            }
            
            // Check if the error is "Address already in use"
            if let error = errorMessage, error.contains("48") || error.lowercased().contains("address") {
                retryCount += 1
                print("⚠️ Address in use, retry \(retryCount)/\(maxRetries)...")
                errorMessage = nil // Clear error for retry
                
                if retryCount < maxRetries {
                    // Wait longer before each retry (exponential backoff)
                    try? await Task.sleep(nanoseconds: UInt64(retryCount) * 1_000_000_000)
                }
            } else {
                // Different error, don't retry
                return
            }
        }
        
        // Max retries reached
        if !isServerRunning {
            errorMessage = "Failed to restart server: Port \(port) is still in use. Please wait a moment and try again."
        }
    }
    
    func validateFolderAccess() -> Bool {
        guard isServerRunning else { return true }
        
        // For photo gallery, check photo library authorization
        if sourceType == .photoGallery {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return status == .authorized || status == .limited
        }
        
        // For folder access, check if we can still read the directory
        guard let folderURL = selectedFolderURL else { return false }
        
        // Try to access the directory
        do {
            let _ = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            return true
        } catch {
            return false
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
        var mediaItems: [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            
            for itemURL in contents {
                let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDirectory && (isImageFile(itemURL.lastPathComponent) || isVideoFile(itemURL.lastPathComponent)) {
                    let modDate = (try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    let fileSize = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    let itemPath = relativePath.isEmpty ? itemURL.lastPathComponent : "\(relativePath)/\(itemURL.lastPathComponent)"
                    let isVideo = isVideoFile(itemURL.lastPathComponent)
                    mediaItems.append((name: itemURL.lastPathComponent, path: itemPath, modificationDate: modDate, size: Int64(fileSize), isVideo: isVideo))
                }
            }
            
            // Sort media items with natural sorting for "name"
            switch sortBy {
            case "date":
                mediaItems.sort { ($0.modificationDate ?? Date.distantPast) > ($1.modificationDate ?? Date.distantPast) }
            case "size":
                mediaItems.sort { $0.size > $1.size }
            default: // "name"
                mediaItems = naturalSortMediaItems(mediaItems)
            }
        } catch {
            return generateErrorHTML("Error reading directory: \(error.localizedDescription)")
        }
        
        // Use template if available
        if !galleryTemplate.isEmpty {
            // Generate controls
            let controls = """
            <a href='/browse/\(encodePathForURL(relativePath))' class='back-btn'>← Back to Folder</a>
            <a href='?sort=name' class='sort-btn \(sortBy == "name" ? "active" : "")'>Sort by Name</a>
            <a href='?sort=date' class='sort-btn \(sortBy == "date" ? "active" : "")'>Sort by Date</a>
            <a href='?sort=size' class='sort-btn \(sortBy == "size" ? "active" : "")'>Sort by Size</a>
            """
            
            // Generate gallery items HTML
            var itemsHTML = ""
            if mediaItems.isEmpty {
                itemsHTML = "<p style='grid-column: 1/-1; text-align: center;'>No images or videos found in this folder</p>"
            } else {
                for (index, item) in mediaItems.enumerated() {
                    let encodedPath = encodePathForURL(item.path)
                    let videoClass = item.isVideo ? " video" : ""
                    
                    if item.isVideo {
                        // For videos, show thumbnail (first frame) using video element
                        itemsHTML += """
                        <div class='gallery-item\(videoClass)' onclick='openMedia(\(index))'>
                            <img src='/file/\(encodedPath)#t=0.1' alt='\(item.name)' loading='lazy'>
                            <div class='image-name'>\(item.name)</div>
                        </div>
                        """
                    } else {
                        itemsHTML += """
                        <div class='gallery-item' onclick='openMedia(\(index))'>
                            <img src='/file/\(encodedPath)' alt='\(item.name)' loading='lazy'>
                            <div class='image-name'>\(item.name)</div>
                        </div>
                        """
                    }
                }
            }
            
            // Generate media items JSON
            var mediaJSON = ""
            for item in mediaItems {
                let encodedPath = encodePathForURL(item.path)
                let type = item.isVideo ? "video" : "image"
                let mimeType = mimeTypeForPath(item.name)
                let videoPath = item.isVideo ? "/file/\(encodedPath)?raw=true" : "/file/\(encodedPath)"
                mediaJSON += "{type: '\(type)', path: '\(videoPath)', mimeType: '\(mimeType)'},\n"
            }
            
            return galleryTemplate
                .replacingOccurrences(of: "{{CONTROLS}}", with: controls)
                .replacingOccurrences(of: "{{GALLERY_ITEMS}}", with: itemsHTML)
                .replacingOccurrences(of: "{{MEDIA_ITEMS}}", with: mediaJSON)
        }
        
        // Fallback inline HTML (in case template loading fails)
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Media Gallery</title>
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
                .gallery-item.video::after {
                    content: '▶';
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    font-size: 60px;
                    color: white;
                    text-shadow: 0 2px 8px rgba(0,0,0,0.7);
                    pointer-events: none;
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
                .video-dialog {
                    display: none;
                    position: fixed;
                    top: 0;
                    left: 0;
                    width: 100%;
                    height: 100%;
                    background: rgba(0,0,0,0.95);
                    z-index: 1001;
                    align-items: center;
                    justify-content: center;
                }
                .video-dialog.active {
                    display: flex;
                }
                .video-dialog video {
                    max-width: 90%;
                    max-height: 90%;
                    border-radius: 8px;
                }
                .video-dialog-close {
                    position: absolute;
                    top: 20px;
                    right: 30px;
                    font-size: 40px;
                    color: white;
                    cursor: pointer;
                    z-index: 1002;
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
        
        if mediaItems.isEmpty {
            html += "<p style='grid-column: 1/-1; text-align: center;'>No images or videos found in this folder</p>"
        } else {
            for (index, item) in mediaItems.enumerated() {
                let encodedPath = encodePathForURL(item.path)
                let videoClass = item.isVideo ? " video" : ""
                html += """
                <div class='gallery-item\(videoClass)' onclick='openMedia(\(index))'>
                    <img src='/file/\(encodedPath)' alt='\(item.name)' loading='lazy'>
                    <div class='image-name'>\(item.name)</div>
                </div>
                """
            }
        }
        
        html += """
            </div>
            <div class='lightbox' id='lightbox'>
                <span class='lightbox-close' onclick='closeLightbox()'>×</span>
                <span class='lightbox-nav lightbox-prev' onclick='event.stopPropagation(); changeImage(-1)'>‹</span>
                <img id='lightbox-img' src='' alt='' loading='lazy'>
                <span class='lightbox-nav lightbox-next' onclick='event.stopPropagation(); changeImage(1)'>›</span>
            </div>
            <div class='video-dialog' id='video-dialog' onclick='closeVideoDialog()'>
                <span class='video-dialog-close' onclick='closeVideoDialog()'>×</span>
                <video id='video-player' controls onclick='event.stopPropagation()'>
                    <source id='video-source' src='' type=''>
                    Your browser does not support the video tag.
                </video>
            </div>
            <script>
                const media = [
        """
        
        for item in mediaItems {
            let encodedPath = encodePathForURL(item.path)
            let type = item.isVideo ? "video" : "image"
            let mimeType = mimeTypeForPath(item.name)
            let path = item.isVideo ? "/file/\(encodedPath)?raw=true" : "/file/\(encodedPath)"
            html += "{type: '\(type)', path: '\(path)', mimeType: '\(mimeType)'},\n"
        }
        
        html += """
                ];
                let currentIndex = 0;
                
                function openMedia(index) {
                    currentIndex = index;
                    const item = media[index];
                    
                    if (item.type === 'image') {
                        document.getElementById('lightbox-img').src = item.path;
                        document.getElementById('lightbox').classList.add('active');
                    } else if (item.type === 'video') {
                        const videoPlayer = document.getElementById('video-player');
                        const videoSource = document.getElementById('video-source');
                        videoSource.src = item.path;
                        videoSource.type = item.mimeType || 'video/mp4';
                        videoPlayer.load();
                        document.getElementById('video-dialog').classList.add('active');
                    }
                }
                
                function closeLightbox() {
                    document.getElementById('lightbox').classList.remove('active');
                }
                
                function closeVideoDialog() {
                    const dialog = document.getElementById('video-dialog');
                    const videoPlayer = document.getElementById('video-player');
                    videoPlayer.pause();
                    videoPlayer.currentTime = 0;
                    dialog.classList.remove('active');
                }
                
                function changeImage(direction) {
                    let newIndex = currentIndex;
                    let found = false;
                    
                    // Find next image (skip videos)
                    for (let i = 0; i < media.length; i++) {
                        newIndex = (newIndex + direction + media.length) % media.length;
                        if (media[newIndex].type === 'image') {
                            found = true;
                            break;
                        }
                    }
                    
                    if (found) {
                        currentIndex = newIndex;
                        document.getElementById('lightbox-img').src = media[currentIndex].path;
                    }
                }
                
                document.addEventListener('keydown', function(e) {
                    const lightboxActive = document.getElementById('lightbox').classList.contains('active');
                    const videoActive = document.getElementById('video-dialog').classList.contains('active');
                    
                    if (lightboxActive) {
                        if (e.key === 'Escape') closeLightbox();
                        if (e.key === 'ArrowLeft') changeImage(-1);
                        if (e.key === 'ArrowRight') changeImage(1);
                    }
                    
                    if (videoActive && e.key === 'Escape') {
                        closeVideoDialog();
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
            <script src="/static/markdown-it.min.js"></script>
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
    
    // MARK: - Static File Handler
    
    private func handleStaticFileRequest(path: String) async -> HTTPResponse {
        guard let staticFileURL = Bundle.main.url(forResource: path.replacingOccurrences(of: ".min.js", with: "").replacingOccurrences(of: ".js", with: ""), withExtension: path.contains(".min.js") ? "min.js" : "js") else {
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
    
    private func naturalSortMediaItems(_ items: [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)]) -> [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)] {
        return items.sorted { item1, item2 in
            return item1.name.localizedStandardCompare(item2.name) == .orderedAscending
        }
    }
    
    // MARK: - Photo Gallery Handlers
    
    private func handlePhotoGalleryRoot(sortBy: String) async -> HTTPResponse {
        let html = generatePhotoGalleryHTML(sortBy: sortBy)
        return HTTPResponse(statusCode: .ok,
                          headers: [.contentType: "text/html; charset=utf-8"],
                          body: html.data(using: .utf8) ?? Data())
    }
    
    private func handlePhotoAssetRequest(assetId: String) async -> HTTPResponse {
        // Check cache first
        if let cachedData = assetCache[assetId] {
            return HTTPResponse(statusCode: .ok,
                              headers: [
                                .contentType: "image/jpeg",
                                .contentLength: "\(cachedData.count)"
                              ],
                              body: cachedData)
        }
        
        // Find asset by ID
        guard let asset = photoAssets.first(where: { $0.localIdentifier == assetId }) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        // Fetch image data
        return await withCheckedContinuation { continuation in
            let imageManager = PHImageManager.default()
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            
            imageManager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options) { [weak self] image, _ in
                guard let self = self, let image = image, let data = image.jpegData(compressionQuality: 0.8) else {
                    continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                    return
                }
                
                // Cache the data
                Task { @MainActor in
                    self.assetCache[assetId] = data
                }
                
                continuation.resume(returning: HTTPResponse(statusCode: .ok,
                                  headers: [
                                    .contentType: "image/jpeg",
                                    .contentLength: "\(data.count)"
                                  ],
                                  body: data))
            }
        }
    }
    
    private func handleVideoAssetRequest(assetId: String, request: HTTPRequest) async -> HTTPResponse {
        // Find asset by ID
        guard let asset = photoAssets.first(where: { $0.localIdentifier == assetId }) else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        guard asset.mediaType == .video else {
            return HTTPResponse(statusCode: .badRequest)
        }
        
        // Request video data
        return await withCheckedContinuation { continuation in
            let videoManager = PHImageManager.default()
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            videoManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                    return
                }
                
                let videoURL = urlAsset.url
                
                do {
                    let fileSize = try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64 ?? 0
                    
                    // Check for Range header for video streaming
                    if let rangeHeader = request.headers[.range] {
                        // Parse Range header
                        let rangeString = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
                        let rangeParts = rangeString.split(separator: "-")
                        
                        guard let startString = rangeParts.first else {
                            continuation.resume(returning: HTTPResponse(statusCode: .badRequest))
                            return
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
                            continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                            return
                        }
                        
                        defer { try? fileHandle.close() }
                        
                        do {
                            try fileHandle.seek(toOffset: UInt64(start))
                            guard let data = try? fileHandle.read(upToCount: Int(length)) else {
                                continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                                return
                            }
                            
                            continuation.resume(returning: HTTPResponse(
                                statusCode: .partialContent,
                                headers: [
                                    .contentType: "video/mp4",
                                    .contentRange: "bytes \(start)-\(end)/\(fileSize)",
                                    .acceptRanges: "bytes",
                                    .contentLength: "\(data.count)"
                                ],
                                body: data
                            ))
                        } catch {
                            continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                        }
                    } else {
                        // No range request - send first chunk
                        let chunkSize: Int64 = min(1024 * 1024, fileSize)
                        
                        guard let fileHandle = try? FileHandle(forReadingFrom: videoURL) else {
                            continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                            return
                        }
                        
                        defer { try? fileHandle.close() }
                        
                        guard let data = try? fileHandle.read(upToCount: Int(chunkSize)) else {
                            continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                            return
                        }
                        
                        continuation.resume(returning: HTTPResponse(
                            statusCode: .partialContent,
                            headers: [
                                .contentType: "video/mp4",
                                .contentRange: "bytes 0-\(chunkSize - 1)/\(fileSize)",
                                .acceptRanges: "bytes",
                                .contentLength: "\(data.count)"
                            ],
                            body: data
                        ))
                    }
                } catch {
                    continuation.resume(returning: HTTPResponse(statusCode: .internalServerError))
                }
            }
        }
    }
    
    private func generatePhotoGalleryHTML(sortBy: String) -> String {
        var sortedAssets = photoAssets
        
        switch sortBy {
        case "name":
            // Sort by filename if available, otherwise by date
            sortedAssets.sort { asset1, asset2 in
                let name1 = (PHAssetResource.assetResources(for: asset1).first?.originalFilename ?? asset1.localIdentifier)
                let name2 = (PHAssetResource.assetResources(for: asset2).first?.originalFilename ?? asset2.localIdentifier)
                return name1.localizedStandardCompare(name2) == .orderedAscending
            }
        case "date":
            sortedAssets.sort { ($0.creationDate ?? Date.distantPast) > ($1.creationDate ?? Date.distantPast) }
        default:
            // Default to date
            sortedAssets.sort { ($0.creationDate ?? Date.distantPast) > ($1.creationDate ?? Date.distantPast) }
        }
        
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>iPhone Media Gallery</title>
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
                .info {
                    color: #999;
                    font-size: 0.9em;
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
                .gallery-item.video::after {
                    content: '▶';
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    font-size: 60px;
                    color: white;
                    text-shadow: 0 2px 8px rgba(0,0,0,0.7);
                    pointer-events: none;
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
                .video-dialog {
                    display: none;
                    position: fixed;
                    top: 0;
                    left: 0;
                    width: 100%;
                    height: 100%;
                    background: rgba(0,0,0,0.95);
                    z-index: 1001;
                    align-items: center;
                    justify-content: center;
                }
                .video-dialog.active {
                    display: flex;
                }
                .video-dialog video {
                    max-width: 90%;
                    max-height: 90%;
                    border-radius: 8px;
                }
                .video-dialog-close {
                    position: absolute;
                    top: 20px;
                    right: 30px;
                    font-size: 40px;
                    color: white;
                    cursor: pointer;
                    z-index: 1002;
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
                <div>
                    <h1>📱 iPhone Media Gallery</h1>
                    <div class='info'>\(photoAssets.count) items</div>
                </div>
                <div class='controls'>
                    <a href='?sort=date' class='sort-btn \(sortBy == "date" ? "active" : "")'>Sort by Date</a>
                    <a href='?sort=name' class='sort-btn \(sortBy == "name" ? "active" : "")'>Sort by Name</a>
                </div>
            </div>
            <div class='gallery'>
        """
        
        if sortedAssets.isEmpty {
            html += "<p style='grid-column: 1/-1; text-align: center;'>No media found</p>"
        } else {
            for (index, asset) in sortedAssets.enumerated() {
                let assetId = asset.localIdentifier
                let isVideo = asset.mediaType == .video
                let videoClass = isVideo ? " video" : ""
                let imageUrl = isVideo ? "/photo/\(assetId)" : "/photo/\(assetId)"
                
                html += """
                <div class='gallery-item\(videoClass)' onclick='openMedia(\(index))'>
                    <img src='\(imageUrl)' alt='Item \(index + 1)' loading='lazy'>
                </div>
                """
            }
        }
        
        html += """
            </div>
            <div class='lightbox' id='lightbox'>
                <span class='lightbox-close' onclick='closeLightbox()'>×</span>
                <span class='lightbox-nav lightbox-prev' onclick='event.stopPropagation(); changeImage(-1)'>‹</span>
                <img id='lightbox-img' src='' alt='' loading='lazy'>
                <span class='lightbox-nav lightbox-next' onclick='event.stopPropagation(); changeImage(1)'>›</span>
            </div>
            <div class='video-dialog' id='video-dialog' onclick='closeVideoDialog()'>
                <span class='video-dialog-close' onclick='closeVideoDialog()'>×</span>
                <video id='video-player' controls onclick='event.stopPropagation()'>
                    <source id='video-source' src='' type='video/mp4'>
                    Your browser does not support the video tag.
                </video>
            </div>
            <script>
                const media = [
        """
        
        for asset in sortedAssets {
            let isVideo = asset.mediaType == .video
            let type = isVideo ? "video" : "image"
            let imagePath = "/photo/\(asset.localIdentifier)"
            let videoPath = "/video/\(asset.localIdentifier)"
            html += "{type: '\(type)', imagePath: '\(imagePath)', videoPath: '\(videoPath)'},\n"
        }
        
        html += """
                ];
                let currentIndex = 0;
                
                function openMedia(index) {
                    currentIndex = index;
                    const item = media[index];
                    
                    if (item.type === 'image') {
                        document.getElementById('lightbox-img').src = item.imagePath;
                        document.getElementById('lightbox').classList.add('active');
                    } else if (item.type === 'video') {
                        const videoPlayer = document.getElementById('video-player');
                        const videoSource = document.getElementById('video-source');
                        videoSource.src = item.videoPath;
                        videoPlayer.load();
                        document.getElementById('video-dialog').classList.add('active');
                    }
                }
                
                function closeLightbox() {
                    document.getElementById('lightbox').classList.remove('active');
                }
                
                function closeVideoDialog() {
                    const dialog = document.getElementById('video-dialog');
                    const videoPlayer = document.getElementById('video-player');
                    videoPlayer.pause();
                    videoPlayer.currentTime = 0;
                    dialog.classList.remove('active');
                }
                
                function changeImage(direction) {
                    let newIndex = currentIndex;
                    let found = false;
                    
                    // Find next image (skip videos)
                    for (let i = 0; i < media.length; i++) {
                        newIndex = (newIndex + direction + media.length) % media.length;
                        if (media[newIndex].type === 'image') {
                            found = true;
                            break;
                        }
                    }
                    
                    if (found) {
                        currentIndex = newIndex;
                        document.getElementById('lightbox-img').src = media[currentIndex].imagePath;
                    }
                }
                
                document.addEventListener('keydown', function(e) {
                    const lightboxActive = document.getElementById('lightbox').classList.contains('active');
                    const videoActive = document.getElementById('video-dialog').classList.contains('active');
                    
                    if (lightboxActive) {
                        if (e.key === 'Escape') closeLightbox();
                        if (e.key === 'ArrowLeft') changeImage(-1);
                        if (e.key === 'ArrowRight') changeImage(1);
                    }
                    
                    if (videoActive && e.key === 'Escape') {
                        closeVideoDialog();
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
                    const swipeThreshold = 50;
                    const diff = touchStartX - touchEndX;
                    
                    if (Math.abs(diff) > swipeThreshold) {
                        if (diff > 0) {
                            changeImage(1);
                        } else {
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
}
