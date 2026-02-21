// LQNetworkError.swift
// 网络请求自定义错误类型
import Foundation

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
