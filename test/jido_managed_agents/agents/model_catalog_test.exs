defmodule JidoManagedAgents.Agents.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias JidoManagedAgents.Agents.ModelCatalog

  test "exposes configured providers and resolves the default model" do
    provider_options = ModelCatalog.provider_options()
    provider_ids = Enum.map(provider_options, &elem(&1, 1))

    assert provider_options != []
    assert "anthropic" in provider_ids

    provider = ModelCatalog.default_provider()
    assert is_atom(provider)
    assert Atom.to_string(provider) in provider_ids

    assert %LLMDB.Model{id: model_id} = model = ModelCatalog.default_model(provider)
    assert {:ok, %LLMDB.Model{id: ^model_id}} = ModelCatalog.resolve(provider, model.id)
  end

  test "returns provider-scoped model options for the selected provider" do
    provider = ModelCatalog.default_provider()
    %LLMDB.Model{id: model_id} = ModelCatalog.default_model(provider)

    model_ids =
      provider
      |> ModelCatalog.model_options(model_id)
      |> Enum.map(&elem(&1, 1))

    assert model_id in model_ids

    assert {:ok, %LLMDB.Model{provider: ^provider, id: ^model_id}} =
             ModelCatalog.resolve(provider, model_id)
  end

  test "normalizes string provider identifiers and trims model ids" do
    assert ModelCatalog.normalize_provider(" openai ") == :openai

    provider = ModelCatalog.default_provider()
    %LLMDB.Model{id: model_id} = ModelCatalog.default_model(provider)

    assert {:ok, %LLMDB.Model{id: ^model_id}} =
             ModelCatalog.resolve(Atom.to_string(provider), " #{model_id} ")
  end
end
