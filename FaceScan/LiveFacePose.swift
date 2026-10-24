import Foundation
import simd

/// The latest camera-relative head pose. Point positions remain face-local;
/// only their scene node moves, so pose updates never rebuild point buffers.
struct LiveFacePose: Sendable {
    let revision: UInt64
    let transform: simd_float4x4
}

/// Shared by the ARSession's serial worker and the main-thread renderer. A tiny
/// locked value avoids publishing full-rate camera updates through SwiftUI.
final class LiveFacePoseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var referencePosition: SIMD3<Float>?
    private var pose: LiveFacePose?
    private var revision: UInt64 = 0

    var latestPose: LiveFacePose? {
        lock.lock()
        defer { lock.unlock() }
        return pose
    }

    /// Pass camera.viewMatrix(for: .portrait) * face.transform. The first
    /// position centers the stage; rotation stays absolute in screen axes, so
    /// even a first observation of a turned head displays its actual angle.
    @discardableResult
    func update(faceToCamera: simd_float4x4) -> Bool {
        guard Self.isValidRigidTransform(faceToCamera) else { return false }
        let position = SIMD3(faceToCamera.columns.3.x, faceToCamera.columns.3.y,
                             faceToCamera.columns.3.z)
        lock.lock()
        defer { lock.unlock() }
        let reference = referencePosition ?? position
        referencePosition = reference
        var transform = faceToCamera
        transform.columns.3 = SIMD4(position - reference, 1)
        revision &+= 1
        pose = LiveFacePose(revision: revision, transform: transform)
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        referencePosition = nil
        pose = nil
    }

    private static func isValidRigidTransform(_ transform: simd_float4x4) -> Bool {
        for column in [transform.columns.0, transform.columns.1,
                       transform.columns.2, transform.columns.3] {
            guard column.x.isFinite, column.y.isFinite,
                  column.z.isFinite, column.w.isFinite else { return false }
        }
        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        // ARKit supplies rigid transforms. Reject malformed samples rather
        // than allowing scaling, reflection, or NaNs to corrupt the stage.
        let gram = rotation.transpose * rotation
        let tolerance: Float = 0.01
        for column in 0..<3 {
            for row in 0..<3 {
                guard abs(gram[column][row] - (column == row ? 1 : 0)) < tolerance else { return false }
            }
        }
        return abs(simd_determinant(rotation) - 1) < tolerance
            && abs(transform.columns.0.w) < tolerance
            && abs(transform.columns.1.w) < tolerance
            && abs(transform.columns.2.w) < tolerance
            && abs(transform.columns.3.w - 1) < tolerance
    }
}
