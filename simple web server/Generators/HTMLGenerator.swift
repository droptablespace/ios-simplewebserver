//
//  HTMLGenerator.swift
//  simple web server
//
//  Created by Кирилл Ветров on 12/10/25.
//

import Foundation
import Photos

class HTMLGenerator {
    private let folderTemplate: String
    private let galleryTemplate: String
    private let errorTemplate: String
    private let secureTemplate: String
    
    init() {
        // Load templates from Templates folder
        if let folderURL = Bundle.main.url(forResource: "folder_template", withExtension: "html", subdirectory: "Templates"),
           let folderHTML = try? String(contentsOf: folderURL, encoding: .utf8) {
            folderTemplate = folderHTML
        } else {
            folderTemplate = ""
        }
        
        if let galleryURL = Bundle.main.url(forResource: "gallery_template", withExtension: "html", subdirectory: "Templates"),
           let galleryHTML = try? String(contentsOf: galleryURL, encoding: .utf8) {
            galleryTemplate = galleryHTML
        } else {
            galleryTemplate = ""
        }
        
        if let errorURL = Bundle.main.url(forResource: "error_template", withExtension: "html", subdirectory: "Templates"),
           let errorHTML = try? String(contentsOf: errorURL, encoding: .utf8) {
            errorTemplate = errorHTML
        } else {
            errorTemplate = ""
        }
        
        if let secureURL = Bundle.main.url(forResource: "secure_template", withExtension: "html", subdirectory: "Templates"),
           let secureHTML = try? String(contentsOf: secureURL, encoding: .utf8) {
            secureTemplate = secureHTML
        } else {
            secureTemplate = ""
        }
    }
    
    // MARK: - Folder HTML Generation
    
    func generateFolderHTML(for url: URL, relativePath: String) -> String {
        let fileManager = FileManager.default
        var items: [(name: String, isDirectory: Bool, path: String)] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            
            for itemURL in contents {
                let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let itemPath = relativePath.isEmpty ? itemURL.lastPathComponent : "\(relativePath)/\(itemURL.lastPathComponent)"
                items.append((name: itemURL.lastPathComponent, isDirectory: isDirectory, path: itemPath))
            }
            
            items = FileUtilities.naturalSort(items)
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
                    breadcrumb += " / <a href='/browse/\(FileUtilities.encodePathForURL(currentPath))'>\(component)</a>"
                }
            }
            
            // Check if current folder has images to show gallery button
            let currentHasImages = FileUtilities.hasImages(in: url)
            let galleryButton = currentHasImages ? "<div style='margin: 20px 0;'><a href='/gallery/\(FileUtilities.encodePathForURL(relativePath))' class='gallery-view-btn' style='display: inline-block; padding: 10px 20px; background: #007AFF; color: white; text-decoration: none; border-radius: 6px; font-weight: 500;'>🖼️ View as Gallery</a></div>" : ""
            
            // Generate items HTML
            var itemsHTML = ""
            if items.isEmpty {
                itemsHTML = "<p>Empty folder</p>"
            } else {
                for item in items {
                    let encodedPath = FileUtilities.encodePathForURL(item.path)
                    
                    if item.isDirectory {
                        let folderURL = url.appendingPathComponent(item.name)
                        if FileUtilities.hasImages(in: folderURL) {
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
                        itemsHTML += generateFileItemHTML(encodedPath: encodedPath, name: item.name, icon: "📄", additionalClass: "pdf")
                    } else if item.name.lowercased().hasSuffix(".md") {
                        itemsHTML += generateFileItemHTML(encodedPath: encodedPath, name: item.name, icon: "📝")
                    } else if FileUtilities.isVideoFile(item.name) {
                        itemsHTML += generateFileItemHTML(encodedPath: encodedPath, name: item.name, icon: "🎬")
                    } else if FileUtilities.isImageFile(item.name) {
                        itemsHTML += generateFileItemHTML(encodedPath: encodedPath, name: item.name, icon: "🖼️", additionalClass: "image")
                    } else {
                        itemsHTML += generateFileItemHTML(encodedPath: encodedPath, name: item.name, icon: "📄")
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
    
    private func generateFileItemHTML(encodedPath: String, name: String, icon: String, additionalClass: String = "") -> String {
        return """
        <div class='item'>
            <span class='item-icon \(additionalClass)'>\(icon)</span>
            <span class='item-name'>
                <a href='/file/\(encodedPath)' target='_blank'>\(name)</a>
                <small style='color: #999;'> | <a href='/download/\(encodedPath)'>Download</a></small>
            </span>
        </div>
        """
    }
    
    // MARK: - Gallery HTML Generation
    
    func generateGalleryHTML(for url: URL, relativePath: String, sortBy: String) -> String {
        let fileManager = FileManager.default
        var mediaItems: [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            
            for itemURL in contents {
                let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDirectory && (FileUtilities.isImageFile(itemURL.lastPathComponent) || FileUtilities.isVideoFile(itemURL.lastPathComponent)) {
                    let modDate = (try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    let fileSize = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    let itemPath = relativePath.isEmpty ? itemURL.lastPathComponent : "\(relativePath)/\(itemURL.lastPathComponent)"
                    let isVideo = FileUtilities.isVideoFile(itemURL.lastPathComponent)
                    mediaItems.append((name: itemURL.lastPathComponent, path: itemPath, modificationDate: modDate, size: Int64(fileSize), isVideo: isVideo))
                }
            }
            
            // Sort media items
            switch sortBy {
            case "date":
                mediaItems.sort { ($0.modificationDate ?? Date.distantPast) > ($1.modificationDate ?? Date.distantPast) }
            case "size":
                mediaItems.sort { $0.size > $1.size }
            default: // "name"
                mediaItems = FileUtilities.naturalSortMediaItems(mediaItems)
            }
        } catch {
            return generateErrorHTML("Error reading directory: \(error.localizedDescription)")
        }
        
        // Use template if available
        if !galleryTemplate.isEmpty {
            let controls = generateGalleryControls(relativePath: relativePath, sortBy: sortBy)
            let itemsHTML = generateGalleryItemsHTML(mediaItems: mediaItems)
            let mediaJSON = generateMediaJSON(mediaItems: mediaItems)
            
            return galleryTemplate
                .replacingOccurrences(of: "{{CONTROLS}}", with: controls)
                .replacingOccurrences(of: "{{GALLERY_ITEMS}}", with: itemsHTML)
                .replacingOccurrences(of: "{{MEDIA_ITEMS}}", with: mediaJSON)
        }
        
        // Fallback to inline HTML generation
        return generateGalleryHTMLInline(relativePath: relativePath, sortBy: sortBy, mediaItems: mediaItems)
    }
    
    private func generateGalleryControls(relativePath: String, sortBy: String) -> String {
        return """
        <a href='/browse/\(FileUtilities.encodePathForURL(relativePath))' class='back-btn'>← Back to Folder</a>
        <a href='?sort=name' class='sort-btn \(sortBy == "name" ? "active" : "")'>Sort by Name</a>
        <a href='?sort=date' class='sort-btn \(sortBy == "date" ? "active" : "")'>Sort by Date</a>
        <a href='?sort=size' class='sort-btn \(sortBy == "size" ? "active" : "")'>Sort by Size</a>
        """
    }
    
    private func generateGalleryItemsHTML(mediaItems: [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)]) -> String {
        if mediaItems.isEmpty {
            return "<p style='grid-column: 1/-1; text-align: center;'>No images or videos found in this folder</p>"
        }
        
        var itemsHTML = ""
        for (index, item) in mediaItems.enumerated() {
            let encodedPath = FileUtilities.encodePathForURL(item.path)
            let videoClass = item.isVideo ? " video" : ""
            
            if item.isVideo {
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
        return itemsHTML
    }
    
    private func generateMediaJSON(mediaItems: [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)]) -> String {
        var mediaJSON = ""
        for item in mediaItems {
            let encodedPath = FileUtilities.encodePathForURL(item.path)
            let type = item.isVideo ? "video" : "image"
            let mimeType = FileUtilities.mimeTypeForPath(item.name)
            let videoPath = item.isVideo ? "/file/\(encodedPath)?raw=true" : "/file/\(encodedPath)"
            mediaJSON += "{type: '\(type)', path: '\(videoPath)', mimeType: '\(mimeType)'},\n"
        }
        return mediaJSON
    }
    
    // MARK: - Video Player HTML
    
    func generateVideoPlayerHTML(videoPath: String, filename: String) -> String {
        let encodedPath = FileUtilities.encodePathForURL(videoPath)
        
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
                <source src="/file/\(encodedPath)?raw=true" type="\(FileUtilities.mimeTypeForPath(filename))">
                Your browser does not support the video element.
            </video>
        </body>
        </html>
        """
    }
    
    // MARK: - Markdown HTML
    
    func generateMarkdownHTML(content: String, filename: String) -> String {
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
    
    // MARK: - Error HTML
    
    func generateErrorHTML(_ message: String) -> String {
        if !errorTemplate.isEmpty {
            return errorTemplate.replacingOccurrences(of: "{{ERROR_MESSAGE}}", with: message)
        }
        
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
    
    // MARK: - Security HTML
    
    func generateSecurePageHTML() -> String {
        if !secureTemplate.isEmpty {
            return secureTemplate
        }
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Secure Access Required</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                    margin: 0;
                    background: #667eea;
                    color: white;
                }
                .container {
                    background: white;
                    border-radius: 20px;
                    padding: 40px;
                    text-align: center;
                    color: #333;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🔒 Protected Access Required</h1>
                <p>This server requires authorization. Please ensure the secure_template.html file is properly loaded.</p>
            </div>
        </body>
        </html>
        """
    }
    
    // MARK: - Photo Gallery HTML
    
    func generatePhotoGalleryHTML(assets: [PHAsset], sortBy: String) -> String {
        var sortedAssets = assets
        
        switch sortBy {
        case "name":
            sortedAssets.sort { asset1, asset2 in
                let name1 = (PHAssetResource.assetResources(for: asset1).first?.originalFilename ?? asset1.localIdentifier)
                let name2 = (PHAssetResource.assetResources(for: asset2).first?.originalFilename ?? asset2.localIdentifier)
                return name1.localizedStandardCompare(name2) == .orderedAscending
            }
        case "date":
            sortedAssets.sort { ($0.creationDate ?? Date.distantPast) > ($1.creationDate ?? Date.distantPast) }
        default:
            sortedAssets.sort { ($0.creationDate ?? Date.distantPast) > ($1.creationDate ?? Date.distantPast) }
        }
        
        return generatePhotoGalleryHTMLContent(sortedAssets: sortedAssets, sortBy: sortBy)
    }
    
    // MARK: - Private Helper Methods
    
    private func generateFolderHTMLInline(for url: URL, relativePath: String, items: [(name: String, isDirectory: Bool, path: String)]) -> String {
        // Inline fallback HTML implementation
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Folder Browser</title>
        </head>
        <body>
            <h1>📁 Folder Browser</h1>
            <p>Folder browsing functionality (inline fallback)</p>
        </body>
        </html>
        """
    }
    
    private func generateGalleryHTMLInline(relativePath: String, sortBy: String, mediaItems: [(name: String, path: String, modificationDate: Date?, size: Int64, isVideo: Bool)]) -> String {
        // Inline fallback HTML implementation
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Media Gallery</title>
        </head>
        <body>
            <h1>🖼️ Media Gallery</h1>
            <p>Gallery functionality (inline fallback)</p>
        </body>
        </html>
        """
    }
    
    private func generatePhotoGalleryHTMLContent(sortedAssets: [PHAsset], sortBy: String) -> String {
        // Use template if available
        if !galleryTemplate.isEmpty {
            let controls = generatePhotoGalleryControls(sortBy: sortBy)
            let itemsHTML = generatePhotoGalleryItemsHTML(assets: sortedAssets)
            let mediaJSON = generatePhotoGalleryMediaJSON(assets: sortedAssets)
            
            return galleryTemplate
                .replacingOccurrences(of: "{{CONTROLS}}", with: controls)
                .replacingOccurrences(of: "{{GALLERY_ITEMS}}", with: itemsHTML)
                .replacingOccurrences(of: "{{MEDIA_ITEMS}}", with: mediaJSON)
        }
        
        // Fallback HTML if template not available
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>📱 iPhone Media Gallery</title>
        </head>
        <body>
            <h1>📱 iPhone Media Gallery</h1>
            <p>\(sortedAssets.count) items found</p>
        </body>
        </html>
        """
    }
    
    private func generatePhotoGalleryControls(sortBy: String) -> String {
        return """
        <a href='?sort=name' class='sort-btn \(sortBy == "name" ? "active" : "")'>Sort by Name</a>
        <a href='?sort=date' class='sort-btn \(sortBy == "date" ? "active" : "")'>Sort by Date</a>
        """
    }
    
    private func generatePhotoGalleryItemsHTML(assets: [PHAsset]) -> String {
        if assets.isEmpty {
            return "<p style='grid-column: 1/-1; text-align: center;'>No photos or videos found in your media library</p>"
        }
        
        var itemsHTML = ""
        for (index, asset) in assets.enumerated() {
            let assetId = asset.localIdentifier
            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "media_\(index)"
            let videoClass = asset.mediaType == .video ? " video" : ""
            
            if asset.mediaType == .video {
                itemsHTML += """
                <div class='gallery-item\(videoClass)' onclick='openMedia(\(index))'>
                    <img class='lazy-image' data-src='/photo/\(assetId)' alt='\(filename)' src='data:image/svg+xml,%3Csvg width="1" height="1" xmlns="http://www.w3.org/2000/svg"%3E%3Crect width="100%25" height="100%25" fill="%23333"/%3E%3C/svg%3E'>
                    <div class='image-name'>\(filename)</div>
                </div>
                """
            } else {
                itemsHTML += """
                <div class='gallery-item' onclick='openMedia(\(index))'>
                    <img class='lazy-image' data-src='/photo/\(assetId)' alt='\(filename)' src='data:image/svg+xml,%3Csvg width="1" height="1" xmlns="http://www.w3.org/2000/svg"%3E%3Crect width="100%25" height="100%25" fill="%23333"/%3E%3C/svg%3E'>
                    <div class='image-name'>\(filename)</div>
                </div>
                """
            }
        }
        return itemsHTML
    }
    
    private func generatePhotoGalleryMediaJSON(assets: [PHAsset]) -> String {
        var mediaJSON = ""
        for asset in assets {
            let assetId = asset.localIdentifier
            let type = asset.mediaType == .video ? "video" : "image"
            let path = asset.mediaType == .video ? "/video/\(assetId)" : "/photo/\(assetId)"
            let mimeType = asset.mediaType == .video ? "video/mp4" : "image/jpeg"
            mediaJSON += "{type: '\(type)', path: '\(path)', mimeType: '\(mimeType)'},\n"
        }
        return mediaJSON
    }
}
