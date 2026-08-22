// Minimal recursive-descent JSON parser producing voxgig struct Values.
// Keeps the SDK runtime dependency-free (the struct port has jsonify for
// serialisation; this is the matching parse). Object key order is
// preserved (OrderedMap), numbers are f64 (JSON semantics).

use crate::utility::voxgigstruct::ordered_map::OrderedMap;
use crate::utility::voxgigstruct::Value;

pub fn json_parse(src: &str) -> Result<Value, String> {
    let bytes: Vec<char> = src.chars().collect();
    let mut p = Parser { c: &bytes, i: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.c.len() {
        return Err(format!("unexpected trailing input at {}", p.i));
    }
    Ok(v)
}

struct Parser<'a> {
    c: &'a [char],
    i: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<char> {
        self.c.get(self.i).copied()
    }

    fn ws(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
                self.i += 1;
            } else {
                break;
            }
        }
    }

    fn expect(&mut self, ch: char) -> Result<(), String> {
        if self.peek() == Some(ch) {
            self.i += 1;
            Ok(())
        } else {
            Err(format!("expected '{}' at {}", ch, self.i))
        }
    }

    fn lit(&mut self, word: &str, val: Value) -> Result<Value, String> {
        for wc in word.chars() {
            if self.peek() != Some(wc) {
                return Err(format!("invalid literal at {}", self.i));
            }
            self.i += 1;
        }
        Ok(val)
    }

    fn value(&mut self) -> Result<Value, String> {
        match self.peek() {
            Some('{') => self.object(),
            Some('[') => self.array(),
            Some('"') => Ok(Value::Str(self.string()?)),
            Some('t') => self.lit("true", Value::Bool(true)),
            Some('f') => self.lit("false", Value::Bool(false)),
            Some('n') => self.lit("null", Value::Null),
            Some(ch) if ch == '-' || ch.is_ascii_digit() => self.number(),
            other => Err(format!("unexpected {:?} at {}", other, self.i)),
        }
    }

    fn object(&mut self) -> Result<Value, String> {
        self.expect('{')?;
        let mut m = OrderedMap::new();
        self.ws();
        if self.peek() == Some('}') {
            self.i += 1;
            return Ok(Value::map(m));
        }
        loop {
            self.ws();
            let key = self.string()?;
            self.ws();
            self.expect(':')?;
            self.ws();
            let val = self.value()?;
            m.insert(key, val);
            self.ws();
            match self.peek() {
                Some(',') => {
                    self.i += 1;
                }
                Some('}') => {
                    self.i += 1;
                    return Ok(Value::map(m));
                }
                other => return Err(format!("unexpected {:?} in object at {}", other, self.i)),
            }
        }
    }

    fn array(&mut self) -> Result<Value, String> {
        self.expect('[')?;
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(']') {
            self.i += 1;
            return Ok(Value::list(items));
        }
        loop {
            self.ws();
            items.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(',') => {
                    self.i += 1;
                }
                Some(']') => {
                    self.i += 1;
                    return Ok(Value::list(items));
                }
                other => return Err(format!("unexpected {:?} in array at {}", other, self.i)),
            }
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            match self.peek() {
                None => return Err("unterminated string".to_string()),
                Some('"') => {
                    self.i += 1;
                    return Ok(out);
                }
                Some('\\') => {
                    self.i += 1;
                    match self.peek() {
                        Some('"') => out.push('"'),
                        Some('\\') => out.push('\\'),
                        Some('/') => out.push('/'),
                        Some('b') => out.push('\u{0008}'),
                        Some('f') => out.push('\u{000C}'),
                        Some('n') => out.push('\n'),
                        Some('r') => out.push('\r'),
                        Some('t') => out.push('\t'),
                        Some('u') => {
                            let mut code = 0u32;
                            for _ in 0..4 {
                                self.i += 1;
                                let d = self
                                    .peek()
                                    .and_then(|c| c.to_digit(16))
                                    .ok_or_else(|| format!("bad \\u escape at {}", self.i))?;
                                code = code * 16 + d;
                            }
                            // Surrogate pairs.
                            if (0xD800..0xDC00).contains(&code) {
                                if self.c.get(self.i + 1) == Some(&'\\')
                                    && self.c.get(self.i + 2) == Some(&'u')
                                {
                                    self.i += 2;
                                    let mut low = 0u32;
                                    for _ in 0..4 {
                                        self.i += 1;
                                        let d = self
                                            .peek()
                                            .and_then(|c| c.to_digit(16))
                                            .ok_or_else(|| {
                                                format!("bad \\u escape at {}", self.i)
                                            })?;
                                        low = low * 16 + d;
                                    }
                                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                                }
                            }
                            out.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
                        }
                        other => return Err(format!("bad escape {:?} at {}", other, self.i)),
                    }
                    self.i += 1;
                }
                Some(ch) => {
                    out.push(ch);
                    self.i += 1;
                }
            }
        }
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.i;
        if self.peek() == Some('-') {
            self.i += 1;
        }
        while let Some(ch) = self.peek() {
            if ch.is_ascii_digit() || ch == '.' || ch == 'e' || ch == 'E' || ch == '+' || ch == '-'
            {
                self.i += 1;
            } else {
                break;
            }
        }
        let txt: String = self.c[start..self.i].iter().collect();
        txt.parse::<f64>()
            .map(Value::Num)
            .map_err(|e| format!("bad number '{}': {}", txt, e))
    }
}
