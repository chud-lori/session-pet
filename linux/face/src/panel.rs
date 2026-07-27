//! Session panel — port of native/src/Panel.swift's design: header with XP
//! progress + mode chip, rounded per-session cards (tinted project pill,
//! title, status; click = acknowledge), and settings.

use crate::proto::{fmt_age, fmt_tokens, Snapshot};
use crate::sprites::Assets;
use gtk::glib;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

pub type CmdSender = Rc<dyn Fn(serde_json::Value)>;

pub struct Panel {
    pub window: gtk::Window,
    /// where to place the panel once the WM has mapped it — moving before
    /// the map races Mutter and the move is silently dropped
    pub place_at: Rc<std::cell::Cell<(i32, i32)>>,
    header: gtk::Label,
    sub: gtk::Label,
    xp_bar: gtk::ProgressBar,
    chip: gtk::Label,
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

// stable per-project badge color, hashed from the project name — same djb2 +
// HSB(hue, 0.55, 0.88) formula as the mac panel (Config.swift projectColor)
fn project_color(name: &str) -> String {
    let mut h: u32 = 5381;
    for b in name.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u32);
    }
    let hue = (h % 360) as f64 / 60.0;
    let (s, v) = (0.55, 0.88);
    let c = v * s;
    let x = c * (1.0 - (hue % 2.0 - 1.0).abs());
    let (r, g, b) = match hue as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = v - c;
    format!(
        "#{:02x}{:02x}{:02x}",
        ((r + m) * 255.0) as u8,
        ((g + m) * 255.0) as u8,
        ((b + m) * 255.0) as u8
    )
}

// project pill: colored text on a translucent tint of the same color —
// per-widget CSS provider, since the tint is per-project
fn badge_label(project: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(project));
    l.set_ellipsize(gtk::pango::EllipsizeMode::End);
    l.set_max_width_chars(18);
    let ctx = l.style_context();
    ctx.add_class("badge");
    let color = project_color(project);
    let css = gtk::CssProvider::new();
    let _ = css.load_from_data(
        format!(".badge {{ color: {color}; background-color: alpha({color}, 0.16); }}")
            .as_bytes(),
    );
    ctx.add_provider(&css, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    l
}

impl Panel {
    pub fn new(assets: &Assets, send: CmdSender) -> Self {
        let window = gtk::Window::new(gtk::WindowType::Toplevel);
        window.set_decorated(false);
        window.set_keep_above(true);
        window.set_skip_taskbar_hint(true);
        window.set_skip_pager_hint(true);
        window.set_type_hint(gtk::gdk::WindowTypeHint::Utility);
        window.set_default_size(340, -1);
        window.style_context().add_class("pet-panel");
        // closing via the WM must hide, not destroy — the panel is reused
        window.connect_delete_event(|w, _| {
            w.hide();
            glib::Propagation::Stop
        });
        // Esc closes
        window.connect_key_press_event(|w, ev| {
            if ev.keyval() == gtk::gdk::keys::constants::Escape {
                w.hide();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });

        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.set_margin_top(14);
        root.set_margin_bottom(12);
        root.set_margin_start(14);
        root.set_margin_end(14);

        let header = gtk::Label::new(None);
        header.set_xalign(0.0);
        let sub = gtk::Label::new(None);
        sub.set_xalign(0.0);
        sub.style_context().add_class("dim");
        let xp_bar = gtk::ProgressBar::new();
        // mode chip ("all idle" / "2 working" / "1 need you") — pill that
        // must not stretch to full width
        let chip = gtk::Label::new(None);
        chip.style_context().add_class("chip");
        let chip_row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        chip_row.pack_start(&chip, false, false, 0);
        root.pack_start(&header, false, false, 0);
        root.pack_start(&sub, false, false, 0);
        root.pack_start(&xp_bar, false, false, 2);
        root.pack_start(&chip_row, false, false, 4);

        let cards = gtk::ListBox::new();
        cards.set_selection_mode(gtk::SelectionMode::None);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .propagate_natural_height(true)
            .max_content_height(440)
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
        sbox.set_margin_top(6);
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

        // outside-click closes, mac-style: any focus loss hides the panel —
        // EXCEPT while the species dropdown is popped up (its grab briefly
        // steals focus and would slam the panel shut mid-pick). The pet
        // window itself never takes focus (set_accept_focus(false)), so
        // clicking the pet keeps plain toggle semantics.
        {
            let combo_open = Rc::new(std::cell::Cell::new(false));
            {
                let combo_open = combo_open.clone();
                species.connect_notify_local(Some("popup-shown"), move |c, _| {
                    combo_open.set(c.property::<bool>("popup-shown"));
                });
            }
            window.connect_focus_out_event(move |w, _| {
                if !combo_open.get() {
                    w.hide();
                }
                glib::Propagation::Proceed
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
        root.pack_start(&settings, false, false, 2);

        window.add(&root);
        let place_at = Rc::new(std::cell::Cell::new((0, 0)));
        {
            let place_at = place_at.clone();
            window.connect_map_event(move |w, _| {
                let (x, y) = place_at.get();
                if (x, y) != (0, 0) {
                    w.move_(x, y);
                }
                glib::Propagation::Proceed
            });
        }
        Panel {
            window,
            place_at,
            header,
            sub,
            xp_bar,
            chip,
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
            "<span size='large'><b>{}{} · Lv.{}</b></span>",
            crown,
            glib::markup_escape_text(&name),
            pet.level
        ));
        match pet.stage_hi {
            Some(hi) if hi > pet.stage_lo => {
                self.sub.set_text(&format!(
                    "{} · {} XP · {} to next stage",
                    pet.stage,
                    pet.xp,
                    hi - pet.xp
                ));
                self.xp_bar.set_visible(true);
                self.xp_bar.set_fraction(
                    ((pet.xp - pet.stage_lo) as f64 / (hi - pet.stage_lo) as f64)
                        .clamp(0.0, 1.0),
                );
            }
            _ => {
                self.sub.set_text(&format!("{} · {} XP · max stage", pet.stage, pet.xp));
                self.xp_bar.set_visible(true);
                self.xp_bar.set_fraction(1.0);
            }
        }

        // mode chip, most urgent first
        let n = |p: &str| snap.sessions.iter().filter(|s| s.phase == p).count();
        let (n_input, n_ready, n_stalled) = (n("input"), n("ready"), n("stalled"));
        let n_active = n("working") + n("busy");
        let (chip_text, chip_color) = if n_input > 0 {
            (format!("{n_input} need you"), "#f28ca8")
        } else if n_stalled > 0 {
            (format!("{n_stalled} stalled"), "#d4a373")
        } else if n_active > 0 {
            (format!("{n_active} working"), "#a6e3a1")
        } else if n_ready > 0 {
            (format!("{n_ready} ready"), "#ffd166")
        } else {
            ("all idle".to_string(), "#7f849c")
        };
        self.chip
            .set_markup(&format!("<span foreground='{chip_color}'>{chip_text}</span>"));

        for child in self.cards.children() {
            self.cards.remove(&child);
        }
        let mut paths = self.card_paths.borrow_mut();
        paths.clear();
        for s in &snap.sessions {
            let row = gtk::ListBoxRow::new();
            row.set_margin_bottom(8);
            let card = gtk::Box::new(gtk::Orientation::Vertical, 3);
            card.style_context().add_class("card");
            if s.phase == "input" {
                card.style_context().add_class("card-input");
            }
            // top: project pill left, age right
            let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            top.pack_start(&badge_label(&s.project), false, false, 0);
            let age = gtk::Label::new(Some(&fmt_age(s.age)));
            age.style_context().add_class("dim");
            top.pack_end(&age, false, false, 0);
            // title: the session's name (ai-title / rename), like the mac card
            let title_text = if s.label.is_empty() { &s.project } else { &s.label };
            let title = gtk::Label::new(None);
            title.set_markup(&format!(
                "<b>{}</b>",
                glib::markup_escape_text(title_text)
            ));
            title.set_xalign(0.0);
            title.set_ellipsize(gtk::pango::EllipsizeMode::End);
            // status line, phase-colored for anything needing eyes
            let doing = gtk::Label::new(None);
            match s.phase.as_str() {
                "input" | "ready" | "stalled" => doing.set_markup(&format!(
                    "<span foreground='{}'>{}</span>",
                    phase_color(&s.phase),
                    glib::markup_escape_text(&s.doing)
                )),
                _ => {
                    doing.set_text(&s.doing);
                    doing.style_context().add_class("dim");
                }
            }
            doing.set_xalign(0.0);
            doing.set_ellipsize(gtk::pango::EllipsizeMode::End);
            // meta: provider · ctx, tiny and dim (mac shows on expand;
            // one compact line here keeps the info without the interaction)
            let ctx = s.ctx.map(|c| format!(" · ctx {}", fmt_tokens(c))).unwrap_or_default();
            let meta = gtk::Label::new(Some(&format!("{}{}", s.provider, ctx)));
            meta.set_xalign(0.0);
            meta.style_context().add_class("meta");
            card.pack_start(&top, false, false, 0);
            card.pack_start(&title, false, false, 0);
            card.pack_start(&doing, false, false, 0);
            card.pack_start(&meta, false, false, 0);
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
