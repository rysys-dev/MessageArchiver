//! Text as the downloads write it: HTML character references (Tinder's `don&rsquo;t`), and CSV
//! (Hinge's newer download: a byte-order mark, CRLF, quoted fields over several lines).

/// Text with its character references decoded: numeric ones and the common named ones. An
/// unknown name is left as written.
pub fn decode(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let decoded = rest.find(';').filter(|&e| e <= 12).and_then(|e| {
            let name = &rest[1..e];
            let c = if let Some(n) = name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
                u32::from_str_radix(n, 16).ok().and_then(char::from_u32)
            } else if let Some(n) = name.strip_prefix('#') {
                n.parse().ok().and_then(char::from_u32)
            } else {
                named(name)
            };
            c.map(|c| (c, e))
        });
        match decoded {
            Some((c, e)) => {
                out.push(c);
                rest = &rest[e + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn named(name: &str) -> Option<char> {
    Some(match name {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => '\u{a0}',
        "ldquo" => '“',
        "rdquo" => '”',
        "lsquo" => '‘',
        "rsquo" => '’',
        "hellip" => '…',
        "mdash" => '—',
        "ndash" => '–',
        "bull" => '•',
        "deg" => '°',
        "euro" => '€',
        "pound" => '£',
        _ => return None,
    })
}

/// A CSV table's rows, each a map from its header's names (lower-case, trimmed) to the field.
pub fn csv(src: &str) -> Vec<std::collections::HashMap<String, String>> {
    let src = src.strip_prefix('\u{feff}').unwrap_or(src);
    let mut rows: Vec<Vec<String>> = vec![];
    let (mut row, mut field, mut quoted, mut chars) = (vec![], String::new(), false, src.chars().peekable());
    while let Some(c) = chars.next() {
        match (quoted, c) {
            (true, '"') if chars.peek() == Some(&'"') => {
                chars.next();
                field.push('"');
            }
            (true, '"') => quoted = false,
            (true, c) => field.push(c),
            (false, '"') if field.is_empty() => quoted = true,
            (false, ',') => row.push(std::mem::take(&mut field)),
            (false, '\r') => {}
            (false, '\n') => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            (false, c) => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    let mut it = rows.into_iter();
    let Some(header) = it.next() else { return vec![] };
    let header: Vec<String> = header.iter().map(|h| h.trim().to_lowercase()).collect();
    it.filter(|r| r.iter().any(|f| !f.is_empty())).map(|r| header.iter().cloned().zip(r).collect()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entities() {
        assert_eq!(decode("don&rsquo;t &amp; &#128512; &bogus;"), "don’t & 😀 &bogus;");
    }

    #[test]
    fn csv_rows() {
        let rows = csv("\u{feff}Timestamp,message,action\r\n2026-09-01 18:22:10,\"See you, at 7?\nOK \"\"yes\"\"\",sent\r\n\r\n");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["timestamp"], "2026-09-01 18:22:10");
        assert_eq!(rows[0]["message"], "See you, at 7?\nOK \"yes\"");
        assert_eq!(rows[0]["action"], "sent");
    }
}
