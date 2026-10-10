fn main() {
    let root = std::path::PathBuf::from(std::env::args().nth(1).expect("assets root"));
    let filter = std::env::args().nth(2).unwrap_or_default().to_uppercase();
    if filter == "--POSE" {
        skate_host::preview::load(&root).unwrap();
        let names = skate_host::preview::bone_names(&root).unwrap();
        let show = |label: &str, posture: u32, gesture: Option<u32>, t: f32| {
            let bones = skate_host::preview::settings_pose(&root, posture, gesture, t, false).unwrap();
            let at = |n: &str| { let i = names.iter().position(|x| x == n).unwrap(); let b = bones[i]; [b[12], b[13], b[14]] };
            let f = |v: [f32; 3]| format!("({:.2} {:.2} {:.2})", v[0], v[1], v[2]);
            println!("{label:28} hips {} head {} rhand {} lhand {}", f(at("HIPS")), f(at("HEAD")), f(at("RIGHTHAND")), f(at("LEFTHAND")));
        };
        show("default", 0, None, 0.5);
        show("stiff", 1, None, 0.5);
        show("slouch", 2, None, 0.5);
        show("buff", 3, None, 0.5);
        for t in [0.2f32, 1.0, 2.0, 3.0] { show(&format!("air guitar t={t}"), 0, Some(0), t); }
        show("airplane t=1", 0, Some(1), 1.0);
        return;
    }
    for n in skate_host::preview::clip_names(&root).unwrap() {
        if n.to_uppercase().contains(&filter) {
            println!("{n}");
        }
    }
}
