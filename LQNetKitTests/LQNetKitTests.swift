//
//  LQNetKitTests.swift
//  LQNetKitTests
//
//  Created by xiangduojia on 2026/2/20.
//

import XCTest
@testable import LQNetKit

final class LQNetKitTests: XCTestCase {
    
    // GET 请求测试
    func testGETRequest() throws {
        let expectation = self.expectation(description: "GET Request should succeed")
        guard let url = URL(string: "https://httpbin.org/get") else {
            XCTFail("URL 构造失败")
            return
        }
        LQNetworkManager.shared.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertFalse(data.isEmpty, "返回数据不应为空")
            case .failure(let error):
                XCTFail("请求失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 10, handler: nil)
    }
    
    // POST 请求测试（参数自动编码）
    func testPOSTRequest() throws {
        let expectation = self.expectation(description: "POST Request should succeed")
        guard let url = URL(string: "https://httpbin.org/post") else {
            XCTFail("URL 构造失败")
            return
        }
        let params = ["foo": "bar"]
        LQNetworkManager.shared.post(url: url, parameters: params) { result in
            switch result {
            case .success(let data):
                XCTAssertFalse(data.isEmpty)
            case .failure(let error):
                XCTFail("POST失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 10, handler: nil)
    }
    
    // 缓存测试（Etag/Last-Modified）
    func testCache() throws {
        let expectation = self.expectation(description: "Cache should work")
        guard let url = URL(string: "https://httpbin.org/cache") else {
            XCTFail("URL 构造失败")
            return
        }
        LQNetworkManager.shared.getWithCache(url: url, useCache: true) { result in
            switch result {
            case .success(let data):
                XCTAssertFalse(data.isEmpty)
            case .failure(let error):
                XCTFail("缓存失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 10, handler: nil)
    }
    
    // Mock/Stub 测试
    func testMockStub() throws {
        let expectation = self.expectation(description: "Mock should return stub data")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/data" {
                let mockData = "mocked".data(using: .utf8)
                return (mockData, nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/data") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "mocked")
            case .failure(let error):
                XCTFail("Mock失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 错误映射测试
    func testErrorMapping() throws {
        let expectation = self.expectation(description: "Error mapping should work")
        let manager = LQNetworkManager()
        manager.addErrorMapper { data, _ in
            if let str = String(data: data, encoding: .utf8), str.contains("error_code_123") {
                return LQNetworkError.custom(message: "业务错误123")
            }
            return nil
        }
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/error" {
                let mockData = "error_code_123".data(using: .utf8)
                return (mockData, nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/error") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(_):
                XCTFail("应返回业务错误")
            case .failure(let error):
                print("error.localizedDescription:", error.localizedDescription)
                XCTAssertEqual(error.localizedDescription, "业务错误123")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 响应中间件测试（解密/预处理）
    func testResponseMiddleware() throws {
        let expectation = self.expectation(description: "Middleware should process data")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/middleware" {
                let mockData = "abc".data(using: .utf8)
                return (mockData, nil, nil)
            }
            return nil
        }
        manager.addResponseMiddleware { data, _ in
            // 假设“解密”就是反转字符串
            let str = String(data: data, encoding: .utf8) ?? ""
            let reversed = String(str.reversed())
            return reversed.data(using: .utf8) ?? data
        }
        guard let url = URL(string: "https://mock.test/middleware") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "cba")
            case .failure(let error):
                XCTFail("中间件失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 文件上传测试（仅接口调用，mock）
    func testUploadMock() throws {
        let expectation = self.expectation(description: "Upload should succeed (mock)")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/upload" {
                return ("upload_ok".data(using: .utf8), nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/upload") else {
            XCTFail("URL 构造失败")
            return
        }
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock.txt")
        try? "mockfile".write(to: fileURL, atomically: true, encoding: .utf8)
        manager.upload(url: url, files: [(fileURL: fileURL, fieldName: "file", fileName: fileURL.lastPathComponent, mimeType: "text/plain")]) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "upload_ok")
            case .failure(let error):
                XCTFail("上传失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 文件下载测试（仅接口调用，mock）
    func testDownloadMock() throws {
        let expectation = self.expectation(description: "Download should succeed (mock)")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/download" {
                let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock_download.txt")
                try? "mockdata".write(to: tempURL, atomically: true, encoding: .utf8)
                // 返回文件路径字符串作为 Data，测试用
                let data = tempURL.absoluteString.data(using: .utf8)
                return (data, nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/download") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.download(url: url) { result in
            switch result {
            case .success(let fileURL):
                XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            case .failure(let error):
                XCTFail("下载失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 并发队列与优先级测试（仅接口调用，mock）
    func testRequestQueuePriority() throws {
        let expectation = self.expectation(description: "Priority queue should work")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.maxConcurrentRequests = 1
        var order: [String] = []
        var fulfilled = false
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/priority1" {
                return ("1".data(using: .utf8), nil, nil)
            }
            if req.url?.absoluteString == "https://mock.test/priority2" {
                return ("2".data(using: .utf8), nil, nil)
            }
            return nil
        }
        let url1 = URL(string: "https://mock.test/priority1")!
        let url2 = URL(string: "https://mock.test/priority2")!
        manager.get(url: url1) { result in
            if case .success(let data) = result {
                order.append(String(data: data, encoding: .utf8) ?? "")
            }
            if order.count == 2 && !fulfilled {
                XCTAssertEqual(order, ["2", "1"])
                expectation.fulfill()
                fulfilled = true
            }
        }
        manager.enqueueRequest(priority: .high) {
            manager.get(url: url2) { result in
                if case .success(let data) = result {
                    order.insert(String(data: data, encoding: .utf8) ?? "", at: 0)
                }
                if order.count == 2 && !fulfilled {
                    XCTAssertEqual(order, ["2", "1"])
                    expectation.fulfill()
                    fulfilled = true
                }
            }
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 网络状态监听与断网重试（仅接口调用，mock）
    func testNetworkMonitor() throws {
        let expectation1 = self.expectation(description: "断网时挂起")
        let expectation2 = self.expectation(description: "恢复后重试成功")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.isNetworkAvailable = false
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/retry" {
                return ("retry_ok".data(using: .utf8), nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/retry") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(_):
                XCTFail("断网时不应成功")
                expectation1.fulfill()
            case .failure(let error):
                XCTAssertTrue(error.localizedDescription.contains("挂起请求"))
                expectation1.fulfill()
            }
        }
        // 恢复网络
        manager.isNetworkAvailable = true
        manager.pendingRequests.forEach { $0() }
        manager.pendingRequests.removeAll()
        manager.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "retry_ok")
                expectation2.fulfill()
            case .failure(let error):
                XCTFail("重试失败: \(error)")
                expectation2.fulfill()
            }
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 日志打印测试（仅接口调用，mock）
    func testLogging() throws {
        let expectation = self.expectation(description: "Logging should print")
        let manager = LQNetworkManager()
        manager.enableLogging = true
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/log" {
                return ("log_ok".data(using: .utf8), nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/log") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "log_ok")
            case .failure(let error):
                XCTFail("日志失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 流式响应测试（仅接口调用，mock）
    func testDataStreamMock() throws {
        let expectation = self.expectation(description: "Data stream should yield chunks")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/stream" {
                let mockData = "abcdefghij".data(using: .utf8)
                return (mockData, nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/stream") else {
            XCTFail("URL 构造失败")
            return
        }
        var chunks: [String] = []
        let stream = manager.dataStream(url: url, chunkSize: 2)
        let task = Task {
            do {
                for try await chunk in stream {
                    chunks.append(String(data: chunk, encoding: .utf8) ?? "")
                }
                XCTAssertEqual(chunks, ["ab", "cd", "ef", "gh", "ij"])
            } catch {
                XCTFail("流式失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
        task.cancel()
    }
    
    // 多文件上传测试
    func testMultiFileUploadMock() throws {
        let expectation = self.expectation(description: "Multi file upload should succeed (mock)")
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.url?.absoluteString == "https://mock.test/multiupload" {
                return ("multi_upload_ok".data(using: .utf8), nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/multiupload") else {
            XCTFail("URL 构造失败")
            return
        }
        let file1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock1.txt")
        let file2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock2.txt")
        try? "mockfile1".write(to: file1, atomically: true, encoding: .utf8)
        try? "mockfile2".write(to: file2, atomically: true, encoding: .utf8)
        let files = [
            (fileURL: file1, fieldName: "fileA", fileName: "mock1.txt", mimeType: "text/plain"),
            (fileURL: file2, fieldName: "fileB", fileName: "mock2.txt", mimeType: "text/plain")
        ]
        manager.upload(url: url, files: files) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "multi_upload_ok")
            case .failure(let error):
                XCTFail("多文件上传失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 全局请求/响应拦截器链测试
    func testGlobalInterceptorChain() throws {
        let expectation = self.expectation(description: "Global interceptor chain should work")
        LQNetworkManager.globalRequestInterceptors = [
            { req in req.setValue("test-token", forHTTPHeaderField: "X-Test-Token") }
        ]
        LQNetworkManager.globalResponseMiddlewares = [
            { data, _ in
                let str = String(data: data, encoding: .utf8) ?? ""
                return (str + "-global").data(using: .utf8) ?? data
            }
        ]
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.value(forHTTPHeaderField: "X-Test-Token") == "test-token" {
                return ("intercepted".data(using: .utf8), nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/intercept") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "intercepted-global")
            case .failure(let error):
                XCTFail("拦截器链失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
        LQNetworkManager.globalRequestInterceptors = []
        LQNetworkManager.globalResponseMiddlewares = []
    }
    
    // 链路追踪与耗时统计测试
    func testTraceIdAndTiming() throws {
        let expectation = self.expectation(description: "TraceId and timing should work")
        LQNetworkManager.enableTraceId = true
        LQNetworkManager.traceIdHeaderKey = "X-Trace-Id"
        LQNetworkManager.traceIdGenerator = { "trace-123" }
        LQNetworkManager.enableTiming = true
        var timing: TimeInterval = 0
        LQNetworkManager.onRequestTiming = { req, duration in
            if req.value(forHTTPHeaderField: "X-Trace-Id") == "trace-123" {
                timing = duration
            }
        }
        let manager = LQNetworkManager()
        manager.enableMock = true
        manager.addMockHandler { req in
            if req.value(forHTTPHeaderField: "X-Trace-Id") == "trace-123" {
                return ("trace_ok".data(using: .utf8), nil, nil)
            }
            return nil
        }
        guard let url = URL(string: "https://mock.test/trace") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "trace_ok")
                XCTAssertTrue(timing >= 0)
            case .failure(let error):
                XCTFail("链路追踪失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
        LQNetworkManager.enableTraceId = false
        LQNetworkManager.enableTiming = false
        LQNetworkManager.onRequestTiming = nil
    }
    
    // 重试策略测试
    func testRetryPolicy() throws {
        let expectation = self.expectation(description: "Retry policy should work")
        let manager = LQNetworkManager()
        manager.retryPolicy = .init(maxRetryCount: 2, baseDelay: 0.1, maxDelay: 0.5, shouldRetry: { error, count in
            return true
        })
        var callCount = 0
        manager.enableMock = true
        manager.addMockHandler { req in
            callCount += 1
            if callCount < 3 {
                return (nil, nil, NSError(domain: "mock", code: -1, userInfo: nil))
            } else {
                return ("retry_success".data(using: .utf8), nil, nil)
            }
        }
        guard let url = URL(string: "https://mock.test/retrypolicy") else {
            XCTFail("URL 构造失败")
            return
        }
        manager.get(url: url) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "retry_success")
                XCTAssertEqual(callCount, 3)
            case .failure(let error):
                XCTFail("重试策略失败: \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
    }
    
    // 网络状态监听细粒度测试
    func testNetworkStatusChange() throws {
        let expectation = self.expectation(description: "Network status change should trigger callback")
        let manager = LQNetworkManager()
        var statusHistory: [LQNetworkManager.NetworkStatus] = []
        manager.onNetworkStatusChanged = { status in
            statusHistory.append(status)
        }
        // 模拟状态变化
        manager.currentNetworkStatus = LQNetworkManager.NetworkStatus.wifi
        manager.onNetworkStatusChanged?(manager.currentNetworkStatus)
        manager.currentNetworkStatus = LQNetworkManager.NetworkStatus.cellular
        manager.onNetworkStatusChanged?(manager.currentNetworkStatus)
        manager.currentNetworkStatus = LQNetworkManager.NetworkStatus.unavailable
        manager.onNetworkStatusChanged?(manager.currentNetworkStatus)
        XCTAssertEqual(statusHistory, [LQNetworkManager.NetworkStatus.wifi, LQNetworkManager.NetworkStatus.cellular, LQNetworkManager.NetworkStatus.unavailable])
        expectation.fulfill()
        waitForExpectations(timeout: 1, handler: nil)
    }
    
    override func setUpWithError() throws {
    }
    
    override func tearDownWithError() throws {
    }
    
    func testExample() throws {
    }
    
    func testPerformanceExample() throws {
        self.measure {
        }
    }
    
}
