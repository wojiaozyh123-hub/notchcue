//
//  Pinyin.swift
//  PrompterCore
//
//  Toneless pinyin readings for matching homophones. CFStringTransform gives
//  one reading per character with no context (银行 → yin xing, 音乐 → yin le),
//  so a character also carries the other readings from a small table of common
//  polyphones. Two characters sound alike when their reading sets intersect.
//

import Foundation

public struct PinyinOptions: Equatable, Sendable {
    /// Merge z/zh, c/ch, s/sh, n/l, an/ang, en/eng, in/ing before comparing.
    public var fuzzy: Bool
    /// Off for Cantonese recognizers, where Mandarin readings do not describe
    /// what was heard; characters then match only exactly.
    public var mandarin: Bool

    public init(fuzzy: Bool = false, mandarin: Bool = true) {
        self.fuzzy = fuzzy
        self.mandarin = mandarin
    }
}

public enum Pinyin {
    /// The CFStringTransform reading without tone marks, or nil when the
    /// character has no Mandarin reading.
    public static func primarySyllable(of character: Character) -> String? {
        guard character.isHan else { return nil }
        let text = NSMutableString(string: String(character))
        guard CFStringTransform(text, nil, kCFStringTransformMandarinLatin, false),
              CFStringTransform(text, nil, kCFStringTransformStripDiacritics, false) else { return nil }
        let syllable = (text as String).lowercased()
        guard !syllable.isEmpty, syllable.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return syllable
    }

    /// Every toneless reading of a character, already fuzzy-normalized when
    /// the options ask for it. Empty for non-Chinese characters.
    public static func readings(of character: Character, options: PinyinOptions) -> Set<String> {
        guard options.mandarin else { return [] }
        var readings = Set(polyphoneReadings[character] ?? [])
        if let primary = primarySyllable(of: character) {
            readings.insert(primary)
        }
        return options.fuzzy ? Set(readings.map(fuzzyNormalized)) : readings
    }

    public static func normalize(_ syllable: String, options: PinyinOptions) -> String {
        options.fuzzy ? fuzzyNormalized(syllable) : syllable
    }

    /// Maps both members of each confusable pair onto one spelling.
    public static func fuzzyNormalized(_ syllable: String) -> String {
        var s = syllable
        if s.hasPrefix("zh") || s.hasPrefix("ch") || s.hasPrefix("sh") {
            s.remove(at: s.index(after: s.startIndex))
        } else if s.hasPrefix("n"), s != "ng" {
            s = "l" + s.dropFirst()
        }
        if s.hasSuffix("ang") || s.hasSuffix("eng") || s.hasSuffix("ing") {
            s.removeLast()
        }
        return s
    }

    /// Readings CFStringTransform does not give, for frequent polyphones.
    /// Each list holds every toneless reading; the transform's own reading is
    /// added at lookup. ü is written u, as StripDiacritics produces.
    static let polyphoneReadings: [Character: [String]] = [
        "行": ["xing", "hang"], "重": ["zhong", "chong"], "长": ["chang", "zhang"],
        "乐": ["le", "yue"], "觉": ["jue", "jiao"], "的": ["de", "di"],
        "了": ["le", "liao"], "得": ["de", "dei"], "地": ["de", "di"],
        "着": ["zhe", "zhao", "zhuo"], "还": ["hai", "huan"], "都": ["dou", "du"],
        "和": ["he", "huo", "hu"], "朝": ["chao", "zhao"], "调": ["tiao", "diao"],
        "传": ["chuan", "zhuan"], "差": ["cha", "chai", "ci"], "大": ["da", "dai"],
        "会": ["hui", "kuai"], "弹": ["dan", "tan"], "参": ["can", "shen", "cen"],
        "薄": ["bao", "bo"], "降": ["jiang", "xiang"], "便": ["bian", "pian"],
        "数": ["shu", "shuo"], "曾": ["ceng", "zeng"], "藏": ["cang", "zang"],
        "解": ["jie", "xie"], "校": ["xiao", "jiao"], "省": ["sheng", "xing"],
        "属": ["shu", "zhu"], "率": ["lu", "shuai"], "奇": ["qi", "ji"],
        "系": ["xi", "ji"], "落": ["luo", "la", "lao"], "露": ["lu", "lou"],
        "区": ["qu", "ou"], "单": ["dan", "shan", "chan"], "石": ["shi", "dan"],
        "宿": ["su", "xiu"], "血": ["xue", "xie"], "壳": ["ke", "qiao"],
        "削": ["xiao", "xue"], "给": ["gei", "ji"], "角": ["jiao", "jue"],
        "脚": ["jiao", "jue"], "没": ["mei", "mo"], "否": ["fou", "pi"],
        "称": ["cheng", "chen"], "盛": ["sheng", "cheng"], "择": ["ze", "zhai"],
        "仇": ["chou", "qiu"], "秘": ["mi", "bi"], "厦": ["sha", "xia"],
        "吓": ["xia", "he"], "咳": ["ke", "hai"], "炮": ["pao", "bao"],
        "模": ["mo", "mu"], "柏": ["bai", "bo"], "剥": ["bo", "bao"],
        "伯": ["bo", "bai"], "迫": ["po", "pai"], "粘": ["nian", "zhan"],
        "似": ["si", "shi"], "识": ["shi", "zhi"], "殖": ["zhi", "shi"],
        "叶": ["ye", "xie"], "折": ["zhe", "she"], "什": ["shen", "shi"],
        "乘": ["cheng", "sheng"], "车": ["che", "ju"], "么": ["me", "mo", "yao"],
        "哪": ["na", "nei"], "那": ["na", "nei"], "恶": ["e", "wu"],
        "佛": ["fo", "fu"], "夹": ["jia", "ga"], "见": ["jian", "xian"],
        "劲": ["jin", "jing"], "句": ["ju", "gou"], "卡": ["ka", "qia"],
        "括": ["kuo", "gua"], "俩": ["lia", "liang"], "绿": ["lu"],
        "脉": ["mai", "mo"], "埋": ["mai", "man"], "抹": ["mo", "ma"],
        "弄": ["nong", "long"], "胖": ["pang", "pan"], "屏": ["ping", "bing"],
        "朴": ["pu", "po", "piao"], "期": ["qi", "ji"], "强": ["qiang", "jiang"],
        "亲": ["qin", "qing"], "圈": ["quan", "juan"], "色": ["se", "shai"],
        "塞": ["sai", "se"], "说": ["shuo", "shui"], "缩": ["suo", "su"],
        "提": ["ti", "di"], "拓": ["tuo", "ta"], "尾": ["wei", "yi"],
        "巷": ["xiang", "hang"], "咽": ["yan", "ye"], "扎": ["zha", "za"],
        "臭": ["chou", "xiu"], "绰": ["chuo", "chao"], "刹": ["cha", "sha"],
        "颤": ["chan", "zhan"], "嘲": ["chao", "zhao"], "匙": ["chi", "shi"],
        "度": ["du", "duo"], "合": ["he", "ge"], "茄": ["qie", "jia"],
        "雀": ["que", "qiao"], "纤": ["xian", "qian"], "召": ["zhao", "shao"],
        "谁": ["shui", "shei"], "熟": ["shu", "shou"], "遗": ["yi", "wei"],
        "爪": ["zhua", "zhao"], "仔": ["zai", "zi"], "南": ["nan", "na"],
        "其": ["qi", "ji"], "栖": ["qi", "xi"], "幢": ["zhuang", "chuang"],
        "攒": ["zan", "cuan"], "囤": ["tun", "dun"], "晕": ["yun"],
        "蔓": ["man", "wan"], "瀑": ["pu", "bao"], "畜": ["chu", "xu"],
        "冯": ["feng", "ping"], "红": ["hong", "gong"], "颈": ["jing", "geng"],
        "扛": ["kang", "gang"], "烙": ["lao", "luo"], "棱": ["leng", "ling"],
        "摩": ["mo", "ma"], "泌": ["mi", "bi"], "疟": ["nue", "yao"],
        "刨": ["pao", "bao"], "杉": ["shan", "sha"], "沓": ["ta", "da"],
        "吁": ["xu", "yu"], "咋": ["za", "ze", "zha"], "柞": ["zuo", "zha"],
        "澄": ["cheng", "deng"], "轧": ["ya", "zha", "ga"], "蛤": ["ha", "ge"],
        "戏": ["xi", "hu"], "殷": ["yin", "yan"], "栅": ["zha", "shan"],
        "辗": ["zhan", "nian"], "尉": ["wei", "yu"], "褪": ["tui", "tun"],
        "呱": ["gua", "gu"], "龟": ["gui", "jun", "qiu"], "娜": ["na", "nuo"],
        "螫": ["shi", "zhe"], "佚": ["yi", "die"], "熨": ["yun", "yu"],
        "厂": ["chang", "an"], "广": ["guang", "an"], "铺": ["pu"],
    ]
}
