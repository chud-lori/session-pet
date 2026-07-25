//! Core ↔ face NDJSON protocol (see linux/core.py docstring).

use serde::Deserialize;

#[derive(Deserialize, Clone)]
#[serde(tag = "type")]
pub enum Msg {
    #[serde(rename = "snapshot")]
    Snapshot(Snapshot),
    #[serde(rename = "sound")]
    Sound(SoundEvent),
}

#[derive(Deserialize, Clone, Default)]
pub struct Snapshot {
    #[allow(dead_code)]
    pub now: f64,
    pub mode: String,
    pub needs_attention: bool,
    #[serde(default)]
    pub unhide: bool,
    pub alert_until: f64,
    pub excite_until: f64,
    pub pet: Pet,
    pub sessions: Vec<Session>,
}

#[derive(Deserialize, Clone, Default)]
pub struct Pet {
    pub species: String,
    pub name: Option<String>,
    pub hatched: bool,
    pub stage: String,
    pub xp: i64,
    pub stage_lo: i64,
    pub stage_hi: Option<i64>,
    pub level: i64,
    pub sound: bool,
    pub walk: bool,
}

#[derive(Deserialize, Clone)]
pub struct Session {
    pub path: String,
    pub age: f64,
    pub phase: String,
    pub doing: String,
    pub provider: String,
    pub ctx: Option<i64>,
    #[allow(dead_code)]
    pub snippet: String,
    #[allow(dead_code)]
    pub label: String,
    #[allow(dead_code)]
    pub cwd: Option<String>,
    pub project: String,
}

#[derive(Deserialize, Clone)]
pub struct SoundEvent {
    #[allow(dead_code)]
    pub kind: String,
    pub volume: f64,
    pub double: bool,
    pub path: String,
}

pub fn fmt_age(age: f64) -> String {
    if age < 60.0 {
        format!("{}s", age as i64)
    } else if age < 3600.0 {
        format!("{}m", (age / 60.0) as i64)
    } else {
        format!("{}h", (age / 3600.0) as i64)
    }
}

pub fn fmt_tokens(n: i64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1000 {
        format!("{}k", n / 1000)
    } else {
        format!("{n}")
    }
}
