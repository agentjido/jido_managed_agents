defmodule JidoManagedAgents.Vault do
  @moduledoc """
  Shared `Cloak` vault for `AshCloak`-encrypted Ash attributes.

  Runtime configuration supplies the Base64-encoded key through the
  `:secret_encryption` application config:

  - development uses `JIDO_MANAGED_AGENTS_CLOAK_KEY` when present and otherwise
    falls back to a deterministic local key
  - test uses the same environment variable when present and otherwise falls
    back to a deterministic test key for repeatable specs
  - production requires `JIDO_MANAGED_AGENTS_CLOAK_KEY`

  Future secret-bearing Ash resources should reference this vault in their
  `cloak` DSL so multiple credential types can reuse one encryption foundation.
  """

  use Cloak.Vault, otp_app: :jido_managed_agents

  @cipher_tag "AES.GCM.V1"
  @iv_length 12

  @impl GenServer
  def init(config) do
    config =
      config
      |> Keyword.put_new(:json_library, Jason)
      |> Keyword.put(:ciphers, default: cipher_config(secret_config()))

    {:ok, config}
  end

  def cipher_tag, do: @cipher_tag

  def iv_length, do: @iv_length

  def key_source do
    secret_config()
    |> Keyword.fetch!(:source)
  end

  defp secret_config do
    Application.fetch_env!(:jido_managed_agents, :secret_encryption)
  end

  defp cipher_config(secret_config) do
    {Cloak.Ciphers.AES.GCM,
     tag: @cipher_tag,
     key: decode_key!(Keyword.fetch!(secret_config, :key)),
     iv_length: @iv_length}
  end

  defp decode_key!(key) when is_binary(key) do
    Base.decode64!(key)
  end
end
