use Test;
use Terminal::Table::Adaptive;

# --- plain ASCII ---
is visible-width(''), 0, 'empty';
is visible-width('abc'), 3, 'ascii';
is visible-width('hello world'), 11, 'ascii with space';

# --- CJK / emoji (Terminal::WCWidth tables) ---
is visible-width('你'), 2, 'CJK char';
is visible-width('你好世界'), 8, 'CJK run';
is visible-width('？'), 2, 'fullwidth punctuation';
is visible-width('a你b'), 4, 'mixed ascii/CJK';
is visible-width('🚀'), 2, 'rocket emoji';
is visible-width('✨'), 2, 'sparkle emoji';
is visible-width('a🚀b'), 4, 'mixed ascii/emoji';
is visible-width('🈀'), 2, 'enclosed ideographic supplement';

# --- combining characters ---
is visible-width("e\x[0301]"), 1, 'combining accent';
is visible-width("e\x[0301]x"), 2, 'accent + char';

# --- tabs expand to 3 spaces ---
is visible-width("\t"), 3, 'single tab';
is visible-width("a\tb"), 5, 'tab between chars';
is visible-width("a\t\tb"), 8, 'two tabs';

# --- ANSI stripping ---
is visible-width("\e[31mred\e[0m"), 3, 'SGR color';
is visible-width("\e[1m"), 0, 'bare SGR';
is visible-width("\e[31m你\e[0m"), 2, 'SGR + CJK';
is visible-width("\e[38;5;240mgray\e[0m"), 4, '256-color SGR';
is visible-width("\e[38;2;1;2;3mrgb\e[0m"), 3, 'RGB SGR';
is visible-width("a\e[Kb"), 2, 'CSI erase-line stripped';
is visible-width("a\e[2Jb"), 2, 'CSI clear stripped';
is visible-width("a\e[1Gb"), 2, 'CSI cursor-column stripped';
is visible-width("a\e[5Bb"), 5, 'CSI cursor-down NOT stripped (final B outside mGKHJ)';
is visible-width("\e]0;title\a"), 0, 'OSC title (BEL)';
is visible-width("\e]0;title\e\\"), 0, 'OSC title (ST)';
is visible-width("\e]8;;http://x\e\\link\e]8;;\e\\"), 4, 'OSC 8 hyperlink';
is visible-width("\e_G1234\a"), 0, 'APC sequence (BEL)';
is visible-width("\e_G1234\e\\"), 0, 'APC sequence (ST)';
is visible-width("\e[999"), 4, 'unterminated CSI: kept literally';
is visible-width("\e[31m"), 0, 'terminated CSI: stripped';

# --- wrapped/newline text ---
is visible-width("a\nb"), 2, 'newline counted as width 1 grapheme pair (JS parity)';

done-testing;
