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
import Photos

@MainActor
class WebServerManager: NSObject, ObservableObject {
    @Published var selectedFolderURL: URL?
    @Published var sourceType: SourceType = .folder
    @Published var isServerRunning = false
    @Published var errorMessage: String?
    @Published var serverURL: String?
    @Published var networkAddresses: [String] = []
    @Published var bonjourHostname: String?
    
    // Expose security manager properties
    var secureMode: Bool {
        get { securityManager.secureMode }
        set { securityManager.secureMode = newValue }
    }
    
    var photoLibraryAuthorized: Bool {
        photoGalleryManager.photoLibraryAuthorized
    }
    
    var authorizedCodes: Set<String> {
        securityManager.authorizedCodes
    }
    
    private var server: HTTPServer?
    let port: UInt16 = 8080
    private var serverTask: Task<Void, Never>?
    
    // Dependency managers
    private let securityManager = SecurityManager()
    private let photoGalleryManager = PhotoGalleryManager()
    private let htmlGenerator = HTMLGenerator()
    private lazy var requestHandlers = RequestHandlers(
        htmlGenerator: htmlGenerator,
        securityManager: securityManager,
        photoGalleryManager: photoGalleryManager
    )
    
    override init() {
        super.init()
        requestHandlers.webServerManager = self
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
        ) { _ in
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
        await photoGalleryManager.requestPhotoLibraryAccess()
        if photoGalleryManager.photoLibraryAuthorized {
            sourceType = .photoGallery
            selectedFolderURL = URL(fileURLWithPath: "Photos")
            errorMessage = nil
        } else {
            errorMessage = "Photo library access denied. Please enable in Settings."
        }
    }
    
    func startServer() async {
        guard let folderURL = selectedFolderURL else {
            errorMessage = "No source selected"
            return
        }
        
        // For folder source, re-access security-scoped resource and validate
        if sourceType == .folder {
            // Try to start accessing the security-scoped resource
            if !folderURL.startAccessingSecurityScopedResource() {
                errorMessage = "Cannot access folder. Please select the folder again."
                selectedFolderURL = nil
                return
            }
            
            // Validate we can actually read the folder
            if !validateFolderAccess() {
                errorMessage = "Folder is no longer accessible. Please select the folder again."
                folderURL.stopAccessingSecurityScopedResource()
                selectedFolderURL = nil
                return
            }
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
            
            // Capture secure mode state for route handlers
            let isSecure = self.secureMode
            
            // Secure page route (must come before other routes)
            await newServer.appendRoute("GET /secure") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                return await self.handleSecurePageRequest()
            }
            
            // Check session code endpoint
            await newServer.appendRoute("GET /check-session") { [weak self] request in
                guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                return await self.handleCheckSessionRequest(request: request)
            }
            
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
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return await self.handleSecurePageRequest()
                        }
                    }
                    
                    return await self.handlePhotoGalleryRoot(sortBy: request.query["sort"] ?? "date")
                }
                
                // Photo asset serving route
                await newServer.appendRoute("GET /photo/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return HTTPResponse(statusCode: .seeOther, headers: [.location: "/secure"])
                        }
                    }
                    
                    let assetId = String(request.path.dropFirst("/photo/".count))
                    return await self.handlePhotoAssetRequest(assetId: assetId)
                }
                
                // Video asset serving route
                await newServer.appendRoute("GET /video/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return HTTPResponse(statusCode: .seeOther, headers: [.location: "/secure"])
                        }
                    }
                    
                    let assetId = String(request.path.dropFirst("/video/".count))
                    return await self.handleVideoAssetRequest(assetId: assetId, request: request)
                }
            } else {
                // Folder routes
                await newServer.appendRoute("GET /") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return await self.handleSecurePageRequest()
                        }
                    }
                    
                    return await self.handleBrowseRequest(path: "", request: request)
                }
                
                // Browse route for folders
                await newServer.appendRoute("GET /browse/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return HTTPResponse(statusCode: .seeOther, headers: [.location: "/secure"])
                        }
                    }
                    
                    let path = String(request.path.dropFirst("/browse/".count))
                    return await self.handleBrowseRequest(path: path, request: request)
                }
                
                // File serving route
                await newServer.appendRoute("GET /file/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return HTTPResponse(statusCode: .seeOther, headers: [.location: "/secure"])
                        }
                    }
                    
                    let path = String(request.path.dropFirst("/file/".count))
                    return await self.handleFileRequest(path: path, request: request)
                }
                
                // Image gallery route
                await newServer.appendRoute("GET /gallery/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return HTTPResponse(statusCode: .seeOther, headers: [.location: "/secure"])
                        }
                    }
                    
                    let path = String(request.path.dropFirst("/gallery/".count))
                    let sortBy = request.query["sort"] ?? "name"
                    return await self.handleGalleryRequest(path: path, sortBy: sortBy)
                }
                
                // Download file route
                await newServer.appendRoute("GET /download/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return HTTPResponse(statusCode: .seeOther, headers: [.location: "/secure"])
                        }
                    }
                    
                    let path = String(request.path.dropFirst("/download/".count))
                    return await self.handleDownloadRequest(path: path)
                }
                
                // Download folder as zip route
                await newServer.appendRoute("GET /download-zip/*") { [weak self] request in
                    guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
                    
                    // Check secure mode
                    if isSecure {
                        let isValid = await self.validateSessionCode(from: request)
                        if !isValid {
                            return HTTPResponse(statusCode: .seeOther, headers: [.location: "/secure"])
                        }
                    }
                    
                    let path = String(request.path.dropFirst("/download-zip/".count))
                    return await self.handleDownloadZipRequest(path: path)
                }
            }
            
            // Start the server and handle errors properly
            // Keep track of the task so we can monitor it
            serverTask = Task {
                do {
                    try await newServer.run()
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
            let ipAddresses = NetworkUtilities.getLocalIPAddresses()
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
        
        // Clear authorized codes when server stops
        securityManager.clearAuthorizedCodes()
        
        // Clean up temporary video files
        photoGalleryManager.cleanupTempVideos()
        requestHandlers.cleanupTranscodedVideos()
        
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
    
    // MARK: - Security Methods
    
    func authorizeCode(_ code: String) {
        securityManager.authorizeCode(code)
    }
    
    private func validateSessionCode(from request: HTTPRequest) async -> Bool {
        return securityManager.validateSessionCode(from: request)
    }
    
    private func handleSecurePageRequest() async -> HTTPResponse {
        return await requestHandlers.handleSecurePageRequest()
    }
    
    private func handleCheckSessionRequest(request: HTTPRequest) async -> HTTPResponse {
        return await requestHandlers.handleCheckSessionRequest(request: request)
    }
    
    
    // MARK: - Request Handlers
    
    private func handleBrowseRequest(path: String, request: HTTPRequest) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        return await requestHandlers.handleBrowseRequest(path: path, request: request, folderURL: folderURL)
    }
    
    private func handleFileRequest(path: String, request: HTTPRequest? = nil) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        return await requestHandlers.handleFileRequest(path: path, request: request, folderURL: folderURL)
    }
    
    private func handleGalleryRequest(path: String, sortBy: String) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        return await requestHandlers.handleGalleryRequest(path: path, sortBy: sortBy, folderURL: folderURL)
    }
    
    
    // MARK: - Static File Handler
    
    private func handleStaticFileRequest(path: String) async -> HTTPResponse {
        return await requestHandlers.handleStaticFileRequest(path: path)
    }
    
    // MARK: - Download Handlers
    
    private func handleDownloadRequest(path: String) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        return await requestHandlers.handleDownloadRequest(path: path, folderURL: folderURL)
    }
    
    private func handleDownloadZipRequest(path: String) async -> HTTPResponse {
        guard let folderURL = selectedFolderURL else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        return await requestHandlers.handleDownloadZipRequest(path: path, folderURL: folderURL)
    }
    
    
    // MARK: - Photo Gallery Handlers
    
    private func handlePhotoGalleryRoot(sortBy: String) async -> HTTPResponse {
        return await requestHandlers.handlePhotoGalleryRoot(sortBy: sortBy)
    }
    
    private func handlePhotoAssetRequest(assetId: String) async -> HTTPResponse {
        return await requestHandlers.handlePhotoAssetRequest(assetId: assetId)
    }
    
    private func handleVideoAssetRequest(assetId: String, request: HTTPRequest) async -> HTTPResponse {
        return await requestHandlers.handleVideoAssetRequest(assetId: assetId, request: request)
    }
}
