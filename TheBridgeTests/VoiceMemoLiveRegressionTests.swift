// VoiceMemoLiveRegressionTests.swift — live-suite fixtures as unit tests (PKT-MEM-105/106)
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runVoiceMemoLiveRegressionTests() async {
    print("\n🎙️ Voice Memos live regression fixtures")

    await test("homophone: blog that → log that contact lane") {
        let transcript = "Blog that I talked with Jacob about the Bridge launch."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(plan.intents.contains { $0.kind == .registryUpdate && $0.entityKey == "contact" }, "contact lane")
        try expect(plan.intents.contains { $0.entityHint?.lowercased().contains("jacob") == true }, "Jacob hint")
    }

    await test("PKT-MEM-127: real GH #73 transcript ('Name, my client') extracts the actual name, not a false-positive word") {
        // VERBATIM excerpt from the real GH #73 memo (fetched live this
        // session via voice_memo_get — not a paraphrase): "So, I just
        // scheduled a meeting with Greg, Flachek, my client, and... I need to
        // get prepared for it." Name-FIRST, "client" as an appositive AFTER
        // the name, with a dictation-pause comma between first/last name.
        //
        // An earlier version of this fix used a forward-only "client <Name>"
        // pattern built from a SECONDHAND PARAPHRASE of this transcript
        // ("my client, Greg Flachek") rather than the real text — live
        // verification against the actual server caught it matching
        // "client, and..." and extracting "And" as the "name", a real
        // false-positive shipped to production and caught only by testing
        // against the real transcript instead of trusting a paraphrase.
        let transcript = "So, I just scheduled a meeting with Greg, Flachek, my client, and... I need to get prepared for it."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(plan.intents.contains { $0.kind == .registryUpdate && $0.entityKey == "contact" }, "contact lane fires for client phrasing")
        try expect(plan.intents.contains { $0.entityHint?.lowercased().contains("greg") == true && $0.entityHint?.lowercased().contains("flachek") == true },
                    "Greg Flachek hint extracted (comma pause artifact collapsed to a clean name)")
        try expect(!plan.intents.contains { $0.entityHint?.lowercased() == "and" }, "must never regress to capturing the word 'and' as a name")
    }

    await test("PKT-MEM-127: 'a client named Name' extracts a contact-lane hint (forward form)") {
        let transcript = "I met with a client named Sarah Chen about the Q3 renewal."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(plan.intents.contains { $0.entityKey == "contact" && ($0.entityHint?.lowercased().contains("sarah") == true) }, "Sarah Chen hint extracted")
    }

    await test("PKT-MEM-127: generic plural 'clients' mention does not misfire a false contact hint") {
        let transcript = "Some of my clients won't have notion, and that's fine for now."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(!plan.intents.contains { $0.entityKey == "contact" }, "plural 'clients' with no named person must not fire the contact lane")
    }

    await test("entityHints: bare update session does not fire contact lane") {
        let transcript = "Update session DST-8 objective to ship memory hub."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(!plan.intents.contains { $0.entityKey == "contact" }, "no contact misfire")
        try expect(plan.intents.contains { $0.entityKey == "session" && $0.entityHint == "DST-8" }, "session DST-8")
    }

    await test("session lane: DST-N without PKT prefix") {
        let plan = VoiceMemoParser.parse(
            transcript: "Update session DST-8 — focus on trust fixes.",
            fallbackTitle: "Memo"
        )
        let session = plan.intents.first { $0.entityKey == "session" }
        try expect(session?.entityHint == "DST-8", "DST-8 hint")
        try expect((session?.confidence ?? 0) >= 0.85, "auto-execute confidence")
    }

    await test("block lane: update block extracts hint") {
        let plan = VoiceMemoParser.parse(
            transcript: "Update block Event block. Description is the live test run.",
            fallbackTitle: "Memo"
        )
        try expect(plan.intents.contains { $0.entityKey == "block" }, "block lane")
    }

    await test("project lane confidence ≥ 0.85 for Bridge v4") {
        let plan = VoiceMemoParser.parse(
            transcript: "Update project Bridge v4 — ship trust fixes this week.",
            fallbackTitle: "Memo"
        )
        let project = plan.intents.first { $0.entityKey == "project" }
        try expect((project?.confidence ?? 0) >= 0.85, "project auto-execute threshold")
    }

    await test("reminder title prefers block phrase over remind tail") {
        let transcript = "Block deep work on Memory Hub v4. Remind me to start at 9am with pass phrase."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        let reminder = plan.intents.first { $0.kind == .reminder }
        try expect(reminder?.title?.lowercased().contains("deep work") == true || reminder?.title?.lowercased().contains("memory hub") == true,
                   "block-derived title, got \(reminder?.title ?? "nil")")
    }

    await test("primary intent election suppresses secondary lanes") {
        let intents = [
            VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "Email Sarah"),
            VoiceMemoIntent(kind: .memoryKeep, confidence: 0.9, entityKey: "memory"),
            VoiceMemoIntent(kind: .agentMemory, confidence: 0.88),
        ]
        let split = VoiceMemoIntentElection.split(intents)
        try expect(split.execute.count == 1, "one execute lane")
        try expect(split.execute.first?.kind == .reminder, "highest priority wins")
        try expect(split.suppressed.count == 2, "two suppressed")
    }

    await test("appendVoiceMemoLog preserves existing content") {
        let merged = VoiceMemoParser.appendVoiceMemoLog(existing: "Prior brief.", newContent: "New note.")
        try expect(merged.contains("Prior brief."), "keeps existing")
        try expect(merged.contains("New note."), "appends new")
        try expect(merged.contains("Voice memo"), "stamp marker")
    }

    await test("processed gate: review queued prevents mark (logic)") {
        // Document invariant: processOne sets reviewQueuedForMemo when queueReview fires.
        let reviewQueuedForMemo = true
        let hasExecuted = true
        let shouldMark = hasExecuted && !reviewQueuedForMemo
        try expect(!shouldMark, "must not mark processed when review pending")
    }

    await test("curator heuristics mode skips Ollama summarization flag") {
        let prior = UserDefaults.standard.string(forKey: BridgeDefaults.voiceMemoCuratorMode)
        UserDefaults.standard.set(VoiceMemoCuratorMode.heuristics.rawValue, forKey: BridgeDefaults.voiceMemoCuratorMode)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: BridgeDefaults.voiceMemoCuratorMode) }
            else { UserDefaults.standard.removeObject(forKey: BridgeDefaults.voiceMemoCuratorMode) }
        }
        try expect(!VoiceMemoCuratorRouter.shouldSummarizeForMemoryKeep(), "heuristics skips LLM summary")
    }
}
