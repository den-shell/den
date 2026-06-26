---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Den Shell"
  text: "A blazing-fast POSIX shell written in Zig"
  tagline: "Native performance meets modern safety"
  image: /images/logo-white.png
  actions:
    - theme: brand
      text: Get Started
      link: /intro
    - theme: alt
      text: View on GitHub
      link: https://github.com/stacksjs/den

features:
  - title: "⚡ Instant Startup"
    icon: "⚡"
    details: "~4-5ms cold start. Native code, no runtime or VM."
  - title: "🛡️ Memory Safe"
    icon: "🛡️"
    details: "Written in Zig. Compile-time safety prevents memory leaks and crashes."
  - title: "📦 Self-Contained"
    icon: "📦"
    details: "A single binary that links only libc — fewer dynamic deps than bash or zsh."
  - title: "🎯 Feature Rich"
    icon: "🎯"
    details: "58 builtins, job control, history, completion, and full POSIX support."
  - title: "🔧 Extensible"
    icon: "🔧"
    details: "Plugin system, custom themes, and comprehensive configuration."
  - title: "📊 Benchmarked"
    icon: "📊"
    details: "Real, reproducible benchmarks via scripts/bench.sh — no made-up numbers."
---