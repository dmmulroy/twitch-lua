use std::io::BufRead;
fn main() {
    // input lines: width \t indent \t text ; output: lines joined by \x1f
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let mut parts = line.splitn(3, '\t');
        let width: usize = parts.next().unwrap().parse().unwrap();
        let indent: usize = parts.next().unwrap().parse().unwrap();
        let text = parts.next().unwrap_or("");
        let prefix = " ".repeat(indent);
        let opts = textwrap::Options::new(width).initial_indent(&prefix);
        let lines: Vec<String> = textwrap::wrap(text, opts).into_iter().enumerate()
            .map(|(i, l)| if i == 0 { l.get(indent.min(l.len())..).unwrap_or("").to_string() } else { l.to_string() })
            .collect();
        println!("{}", lines.join("\u{1f}"));
    }
}
