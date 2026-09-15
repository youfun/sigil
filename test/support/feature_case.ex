defmodule SigilWeb.FeatureCase do
  @moduledoc """
  This module defines the test case to be used by
  PhoenixTest feature tests.

  Uses PhoenixTest for unified feature testing regardless of
  whether pages are LiveView or static.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use SigilWeb, :verified_routes

      import SigilWeb.FeatureCase
      import PhoenixTest

      @endpoint SigilWeb.Endpoint
    end
  end

  setup tags do
    Sigil.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
