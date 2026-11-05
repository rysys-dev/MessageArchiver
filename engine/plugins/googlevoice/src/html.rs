//! Just enough HTML for Google Voice's Takeout pages: tags with their attributes, and text with
//! its entities decoded. The pages look like XHTML but aren't well-formed (`<br>` unclosed), so
//! nothing is assumed about closing tags: [`Walker`] keeps the open elements, treating void
//! elements as closed and an end tag as closing everything opened after its element.

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    Start { name: String, attrs: Vec<(String, String)> },
    End(String),
    Text(String),
}

const VOID: &[&str] = &["br", "img", "meta", "link", "hr", "input", "source", "wbr", "col", "area", "base", "embed", "param", "track"];

pub fn tokens(s: &str) -> Vec<Tok> {
    let mut out = vec![];
    let mut rest = s;
    while !rest.is_empty() {
        let Some(lt) = rest.find('<') else {
            push_text(&mut out, rest);
            break;
        };
        push_text(&mut out, &rest[..lt]);
        rest = &rest[lt..];
        if let Some(r) = rest.strip_prefix("<!--") {
            rest = r.find("-->").map_or("", |i| &r[i + 3..]);
            continue;
        }
        if rest.starts_with("<!") || rest.starts_with("<?") {
            rest = rest.find('>').map_or("", |i| &rest[i + 1..]);
            continue;
        }
        let Some(gt) = tag_end(rest) else {
            push_text(&mut out, rest);
            break;
        };
        let inner = &rest[1..gt];
        rest = &rest[gt + 1..];
        if let Some(name) = inner.strip_prefix('/') {
            out.push(Tok::End(name.trim().to_ascii_lowercase()));
            continue;
        }
        let inner = inner.trim_end_matches('/');
        let name_end = inner.find(|c: char| c.is_whitespace()).unwrap_or(inner.len());
        let name = inner[..name_end].to_ascii_lowercase();
        if name.is_empty() || !name.chars().next().unwrap().is_ascii_alphabetic() {
            push_text(&mut out, &format!("<{inner}>"));
            continue;
        }
        out.push(Tok::Start { name, attrs: attributes(&inner[name_end..]) });
    }
    out
}

/// The `>` that ends a tag, outside quoted attribute values.
fn tag_end(s: &str) -> Option<usize> {
    let mut quote = None;
    for (i, c) in s.char_indices().skip(1) {
        match (quote, c) {
            (None, '"' | '\'') => quote = Some(c),
            (Some(q), c) if c == q => quote = None,
            (None, '>') => return Some(i),
            _ => {}
        }
    }
    None
}

fn push_text(out: &mut Vec<Tok>, s: &str) {
    if !s.is_empty() {
        out.push(Tok::Text(decode(s)));
    }
}

fn attributes(mut s: &str) -> Vec<(String, String)> {
    let mut out = vec![];
    loop {
        s = s.trim_start();
        if s.is_empty() {
            return out;
        }
        let end = s.find(|c: char| c == '=' || c.is_whitespace()).unwrap_or(s.len());
        let name = s[..end].to_ascii_lowercase();
        s = s[end..].trim_start();
        let value = if let Some(r) = s.strip_prefix('=') {
            let r = r.trim_start();
            match r.chars().next() {
                Some(q @ ('"' | '\'')) => {
                    let close = r[1..].find(q).map_or(r.len(), |i| i + 1);
                    let v = &r[1..close];
                    s = r.get(close + 1..).unwrap_or("");
                    v
                }
                _ => {
                    let close = r.find(char::is_whitespace).unwrap_or(r.len());
                    s = &r[close..];
                    &r[..close]
                }
            }
        } else {
            ""
        };
        if name.is_empty() {
            // Stray characters: skip one, so the loop always moves on.
            s = s.get(1..).unwrap_or("");
            continue;
        }
        out.push((name, decode(value)));
    }
}

/// Text with its character references decoded: numeric ones, and the named ones Google's pages
/// use. An unknown name is left as written.
pub fn decode(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let end = rest.find(';').filter(|&e| e <= 12);
        let decoded = end.and_then(|e| {
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
        "copy" => '©',
        "reg" => '®',
        "trade" => '™',
        "euro" => '€',
        "pound" => '£',
        "bull" => '•',
        "deg" => '°',
        _ => return None,
    })
}

/// An open element: its name and classes.
#[derive(Debug, Clone)]
pub struct Open {
    pub name: String,
    pub classes: Vec<String>,
}

/// The open elements while walking a page's tokens.
#[derive(Default)]
pub struct Walker {
    pub stack: Vec<Open>,
}

impl Walker {
    /// Takes one token; returns the element an end tag closed, if any.
    pub fn step(&mut self, t: &Tok) -> Option<Open> {
        match t {
            Tok::Start { name, attrs } if !VOID.contains(&name.as_str()) => {
                self.stack.push(Open { name: name.clone(), classes: class_list(attrs) });
                None
            }
            Tok::End(name) => {
                let i = self.stack.iter().rposition(|o| &o.name == name)?;
                self.stack.drain(i..).next()
            }
            _ => None,
        }
    }

    /// Whether an element `name` with class `class` is open.
    pub fn inside(&self, name: &str, class: &str) -> bool {
        self.stack.iter().any(|o| o.name == name && o.classes.iter().any(|c| c == class))
    }
}

pub fn class_list(attrs: &[(String, String)]) -> Vec<String> {
    attr(attrs, "class").map(|c| c.split_whitespace().map(str::to_string).collect()).unwrap_or_default()
}

pub fn attr<'a>(attrs: &'a [(String, String)], name: &str) -> Option<&'a str> {
    attrs.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
}

pub fn has_class(attrs: &[(String, String)], class: &str) -> bool {
    class_list(attrs).iter().any(|c| c == class)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_text_and_entities() {
        let t = tokens("<?xml version=\"1.0\" ?><!DOCTYPE html><q class='a b'>x &amp; y&#8239;z<br>&ldquo;w&rdquo; &bogus; &#x1F600;</q><img src=\"a>b\" />");
        assert_eq!(t[0], Tok::Start { name: "q".into(), attrs: vec![("class".into(), "a b".into())] });
        assert_eq!(t[1], Tok::Text("x & y\u{202f}z".into()));
        assert_eq!(t[2], Tok::Start { name: "br".into(), attrs: vec![] });
        assert_eq!(t[3], Tok::Text("“w” &bogus; 😀".into()));
        assert_eq!(t[4], Tok::End("q".into()));
        assert_eq!(t[5], Tok::Start { name: "img".into(), attrs: vec![("src".into(), "a>b".into())] });
    }

    #[test]
    fn an_unclosed_element_closes_with_its_parent() {
        let mut w = Walker::default();
        for t in tokens("<div class=\"message\"><q>hi<br><span>") {
            w.step(&t);
        }
        assert!(w.inside("div", "message"));
        let closed = w.step(&Tok::End("div".into())).unwrap();
        assert_eq!(closed.name, "div");
        assert!(w.stack.is_empty());
    }
}
