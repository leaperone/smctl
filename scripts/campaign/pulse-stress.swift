// Heat load for the hardware campaign (test 8): every CPU core runs vector
// FMA chains and the GPU runs a compute kernel, which together draw about
// twice the power of a CPU-only load (~36 W vs ~18 W on an M1 Pro).
// Compiled on the fly by scripts/hardware-campaign.sh; stop it with a signal.
import Foundation
import Metal

// CPU: independent chains that converge (x → 1), so values stay finite.
let cores = ProcessInfo.processInfo.activeProcessorCount
for _ in 0..<cores {
    Thread {
        var a = (0..<8).map { SIMD8<Float>(repeating: Float($0)) }
        let b = SIMD8<Float>(repeating: 0.9999999), c = SIMD8<Float>(repeating: 0.0000001)
        while true {
            for _ in 0..<1_000_000 { for i in 0..<8 { a[i] = a[i] * b + c } }
            if a[0][0] < -1 { print(a[7]) }  // never true; keeps the loop alive
        }
    }.start()
}

// GPU: dependent FMAs over a large grid, resubmitted forever.
let source = """
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id) * 1e-6, y = 0.9999999;
    for (int i = 0; i < 4096; i++) { x = fma(x, y, 1e-7); y = fma(y, 0.9999999, 1e-7); }
    out[id] = x + y;
}
"""
guard let device = MTLCreateSystemDefaultDevice(),
      let library = try? device.makeLibrary(source: source, options: nil),
      let function = library.makeFunction(name: "burn"),
      let pipeline = try? device.makeComputePipelineState(function: function),
      let queue = device.makeCommandQueue(),
      let buffer = device.makeBuffer(length: (1 << 20) * 4, options: .storageModePrivate) else {
    while true { sleep(60) }  // CPU load only
}
while true {
    let commands = queue.makeCommandBuffer()!
    let encoder = commands.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 1 << 20, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
}
