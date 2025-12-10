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
        
        return await withCheckedContinuation { continuation in
            let videoManager = PHImageManager.default()
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            videoManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: nil)
                    return
                }
                
                continuation.resume(returning: urlAsset.url)
            }
        }
    }
}
