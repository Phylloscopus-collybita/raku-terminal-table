# Terminal::Table::Adaptive — width-adaptive terminal tables for Raku.
#
# Renders a table (header + rows of strings; cells may contain ANSI SGR
# codes, OSC 8 hyperlinks, and wide/CJK characters) into lines that fit a
# given terminal width exactly: column widths are computed automatically
# (natural widths when everything fits, proportional shrink with
# floor-rounding when it doesn't, per-column wrapping, box-drawing borders).
#
# Column-fitting and wrapping algorithm derived from
# @earendil-works/pi-tui (https://github.com/earendil/pi-tui),
# Copyright Mario Zechner, MIT License. In particular:
#
#   - fit-columns:  port of Markdown.renderTable() column fitting
#                   (dist/components/markdown.js v0.84.1)
#   - wrap-cell:    port of wrapTextWithAnsi() semantics
#                   (dist/utils.js v0.84.1)
#   - visible-width: pi-tui's visibleWidth() model: tabs expand to 3
#                   spaces, CSI/OSC/APC sequences are stripped, graphemes
#                   measured per wcwidth (Terminal::WCWidth) instead of
#                   pi-tui's own east-asian tables (same results for
#                   common CJK/emoji; see the module POD for provenance)
#
# License: MIT.
unit module Terminal::Table::Adaptive;

use Terminal::WCWidth;

# ---------------------------------------------------------------------------
# Width measurement
# ---------------------------------------------------------------------------

# Extract a terminal escape sequence at $pos in $s, mirroring pi-tui's
# extractAnsiCode(): CSI (ESC [ ... m/G/K/H/J), OSC (ESC ] ... BEL or ESC \),
# APC (ESC _ ... BEL or ESC \). Returns (code, length) or Nil.
my sub extract-ansi-code(Str $s, Int $pos) {
    return Nil if $pos >= $s.chars || $s.substr($pos, 1) ne "\e";
    my $next = $s.substr($pos + 1, 1);
    if $next eq '[' {
        my $j = $pos + 2;
        $j++ while $j < $s.chars && $s.substr($j, 1) !~~ /<[mGKHJ]>/;
        return ($s.substr($pos, $j - $pos + 1), $j - $pos + 1) if $j < $s.chars;
        return Nil;
    }
    if $next eq ']' || $next eq '_' {
        my $j = $pos + 2;
        while $j < $s.chars {
            return ($s.substr($pos, $j - $pos + 1), $j - $pos + 1)
                if $s.substr($j, 1) eq "\x07";
            if $s.substr($j, 1) eq "\e" && $j + 1 < $s.chars && $s.substr($j + 1, 1) eq '\\' {
                return ($s.substr($pos, $j - $pos + 2), $j - $pos + 2);
            }
            $j++;
        }
        return Nil;
    }
    Nil
}

# Strip CSI/OSC/APC escape sequences, expanding tabs to 3 spaces (matching
# pi-tui's visibleWidth() cleaning order).
my sub strip-ansi(Str $s --> Str) {
    my $clean = $s;
    $clean = $clean.subst(/\t/, '   ', :g) if $clean ~~ /\t/;
    return $clean unless $clean ~~ /\e/;
    my $out = '';
    my $i = 0;
    while $i < $clean.chars {
        my $a = extract-ansi-code($clean, $i);
        if $a {
            $i += $a[1];
            next;
        }
        $out ~= $clean.substr($i, 1);
        $i++;
    }
    $out
}

# Visible width of a string in terminal columns: tabs expand to 3 spaces,
# ANSI/OSC/APC sequences are ignored, each grapheme is measured with
# Terminal::WCWidth. Never use .chars for measuring.
#
# O1: widths are memoized per grapheme and per whole string. wcswidth is a
# pure function of its argument, so caching is exact (no semantic drift);
# catalog-shaped text has ~100–300 distinct graphemes across 10⁵ occurrences,
# so measurement collapses to hash lookups after warmup. Both caches are
# capped (cleared when over) to bound memory on hostile input.
my %grapheme-width-cache;
my %string-width-cache;
my constant WIDTH-CACHE-MAX = 10_000;

sub visible-width(Str $text --> Int) is export {
    return 0 if $text.chars == 0;
    with %string-width-cache{$text} {
        return $_;
    }
    if %string-width-cache.elems > WIDTH-CACHE-MAX {
        %string-width-cache = ();
        %grapheme-width-cache = ();
    }
    elsif %grapheme-width-cache.elems > WIDTH-CACHE-MAX {
        %grapheme-width-cache = ();
    }
    my $width = 0;
    my $clean = strip-ansi($text);
    for $clean.comb -> $g {
        $width += %grapheme-width-cache{$g} //= do {
            my $w = wcswidth($g);
            $w > 0 ?? $w !! 0;   # control chars: width 0, like eastAsianWidth
        };
    }
    %string-width-cache{$text} = $width;
    $width
}

# Width of the longest whitespace-delimited word, capped at $cap
# (pi-tui's maxUnbrokenWordWidth = 30). Words split on /\s+/; empty
# words dropped.
sub longest-word-width(Str $text, Int $cap = 30 --> Int) is export {
    my $longest = 0;
    for $text.split(/\s+/) -> $word {
        next unless $word.chars;
        $longest max= visible-width($word);
    }
    min($longest, $cap)
}

# ---------------------------------------------------------------------------
# Column fitting (port of pi-tui renderTable()'s width math)
# ---------------------------------------------------------------------------

# IEEE-double floor-ratio, matching JavaScript's (a / b) * c then Math.floor.
# Raku's Int/Int division is exact (Rat); the JS algorithm relies on float
# rounding, so we force Num arithmetic to stay byte-identical with pi-tui.
my sub ratio-floor(Num() $num, Num() $den, Num() $mul --> Int) {
    ($num / $den * $mul).floor
}

# Fit $available cells into columns with given natural widths (widest
# header/cell) and min widths (longest unbreakable word, pre-capped at 30).
# Mirrors pi-tui's three branches:
#   A — min widths don't fit: start each column at 1, grow proportionally,
#       hand out rounding leftover left-to-right in a single pass;
#   B — everything fits: width = max(natural, min);
#   C — shrink: grow from min proportionally to natural overflow, then
#       distribute remaining cells round-robin until no column can grow.
sub fit-columns(@natural, @min, Int $available --> List) is export {
    my @min-widths = @min;
    my $min-cells = [+] @min-widths;

    if $min-cells > $available {
        # Branch A
        @min-widths = 1 xx @natural.elems;
        my $remaining = $available - @natural.elems;
        if $remaining > 0 {
            my $total-weight = [+] @min.map: { max(0, $_ - 1) };
            my @growth = @min.map: -> $w {
                my $weight = max(0, $w - 1);
                $total-weight > 0 ?? ratio-floor($weight, $total-weight, $remaining) !! 0;
            };
            for ^@natural.elems -> $i {
                @min-widths[$i] += @growth[$i] // 0;
            }
            my $allocated = [+] @growth;
            my $leftover = $remaining - $allocated;
            for ^@natural.elems -> $i {
                last if $leftover <= 0;
                @min-widths[$i]++;
                $leftover--;
            }
        }
        $min-cells = [+] @min-widths;
    }

    my $total-natural = [+] @natural;
    my @widths;
    if $total-natural <= $available {
        # Branch B
        @widths = (@natural Z @min-widths).map: -> ($n, $m) { $n max $m };
    }
    else {
        # Branch C
        my $grow-potential = 0;
        for ^@natural.elems -> $i {
            $grow-potential += max(0, @natural[$i] - @min-widths[$i]);
        }
        my $extra = max(0, $available - $min-cells);
        @widths = (^@natural.elems).map: -> $i {
            my $delta = max(0, @natural[$i] - @min-widths[$i]);
            my $grow = $grow-potential > 0 ?? ratio-floor($delta, $grow-potential, $extra) !! 0;
            @min-widths[$i] + $grow;
        };
        my $allocated = [+] @widths;
        my $remaining = $available - $allocated;
        while $remaining > 0 {
            my $grew = False;
            for ^@natural.elems -> $i {
                last if $remaining <= 0;
                if @widths[$i] < @natural[$i] {
                    @widths[$i]++;
                    $remaining--;
                    $grew = True;
                }
            }
            last unless $grew;
        }
    }
    @widths
}

# ---------------------------------------------------------------------------
# ANSI state tracking (port of pi-tui's AnsiCodeTracker)
# ---------------------------------------------------------------------------

# Parsed OSC 8 hyperlink: [params, url, terminator].
my sub parse-osc8(Str $ansi) {
    return Empty unless $ansi.starts-with("\e]8;");
    my $terminator = $ansi.ends-with("\x07") ?? "\x07" !! "\e\\";
    my $len = $terminator eq "\x07" ?? 1 !! 2;
    my $body = $ansi.substr(4, $ansi.chars - 4 - $len);
    my $sep = $body.index(';');
    return Empty unless $sep.defined;
    my $params = $body.substr(0, $sep);
    my $url = $body.substr($sep + 1);
    return ['close'] if $url eq '';          # closing hyperlink
    ['open', [$params, $url, $terminator]]
}

my sub format-osc8($h --> Str) {
    "\e]8;{$h[0]};{$h[1]}{$h[2]}"
}

my sub format-osc8-close($terminator --> Str) {
    "\e]8;;{$terminator}"
}

class AnsiTracker {
    has Bool $!bold          = False;
    has Bool $!dim           = False;
    has Bool $!italic        = False;
    has Bool $!underline     = False;
    has Bool $!blink         = False;
    has Bool $!inverse       = False;
    has Bool $!hidden        = False;
    has Bool $!strikethrough = False;
    has Str  $!fg-color;                     # "31" or "38;5;240" etc., unset = none
    has Str  $!bg-color;
    has      $!active-hyperlink;             # [params, url, terminator] or unset

    method !reset-state() {
        $!bold = $!dim = $!italic = $!underline = False;
        $!blink = $!inverse = $!hidden = $!strikethrough = False;
        $!fg-color = Str;
        $!bg-color = Str;
        # SGR reset does not affect OSC 8 hyperlink state.
    }

    method process(Str $ansi) {
        my $h = parse-osc8($ansi);
        if $h {
            $!active-hyperlink = $h[0] eq 'open' ?? $h[1] !! Nil;
            return;
        }
        return unless $ansi.ends-with('m');
        my $m = $ansi ~~ /\e\[(<[\d;]>*)m/;
        return unless $m;
        my $params = $m[0].Str;
        if $params eq '' || $params eq '0' {
            self!reset-state;
            return;
        }
        my @parts = $params.split(';');
        my $i = 0;
        while $i < @parts.elems {
            my $code = @parts[$i].Int;
            if $code == 38 || $code == 48 {
                if @parts[$i + 1] eq '5' && @parts[$i + 2].defined {
                    my $color = @parts[$i .. $i + 2].join(';');
                    if $code == 38 { $!fg-color = $color } else { $!bg-color = $color }
                    $i += 3;
                    next;
                }
                elsif @parts[$i + 1] eq '2' && @parts[$i + 4].defined {
                    my $color = @parts[$i .. $i + 4].join(';');
                    if $code == 38 { $!fg-color = $color } else { $!bg-color = $color }
                    $i += 5;
                    next;
                }
            }
            given $code {
                when 0  { self!reset-state }
                when 1  { $!bold = True }
                when 2  { $!dim = True }
                when 3  { $!italic = True }
                when 4  { $!underline = True }
                when 5  { $!blink = True }
                when 7  { $!inverse = True }
                when 8  { $!hidden = True }
                when 9  { $!strikethrough = True }
                when 21 { $!bold = False }                       # some terminals
                when 22 { $!bold = False; $!dim = False }
                when 23 { $!italic = False }
                when 24 { $!underline = False }
                when 25 { $!blink = False }
                when 27 { $!inverse = False }
                when 28 { $!hidden = False }
                when 29 { $!strikethrough = False }
                when 39 { $!fg-color = Str }                     # default fg
                when 49 { $!bg-color = Str }                     # default bg
                default {
                    if 30 <= $code <= 37 || 90 <= $code <= 97 {
                        $!fg-color = $code.Str;
                    }
                    elsif 40 <= $code <= 47 || 100 <= $code <= 107 {
                        $!bg-color = $code.Str;
                    }
                }
            }
            $i++;
        }
    }

    method get-active-codes( --> Str) {
        my @codes;
        @codes.push('1') if $!bold;
        @codes.push('2') if $!dim;
        @codes.push('3') if $!italic;
        @codes.push('4') if $!underline;
        @codes.push('5') if $!blink;
        @codes.push('7') if $!inverse;
        @codes.push('8') if $!hidden;
        @codes.push('9') if $!strikethrough;
        @codes.push($!fg-color) if $!fg-color.defined;
        @codes.push($!bg-color) if $!bg-color.defined;
        my $result = @codes ?? "\e[" ~ @codes.join(';') ~ 'm' !! '';
        $result ~= format-osc8($!active-hyperlink) if $!active-hyperlink.defined;
        $result
    }

    method get-line-end-reset( --> Str) {
        my $result = '';
        $result ~= "\e[24m" if $!underline;      # underline off only, preserves background
        $result ~= format-osc8-close($!active-hyperlink[2])
            if $!active-hyperlink.defined;       # re-opened at line start via get-active-codes
        $result
    }
}

my sub update-tracker(Str $text, AnsiTracker $tracker) {
    return unless $text ~~ /\e/;   # O2: plain text carries no ANSI state
    my $i = 0;
    while $i < $text.chars {
        my $a = extract-ansi-code($text, $i);
        if $a {
            $tracker.process($a[0]);
            $i += $a[1];
        }
        else {
            $i++;
        }
    }
}

# ---------------------------------------------------------------------------
# Wrapping (port of pi-tui's wrapTextWithAnsi)
# ---------------------------------------------------------------------------

# CJK graphemes are break opportunities on their own. pi-tui uses
# Script_Extensions={Han,Hiragana,Katakana,Hangul,Bopomofo}; Rakudo has no
# Script_Extensions support, so we approximate with Script + the common
# extension ranges (CJK punctuation, fullwidth forms, radicals, etc.).
my constant CJK-BREAK = /
    <:Han> | <:Hiragana> | <:Katakana> | <:Hangul> | <:Bopomofo>
    | [\x[3000]..\x[303F]]   # CJK Symbols and Punctuation
    | [\x[3099]..\x[309C]]   # combining marks (scx includes Han/Hiragana)
    | [\x[30FB]..\x[30FC]]   # katakana middle dot / long vowel mark
    | [\x[FE30]..\x[FE4F]]   # CJK Compatibility Forms
    | [\x[FF00]..\x[FF60]]   # fullwidth forms
    | [\x[1F200]..\x[1F2FF]] # Enclosed Ideographic Supplement
    | [\x[2E80]..\x[2EFF]]   # CJK Radicals Supplement
    | [\x[2F00]..\x[2FDF]]   # Kangxi Radicals
    | [\x[2FF0]..\x[2FFF]]   # Ideographic Description
    | [\x[3190]..\x[319F]]   # Kanbun
    | [\x[31C0]..\x[31EF]]   # CJK Strokes
    | [\x[3200]..\x[32FF]]   # Enclosed CJK Letters and Months
/;

# Tokenize a line for wrapping: whitespace runs are preserved as tokens,
# ANSI codes are held pending and attached to the next visible char, CJK
# graphemes become standalone tokens. Mirrors splitIntoTokensWithAnsi().
#
# O2: text without ESC provably contains no ANSI sequence (every CSI/OSC/APC
# starts with ESC), so it takes plain-tokens: one .comb pass with no
# per-position escape scan, no substr-per-char, no pending-ANSI state. Token
# semantics are identical (whitespace runs kept, CJK graphemes standalone
# break tokens).
my sub plain-tokens(Str $line --> List) {
    my @tokens;
    my $current = '';
    my $current-kind;
    for $line.comb -> $seg {
        my $is-space = $seg eq ' ';
        if !$is-space && $seg ~~ CJK-BREAK {
            @tokens.push($current) if $current;
            @tokens.push($seg);
            $current = '';
            $current-kind = Nil;
            next;
        }
        my $kind = $is-space ?? 'space' !! 'word';
        if $current && $current-kind ne $kind {
            @tokens.push($current);
            $current = '';
            $current-kind = Nil;
        }
        $current-kind = $kind;
        $current ~= $seg;
    }
    @tokens.push($current) if $current;
    @tokens
}

my sub split-tokens(Str $line --> List) {
    return plain-tokens($line) unless $line ~~ /\e/;
    my @tokens;
    my $current = '';
    my $pending-ansi = '';
    my $current-kind;
    my $i = 0;
    while $i < $line.chars {
        my $a = extract-ansi-code($line, $i);
        if $a {
            $pending-ansi ~= $a[0];
            $i += $a[1];
            next;
        }
        my $end = $i;
        $end++ while $end < $line.chars && !extract-ansi-code($line, $end);
        for $line.substr($i, $end - $i).comb -> $seg {
            my $is-space = $seg eq ' ';
            if !$is-space && $seg ~~ CJK-BREAK {
                @tokens.push($current) if $current;
                @tokens.push($pending-ansi ~ $seg);
                $pending-ansi = '';
                $current = '';
                $current-kind = Nil;
                next;
            }
            my $kind = $is-space ?? 'space' !! 'word';
            if $current && $current-kind ne $kind {
                @tokens.push($current);
                $current = '';
                $current-kind = Nil;
            }
            if $pending-ansi {
                $current ~= $pending-ansi;
                $pending-ansi = '';
            }
            $current-kind = $kind;
            $current ~= $seg;
        }
        $i = $end;
    }
    if $pending-ansi {
        if $current {
            $current ~= $pending-ansi;
        }
        elsif @tokens {
            @tokens[*-1] ~= $pending-ansi;
        }
        else {
            $current = $pending-ansi;
        }
    }
    @tokens.push($current) if $current;
    @tokens
}

# Break one over-long word char by char, carrying ANSI state across the
# broken lines. Mirrors breakLongWord().
my sub break-long-word(Str $word, Int $width, AnsiTracker $tracker --> List) {
    my @lines;
    my $current-line = $tracker.get-active-codes;
    my $current-width = 0;
    if $word !~~ /\e/ {
        # O2 plain-text path: no ANSI segments possible, so skip the segment
        # build entirely; the loop below is identical to the ANSI path's.
        for $word.comb -> $g {
            next unless $g.chars;
            my $w = visible-width($g);
            if $current-width + $w > $width {
                my $reset = $tracker.get-line-end-reset;
                $current-line ~= $reset if $reset;
                @lines.push($current-line);
                $current-line = $tracker.get-active-codes;
                $current-width = 0;
            }
            $current-line ~= $g;
            $current-width += $w;
        }
        @lines.push($current-line) if $current-line;
        return @lines ?? @lines !! [""];
    }
    my @segments;
    my $i = 0;
    while $i < $word.chars {
        my $a = extract-ansi-code($word, $i);
        if $a {
            @segments.push(['ansi', $a[0]]);
            $i += $a[1];
            next;
        }
        my $end = $i;
        $end++ while $end < $word.chars && !extract-ansi-code($word, $end);
        for $word.substr($i, $end - $i).comb -> $g {
            @segments.push(['graph', $g]);
        }
        $i = $end;
    }
    for @segments -> $seg {
        if $seg[0] eq 'ansi' {
            $current-line ~= $seg[1];
            $tracker.process($seg[1]);
            next;
        }
        my $grapheme = $seg[1];
        next unless $grapheme.chars;
        my $w = visible-width($grapheme);
        if $current-width + $w > $width {
            my $reset = $tracker.get-line-end-reset;
            $current-line ~= $reset if $reset;
            @lines.push($current-line);
            $current-line = $tracker.get-active-codes;
            $current-width = 0;
        }
        $current-line ~= $grapheme;
        $current-width += $w;
    }
    @lines.push($current-line) if $current-line;
    @lines ?? @lines !! [""]
}

# Width of the maximal trailing whitespace run of $s — exactly what
# trim-trailing removes — given $s's full visible width. O3: the trimmed
# width of a line is full − trailing-run width, so padding never re-measures
# a finished line. Exact for all graphemes, incl. word-kind whitespace
# (tabs) and ANSI-only suffixes (which reset the run to 0).
my sub trailing-ws-width(Str $s, Int $full-width --> Int) {
    my $trimmed = $s.trim-trailing;
    $trimmed.chars == $s.chars ?? 0 !! $full-width - visible-width($trimmed)
}

# Internal wrap that returns [line, trimmed-visible-width] pairs (O3): line
# widths are tracked incrementally while wrapping, so render-cell padding
# needs no second measurement pass. Semantics identical to wrap-single-line.
my sub wrap-single-line-pairs(Str $line, Int $width --> List) {
    return (["", 0],) unless $line.chars;
    my $line-width = visible-width($line);
    return ([$line, $line-width],) if $line-width <= $width;

    my @wrapped;                      # [line, trimmed-width] pairs, lines as pushed
    my $tracker = AnsiTracker.new;
    my $current-line = '';
    my $current-visible = 0;
    my $current-trailing-ws = 0;      # width of $current-line's trailing ws run

    for split-tokens($line) -> $token {
        my $token-visible = visible-width($token);
        my $is-whitespace = $token.trim eq '';

        # Token itself is too long: break it character by character.
        if $token-visible > $width && !$is-whitespace {
            if $current-line {
                my $reset = $tracker.get-line-end-reset;
                $current-line ~= $reset if $reset;
                @wrapped.push([$current-line, $current-visible - $current-trailing-ws]);
                $current-line = '';
                $current-visible = 0;
                $current-trailing-ws = 0;
            }
            my @broken = break-long-word($token, $width, $tracker);
            if @broken.end > 0 {
                @wrapped.append(
                    @broken[0 ..^ @broken.end].map({ [$_, visible-width($_.trim-trailing)] })
                );
            }
            $current-line = @broken[*-1];
            $current-visible = visible-width($current-line);
            $current-trailing-ws = trailing-ws-width($current-line, $current-visible);
            next;
        }

        my $total-needed = $current-visible + $token-visible;
        if $total-needed > $width && $current-visible > 0 {
            my $line-to-wrap = $current-line.trim-trailing;
            my $reset = $tracker.get-line-end-reset;
            $line-to-wrap ~= $reset if $reset;
            @wrapped.push([$line-to-wrap, $current-visible - $current-trailing-ws]);
            if $is-whitespace {
                # Don't start a new line with whitespace.
                $current-line = $tracker.get-active-codes;
                $current-visible = 0;
                $current-trailing-ws = 0;
            }
            else {
                $current-line = $tracker.get-active-codes ~ $token;
                $current-visible = $token-visible;
                $current-trailing-ws = trailing-ws-width($token, $token-visible);
            }
        }
        else {
            $current-line ~= $token;
            $current-visible += $token-visible;
            $current-trailing-ws = trailing-ws-width($token, $token-visible);
        }
        update-tracker($token, $tracker);
    }

    @wrapped.push([$current-line, $current-visible - $current-trailing-ws]) if $current-line;
    my @result = @wrapped ?? @wrapped.map({ [$_[0].trim-trailing, $_[1]] }) !! (["", 0],);
    @result
}

# Internal variant of wrap-cell returning [line, visible-width] pairs, so
# render-cell can pad without re-measuring every line (O3).
my sub wrap-cell-pairs(Str $text, Int $width --> List) {
    my $w = max(1, $width);
    return (["", 0],) unless $text.chars;
    my @input-lines = $text.split(/\r\n|\r|\n/);
    my @result;
    my $tracker = AnsiTracker.new;
    for @input-lines -> $input-line {
        my $prefix = @result ?? $tracker.get-active-codes !! '';
        my @wrapped = wrap-single-line-pairs($prefix ~ $input-line, $w);
        @result.append(@wrapped);
        update-tracker($input-line, $tracker);
    }
    @result ?? @result !! (["", 0],)
}

# Wrap text to at most $width visible columns, preserving ANSI state across
# wrapped lines and literal newlines. Whitespace runs are preserved (not
# collapsed); over-long tokens are broken char by char; trailing whitespace
# is trimmed. Mirrors wrapTextWithAnsi().
sub wrap-cell(Str $text, Int $width --> List) is export {
    wrap-cell-pairs($text, $width).map(*[0]).List
}

# ---------------------------------------------------------------------------
# Table rendering (port of pi-tui's Markdown.renderTable())
# ---------------------------------------------------------------------------

# Render a table whose header and rows are arrays of pre-rendered strings
# (cells may contain ANSI SGR codes / OSC 8 hyperlinks) into terminal lines
# that fit $terminal-width exactly where possible. Rows are an array of
# row-arrays; because Raku flattens C<[[...]]> with a single inner array
# when binding (C<my @r = [["x","y"]]> gives C<("x","y")>), a flat array
# of strings is accepted as a single row as well.
#
# Options:
#   :$raw — raw markdown used for the too-narrow fallback (when the border
#           overhead leaves fewer cells than columns); when absent, the
#           fallback is an empty list.
#   :$next-token-type — when set and not 'space', a blank line is appended
#           after the table (pi-tui adds spacing between blocks); after a
#           fallback, it is appended to the fallback lines.
#   :&bold — styling applied to the padded header line as a whole (pi-tui
#           applies the theme's bold; default identity).
sub render-table(@header, @rows, Int $terminal-width,
                 Str :$raw = '', Str :$next-token-type = '',
                 :&bold = -> $s { $s } --> List) is export {
    my $n = @header.elems;
    return [] if $n == 0;

    # Raku flattens [[...]] with a single inner array when binding to an
    # @-parameter (my @r = [["x","y"]] gives ("x","y")). Treat a flat
    # array of strings as one row so both call shapes work.
    my @rows2 = @rows && all(@rows) ~~ Str ?? (@rows,) !! @rows;

    my $available = $terminal-width - (3 * $n + 1);   # border overhead: 3n+1
    if $available < $n {
        my @fallback = $raw ?? wrap-cell($raw, $terminal-width) !! [];
        @fallback.push('') if $next-token-type && $next-token-type ne 'space';
        return @fallback;
    }

    my @natural = @header.map: { visible-width($_) };
    my @min     = @header.map: { max(1, longest-word-width($_)) };
    for @rows2 -> $row {
        for ^$n -> $i {
            my $text = $row[$i] // '';
            @natural[$i] max= visible-width($text);
            @min[$i]     max= max(1, longest-word-width($text));
        }
    }

    my @widths = fit-columns(@natural, @min, $available);

    my sub border($left, $join, $right) {
        $left ~ '─' ~ @widths.map({ '─' x $_ }).join('─' ~ $join ~ '─') ~ '─' ~ $right
    }
    my $top    = border('┌', '┬', '┐');
    my $mid    = border('├', '┼', '┤');
    my $bottom = border('└', '┴', '┘');

    my @out = $top;

    my sub render-cell(Str $text, Int $w --> List) {
        wrap-cell-pairs($text, $w).map({ $_[0] ~ (' ' x max(0, $w - $_[1])) }).List
    }

    my @all = (@header, |@rows2);
    for @all.kv -> $idx, $cells {
        my @cell-lines = (@$cells Z @widths).map: -> ($t, $w) { render-cell($t, $w) };
        my $line-count = @cell-lines».elems.max;
        for ^$line-count -> $r {
            my @parts;
            for @cell-lines.kv -> $c, $cl {
                my $padded = $cl[$r] // (' ' x @widths[$c]);
                @parts.push: $idx == 0 ?? &bold($padded) !! $padded;
            }
            @out.push: '│ ' ~ @parts.join(' │ ') ~ ' │';
        }
        @out.push($mid) if $idx < @all.end;
    }

    @out.push($bottom);
    @out
}

# Adapter for Terminal::Table (plan D3): compute per-column widths that fit a
# terminal width, for feeding Terminal::Table's @max-widths. Columns are
# measured like render-table (visible widths, word-capped minima) and fitted
# with the same three-branch algorithm.
sub to-terminal-table-widths(@header, @rows, Int $terminal-width,
                             Int :$max-word-width = 30 --> List) is export {
    my $n = @header.elems;
    return [] if $n == 0;
    my @rows2 = @rows && all(@rows) ~~ Str ?? (@rows,) !! @rows;
    my $available = max(0, $terminal-width - (3 * $n + 1));
    my @natural = @header.map: { visible-width($_) };
    my @min     = @header.map: { max(1, longest-word-width($_, $max-word-width)) };
    for @rows2 -> $row {
        for ^$n -> $i {
            my $text = $row[$i] // '';
            @natural[$i] max= visible-width($text);
            @min[$i]     max= max(1, longest-word-width($text, $max-word-width));
        }
    }
    fit-columns(@natural, @min, $available)
}

=begin pod

=head1 NAME

Terminal::Table::Adaptive — width-adaptive terminal tables for Raku

=head1 SYNOPSIS

=begin code :lang<raku>

use Terminal::Table::Adaptive;

my @header = <Language Example>;
my @rows = [
    ["Chinese",  "你吃饭了吗？你好！你从哪里来？"],
    ["English",  "Nice to meet you! Where are you from?"],
    ["Japanese", "ありがとうございます。いただきます！"],
];
say render-table(@header, @rows, 40).join("\n");

my @widths = fit-columns([30, 10], [5, 5], 20);   # [14, 6] — fills exactly

=end code

=head1 DESCRIPTION

Renders a table (header + rows of strings; cells may contain ANSI SGR codes,
OSC 8 hyperlinks, and wide/CJK characters) into lines that fit a given
terminal width: column widths are computed automatically — natural widths
when everything fits, proportional shrink with floor-rounding when it does
not, per-column wrapping, box-drawing borders.

The column-fitting and wrapping algorithms are ports of
L<@earendil-works/pi-tui|https://github.com/earendil/pi-tui> (MIT, Copyright
Mario Zechner): the fitting math mirrors C<Markdown.renderTable()> including
its floating-point behavior (IEEE double ratios, not exact rationals), and
wrapping mirrors C<wrapTextWithAnsi()> including SGR-state carry across
wrapped lines and OSC 8 hyperlink close/reopen.

Performance: width measurement is memoized per grapheme and per string
(capped caches); text without ANSI escapes (the common case) takes fast
tokenization paths that skip the escape scanner and ANSI state tracking;
line widths are tracked while wrapping so padding never re-measures a line.

=head1 SUBROUTINES

=head2 fit-columns(@natural, @min, $available)

Pure column-fitting: given per-column natural widths (widest header/cell
content) and min widths (longest unbreakable word, pre-capped at 30), return
column widths that fit $available cells exactly where possible. Three
branches: min-width rescale (branch A), natural fit (branch B), proportional
shrink with round-robin remainder (branch C).

=head2 visible-width($text)

Visible terminal width: tabs expand to 3 spaces, ANSI/OSC/APC sequences are
stripped, graphemes are measured with L<Terminal::WCWidth|https://raku.land/zef:raku-community-modules/Terminal::WCWidth>.

=head2 wrap-cell($text, $width)

Wrap text to at most $width visible columns, preserving ANSI state across
wrapped lines and literal newlines. Whitespace runs are preserved (not
collapsed); over-long tokens are broken character by character; trailing
whitespace is trimmed.

=head2 longest-word-width($text, $cap = 30)

Width of the longest whitespace-delimited word, capped.

=head2 render-table(@header, @rows, $terminal-width, :$raw, :$next-token-type, :&bold)

Render a table into lines. $raw is the fallback source used when the
terminal is too narrow for the border overhead; :$next-token-type mirrors
pi-tui's next-block handling (appends a blank line unless 'space'); :&bold
styles each padded header cell (pi-tui applies the theme's bold there).

=head2 to-terminal-table-widths(@header, @rows, $terminal-width, :$max-word-width = 30)

Adapter for L<Terminal::Table|https://raku.land/github:araraloren/Terminal::Table>:
returns per-column widths that fit a terminal width, suitable for that
module's C<@max-widths> parameter (plan D3).

=head1 ATTRIBUTION

Column-fitting and wrapping algorithms derived from
L<@earendil-works/pi-tui|https://github.com/earendil/pi-tui>
(dist/components/markdown.js C<renderTable()>, dist/utils.js
C<wrapTextWithAnsi()>, C<visibleWidth()>), Copyright Mario Zechner,
MIT License.

=head1 LICENSE

MIT.

=end pod
