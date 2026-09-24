import SwiftUI
import WebKit

// Jev, TypeSafe's decision model, driving the page in front: say what you want
// done and it clicks, types and scrolls its way there, one step at a time.
//
// Jev doesn't write, it picks. Each step the page's links, buttons and fields
// are read into a numbered list, and one request asks three things at once:
// which of them to use next, whether the task already looks done, and whether
// the run is going round in circles. Code keeps the loop: the step budget, the
// clock, the stop, the next-best try when an action changed nothing.
//
// And since Jev can't make words up, anything typed into a page is a phrase
// lifted from the task itself — Jev only chooses which. Nothing the person
// didn't write goes into a page, and a password field is never offered at all.

/// The HTTP side: one endpoint, a key, typed answers.
enum Jev {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"

    enum Failure: LocalizedError {
        case noKey
        case refused(Int, String)
        case garbled

        var errorDescription: String? {
            switch self {
            case .noKey: return "Put TYPESAFE_API_KEY in ~/.env first"
            case .refused(401, _): return "TypeSafe didn't take the key in ~/.env"
            case .refused(let status, let why): return why.isEmpty ? "TypeSafe answered \(status)" : why
            case .garbled: return "TypeSafe's answer made no sense"
            }
        }
    }

    /// From the environment Search was started with, or else ~/.env, where
    /// people keep such things. Read afresh each run, so a key added while
    /// Search is open is picked up without a restart.
    static var key: String? {
        if let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty { return key }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "TYPESAFE_API_KEY" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    struct Choice {
        let pick: String
        let odds: [String: Double]
        /// Every option, likeliest first.
        var ranked: [String] { odds.sorted { $0.value > $1.value }.map(\.key) }
    }

    struct Answers {
        let raw: [String: Any]

        func choice(_ id: String) -> Choice? {
            guard let answer = raw[id] as? [String: Any], let pick = answer["choice"] as? String else { return nil }
            let odds = (answer["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            return Choice(pick: pick, odds: odds.isEmpty ? [pick: 1] : odds)
        }

        func noul(_ id: String) -> Double? {
            ((raw[id] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue
        }
    }

    static func ask(state: Any, questions: [String: Any], key: String) async throws -> Answers {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "state": state, "questions": questions,
        ])
        var wait: UInt64 = 500_000_000
        for attempt in 0..<4 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Busy rather than broken: asked again, a little later each time.
            if status == 429 || status == 529, attempt < 3 {
                try await Task.sleep(nanoseconds: wait)
                wait *= 2
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard status == 200 else { throw Failure.refused(status, reason(json)) }
            guard let answers = json?["answers"] as? [String: Any] else { throw Failure.garbled }
            return Answers(raw: answers)
        }
        throw Failure.refused(529, "TypeSafe is busy — try again in a moment")
    }

    private static func reason(_ json: [String: Any]?) -> String {
        if let detail = json?["detail"] as? String { return detail }
        if let error = json?["error"] as? String { return error }
        if let error = (json?["error"] as? [String: Any])?["message"] as? String { return error }
        return json?["message"] as? String ?? ""
    }
}

@MainActor
final class Pilot: ObservableObject {
    /// The bar is up.
    @Published private(set) var open = false
    @Published var task = ""
    @Published private(set) var running = false
    /// What it is doing now, or how the last run ended.
    @Published private(set) var line: String?
    @Published private(set) var focus = 0

    private weak var browser: Browser?
    private var job: Task<Void, Never>?

    static let steps = 20
    static let seconds: TimeInterval = 150
    /// Past this, a yes-or-no answer is taken as said.
    static let sure = 0.85

    init(browser: Browser) { self.browser = browser }

    func show() {
        open = true
        focus += 1
    }

    func close() {
        stop()
        open = false
        line = nil
    }

    func start() {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !running else { return }
        guard let key = Jev.key else {
            line = Jev.Failure.noKey.errorDescription
            return
        }
        running = true
        line = "Looking at the page"
        job = Task { [weak self] in await self?.drive(task, key: key) }
    }

    func stop() {
        guard running else { return }
        job?.cancel()
        job = nil
        running = false
        line = "Stopped"
    }

    private func end(_ said: String) {
        guard running, !Task.isCancelled else { return }
        running = false
        job = nil
        line = said
    }

    // MARK: - the loop

    private func drive(_ task: String, key: String) async {
        let began = Date()
        // What has been done so far, for Jev to read; and which actions have
        // already been tried on a page that looked just like this one.
        var trail: [String] = []
        var tried: Set<String> = []
        do {
            for step in 1...Pilot.steps {
                guard browser?.prefs.pilot == true else { return end("Stopped") }
                guard let tab = browser?.active, !tab.isBlank else { return end("There's no page to work on") }
                guard Date().timeIntervalSince(began) < Pilot.seconds else {
                    return end("Out of time after \(step - 1) steps")
                }
                await settle(tab)
                try Task.checkCancellation()
                let page = try await Pilot.observe(tab.web)
                let state: [String: Any] = [
                    "task": task,
                    "page": ["url": page.url, "title": page.title, "text": page.text],
                    "done_so_far": trail.isEmpty ? ["nothing yet"] : Array(trail.suffix(10)),
                ]
                let menu = page.menu(canGoBack: tab.canGoBack)
                let answers = try await Jev.ask(state: state, questions: Pilot.questions(menu), key: key)
                try Task.checkCancellation()
                guard let action = answers.choice("action") else { throw Jev.Failure.garbled }
                if answers.noul("goal") ?? 0 > Pilot.sure { return end(step == 1 ? "Already done" : "Done") }
                if answers.noul("stuck") ?? 0 > Pilot.sure { return end("Stuck, so stopped") }

                // Something already done to this very page changed nothing;
                // the next likeliest is tried rather than the same again.
                let pick = action.ranked.first { $0 == "done" || !tried.contains($0 + page.signature) } ?? "done"
                if pick == "done" { return end(step == 1 ? "Nothing to do here" : "Done") }
                tried.insert(pick + page.signature)
                let odds = Int(((action.odds[pick] ?? 0) * 100).rounded())
                line = "\(Pilot.doing(pick, page)) · \(odds)%"
                let did = try await perform(pick, on: tab, page: page, task: task, key: key)
                try Task.checkCancellation()
                trail.append(did)
                line = "\(did) · \(odds)%"
            }
            end("Stopped after \(Pilot.steps) steps")
        } catch {
            end(error is CancellationError ? "Stopped" : error.localizedDescription)
        }
    }

    /// Until the page has stopped loading, and a moment more for what it
    /// draws after.
    private func settle(_ tab: Tab) async {
        let deadline = Date().addingTimeInterval(10)
        try? await Task.sleep(nanoseconds: 250_000_000)
        while tab.loading, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private static func questions(_ menu: [String: String]) -> [String: Any] {
        [
            "action": [
                "type": "choice",
                "instructions": "Which single action best advances `task` on the current page, given `done_so_far`?",
                "criteria": menu,
            ],
            "goal": [
                "type": "noul",
                "instructions": "Has `task` been achieved: does the current page show the outcome it asks for?",
                "criteria": [
                    "true": "The page being viewed is the sought destination, or shows the sought result",
                    "false": "The task is not finished yet",
                ],
            ],
            "stuck": [
                "type": "noul",
                "instructions": "Are the actions in `done_so_far` failing to make progress toward `task`?",
                "criteria": [
                    "true": "The same actions repeat or nothing changes; this approach is not working",
                    "false": "Progress is visible, or it is still early",
                ],
            ],
        ]
    }

    // MARK: - acting

    private func perform(_ pick: String, on tab: Tab, page: Page, task: String, key: String) async throws -> String {
        let web = tab.web
        switch pick {
        case "scroll_down", "scroll_up":
            let sign = pick == "scroll_down" ? "" : "-"
            _ = await Pilot.run(web, "window.scrollBy(0, \(sign)Math.round(innerHeight * 0.8)); 1")
            return pick == "scroll_down" ? "Scrolled down" : "Scrolled up"
        case "back":
            web.goBack()
            return "Went back"
        default:
            break
        }
        guard let target = page.target(pick) else { throw Jev.Failure.garbled }
        let (verb, element) = target
        let selector = "[data-jev=\"\(element.n)\"]"
        switch verb {
        case "click", "press":
            await click(web, selector)
            return "Clicked “\(element.label)”"
        case "select":
            let options = element.options ?? []
            guard !options.isEmpty else { throw Jev.Failure.garbled }
            var criteria: [String: String] = [:]
            for (i, option) in options.enumerated() { criteria["o\(i)"] = option }
            let answers = try await Jev.ask(
                state: ["task": task, "dropdown": element.label],
                questions: ["option": [
                    "type": "choice",
                    "instructions": "Which option of `dropdown` should be chosen to advance `task`?",
                    "criteria": criteria,
                ]],
                key: key
            )
            guard let pick = answers.choice("option")?.pick, let i = Int(pick.dropFirst()), options.indices.contains(i) else {
                throw Jev.Failure.garbled
            }
            _ = await Pilot.run(web, Pilot.choose(selector, index: i))
            return "Chose “\(options[i])” in “\(element.label)”"
        default:
            // type, enter, search: words from the task into the field, and
            // for the last two, Return after them.
            let phrases = Pilot.phrases(task)
            guard !phrases.isEmpty else { throw Jev.Failure.garbled }
            let answers = try await Jev.ask(
                state: ["task": task, "field": element.label, "page": page.title],
                questions: ["words": [
                    "type": "choice",
                    "instructions": "Which words from `task` should be typed into `field`?",
                    "criteria": Dictionary(uniqueKeysWithValues: phrases.map { ($0, NSNull()) }),
                ]],
                key: key
            )
            guard let words = answers.choice("words")?.pick else { throw Jev.Failure.garbled }
            _ = await Pilot.run(web, Bench.act("type", selector: selector, text: words))
            guard verb != "type" else { return "Typed “\(words)” into “\(element.label)”" }
            _ = await Pilot.run(web, "(function(){var el=document.querySelector('\(selector)'); if (el) el.focus(); return 1})()")
            Pilot.press(web, key: 36, characters: "\r")
            return "Typed “\(words)” into “\(element.label)” and pressed Return"
        }
    }

    /// Brought into view, then pressed where it now is — with the mouse, as a
    /// hand would, so a menu that opens on the press and not the click opens
    /// too. Anywhere the mouse can't reach, a plain click() in the page.
    private func click(_ web: WKWebView, _ selector: String) async {
        let spot = await Pilot.run(web, Pilot.centre(selector)) as? [Double]
        let scale = web.pageZoom * web.magnification
        guard let spot, spot.count == 2, let window = web.window else {
            _ = await Pilot.run(web, "(function(){var el=document.querySelector('\(selector)'); if (el) el.click(); return 1})()")
            return
        }
        let x = spot[0] * scale, y = spot[1] * scale
        guard x >= 0, y >= 0, x <= web.bounds.width, y <= web.bounds.height else {
            _ = await Pilot.run(web, "(function(){var el=document.querySelector('\(selector)'); if (el) el.click(); return 1})()")
            return
        }
        let local = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
        let point = web.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
        }
    }

    /// A real key, handed to the page's view — so Return in a field submits
    /// its form the way the browser does, not the way a script can fake.
    private static func press(_ web: WKWebView, key: UInt16, characters: String) {
        web.window?.makeFirstResponder(web)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: web.window?.windowNumber ?? 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: key
            ) else { continue }
            if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
        }
    }

    private static func run(_ web: WKWebView, _ js: String) async -> Any? {
        await withCheckedContinuation { done in
            web.evaluateJavaScript(js) { value, _ in done.resume(returning: value) }
        }
    }

    private static func doing(_ pick: String, _ page: Page) -> String {
        switch pick {
        case "scroll_down": return "Scrolling down"
        case "scroll_up": return "Scrolling up"
        case "back": return "Going back"
        default:
            guard let target = page.target(pick) else { return "Working" }
            let (verb, element) = target
            switch verb {
            case "click", "press": return "Clicking “\(element.label)”"
            case "select": return "Choosing in “\(element.label)”"
            default: return "Typing into “\(element.label)”"
            }
        }
    }

    /// Every run of words in the task, the candidates for what gets typed.
    /// Quoted text first, since that is almost always meant word for word;
    /// then every run of one word, two, and so on, while there is room among
    /// the 255 options a Choice can hold.
    static func phrases(_ task: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func add(_ phrase: String) {
            let phrase = phrase.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty, out.count < 240, seen.insert(phrase).inserted else { return }
            out.append(phrase)
        }
        if let quoted = try? NSRegularExpression(pattern: "[\"“]([^\"”]{1,200})[\"”]") {
            let whole = NSRange(task.startIndex..., in: task)
            for match in quoted.matches(in: task, range: whole) {
                if let range = Range(match.range(at: 1), in: task) { add(String(task[range])) }
            }
        }
        let words = task.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”,;:!?()[]")) }
            // A full stop ends the sentence, not the address or the name before it.
            .map { $0.hasSuffix(".") && !$0.hasSuffix("..") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return out }
        for length in 1...min(words.count, 12) {
            for start in 0...(words.count - length) {
                add(words[start..<start + length].joined(separator: " "))
            }
        }
        return out
    }

    // MARK: - reading the page

    struct Element {
        enum Kind: String { case click, press, toggle, field, search, area, select }
        let n: Int
        let kind: Kind
        let tag: String
        let label: String
        let value: String
        let href: String
        let options: [String]?
    }

    struct Page {
        let url: String
        let title: String
        let text: String
        let scrollY: Int
        let scrollMax: Int
        let elements: [Element]

        /// Enough to tell whether an action changed anything.
        var signature: String { "@\(url)#\(scrollY)#\(elements.count)#\(text.count)" }

        /// Every action there is on this page, as a Choice's options: what
        /// Jev is to pick from, each described in words it can weigh.
        func menu(canGoBack: Bool) -> [String: String] {
            var menu: [String: String] = [:]
            for element in elements {
                let named = "the \(element.tag) “\(element.label)”"
                let now = element.value.isEmpty ? "" : " (now: “\(element.value)”)"
                switch element.kind {
                case .click:
                    menu["click_e\(element.n)"] = "Click \(named)" + (element.href.isEmpty ? "" : " → \(element.href)")
                case .press:
                    menu["press_e\(element.n)"] = "Press \(named), sending its form"
                case .toggle:
                    menu["click_e\(element.n)"] = "Tick or untick \(named)" + now
                case .field:
                    menu["type_e\(element.n)"] = "Type into the field “\(element.label)” without sending it" + now
                    menu["enter_e\(element.n)"] = "Type into the field “\(element.label)” and press Return to send it" + now
                case .search:
                    menu["search_e\(element.n)"] = "Search: type the query into “\(element.label)” and run it" + now
                case .area:
                    menu["type_e\(element.n)"] = "Write into the text box “\(element.label)”" + now
                case .select:
                    menu["select_e\(element.n)"] = "Choose an option in the dropdown “\(element.label)”" + now
                }
            }
            if scrollY + 10 < scrollMax { menu["scroll_down"] = "Scroll down to see more of the page" }
            if scrollY > 0 { menu["scroll_up"] = "Scroll back up the page" }
            if canGoBack { menu["back"] = "Go back to the previous page" }
            menu["done"] = "Stop: the task is finished, or can't be done from here"
            return menu
        }

        func target(_ pick: String) -> (String, Element)? {
            guard let cut = pick.range(of: "_e"), let n = Int(pick[cut.upperBound...]),
                  let element = elements.first(where: { $0.n == n }) else { return nil }
            return (String(pick[..<cut.lowerBound]), element)
        }
    }

    private static func observe(_ web: WKWebView) async throws -> Page {
        guard let json = await run(web, look) as? String,
              let data = json.data(using: .utf8),
              let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Jev.Failure.refused(0, "Couldn't read this page")
        }
        let elements = (found["elements"] as? [[String: Any]] ?? []).compactMap { raw -> Element? in
            guard let n = raw["n"] as? Int, let kind = (raw["kind"] as? String).flatMap(Element.Kind.init) else { return nil }
            return Element(
                n: n, kind: kind,
                tag: raw["tag"] as? String ?? "element",
                label: raw["label"] as? String ?? "",
                value: raw["value"] as? String ?? "",
                href: raw["href"] as? String ?? "",
                options: raw["options"] as? [String]
            )
        }
        return Page(
            url: found["url"] as? String ?? "",
            title: found["title"] as? String ?? "",
            text: found["text"] as? String ?? "",
            scrollY: found["scrollY"] as? Int ?? 0,
            scrollMax: found["scrollMax"] as? Int ?? 0,
            elements: elements
        )
    }

    /// The page, read: its visible text, cut short, and everything on it that
    /// can be clicked, typed into or chosen from — each tagged in the page with
    /// a number, so the action Jev picks finds its way back. What is on screen
    /// comes first; password fields are left out altogether.
    static let look = #"""
    (function () {
      var LIMIT = 110;
      document.querySelectorAll('[data-jev]').forEach(function (e) { e.removeAttribute('data-jev'); });
      var query = 'a[href], button, input, select, textarea, summary, [contenteditable=""], [contenteditable="true"],' +
        '[role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=radio], [role=switch],' +
        '[role=option], [role=searchbox], [role=combobox], [role=textbox], [onclick]';
      function clean(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
      function shown(e) {
        var r = e.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
        var s = getComputedStyle(e);
        return s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity) > 0.05;
      }
      function onScreen(e) {
        var r = e.getBoundingClientRect();
        return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
      }
      function label(e) {
        var by = e.getAttribute('aria-labelledby');
        var named = by ? by.split(/\s+/).map(function (id) { var t = document.getElementById(id); return t ? t.innerText : ''; }).join(' ') : '';
        var img = e.querySelector && e.querySelector('img[alt]');
        return clean(e.getAttribute('aria-label') || named || (e.labels && e.labels[0] && e.labels[0].innerText) ||
          e.placeholder || (e.tagName === 'SELECT' ? '' : e.innerText) ||
          (e.type === 'submit' || e.type === 'button' ? e.value : '') || e.title || e.alt || (img && img.alt) ||
          e.name || e.id || '').slice(0, 80);
      }
      function kind(e) {
        var tag = e.tagName, role = e.getAttribute('role'), type = (e.getAttribute('type') || '').toLowerCase();
        if (tag === 'INPUT') {
          if (type === 'hidden' || type === 'password' || type === 'file') return null;
          if (type === 'checkbox' || type === 'radio') return 'toggle';
          if (type === 'submit' || type === 'image') return 'press';
          if (type === 'button' || type === 'reset') return 'click';
          if (type === 'search' || role === 'searchbox') return 'search';
          if (type === 'range' || type === 'color') return null;
          return 'field';
        }
        if (tag === 'TEXTAREA' || e.isContentEditable || role === 'textbox') return 'area';
        if (tag === 'SELECT') return 'select';
        if (role === 'searchbox') return 'search';
        if (role === 'checkbox' || role === 'radio' || role === 'switch') return 'toggle';
        if (tag === 'BUTTON' && (type === 'submit' || (!type && e.form))) return 'press';
        return 'click';
      }
      var near = [], far = [];
      document.querySelectorAll(query).forEach(function (e) {
        if (e.disabled || e.getAttribute('aria-disabled') === 'true' || !kind(e) || !shown(e)) return;
        // A link inside a link, a span inside a button: the outer one is what gets pressed.
        var up = e.parentElement && e.parentElement.closest('a[href], button, [role=button], [role=link]');
        if (up && kind(e) === 'click') return;
        (onScreen(e) ? near : far).push(e);
      });
      var out = [];
      near.concat(far).slice(0, LIMIT).forEach(function (e, n) {
        var k = kind(e);
        e.setAttribute('data-jev', String(n));
        var item = { n: n, kind: k, tag: (e.getAttribute('role') || e.tagName).toLowerCase(), label: label(e) || '(unlabelled)' };
        if (k === 'field' || k === 'search' || k === 'area') item.value = clean(e.isContentEditable ? e.innerText : e.value).slice(0, 60);
        if (k === 'toggle') item.value = (e.checked || e.getAttribute('aria-checked') === 'true') ? 'ticked' : 'not ticked';
        if (k === 'select') {
          item.value = e.selectedIndex >= 0 ? clean(e.options[e.selectedIndex].text).slice(0, 60) : '';
          item.options = Array.prototype.slice.call(e.options, 0, 200).map(function (o) { return clean(o.text).slice(0, 80) || '(empty)'; });
        }
        if (e.tagName === 'A' && e.href) {
          try { var u = new URL(e.href, location.href); item.href = (u.host === location.host ? '' : u.host) + u.pathname.slice(0, 60); } catch (_) {}
        }
        out.push(item);
      });
      var root = document.scrollingElement || document.documentElement;
      return JSON.stringify({
        url: location.href, title: document.title,
        text: clean(document.body ? document.body.innerText : '').slice(0, 2500),
        scrollY: Math.round(root.scrollTop), scrollMax: Math.max(0, Math.round(root.scrollHeight - innerHeight)),
        elements: out
      });
    })();
    """#

    private static func centre(_ selector: String) -> String {
        """
        (function () {
          var el = document.querySelector('\(selector)');
          if (!el) return 0;
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var r = el.getBoundingClientRect();
          return [r.left + r.width / 2, r.top + r.height / 2];
        })();
        """
    }

    private static func choose(_ selector: String, index: Int) -> String {
        """
        (function () {
          var el = document.querySelector('\(selector)');
          if (!el) return 0;
          el.focus();
          el.selectedIndex = \(index);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 1;
        })();
        """
    }
}

/// Saying what Jev should do. The same pill as finding on the page, rising
/// from the bottom edge; while it works, the pill says what it is doing.
struct PilotBar: View {
    @ObservedObject var pilot: Pilot

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                ZStack(alignment: .leading) {
                    if pilot.task.isEmpty {
                        Text("What should Jev do on this page?")
                            .foregroundStyle(Palette.ink.opacity(0.3))
                    }
                    TextField("", text: $pilot.task)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .focused($focused)
                        .disabled(pilot.running)
                        .onSubmit { pilot.start() }
                }
                .font(.system(size: 12.5))
                .frame(width: 320)
                if pilot.running {
                    ProgressView().controlSize(.small)
                }
                Button(action: { pilot.running ? pilot.stop() : pilot.close() }) {
                    Image(systemName: pilot.running ? "stop.fill" : "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pilot.running ? "Stop" : "Close")
            }
            if let line = pilot.line {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.leading, 19)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .animation(Motion.quick, value: pilot.line)
        .onAppear { focused = true }
        .onChange(of: pilot.focus) { _, _ in focused = true }
    }
}

/// Where the bar stands among the others at the bottom edge: only while it is
/// open, and only while it is switched on in Settings.
struct PilotSlot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var pilot: Pilot

    var body: some View {
        Group {
            if pilot.open, browser.prefs.pilot {
                PilotBar(pilot: pilot)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: pilot.open)
    }
}
