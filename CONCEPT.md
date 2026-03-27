# 🌌 Quicksilver Shell

> **Vision:** A decentralized, local-native computing environment where the UI is a fluid, MSDF-based "metamaterial." No HTML, no CSS, no legacy box models. Lazy, Wizard of Oz evolution of BitNet (and optional cloud LLM) agents embodied as Roc programs compiled to wasm. The Roc compiler is included, and BitNet is provided with info about the system, messaging DSL (a shared language between humans, programs, and LLM agents, which does Markdown-style visual annotation as well as template population from the Roc model, pure expressions, function calls, providing access to the evolving DSL of that domain)... so that it can operate in the system as well as update its own Roc code. It should run in the browser, or a native window on any platform.

## Mercury
**Mercury** will be the Super Agent. He will facilitate the interaction between agents in the system, including the human user, and guide them in the spawning and evolution of new agents. When the system loads, it immediately prompts Mercury. Mercury decides what to do next. If the user appears to be new (no nsec, etc.), he will begin the onboarding dialog that beings with "are we speaking the right language?", basically, then "are you continuing or new" / "create a new nostr keypair or import one". Everything is dialog. There is never anything on the screen that isn't encapsulated as a message. Except the background visual effect. Every input element is in a message which had a request for that type of data. So Mercury and the other agents are renderer agnostic; they only know about messages and how to ask for data. And the UI is just an affordance to the user to provide it. Other agents don't need it, or might be using a different type of interface, like speech. 

## 🛠 Tech Stack
- **Logic Engine:** [Roc](https://www.roc-lang.org/) (Pure functional, Elm-architecture routing).
- **System Host:** [Zig](https://ziglang.org/) (Memory management, WASM lifecycle, C-interop).
- **Graphics:** [WGPU](https://wgpu.rs/) + WGSL (MSDF "Pure Message-based UI" renderer).
- **Typography:** Use Harfbuzz linked to Zig, called by Roc.
- **Layout:** Port functions from Clay to Roc. There is only the List of Message Lists, and Messages, and inner Elements.
- **Interface Concept:** All UI is modelled as messaging, and all UI element interaction results in Reply Messages with the requested types and tags requested. This enables Wizard of Oz development, and LLM integration. It treats the Message List as a shared medium between humans, LLM agents, and Roc programs, and integrates the system across devices using nostr (upgrading to direct p2p).
- **Canon of Elements:** Create a good starting canon of Elements that can reflect the types of our messaging language to display and request data. Instead of using "legacy" toolkits like Basecoat UI and QML, we have a canon of elements in Roc, with corresponding sections of the shader, and BitNet integrated through a "visual harness". Mercury is aware of the visual state, which is rendered to him through a self-directed LOD, and he is able to set the next visual transitions through messages handled by a Roc update function. Mercury can be constantly looping, at a relatively slow rate, while deciding things like background visual changes, and other visual effects applied to the whole scene, maintaining focus, and also keeping the interface alive and vibrant. We will publish new elements over nostr, and they will be hot-swappable. Same with themes for the whole system. Different shaders and layouts.
- **Windowing:** `zglfw` (Ultra-light native shell).
- **Intelligence:** [BitNet 1.58b](https://github.com/microsoft/BitNet) (Local ternary LLM kernel).
- **Network:** [Nostr](https://nostr.com/) + [MLS](https://messaginglayersecurity.rocks/) (P2P signaling and state sync).

## 🧬 The Starting Canon SDF Primitives
### Propose more! We want to build a comprehensive UI model. This was your idea! I hope it isn't too abstract, but I love it.
Every element in the shell is composed of these three mathematical intents:
1. **Cell:** Rounded-rect containers with variable surface tension (viscosity).
2. **Tendril:** Variable-thickness segments connecting Cells (threads/nodes).
3. **Field:** Radial influence zones for focus, aura, and context.

Is this enough? I mean, can we do a code editor with that? A 3D modeller?

Let's name everything mythologically. Hades is the god of the underworld, in our case our host system, network, storage, key rotation...

## 📂 Project Structure
- `/mercury`: `Mercury.roc` - Super Agent, Event Bus, Core Commands, Agent Router.
- `/hades`: `main.zig` - WGPU renderer, host platform, AES storage, nostr, MLS, wasm agent lifecycle, including serialization and deserialization so that agents can sleep, and wake on messages or timers.
- `/agents`: Independent `.roc` WASM blobs for different subagents; extended by in-system installed / developed agents at runtime.
- `/shaders`: `material.wgsl` - The SDF renderer. We prob want a few, and to be able to swap them at runtime and install custom ones from nostr, and edit them live inside the app.
