//! Session panel — compact port of native/src/Panel.swift: header with
//! XP progress, per-session cards (click = acknowledge), and settings
//! (species picker, sound, walk).

use crate::proto::{fmt_age, fmt_tokens, Snapshot};
use crate::sprites::Assets;
use gtk::glib;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

pub type CmdSender = Rc<dyn Fn(serde_json::Value)>;

pub struct Panel {
    pub window: gtk::Window,
    header: gtk::Label,
    xp_bar: gtk::ProgressBar,
    mode_line: gtk::Label,
    cards: gtk::ListBox,
    species: gtk::ComboBoxText,
    sound: gtk::CheckButton,
    walk: gtk::CheckButton,
    card_paths: Rc<RefCell<Vec<String>>>,
    refreshing: Rc<RefCell<bool>>,
}

fn phase_color(phase: &str) -> &'static str {
    match phase {
        "ready" => "#ffd166",
        "input" => "#f28ca8",
        "stalled" => "#d4a373",
        "working" | "busy" => "#a6e3a1",
        _ => "#7f849c",
    }
}

impl Panel {
    pub fn new(assets: &Assets, send: CmdSender) -> Self {
        let window = gtk::Window::new(gtk::WindowType::Toplevel);
        window.set_decorated(false);
        window.set_keep_above(true);
        window.set_skip_taskbar_hint(true);
        window.set_skip_pager_hint(true);
        window.set_type_hint(gtk::gdk::WindowTypeHint::Utility);
        // open where the user just clicked (the pet) — WM-native placement,
        // no position() math, works on Mutter/XWayland where manual moves
        // right after show_all race the map
        window.set_position(gtk::WindowPosition::Mouse);
        window.set_default_size(330, -1);
        window.style_context().add_class("pet-panel");
        // closing via the WM must hide, not destroy — the panel is reused
        window.connect_delete_event(|w, _| {
            w.hide();
            glib::Propagation::Stop
        });

        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.set_margin_top(12);
        root.set_margin_bottom(12);
        root.set_margin_start(12);
        root.set_margin_end(12);

        let header = gtk::Label::new(None);
        header.set_xalign(0.0);
        let xp_bar = gtk::ProgressBar::new();
        let mode_line = gtk::Label::new(None);
        mode_line.set_xalign(0.0);
        root.pack_start(&header, false, false, 0);
        root.pack_start(&xp_bar, false, false, 0);
        root.pack_start(&mode_line, false, false, 0);

        let cards = gtk::ListBox::new();
        cards.set_selection_mode(gtk::SelectionMode::None);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .propagate_natural_height(true)
            .max_content_height(420)
            .build();
        scroll.add(&cards);
        root.pack_start(&scroll, true, true, 0);

        let card_paths: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(vec![]));
        {
            let send = send.clone();
            let card_paths = card_paths.clone();
            cards.connect_row_activated(move |_, row| {
                let idx = row.index();
                if idx >= 0 {
                    if let Some(path) = card_paths.borrow().get(idx as usize) {
                        // clicking a card = you saw that session (per-card ack)
                        send(serde_json::json!({"cmd": "ack", "path": path}));
                    }
                }
            });
        }

        // --- settings ▸
        let refreshing = Rc::new(RefCell::new(false));
        let settings = gtk::Expander::new(Some("settings ▸"));
        let sbox = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let species = gtk::ComboBoxText::new();
        for key in &assets.order {
            let name = assets
                .species
                .get(key)
                .map(|s| s.name.as_str())
                .unwrap_or(key);
            species.append(Some(key), name);
        }
        {
            let send = send.clone();
            let refreshing = refreshing.clone();
            species.connect_changed(move |c| {
                if *refreshing.borrow() {
                    return;
                }
                if let Some(id) = c.active_id() {
                    send(serde_json::json!({"cmd": "pick_species", "key": id.as_str()}));
                }
            });
        }
        let sound = gtk::CheckButton::with_label("sound");
        {
            let send = send.clone();
            let refreshing = refreshing.clone();
            sound.connect_toggled(move |b| {
                if !*refreshing.borrow() {
                    send(serde_json::json!({"cmd": "set", "key": "sound",
                                            "value": b.is_active()}));
                }
            });
        }
        let walk = gtk::CheckButton::with_label("let the pet wander around");
        {
            let send = send.clone();
            let refreshing = refreshing.clone();
            walk.connect_toggled(move |b| {
                if !*refreshing.borrow() {
                    send(serde_json::json!({"cmd": "set", "key": "walk",
                                            "value": b.is_active()}));
                }
            });
        }
        sbox.pack_start(&species, false, false, 0);
        sbox.pack_start(&sound, false, false, 0);
        sbox.pack_start(&walk, false, false, 0);
        settings.add(&sbox);
        root.pack_start(&settings, false, false, 0);

        window.add(&root);
        Panel {
            window,
            header,
            xp_bar,
            mode_line,
            cards,
            species,
            sound,
            walk,
            card_paths,
            refreshing,
        }
    }

    pub fn refresh(&self, snap: &Snapshot, assets: &Assets) {
        *self.refreshing.borrow_mut() = true;
        let pet = &snap.pet;
        let sp_name = assets
            .species
            .get(&pet.species)
            .map(|s| s.name.clone())
            .unwrap_or_else(|| pet.species.clone());
        let name = if pet.hatched {
            pet.name.clone().unwrap_or(sp_name)
        } else {
            "???".to_string()
        };
        let crown = if pet.stage == "legendary" { "★ " } else { "" };
        self.header.set_markup(&format!(
            "<b>{}{} · Lv.{}</b>  <span foreground='#7f849c'>{} · {} xp</span>",
            crown,
            glib::markup_escape_text(&name),
            pet.level,
            pet.stage,
            pet.xp
        ));
        match pet.stage_hi {
            Some(hi) if hi > pet.stage_lo => {
                self.xp_bar.set_visible(true);
                self.xp_bar.set_fraction(
                    ((pet.xp - pet.stage_lo) as f64 / (hi - pet.stage_lo) as f64)
                        .clamp(0.0, 1.0),
                );
            }
            _ => self.xp_bar.set_visible(false),
        }
        let n_input = snap.sessions.iter().filter(|s| s.phase == "input").count();
        self.mode_line.set_markup(&format!(
            "<span foreground='#7f849c'>{} · {} session{}{}</span>",
            snap.mode,
            snap.sessions.len(),
            if snap.sessions.len() == 1 { "" } else { "s" },
            if n_input > 0 {
                format!(" · <span foreground='#f28ca8'>{n_input} need you</span>")
            } else {
                String::new()
            }
        ));

        for child in self.cards.children() {
            self.cards.remove(&child);
        }
        let mut paths = self.card_paths.borrow_mut();
        paths.clear();
        for s in &snap.sessions {
            let row = gtk::ListBoxRow::new();
            let card = gtk::Box::new(gtk::Orientation::Vertical, 2);
            card.style_context().add_class("card");
            let top = gtk::Label::new(None);
            top.set_xalign(0.0);
            top.set_ellipsize(gtk::pango::EllipsizeMode::End);
            let ctx = s.ctx.map(|c| format!(" · {}", fmt_tokens(c))).unwrap_or_default();
            top.set_markup(&format!(
                "<span foreground='{}'>●</span> <b>{}</b> \
                 <span foreground='#7f849c'>{} · {}{}</span>",
                phase_color(&s.phase),
                glib::markup_escape_text(&s.project),
                s.provider,
                fmt_age(s.age),
                ctx
            ));
            let doing = gtk::Label::new(Some(&s.doing));
            doing.set_xalign(0.0);
            doing.set_ellipsize(gtk::pango::EllipsizeMode::End);
            doing.style_context().add_class("dim");
            card.pack_start(&top, false, false, 0);
            card.pack_start(&doing, false, false, 0);
            row.add(&card);
            self.cards.add(&row);
            paths.push(s.path.clone());
        }
        self.cards.show_all();

        if self.species.active_id().map(|s| s.to_string()) != Some(pet.species.clone()) {
            self.species.set_active_id(Some(&pet.species));
        }
        self.sound.set_active(pet.sound);
        self.walk.set_active(pet.walk);
        *self.refreshing.borrow_mut() = false;
    }
}
