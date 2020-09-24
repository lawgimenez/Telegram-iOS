import Foundation
import UIKit
import MediaResources

let colorKeyRegex = try? NSRegularExpression(pattern: "\"k\":\\[[\\d\\.]+\\,[\\d\\.]+\\,[\\d\\.]+\\,[\\d\\.]+\\]")

public func transformedWithFitzModifier(data: Data, fitzModifier: EmojiFitzModifier?) -> Data {
    if let fitzModifier = fitzModifier, var string = String(data: data, encoding: .utf8) {
        let colors: [UIColor] = [0xf77e41, 0xffb139, 0xffd140, 0xffdf79].map { UIColor(rgb: $0) }
        let replacementColors: [UIColor]
        switch fitzModifier {
            case .type12:
                replacementColors = [0xca907a, 0xedc5a5, 0xf7e3c3, 0xfbefd6].map { UIColor(rgb: $0) }
            case .type3:
                replacementColors = [0xaa7c60, 0xc8a987, 0xddc89f, 0xe6d6b2].map { UIColor(rgb: $0) }
            case .type4:
                replacementColors = [0x8c6148, 0xad8562, 0xc49e76, 0xd4b188].map { UIColor(rgb: $0) }
            case .type5:
                replacementColors = [0x6e3c2c, 0x925a34, 0xa16e46, 0xac7a52].map { UIColor(rgb: $0) }
            case .type6:
                replacementColors = [0x291c12, 0x472a22, 0x573b30, 0x68493c].map { UIColor(rgb: $0) }
        }
        
        func colorToString(_ color: UIColor) -> String {
            var r: CGFloat = 0.0
            var g: CGFloat = 0.0
            var b: CGFloat = 0.0
            if color.getRed(&r, green: &g, blue: &b, alpha: nil) {
                return "\"k\":[\(r),\(g),\(b),1]"
            }
            return ""
        }
        
        func match(_ a: Double, _ b: Double, eps: Double) -> Bool {
            return abs(a - b) < eps
        }
        
        var replacements: [(NSTextCheckingResult, String)] = []
        
        if let colorKeyRegex = colorKeyRegex {
            let results = colorKeyRegex.matches(in: string, range: NSRange(string.startIndex..., in: string))
            for result in results.reversed()  {
                if let range = Range(result.range, in: string) {
                    let substring = String(string[range])
                    let color = substring[substring.index(string.startIndex, offsetBy: "\"k\":[".count) ..< substring.index(before: substring.endIndex)]
                    let components = color.split(separator: ",")
                    if components.count == 4, let r = Double(components[0]), let g = Double(components[1]), let b = Double(components[2]), let a = Double(components[3]) {
                        if match(a, 1.0, eps: 0.01) {
                            for i in 0 ..< colors.count {
                                let color = colors[i]
                                var cr: CGFloat = 0.0
                                var cg: CGFloat = 0.0
                                var cb: CGFloat = 0.0
                                if color.getRed(&cr, green: &cg, blue: &cb, alpha: nil) {
                                    if match(r, Double(cr), eps: 0.01) && match(g, Double(cg), eps: 0.01) && match(b, Double(cb), eps: 0.01) {
                                        replacements.append((result, colorToString(replacementColors[i])))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        for (result, text) in replacements {
            if let range = Range(result.range, in: string) {
                string = string.replacingCharacters(in: range, with: text)
            }
        }
        
        return string.data(using: .utf8) ?? data
    } else {
        return data
    }
}
