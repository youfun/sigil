defmodule SigilProbe.AppStagingRootsTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:sigil_probe, :staging_roots)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:sigil_probe, :staging_roots)
      else
        Application.put_env(:sigil_probe, :staging_roots, previous)
      end
    end)

    :ok
  end

  test "host env does not invent staging roots" do
    Application.delete_env(:sigil_probe, :staging_roots)
    assert :ok = SigilProbe.App.configure_staging_roots!(%{})
    assert Application.get_env(:sigil_probe, :staging_roots) == nil

    assert :ok = SigilProbe.App.configure_staging_roots!(%{"MOB_CACHE_DIR" => ""})
    assert Application.get_env(:sigil_probe, :staging_roots) == nil
  end

  test "device MOB_CACHE_DIR maps to cacheDir/controlled_import" do
    cache = Path.join(System.tmp_dir!(), "mob_cache_#{System.unique_integer([:positive])}")
    assert :ok = SigilProbe.App.configure_staging_roots!(%{"MOB_CACHE_DIR" => cache})

    assert Application.get_env(:sigil_probe, :staging_roots) == [
             Path.join(cache, "controlled_import")
           ]
  end

  test "packaged model seed initializes supported apps without overwriting existing config" do
    priv = Path.join(System.tmp_dir!(), "priv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(priv)
    seed = Path.join(priv, "models.seed.json")
    body = ~s({"defaultProvider":"stepfun","providers":{}})
    File.write!(seed, body)
    old_seed = System.get_env("SIGIL_MODELS_SEED")
    old_models = System.get_env("SIGIL_MODELS_FILE")
    System.delete_env("SIGIL_MODELS_SEED")

    on_exit(fn ->
      for {key, value} <- [{"SIGIL_MODELS_SEED", old_seed}, {"SIGIL_MODELS_FILE", old_models}] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      File.rm_rf!(priv)
    end)

    assert :ignored =
             SigilProbe.App.maybe_set_models_seed(priv, %{
               "MOB_NODE_SUFFIX" => "other"
             })

    assert System.get_env("SIGIL_MODELS_SEED") == nil

    for suffix <- ["foundationtest", "nativechat"] do
      assert :seed = SigilProbe.App.maybe_set_models_seed(priv, %{"MOB_NODE_SUFFIX" => suffix})
      assert System.get_env("SIGIL_MODELS_SEED") == seed
      target = Path.join(priv, "#{suffix}/models.json")
      System.put_env("SIGIL_MODELS_FILE", target)
      assert :ok = Sigil.Agent.ModelConfig.ensure_config()
      assert File.read!(target) == body

      File.write!(target, ~s({"custom":true}))
      assert :ok = Sigil.Agent.ModelConfig.ensure_config()
      assert File.read!(target) == ~s({"custom":true})
    end
  end

  test "device MOB_DATA_DIR maps to filesDir/share_intake" do
    Application.delete_env(:sigil_probe, :staging_roots)
    data = Path.join(System.tmp_dir!(), "mob_data_#{System.unique_integer([:positive])}")
    assert :ok = SigilProbe.App.configure_staging_roots!(%{"MOB_DATA_DIR" => data})
    assert Application.get_env(:sigil_probe, :staging_roots) == [Path.join(data, "share_intake")]
  end
end
