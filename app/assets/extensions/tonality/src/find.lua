-- Find Keys: where the music is in which key.
--
-- Each bar is heard as how long each pitch class sounds in it and the bars either side (the
-- lowest note of each chord counting twice), and is most like one key's profile. A key is held
-- until the music has been in another for long enough to outweigh changing twice, and the key
-- signature in force leans toward its own major and minor, toward the one the score names
-- most. A change heard a bar or two from a change of key signature is moved to it, and a key
-- is spelled as near the key signature as it can be (G♭ major among flats, F♯ major among
-- sharps). A score without notes (a PDF's) has its key signatures' keys, major unless they say
-- minor; one without bars, none.
--
-- (Bars, pitch classes and keys are counted from 0 here: keys 0–11 are major on C…B, 12–23
-- minor.)

local keys = require("keys")

local M = {}

-- Krumhansl and Kessler's profiles: how well each pitch class from the tonic up fits a major
-- and a minor key, as listeners rated them.
local MAJOR = {6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88}
local MINOR = {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17}

-- What a change of key costs, in bars' likeness (a quarter's worth of a key's correlation
-- with the music): the music has to be in another key for a few bars, more for one it soon
-- leaves again.
local CHANGE_COST = 6.0

-- How much the key signature in force leans toward its own two keys, a quarter's worth, and
-- toward the one the score names.
local SIGNATURE_LEAN, MODE_LEAN = 0.08, 0.14

-- How much the bars either side count in what a bar is heard as.
local WINDOW = {[-2] = 0.25, [-1] = 0.5, [0] = 1.0, [1] = 0.5, [2] = 0.25}

-- Pearson's correlation of two lists of twelve (from 0).
local function correlation(a, b)
  local mean_a, mean_b = 0.0, 0.0
  for i = 0, 11 do
    mean_a = mean_a + a[i]
    mean_b = mean_b + b[i]
  end
  mean_a = mean_a / 12
  mean_b = mean_b / 12
  local ab, aa, bb = 0.0, 0.0, 0.0
  for i = 0, 11 do
    local x, y = a[i] - mean_a, b[i] - mean_b
    ab = ab + x * y
    aa = aa + x * x
    bb = bb + y * y
  end
  if aa <= 0 or bb <= 0 then return 0.0 end
  return ab / math.sqrt(aa * bb)
end

-- The key on a pitch class, spelled with its key signature as near `near` fifths as it can be.
local function spelled(pitch_class, minor, near)
  local tonic = pitch_class * 7 % 12 -- the inverse of fifths → pitch class: 7 × 7 ≡ 1 (mod 12)
  local best
  for _, t in ipairs({tonic - 12, tonic, tonic + 12}) do
    if keys.valid(t, minor) then
      local signature = keys.signature(t, minor)
      local distance = math.abs(signature - near)
      local best_distance = best and math.abs(keys.signature(best, minor) - near) or 99
      if distance < best_distance or (distance == best_distance and math.abs(signature) < math.abs(keys.signature(best, minor))) then
        best = t
      end
    end
  end
  return best
end

--- The keys of the music (what score.music gives), as key areas from bar to bar, each up to
--- the next, the last to the end: {from, to, tonic, minor}.
function M.keys(music)
  -- Where each bar starts, from 0; the score's end last.
  local starts, count = {}, #music.bars
  for i, start in ipairs(music.bars) do starts[i - 1] = start end
  local bars = count - 1
  if bars <= 0 then return {} end

  local signatures = {}
  for i, key in ipairs(music.keys) do
    signatures[i] = {measure = key.bar - 1, fifths = key.fifths, minor = key.minor}
  end

  local notes = music.notes
  if #notes == 0 then
    -- Nothing to hear (a PDF score's): the key signatures alone, major unless they say minor.
    local in_score = {}
    for _, s in ipairs(signatures) do
      if s.measure < bars then in_score[#in_score + 1] = s end
    end
    local found = {}
    for i, s in ipairs(in_score) do
      local minor = s.minor or false
      found[i] = {
        from = starts[i == 1 and 0 or s.measure],
        to = starts[in_score[i + 1] and in_score[i + 1].measure or bars],
        tonic = keys.of(s.fifths, minor),
        minor = minor,
      }
    end
    return found
  end

  -- The bar a place is in: the last that starts at or before it.
  local function bar_at(at)
    local lo, hi = 0, count - 1
    while hi - lo > 1 do
      local mid = (lo + hi) // 2
      if starts[mid] <= at then lo = mid else hi = mid end
    end
    return lo
  end

  -- How long each pitch class sounds in each bar, in quarters.
  local heard = {}
  for b = 0, bars - 1 do
    local row = {}
    for pc = 0, 11 do row[pc] = 0.0 end
    heard[b] = row
  end
  local function sound(pc, from, to)
    local b = bar_at(from)
    while b < bars and starts[b] < to do
      local overlap = math.min(to, starts[b + 1]) - math.max(from, starts[b])
      if overlap > 0 then heard[b][pc] = heard[b][pc] + overlap end
      b = b + 1
    end
  end

  -- The lowest note of those that start together, in the order they first come.
  local lowest, onsets = {}, {}
  for _, n in ipairs(notes) do
    if n.to > n.from then
      sound(n.pitch % 12, n.from, n.to)
      if not n.tied then
        local onset = math.round(n.from * 1e4)
        local low = lowest[onset]
        if not (low and low.pitch <= n.pitch) then
          if not low then onsets[#onsets + 1] = onset end
          lowest[onset] = n
        end
      end
    end
  end
  for _, onset in ipairs(onsets) do
    local n = lowest[onset]
    sound(n.pitch % 12, n.from, n.to)
  end

  -- Each bar's likeness to each key, heard with the bars either side, as its correlation with
  -- the key's profile.
  local profiles = {}
  for mode, profile in ipairs({MAJOR, MINOR}) do
    for tonic = 0, 11 do
      local of_key = {}
      for pc = 0, 11 do of_key[pc] = profile[(pc - tonic) % 12 + 1] end
      profiles[(mode - 1) * 12 + tonic] = of_key
    end
  end
  local likeness = {}
  for b = 0, bars - 1 do
    local row = {}
    for k = 0, 23 do row[k] = 0.0 end
    likeness[b] = row
    local h = {}
    for pc = 0, 11 do h[pc] = 0.0 end
    for d = -2, 2 do
      if b + d >= 0 and b + d < bars then
        for pc = 0, 11 do h[pc] = h[pc] + heard[b + d][pc] * WINDOW[d] end
      end
    end
    local silent = true -- silence: no key more than another
    for pc = 0, 11 do
      if h[pc] ~= 0 then silent = false end
    end
    if not silent then
      for k = 0, 23 do row[k] = correlation(h, profiles[k]) end
    end
  end

  -- The key signature in force at each bar.
  local signature_at = {}
  for i, s in ipairs(signatures) do
    local stop = signatures[i + 1] and signatures[i + 1].measure or bars
    for b = math.max(0, s.measure), math.min(stop, bars) - 1 do signature_at[b] = s end
  end
  if #signatures > 0 then
    for b = 0, math.min(signatures[1].measure, bars) - 1 do signature_at[b] = signatures[1] end
  end

  -- The likeliest keys through the piece (Viterbi): each bar weighs as long as it lasts.
  local total, from = {}, {}
  for k = 0, 23 do total[k] = 0.0 end
  for b = 0, bars - 1 do
    local length = math.clamp(starts[b + 1] - starts[b], 0.25, 16.0)
    local signature = signature_at[b]
    local best = 0
    for k = 1, 23 do
      if total[k] > total[best] then best = k end
    end
    local before = {}
    for k = 0, 23 do before[k] = total[k] end
    local came = {}
    from[b] = came
    for k = 0, 23 do
      local stay = before[k]
      local change = b == 0 and before[k] or before[best] - CHANGE_COST
      came[k] = stay >= change and k or best
      local lean = 0.0
      if signature then
        local minor = k >= 12
        if k % 12 == keys.pitch_class(keys.of(signature.fifths, minor)) then
          if signature.minor == minor then
            lean = MODE_LEAN
          elseif signature.minor == nil then
            lean = SIGNATURE_LEAN
          else
            lean = SIGNATURE_LEAN / 2
          end
        end
      end
      total[k] = math.max(stay, change) + length * (likeness[b][k] + lean)
    end
  end
  local key_of = {}
  local k = 0
  for i = 1, 23 do
    if total[i] > total[k] then k = i end
  end
  for b = bars - 1, 0, -1 do
    key_of[b] = k
    k = from[b][k]
  end

  -- Where the key changes; one heard a bar or two from a change of key signature (the bars
  -- either side lean it early or late) moves there.
  local changes = {}
  for b = 0, bars - 1 do
    if b == 0 or key_of[b] ~= key_of[b - 1] then changes[#changes + 1] = {bar = b, key = key_of[b]} end
  end
  local signed = {}
  for _, s in ipairs(signatures) do
    if s.measure > 0 and s.measure < bars then signed[s.measure] = true end
  end
  for i = 2, #changes do
    local b = changes[i].bar
    local lo = changes[i - 1].bar + 1
    local hi = changes[i + 1] and changes[i + 1].bar - 1 or bars - 1
    local near
    for _, s in ipairs({b, b - 1, b + 1, b - 2, b + 2}) do
      if not near and s >= lo and s <= hi and signed[s] then near = s end
    end
    if near then changes[i] = {bar = near, key = changes[i].key} end
  end

  local found = {}
  for i, change in ipairs(changes) do
    local minor = change.key >= 12
    local signature = signature_at[change.bar]
    found[i] = {
      from = starts[change.bar],
      to = starts[changes[i + 1] and changes[i + 1].bar or bars],
      tonic = spelled(change.key % 12, minor, signature and signature.fifths or 0),
      minor = minor,
    }
  end
  return found
end

return M
