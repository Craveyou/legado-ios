import Foundation
import CoreFoundation

/// 文本编码识别：参照 LocalNovel TextLoader/TextEncoding 的顺序规则（精简打分版）。
/// 顺序：BOM → 严格 UTF-8 → UTF-16（仅 NUL 特征）→ GB18030 / Big5（按常用汉字打分）。
/// 关键：UTF-16 不能盲目尝试，否则 GBK 文件会被解成乱码。
enum LNTextDecoder {
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        if let s = decodeBOM(data) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        // UTF-16 只在有明显 NUL 字节交替时尝试
        if looksLikeUTF16(data) {
            for enc in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
                if let s = String(data: data, encoding: enc), !s.isEmpty { return s }
            }
        }
        // GB18030 / Big5 按常用汉字出现率取高分
        let gb = cfEncoding(.GB_18030_2000)
        let big5 = cfEncoding(.big5)
        var best: (String, Int)?
        for enc in [gb, big5] {
            guard let s = String(data: data, encoding: enc), !s.isEmpty else { continue }
            let score = readability(s)
            if best == nil || score > best!.1 { best = (s, score) }
        }
        return best?.0
    }

    static func cfEncoding(_ cf: CFStringEncodings) -> String.Encoding {
        let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        return String.Encoding(rawValue: UInt(ns))
    }

    private static func decodeBOM(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    private static func looksLikeUTF16(_ data: Data) -> Bool {
        let sample = [UInt8](data.prefix(64))
        guard sample.count >= 8 else { return false }
        var nulEven = 0, nulOdd = 0
        for (i, byte) in sample.enumerated() where byte == 0 {
            if i % 2 == 0 { nulEven += 1 } else { nulOdd += 1 }
        }
        return nulEven >= 3 || nulOdd >= 3
    }

    /// 常用汉字命中数（够用即可，不照搬 LocalNovel 的完整字表）
    private static let commonHanzi: Set<Unicode.Scalar> = Set(
        "的一是了我不人在他有这上们来到时大地为子中你说生国年着就那和要她出也得里后自以会家可下而过天去能对小多然于心学么之都好看起发当没成只如事把还用第样道想作种开美总从无情己面最女但现前些所同日手又行意动方期它头经长儿回位分爱老因很给名法间斯知世什两次使身者被高已亲其进此话常与活正感见明问力理尔点文几定本公特做外孩相西果走将月十实向声车全信重三机工物气每并别真打太新比才便夫再书部水像眼等体却加电主界门利海受听表德少克代员许先口由死安写性马光白或住难望教命花结乐色更拉东神记处让母父应直字场平报友关放至张认接告入笑内英军候民岁往何度山觉路带万男边风解叫任金快原吃妈变通师立象数四失满战远格士音轻目条呢病始达深完今提求清王化空业思切怎非找片钱吗语元喜曾离飞科言干流欢约各即指合反题必该论交终林请医晚制球决传画保读运及则房早院量苦火布品近坐产答星精视五连司奇管类未朋且台夜青北队久乎越观落尽形影红爸百令周吧识步希术留市半热送兴造谈容极随演收首根讲整式取照办强石古华拿计您装似足双转诉米称丽客南领节衣站黑刻统断福城故历惊脸选包紧争另建维绝树系伤示愿持千史谁准联妇纪基买志静诗独复痛消社算义竟确酒需单治卡幸念举仅钟怕共毛句息功官待究跟穿室易游程号居考突皮哪费倒价图具刚脑永歌响商礼细专黄块脚味灵改据般破引食仍存众注笔甚某沉血备习校默务土微娘须试怀料调广苏显赛查密议底列富梦错座参八除跑亮假印设线温虽掉京初养香停际致阳纸李纳验助激够严证帝饭忘趣支春集丈木研班普导顿睡展跳获艺六波察群皇段急庭创区奥器谢弟店否害草排背止组州朝封睛板角况曲馆育忙质河续哥呼若推镜遇雨标姐充围案伦护冷警贝雪索剧船险烟依斗值帮汉慢佛肯闻唱沙局伯族低玩资屋击速顾泪洲团圣旁堂兵七露园牛哭旅街劳型烈姑陈莫鱼异抱宝权鲁简态级票怪寻杀律胜份汽右洋范床舞秘午登楼贵吸责例追较职属渐左录丝牙党继托赶章智冲叶胡吉卖坚喝肉遗救修松临藏担戏善卫药悲敢靠村戴词森耳差短祖云规窗散迷油旧适乡架恩投弹铁博雷府压超负勒杂醒洗采毫嘴毕九冰既状乱景席珍童顶派素脱农疑练野按犯拍征坏骨余承置彩灯巨琴免环暗换技翻束增忍餐缺忆判欧层付阵批岛项狗休懂武革良恶恋委拥妙探呀营退摇弄桌熟宣银势奖宫忽套康供优课鸟喊降夏困罪亡鞋健模败伴守挥鲜财孤枪禁恐伙杰迹妹遍盖副坦牌江顺秋菜划授归浪凡预奶雄升编典袋含盛济蒙棋端腿招释介烧误".unicodeScalars)

    private static func readability(_ s: String) -> Int {
        let sample = s.prefix(4000)
        var score = 0
        for scalar in sample.unicodeScalars where commonHanzi.contains(scalar) { score += 1 }
        return score
    }

    /// 段落切分：按换行，去掉首尾空行
    static func paragraphs(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
