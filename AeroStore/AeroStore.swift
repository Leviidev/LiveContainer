import Foundation
import AppIntents

@available(iOS 17.0, *)
public struct AeroRefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false }
    
    public init() {}
    
    public func perform() async throws -> some IntentResult
    {
        AeroRefreshHandler.shared.progress = progress
        progress.totalUnitCount = 100
        try await AeroRefreshHandler.shared.startRefresh()
        return .result()
    }
}

@available(iOS 17.0, *)
public struct AeroRefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    public static let intentClassName = "AeroRefreshAllIntent"
    
    public static var title: LocalizedStringResource = "Refresh All Apps"
    public static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    public init() {}
    
    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    public func perform() async throws -> some IntentResult
    {
        AeroRefreshHandler.shared.progress = progress
        progress.totalUnitCount = 100
        try await AeroRefreshHandler.shared.startRefresh()
        return .result(dialog: "All apps have been refreshed.")
    }
}


class AeroRefreshHandler: NSObject, RefreshServer {
    var c: UnsafeContinuation<(), any Error>? = nil
    var launchContinuation: UnsafeContinuation<(), any Error>? = nil
    var progress: Progress? = nil
    var listener: NSXPCListener? = nil
    var aeroStorePid: Int32 = 0
    var client: RefreshClient? = nil
    var ext: NSExtension? = nil
    
    private static var _shared: AeroRefreshHandler? = nil
    static var shared: AeroRefreshHandler {
        get {
            if let _shared {
                return _shared
            } else {
                _shared = AeroRefreshHandler()
                return _shared!
            }
        }
    }
    
    
    func startRefresh() async throws {
        if aeroStorePid <= 0 || getpgid(aeroStorePid) <= 0, let c {
            c.resume(throwing: NSError(domain: "AeroStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in AeroStore quit unexpectedly"]))
            self.c = nil
        }
        
        if c != nil {
            throw NSError(domain: "AeroStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another refresh task is in progress."])
        }
        
        if listener == nil {
            guard let listener = startAnonymousListener(self) else {
                return
            }
            self.listener = listener
        }
        guard let listener = self.listener else {
            return
        }

        if (aeroStorePid <= 0 || getpgid(aeroStorePid) <= 0) && launchContinuation == nil {
            let lcHome = String(cString:getenv("LC_HOME_PATH"))
            let aeroStoreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/AeroStore")
            let bookmarkData = bookmarkForURL(aeroStoreHomeURL)!

            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinAeroStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                  let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw NSError(domain: "AeroStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to locate LiveProcess bundle. Reinstall LiveContainer+AeroStore with LiveProcess installed. Keep app extensions when sideloading."])
            }
            
            var ext : NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw NSError(domain: "AeroStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start extension \(error). Reinstall LiveContainer+AeroStore with LiveProcess installed. Keep app extensions when sideloading."])
            }
            guard let ext else {
                return
            }
            self.ext = ext
            
            ext.setRequestInterruptionBlock { uuid in
                self.c?.resume(throwing: NSError(domain: "AeroStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in AeroStore quit unexpectedly"]))
                self.c = nil
                self.aeroStorePid = 0
                self.launchContinuation = nil
            }
            
            let uuid = await ext.beginRequest(withInputItems: [extensionItem])
            aeroStorePid = ext.pid(forRequestIdentifier: uuid)
            
            try await withUnsafeThrowingContinuation { c in
                self.launchContinuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let c = self.launchContinuation {
                        c.resume(throwing: NSError(domain: "AeroStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in AeroStore failed to start in reasonable time"]))
                        self.launchContinuation = nil
                        ext._kill(9)
                    }
                }
            }
        }
        self.client?.refreshAllApps()
        
        try await withUnsafeThrowingContinuation { c in
            self.c = c
        }
        
    }
    
    func updateProgress(_ value: Double) {
        progress?.completedUnitCount = Int64(value*100)
    }
    
    func finish(_ error: String?) {
        if let error {
            c?.resume(throwing: NSError(domain: "AeroStore", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
            c = nil
        } else {
            c?.resume()
            c = nil
        }
    }
    
    func onConnection(_ connection: NSXPCConnection!) {
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        client = connection.remoteObjectProxy as? RefreshClient
    }
    
    func finishedLaunching() {
        launchContinuation?.resume()
        launchContinuation = nil
    }
    
}
