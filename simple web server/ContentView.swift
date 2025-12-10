//
//  ContentView.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import SwiftUI
import UniformTypeIdentifiers
import CodeScanner
import AVFoundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var serverManager = WebServerManager()
    @State private var showFolderPicker = false
    @State private var showCopiedToast = false
    @State private var showQRScanner = false
    @State private var secureMode = false
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Simple Web Server")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            if let folderURL = serverManager.selectedFolderURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text(serverManager.sourceType == .photoGallery ? "Source: Media Gallery" : "Selected Folder:")
                        .font(.headline)
                    if serverManager.sourceType == .folder {
                        Text(folderURL.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            // Source Type Selection
            if !serverManager.isServerRunning {
                VStack(spacing: 12) {
                    Text("Choose Source:")
                        .font(.headline)
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            showFolderPicker = true
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 32))
                                Text("Folder")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        
                        Button(action: {
                            Task {
                                await serverManager.requestPhotoLibraryAccess()
                            }
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.fill.on.rectangle.fill")
                                    .font(.system(size: 32))
                                Text("Media Gallery")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            if serverManager.selectedFolderURL != nil {
                // Secure Mode Toggle (only show when folder/gallery is selected but server not running)
                if !serverManager.isServerRunning {
                    Toggle(isOn: $secureMode) {
                        HStack {
                            Image(systemName: secureMode ? "lock.fill" : "lock.open.fill")
                                .foregroundColor(secureMode ? .green : .gray)
                            Text("Protected Mode")
                                .font(.headline)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .onChange(of: secureMode) { oldValue, newValue in
                        serverManager.secureMode = newValue
                    }
                }
                
                if serverManager.isServerRunning {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Server Running")
                                .font(.headline)
                                .foregroundColor(.green)
                            
                            if serverManager.secureMode {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundColor(.green)
                                Text("Protected")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        // Secure mode instructions
                        if serverManager.secureMode {
                            VStack(spacing: 10) {
                                Text("🔐 Protected Mode Active")
                                    .font(.headline)
                                    .foregroundColor(.green)
                                
                                Text("To connect:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text("1. Open the server URL in browser\n2. Scan QR code with this app\n3. Confirm on webpage")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                
                                Button(action: {
                                    showQRScanner = true
                                }) {
                                    Label("Scan Client QR Code", systemImage: "qrcode.viewfinder")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                }
                                .padding(.horizontal)
                                
                                if !serverManager.authorizedCodes.isEmpty {
                                    Text("Authorized clients: \(serverManager.authorizedCodes.count)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Access from this device:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            
                            AddressRow(
                                address: "http://localhost:\(String(serverManager.port))",
                                showCopiedToast: $showCopiedToast
                            )
                            
                            if !serverManager.networkAddresses.isEmpty {
                                Divider()
                                Text("Access from other devices on local network:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                
                                // mDNS address (Bonjour) - using actual Bonjour hostname
                                if let bonjourHost = serverManager.bonjourHostname {
                                    AddressRow(
                                        address: "http://\(bonjourHost):\(String(serverManager.port))",
                                        showCopiedToast: $showCopiedToast
                                    )
                                }
                                
                                // IP addresses
                                ForEach(serverManager.networkAddresses, id: \.self) { address in
                                    AddressRow(
                                        address: "http://\(address):\(String(serverManager.port))",
                                        showCopiedToast: $showCopiedToast
                                    )
                                }
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                        
                        Button(action: {
                            Task {
                                await serverManager.stopServer()
                            }
                        }) {
                            Label("Stop Server", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .padding(.horizontal)
                        
                        #if os(iOS)
                        VStack(spacing: 4) {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text("Note: While the server is running, your iPhone will not sleep. This will lead to battery drain.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                        #endif
                    }
                } else {
                    Button(action: {
                        Task {
                            await serverManager.startServer()
                        }
                    }) {
                        Label("Start Server", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
            }
            
            if let error = serverManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding()
            }
            
            Spacer()
        }
        .padding()
        .overlay(
            Group {
                if showCopiedToast {
                    Text("Copied to clipboard!")
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
                }
            }
            , alignment: .bottom
        )
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    serverManager.selectFolder(url)
                }
            case .failure(let error):
                serverManager.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView(serverManager: serverManager, isPresented: $showQRScanner)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // When app becomes active, check if server still has access
            if newPhase == .active && oldPhase != .active {
                checkServerAccess()
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func getDeviceName() -> String {
        #if os(iOS)
        let deviceName = UIDevice.current.name
        #elseif os(macOS)
        let deviceName = Host.current().localizedName ?? "device"
        #endif
        
        return deviceName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }
    
    private func checkServerAccess() {
        // Only check if server is running
        guard serverManager.isServerRunning else { return }
        
        // Validate folder/photo access
        if !serverManager.validateFolderAccess() {
            // Access lost - stop server and show warning
            Task {
                await serverManager.stopServer()
                
                // Set error message based on source type
                if serverManager.sourceType == .photoGallery {
                    serverManager.errorMessage = "⚠️ Server stopped: Photo library access was lost. Please restart the server."
                } else {
                    serverManager.errorMessage = "⚠️ Server stopped: Folder access was lost. Please select the folder again and restart the server."
                }
            }
        }
    }
}

// MARK: - QR Scanner View
struct QRScannerView: View {
    @ObservedObject var serverManager: WebServerManager
    @Binding var isPresented: Bool
    @State private var scannedCode: String?
    @State private var showError = false
    
    var body: some View {
        NavigationView {
            VStack {
                if let code = scannedCode {
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("QR Code Scanned!")
                            .font(.title)
                        
                        Text("Code: \(code)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button("Done") {
                            isPresented = false
                        }
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .padding()
                } else {
                    CodeScannerView(codeTypes: [.qr], simulatedData: "test-session-12345") { response in
                        switch response {
                        case .success(let result):
                            handleScan(result.string)
                        case .failure(let error):
                            print("Scanning failed: \(error.localizedDescription)")
                            showError = true
                        }
                    }
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .alert("Scanning Error", isPresented: $showError) {
                Button("OK") {
                    isPresented = false
                }
            } message: {
                Text("Failed to scan QR code. Please try again.")
            }
        }
    }
    
    private func handleScan(_ code: String) {
        scannedCode = code
        serverManager.authorizeCode(code)
    }
}

// MARK: - Address Row Component
struct AddressRow: View {
    let address: String
    @Binding var showCopiedToast: Bool
    
    var body: some View {
        HStack {
            Text(address)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.blue)
                .onTapGesture {
                    openInSafari()
                }
            
            Spacer()
            
            Button(action: {
                copyToClipboard()
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    private func copyToClipboard() {
        #if os(iOS)
        UIPasteboard.general.string = address
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #endif
        
        withAnimation {
            showCopiedToast = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopiedToast = false
            }
        }
    }
    
    private func openInSafari() {
        guard let url = URL(string: address) else { return }
        
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

#Preview {
    ContentView()
}
