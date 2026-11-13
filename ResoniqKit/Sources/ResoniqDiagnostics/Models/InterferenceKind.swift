import Foundation

/// The kinds of interfering sound the product talks about, in plain words.
public enum InterferenceKind: String, Sendable, Codable, CaseIterable {
    case speech
    case music
    /// No label of the system classifier names a television or radio (its list has none), so nothing maps here
    /// today: a TV is heard as speech or music, and the music sentence says "or a TV". Kept for a future model.
    case televisionOrRadio
    case traffic
    /// A vacuum cleaner, a fan, a hair dryer; the classifier has no washing-machine label.
    case appliance
    case animal
    case doorOrFootsteps
    case windOrRain
    case babyOrChildren
    case phoneOrAlarm
    /// The classifier was sure of a sound that none of the kinds above covers.
    case unknown

    /// Whether the test sweep itself can pass for this kind. Measured: the system classifier calls the app's
    /// measurement sweep "music" (up to 0.95), "theremin" (0.96), "synthesizer", "tuning_fork" and "bell" (0.58), and a
    /// plain 20 Hz–20 kHz sweep's top octaves "bird_chirp_tweet" (0.52) and "whistling" (`SoundClassifierTests`). A
    /// sweep is a rising tone, so a siren or an alarm is just as close, and an unmapped label heard over it may be the
    /// sweep. While the sweep plays, these kinds are not named.
    public var isMimickedBySweep: Bool {
        switch self {
        case .music, .animal, .phoneOrAlarm, .unknown: true
        case .speech, .televisionOrRadio, .traffic, .appliance, .doorOrFootsteps, .windOrRain, .babyOrChildren: false
        }
    }
}

/// What a label of the system classifier means to the product.
public enum InterferenceLabel: Sendable, Equatable {
    case kind(InterferenceKind)
    /// A label a pure or swept tone draws: the app's own test signal, never named as interference.
    case testSignal
}

/// The table from the system classifier's label identifiers (`SNClassifierIdentifier.version1`) to kinds.
///
/// Every identifier here is checked against the classifier's list as it was obtained on macOS 27 / iOS 27.1 SDK
/// (`SoundClassifierLabels.version1` in the tests, 303 labels), so a later OS that renames a label fails a test
/// instead of silently dropping it. Labels left out (coughs, cutlery, water, gunshots, sports, insects…) are
/// unmapped: they are never a reason on their own, only `unknown` when nothing mapped is heard.
///
/// Insects are left out on purpose: the system classifier gives "mosquito_buzz" and "insect" up to 0.76 on a
/// synthetic voice's sibilants.
public enum InterferenceMapping {
    public static let labels: [String: InterferenceLabel] = {
        var table: [String: InterferenceLabel] = [:]
        func add(_ kind: InterferenceLabel, _ identifiers: [String]) {
            for identifier in identifiers {
                precondition(table[identifier] == nil, "\(identifier) is mapped twice")
                table[identifier] = kind
            }
        }
        add(.kind(.speech), [
            "speech", "shout", "yell", "battle_cry", "screaming", "whispering", "laughter", "giggling", "snicker",
            "belly_laugh", "chuckle_chortle", "crying_sobbing", "chatter", "crowd", "babble", "cheering", "applause",
            "booing",
        ])
        add(.kind(.babyOrChildren), ["baby_crying", "baby_laughter", "children_shouting"])
        add(.kind(.music), [
            "music", "singing", "choir_singing", "yodeling", "rapping", "humming",
            "plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar", "acoustic_guitar",
            "steel_guitar_slide_guitar", "guitar_tapping", "guitar_strum", "banjo", "sitar", "mandolin", "zither",
            "ukulele", "keyboard_musical", "piano", "electric_piano", "organ", "electronic_organ", "hammond_organ",
            "harpsichord", "percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "timpani", "tabla", "cymbal",
            "hi_hat", "tambourine", "rattle_instrument", "gong", "mallet_percussion", "marimba_xylophone",
            "glockenspiel", "vibraphone", "steelpan", "orchestra", "brass_instrument", "french_horn", "trumpet",
            "trombone", "bowed_string_instrument", "violin_fiddle", "cello", "double_bass", "wind_instrument", "flute",
            "saxophone", "clarinet", "oboe", "bassoon", "harp", "harmonica", "accordion", "bagpipes", "didgeridoo",
            "disc_scratching",
        ])
        add(.kind(.animal), [
            "dog", "dog_bark", "dog_howl", "dog_bow_wow", "dog_growl", "dog_whimper", "cat", "cat_purr", "cat_meow",
            "horse_clip_clop", "horse_neigh", "cow_moo", "pig_oink", "sheep_bleat", "fowl", "chicken", "chicken_cluck",
            "rooster_crow", "turkey_gobble", "duck_quack", "goose_honk", "bird", "bird_vocalization", "bird_chirp_tweet",
            "bird_squawk", "pigeon_dove_coo", "crow_caw", "owl_hoot", "bird_flapping",
        ])
        add(.kind(.windOrRain), [
            "wind", "wind_rustling_leaves", "wind_noise_microphone", "thunderstorm", "thunder", "rain", "raindrop",
        ])
        add(.kind(.traffic), [
            "car_horn", "vehicle_skidding", "car_passing_by", "race_car", "truck", "air_horn", "reverse_beeps", "bus",
            "emergency_vehicle", "police_siren", "ambulance_siren", "fire_engine_siren", "motorcycle", "traffic_noise",
            "rail_transport", "train", "train_whistle", "train_horn", "railroad_car", "train_wheels_squealing",
            "subway_metro", "aircraft", "helicopter", "airplane", "engine", "engine_knocking", "engine_starting",
            "engine_idling", "engine_accelerating_revving",
        ])
        add(.kind(.appliance), [
            "lawn_mower", "chainsaw", "microwave_oven", "blender", "hair_dryer", "vacuum_cleaner", "electric_shaver",
            "toothbrush", "sewing_machine", "mechanical_fan", "air_conditioner", "printer", "hammer", "saw",
            "power_tool", "drill", "hedge_trimmer", "water_pump",
        ])
        add(.kind(.doorOrFootsteps), [
            "door", "door_bell", "door_sliding", "door_slam", "knock", "drawer_open_close", "person_running",
            "person_shuffling", "person_walking",
        ])
        add(.kind(.phoneOrAlarm), [
            "telephone", "telephone_bell_ringing", "ringtone", "alarm_clock", "siren", "civil_defense_siren",
            "smoke_detector",
        ])
        add(.testSignal, ["synthesizer", "theremin", "tuning_fork", "beep", "whistling", "bell"])
        return table
    }()

    /// Labels that say nothing about interference at all.
    public static let ignored: Set<String> = ["silence"]

    /// What `identifier` means; nil for an unmapped label.
    public static func label(for identifier: String) -> InterferenceLabel? { labels[identifier] }
}
