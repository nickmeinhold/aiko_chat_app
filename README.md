# aiko_chat_app

Aiko Chat — mobile app (Flutter, Riverpod). Talks to the aiko-chat-island WSS+REST contract.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## License

**GNU AGPL-3.0** ([`LICENSE`](LICENSE)). Decided 2026-07-17/20 with the AI+ML+Robots squad,
as a choice about culture rather than about law: *anyone can run an island, nobody can
capture one.* Using Aiko Chat is completely free, with no obligations. The obligation
attaches to **modifying and then serving or distributing** it, and then only to publishing
those changes.

The same licence covers the client and the gateway
([`aiko-chat-island`](https://github.com/nickmeinhold/aiko-chat-island)) deliberately, so
the commons is not split down the middle of one product. The network-use clause is what
bites hardest on the island — the half that gets run as a service — while for this client
the familiar distribution terms do the work. See [`LICENSE`](LICENSE) for the actual terms;
the summary here is orientation, not legal advice.

**Commons-owned — there is no contributor licence agreement and no copyright assignment**
(the Linux model). Contributions stay owned by whoever wrote them, which makes the licence
effectively permanent once outside contributions arrive: nobody, including the original
authors, can later take it proprietary. That is deliberate, and it is the point. Anyone
proposing a CLA later is proposing to reverse a decision, not to fill a gap.

**A linking exception is intended and not yet written.** The agreement was "AGPL-3.0 with a
ClassPath-style exception (or similar)", so that genuinely independent work — Agents,
Robots, PipelineElements, Actors that link against or run on an island without being
modifications of it — is not forced to adopt this licence. That wording is still being
settled. Adding permissions later is always possible under the licence; removing them is
not, so the base licence lands first and the exception follows.

Sibling projects are deliberately licensed differently:
[`aiko_services`](https://github.com/geekscape/aiko_services) is Apache-2.0 under a
stewardship model, which is a different bet, made on purpose.

---

Part of the aiko mesh: [`aiko_services`](https://github.com/geekscape/aiko_services)
(framework) · [`aiko_chat`](https://github.com/geekscape/aiko_chat) (ChatServer)
· [`aiko-chat-island`](https://github.com/nickmeinhold/aiko-chat-island) (the gateway this
client talks to).
