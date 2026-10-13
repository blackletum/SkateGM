//! The engine's physical state by name (Pose.state, the stand-in's too): what
//! kind of state it is, in one place.

const AIRBORNE: &[&str] = &["PhysicsAir", "KnownAir", "PhysicsAirSecondary", "BipedAir"];
const STANDING: &[&str] = &["PhysicsGround", "SlideGround", "RevertGround", "GroundAnimation", "BipedGround"];

pub fn airborne(state: &str) -> bool {
    AIRBORNE.contains(&state)
}

pub fn grinding(state: &str) -> bool {
    state.starts_with("Grind")
}

pub fn standing(state: &str) -> bool {
    STANDING.contains(&state)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_match_the_names() {
        assert!(airborne("KnownAir") && airborne("BipedAir") && !airborne("PhysicsGround"));
        assert!(grinding("GrindFiftyFifty") && !grinding("PhysicsGround"));
        assert!(standing("BipedGround") && standing("PhysicsGround") && !standing("WipeoutGround") && !standing("KnownAir"));
    }
}
