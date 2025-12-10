//
//  PhotoGalleryManager.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import Foundation
import Photos
import UIKit
import Combine
import AVFoundation

class PhotoGalleryManager: ObservableObject {
    @Published var photoLibraryAuthorized = false
    private var photoAssets: [PHAsset] = []
    private var assetCache: [String: Data] = [:]
    
    // MARK: - Photo Library Access
    
    func requestPhotoLibraryAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            await MainActor.run {
                self.photoLibraryAuthorized = true
            }
            await fetchPhotoAssets()
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await MainActor.run {
                if newStatus == .authorized || newStatus == .limited {
                    self.photoLibraryAuthorized = true
                } else {
                    self.photoLibraryAuthorized = false
                }
            }
            if newStatus == .authorized || newStatus == .limited {
                await fetchPhotoAssets()
            }
        case .denied, .restricted:
            await MainActor.run {
                self.photoLibraryAuthorized = false
            }
        @unknown default:
            await MainActor.run {
                self.photoLibraryAuthorized = false
            }
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
        
        await MainActor.run {
            self.photoAssets = assets
            self.assetCache.removeAll()
        }
    }
    
    // MARK: - Asset Access
    
    func getPhotoAssets() -> [PHAsset] {
        return photoAssets
    }
    
    func getAssetData(for assetId: String) async -> Data? {
        // Check cache first
        if let cachedData = assetCache[assetId] {
            return cachedData
        }
        
        // Find asset by ID
        guard let asset = photoAssets.first(where: { $0.localIdentifier == assetId }) else {
            return nil
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
                    continuation.resume(returning: nil)
                    return
                }
                
                // Cache the data
                Task { @MainActor in
                    self.assetCache[assetId] = data
                }
                
                continuation.resume(returning: data)
            }
        }
    }
    
    func getVideoAssetURL(for assetId: String) async -> URL? {
        // Find asset by ID
        guard let asset = photoAssets.first(where: { $0.localIdentifier == assetId }),
              asset.mediaType == .video else {
            return nil
        }
        
        // Create a unique temp file for this video
        let tempDir = FileManager.default.temporaryDirectory
        let safeAssetId = assetId.replacingOccurrences(of: "/", with: "_")
        let tempVideoURL = tempDir.appendingPathComponent("video_\(safeAssetId).mp4")
        
        // If temp file already exists, use it
        if FileManager.default.fileExists(atPath: tempVideoURL.path) {
            return tempVideoURL
        }
        
        // Choose appropriate export preset based on video resolution
        // This ensures H.264 output which is universally supported
        let exportPreset: String
        let videoWidth = asset.pixelWidth
        let videoHeight = asset.pixelHeight
        let maxDimension = max(videoWidth, videoHeight)
        
        if maxDimension >= 1920 {
            exportPreset = AVAssetExportPreset1920x1080
        } else if maxDimension >= 1280 {
            exportPreset = AVAssetExportPreset1280x720
        } else if maxDimension >= 960 {
            exportPreset = AVAssetExportPreset960x540
        } else {
            exportPreset = AVAssetExportPreset640x480
        }
        
        print("Video dimensions: \(videoWidth)x\(videoHeight), using preset: \(exportPreset)")
        
        // Export video using AVAssetExportSession with H.264 for maximum compatibility
        return await withCheckedContinuation { continuation in
            let videoManager = PHImageManager.default()
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            // Request export session with resolution preset to force H.264 transcoding
            videoManager.requestExportSession(forVideo: asset, options: options, exportPreset: exportPreset) { exportSession, _ in
                guard let exportSession = exportSession else {
                    print("Export session creation failed, trying direct export")
                    // If export session fails, try direct resource export
                    self.exportVideoDirectly(for: asset, to: tempVideoURL, continuation: continuation)
                    return
                }
                
                // Remove existing temp file if any
                try? FileManager.default.removeItem(at: tempVideoURL)
                
                Task {
                    do {
                        try await exportSession.export(to: tempVideoURL, as: .mp4)
                        print("Video export completed successfully to H.264")
                        continuation.resume(returning: tempVideoURL)
                    } catch {
                        print("Export failed: \(error.localizedDescription)")
                        // Try direct export as fallback
                        self.exportVideoDirectly(for: asset, to: tempVideoURL, continuation: continuation)
                    }
                }
            }
        }
    }
    
    private func exportVideoDirectly(for asset: PHAsset, to tempVideoURL: URL, continuation: CheckedContinuation<URL?, Never>) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) else {
            continuation.resume(returning: nil)
            return
        }
        
        // Use PHAssetResourceManager for direct export
        let resourceManager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        
        // Remove existing temp file if any
        try? FileManager.default.removeItem(at: tempVideoURL)
        
        resourceManager.writeData(for: videoResource, toFile: tempVideoURL, options: options) { error in
            if error == nil {
                continuation.resume(returning: tempVideoURL)
            } else {
                print("Error exporting video directly: \(error!)")
                continuation.resume(returning: nil)
            }
        }
    }
    
    // Clean up temp videos when they're no longer needed
    func cleanupTempVideos() {
        let tempDir = FileManager.default.temporaryDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for file in contents where file.lastPathComponent.hasPrefix("video_") {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            print("Error cleaning temp videos: \(error)")
        }
    }
}
