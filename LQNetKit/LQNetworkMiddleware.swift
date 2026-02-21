// LQNetworkMiddleware.swift
// 响应处理链（中间件）与错误映射
import Foundation

public typealias LQErrorMapper = (Data, URLResponse?) -> Error?
public typealias LQResponseMiddleware = (Data, URLResponse?) -> Data
