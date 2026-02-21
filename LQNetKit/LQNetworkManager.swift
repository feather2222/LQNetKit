// LQNetworkManager.swift
// 主网络请求管理器
import Foundation
import Network

public class LQNetworkManager {
    // MARK: - 链路追踪
    public static var enableTraceId: Bool = false
    public static var traceIdGenerator: (() -> String)? = { UUID().uuidString }
    public static var traceIdHeaderKey: String = "X-Trace-Id"
    public static var enableTiming: Bool = false
    public static var onRequestTiming: ((URLRequest, TimeInterval) -> Void)?
    
    /// 当前网络状态
    public internal(set) var currentNetworkStatus: NetworkStatus = .other
    
    /// 网络状态变更回调
    public var onNetworkStatusChanged: ((NetworkStatus) -> Void)?
    
    // MARK: - 拦截器
    public typealias RequestInterceptor = (inout URLRequest) -> Void
    
    /// 局部拦截器
    public var interceptors: [RequestInterceptor] = []
    /// 全局请求拦截器链
    public static var globalRequestInterceptors: [RequestInterceptor] = []
    /// 全局响应拦截器链
    public static var globalResponseMiddlewares: [ResponseMiddleware] = []
    
    // MARK: - URLSession/初始化/单例
    public static let shared = LQNetworkManager()
    
    private let session: URLSession
    
    public var defaultTimeout: TimeInterval = 30
    
    // MARK: - 下载断点续传与进度流式
    private var downloadResumeData: [URL: Data] = [:]
    
    // 上传断点续传（预留接口，需服务端支持）
    // public func resumeUpload(...) { ... }
    // MARK: - Mock/Stub 支持
    public typealias MockHandler = (URLRequest) -> (Data?, URLResponse?, Error?)?
    
    private var mockHandlers: [MockHandler] = []
    public var enableMock: Bool = false
    
    // MARK: - 自定义错误映射
    public typealias ErrorMapper = (Data, URLResponse?) -> Error?
    
    private var errorMappers: [ErrorMapper] = []
    
    // MARK: - 响应处理链（中间件）
    public typealias ResponseMiddleware = (Data, URLResponse?) -> Data
    
    private var responseMiddlewares: [ResponseMiddleware] = []
    
    // MARK: - 请求队列与并发控制
    public enum RequestPriority: Int {
        case low = 0, normal = 1, high = 2
    }
    
    private var requestQueue: [(priority: RequestPriority, task: () -> Void)] = []
    private var activeRequests: Int = 0
    public var maxConcurrentRequests: Int = 4
    
    // MARK: - 上传/下载进度回调
    private var uploadProgressHandlers: [URLSessionTask: (Double) -> Void] = [:]
    
    private var downloadProgressHandlers: [URLSessionTask: (Double) -> Void] = [:]
    
    // MARK: - 网络状态监听与断网自动重试
    private var monitor: NWPathMonitor?
    
    var isNetworkAvailable: Bool = true
    
    var pendingRequests: [() -> Void] = []
    
    /// URLSessionTaskDelegate 进度回调实现
    private lazy var progressDelegate: URLSessionTaskDelegate = ProgressDelegate(manager: self)
    
    // MARK: - 本地缓存支持
    private var cache: [String: (data: Data, etag: String?, lastModified: String?)] = [:]
    
    /// 最近一次 HTTP 响应
    private var lastHTTPURLResponse: HTTPURLResponse?
    
    /// 是否启用日志打印
    public var enableLogging: Bool = false
    
    public var retryPolicy = RetryPolicy()
    
    // MARK: - 网络状态类型
    public enum NetworkStatus: Equatable {
        case wifi
        case cellular
        case unavailable
        case other
    }
    
    private class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        
        weak var manager: LQNetworkManager?
        
        init(manager: LQNetworkManager) { self.manager = manager }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard let handler = manager?.uploadProgressHandlers[task], totalBytesExpectedToSend > 0 else { return }
            let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            handler(progress)
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let handler = manager?.downloadProgressHandlers[downloadTask], totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            handler(progress)
        }
    }
    
    public init(session: URLSession = .shared) {
        self.session = session
        setupNetworkMonitor()
    }
    
    private func setupNetworkMonitor() {
        monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.lqnetkit.network.monitor")
        monitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let oldStatus = self.currentNetworkStatus
            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi) {
                    self.currentNetworkStatus = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.currentNetworkStatus = .cellular
                } else {
                    self.currentNetworkStatus = .other
                }
                self.isNetworkAvailable = true
                // 网络恢复，自动重试挂起请求
                if !self.pendingRequests.isEmpty {
                    let requests = self.pendingRequests
                    self.pendingRequests.removeAll()
                    requests.forEach { $0() }
                }
            } else {
                self.currentNetworkStatus = .unavailable
                self.isNetworkAvailable = false
            }
            if oldStatus != self.currentNetworkStatus {
                DispatchQueue.main.async {
                    self.onNetworkStatusChanged?(self.currentNetworkStatus)
                }
            }
        }
        monitor?.start(queue: queue)
    }
    
    // MARK: - 上传文件（支持进度回调）
    /// 多文件上传支持
    public func uploadWithProgress(url: URL, files: [(fileURL: URL, fieldName: String, fileName: String?, mimeType: String)], headers: [String: String]? = nil, parameters: [String: Any]? = nil, progress: ((Double) -> Void)? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        var body = Data()
        if let parameters = parameters {
            for (key, value) in parameters {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
        }
        for file in files {
            let uploadFileName = file.fileName ?? file.fileURL.lastPathComponent
            if let fileData = try? Data(contentsOf: file.fileURL) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(uploadFileName)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: \(file.mimeType)\r\n\r\n".data(using: .utf8)!)
                body.append(fileData)
                body.append("\r\n".data(using: .utf8)!)
            }
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        // 链路追踪 traceId 注入
        if LQNetworkManager.enableTraceId {
            let traceId = LQNetworkManager.traceIdGenerator?() ?? UUID().uuidString
            request.setValue(traceId, forHTTPHeaderField: LQNetworkManager.traceIdHeaderKey)
        }
        // 全局请求拦截器链
        for interceptor in LQNetworkManager.globalRequestInterceptors {
            interceptor(&request)
        }
        // 局部拦截器链
        for interceptor in interceptors {
            interceptor(&request)
        }
        let startTime = LQNetworkManager.enableTiming ? Date() : nil
        let task = session.uploadTask(with: request, from: body) { data, response, error in
            if let startTime = startTime, LQNetworkManager.enableTiming {
                let duration = Date().timeIntervalSince(startTime)
                LQNetworkManager.onRequestTiming?(request, duration)
            }
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(LQNetworkError.noData))
                return
            }
            completion(.success(data))
        }
        if let progress = progress {
            uploadProgressHandlers[task] = progress
        }
        task.resume()
    }
    
    // MARK: - 下载文件（支持进度回调）
    public func downloadWithProgress(url: URL, headers: [String: String]? = nil, progress: ((Double) -> Void)? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        for interceptor in interceptors {
            interceptor(&request)
        }
        let task = session.downloadTask(with: request) { tempURL, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let tempURL = tempURL else {
                completion(.failure(LQNetworkError.noData))
                return
            }
            completion(.success(tempURL))
        }
        if let progress = progress {
            downloadProgressHandlers[task] = progress
        }
        task.resume()
    }
    
    // MARK: - Mock/Stub 支持
    public func addMockHandler(_ handler: @escaping MockHandler) {
        mockHandlers.append(handler)
    }
    public func clearMockHandlers() {
        mockHandlers.removeAll()
    }
    
    // MARK: - 错误映射与中间件
    public func addErrorMapper(_ mapper: @escaping ErrorMapper) {
        errorMappers.append(mapper)
    }
    
    public func clearErrorMappers() {
        errorMappers.removeAll()
    }
    
    private func mapCustomError(data: Data, response: URLResponse?) -> Error? {
        for mapper in errorMappers {
            if let err = mapper(data, response) {
                return err
            }
        }
        return nil
    }
    
    public func addResponseMiddleware(_ middleware: @escaping ResponseMiddleware) {
        responseMiddlewares.append(middleware)
    }
    
    public func clearResponseMiddlewares() {
        responseMiddlewares.removeAll()
    }
    
    private func processResponseMiddlewares(data: Data, response: URLResponse?) -> Data {
        return responseMiddlewares.reduce(data) { result, middleware in
            middleware(result, response)
        }
    }
    
    // MARK: - 队列与并发控制
    func enqueueRequest(priority: RequestPriority = .normal, task: @escaping () -> Void) {
        requestQueue.append((priority, task))
        requestQueue.sort { $0.priority.rawValue > $1.priority.rawValue }
        processQueue()
    }
    
    private func processQueue() {
        while activeRequests < maxConcurrentRequests, !requestQueue.isEmpty {
            let item = requestQueue.removeFirst()
            activeRequests += 1
            item.task()
        }
    }
    
    private func requestDidFinish() {
        activeRequests = max(0, activeRequests - 1)
        processQueue()
    }
    
    // MARK: - 缓存
    public func clearCache() {
        cache.removeAll()
    }
    
    public static func custom(configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil, delegateQueue: OperationQueue? = nil) -> LQNetworkManager {
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        return LQNetworkManager(session: session)
    }
    
    /// 开始断点续传下载（回调版）
    public func resumeDownload(url: URL, headers: [String: String]? = nil, progress: ((Double) -> Void)? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        if let resumeData = downloadResumeData[url] {
            let task = session.downloadTask(withResumeData: resumeData) { tempURL, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let tempURL = tempURL else {
                    completion(.failure(LQNetworkError.noData))
                    return
                }
                completion(.success(tempURL))
            }
            if let progress = progress {
                downloadProgressHandlers[task] = progress
            }
            task.resume()
        } else {
            downloadWithProgress(url: url, headers: headers, progress: progress, completion: completion)
        }
    }
    
    /// 取消下载并保存断点数据
    public func cancelDownloadAndSaveResumeData(url: URL, task: URLSessionDownloadTask) {
        task.cancel { [weak self] resumeData in
            if let data = resumeData {
                self?.downloadResumeData[url] = data
            }
        }
    }
    
    /// 下载进度流式回调（AsyncSequence）
    public func downloadWithProgressStream(url: URL, headers: [String: String]? = nil) -> AsyncThrowingStream<(progress: Double, fileURL: URL?), Error> {
        AsyncThrowingStream { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            for interceptor in self.interceptors {
                interceptor(&request)
            }
            let task = self.session.downloadTask(with: request) { tempURL, response, error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let tempURL = tempURL else {
                    continuation.finish(throwing: LQNetworkError.noData)
                    return
                }
                continuation.yield((progress: 1.0, fileURL: tempURL))
                continuation.finish()
            }
            self.downloadProgressHandlers[task] = { progress in
                continuation.yield((progress: progress, fileURL: nil))
            }
            task.resume()
        }
    }
    
    // MARK: - 上传文件（回调版）
    /// 多文件上传支持
    public func upload(url: URL, files: [(fileURL: URL, fieldName: String, fileName: String?, mimeType: String)], headers: [String: String]? = nil, parameters: [String: Any]? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        var body = Data()
        if let parameters = parameters {
            for (key, value) in parameters {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
        }
        for file in files {
            let uploadFileName = file.fileName ?? file.fileURL.lastPathComponent
            if let fileData = try? Data(contentsOf: file.fileURL) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(uploadFileName)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: \(file.mimeType)\r\n\r\n".data(using: .utf8)!)
                body.append(fileData)
                body.append("\r\n".data(using: .utf8)!)
            }
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        for interceptor in interceptors {
            interceptor(&request)
        }
        // Mock 支持
        if enableMock {
            for handler in mockHandlers {
                if let (mockData, _, mockError) = handler(request) {
                    if let error = mockError {
                        completion(.failure(error))
                    } else if let data = mockData {
                        completion(.success(data))
                    } else {
                        completion(.failure(LQNetworkError.noData))
                    }
                    return
                }
            }
        }
        let startTime = LQNetworkManager.enableTiming ? Date() : nil
        let task = session.dataTask(with: request) { data, response, error in
            if let startTime = startTime, LQNetworkManager.enableTiming {
                let duration = Date().timeIntervalSince(startTime)
                LQNetworkManager.onRequestTiming?(request, duration)
            }
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(LQNetworkError.noData))
                return
            }
            completion(.success(data))
        }
        task.resume()
    }
    
    // MARK: - 流式响应（AsyncSequence）
    public func dataStream(url: URL, headers: [String: String]? = nil, chunkSize: Int = 4096) -> AsyncThrowingStream<Data, Error> {
        if enableMock {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            for handler in mockHandlers {
                if let (mockData, _, mockError) = handler(request) {
                    return AsyncThrowingStream { continuation in
                        if let error = mockError {
                            continuation.finish(throwing: error)
                            return
                        }
                        guard let data = mockData else {
                            continuation.finish(throwing: LQNetworkError.noData)
                            return
                        }
                        var offset = 0
                        while offset < data.count {
                            let end = min(offset + chunkSize, data.count)
                            let chunk = data.subdata(in: offset..<end)
                            continuation.yield(chunk)
                            offset = end
                        }
                        continuation.finish()
                    }
                }
            }
        }
        return AsyncThrowingStream { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            for interceptor in self.interceptors {
                interceptor(&request)
            }
            let task = self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let data = data else {
                    continuation.finish(throwing: LQNetworkError.noData)
                    return
                }
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    let chunk = data.subdata(in: offset..<end)
                    continuation.yield(chunk)
                    offset = end
                }
                continuation.finish()
            }
            task.resume()
        }
    }
    
    // MARK: - 通用 GET/POST/PUT/DELETE（回调版）
    public func get(url: URL, headers: [String: String]? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        request(url: url, method: "GET", headers: headers, body: nil, completion: completion)
    }
    
    public func post(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json, completion: @escaping (Result<Data, Error>) -> Void) {
        var headers = headers ?? [:]
        var bodyData = body
        if bodyData == nil, let parameters = parameters {
            let (data, contentType) = encodeBody(parameters: parameters, encoding: encoding)
            bodyData = data
            if let contentType = contentType {
                headers["Content-Type"] = contentType
            }
        }
        request(url: url, method: "POST", headers: headers, body: bodyData, completion: completion)
    }
    
    public func getWithCache(url: URL, headers: [String: String]? = nil, useCache: Bool = true, completion: @escaping (Result<Data, Error>) -> Void) {
        let cacheKey = url.absoluteString
        var headers = headers ?? [:]
        if useCache, let cached = cache[cacheKey] {
            if let etag = cached.etag {
                headers["If-None-Match"] = etag
            }
            if let lastModified = cached.lastModified {
                headers["If-Modified-Since"] = lastModified
            }
        }
        request(url: url, method: "GET", headers: headers, body: nil) { [weak self] result in
            switch result {
            case .success(let data):
                if let response = self?.lastHTTPURLResponse,
                   let statusCode = response.statusCode as Int?,
                   statusCode == 304,
                   let cached = self?.cache[cacheKey] {
                    completion(.success(cached.data))
                    return
                }
                let etag = (self?.lastHTTPURLResponse?.allHeaderFields["Etag"] as? String)
                let lastModified = (self?.lastHTTPURLResponse?.allHeaderFields["Last-Modified"] as? String)
                self?.cache[cacheKey] = (data, etag, lastModified)
                completion(.success(data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    public func download(url: URL, headers: [String: String]? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        for interceptor in interceptors {
            interceptor(&request)
        }
        let task = session.downloadTask(with: request) { tempURL, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let tempURL = tempURL else {
                completion(.failure(LQNetworkError.noData))
                return
            }
            completion(.success(tempURL))
        }
        task.resume()
    }
    
    // MARK: - 参数编码工具
    private func encodeBody(parameters: [String: Any]?, encoding: LQParameterEncoding) -> (Data?, String?) {
        guard let parameters = parameters else { return (nil, nil) }
        switch encoding {
        case .json:
            return (parameters.toJSONData(), "application/json")
        case .urlForm:
            return (parameters.toFormData(), "application/x-www-form-urlencoded")
        }
    }
    
    // MARK: - 通用请求实现
    private func request(url: URL, method: String, headers: [String: String]? = nil, body: Data? = nil, timeout: TimeInterval? = nil, retryCount: Int? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        let maxRetry = retryCount ?? retryPolicy.maxRetryCount
        func execute(tryCount: Int) {
            enqueueRequest(priority: .normal) { [weak self] in
                guard let self = self else { return }
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.timeoutInterval = timeout ?? self.defaultTimeout
                if let headers = headers {
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }
                request.httpBody = body
                for interceptor in self.interceptors {
                    interceptor(&request)
                }
                if self.enableMock {
                    for handler in self.mockHandlers {
                        if let (mockData, mockResponse, mockError) = handler(request) {
                            if let error = mockError {
                                completion(.failure(error))
                            } else if let data = mockData {
                                let processedData = self.processResponseMiddlewares(data: data, response: mockResponse)
                                if let customError = self.mapCustomError(data: processedData, response: mockResponse), tryCount == 0 {
                                    completion(.failure(customError))
                                } else {
                                    completion(.success(processedData))
                                }
                            } else {
                                completion(.failure(LQNetworkError.noData))
                            }
                            self.requestDidFinish()
                            return
                        }
                    }
                }
                if !self.isNetworkAvailable {
                    self.pendingRequests.append {
                        self.request(url: url, method: method, headers: headers, body: body, timeout: timeout, retryCount: maxRetry, completion: completion)
                    }
                    completion(.failure(LQNetworkError.custom(message: "网络不可用，已挂起请求")))
                    self.requestDidFinish()
                    return
                }
                let task = self.session.dataTask(with: request) { [weak self] data, response, error in
                    guard let self = self else { return }
                    if let httpResponse = response as? HTTPURLResponse {
                        self.lastHTTPURLResponse = httpResponse
                    }
                    if let error = error {
                        let shouldRetry = tryCount < maxRetry && (self.retryPolicy.shouldRetry?(error, tryCount) ?? true)
                        if shouldRetry {
                            let delay = min(self.retryPolicy.baseDelay * pow(2, Double(tryCount)), self.retryPolicy.maxDelay)
                            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                                execute(tryCount: tryCount + 1)
                            }
                            self.requestDidFinish()
                            return
                        }
                        completion(.failure(LQNetworkError.underlying(error)))
                        self.requestDidFinish()
                        return
                    }
                    guard let httpResponse = response as? HTTPURLResponse else {
                        completion(.failure(LQNetworkError.invalidResponse))
                        self.requestDidFinish()
                        return
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let error = LQNetworkError.httpError(statusCode: httpResponse.statusCode, data: data)
                        let shouldRetry = tryCount < maxRetry && (self.retryPolicy.shouldRetry?(error, tryCount) ?? false)
                        if shouldRetry {
                            let delay = min(self.retryPolicy.baseDelay * pow(2, Double(tryCount)), self.retryPolicy.maxDelay)
                            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                                execute(tryCount: tryCount + 1)
                            }
                            self.requestDidFinish()
                            return
                        }
                        completion(.failure(error))
                        self.requestDidFinish()
                        return
                    }
                    guard let data = data else {
                        completion(.failure(LQNetworkError.noData))
                        self.requestDidFinish()
                        return
                    }
                    // 全局响应中间件链
                    var processedData = data
                    for middleware in LQNetworkManager.globalResponseMiddlewares {
                        processedData = middleware(processedData, response)
                    }
                    // 局部响应中间件链
                    processedData = self.processResponseMiddlewares(data: processedData, response: response)
                    if let customError = self.mapCustomError(data: processedData, response: response), tryCount == 0 {
                        completion(.failure(customError))
                    } else {
                        completion(.success(processedData))
                    }
                    self.requestDidFinish()
                }
                task.resume()
            }
        }
        execute(tryCount: 0)
    }
}
