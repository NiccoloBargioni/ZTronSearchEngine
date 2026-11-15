import Foundation

// The curated word list behind `FixtureLexicon`.
//
// Domain: a generic game-companion catalog (maps, tips, tools, games, captioned images). Every
// word is an ordinary dictionary word; nothing names a real game, studio, character or product.
//
// Rules the rows follow (checked by `FixtureLexicon.validate()`):
// - a lemma, a synonym and an Italian or German form is one word of three letters or more;
// - no folded form belongs to two concepts, in any language;
// - a synonym never shares a token with its lemma.

extension FixtureLexicon {
    /// One adjective. Italian is the masculine singular (the feminine is derived: `-o` becomes
    /// `-a`, anything else is invariable). German is the uninflected stem (`-er`, `-e`, `-es`
    /// and `-en` are appended). Japanese is the attributive form, ready to precede a noun.
    struct AdjectiveRow {
        let lemma: String
        let synonyms: String
        let italian: String
        let german: String
        let japanese: String

        init(_ lemma: String, _ synonyms: String, _ italian: String, _ german: String, _ japanese: String) {
            self.lemma = lemma
            self.synonyms = synonyms
            self.italian = italian
            self.german = german
            self.japanese = japanese
        }
    }

    /// One noun, with the grammatical gender of its Italian and German forms.
    struct NounRow {
        let lemma: String
        let synonyms: String
        let italian: String
        let italianGender: FixtureGender
        let german: String
        let germanGender: FixtureGender
        let japanese: String

        init(
            _ lemma: String, _ synonyms: String, _ italian: String, _ italianGender: FixtureGender,
            _ german: String, _ germanGender: FixtureGender, _ japanese: String
        ) {
            self.lemma = lemma
            self.synonyms = synonyms
            self.italian = italian
            self.italianGender = italianGender
            self.german = german
            self.germanGender = germanGender
            self.japanese = japanese
        }
    }

    // MARK: Adjectives

    static let descriptorRows: [AdjectiveRow] = [
        AdjectiveRow("frozen", "icy glacial frosty", "ghiacciato", "gefroren", "凍った"),
        AdjectiveRow("hidden", "concealed veiled obscured", "nascosto", "verborgen", "隠された"),
        AdjectiveRow("ancient", "archaic primeval antique", "antico", "uralt", "古代の"),
        AdjectiveRow("burning", "blazing flaming fiery", "ardente", "brennend", "燃える"),
        AdjectiveRow("silent", "quiet hushed noiseless", "silenzioso", "still", "静かな"),
        AdjectiveRow("golden", "gilded aureate", "dorato", "vergoldet", "金色の"),
        AdjectiveRow("sunken", "submerged drowned", "sommerso", "versunken", "沈んだ"),
        AdjectiveRow("cursed", "hexed jinxed doomed", "maledetto", "verflucht", "呪われた"),
        AdjectiveRow("forgotten", "unremembered overlooked", "dimenticato", "vergessen", "忘れられた"),
        AdjectiveRow("shattered", "broken smashed fractured", "infranto", "zerbrochen", "砕けた"),
        AdjectiveRow("lost", "missing vanished misplaced", "perduto", "verloren", "失われた"),
        AdjectiveRow("sacred", "holy hallowed blessed", "sacro", "heilig", "神聖な"),
        AdjectiveRow("stormy", "tempestuous turbulent squally", "tempestoso", "stürmisch", "嵐の"),
        AdjectiveRow("misty", "foggy hazy vaporous", "nebbioso", "neblig", "霧の"),
        AdjectiveRow("hollow", "cavernous vacant", "cavo", "ausgehöhlt", "空洞の"),
        AdjectiveRow("wild", "untamed feral savage", "selvaggio", "ungezähmt", "野生の"),
        AdjectiveRow("royal", "regal kingly majestic", "reale", "königlich", "王家の"),
        AdjectiveRow("secret", "covert clandestine undisclosed", "segreto", "geheim", "秘密の"),
        AdjectiveRow("deep", "bottomless profound abyssal", "profondo", "tief", "深い"),
        AdjectiveRow("bright", "radiant luminous gleaming", "luminoso", "hell", "明るい"),
        AdjectiveRow("floating", "hovering drifting levitating", "fluttuante", "schwebend", "浮かぶ"),
        AdjectiveRow("abandoned", "deserted forsaken derelict", "abbandonato", "verlassen", "見捨てられた"),
        AdjectiveRow("endless", "infinite boundless limitless", "infinito", "endlos", "無限の"),
        AdjectiveRow("sleeping", "dormant slumbering napping", "dormiente", "schlafend", "眠れる"),
        AdjectiveRow("rusty", "corroded oxidized tarnished", "arrugginito", "rostig", "錆びた"),
        AdjectiveRow("silver", "argent silvery", "argenteo", "silbern", "銀の"),
        AdjectiveRow("lonely", "solitary isolated secluded", "solitario", "einsam", "孤独な"),
        AdjectiveRow("poisonous", "toxic venomous noxious", "velenoso", "giftig", "毒の"),
        AdjectiveRow("snowy", "wintry snowbound", "innevato", "verschneit", "雪の"),
        AdjectiveRow("gloomy", "dim murky dismal", "cupo", "düster", "薄暗い"),
        AdjectiveRow("crimson", "scarlet vermilion ruby", "cremisi", "karmesinrot", "深紅の"),
        AdjectiveRow("tiny", "minuscule miniature diminutive", "minuscolo", "winzig", "小さな"),
        AdjectiveRow("swift", "rapid speedy fleet", "veloce", "flink", "素早い"),
        AdjectiveRow("brave", "fearless valiant courageous", "coraggioso", "tapfer", "勇敢な"),
        AdjectiveRow("eternal", "everlasting perpetual undying", "eterno", "ewig", "永久の"),
        AdjectiveRow("scorched", "charred singed seared", "bruciato", "versengt", "焦げた"),
    ]

    // MARK: Places

    static let placeRows: [NounRow] = [
        NounRow("harbor", "port haven anchorage marina", "porto", .masculine, "Hafen", .masculine, "港"),
        NounRow("tower", "spire turret steeple", "torre", .feminine, "Turm", .masculine, "塔"),
        NounRow("forest", "woods woodland timberland", "foresta", .feminine, "Wald", .masculine, "森"),
        NounRow("cave", "cavern grotto den", "caverna", .feminine, "Höhle", .feminine, "洞窟"),
        NounRow("valley", "vale dale glen", "valle", .feminine, "Tal", .neuter, "谷"),
        NounRow("island", "isle islet atoll", "isola", .feminine, "Insel", .feminine, "島"),
        NounRow("temple", "sanctuary sanctum pagoda", "tempio", .masculine, "Tempel", .masculine, "神殿"),
        NounRow("village", "hamlet settlement township", "villaggio", .masculine, "Dorf", .neuter, "村"),
        NounRow("bridge", "overpass viaduct footbridge", "ponte", .masculine, "Brücke", .feminine, "橋"),
        NounRow("mine", "pit colliery shaft", "miniera", .feminine, "Bergwerk", .neuter, "鉱山"),
        NounRow("swamp", "bog mire marsh", "palude", .feminine, "Sumpf", .masculine, "沼"),
        NounRow("desert", "wasteland dunes barrens", "deserto", .masculine, "Wüste", .feminine, "砂漠"),
        NounRow("castle", "citadel stronghold chateau", "castello", .masculine, "Burg", .feminine, "城"),
        NounRow("canyon", "gorge ravine chasm", "gola", .feminine, "Schlucht", .feminine, "峡谷"),
        NounRow("lake", "loch lagoon mere", "lago", .masculine, "See", .masculine, "湖"),
        NounRow("river", "stream waterway brook", "fiume", .masculine, "Fluss", .masculine, "川"),
        NounRow("mountain", "peak summit alp", "montagna", .feminine, "Berg", .masculine, "山"),
        NounRow("market", "bazaar marketplace emporium", "mercato", .masculine, "Markt", .masculine, "市場"),
        NounRow("library", "archive athenaeum bookroom", "biblioteca", .feminine, "Bibliothek", .feminine, "図書館"),
        NounRow("fortress", "bastion rampart redoubt", "fortezza", .feminine, "Festung", .feminine, "要塞"),
        NounRow("shrine", "chapel reliquary altar", "santuario", .masculine, "Schrein", .masculine, "祠"),
        NounRow("tunnel", "passage underpass burrow", "galleria", .feminine, "Stollen", .masculine, "トンネル"),
        NounRow("dungeon", "jail oubliette prison", "prigione", .feminine, "Kerker", .masculine, "地下牢"),
        NounRow("palace", "mansion manor residence", "palazzo", .masculine, "Palast", .masculine, "宮殿"),
        NounRow("beach", "shore seashore coast", "spiaggia", .feminine, "Strand", .masculine, "浜辺"),
        NounRow("cliff", "bluff crag precipice", "scogliera", .feminine, "Klippe", .feminine, "崖"),
        NounRow("waterfall", "cascade falls cataract", "cascata", .feminine, "Wasserfall", .masculine, "滝"),
        NounRow("graveyard", "cemetery churchyard necropolis", "cimitero", .masculine, "Friedhof", .masculine, "墓地"),
        NounRow("meadow", "pasture grassland prairie", "prato", .masculine, "Wiese", .feminine, "草原"),
        NounRow("hill", "knoll mound hillock", "collina", .feminine, "Hügel", .masculine, "丘"),
        NounRow("tavern", "pub alehouse saloon", "osteria", .feminine, "Schenke", .feminine, "酒場"),
        NounRow("farm", "ranch homestead croft", "fattoria", .feminine, "Bauernhof", .masculine, "農場"),
        NounRow("camp", "encampment bivouac campsite", "accampamento", .masculine, "Lager", .neuter, "野営地"),
        NounRow("gate", "portal gateway entrance", "cancello", .masculine, "Tor", .neuter, "門"),
        NounRow("station", "depot terminal terminus", "stazione", .feminine, "Bahnhof", .masculine, "駅"),
        NounRow("workshop", "atelier studio workroom", "officina", .feminine, "Werkstatt", .feminine, "工房"),
    ]

    // MARK: Themes (evocative nouns for game titles)

    static let themeRows: [NounRow] = [
        NounRow("crown", "diadem coronet tiara", "corona", .feminine, "Krone", .feminine, "王冠"),
        NounRow("tide", "surge swell current", "marea", .feminine, "Flut", .feminine, "潮"),
        NounRow("ember", "cinder spark coal", "brace", .feminine, "Glut", .feminine, "残り火"),
        NounRow("legion", "army battalion host", "legione", .feminine, "Heer", .neuter, "軍団"),
        NounRow("oath", "vow pledge promise", "giuramento", .masculine, "Eid", .masculine, "誓い"),
        NounRow("echo", "reverberation resonance", "eco", .feminine, "Widerhall", .masculine, "残響"),
        NounRow("frontier", "border borderland boundary", "confine", .masculine, "Grenze", .feminine, "辺境"),
        NounRow("kingdom", "realm monarchy dominion", "regno", .masculine, "Königreich", .neuter, "王国"),
        NounRow("empire", "imperium hegemony", "impero", .masculine, "Kaiserreich", .neuter, "帝国"),
        NounRow("legacy", "heritage inheritance bequest", "eredità", .feminine, "Erbe", .neuter, "遺産"),
        NounRow("voyage", "journey expedition trek", "viaggio", .masculine, "Reise", .feminine, "航海"),
        NounRow("prophecy", "prediction omen foretelling", "profezia", .feminine, "Weissagung", .feminine, "予言"),
        NounRow("rebellion", "uprising revolt insurrection", "rivolta", .feminine, "Aufstand", .masculine, "反乱"),
        NounRow("exile", "banishment deportation", "esilio", .masculine, "Verbannung", .feminine, "追放"),
        NounRow("harvest", "reaping crop yield", "raccolto", .masculine, "Ernte", .feminine, "収穫"),
        NounRow("oracle", "seer soothsayer prophet", "oracolo", .masculine, "Orakel", .neuter, "神託"),
        NounRow("relic", "artifact heirloom keepsake", "reliquia", .feminine, "Relikt", .neuter, "遺物"),
        NounRow("guardian", "protector sentinel warden", "custode", .masculine, "Wächter", .masculine, "守護者"),
        NounRow("hunter", "stalker huntsman trapper", "cacciatore", .masculine, "Jäger", .masculine, "狩人"),
        NounRow("blacksmith", "smith ironworker farrier", "fabbro", .masculine, "Schmied", .masculine, "鍛冶師"),
        NounRow("dragon", "wyrm drake wyvern", "drago", .masculine, "Drache", .masculine, "竜"),
        NounRow("knight", "cavalier paladin chevalier", "cavaliere", .masculine, "Ritter", .masculine, "騎士"),
        NounRow("wizard", "sorcerer mage warlock", "mago", .masculine, "Zauberer", .masculine, "魔法使い"),
        NounRow("thief", "burglar robber bandit", "ladro", .masculine, "Dieb", .masculine, "盗賊"),
        NounRow("merchant", "trader vendor seller", "mercante", .masculine, "Händler", .masculine, "商人"),
        NounRow("ghost", "phantom specter apparition", "fantasma", .masculine, "Geist", .masculine, "幽霊"),
        NounRow("dream", "reverie daydream fantasy", "sogno", .masculine, "Traum", .masculine, "夢"),
        NounRow("song", "melody tune ballad", "canzone", .feminine, "Lied", .neuter, "歌"),
        NounRow("night", "nighttime darkness", "notte", .feminine, "Nacht", .feminine, "夜"),
        NounRow("sea", "ocean brine", "mare", .masculine, "Meer", .neuter, "海"),
        NounRow("sky", "heavens firmament", "cielo", .masculine, "Himmel", .masculine, "空"),
        NounRow("fate", "destiny fortune doom", "destino", .masculine, "Schicksal", .neuter, "運命"),
        NounRow("war", "conflict warfare battle", "guerra", .feminine, "Krieg", .masculine, "戦争"),
        NounRow("peace", "harmony truce concord", "pace", .feminine, "Frieden", .masculine, "平和"),
        NounRow("hero", "champion protagonist", "eroe", .masculine, "Held", .masculine, "英雄"),
        NounRow("beast", "creature monster brute", "belva", .feminine, "Ungeheuer", .neuter, "獣"),
    ]

    // MARK: Objects

    static let objectRows: [NounRow] = [
        NounRow("potion", "elixir tonic draught", "pozione", .feminine, "Trank", .masculine, "ポーション"),
        NounRow("sword", "saber rapier broadsword", "spada", .feminine, "Schwert", .neuter, "剣"),
        NounRow("shield", "buckler aegis", "scudo", .masculine, "Schild", .masculine, "盾"),
        NounRow("key", "passkey latchkey opener", "chiave", .feminine, "Schlüssel", .masculine, "鍵"),
        NounRow("chest", "coffer trunk strongbox", "forziere", .masculine, "Truhe", .feminine, "宝箱"),
        NounRow("coin", "currency cash money", "moneta", .feminine, "Münze", .feminine, "硬貨"),
        NounRow("armor", "cuirass plating mail", "armatura", .feminine, "Rüstung", .feminine, "鎧"),
        NounRow("bow", "longbow crossbow", "arco", .masculine, "Bogen", .masculine, "弓"),
        NounRow("arrow", "dart bolt quarrel", "freccia", .feminine, "Pfeil", .masculine, "矢"),
        NounRow("lantern", "lamp luminaire", "lanterna", .feminine, "Laterne", .feminine, "ランタン"),
        NounRow("scroll", "parchment manuscript papyrus", "pergamena", .feminine, "Schriftrolle", .feminine, "巻物"),
        NounRow("gem", "jewel gemstone bijou", "gemma", .feminine, "Edelstein", .masculine, "宝石"),
        NounRow("helmet", "headgear casque headpiece", "elmo", .masculine, "Helm", .masculine, "兜"),
        NounRow("staff", "rod wand scepter", "bastone", .masculine, "Stab", .masculine, "杖"),
        NounRow("torch", "flare firebrand", "torcia", .feminine, "Fackel", .feminine, "松明"),
        NounRow("rope", "cord tether lasso", "corda", .feminine, "Seil", .neuter, "縄"),
        NounRow("boat", "vessel skiff dinghy", "barca", .feminine, "Boot", .neuter, "小舟"),
        NounRow("horse", "steed stallion mount", "cavallo", .masculine, "Pferd", .neuter, "馬"),
        NounRow("book", "tome volume codex", "libro", .masculine, "Buch", .neuter, "書物"),
        NounRow("bell", "chime gong", "campana", .feminine, "Glocke", .feminine, "鐘"),
        NounRow("mask", "disguise visor", "maschera", .feminine, "Maske", .feminine, "仮面"),
        NounRow("cloak", "cape mantle robe", "mantello", .masculine, "Umhang", .masculine, "外套"),
        NounRow("dagger", "knife dirk stiletto", "pugnale", .masculine, "Dolch", .masculine, "短剣"),
        NounRow("axe", "hatchet tomahawk cleaver", "ascia", .feminine, "Axt", .feminine, "斧"),
        NounRow("spear", "lance javelin pike", "lancia", .feminine, "Speer", .masculine, "槍"),
        NounRow("necklace", "pendant choker locket", "collana", .feminine, "Halskette", .feminine, "首飾り"),
        NounRow("bottle", "flask vial phial", "bottiglia", .feminine, "Flasche", .feminine, "瓶"),
        NounRow("candle", "taper waxlight", "candela", .feminine, "Kerze", .feminine, "蝋燭"),
        NounRow("bag", "sack pouch satchel", "borsa", .feminine, "Beutel", .masculine, "袋"),
        NounRow("letter", "missive message epistle", "lettera", .feminine, "Brief", .masculine, "手紙"),
        NounRow("flower", "blossom bloom", "fiore", .masculine, "Blume", .feminine, "花"),
        NounRow("mushroom", "fungus toadstool", "fungo", .masculine, "Pilz", .masculine, "キノコ"),
        NounRow("flute", "pipe fife piccolo", "flauto", .masculine, "Flöte", .feminine, "笛"),
        NounRow("tent", "shelter marquee pavilion", "tenda", .feminine, "Zelt", .neuter, "テント"),
        NounRow("barrel", "cask keg", "botte", .feminine, "Fass", .neuter, "樽"),
        NounRow("trap", "snare pitfall", "trappola", .feminine, "Falle", .feminine, "罠"),
    ]

    /// Objects that never appear in a title or a body. Each is the keyword of exactly one golden
    /// item, which makes it a distinctive keyword for typo queries.
    static let rareObjectRows: [NounRow] = [
        NounRow("cup", "goblet chalice mug", "coppa", .feminine, "Becher", .masculine, "杯"),
        NounRow("medal", "medallion badge decoration", "medaglia", .feminine, "Orden", .masculine, "勲章"),
        NounRow("banner", "flag pennant standard", "stendardo", .masculine, "Fahne", .feminine, "旗"),
        NounRow("crate", "box case container", "cassa", .feminine, "Kiste", .feminine, "木箱"),
        NounRow("whip", "lash scourge", "frusta", .feminine, "Peitsche", .feminine, "鞭"),
        NounRow("drum", "tambour kettledrum", "tamburo", .masculine, "Trommel", .feminine, "太鼓"),
        NounRow("basket", "hamper pannier", "cesto", .masculine, "Korb", .masculine, "籠"),
        NounRow("anchor", "grapnel mooring", "ancora", .feminine, "Anker", .masculine, "錨"),
        NounRow("wheel", "disc roller", "ruota", .feminine, "Rad", .neuter, "車輪"),
    ]

    // MARK: Actions (verbal nouns)

    static let actionRows: [NounRow] = [
        NounRow("fishing", "angling trawling", "pesca", .feminine, "Angeln", .neuter, "釣り"),
        NounRow("mining", "excavation digging quarrying", "estrazione", .feminine, "Bergbau", .masculine, "採掘"),
        NounRow("cooking", "cookery gastronomy", "cucina", .feminine, "Kochen", .neuter, "料理"),
        NounRow("trading", "commerce bartering dealing", "commercio", .masculine, "Handel", .masculine, "交易"),
        NounRow("healing", "recovery mending curing", "guarigione", .feminine, "Heilung", .feminine, "回復"),
        NounRow("climbing", "scaling ascending mountaineering", "arrampicata", .feminine, "Klettern", .neuter, "クライミング"),
        NounRow("farming", "agriculture cultivation tilling", "agricoltura", .feminine, "Ackerbau", .masculine, "農業"),
        NounRow("crafting", "fabrication handiwork tinkering", "artigianato", .masculine, "Handwerk", .neuter, "クラフト"),
        NounRow("brewing", "distilling fermenting", "birrificazione", .feminine, "Brauen", .neuter, "醸造"),
        NounRow("forging", "smithing metalworking", "forgiatura", .feminine, "Schmieden", .neuter, "鍛造"),
        NounRow("taming", "domestication gentling", "addomesticamento", .masculine, "Zähmung", .feminine, "調教"),
        NounRow("gliding", "soaring coasting", "planata", .feminine, "Gleiten", .neuter, "滑空"),
        NounRow("exploring", "scouting surveying reconnaissance", "esplorazione", .feminine, "Erkundung", .feminine, "探索"),
        NounRow("building", "construction erecting assembling", "costruzione", .feminine, "Bauen", .neuter, "建築"),
        NounRow("sailing", "seafaring navigation boating", "navigazione", .feminine, "Segeln", .neuter, "セーリング"),
        NounRow("riding", "horsemanship equitation", "equitazione", .feminine, "Reiten", .neuter, "乗馬"),
        NounRow("archery", "bowmanship marksmanship", "arcieria", .feminine, "Bogenschießen", .neuter, "弓術"),
        NounRow("fencing", "swordplay dueling", "scherma", .feminine, "Fechten", .neuter, "剣術"),
        NounRow("diving", "plunging submersion", "immersione", .feminine, "Tauchen", .neuter, "潜水"),
        NounRow("dodging", "evading sidestepping evasion", "schivata", .feminine, "Ausweichen", .neuter, "回避"),
        NounRow("parrying", "blocking deflecting fending", "parata", .feminine, "Parieren", .neuter, "受け流し"),
        NounRow("weaving", "loomwork braiding", "tessitura", .feminine, "Weben", .neuter, "機織り"),
        NounRow("carving", "sculpting whittling engraving", "intaglio", .masculine, "Schnitzen", .neuter, "彫刻"),
        NounRow("smelting", "melting refining", "fusione", .feminine, "Schmelzen", .neuter, "精錬"),
    ]

    // MARK: Document, tool and picture nouns

    static let mapNounRows: [NounRow] = [
        NounRow("route", "itinerary pathway course", "percorso", .masculine, "Strecke", .feminine, "ルート"),
        NounRow("overview", "summary outline synopsis", "panoramica", .feminine, "Übersicht", .feminine, "概要"),
        NounRow("layout", "arrangement blueprint floorplan", "disposizione", .feminine, "Grundriss", .masculine, "見取り図"),
    ]

    static let tipNounRows: [NounRow] = [
        NounRow("guide", "handbook manual primer", "guida", .feminine, "Leitfaden", .masculine, "ガイド"),
        NounRow("basics", "fundamentals essentials rudiments", "fondamenti", .masculine, "Grundlagen", .feminine, "基本"),
        NounRow("tricks", "hints pointers", "trucchi", .masculine, "Kniffe", .masculine, "コツ"),
        NounRow("mistakes", "errors blunders slips", "errori", .masculine, "Fehler", .masculine, "失敗"),
        NounRow("walkthrough", "playthrough solution", "soluzione", .feminine, "Komplettlösung", .feminine, "攻略"),
        NounRow("shortcuts", "bypasses timesavers", "scorciatoie", .feminine, "Abkürzungen", .feminine, "近道"),
        NounRow("rewards", "prizes payouts bounties", "ricompense", .feminine, "Belohnungen", .feminine, "報酬"),
    ]

    static let toolNounRows: [NounRow] = [
        NounRow("calculator", "estimator tabulator", "calcolatore", .masculine, "Rechner", .masculine, "計算機"),
        NounRow("journal", "diary logbook chronicle", "diario", .masculine, "Tagebuch", .neuter, "日誌"),
        NounRow("planner", "scheduler organizer", "pianificatore", .masculine, "Planer", .masculine, "プランナー"),
        NounRow("timer", "stopwatch countdown chronometer", "cronometro", .masculine, "Stoppuhr", .feminine, "タイマー"),
        NounRow("counter", "tally totalizer", "contatore", .masculine, "Zähler", .masculine, "カウンター"),
        NounRow("finder", "locator seeker detector", "cercatore", .masculine, "Sucher", .masculine, "探知機"),
        NounRow("calendar", "almanac datebook", "calendario", .masculine, "Kalender", .masculine, "暦"),
        NounRow("catalog", "index directory registry", "catalogo", .masculine, "Verzeichnis", .neuter, "目録"),
    ]

    static let viewNounRows: [NounRow] = [
        NounRow("sunrise", "daybreak dawn sunup", "alba", .feminine, "Sonnenaufgang", .masculine, "日の出"),
        NounRow("sunset", "sundown nightfall", "tramonto", .masculine, "Sonnenuntergang", .masculine, "夕日"),
        NounRow("landscape", "scenery vista", "paesaggio", .masculine, "Landschaft", .feminine, "景色"),
        NounRow("screenshot", "capture screengrab snapshot", "schermata", .feminine, "Bildschirmfoto", .neuter, "スクリーンショット"),
        NounRow("portrait", "likeness headshot depiction", "ritratto", .masculine, "Bildnis", .neuter, "肖像"),
        NounRow("sketch", "drawing draft doodle", "schizzo", .masculine, "Skizze", .feminine, "スケッチ"),
        NounRow("poster", "placard billboard", "manifesto", .masculine, "Plakat", .neuter, "ポスター"),
        NounRow("wallpaper", "background backdrop", "sfondo", .masculine, "Hintergrund", .masculine, "壁紙"),
    ]

    // MARK: Tags (genres and features)

    static let tagRows: [NounRow] = [
        NounRow("stealth", "sneaking infiltration", "furtività", .feminine, "Schleichen", .neuter, "隠密"),
        NounRow("puzzle", "riddle brainteaser conundrum", "rompicapo", .masculine, "Rätsel", .neuter, "パズル"),
        NounRow("racing", "speedway motorsport", "corse", .feminine, "Rennen", .neuter, "レース"),
        NounRow("strategy", "tactics planning", "strategia", .feminine, "Strategie", .feminine, "戦略"),
        NounRow("survival", "endurance subsistence", "sopravvivenza", .feminine, "Überleben", .neuter, "サバイバル"),
        NounRow("adventure", "escapade exploit odyssey", "avventura", .feminine, "Abenteuer", .neuter, "冒険"),
        NounRow("teamwork", "cooperation collaboration", "cooperazione", .feminine, "Zusammenarbeit", .feminine, "協力"),
        NounRow("beginner", "novice newcomer rookie", "principiante", .masculine, "Anfänger", .masculine, "初心者"),
        NounRow("expert", "veteran master specialist", "esperto", .masculine, "Meister", .masculine, "上級者"),
        NounRow("mystery", "whodunit intrigue enigma", "mistero", .masculine, "Krimi", .masculine, "ミステリー"),
        NounRow("rhythm", "beat tempo cadence", "ritmo", .masculine, "Takt", .masculine, "リズム"),
        NounRow("economy", "finance budget", "economia", .feminine, "Wirtschaft", .feminine, "経済"),
        NounRow("combat", "fighting brawling skirmish", "combattimento", .masculine, "Kampf", .masculine, "戦闘"),
        NounRow("narrative", "story plot tale", "trama", .feminine, "Handlung", .feminine, "物語"),
        NounRow("history", "past annals antiquity", "storia", .feminine, "Geschichte", .feminine, "歴史"),
        NounRow("education", "learning schooling teaching", "istruzione", .feminine, "Bildung", .feminine, "教育"),
        NounRow("family", "household kin relatives", "famiglia", .feminine, "Familie", .feminine, "家族"),
        NounRow("challenge", "trial ordeal test", "sfida", .feminine, "Herausforderung", .feminine, "挑戦"),
        NounRow("achievement", "accomplishment feat milestone", "traguardo", .masculine, "Erfolg", .masculine, "実績"),
        NounRow("weather", "climate forecast", "meteo", .masculine, "Wetter", .neuter, "気象"),
        NounRow("companion", "sidekick ally partner", "compagno", .masculine, "Gefährte", .masculine, "仲間"),
        NounRow("leaderboard", "ranking scoreboard standings", "classifica", .feminine, "Rangliste", .feminine, "ランキング"),
        NounRow("tournament", "competition contest championship", "torneo", .masculine, "Turnier", .neuter, "大会"),
    ]

    // MARK: Reserved words
    //
    // Reserved concepts are used only by golden items that carry no localization at all. Their
    // Italian, German and Japanese forms therefore never appear in any indexed surface: a query
    // made of them can only be answered by the semantic channel.

    static let reservedModifierRows: [NounRow] = [
        NounRow("raven", "crow corvid", "corvo", .masculine, "Rabe", .masculine, "鴉"),
        NounRow("fox", "vixen reynard", "volpe", .feminine, "Fuchs", .masculine, "狐"),
        NounRow("owl", "nightbird hooter", "gufo", .masculine, "Eule", .feminine, "梟"),
        NounRow("snake", "serpent viper adder", "serpente", .masculine, "Schlange", .feminine, "蛇"),
        NounRow("bear", "grizzly bruin", "orso", .masculine, "Bär", .masculine, "熊"),
        NounRow("stag", "deer buck hart", "cervo", .masculine, "Hirsch", .masculine, "鹿"),
        NounRow("hawk", "falcon raptor kestrel", "falco", .masculine, "Falke", .masculine, "鷹"),
        NounRow("whale", "leviathan cetacean", "balena", .feminine, "Wal", .masculine, "鯨"),
        NounRow("turtle", "tortoise terrapin", "tartaruga", .feminine, "Schildkröte", .feminine, "亀"),
        NounRow("spider", "arachnid tarantula", "ragno", .masculine, "Spinne", .feminine, "蜘蛛"),
        NounRow("boar", "hog swine", "cinghiale", .masculine, "Wildschwein", .neuter, "猪"),
        NounRow("heron", "egret crane", "airone", .masculine, "Reiher", .masculine, "鷺"),
        NounRow("toad", "frog bullfrog", "rospo", .masculine, "Kröte", .feminine, "蟇"),
        NounRow("hare", "rabbit bunny", "lepre", .feminine, "Hase", .masculine, "兎"),
        NounRow("velvet", "velour plush", "velluto", .masculine, "Samt", .masculine, "ビロード"),
        NounRow("honey", "nectar syrup", "miele", .masculine, "Honig", .masculine, "蜂蜜"),
        NounRow("thunder", "thunderclap rumble", "tuono", .masculine, "Donner", .masculine, "雷鳴"),
        NounRow("twilight", "dusk gloaming", "crepuscolo", .masculine, "Dämmerung", .feminine, "黄昏"),
        NounRow("thorn", "spine prickle barb", "spina", .feminine, "Dorn", .masculine, "棘"),
        NounRow("mirror", "reflector speculum", "specchio", .masculine, "Spiegel", .masculine, "鏡"),
        NounRow("feather", "plume quill", "piuma", .feminine, "Feder", .feminine, "羽"),
        NounRow("frost", "rime hoarfrost", "brina", .feminine, "Raureif", .masculine, "霜"),
        NounRow("ivory", "tusk", "avorio", .masculine, "Elfenbein", .neuter, "象牙"),
        NounRow("amber", "resin succinite", "ambra", .feminine, "Bernstein", .masculine, "琥珀"),
        NounRow("shadow", "shade silhouette umbra", "ombra", .feminine, "Schatten", .masculine, "影"),
        NounRow("clay", "loam terracotta", "argilla", .feminine, "Lehm", .masculine, "粘土"),
        NounRow("silk", "satin", "seta", .feminine, "Seide", .feminine, "絹"),
        NounRow("wool", "fleece yarn", "lana", .feminine, "Wolle", .feminine, "羊毛"),
        NounRow("ink", "dye pigment", "inchiostro", .masculine, "Tinte", .feminine, "墨"),
        NounRow("pearl", "nacre", "perla", .feminine, "Perle", .feminine, "真珠"),
    ]

    static let reservedPlaceRows: [NounRow] = [
        NounRow("lighthouse", "beacon pharos", "faro", .masculine, "Leuchtturm", .masculine, "灯台"),
        NounRow("monastery", "abbey cloister priory", "abbazia", .feminine, "Kloster", .neuter, "修道院"),
        NounRow("observatory", "planetarium", "osservatorio", .masculine, "Sternwarte", .feminine, "天文台"),
        NounRow("windmill", "mill gristmill", "mulino", .masculine, "Windmühle", .feminine, "風車"),
        NounRow("vineyard", "winery vinery", "vigneto", .masculine, "Weinberg", .masculine, "葡萄園"),
        NounRow("orchard", "grove plantation", "frutteto", .masculine, "Obstgarten", .masculine, "果樹園"),
        NounRow("shipyard", "dockyard boatyard", "cantiere", .masculine, "Werft", .feminine, "造船所"),
        NounRow("brewery", "distillery", "birrificio", .masculine, "Brauerei", .feminine, "醸造所"),
        NounRow("forge", "smithy foundry", "fucina", .feminine, "Schmiede", .feminine, "鍛冶場"),
        NounRow("greenhouse", "conservatory hothouse glasshouse", "serra", .feminine, "Gewächshaus", .neuter, "温室"),
        NounRow("maze", "labyrinth", "labirinto", .masculine, "Irrgarten", .masculine, "迷路"),
        NounRow("well", "cistern borehole", "pozzo", .masculine, "Brunnen", .masculine, "井戸"),
        NounRow("pier", "jetty wharf quay", "molo", .masculine, "Steg", .masculine, "埠頭"),
        NounRow("attic", "loft garret", "soffitta", .feminine, "Dachboden", .masculine, "屋根裏"),
        NounRow("cellar", "basement", "cantina", .feminine, "Keller", .masculine, "地下室"),
        NounRow("courtyard", "quadrangle patio", "cortile", .masculine, "Innenhof", .masculine, "中庭"),
        NounRow("stable", "barn paddock", "scuderia", .feminine, "Pferdestall", .masculine, "厩舎"),
        NounRow("inn", "hostel lodge guesthouse", "locanda", .feminine, "Gasthaus", .neuter, "宿屋"),
        NounRow("reef", "shoal sandbar", "barriera", .feminine, "Riff", .neuter, "岩礁"),
    ]

    static let reservedObjectRows: [NounRow] = [
        NounRow("telescope", "spyglass scope", "cannocchiale", .masculine, "Fernrohr", .neuter, "望遠鏡"),
        NounRow("hourglass", "sandglass", "clessidra", .feminine, "Sanduhr", .feminine, "砂時計"),
        NounRow("kettle", "teapot boiler", "bollitore", .masculine, "Kessel", .masculine, "薬缶"),
        NounRow("chisel", "gouge graver", "scalpello", .masculine, "Meißel", .masculine, "鑿"),
        NounRow("sickle", "scythe", "falce", .feminine, "Sichel", .feminine, "鎌"),
        NounRow("ladle", "scoop dipper", "mestolo", .masculine, "Kelle", .feminine, "柄杓"),
        NounRow("broom", "besom", "scopa", .feminine, "Besen", .masculine, "箒"),
        NounRow("saddle", "harness pillion", "sella", .feminine, "Sattel", .masculine, "鞍"),
        NounRow("pickaxe", "pick mattock", "piccone", .masculine, "Spitzhacke", .feminine, "鶴嘴"),
        NounRow("shovel", "spade", "pala", .feminine, "Schaufel", .feminine, "シャベル"),
        NounRow("compass", "lodestone", "bussola", .feminine, "Kompass", .masculine, "羅針盤"),
        NounRow("lute", "mandolin", "liuto", .masculine, "Laute", .feminine, "リュート"),
    ]

    static let reservedThemeRows: [NounRow] = [
        NounRow("covenant", "pact treaty accord", "patto", .masculine, "Bündnis", .neuter, "盟約"),
        NounRow("lullaby", "cradlesong berceuse", "ninnananna", .feminine, "Wiegenlied", .neuter, "子守唄"),
        NounRow("vengeance", "revenge retribution reprisal", "vendetta", .feminine, "Rache", .feminine, "復讐"),
        NounRow("famine", "starvation hunger", "carestia", .feminine, "Hungersnot", .feminine, "飢饉"),
        NounRow("plague", "pestilence epidemic contagion", "peste", .feminine, "Seuche", .feminine, "疫病"),
        NounRow("siege", "blockade encirclement", "assedio", .masculine, "Belagerung", .feminine, "包囲"),
        NounRow("pilgrimage", "peregrination", "pellegrinaggio", .masculine, "Wallfahrt", .feminine, "巡礼"),
        NounRow("drought", "dryness aridity", "siccità", .feminine, "Dürre", .feminine, "旱魃"),
        NounRow("carnival", "festival fair fete", "carnevale", .masculine, "Jahrmarkt", .masculine, "祝祭"),
        NounRow("avalanche", "snowslide landslide", "valanga", .feminine, "Lawine", .feminine, "雪崩"),
    ]
}
