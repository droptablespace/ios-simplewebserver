# Simple Web Server

A lightweight iOS app that turns your device into a file server. Browse and share files from any folder over your local network.

## Features

- 📁 **Folder Browser** - Navigate through directories with a clean web interface
- 🖼️ **Image Gallery** - View images in a grid layout with lightbox support and natural sorting
- 🎬 **Video Player** - Stream videos with built-in HTML5 player
- 📝 **Markdown Viewer** - Render `.md` files beautifully
- 📥 **Download Files** - Download individual files with a single click
- 📦 **Download Folders as ZIP** - Download entire folders as compressed archives
- 📱 **Network Access** - Access from any device on your local network
- 🔒 **Protected Mode** - Secure your server with access codes for privacy
- 📷 **QR Code Reader** - Scan QR codes to quickly enter access codes
- 📱 **Photo Library Access** - Browse and share photos/videos from your device's photo library

## Requirements

- iOS 15.0+
- Xcode 14.0+

## Dependencies

### Swift Frameworks
- [FlyingFox](https://github.com/swhitty/FlyingFox) - Lightweight HTTP server
- [Zip](https://github.com/marmelroy/Zip) - Swift framework for zipping and unzipping files
- [CodeScanner](https://github.com/twostraws/CodeScanner) - QR code scanner for iOS

### JavaScript Libraries (included in HTML templates)
- [markdown-it](https://github.com/markdown-it/markdown-it) - Markdown parser for rendering .md files
- [qrcode.js](https://github.com/davidshimjs/qrcode) - QR code generator for secure access

## Usage

1. Launch the app
2. Tap "Choose Folder" and select a directory
3. Tap "Start Server"
4. Access the server from any browser using the displayed URL

## License

MIT
