import CoreGraphics
import Foundation
import simd

struct Canvas {
  let rgb: FloatBuffer
  let w, h: Int
  var facts: Facts
  var frames: [Facts]
}
// Fractions of source pixels per cell, suitable for an overlay on a fit-to-view inspection preview.
func maskPreview(_ values: [UInt8], _ width: Int, _ height: Int, select: (UInt8) -> Bool) -> Facts {
  let cols = min(96, width)
  let rows = min(64, height)
  var bytes = [UInt8](repeating: 0, count: cols * rows)
  for by in 0..<rows {
    let top = by * height / rows
    let bottom = (by + 1) * height / rows
    for bx in 0..<cols {
      let left = bx * width / cols
      let right = (bx + 1) * width / cols
      var selected = 0
      for y in top..<bottom {
        for x in left..<right where select(values[y * width + x]) { selected += 1 }
      }
      let fraction = Double(selected) / Double((bottom - top) * (right - left))
      bytes[by * cols + bx] = UInt8((fraction * 255).rounded())
    }
  }
  return [
    "width": cols, "height": rows, "space": "top-left normalized uncropped",
    "encoding": "base64 row-major uint8 fractional coverage",
    "data": Data(bytes).base64EncodedString(),
  ]
}
func near(_ a: Double?, _ b: Double?) -> Bool {
  guard let a, let b, a > 0, b > 0 else { return false }
  return abs(log(a / b)) < 0.05
}
func dimension(_ w: Int, _ h: Int, _ other: (FloatBuffer, Int, Int)) throws {
  guard w == other.1, h == other.2 else {
    throw RenderIssue("decoded dimensions changed across frames")
  }
}
func star(_ xs: [Input], _ r: Recipe) throws -> Canvas {
  guard r.stackMode == nil || r.stackMode == "lighten" else {
    throw RenderIssue("unsupported star-trail stack mode")
  }
  let first = xs[0]
  let reference = r.referenceIndex ?? xs.count / 2
  guard xs.indices.contains(reference), r.foregroundStartY.map({ (0...1).contains($0) }) ?? true
  else { throw RenderIssue("invalid star-trail reference or foreground boundary") }
  let neutral = first.neutral
  let anchorProxy = try makeProxy(xs[reference], neutral: neutral)
  var uncertain = [Int]()
  var displaced = [Int]()
  let anchorTop = min(0.83, r.foregroundStartY ?? 0.58)
  let base = try rawImage(first, neutral: neutral).extent.integral
  let w = Int(base.width)
  let h = Int(base.height)
  let n = w * h
  let output = try FloatBuffer(3 * n)
  var owner = [UInt16](repeating: 0, count: n)
  var per = [Facts]()
  var gaps = [Double]()
  var maxGap: Double = 0
  for (i, x) in xs.enumerated() {
    if let a = x.shutter, let b = first.shutter, !near(a, b) {
      throw RenderIssue("star exposure changed at frozen index \(i)")
    }
    let updated: UInt64 = try autoreleasepool {
      let im = try renderInput(x, neutral: neutral)
      try dimension(w, h, im)
      var updated: UInt64 = 0
      gr_star(output.p, &owner, im.0.p, Int32(n), Int32(i), &updated)
      return updated
    }
    var frame: Facts = ["winningUpdates": updated]
    if i != reference {
      let moving = try makeProxy(x, neutral: neutral)
      guard moving.w == anchorProxy.w, moving.h == anchorProxy.h else {
        throw RenderIssue("inconsistent star proxy geometry")
      }
      var measurement = GRMatch()
      let status = gr_anchor(
        anchorProxy.data, moving.data, Int32(moving.w), Int32(moving.h), anchorTop, &measurement)
      frame["lowerRegionInliers"] = measurement.inliers
      if status == 0 {
        frame["lowerRegionShiftProxyPixels"] = [measurement.deltaX, measurement.deltaY]
        if hypot(measurement.deltaX, measurement.deltaY) > 2 || measurement.translationP95 > 2 {
          displaced.append(i)
        }
      } else {
        uncertain.append(i)
      }
    }
    if i > 0, let t = x.clock, let prev = xs[i - 1].clock {
      let dt = t - prev
      guard dt >= 0 else { throw RenderIssue("star capture order runs backwards at index \(i)") }
      let gap = max(0, dt - (xs[i - 1].shutter ?? 0))
      frame["startIntervalSeconds"] = dt
      frame["estimatedUnexposedSeconds"] = gap
      gaps.append(dt)
      maxGap = max(maxGap, gap)
    }
    per.append(frame)
  }
  var final = [UInt64](repeating: 0, count: xs.count)
  for id in owner { final[Int(id)] += 1 }
  for i in per.indices { per[i]["winningOutputPixels"] = final[i] }
  var facts: Facts = [
    "stackMode": "lighten",
    "winningRule": "linear Rec.709 luminance, full RGB from winner; frozen-first ties",
    "alignment": "fixed terrestrial coordinates", "temporalInterpolation": false,
    "maximumUnexposedSeconds": maxGap,
    "changedFromFirstPixels": UInt64(n) - final[0], "cameraIntervalsMeasured": gaps.count,
  ]
  facts["referenceIndex"] = reference
  facts["lowerRegionProxySize"] = [anchorProxy.w, anchorProxy.h]
  facts["lowerRegionTopNormalized"] = anchorTop
  facts["foregroundReviewIndices"] = displaced
  facts["foregroundUnknownIndices"] = uncertain
  facts["registrationPolicy"] =
    "original frame geometry; lower-region anchor displacement is review evidence only"
  if let top = r.foregroundStartY {
    let ref = try renderInput(xs[reference], neutral: neutral)
    try dimension(w, h, ref)
    var counts = [UInt64](repeating: 0, count: 2)
    gr_foreground(output.p, ref.0.p, Int32(w), Int32(h), top, &counts)
    facts["foregroundStartY"] = top
    facts["referenceForegroundPixels"] = counts[0]
    facts["featheredForegroundPixels"] = counts[1]
    facts["winningCountsSpace"] = "lighten accumulator before optional reference foreground mask"
  }
  if !gaps.isEmpty {
    let med = gaps.sorted()[gaps.count / 2]
    facts["medianStartIntervalSeconds"] = med
    facts["cadenceBreakIndices"] = gaps.enumerated().compactMap {
      $0.element > med * 1.5 ? $0.offset + 1 : nil
    }
  }
  return Canvas(rgb: output, w: w, h: h, facts: facts, frames: per)
}

func hdr(_ xs: [Input], _ recipe: Recipe) throws -> Canvas {
  let shutters = try xs.enumerated().map { i, x -> Double in
    guard let t = x.shutter, t > 0, near(x.iso, xs[0].iso), near(x.aperture, xs[0].aperture) else {
      throw RenderIssue("HDR requires measured shutter and constant ISO/aperture at index \(i)")
    }
    return t
  }
  guard let lo = shutters.min(), let hi = shutters.max(), hi / lo >= 1.5 else {
    throw RenderIssue("HDR bracket lacks distinct measured exposures")
  }
  let ref =
    recipe.referenceIndex
    ?? shutters.indices.sorted { shutters[$0] < shutters[$1] }[shutters.count / 2]
  let threshold = recipe.motionThreshold ?? 0.25
  guard xs.indices.contains(ref), (0.05...1).contains(threshold) else {
    throw RenderIssue("invalid HDR reference or deghost threshold")
  }
  let neutral = xs[ref].neutral
  let p = try makeProxy(xs[ref], neutral: neutral)
  let reference = try renderInput(xs[ref], neutral: neutral)
  let w = reference.1
  let h = reference.2
  let n = w * h
  let output = try FloatBuffer(3 * n)
  let weights = try FloatBuffer(n)
  var ghost = [UInt8](repeating: 0, count: n)
  var per = [Facts]()
  var total = [UInt64](repeating: 0, count: 2)
  let focal = (xs[ref].focal35 ?? 50) * hypot(Double(p.w), Double(p.h)) / hypot(36, 24)
  for i in xs.indices {
    var dx = 0.0
    var dy = 0.0
    var frame: Facts = ["registration": "reference"]
    if i != ref {
      let other = try makeProxy(xs[i], neutral: neutral)
      let (m, status) = try matches(p, other, focal: focal)
      if status == 0 && m.translationP95 <= 2.5 {
        dx = m.deltaX
        dy = m.deltaY
        frame = [
          "registration": "SIFT translation", "inliers": Int(m.inliers),
          "residualP95ProxyPixels": m.translationP95,
        ]
      } else {
        var t = [Double](repeating: 0, count: 3)
        guard gr_mtb(p.data, other.data, Int32(p.w), Int32(p.h), &t) == 0 else {
          throw RenderIssue(
            "HDR alignment unsupported at frozen index \(i) (features \(m.inliers), status \(status))"
          )
        }
        dx = t[0]
        dy = t[1]
        frame = ["registration": "median threshold bitmap translation", "binaryAgreement": t[2]]
      }
      dx *= Double(w) / Double(p.w)
      dy *= Double(h) / Double(p.h)
    }
    let ratio = shutters[ref] / shutters[i]
    try autoreleasepool {
      let im = i == ref ? reference : try renderInput(xs[i], neutral: neutral)
      try dimension(w, h, im)
      var c = [UInt64](repeating: 0, count: 3)
      gr_hdr(
        output.p, weights.p, &ghost, reference.0.p, im.0.p, Int32(w), Int32(h), dx, dy, ratio,
        i == ref ? 1 : 0, recipe.deghost == false ? Double.greatestFiniteMagnitude : threshold, &c)
      frame["validWeightedPixels"] = c[0]
      frame["motionDisagreements"] = c[1]
      frame["nearBlackOrClipPixels"] = c[2]
    }
    frame["translationFullPixels"] = [dx, dy]
    frame["exposureToReference"] = ratio
    per.append(frame)
  }
  gr_hdr_finish(output.p, weights.p, ghost, reference.0.p, Int32(n), &total)
  return Canvas(
    rgb: output, w: w, h: h,
    facts: [
      "referenceIndex": ref, "deghost": recipe.deghost ?? true,
      "motionThreshold": threshold, "motionReferencePixels": total[1],
      "motionOverlay": maskPreview(ghost, w, h) { $0 != 0 },
      "zeroWeightReferenceFallbackPixels": total[0],
      "response": "scene-linear radiance normalized to measured reference shutter",
      "validSignalRange": [0.002, 0.96],
    ], frames: per)
}

func matrix(_ m: GRMatch) -> simd_double3x3 {
  var r = m.rotation
  let v = withUnsafeBytes(of: &r) { Array($0.bindMemory(to: Double.self)) }
  return simd_double3x3(rows: [
    SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]),
  ])
}
func rowMajor(_ m: simd_double3x3) -> [Double] { (0..<9).map { m[$0 % 3][$0 / 3] } }
func gainEstimate(_ a: Proxy, _ b: Proxy, _ rotation: simd_double3x3, _ f: Double) -> Double {
  let cx = Double(a.w - 1) / 2
  let cy = Double(a.h - 1) / 2
  var logRatios = [Double]()
  for y in stride(from: 8, to: b.h - 8, by: 9) {
    for x in stride(from: 8, to: b.w - 8, by: 9) {
      let d = rotation * SIMD3((Double(x) - cx) / f, (Double(y) - cy) / f, 1)
      guard d.z > 0.1 else { continue }
      let sx = Int((f * d.x / d.z + cx).rounded())
      let sy = Int((f * d.y / d.z + cy).rounded())
      guard (0..<a.w).contains(sx), (0..<a.h).contains(sy) else { continue }
      let u = Double(a.data[sy * a.w + sx])
      let v = Double(b.data[y * b.w + x])
      if u > 24, u < 210, v > 24, v < 210 {
        logRatios.append(log(expm1(u / 255 * log(16)) / expm1(v / 255 * log(16))))
      }
    }
  }
  guard logRatios.count >= 32 else { return 1 }
  return min(2, max(0.5, exp(logRatios.sorted()[logRatios.count / 2])))
}

func panorama(_ xs: [Input], _ recipe: Recipe, _ scratch: URL) throws -> Canvas {
  let crop = recipe.crop ?? "validRectangle"
  let bands = recipe.bands ?? 4
  guard xs.count <= 32, (1...5).contains(bands), ["validRectangle", "bounds"].contains(crop),
    recipe.projection == nil || recipe.projection == "cylindrical"
  else { throw RenderIssue("unsupported panorama recipe") }
  guard let focal35 = xs[0].focal35, focal35 > 0, xs.allSatisfy({ near($0.focal35, focal35) })
  else {
    throw RenderIssue("panorama requires a fixed, measured 35 mm equivalent focal length")
  }
  let neutral = xs[xs.count / 2].neutral
  let proxies = try xs.map { try makeProxy($0, neutral: neutral) }
  let p = proxies[0]
  let pf = focal35 * hypot(Double(p.w), Double(p.h)) / hypot(36, 24)
  var poses = [matrix_identity_double3x3]
  var gain = [1.0]
  var edges = [Facts]()
  var constraints = [(Int, Int, simd_double3x3, Double)]()
  for i in 1..<xs.count {
    let (m, status) = try matches(proxies[i - 1], proxies[i], focal: pf)
    guard status == 0 else {
      throw RenderIssue(
        "panorama disconnected between frozen indices \(i-1),\(i) (inliers \(m.inliers), matches \(m.pairs), status \(status))"
      )
    }
    guard m.rotationP95 <= 5.0, m.secondaryMotionInliers == 0 else {
      throw RenderIssue(
        "panorama parallax or camera translation at pair \(i-1),\(i), rotation p95 \(m.rotationP95) proxy px; secondary motion inliers \(m.secondaryMotionInliers)"
      )
    }
    let r = matrix(m)
    poses.append(poses[i - 1] * r)
    constraints.append((i - 1, i, r, Double(m.inliers)))
    gain.append(gain[i - 1] * gainEstimate(proxies[i - 1], proxies[i], r, pf))
    edges.append([
      "indices": [i - 1, i], "ratioMatches": m.pairs, "inliers": m.inliers,
      "featureSupport": m.support, "secondaryMotionInliers": m.secondaryMotionInliers,
      "homographyP50ProxyPixels": m.p50, "homographyP95ProxyPixels": m.p95,
      "rotationP95ProxyPixels": m.rotationP95,
    ])
  }
  // Additional skip-one overlaps constrain accumulated error. Keep every adjacent edge and every frame.
  if xs.count >= 3 {
    for i in 2..<xs.count {
      let (m, status) = try matches(proxies[i - 2], proxies[i], focal: pf)
      if status == 0, m.rotationP95 <= 5 {
        let rotation = matrix(m)
        let delta = simd_quatd((poses[i - 2] * rotation).transpose * poses[i]).angle
        if min(delta, 2 * Double.pi - delta) < 0.04 {
          constraints.append((i - 2, i, rotation, Double(m.inliers)))
          edges.append([
            "indices": [i - 2, i], "closure": true, "inliers": m.inliers,
            "rotationP95ProxyPixels": m.rotationP95,
          ])
        }
      }
    }
  }
  let anchor = xs.count / 2
  let origin = poses[anchor].transpose
  poses = poses.map { origin * $0 }
  if constraints.count > xs.count - 1 {
    for _ in 0..<8 {
      var next = poses
      for i in xs.indices where i != anchor {
        let current = simd_quatd(poses[i])
        var v = current.vector * 100
        var weight = 100.0
        for (a, b, r, n) in constraints where i == a || i == b {
          let q = simd_quatd(i == a ? poses[b] * r.transpose : poses[a] * r)
          v += (simd_dot(current.vector, q.vector) < 0 ? -q.vector : q.vector) * n
          weight += n
        }
        next[i] = simd_double3x3(simd_quatd(vector: simd_normalize(v / weight)))
      }
      poses = next
    }
  }
  let midGain = gain[anchor]
  gain = gain.map { min(2, max(0.5, $0 / midGain)) }
  var decoded = [FloatBuffer]()
  var w = 0
  var h = 0
  for (i, x) in xs.enumerated() {
    let im = try renderInput(
      x, neutral: neutral, scratch: scratch.appendingPathComponent("pixels-\(i)"))
    if i > 0 { try dimension(w, h, im) }
    w = im.1
    h = im.2
    decoded.append(im.0)
  }
  let f = focal35 * hypot(Double(w), Double(h)) / hypot(36, 24)
  let rot = poses.map(rowMajor)
  var minX = Double.infinity
  var minY = Double.infinity
  var maxX = -Double.infinity
  var maxY = -Double.infinity
  for r in rot {
    var b = [Double](repeating: 0, count: 4)
    guard gr_bounds(r, Int32(w), Int32(h), f, &b) == 0 else {
      throw RenderIssue("panorama cylinder reaches unsupported pole")
    }
    minX = min(minX, b[0])
    minY = min(minY, b[1])
    maxX = max(maxX, b[2])
    maxY = max(maxY, b[3])
  }
  let ox = Int(floor(minX))
  let oy = Int(floor(minY))
  let cw = Int(ceil(maxX)) - ox + 1
  let ch = Int(ceil(maxY)) - oy + 1
  guard cw > 0, ch > 0, cw * ch <= 200_000_000, Double(cw) < 2 * Double.pi * f else {
    throw RenderIssue("panorama canvas exceeds the supported geometry")
  }
  let image = try FloatBuffer(3 * cw * ch)
  var coverage = [UInt8](repeating: 0, count: cw * ch)
  let halo = 4 * (1 << bands)
  var overlap = 0
  var holes = 0
  for by in stride(from: 0, to: ch, by: 256) {
    for bx in stride(from: 0, to: cw, by: 512) {
      let left = max(0, bx - halo)
      let top = max(0, by - halo)
      let iw = min(512, cw - bx)
      let ih = min(256, ch - by)
      let tw = min(cw, bx + iw + halo) - left
      let th = min(ch, by + ih + halo) - top
      let n = tw * th
      let warps = try FloatBuffer(3 * n * xs.count)
      let weights = try FloatBuffer(n * xs.count)
      let tile = try FloatBuffer(3 * n)
      for i in xs.indices {
        gr_cylinder(
          decoded[i].p, Int32(w), Int32(h), rot[i], f, Int32(ox + left), Int32(oy + top), Int32(tw),
          Int32(th),
          Float(gain[i]), warps.p.advanced(by: 3 * n * i), weights.p.advanced(by: n * i))
      }
      var cover = [UInt8](repeating: 0, count: n)
      gr_blend_bands(
        tile.p, warps.p, weights.p, Int32(xs.count), Int32(tw), Int32(th), Int32(bands), &cover)
      for j in 0..<ih {
        let dest = (by + j) * cw + bx
        let src = (by + j - top) * tw + bx - left
        image.p.advanced(by: 3 * dest).update(from: tile.p.advanced(by: 3 * src), count: 3 * iw)
        for x in 0..<iw {
          let v = cover[src + x]
          coverage[dest + x] = v
          if v > 1 { overlap += 1 }
          if v == 0 { holes += 1 }
        }
      }
    }
  }
  guard overlap > cw * ch / 100 else {
    throw RenderIssue("panorama has insufficient overlapping output support")
  }
  var rect: [Int32] = [0, 0, Int32(cw), Int32(ch)]
  if crop == "validRectangle" { gr_valid_rect(coverage, Int32(cw), Int32(ch), &rect) }
  let rw = Int(rect[2])
  let rh = Int(rect[3])
  guard rw > 1, rh > 1 else { throw RenderIssue("panorama has no valid output rectangle") }
  let out: FloatBuffer
  if rw == cw && rh == ch {
    out = image
  } else {
    out = try FloatBuffer(3 * rw * rh)
    for y in 0..<rh {
      out.p.advanced(by: 3 * y * rw).update(
        from: image.p.advanced(by: 3 * ((y + Int(rect[1])) * cw + Int(rect[0]))), count: 3 * rw)
    }
  }
  let per: [Facts] = xs.indices.map {
    ["cameraToReferenceRotationRowMajor": rot[$0], "appliedGain": gain[$0]]
  }
  return Canvas(
    rgb: out, w: rw, h: rh,
    facts: [
      "projection": "cylindrical",
      "registration": "mutual SIFT, RANSAC homography, calibrated rotation",
      "focalLength35mm": focal35, "referenceIndex": anchor, "overlapEdges": edges, "bands": bands,
      "blend": "scene-linear float Laplacian pyramid, Gaussian edge weights",
      "geometryProxySize": [p.w, p.h],
      "uncroppedSize": [cw, ch], "cylinderOrigin": [ox, oy], "crop": crop, "cropRect": rect,
      "uncroppedEmptyPixels": holes,
      "uncroppedOverlapPixels": overlap,
      "coverageOverlay": maskPreview(coverage, cw, ch) { $0 > 0 },
      "uncoveredPolicy": "zero only outside measured coverage",
    ], frames: per)
}
