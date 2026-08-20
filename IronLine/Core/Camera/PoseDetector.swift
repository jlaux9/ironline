import CoreGraphics
import CoreVideo
import ImageIO
import Vision

struct PoseFrame {
    let elbowAngle: Double
    let confidence: Double
    let shoulder: CGPoint
    let elbow: CGPoint
    let wrist: CGPoint
}

/// Thin Vision adapter. It intentionally does NOT know about reps or exercises.
/// Its job is only: pixels -> reliable joint geometry.
final class PoseDetector {
    private let request = VNDetectHumanBodyPoseRequest()

    func detect(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> PoseFrame? {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])

        guard let observation = request.results?.first else { return nil }

        let rawWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let rawHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rotatesImage = orientation == .left || orientation == .leftMirrored || orientation == .right || orientation == .rightMirrored
        let width = rotatesImage ? rawHeight : rawWidth
        let height = rotatesImage ? rawWidth : rawHeight

        let left = try armFrame(
            observation: observation,
            shoulderName: .leftShoulder,
            elbowName: .leftElbow,
            wristName: .leftWrist,
            width: width,
            height: height
        )

        let right = try armFrame(
            observation: observation,
            shoulderName: .rightShoulder,
            elbowName: .rightElbow,
            wristName: .rightWrist,
            width: width,
            height: height
        )

        // Side-view gym footage often occludes one arm. Prefer the arm Vision is
        // more confident about instead of averaging a clean arm with a bad one.
        return [left, right]
            .compactMap { $0 }
            .max(by: { $0.confidence < $1.confidence })
    }

    private func armFrame(
        observation: VNHumanBodyPoseObservation,
        shoulderName: VNHumanBodyPoseObservation.JointName,
        elbowName: VNHumanBodyPoseObservation.JointName,
        wristName: VNHumanBodyPoseObservation.JointName,
        width: CGFloat,
        height: CGFloat
    ) throws -> PoseFrame? {
        let points = try observation.recognizedPoints(.all)

        guard
            let shoulderPoint = points[shoulderName],
            let elbowPoint = points[elbowName],
            let wristPoint = points[wristName]
        else { return nil }

        let confidence = Double(min(shoulderPoint.confidence, elbowPoint.confidence, wristPoint.confidence))
        guard confidence >= 0.25 else { return nil }

        let shoulder = CGPoint(x: shoulderPoint.location.x * width, y: shoulderPoint.location.y * height)
        let elbow = CGPoint(x: elbowPoint.location.x * width, y: elbowPoint.location.y * height)
        let wrist = CGPoint(x: wristPoint.location.x * width, y: wristPoint.location.y * height)

        return PoseFrame(
            elbowAngle: Self.angle(a: shoulder, vertex: elbow, c: wrist),
            confidence: confidence,
            shoulder: shoulder,
            elbow: elbow,
            wrist: wrist
        )
    }

    private static func angle(a: CGPoint, vertex b: CGPoint, c: CGPoint) -> Double {
        let ba = CGVector(dx: a.x - b.x, dy: a.y - b.y)
        let bc = CGVector(dx: c.x - b.x, dy: c.y - b.y)
        let dot = ba.dx * bc.dx + ba.dy * bc.dy
        let magnitude = hypot(ba.dx, ba.dy) * hypot(bc.dx, bc.dy)
        guard magnitude > 0 else { return 0 }
        let cosine = max(-1, min(1, dot / magnitude))
        return acos(cosine) * 180 / .pi
    }
}
