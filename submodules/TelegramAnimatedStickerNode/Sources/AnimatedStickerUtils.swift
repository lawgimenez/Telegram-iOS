import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import Display
import TelegramCore
import SyncCore
import Compression
import GZip
import RLottieBinding
import MediaResources
import MobileCoreServices
import MediaResources
import YuvConversion
import AnimatedStickerNode

public func fetchCompressedLottieFirstFrameAJpeg(data: Data, size: CGSize, fitzModifier: EmojiFitzModifier? = nil, cacheKey: String) -> Signal<TempBoxFile, NoError> {
    return Signal({ subscriber in
        let queue = Queue()
        
        let cancelled = Atomic<Bool>(value: false)
        
        queue.async {
            if cancelled.with({ $0 }) {
                return
            }
            
            let decompressedData = TGGUnzipData(data, 8 * 1024 * 1024)
            if let decompressedData = decompressedData {
                let decompressedData = transformedWithFitzModifier(data: decompressedData, fitzModifier: fitzModifier)
                if let player = LottieInstance(data: decompressedData, cacheKey: cacheKey) {
                    if cancelled.with({ $0 }) {
                        return
                    }
                    
                    let context = DrawingContext(size: size, scale: 1.0, clear: true)
                    player.renderFrame(with: 0, into: context.bytes.assumingMemoryBound(to: UInt8.self), width: Int32(size.width), height: Int32(size.height), bytesPerRow: Int32(context.bytesPerRow))
                    
                    let yuvaPixelsPerAlphaRow = (Int(size.width) + 1) & (~1)
                    assert(yuvaPixelsPerAlphaRow % 2 == 0)
                    
                    let yuvaLength = Int(size.width) * Int(size.height) * 2 + yuvaPixelsPerAlphaRow * Int(size.height) / 2
                    var yuvaFrameData = malloc(yuvaLength)!
                    memset(yuvaFrameData, 0, yuvaLength)
                    
                    defer {
                        free(yuvaFrameData)
                    }
                    
                    encodeRGBAToYUVA(yuvaFrameData.assumingMemoryBound(to: UInt8.self), context.bytes.assumingMemoryBound(to: UInt8.self), Int32(size.width), Int32(size.height), Int32(context.bytesPerRow))
                    decodeYUVAToRGBA(yuvaFrameData.assumingMemoryBound(to: UInt8.self), context.bytes.assumingMemoryBound(to: UInt8.self), Int32(size.width), Int32(size.height), Int32(context.bytesPerRow))
                    
                    if let colorSourceImage = context.generateImage(), let alphaImage = generateGrayscaleAlphaMaskImage(image: colorSourceImage) {
                        let colorContext = DrawingContext(size: size, scale: 1.0, clear: false)
                        colorContext.withFlippedContext { c in
                            c.setFillColor(UIColor.black.cgColor)
                            c.fill(CGRect(origin: CGPoint(), size: size))
                            c.draw(colorSourceImage.cgImage!, in: CGRect(origin: CGPoint(), size: size))
                        }
                        guard let colorImage = colorContext.generateImage() else {
                            return
                        }
                        
                        let colorData = NSMutableData()
                        let alphaData = NSMutableData()
                        
                        if let colorDestination = CGImageDestinationCreateWithData(colorData as CFMutableData, kUTTypeJPEG, 1, nil), let alphaDestination = CGImageDestinationCreateWithData(alphaData as CFMutableData, kUTTypeJPEG, 1, nil) {
                            CGImageDestinationSetProperties(colorDestination, [:] as CFDictionary)
                            CGImageDestinationSetProperties(alphaDestination, [:] as CFDictionary)
                            
                            let colorQuality: Float
                            let alphaQuality: Float
                            colorQuality = 0.5
                            alphaQuality = 0.4
                            
                            let options = NSMutableDictionary()
                            options.setObject(colorQuality as NSNumber, forKey: kCGImageDestinationLossyCompressionQuality as NSString)
                            
                            let optionsAlpha = NSMutableDictionary()
                            optionsAlpha.setObject(alphaQuality as NSNumber, forKey: kCGImageDestinationLossyCompressionQuality as NSString)
                            
                            CGImageDestinationAddImage(colorDestination, colorImage.cgImage!, options as CFDictionary)
                            CGImageDestinationAddImage(alphaDestination, alphaImage.cgImage!, optionsAlpha as CFDictionary)
                            if CGImageDestinationFinalize(colorDestination) && CGImageDestinationFinalize(alphaDestination) {
                                let finalData = NSMutableData()
                                var colorSize: Int32 = Int32(colorData.length)
                                finalData.append(&colorSize, length: 4)
                                finalData.append(colorData as Data)
                                var alphaSize: Int32 = Int32(alphaData.length)
                                finalData.append(&alphaSize, length: 4)
                                finalData.append(alphaData as Data)
                                
                                let tempFile = TempBox.shared.tempFile(fileName: "image.ajpg")
                                let _ = try? finalData.write(to: URL(fileURLWithPath: tempFile.path), options: [])
                                subscriber.putNext(tempFile)
                                subscriber.putCompletion()
                            }
                        }
                    }
                }
            }
        }
        return ActionDisposable {
            let _ = cancelled.swap(true)
        }
    })
}

private let threadPool: ThreadPool = {
    return ThreadPool(threadCount: 3, threadPriority: 0.5)
}()

@available(iOS 9.0, *)
public func experimentalConvertCompressedLottieToCombinedMp4(data: Data, size: CGSize, fitzModifier: EmojiFitzModifier? = nil, cacheKey: String) -> Signal<CachedMediaResourceRepresentationResult, NoError> {
    return Signal({ subscriber in
        let cancelled = Atomic<Bool>(value: false)
        
        threadPool.addTask(ThreadPoolTask({ _ in
            if cancelled.with({ $0 }) {
                return
            }
            
            let startTime = CACurrentMediaTime()
            var drawingTime: Double = 0
            var appendingTime: Double = 0
            var deltaTime: Double = 0
            var compressionTime: Double = 0
       
            let decompressedData = TGGUnzipData(data, 8 * 1024 * 1024)
            if let decompressedData = decompressedData {
                let decompressedData = transformedWithFitzModifier(data: decompressedData, fitzModifier: fitzModifier)
                if let player = LottieInstance(data: decompressedData, cacheKey: cacheKey) {
                    let endFrame = Int(player.frameCount)
                    
                    if cancelled.with({ $0 }) {
                        return
                    }
                    
                    let bytesPerRow = (4 * Int(size.width) + 15) & (~15)
                    
                    var currentFrame: Int32 = 0
                    
                    //let writeBuffer = WriteBuffer()
                    let tempFile = TempBox.shared.tempFile(fileName: "result.asticker")
                    guard let file = ManagedFile(queue: nil, path: tempFile.path, mode: .readwrite) else {
                        return
                    }
                    
                    func writeData(_ data: UnsafeRawPointer, length: Int) {
                        file.write(data, count: length)
                    }
                    
                    func commitData() {
                    }
                    
                    func completeWithCurrentResult() {
                        subscriber.putNext(.tempFile(tempFile))
                        subscriber.putCompletion()
                    }
                    
                    var numberOfFramesCommitted = 0
                    
                    var fps: Int32 = player.frameRate
                    var frameCount: Int32 = player.frameCount
                    writeData(&fps, length: 4)
                    writeData(&frameCount, length: 4)
                    var widthValue: Int32 = Int32(size.width)
                    var heightValue: Int32 = Int32(size.height)
                    var bytesPerRowValue: Int32 = Int32(bytesPerRow)
                    writeData(&widthValue, length: 4)
                    writeData(&heightValue, length: 4)
                    writeData(&bytesPerRowValue, length: 4)
                    
                    let frameLength = bytesPerRow * Int(size.height)
                    assert(frameLength % 16 == 0)
                    
                    let currentFrameData = malloc(frameLength)!
                    memset(currentFrameData, 0, frameLength)
                    
                    let yuvaPixelsPerAlphaRow = (Int(size.width) + 1) & (~1)
                    assert(yuvaPixelsPerAlphaRow % 2 == 0)
                    
                    let yuvaLength = Int(size.width) * Int(size.height) * 2 + yuvaPixelsPerAlphaRow * Int(size.height) / 2
                    var yuvaFrameData = malloc(yuvaLength)!
                    memset(yuvaFrameData, 0, yuvaLength)
                    
                    var previousYuvaFrameData = malloc(yuvaLength)!
                    memset(previousYuvaFrameData, 0, yuvaLength)
                    
                    defer {
                        free(currentFrameData)
                        free(previousYuvaFrameData)
                        free(yuvaFrameData)
                    }
                    
                    var compressedFrameData = Data(count: frameLength)
                    let compressedFrameDataLength = compressedFrameData.count
                    
                    let scratchData = malloc(compression_encode_scratch_buffer_size(COMPRESSION_LZFSE))!
                    defer {
                        free(scratchData)
                    }
                    
                    while currentFrame < endFrame {
                        if cancelled.with({ $0 }) {
                            return
                        }
                        
                        let drawStartTime = CACurrentMediaTime()
                        memset(currentFrameData, 0, frameLength)
                        player.renderFrame(with: Int32(currentFrame), into: currentFrameData.assumingMemoryBound(to: UInt8.self), width: Int32(size.width), height: Int32(size.height), bytesPerRow: Int32(bytesPerRow))
                        drawingTime += CACurrentMediaTime() - drawStartTime
                        
                        let appendStartTime = CACurrentMediaTime()
                        
                        encodeRGBAToYUVA(yuvaFrameData.assumingMemoryBound(to: UInt8.self), currentFrameData.assumingMemoryBound(to: UInt8.self), Int32(size.width), Int32(size.height), Int32(bytesPerRow))
                        
                        appendingTime += CACurrentMediaTime() - appendStartTime
                        
                        let deltaStartTime = CACurrentMediaTime()
                        var lhs = previousYuvaFrameData.assumingMemoryBound(to: UInt64.self)
                        var rhs = yuvaFrameData.assumingMemoryBound(to: UInt64.self)
                        for _ in 0 ..< yuvaLength / 8 {
                            lhs.pointee = rhs.pointee ^ lhs.pointee
                            lhs = lhs.advanced(by: 1)
                            rhs = rhs.advanced(by: 1)
                        }
                        var lhsRest = previousYuvaFrameData.assumingMemoryBound(to: UInt8.self).advanced(by: (yuvaLength / 8) * 8)
                        var rhsRest = yuvaFrameData.assumingMemoryBound(to: UInt8.self).advanced(by: (yuvaLength / 8) * 8)
                        for _ in (yuvaLength / 8) * 8 ..< yuvaLength {
                            lhsRest.pointee = rhsRest.pointee ^ lhsRest.pointee
                            lhsRest = lhsRest.advanced(by: 1)
                            rhsRest = rhsRest.advanced(by: 1)
                        }
                        deltaTime += CACurrentMediaTime() - deltaStartTime
                        
                        let compressionStartTime = CACurrentMediaTime()
                        compressedFrameData.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                            let length = compression_encode_buffer(bytes, compressedFrameDataLength, previousYuvaFrameData.assumingMemoryBound(to: UInt8.self), yuvaLength, scratchData, COMPRESSION_LZFSE)
                            var frameLengthValue: Int32 = Int32(length)
                            writeData(&frameLengthValue, length: 4)
                            writeData(bytes, length: length)
                        }
                        
                        let tmp = previousYuvaFrameData
                        previousYuvaFrameData = yuvaFrameData
                        yuvaFrameData = tmp
                        
                        compressionTime += CACurrentMediaTime() - compressionStartTime
                        
                        currentFrame += 1
                        
                        numberOfFramesCommitted += 1
                        
                        if numberOfFramesCommitted >= 5 {
                            numberOfFramesCommitted = 0
                            
                            commitData()
                        }
                        
                    }
                    
                    commitData()
                    
                    completeWithCurrentResult()
                    subscriber.putCompletion()
                    /*print("animation render time \(CACurrentMediaTime() - startTime)")
                    print("of which drawing time \(drawingTime)")
                    print("of which appending time \(appendingTime)")
                    print("of which delta time \(deltaTime)")
                    
                    print("of which compression time \(compressionTime)")*/
                }
            }
        }))
        return ActionDisposable {
            let _ = cancelled.swap(true)
        }
    })
}
