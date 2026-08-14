use Test;
use Terminal::Table::Adaptive;
use JSON::Fast;

my $root = $*PROGRAM.parent.parent;

sub unhex(Str $h --> Str) { Buf.new($h.comb(2).map({ :16($_) })).decode('utf-8') }

# ---------------------------------------------------------------------------
# Oracle: 44 fixed tricky inputs through the REAL pi-tui wrapTextWithAnsi
# (tools/wrap-oracle.mjs). Byte-for-byte equality of wrapped lines.
# ---------------------------------------------------------------------------

my $oracle-file = "$root/fixtures/wrap-oracle.jsonl";
my @cases = $oracle-file.IO.lines.map(*.&from-json);

for @cases.kv -> $i, $case {
    my $text  = unhex($case<text>);
    my $width = $case<width>;
    my @got   = wrap-cell($text, $width);
    my @want  = $case<lines>.map(*.&unhex);
    ok @got eqv @want, "wrap oracle case {$i + 1}/@cases.elems (w=$width)";
}

# ---------------------------------------------------------------------------
# Direct semantic checks (from the JS contract)
# ---------------------------------------------------------------------------

# Newlines split; ANSI state carries across literal newlines.
my @nl = wrap-cell("ab\ncd", 3);
is-deeply @nl.Array, ["ab", "cd"], 'newline split';

my @styled-nl = wrap-cell("\e[1ma\nb\e[0m", 5);
is-deeply @styled-nl.Array, ["\e[1ma", "\e[1mb\e[0m"], 'SGR state carried across newline';

# Whitespace runs preserved, not collapsed.
my @runs = wrap-cell("a  b", 4);
is-deeply @runs.Array, ["a  b"], 'whitespace runs kept when they fit';

# Long word broken char-by-char.
my @long = wrap-cell("abcdef", 3);
is-deeply @long.Array, ["abc", "def"], 'char-by-char break';

# Widths never exceed the requested width (visible).
for @cases -> $case {
    my $text  = unhex($case<text>);
    my $width = $case<width>;
    for wrap-cell($text, $width) -> $line {
        ok visible-width($line) <= max(1, $width),
            "no line exceeds width $width for {$text.raku}";
    }
}

done-testing;
