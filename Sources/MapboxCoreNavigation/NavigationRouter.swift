import Foundation
import MapboxDirections
import MapboxNavigationNative

public class NavigationRouter {
    
    public typealias RequestId = UInt64
    
    public struct RoutingRequest {
        public let id: RequestId
        
        // Intended retain cycle to prevent deallocating. `RoutingRequest` will be deleted once request completes.
        let router: NavigationRouter
        
        public func cancel() {
            router.finish(request: id)
        }
    }
    
    public enum RouterSource {
        case online
        case offline
        case hybrid
        
        var nativeSource: RouterType {
            switch self {
            case .online:
                return .online
            case .offline:
                return .onboard
            case .hybrid:
                return .hybrid
            }
        }
    }
    
    public private(set) var activeRequests: [RequestId : RoutingRequest] = [:]
    public private(set) var source: RouterSource
    private var router: RouterInterface
    private var settings: NavigationSettings
    
    public init(_ source: RouterSource = .hybrid, settings: NavigationSettings = .shared) {
        self.source = source
        self.settings = settings
        
        let factory = NativeHandlersFactory(tileStorePath: settings.tileStoreConfiguration.navigatorLocation.tileStoreURL?.path ?? "",
                                            credentials: settings.directions.credentials)
        self.router = MapboxNavigationNative.RouterFactory.build(for: source.nativeSource,
                                                                 cache: factory.cacheHandle,
                                                                 historyRecorder: factory.historyRecorder)
    }
    
    deinit {
        print(">>> dealloc")
    }
    
    fileprivate func finish(request id: RequestId) {
        router.cancelRequest(forToken: id)
        activeRequests[id] = nil
        print(">>> finished id: \(id)")
    }
    
    public func doRequest<ResponseType: Codable>(options: DirectionsOptions,
                                                 completion: @escaping (Result<ResponseType, DirectionsError>) -> Void) -> RequestId {
        let directionsUri = settings.directions.url(forCalculating: options).absoluteString
        var requestId: RequestId!
        requestId = router.getRouteForDirectionsUri(directionsUri) { [weak self] (result, _) in // mind exposing response origin?
            guard let self = self else { return }
            
            let json = result.value as? String
            let data = json?.data(using: .utf8)
            let decoder = JSONDecoder()
            decoder.userInfo = [.options: options,
                                .credentials: self.settings.directions.credentials]
            
            if let jsonData = data,
               let response = try? decoder.decode(ResponseType.self, from: jsonData) {
                DispatchQueue.main.async {
                    completion(.success(response))
                    self.finish(request: requestId)
                }
            } else {
                DispatchQueue.main.async {
                    completion(.failure(.unknown(response: nil,
                                                 underlying: result.error as? Error,
                                                 code: nil,
                                                 message: nil)))
                    self.finish(request: requestId)
                }
            }
        }
        activeRequests[requestId] = .init(id: requestId,
                                          router: self)
        print(">>> started id: \(requestId)")
        return requestId
    }
    
    @discardableResult public func requestRoutes(options: RouteOptions,
                                                 completionHandler: @escaping Directions.RouteCompletionHandler) -> RequestId {
        return doRequest(options: options) { [weak self] (result: Result<RouteResponse, DirectionsError>) in
            guard let self = self else { return }
            let session = (options: options as DirectionsOptions,
                           credentials: self.settings.directions.credentials)
            completionHandler(session, result)
        }
    }
    
    @discardableResult public func requestRoutes(options: MatchOptions,
                                                 completionHandler: @escaping Directions.MatchCompletionHandler) -> RequestId {
        return doRequest(options: options) { (result: Result<MapMatchingResponse, DirectionsError>) in
            let session = (options: options as DirectionsOptions,
                           credentials: self.settings.directions.credentials)
            completionHandler(session, result)
        }
    }
    
    @discardableResult public func refreshRoute(indexedRouteResponse: IndexedRouteResponse,
                                                fromLegAtIndex startLegIndex: UInt32 = 0,
                                                completionHandler: @escaping Directions.RouteRefreshCompletionHandler) -> RequestId {
        guard case let .route(routeOptions) = indexedRouteResponse.routeResponse.options,
              let route = indexedRouteResponse.selectedRoute,
              let responseIdentifier = indexedRouteResponse.routeResponse.identifier else {
            preconditionFailure("Invalid route data passed for refreshing.")
        }
        
        let encoder = JSONEncoder()
        encoder.userInfo[.options] = routeOptions
        
        let routeIndex = UInt32(indexedRouteResponse.routeIndex)
        
        guard let routeData = try? encoder.encode(route),
              let routeJSONString = String(data: routeData, encoding: .utf8) else {
            preconditionFailure("Could not serialize route data for refreshing.")
        }
        
        var requestId: RequestId!
        requestId = router.getRouteRefresh(for: RouteRefreshOptions(requestId: responseIdentifier,
                                                                    routeIndex: routeIndex,
                                                                    legIndex: startLegIndex),
                                           route: routeJSONString) { [weak self] result, _ in
            guard let self = self else { return }
            // change to route deserialization
            do {
                let json = result.value as? String
                guard let data = json?.data(using: .utf8) else {
                    DispatchQueue.main.async {
                        completionHandler(self.settings.directions.credentials, .failure(.noData))
                        self.finish(request: requestId)
                    }
                    return
                }
                let decoder = JSONDecoder()
                decoder.userInfo = [
                    .responseIdentifier: responseIdentifier,
                    .routeIndex: routeIndex,
                    .startLegIndex: startLegIndex,
                    .credentials: self.settings.directions.credentials,
                ]
                
                let result = try decoder.decode(RouteRefreshResponse.self, from: data)
                
                DispatchQueue.main.async {
                    completionHandler(self.settings.directions.credentials, .success(result))
                    self.finish(request: requestId)
                }
            } catch {
                DispatchQueue.main.async {
                    let bailError = DirectionsError(code: nil, message: nil, response: nil, underlyingError: error)
                    completionHandler(self.settings.directions.credentials, .failure(bailError))
                    self.finish(request: requestId)
                }
            }
        }
        activeRequests[requestId] = .init(id: requestId,
                                          router: self)
        print(">>> started refresh id: \(requestId)")
        return requestId
    }
}
