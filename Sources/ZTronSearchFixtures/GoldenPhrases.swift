import Foundation

/// How the concepts of a golden title are arranged.
enum GoldenTitlePattern: Sendable, Hashable {
    /// `[modifier, head]`: "Frozen Harbor".
    case modifierHead
    /// `[modifier, head, noun]`: "Frozen Harbor Route".
    case modifierHeadNoun
    /// `[head, noun]`: "Potion Calculator", "Fishing Basics", "Stealth Legion".
    case headNoun
    /// `[modifier, head]` followed by a numeral: "Hollow Tide 2".
    case modifierHeadNumber(Int)
}

/// Composes titles and phrases from lexicon concepts in one language.
///
/// The templates are chosen so that the little grammar they need is always right: Italian and
/// German adjectives agree with the gender of their noun, a third element follows a colon instead
/// of a preposition, and Japanese adjectives come in their attributive form. No template writes
/// an apostrophe: `NLTokenizer` keeps an Italian elision such as `dell'isola` as one word, which
/// would hide the noun from the index.
struct GoldenPhrases: Sendable {
    /// `"en"`, `"it"`, `"de"` or `"ja"`.
    let language: String

    /// A noun as it is written inside a sentence.
    func word(_ concept: FixtureConcept) -> String {
        concept.form(in: language)
    }

    /// A modifier and its head, lowercase except for German nouns: "frozen harbor",
    /// "porto ghiacciato", "gefrorener Hafen", "凍った港".
    ///
    /// A noun used as a modifier ("raven lighthouse") only exists in English: the items that use
    /// one carry no localization.
    func nounPhrase(_ modifier: FixtureConcept, _ head: FixtureConcept) -> String {
        switch language {
        case "it":
            return head.italian + " " + modifier.italianForm(agreeingWith: head.italianGender ?? .masculine)
        case "de":
            return modifier.germanForm(agreeingWith: head.germanGender ?? .masculine) + " " + head.german
        case "ja":
            return modifier.japanese + head.japanese
        default:
            return modifier.lemma + " " + head.lemma
        }
    }

    /// The subject of an item as its body text names it: the modifier and head of the title, or
    /// the head alone.
    func subject(_ pattern: GoldenTitlePattern, _ concepts: [FixtureConcept]) -> String {
        switch pattern {
        case .modifierHead, .modifierHeadNoun, .modifierHeadNumber:
            return nounPhrase(concepts[0], concepts[1])
        case .headNoun:
            return word(concepts[0])
        }
    }

    /// The title of an item.
    func title(_ pattern: GoldenTitlePattern, _ concepts: [FixtureConcept]) -> String {
        switch language {
        case "it":
            switch pattern {
            case .modifierHead:
                return Self.capitalized(nounPhrase(concepts[0], concepts[1]))
            case .modifierHeadNoun:
                return Self.capitalized(nounPhrase(concepts[0], concepts[1])) + ": " + concepts[2].italian
            case .headNoun:
                return Self.capitalized(concepts[0].italian) + ": " + concepts[1].italian
            case .modifierHeadNumber(let number):
                return Self.capitalized(nounPhrase(concepts[0], concepts[1])) + " \(number)"
            }
        case "de":
            switch pattern {
            case .modifierHead:
                return Self.capitalized(nounPhrase(concepts[0], concepts[1]))
            case .modifierHeadNoun:
                return Self.capitalized(nounPhrase(concepts[0], concepts[1])) + ": " + concepts[2].german
            case .headNoun:
                // A tool is a compound noun in German: "Trank-Rechner".
                let joiner = concepts[1].role == .toolNoun ? "-" : ": "
                return concepts[0].german + joiner + concepts[1].german
            case .modifierHeadNumber(let number):
                return Self.capitalized(nounPhrase(concepts[0], concepts[1])) + " \(number)"
            }
        case "ja":
            switch pattern {
            case .modifierHead:
                return nounPhrase(concepts[0], concepts[1])
            case .modifierHeadNoun:
                return nounPhrase(concepts[0], concepts[1]) + "の" + concepts[2].japanese
            case .headNoun:
                let joiner = concepts[1].role == .toolNoun ? "" : "の"
                return concepts[0].japanese + joiner + concepts[1].japanese
            case .modifierHeadNumber(let number):
                return nounPhrase(concepts[0], concepts[1]) + "\(number)"
            }
        default:
            var words = concepts.map { Self.capitalized($0.lemma) }
            if case .modifierHeadNumber(let number) = pattern { words.append("\(number)") }
            return words.joined(separator: " ")
        }
    }

    /// A list of nouns: "chest, key, lantern".
    func list(_ concepts: [FixtureConcept]) -> String {
        concepts.map(word).joined(separator: language == "ja" ? "、" : ", ")
    }

    /// Uppercases the first character and leaves the rest alone.
    static func capitalized(_ string: String) -> String {
        guard let first = string.first else { return string }
        return first.uppercased() + string.dropFirst()
    }

    // MARK: Body texts

    /// What a body is written from.
    struct Body {
        var pattern: GoldenTitlePattern
        var title: [FixtureConcept]
        var objects: [FixtureConcept] = []
        var actions: [FixtureConcept] = []
        var place: FixtureConcept?
        var tag: FixtureConcept?
    }

    /// Body of a map: what it shows and what it marks.
    func mapText(_ body: Body) -> String {
        let subject = subject(body.pattern, body.title)
        let marks = list(body.objects)
        let action = body.actions.first.map(word) ?? ""
        switch language {
        case "it":
            return "Mappa interattiva. Luogo: \(subject). Punti segnati: \(marks). Zona popolare per: \(action)."
        case "de":
            return "Interaktive Karte. Ort: \(subject). Markierte Punkte: \(marks). Beliebt für: \(action)."
        case "ja":
            return "\(subject)のインタラクティブな地図。目印：\(marks)。\(action)に人気の場所。"
        default:
            return "Interactive map of the \(subject). Notable points: \(marks). Popular area for \(action)."
        }
    }

    /// Body of a tip. A tip is about a place (three-word titles), an activity or an object.
    func tipText(_ body: Body) -> String {
        let items = list(body.objects)
        let action = body.actions.first.map(word) ?? ""
        let place = body.place.map(word) ?? ""
        let subject = subject(body.pattern, body.title)
        let isLocation: Bool
        if case .headNoun = body.pattern { isLocation = false } else { isLocation = true }
        let isActivity = !isLocation && body.title[0].wordClass == .action

        switch language {
        case "it":
            if isLocation {
                return "Consigli pratici. Luogo: \(subject). Oggetti utili: \(items). Utile prima di: \(action)."
            }
            let combine = isActivity ? "Oggetti utili" : "Da combinare con"
            return "Consigli pratici. Tema: \(subject). \(combine): \(items). Luogo consigliato: \(place)."
        case "de":
            if isLocation {
                return "Praktische Hinweise. Ort: \(subject). Nützliche Gegenstände: \(items). Hilfreich vor: \(action)."
            }
            let combine = isActivity ? "Nützliche Gegenstände" : "Kombinierbar mit"
            return "Praktische Hinweise. Thema: \(subject). \(combine): \(items). Empfohlener Ort: \(place)."
        case "ja":
            if isLocation {
                return "\(subject)についての実用的なアドバイス。役立つ道具：\(items)。\(action)の前に便利。"
            }
            let combine = isActivity ? "役立つ道具" : "組み合わせ"
            return "\(subject)についての実用的なアドバイス。\(combine)：\(items)。おすすめの場所：\(place)。"
        default:
            let first = body.objects.first.map(word) ?? ""
            let second = body.objects.dropFirst().first.map(word) ?? ""
            if isLocation {
                return "Practical advice for the \(subject). Bring the \(first) and the \(second). Useful before \(action)."
            }
            if isActivity {
                return "Practical advice about \(subject). Bring the \(first) and the \(second). Works best near the \(place)."
            }
            return "Practical advice about the \(subject). Combine with the \(first) and the \(second). Works best near the \(place)."
        }
    }

    /// Body of a tool: what it is for and what it supports.
    func toolText(_ body: Body) -> String {
        let subject = subject(body.pattern, body.title)
        let supported = list(body.actions)
        let category = body.title.last.map(word) ?? ""
        switch language {
        case "it":
            return "Strumento pratico. Oggetto: \(subject). Supporta: \(supported). Categoria: \(category)."
        case "de":
            return "Praktisches Werkzeug. Gegenstand: \(subject). Unterstützt: \(supported). Kategorie: \(category)."
        case "ja":
            return "\(subject)のための便利なツール。対応：\(supported)。分類：\(category)。"
        default:
            let first = body.actions.first.map(word) ?? ""
            let second = body.actions.dropFirst().first.map(word) ?? ""
            return "Handy utility for every \(subject). Supports \(first) and \(second). Category: \(category)."
        }
    }

    /// Body of a game: its campaign, genre, setting and features.
    func gameText(_ body: Body) -> String {
        let campaign: String
        if case .headNoun = body.pattern {
            // "Stealth Legion": the campaign is named after both words.
            campaign = language == "ja"
                ? word(body.title[0]) + "の" + word(body.title[1])
                : word(body.title[0]) + " " + word(body.title[1])
        } else {
            campaign = subject(body.pattern, body.title)
        }
        let genre = body.tag.map(word) ?? ""
        let place = body.place.map(word) ?? ""
        let features = list(body.actions + body.objects)
        switch language {
        case "it":
            return "Campagna: \(campaign). Genere: \(genre). Ambientazione: \(place). Elementi: \(features)."
        case "de":
            return "Kampagne: \(campaign). Genre: \(genre). Schauplatz: \(place). Elemente: \(features)."
        case "ja":
            return "\(campaign)のキャンペーン。ジャンル：\(genre)。設定：\(place)。要素：\(features)。"
        default:
            let actions = list(body.actions)
            let object = body.objects.first.map(word) ?? ""
            return "The \(campaign) campaign. Genre: \(genre). Setting: the \(place). Features: \(actions), the legendary \(object)."
        }
    }

    /// Alt text of an image: what kind of picture it is and what it shows.
    func imageAltText(_ body: Body) -> String {
        let subject = subject(body.pattern, body.title)
        let view: FixtureConcept? = body.title.count > 2 ? body.title[2] : nil
        switch language {
        case "it":
            return "Tipo di immagine: \(view.map(word) ?? "illustrazione"). Soggetto: \(subject)."
        case "de":
            return "Bildtyp: \(view.map(word) ?? "Illustration"). Motiv: \(subject)."
        case "ja":
            return "画像の種類：\(view.map(word) ?? "イラスト")。被写体：\(subject)。"
        default:
            return "Image type: \(view.map(word) ?? "illustration"). Subject: the \(subject)."
        }
    }

    /// Caption of an image.
    func imageCaption(_ body: Body) -> String {
        let subject = subject(body.pattern, body.title)
        if let place = body.place.map(word) {
            switch language {
            case "it": return "\(Self.capitalized(subject)) vicino a: \(place)."
            case "de": return "\(Self.capitalized(subject)), in der Nähe: \(place)."
            case "ja": return "\(place)の近くの\(subject)。"
            default: return "The \(subject) resting near the \(place)."
            }
        }
        let object = body.objects.first.map(word) ?? ""
        switch language {
        case "it": return "\(Self.capitalized(subject)), \(object) in primo piano."
        case "de": return "\(Self.capitalized(subject)), \(object) im Vordergrund."
        case "ja": return "\(subject)、手前に\(object)。"
        default: return "The \(subject), \(object) in the foreground."
        }
    }
}
