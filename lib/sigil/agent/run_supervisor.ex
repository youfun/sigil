defmodule Sigil.Agent.RunSupervisor do
  @moduledoc """
  Per-conversation run supervision tree.

  A run is an atomic unit: the queue and runner are started together, and
  `:one_for_all` ensures neither survives alone after a crash.
  """

  use Supervisor

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    Supervisor.start_link(__MODULE__, opts,
      name: {:via, Registry, {Sigil.AgentRunSupervisorRegistry, conversation_id}}
    )
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    queue_name = {:via, Registry, {Sigil.AgentRunQueueRegistry, conversation_id}}

    queue_opts = [
      session_id: conversation_id,
      owner: self(),
      name: queue_name
    ]

    runner_opts =
      opts
      |> Keyword.put(:queue_name, queue_name)

    Supervisor.init(
      [
        Supervisor.child_spec({Sigil.Agent.CandidateQueue, queue_opts},
          id: Sigil.Agent.CandidateQueue,
          restart: :transient
        ),
        Supervisor.child_spec({Sigil.Agent.Runner, runner_opts},
          id: Sigil.Agent.Runner,
          restart: :transient
        )
      ],
      strategy: :one_for_all,
      max_restarts: 1,
      max_seconds: 5
    )
  end
end
