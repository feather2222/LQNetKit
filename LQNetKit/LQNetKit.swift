//
//  LQNetKit.swift
//  LQNetKit
//
//  Created by xiangduojia on 2026/2/20.
//

import Foundation
import Network

/// 请求参数编码类型
public enum LQParameterEncoding {
    case json
    case urlForm
}

/// 网络请求自定义错误类型
public enum LQNetworkError: Error {
    case invalidResponse
    case httpError(statusCode: Int, data: Data?)
    case noData
    case underlying(Error)
    case custom(message: String)
    
    public var localizedDescription: String {
        switch self {
        case .invalidResponse:
            return "无效的响应"
        case .httpError(let code, _):
            return "HTTP 错误，状态码：\(code)"
        case .noData:
            return "无数据返回"
        case .underlying(let error):
            return error.localizedDescription
        case .custom(let message):
            return message
        }
    }
}

/// 通用网络请求管理器
public class LQNetworkManager {
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
    
    private class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
        // 必须实现的协议方法，否则编译报错
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // 可选：可在此处理下载完成后的文件
        }
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
    
    /// 上传文件（支持进度回调）
    public func uploadWithProgress(url: URL, fileURL: URL, fieldName: String = "file", fileName: String? = nil, mimeType: String = "application/octet-stream", headers: [String: String]? = nil, parameters: [String: Any]? = nil, progress: ((Double) -> Void)? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
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
        let uploadFileName = fileName ?? fileURL.lastPathComponent
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(uploadFileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        for interceptor in interceptors {
            interceptor(&request)
        }
        let task = session.uploadTask(with: request, from: body) { data, response, error in
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
    
    /// 下载文件（支持进度回调）
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
    
    /// 清除所有缓存
    public func clearCache() {
        cache.removeAll()
    }
    
    /// GET 请求（带缓存）
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
    
    /// 日志打印方法
    private func logRequest(_ request: URLRequest) {
        guard enableLogging else { return }
        print("[LQNetKit] 请求: \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            print("[LQNetKit] 请求头: \(headers)")
        }
        if let body = request.httpBody, let bodyStr = String(data: body, encoding: .utf8) {
            print("[LQNetKit] 请求体: \(bodyStr)")
        }
    }
    
    private func logResponse(_ response: URLResponse?, data: Data?) {
        guard enableLogging else { return }
        if let httpResponse = response as? HTTPURLResponse {
            print("[LQNetKit] 响应: \(httpResponse.statusCode) \(httpResponse.url?.absoluteString ?? "")")
            print("[LQNetKit] 响应头: \(httpResponse.allHeaderFields)")
        }
        if let data = data, let str = String(data: data, encoding: .utf8) {
            print("[LQNetKit] 响应体: \(str)")
        }
    }
    
    // MARK: - AsyncSequence 流式响应
    /// 以流式方式获取响应数据（适合大文件下载、SSE等场景）
    public func dataStream(url: URL, headers: [String: String]? = nil, chunkSize: Int = 4096) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            // 全局拦截器处理
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
                // 按块分发数据
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
    public static let shared = LQNetworkManager()
    private let session: URLSession
    
    /// 默认超时时间（秒）
    public var defaultTimeout: TimeInterval = 30
    /// 全局请求拦截器类型
    public typealias RequestInterceptor = (inout URLRequest) -> Void
    /// 全局请求拦截器数组
    public var interceptors: [RequestInterceptor] = []
    /// 通用 JSON 解码（同步回调版）
    public func getDecodable<T: Decodable>(url: URL, headers: [String: String]? = nil, completion: @escaping (Result<T, Error>) -> Void) {
        get(url: url, headers: headers) { result in
            switch result {
            case .success(let data):
                do {
                    let model = try JSONDecoder().decode(T.self, from: data)
                    completion(.success(model))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// 通用 JSON 解码（async/await 版）
    public func getDecodable<T: Decodable>(url: URL, headers: [String: String]? = nil) async throws -> T {
        let data = try await get(url: url, headers: headers)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    /// 通用 JSON 解码（POST，async/await 版）
    public func postDecodable<T: Decodable>(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json) async throws -> T {
        let data = try await post(url: url, headers: headers, body: body, parameters: parameters, encoding: encoding)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    /// 通用 JSON 解码（POST，同步回调版）
    public func postDecodable<T: Decodable>(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json, completion: @escaping (Result<T, Error>) -> Void) {
        post(url: url, headers: headers, body: body, parameters: parameters, encoding: encoding) { result in
            switch result {
            case .success(let data):
                do {
                    let model = try JSONDecoder().decode(T.self, from: data)
                    completion(.success(model))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// 支持自定义 URLSession 配置的初始化
    public init(session: URLSession = .shared) {
        self.session = session
    }
    
    /// 通过自定义配置创建 manager
    public static func custom(configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil, delegateQueue: OperationQueue? = nil) -> LQNetworkManager {
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        return LQNetworkManager(session: session)
    }
    
    /// 参数编码工具（JSON、Form）
    private func encodeBody(parameters: [String: Any]?, encoding: LQParameterEncoding) -> (Data?, String?) {
        guard let parameters = parameters else { return (nil, nil) }
        switch encoding {
        case .json:
            return (parameters.toJSONData(), "application/json")
        case .urlForm:
            return (parameters.toFormData(), "application/x-www-form-urlencoded")
        }
    }
    
    /// 发送通用请求
    private func request(url: URL, method: String, headers: [String: String]? = nil, body: Data? = nil, timeout: TimeInterval? = nil, retryCount: Int = 0, completion: @escaping (Result<Data, Error>) -> Void) {
        enqueueRequest(priority: .normal) { [weak self] in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout ?? self?.defaultTimeout ?? 30
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            request.httpBody = body
            // 全局拦截器处理
            for interceptor in self?.interceptors ?? [] {
                interceptor(&request)
            }
            // Mock/Stub 支持
            if self?.enableMock == true {
                for handler in self?.mockHandlers ?? [] {
                    if let (mockData, mockResponse, mockError) = handler(request) {
                        if let error = mockError {
                            completion(.failure(error))
                        } else if let data = mockData {
                            let processedData = self?.processResponseMiddlewares(data: data, response: mockResponse)
                            if let customError = self?.mapCustomError(data: processedData ?? data, response: mockResponse), retryCount == 0 {
                                completion(.failure(customError))
                            } else {
                                completion(.success(processedData ?? data))
                            }
                        } else {
                            completion(.failure(LQNetworkError.noData))
                        }
                        self?.requestDidFinish()
                        return
                    }
                }
            }
            // 网络不可用时挂起请求
            if self?.isNetworkAvailable == false {
                self?.pendingRequests.append {
                    self?.request(url: url, method: method, headers: headers, body: body, timeout: timeout, retryCount: retryCount, completion: completion)
                }
                completion(.failure(LQNetworkError.custom(message: "网络不可用，已挂起请求")))
                self?.requestDidFinish()
                return
            }
            let task = self?.session.dataTask(with: request) { [weak self] data, response, error in
                if let httpResponse = response as? HTTPURLResponse {
                    self?.lastHTTPURLResponse = httpResponse
                }
                if let error = error {
                    if retryCount > 0 {
                        self?.request(url: url, method: method, headers: headers, body: body, timeout: timeout, retryCount: retryCount - 1, completion: completion)
                        self?.requestDidFinish()
                        return
                    }
                    completion(.failure(LQNetworkError.underlying(error)))
                    self?.requestDidFinish()
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(LQNetworkError.invalidResponse))
                    self?.requestDidFinish()
                    return
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    if retryCount > 0 {
                        self?.request(url: url, method: method, headers: headers, body: body, timeout: timeout, retryCount: retryCount - 1, completion: completion)
                        self?.requestDidFinish()
                        return
                    }
                    completion(.failure(LQNetworkError.httpError(statusCode: httpResponse.statusCode, data: data)))
                    self?.requestDidFinish()
                    return
                }
                self?.logRequest(request)
                guard let data = data else {
                    completion(.failure(LQNetworkError.noData))
                    self?.requestDidFinish()
                    return
                }
                // 响应处理链：统一解密、解压、预处理
                let processedData = self?.processResponseMiddlewares(data: data, response: response)
                // 自定义错误映射
                if let customError = self?.mapCustomError(data: processedData ?? data, response: response), retryCount == 0 {
                    completion(.failure(customError))
                } else {
                    completion(.success(processedData ?? data))
                }
                self?.requestDidFinish()
            }
            task?.resume()
        }
    }
    
    // MARK: - Async/Await 版本
    
    /// 通用 async/await 请求
    private func requestAsync(url: URL, method: String, headers: [String: String]? = nil, body: Data? = nil, timeout: TimeInterval? = nil, retryCount: Int = 0) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? defaultTimeout
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        request.httpBody = body
        // 全局拦截器处理
        for interceptor in interceptors {
            interceptor(&request)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LQNetworkError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                if retryCount > 0 {
                    return try await requestAsync(url: url, method: method, headers: headers, body: body, timeout: timeout, retryCount: retryCount - 1)
                }
                throw LQNetworkError.httpError(statusCode: httpResponse.statusCode, data: data)
            }
            return data
        } catch {
            if retryCount > 0 {
                return try await requestAsync(url: url, method: method, headers: headers, body: body, timeout: timeout, retryCount: retryCount - 1)
            }
            throw LQNetworkError.underlying(error)
        }
    }
    
    /// async/await GET
    public func get(url: URL, headers: [String: String]? = nil) async throws -> Data {
        try await requestAsync(url: url, method: "GET", headers: headers, body: nil)
    }
    
    /// async/await POST
    public func post(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json) async throws -> Data {
        var headers = headers ?? [:]
        var bodyData = body
        if bodyData == nil, let parameters = parameters {
            let (data, contentType) = encodeBody(parameters: parameters, encoding: encoding)
            bodyData = data
            if let contentType = contentType {
                headers["Content-Type"] = contentType
            }
        }
        return try await requestAsync(url: url, method: "POST", headers: headers, body: bodyData)
    }
    
    /// async/await PUT
    public func put(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json) async throws -> Data {
        var headers = headers ?? [:]
        var bodyData = body
        if bodyData == nil, let parameters = parameters {
            let (data, contentType) = encodeBody(parameters: parameters, encoding: encoding)
            bodyData = data
            if let contentType = contentType {
                headers["Content-Type"] = contentType
            }
        }
        return try await requestAsync(url: url, method: "PUT", headers: headers, body: bodyData)
    }
    
    /// async/await DELETE
    public func delete(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json) async throws -> Data {
        var headers = headers ?? [:]
        var bodyData = body
        if bodyData == nil, let parameters = parameters {
            let (data, contentType) = encodeBody(parameters: parameters, encoding: encoding)
            bodyData = data
            if let contentType = contentType {
                headers["Content-Type"] = contentType
            }
        }
        return try await requestAsync(url: url, method: "DELETE", headers: headers, body: bodyData)
    }
    
    /// 发送 POST 请求（支持参数自动编码）
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
    
    /// 发送 PUT 请求（支持参数自动编码）
    public func put(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json, completion: @escaping (Result<Data, Error>) -> Void) {
        var headers = headers ?? [:]
        var bodyData = body
        if bodyData == nil, let parameters = parameters {
            let (data, contentType) = encodeBody(parameters: parameters, encoding: encoding)
            bodyData = data
            if let contentType = contentType {
                headers["Content-Type"] = contentType
            }
        }
        request(url: url, method: "PUT", headers: headers, body: bodyData, completion: completion)
    }
    
    /// 发送 DELETE 请求（支持参数自动编码）
    public func delete(url: URL, headers: [String: String]? = nil, body: Data? = nil, parameters: [String: Any]? = nil, encoding: LQParameterEncoding = .json, completion: @escaping (Result<Data, Error>) -> Void) {
        var headers = headers ?? [:]
        var bodyData = body
        if bodyData == nil, let parameters = parameters {
            let (data, contentType) = encodeBody(parameters: parameters, encoding: encoding)
            bodyData = data
            if let contentType = contentType {
                headers["Content-Type"] = contentType
            }
        }
        request(url: url, method: "DELETE", headers: headers, body: bodyData, completion: completion)
    }
    
    /// 发送 GET 请求
    /// - Parameters:
    ///   - url: 请求地址
    ///   - headers: 请求头
    ///   - completion: 完成回调，返回 Data 或 Error
    public func get(url: URL, headers: [String: String]? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        request(url: url, method: "GET", headers: headers, body: nil, completion: completion)
    }
    
    // MARK: - 文件上传
    /// 上传文件（multipart/form-data，回调版）
    public func upload(url: URL, fileURL: URL, fieldName: String = "file", fileName: String? = nil, mimeType: String = "application/octet-stream", headers: [String: String]? = nil, parameters: [String: Any]? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
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
        // 附加参数
        if let parameters = parameters {
            for (key, value) in parameters {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
        }
        // 附加文件
        let uploadFileName = fileName ?? fileURL.lastPathComponent
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(uploadFileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        // 全局拦截器处理
        for interceptor in interceptors {
            interceptor(&request)
        }
        let task = session.dataTask(with: request) { data, response, error in
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
    
    /// 上传文件（async/await 版）
    public func upload(url: URL, fileURL: URL, fieldName: String = "file", fileName: String? = nil, mimeType: String = "application/octet-stream", headers: [String: String]? = nil, parameters: [String: Any]? = nil) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            self.upload(url: url, fileURL: fileURL, fieldName: fieldName, fileName: fileName, mimeType: mimeType, headers: headers, parameters: parameters, completion: { result in
                continuation.resume(with: result)
            })
        }
    }
    
    // MARK: - 文件下载
    /// 下载文件到本地（回调版）
    public func download(url: URL, headers: [String: String]? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        // 全局拦截器处理
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
    
    /// 下载文件到本地（async/await 版）
    public func download(url: URL, headers: [String: String]? = nil) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            self.download(url: url, headers: headers, completion: { result in
                continuation.resume(with: result)
            })
        }
    }
    
    /// 启动网络状态监听
    public func startNetworkMonitor() {
        if monitor != nil { return }
        monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "LQNetKit.NetworkMonitor")
        monitor?.pathUpdateHandler = { [weak self] (path: NWPath) in
            self?.isNetworkAvailable = path.status == NWPath.Status.satisfied
            if self?.isNetworkAvailable == true {
                // 网络恢复，重试所有挂起请求
                let requests = self?.pendingRequests ?? []
                self?.pendingRequests.removeAll()
                for req in requests { req() }
            }
        }
        monitor?.start(queue: queue)
    }
    
    /// 停止网络状态监听
    public func stopNetworkMonitor() {
        monitor?.cancel()
        monitor = nil
    }
    
    /// 添加错误映射器
    public func addErrorMapper(_ mapper: @escaping ErrorMapper) {
        errorMappers.append(mapper)
    }
    
    /// 清空错误映射器
    public func clearErrorMappers() {
        errorMappers.removeAll()
    }
    
    /// 执行错误映射链
    private func mapCustomError(data: Data, response: URLResponse?) -> Error? {
        for mapper in errorMappers {
            if let err = mapper(data, response) {
                return err
            }
        }
        return nil
    }
    
    /// 添加响应中间件
    public func addResponseMiddleware(_ middleware: @escaping ResponseMiddleware) {
        responseMiddlewares.append(middleware)
    }
    
    /// 清空响应中间件
    public func clearResponseMiddlewares() {
        responseMiddlewares.removeAll()
    }
    
    /// 执行响应处理链
    private func processResponseMiddlewares(data: Data, response: URLResponse?) -> Data {
        return responseMiddlewares.reduce(data) { result, middleware in
            middleware(result, response)
        }
    }
    
    /// 入队请求
    func enqueueRequest(priority: RequestPriority = .normal, task: @escaping () -> Void) {
        requestQueue.append((priority, task))
        requestQueue.sort { $0.priority.rawValue > $1.priority.rawValue }
        processQueue()
    }
    
    /// 处理队列
    private func processQueue() {
        while activeRequests < maxConcurrentRequests, !requestQueue.isEmpty {
            let item = requestQueue.removeFirst()
            activeRequests += 1
            item.task()
        }
    }
    
    /// 请求完成后调用
    private func requestDidFinish() {
        activeRequests = max(0, activeRequests - 1)
        processQueue()
    }
    
    /// 添加 mock handler
    public func addMockHandler(_ handler: @escaping MockHandler) {
        mockHandlers.append(handler)
    }
    
    /// 清空 mock handler
    public func clearMockHandlers() {
        mockHandlers.removeAll()
    }
}

extension Dictionary where Key == String, Value == Any {
    /// 转为 JSON Data
    func toJSONData() -> Data? {
        try? JSONSerialization.data(withJSONObject: self, options: [])
    }
    /// 转为 x-www-form-urlencoded Data
    func toFormData() -> Data? {
        let query = self.map { key, value in
            "\(key)=\(String(describing: value))"
        }.joined(separator: "&")
        return query.data(using: .utf8)
    }
}
