//
//  ContentView.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var serverManager = WebServerManager()
    @State private var showFolderPicker = false
    @State private var showCopiedToast = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Simple Web Server")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            if let folderURL = serverManager.selectedFolderURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text(serverManager.sourceType == .photoGallery ? "Source: iPhone Photos" : "Selected Folder:")
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
                                Text("Photos")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            if serverManager.selectedFolderURL != nil {
                if serverManager.isServerRunning {
                    VStack(spacing: 12) {
                        Text("Server Running")
                            .font(.headline)
                            .foregroundColor(.green)
                        
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
                                Text("Access from other devices:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                
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
