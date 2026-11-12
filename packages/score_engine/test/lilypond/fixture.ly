\version "2.26.0"
% What LilyPondScore is tested on: fixture.svg and fixture.jsonl are LilyPond 2.26.0's engraving of
% this with Curator's settings (app/assets/lilypond/curator.ly), made in this folder by
%   CURATOR_LILYPOND_DATA=$PWD/fixture.jsonl lilypond --loglevel=WARN -dbackend=svg -fsvg \
%     -dinclude-settings=$PWD/../../../../app/assets/lilypond/curator.ly -o fixture fixture.ly
%   sed -i '' "s|textedit://$PWD/|textedit:///score/|g" fixture.svg
% (the links' folder made /score, so no path of the computer it was made on is kept).
\language "english"
\score {
  <<
    \new Staff \with { instrumentName = "Flute" shortInstrumentName = "Fl." } \relative c'' {
      \tempo "Allegro" 4 = 120
      \key g \major \time 3/4
      \partial 4 d4 |
      \repeat volta 2 { g2 a4 | }
      \alternative { { b4.( c8 d4) | } { b2. | } }
      \mark \default e2.~ | e4 r r^"rit." |
      \key f \major \time 2/2 \grace { g16 } f1 \bar "|."
    }
    \new Staff \with { instrumentName = \markup { "Clarinet in B" \flat } } \relative c'' {
      \transposition bf
      \key a \major \time 3/4
      r4 |
      \repeat volta 2 { a2 b4 | }
      \alternative { { cs2. | } { cs2 r4 | } }
      R2. | R2. |
      \key g \major \time 2/2 a1
    }
    \new PianoStaff \with { instrumentName = "Piano" } <<
      \new Staff = "up" \relative c' {
        \key g \major \time 3/4
        r4 |
        \repeat volta 2 { <g b d>2. | }
        \alternative { { \tuplet 3/2 { g8 a b } c2 | } { d2.\f | } }
        d4 \change Staff = "down" g,, a \change Staff = "up" | b''2. |
        \key f \major \time 2/2 <f a c>1
      }
      \new Staff = "down" \relative c {
        \clef bass \key g \major \time 3/4
        r4 |
        \repeat volta 2 { g2. | }
        \alternative { { << { c4 d e } \\ { c,2 c4 } >> | } { \clef "treble_8" d'2. | } }
        s2. | g,2.\p |
        \clef bass \key f \major \time 2/2 f,1
      }
    >>
    \new Staff \with { instrumentName = "Voice" } \new Voice = "v" \relative c'' {
      \key g \major \time 3/4
      r4 |
      \repeat volta 2 { b2 a4 | }
      \alternative { { g2 r4 | } { g2. | } }
      r2. | R2. |
      \key f \major \time 2/2 a1
    }
    \new Lyrics \lyricsto "v" { Hel -- lo you, la }
    \new DrumStaff \with { instrumentName = "Drums" } \drummode {
      \time 3/4
      r4 |
      \repeat volta 2 { bd4 sn sn | }
      \alternative { { bd2 sn4 | } { hh8 hh hh hh sn4 | } }
      bd4 sn sn | bd2. |
      \time 2/2 cymc1
    }
  >>
}
