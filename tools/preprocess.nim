import std/[os, math, memfiles, strutils]

const D = 14
const ExpectedN = 3_000_000
const DefaultIvfClusters = 4096
const DefaultIvfNProbe = 24
const MaxIvfNProbe = 24
const DefaultIvfSample = 65_536
const DefaultIvfIterations = 25

const IvfMagic = "RIVF2026"

proc envInt(name: string; defaultValue: int): int =
  let raw = getEnv(name, "")
  if raw.len == 0:
    return defaultValue
  try:
    result = parseInt(raw)
    if result <= 0:
      result = defaultValue
  except ValueError:
    result = defaultValue

const
  Q16Scale = 32767.0'f64
  RefineStep = 128
  RefineScale = Q16Scale * float64(RefineStep)
  RefineMin = -32767 * RefineStep
  RefineMax = 32767 * RefineStep

proc f32ToRefinedParts(x: float32): tuple[hi: uint16, lo: uint8] {.inline.} =
  let hiScaled = round(float64(x) * Q16Scale)
  let hi32 = int32(max(-32767.0, min(32767.0, hiScaled)))
  let refinedScaled = round(float64(x) * RefineScale)
  let refined = int32(max(float64(RefineMin), min(float64(RefineMax), refinedScaled)))
  let residual = max(-128, min(127, refined - hi32 * RefineStep))
  (cast[uint16](int16(hi32)), cast[uint8](int8(residual)))

proc q16ToF32(h: uint16): float32 {.inline.} =
  float32(cast[int16](h))

proc writeU32LE(f: File; value: uint32) =
  var bytes: array[4, uint8]
  bytes[0] = uint8(value and 0xff'u32)
  bytes[1] = uint8((value shr 8) and 0xff'u32)
  bytes[2] = uint8((value shr 16) and 0xff'u32)
  bytes[3] = uint8((value shr 24) and 0xff'u32)
  if f.writeBuffer(addr bytes[0], 4) != 4:
    quit("short write while writing u32", 1)

proc writeF32LE(f: File; value: float32) {.inline.} =
  writeU32LE(f, cast[uint32](value))

proc nearestCentroidSample(
  sample: seq[float32];
  sampleOffset: int;
  centroids: seq[float32];
  clusterCount: int
): int {.inline.} =
  var best = 0
  var bestDist = 1.0e30'f32
  var c = 0
  while c < clusterCount:
    let base = c * D
    var dist = 0.0'f32
    var d = 0
    while d < D:
      let diff = sample[sampleOffset + d] - centroids[base + d]
      dist += diff * diff
      inc d
    if dist < bestDist:
      bestDist = dist
      best = c
    inc c
  best

proc nearestCentroidVector(
  vectors: var array[D, seq[uint16]];
  idx: int;
  centroids: seq[float32];
  clusterCount: int
): int {.inline.} =
  var point: array[D, float32]
  var d = 0
  while d < D:
    point[d] = q16ToF32(vectors[d][idx])
    inc d

  var best = 0
  var bestDist = 1.0e30'f32
  var c = 0
  while c < clusterCount:
    let base = c * D
    var dist = 0.0'f32
    d = 0
    while d < D:
      let diff = point[d] - centroids[base + d]
      dist += diff * diff
      inc d
    if dist < bestDist:
      bestDist = dist
      best = c
    inc c
  best

proc trainIvf(
  vectors: var array[D, seq[uint16]];
  n: int;
  clusterCount: int;
  sampleCountWanted: int;
  iterations: int
): seq[float32] =
  let sampleCount = min(n, max(clusterCount, sampleCountWanted))
  echo "training IVF: clusters=", clusterCount,
       " sample=", sampleCount,
       " iterations=", iterations

  var sample = newSeq[float32](sampleCount * D)
  var seed = 0x9e3779b97f4a7c15'u64
  var s = 0
  while s < sampleCount:
    seed = seed * 2862933555777941757'u64 + 3037000493'u64
    let idx = int(seed mod uint64(n))
    var d = 0
    while d < D:
      sample[s * D + d] = q16ToF32(vectors[d][idx])
      inc d
    inc s

  var centroids = newSeq[float32](clusterCount * D)
  var c = 0
  while c < clusterCount:
    let sampleBase = ((c * sampleCount) div clusterCount) * D
    let dstBase = c * D
    var d = 0
    while d < D:
      centroids[dstBase + d] = sample[sampleBase + d]
      inc d
    inc c

  var sums = newSeq[float32](clusterCount * D)
  var counts = newSeq[int](clusterCount)
  var iter = 0
  while iter < iterations:
    var i = 0
    while i < sums.len:
      sums[i] = 0.0'f32
      inc i
    i = 0
    while i < counts.len:
      counts[i] = 0
      inc i

    s = 0
    while s < sampleCount:
      let sampleOffset = s * D
      let nearest = nearestCentroidSample(sample, sampleOffset, centroids, clusterCount)
      inc counts[nearest]
      let base = nearest * D
      var d = 0
      while d < D:
        sums[base + d] += sample[sampleOffset + d]
        inc d
      inc s

    c = 0
    while c < clusterCount:
      let base = c * D
      if counts[c] > 0:
        let inv = 1.0'f32 / float32(counts[c])
        var d = 0
        while d < D:
          centroids[base + d] = sums[base + d] * inv
          inc d
      else:
        let sampleBase = (((iter + 1) * 131 + c * 17) mod sampleCount) * D
        var d = 0
        while d < D:
          centroids[base + d] = sample[sampleBase + d]
          inc d
      inc c

    echo "  kmeans iteration ", iter + 1, "/", iterations
    inc iter

  centroids

proc buildAssignments(
  vectors: var array[D, seq[uint16]];
  n: int;
  centroids: var seq[float32];
  clusterCount: int
): tuple[assignments: seq[uint16], boundaries: seq[uint32]] =
  echo "assigning ", n, " vectors to IVF clusters"
  var assignments = newSeq[uint16](n)
  var counts = newSeq[int](clusterCount)
  var sums = newSeq[float32](clusterCount * D)

  var i = 0
  while i < n:
    let nearest = nearestCentroidVector(vectors, i, centroids, clusterCount)
    assignments[i] = uint16(nearest)
    inc counts[nearest]
    let base = nearest * D
    var d = 0
    while d < D:
      sums[base + d] += q16ToF32(vectors[d][i])
      inc d
    inc i
    if (i mod 250_000) == 0:
      echo "  assigned ", i, " vectors"

  var boundaries = newSeq[uint32](clusterCount + 1)
  var running = 0
  var c = 0
  while c < clusterCount:
    boundaries[c] = uint32(running)
    running += counts[c]

    let base = c * D
    if counts[c] > 0:
      let inv = 1.0'f32 / float32(counts[c])
      var d = 0
      while d < D:
        centroids[base + d] = sums[base + d] * inv
        inc d
    inc c
  boundaries[clusterCount] = uint32(running)
  if running != n:
    quit("assignment count mismatch", 1)

  (assignments, boundaries)

proc buildClusterRadii(
  vectors: var array[D, seq[uint16]];
  assignments: seq[uint16];
  centroids: seq[float32];
  clusterCount: int
): seq[float32] =
  echo "measuring IVF cluster radii"
  var radiiSq = newSeq[float32](clusterCount)

  var i = 0
  while i < assignments.len:
    let cluster = int(assignments[i])
    let base = cluster * D
    var dist = 0.0'f32
    var d = 0
    while d < D:
      let diff = q16ToF32(vectors[d][i]) - centroids[base + d]
      dist += diff * diff
      inc d
    if dist > radiiSq[cluster]:
      radiiSq[cluster] = dist
    inc i
    if (i mod 500_000) == 0:
      echo "  measured ", i, " vectors"

  result = newSeq[float32](clusterCount)
  for cluster in 0..<clusterCount:
    result[cluster] = sqrt(radiiSq[cluster])

proc writeIvfIndex(
  outPath: string;
  centroids: seq[float32];
  radii: seq[float32];
  boundaries: seq[uint32];
  clusterCount: int;
  nprobe: int;
  n: int
) =
  echo "writing ", outPath,
       " (", centroids.len * 4 + radii.len * 4 + boundaries.len * 4 + 28, " bytes)"
  var outIdx = system.open(outPath, fmWrite)
  outIdx.write(IvfMagic)
  writeU32LE(outIdx, uint32(D))
  writeU32LE(outIdx, uint32(clusterCount))
  writeU32LE(outIdx, uint32(nprobe))
  writeU32LE(outIdx, uint32(n))
  writeU32LE(outIdx, 0'u32)

  var i = 0
  while i < centroids.len:
    writeF32LE(outIdx, centroids[i])
    inc i
  i = 0
  while i < radii.len:
    writeF32LE(outIdx, radii[i])
    inc i
  i = 0
  while i < boundaries.len:
    writeU32LE(outIdx, boundaries[i])
    inc i
  outIdx.close()

template skipWs(s: cstring; n: int; p: var int) =
  while p < n:
    let c = s[p]
    if c == ' ' or c == '\n' or c == '\r' or c == '\t':
      inc p
    else:
      break

proc parseNumberFast(s: cstring; n: int; p: var int): float64 =
  skipWs(s, n, p)
  var sign = 1.0
  if p < n and s[p] == '-':
    sign = -1.0
    inc p
  elif p < n and s[p] == '+':
    inc p

  var v = 0.0
  while p < n and s[p] >= '0' and s[p] <= '9':
    v = v * 10.0 + float64(ord(s[p]) - ord('0'))
    inc p

  if p < n and s[p] == '.':
    inc p
    var scale = 0.1
    while p < n and s[p] >= '0' and s[p] <= '9':
      v += float64(ord(s[p]) - ord('0')) * scale
      scale *= 0.1
      inc p

  if p < n and (s[p] == 'e' or s[p] == 'E'):
    inc p
    var expSign = 1
    if s[p] == '-':
      expSign = -1
      inc p
    elif s[p] == '+':
      inc p
    var ev = 0
    while p < n and s[p] >= '0' and s[p] <= '9':
      ev = ev * 10 + (ord(s[p]) - ord('0'))
      inc p
    v *= pow(10.0, float64(expSign * ev))

  sign * v

proc main() =
  if paramCount() != 5:
    quit("usage: preprocess <input.json> <vectors.bin> <labels.bin> <residuals.bin> <ivf.bin>", 1)

  let inPath = paramStr(1)
  let outVecPath = paramStr(2)
  let outLblPath = paramStr(3)
  let outResidualPath = paramStr(4)
  let outIvfPath = paramStr(5)
  let clusterCount = envInt("IVF_CLUSTERS", DefaultIvfClusters)
  let nprobe = min(clusterCount, min(MaxIvfNProbe, envInt("IVF_NPROBE", DefaultIvfNProbe)))
  let sampleCount = envInt("IVF_SAMPLE", DefaultIvfSample)
  let iterations = envInt("IVF_ITERATIONS", DefaultIvfIterations)

  if clusterCount > int(high(uint16)):
    quit("IVF_CLUSTERS must fit in uint16", 1)

  echo "opening ", inPath
  var mf = memfiles.open(inPath, mode = fmRead)
  let raw = cast[cstring](mf.mem)
  let total = mf.size
  echo "mapped ", total, " bytes"

  var vectors: array[D, seq[uint16]]
  var residuals: array[D, seq[uint8]]
  for d in 0..<D:
    vectors[d] = newSeqOfCap[uint16](ExpectedN)
    residuals[d] = newSeqOfCap[uint8](ExpectedN)
  var labels = newSeqOfCap[uint8](ExpectedN)

  var p = 0
  skipWs(raw, total, p)
  if p >= total or raw[p] != '[':
    quit("expected top-level array", 1)
  inc p

  var n = 0
  while true:
    skipWs(raw, total, p)
    if p >= total: break
    if raw[p] == ']':
      break
    if raw[p] == ',':
      inc p
      continue
    if raw[p] != '{':
      quit("expected object at offset " & $p, 1)
    inc p

    var dimIdx = 0
    var currentVec: array[D, uint16]
    var currentResidual: array[D, uint8]
    var labelByte: uint8 = 0
    var sawVector = false
    var sawLabel = false

    while true:
      skipWs(raw, total, p)
      if p >= total: quit("unexpected EOF in object", 1)
      if raw[p] == '}':
        inc p
        break
      if raw[p] == ',':
        inc p
        continue

      if raw[p] != '"':
        quit("expected key string at " & $p, 1)
      inc p
      let keyStart = p
      while p < total and raw[p] != '"':
        inc p
      let keyLen = p - keyStart
      inc p

      skipWs(raw, total, p)
      if p >= total or raw[p] != ':':
        quit("expected colon", 1)
      inc p

      if keyLen == 6 and raw[keyStart] == 'v':
        skipWs(raw, total, p)
        if raw[p] != '[':
          quit("expected vector array", 1)
        inc p
        dimIdx = 0
        while true:
          skipWs(raw, total, p)
          if raw[p] == ']':
            inc p
            break
          if raw[p] == ',':
            inc p
            continue
          let v = parseNumberFast(raw, total, p)
          if dimIdx < D:
            let parts = f32ToRefinedParts(float32(v))
            currentVec[dimIdx] = parts.hi
            currentResidual[dimIdx] = parts.lo
          inc dimIdx
        sawVector = true
      elif keyLen == 5 and raw[keyStart] == 'l':
        skipWs(raw, total, p)
        if raw[p] != '"':
          quit("expected label string", 1)
        inc p

        if p < total and raw[p] == 'f':
          labelByte = 1'u8
        else:
          labelByte = 0'u8
        while p < total and raw[p] != '"':
          inc p
        inc p
        sawLabel = true
      else:
        skipWs(raw, total, p)
        let c = raw[p]
        if c == '"':
          inc p
          while p < total and raw[p] != '"': inc p
          inc p
        elif c == '[' or c == '{':
          let openCh = c
          let closeCh = if c == '[': ']' else: '}'
          var depth = 1
          inc p
          while p < total and depth > 0:
            if raw[p] == '"':
              inc p
              while p < total and raw[p] != '"': inc p
              inc p
            elif raw[p] == openCh:
              inc depth
              inc p
            elif raw[p] == closeCh:
              dec depth
              inc p
            else:
              inc p
        else:
          while p < total and raw[p] != ',' and raw[p] != '}':
            inc p

    if not sawVector or not sawLabel:
      quit("record missing vector or label", 1)

    for d in 0..<D:
      vectors[d].add(currentVec[d])
      residuals[d].add(currentResidual[d])
    labels.add(labelByte)
    inc n

    if (n mod 250_000) == 0:
      echo "  processed ", n, " records"

  echo "total parsed: ", n, " records"

  if n == 0:
    quit("no records parsed", 1)

  if clusterCount > n:
    quit("IVF_CLUSTERS cannot exceed record count", 1)

  var centroids = trainIvf(vectors, n, clusterCount, sampleCount, iterations)
  let (assignments, boundaries) = buildAssignments(vectors, n, centroids, clusterCount)
  let radii = buildClusterRadii(vectors, assignments, centroids, clusterCount)

  echo "writing ", outVecPath, " (", n * D * 2, " bytes)"
  var outVec = system.open(outVecPath, fmWrite)
  var positions = newSeq[int](clusterCount)
  var sortedDim = newSeq[uint16](n)
  for d in 0..<D:
    for c in 0..<clusterCount:
      positions[c] = int(boundaries[c])
    var i = 0
    while i < n:
      let c = int(assignments[i])
      let pos = positions[c]
      sortedDim[pos] = vectors[d][i]
      positions[c] = pos + 1
      inc i
    let written = outVec.writeBuffer(addr sortedDim[0], n * 2)
    if written != n * 2:
      quit("short write on vectors.bin", 1)
  outVec.close()

  echo "writing ", outResidualPath, " (", n * D, " bytes)"
  var outResidual = system.open(outResidualPath, fmWrite)
  var sortedResidual = newSeq[uint8](n)
  for d in 0..<D:
    for c in 0..<clusterCount:
      positions[c] = int(boundaries[c])
    var i = 0
    while i < n:
      let c = int(assignments[i])
      let pos = positions[c]
      sortedResidual[pos] = residuals[d][i]
      positions[c] = pos + 1
      inc i
    let written = outResidual.writeBuffer(addr sortedResidual[0], n)
    if written != n:
      quit("short write on residuals.bin", 1)
  outResidual.close()

  echo "writing ", outLblPath, " (", n, " bytes)"
  var outLbl = system.open(outLblPath, fmWrite)
  var sortedLabels = newSeq[uint8](n)
  for c in 0..<clusterCount:
    positions[c] = int(boundaries[c])
  var i = 0
  while i < n:
    let c = int(assignments[i])
    let pos = positions[c]
    sortedLabels[pos] = labels[i]
    positions[c] = pos + 1
    inc i
  let writtenL = outLbl.writeBuffer(addr sortedLabels[0], n)
  if writtenL != n:
    quit("short write on labels.bin", 1)
  outLbl.close()

  writeIvfIndex(outIvfPath, centroids, radii, boundaries, clusterCount, nprobe, n)

  mf.close()
  echo "done"

main()