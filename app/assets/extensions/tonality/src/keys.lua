-- Keys. A key is its tonic and whether it is minor. The tonic is counted in fifths from C
-- along the line of fifths: G is 1, F is -1, F♯ is 6, B♭ is -2. The keys there are have a key
-- signature of seven sharps or flats at most.

local M = {}

--- The tonic of the key whose key signature has that many fifths (sharps up, flats down).
function M.of(signature, minor)
  return minor and signature + 3 or signature
end

--- A key's key signature, in fifths: sharps up, flats down.
function M.signature(tonic, minor)
  return minor and tonic - 3 or tonic
end

--- Whether there is such a key: seven sharps or flats at most.
function M.valid(tonic, minor)
  local signature = M.signature(tonic, minor)
  return signature >= -7 and signature <= 7
end

--- The tonic's pitch class: C is 0, B is 11.
function M.pitch_class(tonic)
  return tonic * 7 % 12
end

--- The tonic as written, a letter and its accidental: C, F♯, B♭.
function M.tonic_name(tonic)
  local i = tonic + 1 -- F 0, C 1 … B 6
  local accidentals = i // 7
  local letter = ("FCGDAEB"):sub(i % 7 + 1, i % 7 + 1)
  return letter .. (accidentals > 0 and ("♯"):rep(accidentals) or ("♭"):rep(-accidentals))
end

--- A key's name in English: "F major", "C♯ minor".
function M.name(tonic, minor)
  return M.tonic_name(tonic) .. " " .. (minor and "minor" or "major")
end

--- A key's name in the interface's language.
function M.label(tonic, minor)
  return curator.tr(M.name(tonic, minor))
end

-- The sRGB colour of OKLCH lightness l, chroma c and hue (degrees), clipped to sRGB.
local function oklch(l, c, hue)
  local h = hue * math.pi / 180
  local a, b = c * math.cos(h), c * math.sin(h)
  local function cube(v) return v * v * v end
  local l3 = cube(l + 0.3963377774 * a + 0.2158037573 * b)
  local m3 = cube(l - 0.1055613458 * a - 0.0638541728 * b)
  local s3 = cube(l - 0.0894841775 * a - 1.2914855480 * b)
  local function encoded(v)
    v = math.clamp(v, 0.0, 1.0)
    return v <= 0.0031308 and 12.92 * v or 1.055 * v ^ (1 / 2.4) - 0.055
  end
  return {
    r = encoded(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
    g = encoded(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
    b = encoded(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
  }
end

local colors = {}

--- A key's colour in the band and the lane: its tonic's place on the circle of fifths as a
--- hue, so keys a fifth apart are neighbours (the sharp keys cool, the flat ones warm) and two
--- spelled differently (F♯, G♭) are one colour; a minor key darker than a major one. Every one
--- is as light as the others, so the paper-coloured names on them read alike.
function M.color(tonic, minor)
  local place = tonic % 12
  local id = minor and place + 12 or place
  if not colors[id] then
    colors[id] = oklch(minor and 0.52 or 0.64, minor and 0.085 or 0.1, 130.0 + 30 * place)
  end
  return colors[id]
end

--- Every key: each key signature's major key and its minor, C♭ major to C♯ major and A♭ minor
--- to A♯ minor, in the order of their signatures. Each {tonic, minor}.
M.all = {}
for signature = -7, 7 do
  M.all[#M.all + 1] = {tonic = M.of(signature, false), minor = false}
  M.all[#M.all + 1] = {tonic = M.of(signature, true), minor = true}
end

--- Where a key is in M.all.
function M.index(tonic, minor)
  for i, key in ipairs(M.all) do
    if key.tonic == tonic and key.minor == minor then return i end
  end
end

return M
