%% Curator's settings for engraving a score it imports (lilypond -dinclude-settings=…).
%% The whole piece is set on one endless line, and every graphical object is tagged in the
%% SVG with what made it (data-c: its number, data-g: its kind, data-l: the line, a staff or
%% lyrics, it belongs to). What the score is (its contexts, bars, notes, clefs, keys and
%% times, tempo and rehearsal marks) is written beside it, one JSON object a line, to the file
%% CURATOR_LILYPOND_DATA names. Nothing here may stop a score from engraving: a failure is
%% written as an error line and the score goes on.

\paper {
  page-breaking = #ly:one-line-breaking
  bookTitleMarkup = ##f
  scoreTitleMarkup = ##f
  oddHeaderMarkup = ##f
  evenHeaderMarkup = ##f
  oddFooterMarkup = ##f
  evenFooterMarkup = ##f
}

#(define curator:port #f)
#(define curator:keys (make-hash-table))
#(define curator:lines (make-hash-table))
#(define curator:next-key 0)
#(define curator:next-grob 0)
#(define curator:score -1)

#(define (curator:emit line)
   (if (not curator:port)
       (let ((path (getenv "CURATOR_LILYPOND_DATA")))
         (if path (set! curator:port (open-output-file path)))))
   (if curator:port
       (begin (display line curator:port) (newline curator:port) (force-output curator:port))))

#(define (curator:str s)
   (let ((s (if (string? s) s (format #f "~a" s))))
     (string-append "\""
       (apply string-append
         (map (lambda (ch)
                (cond ((char=? ch #\") "\\\"")
                      ((char=? ch #\\) "\\\\")
                      ((char<? ch #\space) " ")
                      (else (string ch))))
              (string->list s)))
       "\"")))

#(define-syntax-rule (curator:safely body ...)
   (catch #t
     (lambda () body ...)
     (lambda (key . args)
       (catch #t
         (lambda () (curator:emit (format #f "{\"t\":\"error\",\"what\":~a}" (curator:str (cons key args)))))
         (lambda _ #f)))))

#(define (curator:moment m) (curator:str (ly:moment-main m)))

%% A markup with its accidentals as characters ("Clarinet in B" \flat: "Clarinet in B♭"), which
%% markup->string would leave out.
#(define (curator:glyphs m)
   (cond ((and (pair? m) (procedure? (car m)))
          (let ((f (car m)))
            (cond ((eq? f flat-markup) "♭")
                  ((eq? f sharp-markup) "♯")
                  ((eq? f natural-markup) "♮")
                  ((eq? f doubleflat-markup) "𝄫")
                  ((eq? f doublesharp-markup) "𝄪")
                  ((list? (cdr m)) (cons f (map curator:glyphs (cdr m))))
                  (else m))))
         ((list? m) (map curator:glyphs m))
         (else m)))

#(define (curator:markup m) (curator:str (if (markup? m) (markup->string (curator:glyphs m)) "")))

#(define (curator:key ctx)
   (or (hashq-ref curator:keys ctx)
       (let ((k curator:next-key))
         (set! curator:next-key (1+ k))
         (hashq-set! curator:keys ctx k)
         (let* ((parent (ly:context-parent ctx))
                (p (if (ly:context? parent) (curator:key parent) -1)))
           (curator:emit (format #f "{\"t\":\"ctx\",\"s\":~a,\"k\":~a,\"n\":~a,\"id\":~a,\"p\":~a}"
                                 curator:score k (curator:str (ly:context-name ctx)) (curator:str (ly:context-id ctx)) p)))
         k)))

#(define (curator:line-of ctx)
   (cond ((not (ly:context? ctx)) -1)
         ((hashq-ref curator:lines ctx) (curator:key ctx))
         (else (curator:line-of (ly:context-parent ctx)))))

#(define (curator:pitch p)
   (if (ly:pitch? p)
       (format #f "[~a,~a,~a]" (ly:pitch-octave p) (ly:pitch-notename p) (curator:str (ly:pitch-alteration p)))
       "null"))

#(define (curator:length d)
   (if (ly:duration? d) (curator:str (ly:duration->number d)) "null"))

%% How a duration is written: its log (2 a crotchet), dots and tuplet scale.
#(define (curator:shape d)
   (if (ly:duration? d)
       (format #f ",\"dl\":~a,\"dd\":~a,\"ds\":~a"
               (ly:duration-log d) (ly:duration-dot-count d) (curator:str (ly:duration-scale d)))
       ""))

#(define (curator:text t)
   (curator:str (cond ((string? t) t) ((markup? t) (markup->string t)) (else ""))))

%% The number a grob was tagged with (data-c), or #f.
#(define (curator:id-of grob)
   (and (ly:grob? grob) (assq-ref (ly:grob-property grob 'output-attributes '()) 'data-c)))

#(define (curator:describe name grob ctx ev)
   (case name
     ((NoteHead TabNoteHead)
      (format #f ",\"cn\":~a,\"st\":~a,\"p\":~a,\"d\":~a,\"tr\":~a,\"drum\":~a,\"sp\":~a~a"
              (curator:str (ly:context-name ctx))
              (curator:key (ly:context-parent ctx))
              (if ev (curator:pitch (ly:event-property ev 'pitch #f)) "null")
              (if ev (curator:length (ly:event-property ev 'duration #f)) "null")
              (curator:pitch (ly:context-property ctx 'instrumentTransposition))
              (curator:str (if ev (ly:event-property ev 'drum-type "") ""))
              (let ((sp (ly:grob-property grob 'staff-position 0))) (if (number? sp) sp 0))
              (if ev (curator:shape (ly:event-property ev 'duration #f)) "")))
     ((Rest MultiMeasureRest)
      (format #f ",\"st\":~a,\"d\":~a~a"
              (curator:key (ly:context-parent ctx))
              (if ev (curator:length (ly:event-property ev 'duration #f)) "null")
              (if ev (curator:shape (ly:event-property ev 'duration #f)) "")))
     ((Clef)
      (format #f ",\"glyph\":~a,\"pos\":~a,\"oct\":~a"
              (curator:str (ly:context-property ctx 'clefGlyph ""))
              (ly:context-property ctx 'clefPosition 0)
              (ly:context-property ctx 'clefTransposition 0)))
     ((KeySignature)
      (format #f ",\"alts\":~a" (curator:str (ly:context-property ctx 'keyAlterations '()))))
     ((TimeSignature)
      (format #f ",\"sig\":~a,\"style\":~a"
              (curator:str (ly:grob-property grob 'time-signature))
              (curator:str (ly:grob-property grob 'style))))
     ((BarLine)
      (format #f ",\"glyph\":~a" (curator:str (ly:grob-property grob 'glyph ""))))
     ((MetronomeMark)
      (format #f ",\"text\":~a,\"unit\":~a,\"count\":~a"
              (if ev (curator:markup (ly:event-property ev 'text #f)) "\"\"")
              (if ev (curator:length (ly:event-property ev 'tempo-unit #f)) "null")
              (if ev (curator:str (ly:event-property ev 'metronome-count #f)) "null")))
     ((DynamicText)
      (format #f ",\"text\":~a" (curator:text (if ev (ly:event-property ev 'text "") ""))))
     ((RehearsalMark TextMark SectionLabel VoltaBracket TextScript)
      (format #f ",\"text\":~a" (curator:markup (ly:grob-property grob 'text #f))))
     ((InstrumentName)
      (format #f ",\"long\":~a,\"short\":~a"
              (curator:markup (ly:grob-property grob 'long-text #f))
              (curator:markup (ly:grob-property grob 'short-text #f))))
     ((StaffSymbol)
      (format #f ",\"lines\":~a" (curator:str (ly:grob-property grob 'line-positions '()))))
     ((VerticalAxisGroup)
      (format #f ",\"aff\":~a" (curator:str (ly:grob-property grob 'staff-affinity '()))))
     (else #f)))

#(define (Curator_engraver context)
   (let ((pending '()) (spanners '()) (ties '()) (first #t))
     (make-engraver
      ((initialize engraver)
       (set! curator:score (1+ curator:score))
       (curator:safely (curator:key context)))
      ((process-music engraver)
       (curator:safely
        (let ((pos (ly:context-property context 'measurePosition))
              (now (ly:context-current-moment context)))
          ;; A bar starts where the position in the bar is 0 again (in a cadenza, timing off, it
          ;; stays where it was: one bar).
          (if (and (ly:moment? pos) (= 0 (ly:moment-grace now))
                   (or first (and (ly:context-property context 'timing #t) (equal? 0 (ly:moment-main pos)))))
              (begin
                (set! first #f)
                (curator:emit
                 (format #f "{\"t\":\"measure\",\"s\":~a,\"m\":~a,\"pos\":~a,\"len\":~a,\"bar\":~a,\"sig\":~a,\"timing\":~a}"
                         curator:score (curator:moment now) (curator:moment pos)
                         (curator:str (ly:context-property context 'measureLength))
                         (ly:context-property context 'currentBarNumber 0)
                         (curator:str (ly:context-property context 'timeSignature))
                         (if (ly:context-property context 'timing #t) "true" "false"))))))))
      (acknowledgers
       ((grob-interface engraver grob source-engraver)
        (curator:safely
         (let ((ctx (ly:translator-context source-engraver)))
           (if (eq? (grob::name grob) 'VerticalAxisGroup) (hashq-set! curator:lines ctx #t))
           (set! pending (cons (cons grob ctx) pending))))))
      ((stop-translation-timestep engraver)
       (let ((now (ly:context-current-moment context))
             (grobs (reverse pending)))
         (set! pending '())
         (for-each
          (lambda (entry)
            (curator:safely
             (let* ((grob (car entry)) (ctx (cdr entry))
                    (name (grob::name grob))
                    (id curator:next-grob)
                    (line (curator:line-of ctx))
                    (cause (ly:grob-property grob 'cause))
                    (ev (if (ly:stream-event? cause) cause #f)))
               (set! curator:next-grob (1+ id))
               (ly:grob-set-property! grob 'output-attributes
                 (append (list (cons 'data-c id) (cons 'data-g name) (cons 'data-l line))
                         (ly:grob-property grob 'output-attributes '())))
               (if (eq? name 'VoltaBracket) (set! spanners (cons (cons id grob) spanners)))
               (if (eq? name 'Tie) (set! ties (cons grob ties)))
               (let ((extra (curator:describe name grob ctx ev)))
                 (if extra
                     (curator:emit (format #f "{\"t\":~a,\"s\":~a,\"c\":~a,\"l\":~a,\"k\":~a,\"m\":~a,\"g\":~a~a}"
                                           (curator:str name) curator:score id line (curator:key ctx)
                                           (curator:moment now) (curator:str (ly:moment-grace now)) extra)))))))
          grobs)))
      ((finalize engraver)
       (curator:safely
        (for-each
         (lambda (entry)
           ;; Where the bracket ends: the moment of the column its right end is in.
           (let* ((grob (cdr entry))
                  (right (ly:spanner-bound grob RIGHT))
                  (column (and (ly:item? right) (ly:item-get-column right)))
                  (when (and (ly:grob? column) (ly:grob-property column 'when #f))))
             (curator:emit (format #f "{\"t\":\"span\",\"s\":~a,\"c\":~a,\"end\":~a}" curator:score (car entry)
                                   (if (ly:moment? when) (curator:moment when) "null")))))
         spanners)
        ;; Each tie: the note it starts at and the one it ends at.
        (for-each
         (lambda (tie)
           (let ((from (curator:id-of (ly:spanner-bound tie LEFT)))
                 (to (curator:id-of (ly:spanner-bound tie RIGHT))))
             (if (and from to)
                 (curator:emit (format #f "{\"t\":\"tie\",\"s\":~a,\"from\":~a,\"to\":~a}" curator:score from to)))))
         (reverse ties))
        (curator:emit (format #f "{\"t\":\"end\",\"s\":~a,\"m\":~a}" curator:score
                              (curator:moment (ly:context-current-moment context)))))))))

\layout {
  \context {
    \Score
    \consists #Curator_engraver
  }
}
