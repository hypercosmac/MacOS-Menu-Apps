import Cocoa
import Foundation
import CoreGraphics

enum AIModel: String {
    case moondream = "moondream:v2"  // Updated to use v2 model
    case llava = "llava:7b"
    case minicpm = "minicpm-v"
}

class ScreenshotMonitor: NSObject, NSApplicationDelegate {
    private let fileManager = FileManager.default
    private var desktopPath: String
    private let ollamaPath = "/usr/local/bin/ollama"
    private var selectedModel: AIModel = .moondream
    private var statusItem: NSStatusItem!
    private var modelMenu: NSMenu!
    
    override init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.desktopPath = "\(homeDir)/Desktop"
        super.init()
        print("Monitoring Desktop folder at: \(desktopPath)")
        setupStatusBarItem()
        startMonitoring()
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📷"
        
        modelMenu = NSMenu()
        
        // Add model selection menu items
        let moondreamItem = NSMenuItem(title: "Moondream", action: #selector(selectModel(_:)), keyEquivalent: "")
        moondreamItem.representedObject = AIModel.moondream
        moondreamItem.state = .on
        
        let llavaItem = NSMenuItem(title: "LLaVA", action: #selector(selectModel(_:)), keyEquivalent: "")
        llavaItem.representedObject = AIModel.llava
        
        let minicpmItem = NSMenuItem(title: "MiniCPM", action: #selector(selectModel(_:)), keyEquivalent: "")
        minicpmItem.representedObject = AIModel.minicpm
        
        modelMenu.addItem(moondreamItem)
        modelMenu.addItem(llavaItem)
        modelMenu.addItem(minicpmItem)
        modelMenu.addItem(NSMenuItem.separator())
        modelMenu.addItem(NSMenuItem(title: "Process Screenshots", action: #selector(processExistingScreenshots), keyEquivalent: ""))
        modelMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = modelMenu
    }
    
    @objc private func selectModel(_ sender: NSMenuItem) {
        // Update checkmarks
        modelMenu.items.forEach { item in
            if let model = item.representedObject as? AIModel {
                item.state = (sender == item) ? .on : .off
                if sender == item {
                    selectedModel = model
                }
            }
        }
    }
    
    private func startMonitoring() {
        // Create a file descriptor for the Desktop directory
        let fileDescriptor = open(desktopPath, O_EVTONLY)
        if fileDescriptor < 0 {
            print("Error: Could not create file descriptor for Desktop folder")
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .link],
            queue: .main
        )
        
        source.setEventHandler { [weak self] in
            print("Change detected in Desktop folder")
            self?.checkForNewScreenshots()
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
    }
    
    private func checkForNewScreenshots() {
        do {
            let files = try fileManager.contentsOfDirectory(atPath: desktopPath)
            let screenshots = files.filter { $0.hasPrefix("Screenshot ") }
            
            if !screenshots.isEmpty {
                print("Found \(screenshots.count) screenshots: \(screenshots)")
                
                for screenshot in screenshots {
                    let fullPath = (desktopPath as NSString).appendingPathComponent(screenshot)
                    processScreenshot(at: fullPath)
                }
            }
        } catch {
            print("Error reading directory: \(error)")
        }
    }
    
    private func processScreenshot(at path: String) {
        print("Processing screenshot at: \(path)")
        
        // Check if file exists
        guard fileManager.fileExists(atPath: path) else {
            print("Error: File not found at path: \(path)")
            return
        }
        
        // Check if Ollama exists
        guard fileManager.fileExists(atPath: ollamaPath) else {
            print("Error: Ollama not found at path: \(ollamaPath)")
            return
        }
        
        // First pull the model to ensure it's available
        let pullProcess = Process()
        pullProcess.executableURL = URL(fileURLWithPath: ollamaPath)
        pullProcess.arguments = ["pull", selectedModel.rawValue]
        
        do {
            try pullProcess.run()
            pullProcess.waitUntilExit()
        } catch {
            print("Error pulling model: \(error)")
            return
        }
        
        // Create and configure process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        
        process.arguments = [
            "run", 
            selectedModel.rawValue,
            "Generate a title in less than four words for this image",
            path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            if !errorData.isEmpty {
                if let errorString = String(data: errorData, encoding: .utf8) {
                    print("Ollama Error: \(errorString)")
                    
                    // If we get a GGML error, try with LLaVA as fallback
                    if errorString.contains("GGML_ASSERT") {
                        print("Retrying with LLaVA model...")
                        let fallbackProcess = Process()
                        fallbackProcess.executableURL = URL(fileURLWithPath: ollamaPath)
                        fallbackProcess.arguments = [
                            "run",
                            AIModel.llava.rawValue,
                            "Generate a title in less than four words for this image",
                            path
                        ]
                        
                        let fallbackPipe = Pipe()
                        fallbackProcess.standardOutput = fallbackPipe
                        
                        try fallbackProcess.run()
                        fallbackProcess.waitUntilExit()
                        
                        let fallbackData = fallbackPipe.fileHandleForReading.readDataToEndOfFile()
                        if let fallbackOutput = String(data: fallbackData, encoding: .utf8) {
                            processOutput(fallbackOutput, forPath: path)
                        }
                    }
                    return
                }
            }
            
            if let output = String(data: data, encoding: .utf8) {
                processOutput(output, forPath: path)
            }
        } catch {
            print("Error running Ollama: \(error)")
        }
    }
    
    private func processOutput(_ output: String, forPath path: String) {
        print("Ollama Output: \(output)")
        let title = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        
        // Only proceed if we got a non-empty title
        if !title.isEmpty {
            print("Generated Title: \(title)")
            
            do {
                let directory = (path as NSString).deletingLastPathComponent
                let newPath = (directory as NSString).appendingPathComponent("\(title).png")
                
                print("Attempting to rename file to: \(newPath)")
                try fileManager.moveItem(atPath: path, toPath: newPath)
                print("Successfully renamed file")
            } catch {
                print("Error renaming file: \(error)")
            }
        } else {
            print("Empty title generated, skipping file rename")
        }
    }
    
    @objc func processExistingScreenshots() {
        print("Processing existing screenshots...")
        checkForNewScreenshots()
    }
}

// Create and start the app
let app = NSApplication.shared
let monitor = ScreenshotMonitor()
app.delegate = monitor
app.run()