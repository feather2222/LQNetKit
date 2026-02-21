//
//  LQNetKit.swift
//  LQNetKit
//
//  Created by xiangduojia on 2026/2/20.
//


import Foundation
import Network

// MARK: - 重试策略
public struct RetryPolicy {
    public var maxRetryCount: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var shouldRetry: ((Error, Int) -> Bool)?
    public init(maxRetryCount: Int = 2, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 5, shouldRetry: ((Error, Int) -> Bool)? = nil) {
        self.maxRetryCount = maxRetryCount
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.shouldRetry = shouldRetry
    }
}
