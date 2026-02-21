# LQNetKit

LQNetKit 是一个现代化、功能丰富的 Swift 网络请求库，支持多种高级特性，适用于 iOS/macOS 网络层开发。

## 特性
- 支持 GET/POST/PUT/DELETE 等常用请求
- 参数自动编码（JSON、x-www-form-urlencoded、multipart/form-data 多文件上传）
- 支持 Mock/Stub 测试与数据注入
- 错误映射与响应中间件链（如解密、预处理）
- 请求队列与优先级并发控制
- 上传/下载进度回调、断点续传
- 本地缓存（Etag/Last-Modified）
- 网络状态监听与断网自动重试
- 支持全局/局部请求与响应拦截器链
- 支持链路追踪（traceId 注入、耗时统计）
- 灵活的请求重试策略（指数退避、最大重试次数、自定义重试条件）
- 完善的单元测试覆盖

## 安装

### CocoaPods
```
pod 'LQNetKit'
```

### Swift Package Manager
```
.package(url: "https://github.com/你的github/LQNetKit.git", from: "1.0.0")
```

## 快速使用
```swift
import LQNetKit

// GET 请求
LQNetworkManager.shared.get(url: URL(string: "https://httpbin.org/get")!) { result in
    // ...
}

// POST 请求
LQNetworkManager.shared.post(url: URL(string: "https://httpbin.org/post")!, parameters: ["foo": "bar"]) { result in
    // ...
}

// 多文件上传
let files = [
    (fileURL: file1, fieldName: "fileA", fileName: "file1.txt", mimeType: "text/plain"),
    (fileURL: file2, fieldName: "fileB", fileName: "file2.txt", mimeType: "text/plain")
]
LQNetworkManager.shared.upload(url: uploadURL, files: files) { result in
    // ...
}
```

## 高级用法

### Mock/Stub 测试
```swift
let manager = LQNetworkManager()
manager.enableMock = true
manager.addMockHandler { req in
    if req.url?.absoluteString == "https://mock.test/data" {
        return ("mocked".data(using: .utf8), nil, nil)
    }
    return nil
}
```

### 错误映射与响应中间件
```swift
manager.addErrorMapper { data, _ in
    // ...
    return nil
}
manager.addResponseMiddleware { data, _ in
    // ...
    return data
}
```

### 全局拦截器链
```swift
LQNetworkManager.globalRequestInterceptors = [
    { req in req.setValue("token", forHTTPHeaderField: "X-Token") }
]
LQNetworkManager.globalResponseMiddlewares = [
    { data, _ in data }
]
```

### 链路追踪与耗时统计
```swift
LQNetworkManager.enableTraceId = true
LQNetworkManager.enableTiming = true
LQNetworkManager.onRequestTiming = { req, duration in
    print("请求耗时: \(duration)s")
}
```

### 重试策略
```swift
manager.retryPolicy = .init(maxRetryCount: 3, baseDelay: 0.5, maxDelay: 2)
```

## 单元测试

所有功能均有专项测试，详见 `LQNetKitTests/LQNetKitTests.swift`。

## 许可证

MIT License

---
如需更多示例或文档，欢迎提 issue 或 PR！