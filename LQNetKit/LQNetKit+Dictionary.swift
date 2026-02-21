// Dictionary+LQNetKit.swift
// 字典扩展：参数编码
import Foundation

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
