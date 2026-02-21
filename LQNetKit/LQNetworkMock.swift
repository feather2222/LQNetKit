// LQNetworkMock.swift
// Mock/Stub 支持
import Foundation

public typealias LQMockHandler = (URLRequest) -> (Data?, URLResponse?, Error?)?
