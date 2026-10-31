import Foundation
import Observation

/// Password / UUID / number / lorem generator.
/// Randomness comes from `SystemRandomNumberGenerator`, which is cryptographically secure on macOS.
/// Nothing generated is ever persisted.
@MainActor @Observable
final class GeneratorModel {
    static let shared = GeneratorModel()

    enum Mode: String, CaseIterable, Identifiable { case password = "Password", uuid = "UUID", number = "Number", lorem = "Lorem"
        var id: String { rawValue } }
    enum Style: String, CaseIterable, Identifiable { case random = "Random", memorable = "Memorable"
        var id: String { rawValue } }

    var mode: Mode = .password { didSet { generate() } }
    var style: Style = .memorable { didSet { generate() } }
    var length: Double = 20 { didSet { if Int(length) != Int(oldValue) { generate() } } }
    var words: Double = 5 { didSet { if Int(words) != Int(oldValue) { generate() } } }
    var upper = true { didSet { generate() } }
    var lower = true { didSet { generate() } }
    var digits = true { didSet { generate() } }
    var symbols = true { didSet { generate() } }
    var uuidUppercase = false { didSet { generate() } }
    var numberMin: Double = 1 { didSet { generate() } }
    var numberMax: Double = 100 { didSet { generate() } }
    var loremParagraphs: Double = 1 { didSet { generate() } }

    private(set) var output = ""
    private(set) var entropy: Double = 0

    private init() { generate() }

    var strength: (label: String, fraction: Double) {
        switch entropy {
        case ..<40: ("Weak", 0.25)
        case ..<60: ("Fair", 0.5)
        case ..<80: ("Strong", 0.75)
        default: ("Very strong", 1)
        }
    }

    var isSensitive: Bool { mode == .password }

    func generate() {
        var rng = SystemRandomNumberGenerator()
        switch mode {
        case .password:
            style == .random ? randomPassword(&rng) : memorablePassword(&rng)
        case .uuid:
            let value = UUID().uuidString
            output = uuidUppercase ? value : value.lowercased()
            entropy = 122
        case .number:
            let lo = Int(min(numberMin, numberMax)), hi = Int(max(numberMin, numberMax))
            output = String(Int.random(in: lo...hi, using: &rng))
            entropy = log2(Double(hi - lo + 1))
        case .lorem:
            output = (0..<max(1, Int(loremParagraphs))).map { _ in Lorem.paragraph(&rng) }.joined(separator: "\n\n")
            entropy = 0
        }
    }

    private static let upperSet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let lowerSet = Array("abcdefghijklmnopqrstuvwxyz")
    private static let digitSet = Array("0123456789")
    private static let symbolSet = Array("!@#$%^&*-_=+?:;.~")

    private func randomPassword(_ rng: inout SystemRandomNumberGenerator) {
        var sets: [[Character]] = []
        if upper { sets.append(Self.upperSet) }
        if lower { sets.append(Self.lowerSet) }
        if digits { sets.append(Self.digitSet) }
        if symbols { sets.append(Self.symbolSet) }
        if sets.isEmpty { sets = [Self.lowerSet] }
        let pool = sets.flatMap { $0 }
        let count = max(Int(length), sets.count)
        // Guarantee one char from each selected set, then fill and shuffle.
        var chars = sets.map { $0.randomElement(using: &rng)! }
        while chars.count < count { chars.append(pool.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        output = String(chars)
        entropy = Double(count) * log2(Double(pool.count))
    }

    private func memorablePassword(_ rng: inout SystemRandomNumberGenerator) {
        let n = max(3, Int(words))
        var parts: [String] = []
        var bits = Double(n) * log2(Double(WordList.words.count))
        let digitWord = digits ? Int.random(in: 0..<n, using: &rng) : -1
        for i in 0..<n {
            var word = WordList.words.randomElement(using: &rng)!
            if upper { word = word.prefix(1).uppercased() + word.dropFirst() }
            if !lower { word = word.uppercased() }
            if i == digitWord {
                word += String(format: "%02d", Int.random(in: 0...99, using: &rng))
                bits += log2(100) + log2(Double(n))
            }
            parts.append(word)
        }
        var result = parts[0]
        for part in parts.dropFirst() {
            if symbols {
                result.append(Self.symbolSet.randomElement(using: &rng)!)
                bits += log2(Double(Self.symbolSet.count))
            } else {
                result.append("-")
            }
            result += part
        }
        output = result
        entropy = bits
    }
}

enum Lorem {
    static let words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum".split(separator: " ").map(String.init)

    static func sentence(_ rng: inout SystemRandomNumberGenerator) -> String {
        let count = Int.random(in: 7...14, using: &rng)
        let s = (0..<count).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
        return s.prefix(1).uppercased() + s.dropFirst() + "."
    }

    static func paragraph(_ rng: inout SystemRandomNumberGenerator) -> String {
        (0..<Int.random(in: 4...6, using: &rng)).map { _ in sentence(&rng) }.joined(separator: " ")
    }
}

enum WordList {
    // 512 short, common, easy-to-type English words (9 bits each).
    static let words: [String] = """
    able acid aged also arch area army atom aunt away axis baby back bake ball band bank barn base bath bead beam bean bear beat bell belt bench berry bike bird blade blank blast blend bliss block bloom blue blur board boat body bold bolt bond bone book boot boss bowl brave bread brick bride brief brisk broad brook brush buddy bulb bunny burst butter cabin cable cactus cake calm camel camp candy cane canoe cape card cargo carol carry cart case castle cave cedar chain chalk charm chart chase cheek cheer chef cherry chess chief chili chip choir chunk cider cinema city clam clan clay clerk cliff climb clock cloud clover coach coast cocoa coin comet coral cord corn couch crab craft crane crate creek crisp crow crown cube cumin curl curve cycle daisy dance dawn deck deer delta denim depth desk dial diary dime diner disco dock dome donut door dove draft dragon drama dream dress drift drum duck dune dusk dust eagle earth easel echo edge elbow elder elm ember empty engine epic equal ether event fable fair faith falcon fancy farm feast fern ferry fever fiber field fig film finch fire firm fish flag flame flash fleet flint flock flora flute focus foam fog folk forest forge fork fort fossil fox frame fresh frog frost fruit fudge gala game garden gate gear gecko gem genie giant ginger glad glass globe glow glue goat gold golf goose grain grape graph grass gravy green grid grill grove guard guide guitar gulf gust habit hall halo harbor harp hatch hawk hazel heart heron hill hive holly honey hood hook hope horn hotel humble husky icon igloo inch index ink iris iron island ivory ivy jacket jade jam jar jazz jelly jewel jolly judge juice jumbo jungle karma kayak kettle key kite kiwi knee knot koala label lace ladder lake lamp lance laser latch lava lawn layer leaf lemon lens level lilac lime linen lion lizard llama lobby lodge logic lotus lucky lunar lunch lyric magic magnet maize mango maple marble march mask meadow medal melon mercy merit mesa metal meteor mint mirror mist mocha model molar moon moose mossy motor mouse mud mural music nacho nectar needle nest nickel night ninja noble noodle north nova novel nutmeg oak oasis ocean olive omega onion opal opera orbit orchid otter oven owl oxide paddle palm panda paper parade park pastel patch peach pearl pebble pecan pedal penny pepper piano pickle pilot pine pixel pizza plain planet plaza plum polar pond poppy porch prism pulse pumpkin puppy quail quartz queen quest quilt quiet rabbit radar radio rain ranch raven reef relic ribbon ridge river robin rocket rose ruby rugby saddle saga sage salad salmon salt sand satin scarf scout sea seed shadow shark shell shore silk silver siren sketch sky slate sled smile snow solar sonic spark spice spire spoon spring spruce squid star steam stone storm stove straw stream sugar summit sun swan sweet swift table taco talon tango temple thimble thunder tiger timber toast topaz torch tower trail train tulip tundra turtle twig umbra unity urban valley vapor velvet venus vessel violet vivid volcano voyage wafer wagon walnut walrus wave willow window winter wizard wolf wonder yacht yarn yeti yoga zebra zenith zero zinc zone bright lunar sugar
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
}
