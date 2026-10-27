import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

public enum VisionImageEffect: Sendable, Equatable {
    case blurBackground
    case extractSubject

    public var progressMessage: String {
        switch self {
        case .blurBackground: return L10n.string("正在虚化背景...")
        case .extractSubject: return L10n.string("正在提取主体...")
        }
    }

    public var completionMessage: String {
        switch self {
        case .blurBackground: return L10n.string("背景虚化完成")
        case .extractSubject: return L10n.string("主体已提取")
        }
    }
}

public enum VisionImageEffectsError: LocalizedError {
    case invalidImage
    case noForegroundSubject
    case couldNotRender

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return L10n.string("无法读取这张图片。")
        case .noForegroundSubject:
            return L10n.string("没有识别到可分离的主体。")
        case .couldNotRender:
            return L10n.string("无法生成图片效果。")
        }
    }
}

public final class VisionImageEffectsService {
    public static let shared = VisionImageEffectsService()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private init() {}

    public func apply(_ effect: VisionImageEffect, to image: NSImage) async throws -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisionImageEffectsError.invalidImage
        }

        let pointSize = image.size
        return try await Task.detached(priority: .userInitiated) {
            try Self.render(effect, cgImage: cgImage, pointSize: pointSize)
        }.value
    }

    private static func render(
        _ effect: VisionImageEffect,
        cgImage: CGImage,
        pointSize: NSSize
    ) throws -> NSImage {
        let source = CIImage(cgImage: cgImage)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        try handler.perform([request])

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw VisionImageEffectsError.noForegroundSubject
        }

        let instances = observation.allInstances

        let output: CIImage
        switch effect {
        case .extractSubject:
            let pixelBuffer = try observation.generateMaskedImage(
                ofInstances: instances,
                from: handler,
                croppedToInstancesExtent: false
            )
            output = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: source.extent)

        case .blurBackground:
            let maskBuffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
            let mask = CIImage(cvPixelBuffer: maskBuffer)
            let blurredBackground = source
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22.0])
                .cropped(to: source.extent)

            let composite = CIFilter.blendWithMask()
            composite.inputImage = source
            composite.backgroundImage = blurredBackground
            composite.maskImage = mask
            guard let blended = composite.outputImage else {
                throw VisionImageEffectsError.couldNotRender
            }
            output = blended

        }

        guard let result = context.createCGImage(output, from: source.extent) else {
            throw VisionImageEffectsError.couldNotRender
        }
        return NSImage(cgImage: result, size: pointSize)
    }

}
