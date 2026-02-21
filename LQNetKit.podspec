Pod::Spec.new do |s|
  s.name         = "LQNetKit"
  s.version      = "1.0.0"
  s.summary      = "通用网络请求 iOS 工具库，支持多种 HTTP 方法、缓存、Mock、进度、断网重试等。"
  s.description  = <<-DESC
LQNetKit 是一个 Swift 编写的通用网络请求工具库，支持 GET/POST/PUT/DELETE、参数自动编码、响应链式处理、错误映射、缓存、进度回调、网络状态监听、断网自动重试、并发队列、优先级、全局拦截器、日志、文件上传下载、流式响应、async/await、Mock/Stub 等。
  DESC
  s.homepage     = "https://github.com/feather2222/LQNetKit"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "xiangduojia" => "1402479908@qq.com" }
  s.source       = { :git => "https://github.com/feather2222/LQNetKit.git", :tag => s.version }
  s.platform     = :ios, "13.0"
  s.swift_version = "5.0"
  s.source_files = "LQNetKit/**/*.{swift}"
  s.requires_arc = true
end