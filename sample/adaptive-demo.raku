# Demo: width-adaptive tables (CJK-correct, unlike the original PoC's
# .chars-based version). Run: raku-rakuast -Ilib examples/demo.raku
use Terminal::Table::Adaptive;

my @header = <Language Example>;
my @rows = [
    ["Chinese",  "你吃饭了吗？你好！你从哪里来？"],
    ["English",  "Nice to meet you! Where are you from?"],
    ["Japanese", "ありがとうございます。いただきます！"],
    ["Emoji",    "🚀✨ 你好 hello 世界"],
];

for 60, 40, 26, 12 -> $width {
    say("── terminal width $width " ~ ('─' x 12));
    for render-table(@header, @rows, $width) -> $line {
        say $line;
    }
    say '';
}

# Pure fitting math (public API), e.g. for custom renderers:
say "widths at 40: ", to-terminal-table-widths(@header, @rows, 40).raku;
say "widths at 26: ", to-terminal-table-widths(@header, @rows, 26).raku;

# Fallback: too narrow for the border overhead -> wrapped raw markdown.
say '── too narrow (raw fallback) ' ~ ('─' x 4);
say render-table(@header, @rows, 8,
    :raw("| Language | Example |\n| --- | --- |\n| 中文 | 你好 |")).join("\n");
