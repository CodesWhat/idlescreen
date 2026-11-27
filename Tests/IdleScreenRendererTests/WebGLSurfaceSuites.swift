import Testing

/// Every suite that creates an `IdleScreenAquariumWebSurface` nests here. `.serialized` on the
/// parent runs them one test at a time, so only one WebGL context is live at once. Without it the
/// `@MainActor` tests interleave at each `await` and hosted runners hit their per-process context
/// limit, after which every later load fails with "WebGL unavailable".
@Suite("Hosted WebGL surfaces", .serialized)
enum WebGLSurfaceSuites {}
