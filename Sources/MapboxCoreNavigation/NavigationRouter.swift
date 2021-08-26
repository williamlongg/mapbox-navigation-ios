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
    private let requestsLock = NSLock()
    public let source: RouterSource
    private let router: RouterInterface
    private let settings: NavigationSettings
    
    public init(_ source: RouterSource = .hybrid, settings: NavigationSettings = .shared) {
        self.source = source
        self.settings = settings
        
        let factory = NativeHandlersFactory(tileStorePath: settings.tileStoreConfiguration.navigatorLocation.tileStoreURL?.path ?? "",
                                            credentials: settings.directions.credentials)
        self.router = MapboxNavigationNative.RouterFactory.build(for: source.nativeSource,
                                                                 cache: factory.cacheHandle,
                                                                 historyRecorder: factory.historyRecorder)
    }
    
    fileprivate func finish(request id: RequestId) {
        requestsLock.lock(); defer {
            requestsLock.unlock()
        }
        
        router.cancelRequest(forToken: id)
        activeRequests[id] = nil
    }
    
    func complete(requestId: RequestId, with result: @escaping () -> Void) {
        DispatchQueue.main.async {
            result()
            self.finish(request: requestId)
        }
    }

    
    public func doRequest<ResponseType: Codable>(options: DirectionsOptions,
                                                 completion: @escaping (Result<ResponseType, DirectionsError>) -> Void) -> RequestId {
        let directionsUri = settings.directions.url(forCalculating: options).absoluteString
        var requestId: RequestId!
        requestsLock.lock()
        requestId = router.getRouteForDirectionsUri(directionsUri) { [weak self] (result, _) in // mind exposing response origin?
            guard let self = self else { return }
            
            let json = result.value as? String
            let data = json?.data(using: .utf8)
            let decoder = JSONDecoder()
            decoder.userInfo = [.options: options,
                                .credentials: self.settings.directions.credentials]
            
            if let jsonData = data,
               let response = try? decoder.decode(ResponseType.self, from: jsonData) {
                self.complete(requestId: requestId) {
                    completion(.success(response))
                }
            } else {
                self.complete(requestId: requestId) {
                    completion(.failure(.unknown(response: nil,
                                                 underlying: result.error as? Error,
                                                 code: nil,
                                                 message: nil)))
                }
            }
        }
        activeRequests[requestId] = .init(id: requestId,
                                          router: self)
        requestsLock.unlock()
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
                                                completionHandler: @escaping Directions.RouteCompletionHandler) -> RequestId {
        guard case let .route(routeOptions) = indexedRouteResponse.routeResponse.options,
              let responseIdentifier = indexedRouteResponse.routeResponse.identifier else {
            preconditionFailure("Invalid route data passed for refreshing.")
        }
        
        let encoder = JSONEncoder()
        encoder.userInfo[.options] = routeOptions
        
        let routeIndex = UInt32(indexedRouteResponse.routeIndex)
        
        guard
            let routeData = try? encoder.encode(indexedRouteResponse.routeResponse),
              let routeJSONString = String(data: routeData, encoding: .utf8) else {
            preconditionFailure("Could not serialize route data for refreshing.")
        }
        
        var requestId: RequestId!
        let refreshOptions = RouteRefreshOptions(requestId: responseIdentifier,
                                                 routeIndex: routeIndex,
                                                 legIndex: startLegIndex,
                                                 routingProfile: routeOptions.profileIdentifier.nativeProfile)
        requestsLock.lock()
        requestId = router.getRouteRefresh(for: refreshOptions,
                                           route: routeJSONString) { [weak self] result, _ in
            guard let self = self else { return }
            // change to route deserialization
            do {
                let json = result.value as? String
                guard let data = json?.data(using: .utf8) else {
                    self.complete(requestId: requestId) {
                        let session = (options: routeOptions as DirectionsOptions,
                                       credentials: self.settings.directions.credentials)
                        completionHandler(session, .failure(.noData))
                    }
                    return
                }
                let decoder = JSONDecoder()
                decoder.userInfo = [.options: routeOptions,
                                    .credentials: self.settings.directions.credentials]
                
                let result = try decoder.decode(RouteResponse.self, from: data)
                
                self.complete(requestId: requestId) {
                    let session = (options: routeOptions as DirectionsOptions,
                                   credentials: self.settings.directions.credentials)
                    completionHandler(session, .success(result))
                }
            } catch {
                self.complete(requestId: requestId) {
                    let session = (options: routeOptions as DirectionsOptions,
                                   credentials: self.settings.directions.credentials)
                    let bailError = DirectionsError(code: nil, message: nil, response: nil, underlyingError: error)
                    completionHandler(session, .failure(bailError))
                }
            }
        }
        activeRequests[requestId] = .init(id: requestId,
                                          router: self)
        requestsLock.unlock()
        return requestId
    }
}

extension DirectionsProfileIdentifier {
    var nativeProfile: RoutingProfile {
        switch self {
        case .automobile:
            return .driving
        case .automobileAvoidingTraffic:
            return .drivingTraffic
        case .cycling:
            return .cycling
        case .walking:
            return .walking
        default:
            return .driving
        }
    }
}
