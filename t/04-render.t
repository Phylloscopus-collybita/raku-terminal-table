use Test;
use Terminal::Table::Adaptive;

# --- borders ---
my @h = <Name Value>;
my @r = [["alpha", "1"], ["beta", "22"]];
my @lines = render-table(@h, @r, 30);
ok @lines[0].starts-with('┌') && @lines[0].ends-with('┐'), 'top border';
ok @lines[2].starts-with('├') && @lines[2].ends-with('┤'), 'mid border';
ok @lines[*-1].starts-with('└') && @lines[*-1].ends-with('┘'), 'bottom border';

# --- exact fit when shrinking ---
my @wide = render-table(<A very very long header cell indeed B>, [["x", "y"]], 30);
for @wide -> $line {
    is visible-width($line), 30, 'every line exactly 30 wide (shrink branch)';
}

# --- natural fit is not padded to width (padding is the caller's job,
#     mirroring pi-tui render()) ---
my @nat = render-table(<aa bb>, [["c", "d"]], 30);
is visible-width(@nat[0]), 11, 'natural table stays 11 wide (unpadded)';

# --- too narrow: raw-markdown fallback ---
my @fb = render-table(<aa bb>, [["c", "d"]], 8, :raw("| aa | bb |"));
is @fb.elems, 2, 'fallback wraps raw markdown';
ok all(@fb.map({ visible-width($_) })) <= 8, 'fallback fits width';
is-deeply render-table(<aa bb>, [["c", "d"]], 8).Array, [].Array, 'no raw: empty fallback';

# --- blank line after table unless next token is space ---
my @nb = render-table(<a b>, [["c", "d"]], 8, :raw("| a | b |"), :next-token-type('paragraph'));
is @nb[*-1], '', 'blank line appended after fallback for non-space next token';
my @sb = render-table(<a b>, [["c", "d"]], 8, :raw("| a | b |"), :next-token-type('space'));
is @sb[*-1], '|', 'no blank line for space next token';
is-deeply render-table(<a b>, [["c", "d"]], 8, :raw("x"), :next-token-type('paragraph')).Array,
    ['x', ''].Array, 'fallback + blank line';

# --- empty header ---
is-deeply render-table([], [], 20).Array, [].Array, 'empty header renders nothing';

# --- header bold hook (pi applies theme.bold to the padded header line) ---
my @b = render-table(["Name"], [["x"]], 20, :bold(-> $s { "\e[1m$s\e[0m" }));
ok @b[1].contains("│ \e[1mName\e[0m │"), 'bold applied to each padded header cell';
my @ib = render-table(["Name"], [["x"]], 20);
nok @ib[1] ~~ /\e/, 'default header style is identity';

# --- rows shorter than header are padded ---
my @short = render-table(<a b c>, [["x"]], 20);
my $sep-count = @short.grep(*.starts-with('├')).elems;
is $sep-count, 1, 'short row still renders all columns';

# --- empty body cells ---
my @ec = render-table(<a b>, [["", "c"]], 20);
ok @ec.grep(*.contains('│   │')).elems >= 1, 'empty cell renders as blank';

# --- CJK: no line exceeds the terminal width ---
my @cj = render-table(<语言 例子>,
    [["中文", "你吃饭了吗？你好！你从哪里来？"]], 24);
for @cj -> $line {
    ok visible-width($line) <= 24, "CJK line within width: {$line.raku}";
}
is visible-width(@cj[0]), 24, 'CJK shrink fills exactly';

# --- ANSI cells measure by visible width ---
my @ansi = render-table(<Item Status>,
    [["alpha", "\e[32mgreen\e[0m"], ["beta", "\e[1mbold\e[0m"]], 18);
for @ansi -> $line {
    ok visible-width($line) <= 18, "ANSI line within width: {$line.raku}";
}
is visible-width(@ansi[0]), 18, 'ANSI table fills exactly';

# --- visible width of the fallback raw includes pipes ---
my @fb2 = render-table(<a b>, [["c", "d"]], 8, :raw("| a | b |"));
is visible-width(@fb2[0]), 7, 'fallback raw wrapped to width';

done-testing;

# --- Terminal::Table adapter (plan D3) ---
my @aw = to-terminal-table-widths(<Name Value Note>,
    [["alpha", "1", "first"], ["beta", "22", "second"]], 30);
is-deeply @aw.Array, [5, 5, 6].Array, 'adapter: natural widths when fitting';
my @aw2 = to-terminal-table-widths(["A very very long header cell indeed", "B"],
    [["x", "y"]], 30);
is ([+] @aw2), 23, 'adapter: shrink fills available';
is @aw2[0], 22, 'adapter: proportional share';
is-deeply to-terminal-table-widths([], [], 20).Array, [].Array, 'adapter: empty table';

done-testing;

# --- single-row call shapes (Raku flattens [[...]] with one inner array) ---
my @sr1 = render-table(<a b>, [["x", "y"]], 12);
my @sr2 = render-table(<a b>, (["x", "y"],), 12);
is-deeply @sr1.Array, @sr2.Array, 'flattened single row [[...]] == explicit (["..."],)';
is @sr1.grep(*.contains('│ x │ y │')).elems, 1, 'single row renders both cells on one line';
my @sr3 = render-table(<a b>, [["x", "y"], ["z", "w"]], 12);
is @sr3.grep(*.starts-with('├')).elems, 2, 'two rows, two separators';

done-testing;
