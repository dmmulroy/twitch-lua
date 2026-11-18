#![allow(dead_code, non_upper_case_globals)]
mod lb {
    include!("UNICODE_LINEBREAK_SRC/src/shared.rs");
    include!("UNICODE_LINEBREAK_SRC/src/tables.rs");
    pub fn class_of(codepoint: u32) -> u8 {
        const BMP_INDEX_LENGTH: u32 = BMP_LIMIT >> BMP_SHIFT;
        const OMITTED_BMP_INDEX_1_LENGTH: u32 = BMP_LIMIT >> SHIFT_1;
        let data_pos = if codepoint < BMP_LIMIT {
            let i = codepoint >> BMP_SHIFT;
            BREAK_PROP_TRIE_INDEX[i as usize] + (codepoint & (BMP_DATA_BLOCK_LENGTH - 1)) as u16
        } else if codepoint < BREAK_PROP_TRIE_HIGH_START {
            let i1 = codepoint >> SHIFT_1;
            let i2 = BREAK_PROP_TRIE_INDEX[(i1 + BMP_INDEX_LENGTH - OMITTED_BMP_INDEX_1_LENGTH) as usize]
                + ((codepoint >> SHIFT_2) & (INDEX_2_BLOCK_LENGTH - 1)) as u16;
            let i3_block = BREAK_PROP_TRIE_INDEX[i2 as usize];
            let i3_pos = ((codepoint >> SHIFT_3) & (INDEX_3_BLOCK_LENGTH - 1)) as u16;
            let data_block = BREAK_PROP_TRIE_INDEX[(i3_block + i3_pos) as usize];
            data_block + (codepoint & (SMALL_DATA_BLOCK_LENGTH - 1)) as u16
        } else {
            return XX as u8;
        };
        BREAK_PROP_TRIE_DATA[data_pos as usize] as u8
    }
    pub fn pair(state: usize, class: usize) -> u8 { PAIR_TABLE[state][class] }
    pub const OUT_SOT: u8 = sot;
    pub const OUT_EOT: u8 = eot;
    pub const OUT_ZWJ: u8 = BreakClass::ZeroWidthJoiner as u8;
    pub const OUT_ALLOWED: u8 = ALLOWED_BREAK_BIT;
    pub const OUT_MANDATORY: u8 = MANDATORY_BREAK_BIT;
    pub const STATES: usize = 53;
    pub const CLASSES: usize = 44;
}
use unicode_width::UnicodeWidthChar;
fn ranges(value_of: impl Fn(u32) -> u8, skip: u8) -> Vec<(u32, u32, u8)> {
    let mut out: Vec<(u32, u32, u8)> = Vec::new();
    for cp in 0..=0x10FFFFu32 {
        let v = value_of(cp);
        if let Some(last) = out.last_mut() { if last.2 == v && last.1 + 1 == cp { last.1 = cp; continue; } }
        out.push((cp, cp, v));
    }
    out.into_iter().filter(|r| r.2 != skip).collect()
}
fn main() {
    let mut s = String::new();
    s.push_str("-- Generated from the Rust crates twitch-tui (twt) uses: unicode-linebreak 0.1.5 (Unicode 15.0)\n");
    s.push_str("-- and unicode-width 0.2.2, plus Rust's char::is_alphanumeric. Do not edit; scripts/generate_unicode_tables.sh\n-- rebuilds it.\nlocal M = {}\n");
    // widths: store ranges whose width is not 1; surrogates and non-characters read as 1
    let w = ranges(|cp| match char::from_u32(cp) { Some(c) => match c.width() { Some(w) => w as u8, None => 0 }, None => 1 }, 1);
    s.push_str("-- { first, last, cells } for every code point whose width is not 1, sorted\nM.CHARACTER_WIDTH_RANGES = {\n");
    for (a, b, v) in &w { s.push_str(&format!("{{{a},{b},{v}}},")); }
    s.push_str("\n}\n");
    let a = ranges(|cp| match char::from_u32(cp) { Some(ch) if ch.is_alphanumeric() => 1, _ => 0 }, 0);
    s.push_str("-- { first, last, 1 } code points for which Rust's char::is_alphanumeric is true, sorted\nM.ALPHANUMERIC_RANGES = {\n");
    for (x, y, v) in &a { s.push_str(&format!("{{{x},{y},{v}}},")); }
    s.push_str("\n}\n");
    let c = ranges(lb::class_of, 255);
    s.push_str("-- { first, last, class } line break class of every code point (UAX #14), sorted\nM.LINE_BREAK_CLASS_RANGES = {\n");
    for (a, b, v) in &c { s.push_str(&format!("{{{a},{b},{v}}},")); }
    s.push_str("\n}\n-- PAIR_TABLE[state + 1][class + 1]\nM.LINE_BREAK_PAIR_TABLE = {\n");
    for st in 0..lb::STATES { s.push_str("{"); for cl in 0..lb::CLASSES { s.push_str(&format!("{},", lb::pair(st, cl))); } s.push_str("},\n"); }
    s.push_str("}\n");
    s.push_str(&format!("M.LINE_BREAK_SOT = {}\nM.LINE_BREAK_EOT = {}\nM.LINE_BREAK_ZWJ = {}\nM.LINE_BREAK_ALLOWED_BIT = {}\nM.LINE_BREAK_MANDATORY_BIT = {}\nreturn M\n", lb::OUT_SOT, lb::OUT_EOT, lb::OUT_ZWJ, lb::OUT_ALLOWED, lb::OUT_MANDATORY));
    std::fs::write(std::env::args().nth(1).unwrap(), s).unwrap();
    eprintln!("width ranges {}, alphanumeric ranges {}, class ranges {}", w.len(), a.len(), c.len());
}
