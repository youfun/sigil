# Reach architecture policy for Sigil
# See https://github.com/elixir-vibe/reach for full reference
#
# Known accepted trade-offs:
#   agent ↔ pubsub cycle — PubSub.Session manages Agent.CandidateQueue directly.
#     Accepted: they run in the same BEAM process tree and share runtime state.
#     Session already holds queue_pid (Agent exposes it intentionally).

[
  # ── Architecture Layers ──
  layers: [
    web: "SigilWeb.*",

    # Runtime = Agent + Tool + PubSub, tightly coupled by design
    runtime: ["Sigil.Agent.*", "Sigil.Tool.*", "Sigil.PubSub.*"],
    mcp: "Sigil.MCP.*",
    memory: "Sigil.Memory.*",
    delivery: "Sigil.Delivery*",
    store: ["Sigil.SessionStore*", "Sigil.ConversationTranscriptStore*"],
    extension: "Sigil.Extension.*",
    log: "Sigil.Log.*",
    security: "Sigil.Security.*",
    utils: "Sigil.Utils*",
    mix_tasks: "Sigil.Mix.Tasks.*",
    csv: ["Sigil.Csv*", "Sigil.CsvProfile*"],
    permissions: "Sigil.Permissions*",
    settings: "Sigil.Settings*",
    skills: "Sigil.Skills*"
  ],

  # ── Dependency Rules ──
  deps: [
    forbidden: [
      # Core layers must NOT depend on web (web is a projection, not the owner)
      {:runtime, :web},
      {:memory, :web},
      {:mcp, :web},
      {:delivery, :web},
      {:security, :web},
      {:log, :web},

      # Delivery is outbound only — must not drive agent logic
      {:delivery, :runtime},

      # Memory should stay focused on storage, not runtime orchestration
      {:memory, :runtime}
    ]
  ],

  # ── Source Restrictions ──
  source: [
    forbidden_modules: []
  ],

  # ── Call Restrictions ──
  calls: [
    forbidden: [
      # Runtime must not do raw IO (use Logger instead)
      {"Sigil.Agent.*", ["IO.puts", "IO.inspect"]},
      {"Sigil.Tool.*", ["IO.puts", "IO.inspect"]},

      # Web layer must not touch database directly
      {"SigilWeb.*", ["Sigil.Repo"]},

      # PubSub must not access database directly
      {"Sigil.PubSub.*", "Sigil.Repo"},

      # Delivery must not access database directly
      {"Sigil.Delivery*", "Sigil.Repo"}
    ]
  ],

  # ── Test Hints ──
  tests: [
    hints: [
      {"lib/sigil/agent/**", ["test/sigil/agent/*_test.exs"]},
      {"lib/sigil/tool/**", ["test/sigil/tool/*_test.exs"]},
      {"lib/sigil/mcp/**", ["test/sigil/mcp/*_test.exs"]},
      {"lib/sigil_web/**", ["test/sigil_web/*_test.exs"]}
    ]
  ]
]
