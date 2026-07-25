//! Sprite assets (assets.json + drop-in sprites/*.json packs) and cairo
//! rendering. Port of native/src/Sprites.swift.

use gtk::cairo::Context;
use std::collections::HashMap;
use std::fs;

pub struct Species {
    pub name: String,
    pub palette: HashMap<char, (f64, f64, f64)>,
    pub rows: Vec<String>,
    // optional hand-authored walk cycle; absent → procedural leg-shuffle
    pub walk_frames: Vec<Vec<String>>,
}

pub struct Assets {
    pub order: Vec<String>,
    pub species: HashMap<String, Species>,
}

fn hex_color(hex: &str) -> (f64, f64, f64) {
    let h = hex.trim_start_matches('#');
    if h.len() != 6 {
        return (1.0, 1.0, 1.0);
    }
    match u32::from_str_radix(h, 16) {
        Ok(v) => (
            ((v >> 16) & 0xFF) as f64 / 255.0,
            ((v >> 8) & 0xFF) as f64 / 255.0,
            (v & 0xFF) as f64 / 255.0,
        ),
        Err(_) => (1.0, 1.0, 1.0),
    }
}

fn make_species(key: &str, s: &serde_json::Value) -> Species {
    let mut palette = HashMap::new();
    if let Some(pal) = s.get("palette").and_then(|v| v.as_object()) {
        for (ch, hex) in pal {
            if let (Some(c), Some(h)) = (ch.chars().next(), hex.as_str()) {
                palette.insert(c, hex_color(h));
            }
        }
    }
    let rows: Vec<String> = s
        .get("rows")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|r| r.as_str().map(String::from)).collect())
        .unwrap_or_default();
    let walk_frames: Vec<Vec<String>> = s
        .get("walk")
        .and_then(|v| v.as_array())
        .map(|frames| {
            frames
                .iter()
                .filter_map(|f| {
                    let fr: Vec<String> = f
                        .as_array()?
                        .iter()
                        .filter_map(|r| r.as_str().map(String::from))
                        .collect();
                    (fr.len() == rows.len()).then_some(fr)
                })
                .collect()
        })
        .unwrap_or_default();
    Species {
        name: s
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or(key)
            .to_string(),
        palette,
        rows,
        walk_frames,
    }
}

/// Built-ins from assets.json (embedded or repo copy), then user packs from
/// sprites/<key>.json — packs OVERWRITE built-ins; malformed files skipped.
pub fn load_assets(assets_json: &str, sprites_dir: Option<&std::path::Path>) -> Assets {
    let root: serde_json::Value =
        serde_json::from_str(assets_json).expect("assets.json is malformed");
    let mut order: Vec<String> = root
        .get("order")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect())
        .unwrap_or_default();
    let mut species = HashMap::new();
    if let Some(dict) = root.get("species").and_then(|v| v.as_object()) {
        for (key, s) in dict {
            species.insert(key.clone(), make_species(key, s));
        }
    }
    if let Some(dir) = sprites_dir {
        let mut files: Vec<_> = fs::read_dir(dir)
            .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
            .unwrap_or_default();
        files.sort();
        for f in files {
            if f.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Ok(text) = fs::read_to_string(&f) else { continue };
            let Ok(s) = serde_json::from_str::<serde_json::Value>(&text) else {
                continue;
            };
            let sp_rows = s.get("rows").and_then(|v| v.as_array());
            if sp_rows.map_or(true, |r| r.is_empty()) {
                continue;
            }
            let key = f
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or_default()
                .to_string();
            species.insert(key.clone(), make_species(&key, &s));
            // "egg" stays out of the picker — picking a sprite is what hatches
            if key != "egg" && !order.contains(&key) {
                order.push(key);
            }
        }
    }
    Assets { order, species }
}

/// Draw at (ox, oy_top) — cairo y grows DOWN, row 0 is the sprite's top row.
#[allow(clippy::too_many_arguments)]
pub fn draw_sprite(
    ctx: &Context,
    sp: &Species,
    scale: f64,
    ox: f64,
    oy_top: f64,
    eyes_closed: bool,
    mirrored: bool,
    walk_frame: Option<usize>,
) {
    let mut rows = &sp.rows;
    let mut shuffle: i64 = 0;
    if let Some(f) = walk_frame {
        if !sp.walk_frames.is_empty() {
            rows = &sp.walk_frames[f % sp.walk_frames.len()];
        } else {
            // procedural 2-frame leg shuffle: bottom rows scissor by one px
            shuffle = if f % 2 == 0 { 1 } else { -1 };
        }
    }
    let row_count = rows.len() as i64;
    let col_count = rows.first().map_or(16, |r| r.chars().count() as i64);
    // snap cell edges to whole pixels — unsnapped rects antialias into
    // hairline seams between rows (same fix as the Mac renderer)
    let xs: Vec<f64> = (-1..=col_count + 1)
        .map(|i| (ox + i as f64 * scale).round())
        .collect();
    let ys: Vec<f64> = (0..=row_count)
        .map(|j| (oy_top + j as f64 * scale).round())
        .collect();
    for (y, row) in rows.iter().enumerate() {
        let y = y as i64;
        let mut step_x: i64 = 0;
        if shuffle != 0 && y >= row_count - 2 {
            step_x = if y == row_count - 1 { shuffle } else { -shuffle };
        }
        for (x, ch) in row.chars().enumerate() {
            let x = x as i64;
            let mut c = ch;
            if c == '.' {
                continue;
            }
            if eyes_closed && (c == 'o' || c == 'w') {
                c = 'X';
            }
            let Some(&(r, g, b)) = sp.palette.get(&c) else { continue };
            ctx.set_source_rgb(r, g, b);
            let px = (if mirrored { col_count - 1 - x } else { x }
                + if mirrored { -step_x } else { step_x }
                + 1) as usize;
            let yy = y as usize;
            ctx.rectangle(
                xs[px],
                ys[yy],
                xs[px + 1] - xs[px],
                ys[yy + 1] - ys[yy],
            );
            let _ = ctx.fill();
        }
    }
}
