
import MapboxNavigationNative

struct CacheHandlerFactory {
    
    private static var key: (TilesConfig, ConfigHandle, HistoryRecorderHandle?)? = nil
    private static var cachedHandle: CacheHandle!
    private static let lock = NSLock()
    
    static func getHandler(for tilesConfig: TilesConfig,
                           config: ConfigHandle,
                           historyRecorder: HistoryRecorderHandle?) -> CacheHandle {
        lock.lock(); defer {
            lock.unlock()
        }
        
        if key == nil || key! != (tilesConfig, config, historyRecorder) {
            cachedHandle = CacheFactory.build(for: tilesConfig,
                                              config: config,
                                              historyRecorder: historyRecorder)
            key = (tilesConfig, config, historyRecorder)
        }
        return cachedHandle
    }
}
