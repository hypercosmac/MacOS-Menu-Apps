import Cocoa
import AVFoundation

class CustomWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer: Bool) {
        super.init(contentRect: contentRect, 
                  styleMask: [.borderless], // Make it borderless
                  backing: backing, 
                  defer: `defer`)
        
        self.isOpaque = false
        self.hasShadow = true
        self.backgroundColor = .clear
        self.level = .floating
        self.isMovableByWindowBackground = true
    }
}

class CustomView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 125 // Default radius
        layer?.masksToBounds = true
    }
}

class WebcamWindowController: NSWindowController {
    internal var previewLayer: AVCaptureVideoPreviewLayer?
    private let session = AVCaptureSession()
    
    override func loadWindow() {
        super.loadWindow()
        setupWebcam()
    }
    
    private func setupWebcam() {
        // Request camera permissions first
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async {
                self?.initializeWebcam()
            }
        }
    }
    
    private func initializeWebcam() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        
        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        
        let customView = CustomView(frame: window?.contentView?.bounds ?? .zero)
        window?.contentView = customView
        
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer?.frame = customView.bounds
        previewLayer?.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        previewLayer?.videoGravity = .resizeAspectFill
        previewLayer?.cornerRadius = 125
        
        if let layer = previewLayer {
            customView.layer?.addSublayer(layer)
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }
}

class StatusBarController {
    private var statusItem: NSStatusItem!
    private var webcamWindow: CustomWindow?
    private var windowController: WebcamWindowController?
    private var currentRadius: CGFloat = 75
    
    init() {
        setupStatusBar()
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📹"
        
        let menu = NSMenu()
        
        // Toggle webcam item
        let toggleItem = NSMenuItem(title: "Toggle Webcam", action: #selector(toggleWebcam), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Create custom view for slider
        let customView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        
        // Create and configure slider
        let slider = NSSlider(frame: NSRect(x: 10, y: 10, width: 180, height: 20))
        slider.minValue = 0
        slider.maxValue = 200
        slider.doubleValue = Double(currentRadius)
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        
        // Add label
        let label = NSTextField(frame: NSRect(x: 10, y: 25, width: 180, height: 15))
        label.stringValue = "Corner Radius: \(Int(currentRadius))px"
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.tag = 100 // Tag for updating later
        
        customView.addSubview(slider)
        customView.addSubview(label)
        
        // Create menu item with custom view
        let sliderItem = NSMenuItem()
        sliderItem.view = customView
        menu.addItem(sliderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit item
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func sliderChanged(_ sender: NSSlider) {
        currentRadius = CGFloat(sender.doubleValue)
        
        // Update the label
        if let menu = statusItem.menu,
           let sliderItem = menu.items.first(where: { $0.view != nil }),
           let customView = sliderItem.view,
           let label = customView.viewWithTag(100) as? NSTextField {
            label.stringValue = "Corner Radius: \(Int(currentRadius))px"
        }
        
        // Update the corner radius
        if let customView = webcamWindow?.contentView as? CustomView {
            customView.layer?.cornerRadius = currentRadius
        }
        if let previewLayer = windowController?.previewLayer {
            previewLayer.cornerRadius = currentRadius
        }
    }
    
    @objc private func toggleWebcam() {
        if webcamWindow == nil {
            // Create and configure the window
            let window = CustomWindow(
                contentRect: NSRect(x: 0, y: 0, width: 250, height: 250),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            
            // Create the window controller
            let controller = WebcamWindowController(window: window)
            controller.loadWindow()
            controller.showWindow(nil)
            
            // Set initial corner radius
            if let previewLayer = controller.previewLayer {
                previewLayer.cornerRadius = currentRadius
            }
            if let customView = window.contentView as? CustomView {
                customView.layer?.cornerRadius = currentRadius
            }
            
            // Store references
            windowController = controller
            webcamWindow = window
            
            // Position the window
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            webcamWindow?.orderOut(nil)
            webcamWindow = nil
            windowController = nil
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// Main entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }
}
